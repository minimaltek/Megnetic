//
//  AudioEngine.swift
//  Magnetic
//
//  Real-time microphone input with FFT frequency analysis
//

import AVFoundation
import Accelerate
import Combine
import QuartzCore

@MainActor
final class AudioEngine: ObservableObject {
    
    // Audio energy levels (updated at throttled rate to avoid SwiftUI thrashing)
    @Published var bassEnergy: Float = 0
    @Published var midEnergy: Float = 0
    @Published var highEnergy: Float = 0
    @Published var isRunning = false
    
    // Mic input level (0..1, for level meter display)
    @Published var inputLevel: Float = 0
    
    // BPM detection
    @Published var detectedBPM: Float = 0       // 0 = not detected
    @Published var beatPhase: Float = 0          // 0..1, cycles with the beat
    @Published var predictedBeatPulse: Float = 0 // spikes to 1.0 on predicted beat
    @Published var beatFired: Bool = false       // true for ~120ms on each beat
    private var beatOffTask: Task<Void, Never>?
    
    // Throttle: accumulate updates, publish at display rate
    private var pendingBass: Float = 0
    private var pendingMid: Float = 0
    private var pendingHigh: Float = 0
    private var pendingBPM: Float = 0
    private var pendingPhase: Float = 0
    private var pendingPulse: Float = 0
    private var pendingInputLevel: Float = 0
    private var hasPendingUpdate = false
    private var displayLink: CADisplayLink?
    
    // Gain mode: 0 = AUTO (adaptive), 1 = MANUAL (slider)
    var gainMode: Int = 0
    var manualGainValue: Float = 3.0
    
    // Auto-gain state
    private var noiseFloor: Float = 0.0        // slow-adapting ambient noise level
    private var signalPeak: Float = 0.001      // fast-attack, slow-decay signal peak
    private var smoothedAutoGain: Float = 1.5  // smoothed output gain to prevent pumping
    private var autoGainInitialized = false
    
    /// Current effective gain (readable for reactivity bridging)
    var effectiveGain: Float {
        gainMode == 0 ? smoothedAutoGain : manualGainValue
    }
    
    private var beatDetector = BeatDetector()
    
    private var audioEngine: AVAudioEngine?
    private let bufferSize: AVAudioFrameCount = 1024
    
    // FFT processor runs off main actor
    private let fftProcessor = FFTProcessor(bufferSize: 1024)
    
    /// Called by display link to flush pending audio updates to @Published properties.
    /// This batches multiple audio tap callbacks into one SwiftUI update per frame.
    @objc private func flushAudioUpdates(_ link: CADisplayLink) {
        guard hasPendingUpdate else { return }
        hasPendingUpdate = false
        
        bassEnergy = pendingBass
        midEnergy = pendingMid
        highEnergy = pendingHigh
        detectedBPM = pendingBPM
        beatPhase = pendingPhase
        predictedBeatPulse = pendingPulse
        inputLevel = pendingInputLevel
    }
    
    func requestPermissionAndStart() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                if granted {
                    self?.start()
                }
            }
        }
    }
    
    func start() {
        guard !isRunning else { return }
        
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            print("Audio session error: \(error)")
            return
        }
        
        // Set up display link to throttle @Published updates to screen refresh rate
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(flushAudioUpdates(_:)))
            link.preferredFramesPerSecond = 30  // match Metal view's frame rate
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        
        let processor = fftProcessor
        
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, time in
            let result = processor.process(buffer: buffer, sensitivity: 1.0)
            let now = CACurrentMediaTime()
            Task { @MainActor [weak self] in
                guard let self else { return }
                
                // Compute current energy for auto-gain tracking
                let currentEnergy = result.bass + result.mid * 0.7 + result.high * 0.3
                
                if self.gainMode == 0 {
                    // AUTO gain: adaptive algorithm that mimics human hearing
                    if !self.autoGainInitialized {
                        self.noiseFloor = currentEnergy
                        self.signalPeak = max(currentEnergy, 0.001)
                        self.autoGainInitialized = true
                    }
                    
                    // Noise floor: slow rise (adapts to rising ambient), fast fall (detects quieter env)
                    if currentEnergy < self.noiseFloor {
                        self.noiseFloor = self.noiseFloor * 0.95 + currentEnergy * 0.05
                    } else {
                        self.noiseFloor = self.noiseFloor * 0.9995 + currentEnergy * 0.0005
                    }
                    
                    // Signal peak: fast rise (catch transients), slow decay
                    if currentEnergy > self.signalPeak {
                        self.signalPeak = self.signalPeak * 0.7 + currentEnergy * 0.3
                    } else {
                        self.signalPeak = self.signalPeak * 0.995 + currentEnergy * 0.005
                    }
                    
                    // Compute target gain from dynamic range
                    let dynamicRange = max(self.signalPeak - self.noiseFloor, 0.001)
                    let targetOutput: Float = 0.4
                    let rawGain = targetOutput / dynamicRange
                    let clampedGain = min(max(rawGain, 0.5), 20.0)
                    
                    // Smooth gain changes: slow attack, moderate release
                    let smoothAlpha: Float = clampedGain > self.smoothedAutoGain ? 0.02 : 0.05
                    self.smoothedAutoGain += (clampedGain - self.smoothedAutoGain) * smoothAlpha
                }
                
                let gain = self.effectiveGain
                let bass = result.bass * gain
                let mid = result.mid * gain
                let high = result.high * gain
                
                // Accumulate into pending values (published by display link)
                self.pendingBass = max(bass, self.pendingBass * 0.8)
                self.pendingMid = max(mid, self.pendingMid * 0.82)
                self.pendingHigh = max(high, self.pendingHigh * 0.85)
                
                // Input level for meter (fast attack, moderate decay, normalized to 0..1)
                let rawLevel = (bass + mid * 0.7 + high * 0.3)
                let normalizedLevel = min(rawLevel / 0.8, 1.0)
                // Fast attack (0.6) for peaks, slower decay (0.15) for smooth falloff
                let levelAlpha: Float = normalizedLevel > self.pendingInputLevel ? 0.6 : 0.15
                self.pendingInputLevel = self.pendingInputLevel * (1.0 - levelAlpha) + normalizedLevel * levelAlpha
                
                // Feed beat detector with multi-band flux
                let beatResult = self.beatDetector.feed(
                    bassFlux: result.bassFlux * gain,
                    midFlux: result.midFlux * gain,
                    highFlux: result.highFlux * gain,
                    bassEnergy: bass,
                    highEnergy: high,
                    zcr: result.zcr,
                    timestamp: now
                )
                self.pendingBPM = beatResult.bpm
                self.pendingPhase = beatResult.phase
                let prevPulse = self.pendingPulse
                self.pendingPulse = beatResult.pulse
                self.hasPendingUpdate = true
                
                // Fire beat indicator: on when pulse spikes, off after 120ms
                // (beatFired is published immediately for responsive UI feedback)
                if beatResult.pulse > 0.7 && prevPulse < 0.5 {
                    self.beatFired = true
                    self.beatOffTask?.cancel()
                    self.beatOffTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 120_000_000) // 120ms
                        if !Task.isCancelled {
                            self.beatFired = false
                        }
                    }
                }
            }
        }
        
        do {
            try engine.start()
            self.audioEngine = engine
            self.isRunning = true
        } catch {
            print("Audio engine start error: \(error)")
        }
    }
    
    func stop() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRunning = false
        
        displayLink?.invalidate()
        displayLink = nil
    }
}

// MARK: - BPM Beat Detector (Spectral Flux + Autocorrelation + Pulse Train Scoring)
//
// Algorithm based on Percival & Tzanetakis (2014) and Beat-and-Tempo-Tracking:
//   1. Spectral flux onset signal → ring buffer
//   2. Generalized autocorrelation to find periodic peaks
//   3. Candidate tempos scored by cross-correlation with ideal pulse trains
//   4. Decaying histogram for tempo stability with perceptual 120 BPM weighting
//   5. Beat phase prediction with onset re-sync

@MainActor
final class BeatDetector {
    
    struct Result {
        var bpm: Float      // detected BPM (0 if not confident)
        var phase: Float    // 0..1, current position in beat cycle
        var pulse: Float    // 0..1, spikes on predicted beat
    }
    
    // --- Configuration ---
    private let ossLength = 512          // onset signal ring buffer (~12s at 43 fps)
    private let minBPM: Float = 60
    private let maxBPM: Float = 200
    private let numCandidates = 10       // top autocorrelation peaks to evaluate
    private let histogramBins = 300      // BPM histogram: 0.5 BPM resolution over 0-150 range mapped to 60-210
    private let histogramDecay: Float = 0.995  // moderate decay for stability
    private let minOSSForEstimation = 215 // ~5s at 43fps — require 5s of data before any tempo estimation
    private let stabilityDuration: Double = 3.0 // BPM must be stable for 3s before being reported
    
    // --- Onset Signal (ring buffer) ---
    private var oss: [Float]             // spectral flux onset strength signal
    private var ossWriteIndex = 0
    private var ossCount = 0             // how many samples written so far
    
    // Adaptive threshold for onset picking
    private var ossMean: Float = 0
    private var ossVariance: Float = 0
    
    // --- Tempo Histogram ---
    private var histogram: [Float]       // decaying BPM histogram
    
    // --- Output State ---
    private var currentBPM: Float = 0        // internal candidate (not yet confirmed)
    private var confirmedBPM: Float = 0      // output BPM (only after 10s stability)
    private var beatInterval: Double = 0
    private var lastBeatTime: Double = 0
    private var confidence: Float = 0
    
    // --- BPM Stability tracking ---
    private var candidateBPM: Float = 0      // current best candidate from histogram
    private var candidateStartTime: Double = 0  // when this candidate first appeared
    private var candidateStable = false      // has the candidate been stable for 10s?
    
    // --- Pulse prediction ---
    private var pulseDecay: Float = 0
    private var lastPulseFiredTime: Double = 0
    
    // --- Energy gate: ignore quiet input to prevent false BPM ---
    private var smoothEnergy: Float = 0
    private let energyGate: Float = 0.08   // minimum percussive energy (raised to reject mic noise floor)
    private var quietFrameCount: Int = 0   // consecutive frames below energy gate
    
    // --- ZCR stability tracking (music vs noise/speech discrimination) ---
    // Music has stable ZCR; speech/noise have erratic ZCR
    private var zcrMean: Float = 0
    private var zcrVariance: Float = 0
    private var zcrStability: Float = 0    // 0=noisy/speech, 1=stable/music
    
    // --- OSS sample rate (audio buffer callbacks per second) ---
    private var ossSampleRate: Float = 43  // ~44100/1024, refined at runtime
    private var lastTimestamp: Double = 0
    private var timestampCount = 0
    
    init() {
        oss = [Float](repeating: 0, count: ossLength)
        histogram = [Float](repeating: 0, count: histogramBins)
    }
    
    /// Feed band-specific flux for rhythm detection.
    /// Multi-band weighted onset: bass (kick) + mid (snare) + high (hi-hat).
    /// ZCR (zero crossing rate) is used to discriminate music from speech/noise.
    func feed(bassFlux: Float, midFlux: Float, highFlux: Float, bassEnergy: Float, highEnergy: Float, zcr: Float, timestamp: Double) -> Result {
        // --- ZCR stability: music has consistent ZCR, speech/noise fluctuates ---
        let zcrAlpha: Float = 0.02
        zcrMean = zcrMean * (1 - zcrAlpha) + zcr * zcrAlpha
        let zcrDiff = zcr - zcrMean
        zcrVariance = zcrVariance * (1 - zcrAlpha) + zcrDiff * zcrDiff * zcrAlpha
        // Low variance = stable = likely music. Map variance to 0..1 stability score.
        // Typical music ZCR variance: 0.0001-0.001, speech/noise: 0.002-0.01+
        let rawStability = 1.0 - min(sqrt(zcrVariance) / 0.05, 1.0)
        zcrStability = zcrStability * 0.95 + rawStability * 0.05  // smooth
        
        // Refine OSS sample rate from actual timestamps
        if lastTimestamp > 0 {
            let dt = timestamp - lastTimestamp
            if dt > 0.001 && dt < 0.5 {
                let instantRate = Float(1.0 / dt)
                ossSampleRate = ossSampleRate * 0.99 + instantRate * 0.01
            }
        }
        lastTimestamp = timestamp
        timestampCount += 1
        
        // --- Energy gate: ignore very quiet input (multi-band) ---
        let totalPercussiveEnergy = bassEnergy + highEnergy * 0.3
        // Fast rise, faster fall — detects silence quickly
        if totalPercussiveEnergy > smoothEnergy {
            smoothEnergy = smoothEnergy * 0.9 + totalPercussiveEnergy * 0.1  // fast rise
        } else {
            smoothEnergy = smoothEnergy * 0.92 + totalPercussiveEnergy * 0.08  // fast fall
        }
        let isLoud = smoothEnergy > energyGate
        
        // --- Compose onset signal: multi-band weighted ---
        // Bass (kick) dominant, mid (snare) and high (hi-hat) for broader genre support
        let onsetValue = isLoud ? (bassFlux * 1.2 + midFlux * 0.5 + highFlux * 0.3) : 0
        
        // Write to ring buffer
        oss[ossWriteIndex] = onsetValue
        ossWriteIndex = (ossWriteIndex + 1) % ossLength
        ossCount = min(ossCount + 1, ossLength)
        
        // --- Adaptive onset threshold (running mean + std dev) ---
        let alpha: Float = 0.01
        ossMean = ossMean * (1 - alpha) + onsetValue * alpha
        let diff = onsetValue - ossMean
        ossVariance = ossVariance * (1 - alpha) + diff * diff * alpha
        let ossStd = sqrt(ossVariance)
        // Stricter threshold: 1.5x std dev above mean (was 1.0)
        let onsetThreshold = ossMean + ossStd * 1.5
        let isOnset = isLoud && onsetValue > onsetThreshold && onsetValue > 0.005
        
        // --- Tempo estimation via autocorrelation (every 4th frame for efficiency) ---
        // Require ~10s of onset data before attempting any tempo estimation
        if ossCount >= minOSSForEstimation && timestampCount % 4 == 0 {
            estimateTempoAutocorrelation(timestamp: timestamp)
        }
        
        // --- When quiet, kill BPM quickly ---
        if !isLoud {
            quietFrameCount += 1
            confidence *= 0.85  // aggressive decay when silent
            // Rapid histogram decay
            var fastDecay: Float = 0.93
            vDSP_vsmul(histogram, 1, &fastDecay, &histogram, 1, vDSP_Length(histogramBins))
            
            // After ~1 second of silence (~43 frames), force clear everything
            if quietFrameCount > 40 || confidence < 0.15 {
                currentBPM = 0
                confirmedBPM = 0
                candidateBPM = 0
                candidateStable = false
                beatInterval = 0
                confidence = 0
                histogram = [Float](repeating: 0, count: histogramBins)
                ossCount = 0  // reset onset buffer so stale data doesn't re-trigger
                ossMean = 0
                ossVariance = 0
                zcrMean = 0
                zcrVariance = 0
                zcrStability = 0
            }
        } else {
            quietFrameCount = 0
        }
        
        // --- Beat prediction and pulse generation ---
        pulseDecay *= 0.82
        
        // Only fire beats using CONFIRMED BPM (stable for 10s+)
        if confirmedBPM > 0 && beatInterval > 0 && confidence > 0.35 {
            let timeSinceLastBeat = timestamp - lastBeatTime
            let phase = Float(fmod(timeSinceLastBeat, beatInterval) / beatInterval)
            
            // Fire pulse near predicted beat
            let minPulseGap = beatInterval * 0.6
            let timeSinceLastPulse = timestamp - lastPulseFiredTime
            
            let beatWindow: Float = 0.10
            if (phase < beatWindow || phase > (1.0 - beatWindow)) && timeSinceLastPulse > minPulseGap {
                if pulseDecay < 0.4 {
                    pulseDecay = 1.0
                    lastPulseFiredTime = timestamp
                }
            }
            
            // Re-sync on actual onset
            if isOnset {
                // Snap lastBeatTime to nearest grid position near this onset
                if beatInterval > 0 {
                    let elapsed = timestamp - lastBeatTime
                    let beats = round(elapsed / beatInterval)
                    if beats > 0 {
                        lastBeatTime = lastBeatTime + beats * beatInterval
                    }
                } else {
                    lastBeatTime = timestamp
                }
                if pulseDecay < 0.6 {
                    pulseDecay = 1.0
                    lastPulseFiredTime = timestamp
                }
            }
            
            return Result(bpm: confirmedBPM, phase: phase, pulse: pulseDecay)
        } else if isOnset {
            pulseDecay = 1.0
            lastPulseFiredTime = timestamp
            lastBeatTime = timestamp
        }
        
        return Result(bpm: confirmedBPM, phase: 0, pulse: pulseDecay)
    }
    
    // MARK: - Autocorrelation-Based Tempo Estimation
    
    private func estimateTempoAutocorrelation(timestamp: Double) {
        // Extract linear OSS from ring buffer
        let len = min(ossCount, ossLength)
        var linear = [Float](repeating: 0, count: len)
        for i in 0..<len {
            let idx = (ossWriteIndex - len + i + ossLength) % ossLength
            linear[i] = oss[idx]
        }
        
        // Lag range: convert BPM range to OSS sample lags
        // lag = ossSampleRate * 60 / bpm
        let maxLag = min(Int(ossSampleRate * 60.0 / minBPM), len - 1)  // slowest tempo
        let minLag = max(Int(ossSampleRate * 60.0 / maxBPM), 1)        // fastest tempo
        guard maxLag > minLag else { return }
        
        // --- Generalized autocorrelation: GAC(lag) = sum(oss[i]^0.5 * oss[i+lag]^0.5) ---
        // Using exponent 0.5 (compressed autocorrelation) for better peak definition
        var compressed = [Float](repeating: 0, count: len)
        for i in 0..<len {
            compressed[i] = sqrt(max(linear[i], 0))
        }
        
        // Compute autocorrelation for each lag in range
        var acf = [Float](repeating: 0, count: maxLag + 1)
        compressed.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for lag in minLag...maxLag {
                var sum: Float = 0
                let count = len - lag
                if count > 0 {
                    vDSP_dotpr(base, 1,
                              base + lag, 1,
                              &sum,
                              vDSP_Length(count))
                    acf[lag] = sum / Float(count)
                }
            }
        }
        
        // --- Find top candidate peaks in ACF ---
        var candidates: [(lag: Int, strength: Float)] = []
        for lag in (minLag + 1)..<maxLag {
            if acf[lag] > acf[lag - 1] && acf[lag] > acf[lag + 1] && acf[lag] > 0 {
                candidates.append((lag: lag, strength: acf[lag]))
            }
        }
        candidates.sort { $0.strength > $1.strength }
        candidates = Array(candidates.prefix(numCandidates))
        
        guard !candidates.isEmpty else { return }
        
        // --- ACF peak quality check ---
        // Music produces sharp, prominent ACF peaks; noise/speech produce flat, diffuse ACF.
        // Require the top peak to be significantly stronger than the median.
        if candidates.count >= 2 {
            let topStrength = candidates[0].strength
            let secondStrength = candidates[1].strength
            // If top peak isn't at least 20% stronger than second, signal is not periodic enough
            if topStrength < secondStrength * 1.2 {
                confidence *= 0.95  // gentle suppression for ambiguous autocorrelation
            }
        }
        
        // --- Score each candidate via pulse train cross-correlation ---
        var bestScore: Float = -1
        var bestLag: Int = 0
        
        for candidate in candidates {
            let lag = candidate.lag
            let score = scorePulseTrain(oss: compressed, lag: lag, len: len)
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        
        guard bestLag > 0 else { return }
        
        let estimatedBPM = ossSampleRate * 60.0 / Float(bestLag)
        
        // Resolve octave ambiguity: check half and double tempo
        let resolvedBPM = resolveOctave(estimatedBPM, oss: compressed, len: len)
        
        // --- Update decaying histogram ---
        // Decay existing histogram
        var decay = histogramDecay
        vDSP_vsmul(histogram, 1, &decay, &histogram, 1, vDSP_Length(histogramBins))
        
        // Add Gaussian spike at estimated BPM
        let binCenter = bpmToBin(resolvedBPM)
        let sigma: Float = 2.0  // ~1 BPM width
        for b in max(0, binCenter - 8)...min(histogramBins - 1, binCenter + 8) {
            let d = Float(b - binCenter)
            let gaussian = bestScore * exp(-d * d / (2 * sigma * sigma))
            histogram[b] += gaussian
        }
        
        // Apply perceptual weighting (preference toward ~120 BPM)
        // log-Gaussian: mean=120, sigma=40
        var weightedHist = [Float](repeating: 0, count: histogramBins)
        for b in 0..<histogramBins {
            let bpm = binToBPM(b)
            let logRatio = log2(bpm / 120.0)
            let weight = exp(-logRatio * logRatio / (2 * 0.4 * 0.4))  // log-Gaussian
            weightedHist[b] = histogram[b] * weight
        }
        
        // Find histogram peak
        var maxVal: Float = 0
        var maxIdx: vDSP_Length = 0
        vDSP_maxvi(weightedHist, 1, &maxVal, &maxIdx, vDSP_Length(histogramBins))
        
        guard maxVal > 0.05 else {
            confidence *= 0.92
            if confidence < 0.15 { currentBPM = 0; beatInterval = 0 }
            return
        }
        
        // Parabolic interpolation around peak for sub-bin accuracy
        let peakBin = Int(maxIdx)
        var refinedBPM = binToBPM(peakBin)
        if peakBin > 0 && peakBin < histogramBins - 1 {
            let y0 = weightedHist[peakBin - 1]
            let y1 = weightedHist[peakBin]
            let y2 = weightedHist[peakBin + 1]
            let denom = y0 - 2 * y1 + y2
            if abs(denom) > 0.0001 {
                let offset = 0.5 * (y0 - y2) / denom
                refinedBPM = binToBPM(peakBin + Int(round(offset)))
            }
        }
        
        // Update internal candidate
        let newBPM = round(refinedBPM)
        currentBPM = newBPM
        
        // Confidence: histogram peak prominence × ZCR stability
        // ZCR stability acts as a multiplier: music (stable ZCR) boosts confidence,
        // speech/noise (erratic ZCR) suppresses it
        let histSum = histogram.reduce(0, +)
        if histSum > 0 {
            let histConfidence = min(maxVal / histSum * Float(histogramBins) * 0.3, 1.0)
            // Blend: 70% histogram prominence + 30% ZCR stability
            let zcrWeight: Float = 0.3
            confidence = histConfidence * (1.0 - zcrWeight + zcrStability * zcrWeight)
        }
        
        // --- 10-second stability gate ---
        // Track if the same BPM (within ±5 BPM) has been the winner consistently
        if abs(newBPM - candidateBPM) <= 5 && confidence > 0.3 {
            // Same candidate — check if 10s has passed
            let elapsed = timestamp - candidateStartTime
            if elapsed >= stabilityDuration && !candidateStable {
                // BPM confirmed! Promote to output
                candidateStable = true
                confirmedBPM = newBPM
                beatInterval = Double(60.0 / confirmedBPM)
                lastBeatTime = timestamp
            } else if candidateStable {
                // Already confirmed — update with refined value
                let prevConfirmed = confirmedBPM
                confirmedBPM = newBPM
                beatInterval = Double(60.0 / confirmedBPM)
                // If BPM changed significantly, re-sync beat grid
                if abs(confirmedBPM - prevConfirmed) > 5 {
                    lastBeatTime = timestamp
                }
            }
        } else {
            // Different candidate or low confidence — reset stability timer
            candidateBPM = newBPM
            candidateStartTime = timestamp
            candidateStable = false
            // Don't immediately clear confirmed BPM — let it decay naturally
        }
    }
    
    // MARK: - Pulse Train Cross-Correlation
    
    /// Score a candidate tempo lag by correlating OSS with an ideal pulse train
    private func scorePulseTrain(oss: [Float], lag: Int, len: Int) -> Float {
        guard lag > 0 else { return 0 }
        var score: Float = 0
        var count: Float = 0
        // Walk backward through OSS at intervals of `lag`, sum the OSS values at pulse positions
        var pos = len - 1
        while pos >= 0 {
            score += oss[pos]
            count += 1
            pos -= lag
        }
        return count > 0 ? score / count : 0
    }
    
    // MARK: - Octave Ambiguity Resolution
    
    /// Check if half-tempo or double-tempo scores better, resolving 60↔120↔240 confusion
    private func resolveOctave(_ bpm: Float, oss: [Float], len: Int) -> Float {
        let lag = Int(ossSampleRate * 60.0 / bpm)
        let baseScore = scorePulseTrain(oss: oss, lag: lag, len: len)
        
        // Check double tempo (half the lag)
        let doubleBPM = bpm * 2
        if doubleBPM <= maxBPM {
            let doubleLag = lag / 2
            if doubleLag > 0 {
                let doubleScore = scorePulseTrain(oss: oss, lag: doubleLag, len: len)
                // Prefer double tempo if it scores similarly (perceptual preference)
                if doubleScore > baseScore * 0.85 && doubleBPM >= 90 && doubleBPM <= 180 {
                    return doubleBPM
                }
            }
        }
        
        // Check half tempo (double the lag)
        let halfBPM = bpm / 2
        if halfBPM >= minBPM {
            let halfLag = lag * 2
            if halfLag < len {
                let halfScore = scorePulseTrain(oss: oss, lag: halfLag, len: len)
                // Prefer half tempo only if it scores significantly better
                if halfScore > baseScore * 1.3 && halfBPM >= 90 && halfBPM <= 160 {
                    return halfBPM
                }
            }
        }
        
        return bpm
    }
    
    // MARK: - Histogram Helpers
    
    /// BPM to histogram bin index (linear mapping: 60-210 BPM → 0..histogramBins)
    private func bpmToBin(_ bpm: Float) -> Int {
        let normalized = (bpm - 60) / 150.0  // 0..1 for 60-210
        return max(0, min(histogramBins - 1, Int(normalized * Float(histogramBins))))
    }
    
    /// Histogram bin index to BPM
    private func binToBPM(_ bin: Int) -> Float {
        return 60.0 + Float(bin) / Float(histogramBins) * 150.0
    }
}

// MARK: - FFT Processor with Spectral Flux (nonisolated, called from audio thread)

nonisolated final class FFTProcessor: @unchecked Sendable {
    
    struct AnalysisResult: Sendable {
        var bass: Float
        var mid: Float
        var high: Float
        var spectralFlux: Float      // full-band half-wave rectified spectral difference
        var bassFlux: Float          // spectral flux in bass band only (0–120 Hz)
        var midFlux: Float           // spectral flux in mid band (120–2000 Hz)
        var highFlux: Float          // spectral flux in high band only (2000+ Hz)
        var zcr: Float               // zero crossing rate (0..1, normalized)
    }
    
    private let bufferSize: Int
    private let halfN: Int
    private var fftSetup: vDSP_DFT_Setup?
    private var inputReal: [Float]
    private var inputImag: [Float]
    private var outputReal: [Float]
    private var outputImag: [Float]
    private var window: [Float]
    private var prevMagnitudes: [Float]  // previous frame for spectral flux
    private var magnitudes: [Float]
    
    init(bufferSize: Int) {
        self.bufferSize = bufferSize
        self.halfN = bufferSize / 2
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(bufferSize), .FORWARD)
        inputReal = [Float](repeating: 0, count: bufferSize)
        inputImag = [Float](repeating: 0, count: bufferSize)
        outputReal = [Float](repeating: 0, count: bufferSize)
        outputImag = [Float](repeating: 0, count: bufferSize)
        prevMagnitudes = [Float](repeating: 0, count: bufferSize / 2)
        magnitudes = [Float](repeating: 0, count: bufferSize / 2)
        window = [Float](repeating: 0, count: bufferSize)
        vDSP_hann_window(&window, vDSP_Length(bufferSize), Int32(vDSP_HANN_NORM))
    }
    
    deinit {
        if let setup = fftSetup {
            vDSP_DFT_DestroySetup(setup)
        }
    }
    
    func process(buffer: AVAudioPCMBuffer, sensitivity: Float) -> AnalysisResult {
        guard let fftSetup = fftSetup,
              let channelData = buffer.floatChannelData?[0] else {
            return AnalysisResult(bass: 0, mid: 0, high: 0, spectralFlux: 0, bassFlux: 0, midFlux: 0, highFlux: 0, zcr: 0)
        }
        
        let n = bufferSize
        
        // --- Zero Crossing Rate (time domain, before windowing) ---
        var zeroCrossings: Float = 0
        for i in 1..<n {
            if (channelData[i] >= 0) != (channelData[i - 1] >= 0) {
                zeroCrossings += 1
            }
        }
        let zcr = zeroCrossings / Float(n)  // normalized: 0..1
        
        // Copy and window input
        memcpy(&inputReal, channelData, n * MemoryLayout<Float>.size)
        memset(&inputImag, 0, n * MemoryLayout<Float>.size)
        vDSP_vmul(inputReal, 1, window, 1, &inputReal, 1, vDSP_Length(n))
        
        // FFT
        vDSP_DFT_Execute(fftSetup, inputReal, inputImag, &outputReal, &outputImag)
        
        // Compute magnitudes using vDSP
        // magnitudes[i] = sqrt(real[i]^2 + imag[i]^2)
        var realSq = [Float](repeating: 0, count: halfN)
        var imagSq = [Float](repeating: 0, count: halfN)
        vDSP_vsq(outputReal, 1, &realSq, 1, vDSP_Length(halfN))
        vDSP_vsq(outputImag, 1, &imagSq, 1, vDSP_Length(halfN))
        vDSP_vadd(realSq, 1, imagSq, 1, &magnitudes, 1, vDSP_Length(halfN))
        var sqrtCount = Int32(halfN)
        vvsqrtf(&magnitudes, magnitudes, &sqrtCount)
        
        // --- Frequency band boundaries ---
        // Bass: 0–120 Hz (kick drums, sub-bass)
        // Mid: 120–2000 Hz (snare, vocals, melodic bass)
        // High: 2000–22050 Hz (hi-hats, cymbals, sibilance)
        let sampleRate: Float = 44100.0
        let freqRes = sampleRate / Float(n)
        let bassEnd = min(Int(120.0 / freqRes), halfN)
        let midEnd = min(Int(2000.0 / freqRes), halfN)
        
        // --- Log-compressed magnitudes for spectral flux (Percival & Tzanetakis) ---
        // log(1 + γ * mag) enhances soft onsets (ghost notes, quiet snares)
        // γ = 100 is standard in librosa/Essentia
        var logMag = [Float](repeating: 0, count: halfN)
        var gamma: Float = 100.0
        vDSP_vsmul(magnitudes, 1, &gamma, &logMag, 1, vDSP_Length(halfN))
        var one: Float = 1.0
        vDSP_vsadd(logMag, 1, &one, &logMag, 1, vDSP_Length(halfN))
        var logCount = Int32(halfN)
        vvlogf(&logMag, logMag, &logCount)
        
        // --- Spectral Flux (half-wave rectified, on log-compressed magnitudes) ---
        var diff = [Float](repeating: 0, count: halfN)
        vDSP_vsub(prevMagnitudes, 1, logMag, 1, &diff, 1, vDSP_Length(halfN))
        // Half-wave rectify: keep only positive differences (energy increases)
        var zero: Float = 0
        vDSP_vthres(diff, 1, &zero, &diff, 1, vDSP_Length(halfN))
        
        // Full-band flux
        var flux: Float = 0
        vDSP_sve(diff, 1, &flux, vDSP_Length(halfN))
        flux /= Float(halfN)
        
        // Bass-band flux (0–120 Hz) — kick detection
        var bassFlux: Float = 0
        if bassEnd > 0 {
            vDSP_sve(diff, 1, &bassFlux, vDSP_Length(bassEnd))
            bassFlux /= Float(bassEnd)
        }
        
        // Mid-band flux (120–2000 Hz) — snare/melodic detection
        var midFlux: Float = 0
        if midEnd > bassEnd {
            diff.withUnsafeBufferPointer { buf in
                vDSP_sve(buf.baseAddress! + bassEnd, 1, &midFlux, vDSP_Length(midEnd - bassEnd))
            }
            midFlux /= Float(midEnd - bassEnd)
        }
        
        // High-band flux (2000+ Hz) — hi-hat detection
        var highFlux: Float = 0
        if halfN > midEnd {
            diff.withUnsafeBufferPointer { buf in
                vDSP_sve(buf.baseAddress! + midEnd, 1, &highFlux, vDSP_Length(halfN - midEnd))
            }
            highFlux /= Float(halfN - midEnd)
        }
        
        // Store log-compressed magnitudes for next frame's flux calculation
        memcpy(&prevMagnitudes, logMag, halfN * MemoryLayout<Float>.size)
        
        var bass: Float = 0, mid: Float = 0, high: Float = 0
        
        if bassEnd > 0 {
            vDSP_meanv(magnitudes, 1, &bass, vDSP_Length(bassEnd))
        }
        if midEnd > bassEnd {
            magnitudes.withUnsafeBufferPointer { buf in
                vDSP_meanv(buf.baseAddress! + bassEnd, 1, &mid, vDSP_Length(midEnd - bassEnd))
            }
        }
        if halfN > midEnd {
            magnitudes.withUnsafeBufferPointer { buf in
                vDSP_meanv(buf.baseAddress! + midEnd, 1, &high, vDSP_Length(halfN - midEnd))
            }
        }
        
        let scale = sensitivity * 0.01
        return AnalysisResult(
            bass: min(bass * scale * 5.0, 3.0),
            mid: min(mid * scale * 5.0, 3.0),
            high: min(high * scale * 10.0, 3.0),
            spectralFlux: flux * scale,
            bassFlux: bassFlux * scale * 3.0,
            midFlux: midFlux * scale * 4.0,
            highFlux: highFlux * scale * 5.0,
            zcr: zcr
        )
    }
}
