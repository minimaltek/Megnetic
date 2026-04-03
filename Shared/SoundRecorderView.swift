//
//  SoundRecorderView.swift
//  Magnetic
//
//  Recording + waveform trimming UI for custom WALL HIT sounds
//

import SwiftUI
import AVFoundation
import Combine

// MARK: - Theme (matching SettingsView)

private enum RecTheme {
    static let bg = Color(white: 0.06)
    static let surface = Color(white: 0.10)
    static let surfaceHi = Color(white: 0.14)
    static let label = Color(white: 0.50)
    static let text = Color(white: 0.88)
    static let accent = Color(white: 1.0)
    static let dimmed = Color(white: 0.30)
    static let recRed = Color(red: 0.9, green: 0.15, blue: 0.15)
}

// MARK: - SoundRecorder (audio capture engine)

class SoundRecorder: ObservableObject {
    private var engine: AVAudioEngine?
    private var collectedBuffers: [AVAudioPCMBuffer] = []
    private var recordFormat: AVAudioFormat?
    
    @Published var isRecording = false
    @Published var recordedBuffer: AVAudioPCMBuffer?
    @Published var liveLevels: [Float] = []   // real-time amplitude bars
    @Published var recordingDuration: Double = 0
    
    private var recordStartTime: Date?
    private let maxDuration: Double = 5.0
    private var stopTimer: Timer?
    
    func startRecording() {
        // Reset
        collectedBuffers = []
        recordedBuffer = nil
        liveLevels = []
        recordingDuration = 0
        
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.defaultToSpeaker, .mixWithOthers, .allowBluetoothA2DP])
        try? session.setActive(true)
        #endif
        
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        self.recordFormat = format
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.collectedBuffers.append(buffer)
            
            // Compute peak level for live display
            if let channelData = buffer.floatChannelData {
                let frameCount = Int(buffer.frameLength)
                var peak: Float = 0
                for i in 0..<frameCount {
                    let amp = abs(channelData[0][i])
                    if amp > peak { peak = amp }
                }
                DispatchQueue.main.async {
                    self.liveLevels.append(peak)
                    // Keep last ~200 bars for display
                    if self.liveLevels.count > 200 {
                        self.liveLevels.removeFirst(self.liveLevels.count - 200)
                    }
                    self.recordingDuration = Date().timeIntervalSince(self.recordStartTime ?? Date())
                }
            }
        }
        
        do {
            try engine.start()
            self.engine = engine
            recordStartTime = Date()
            isRecording = true
            
            // Auto-stop after maxDuration
            stopTimer = Timer.scheduledTimer(withTimeInterval: maxDuration, repeats: false) { [weak self] _ in
                self?.stopRecording()
            }
        } catch {
            print("SoundRecorder: failed to start engine: \(error)")
        }
    }
    
    func stopRecording() {
        stopTimer?.invalidate()
        stopTimer = nil
        
        guard isRecording else { return }
        
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRecording = false
        
        // Merge collected buffers into one
        recordedBuffer = mergeBuffers()
        recordingDuration = Double(recordedBuffer?.frameLength ?? 0) / (recordFormat?.sampleRate ?? 44100)
    }
    
    private func mergeBuffers() -> AVAudioPCMBuffer? {
        guard let format = recordFormat, !collectedBuffers.isEmpty else { return nil }
        
        let totalFrames = collectedBuffers.reduce(0) { $0 + Int($1.frameLength) }
        guard totalFrames > 0,
              let merged = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)) else { return nil }
        
        merged.frameLength = AVAudioFrameCount(totalFrames)
        
        let channels = Int(format.channelCount)
        guard let dstData = merged.floatChannelData else { return nil }
        
        var offset = 0
        for buf in collectedBuffers {
            guard let srcData = buf.floatChannelData else { continue }
            let count = Int(buf.frameLength)
            for ch in 0..<channels {
                dstData[ch].advanced(by: offset).update(from: srcData[ch], count: count)
            }
            offset += count
        }
        
        return merged
    }
    
    /// Preview playback of a trimmed segment
    func playPreview(buffer: AVAudioPCMBuffer) {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
        try? session.setActive(true)
        #endif
        
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        try? engine.start()
        player.play()
        player.scheduleBuffer(buffer, at: nil, options: []) { [weak engine] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                engine?.stop()
            }
        }
        // Keep engine alive temporarily
        self.engine = engine
    }
}

// MARK: - SoundRecorderView

struct SoundRecorderView: View {
    let slot: Int
    let onSaved: () -> Void
    let onCancel: () -> Void
    
    @StateObject private var recorder = SoundRecorder()
    
    // Trim state
    @State private var trimStart: Double = 0       // 0..1 fraction of buffer
    @State private var trimEnd: Double = 1         // 0..1 fraction of buffer
    @State private var phase: RecordPhase = .ready
    
    private enum RecordPhase {
        case ready      // initial - show record button
        case recording  // capturing audio
        case trimming   // waveform editor
    }
    
    private let maxTrimDuration: Double = 1.5
    
    var body: some View {
        ZStack {
            RecTheme.bg.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Button {
                        recorder.stopRecording()
                        onCancel()
                    } label: {
                        Text("CANCEL")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(RecTheme.dimmed)
                            .tracking(1)
                    }
                    
                    Spacer()
                    
                    Text("REC \(slot + 1)")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(RecTheme.text)
                        .tracking(2)
                    
                    Spacer()
                    
                    // Invisible balance
                    Text("CANCEL")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.clear)
                        .tracking(1)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                
                Spacer()
                
                switch phase {
                case .ready:
                    readyPhase
                case .recording:
                    recordingPhase
                case .trimming:
                    trimmingPhase
                }
                
                Spacer()
            }
        }
        .onChange(of: recorder.isRecording) { newValue in
            if !newValue && phase == .recording {
                // Recording stopped — transition to trimming
                if recorder.recordedBuffer != nil {
                    initializeTrimRange()
                    phase = .trimming
                } else {
                    phase = .ready
                }
            }
        }
    }
    
    // MARK: - Ready Phase
    
    private var readyPhase: some View {
        VStack(spacing: 24) {
            Text("TAP TO RECORD")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(RecTheme.label)
                .tracking(2)
            
            Button {
                phase = .recording
                recorder.startRecording()
            } label: {
                Circle()
                    .fill(RecTheme.recRed)
                    .frame(width: 80, height: 80)
                    .overlay {
                        Circle()
                            .stroke(RecTheme.text, lineWidth: 3)
                    }
                    .overlay {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white)
                    }
            }
            
            Text("MAX 5 SEC")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(RecTheme.dimmed)
                .tracking(1)
        }
    }
    
    // MARK: - Recording Phase
    
    private var recordingPhase: some View {
        VStack(spacing: 20) {
            // Timer
            Text(String(format: "%.1fs", recorder.recordingDuration))
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(RecTheme.recRed)
            
            // Live waveform
            liveWaveformView
                .frame(height: 80)
                .padding(.horizontal, 20)
            
            // Stop button
            Button {
                recorder.stopRecording()
            } label: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(RecTheme.recRed)
                    .frame(width: 60, height: 60)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.white)
                            .frame(width: 24, height: 24)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(RecTheme.text, lineWidth: 3)
                    }
            }
            
            Text("TAP TO STOP")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(RecTheme.dimmed)
                .tracking(1)
        }
    }
    
    private var liveWaveformView: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 1) {
                ForEach(Array(recorder.liveLevels.suffix(Int(geo.size.width / 3)).enumerated()), id: \.offset) { _, level in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(RecTheme.recRed)
                        .frame(width: 2, height: max(2, CGFloat(level) * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .background(RecTheme.surface.cornerRadius(8))
    }
    
    // MARK: - Trimming Phase
    
    private var trimmingPhase: some View {
        VStack(spacing: 16) {
            // Duration info
            let totalDuration = recorder.recordingDuration
            let trimDuration = (trimEnd - trimStart) * totalDuration
            
            HStack {
                Text(String(format: "%.2fs", trimDuration))
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(RecTheme.text)
                
                Text("/ \(String(format: "%.1fs", totalDuration))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(RecTheme.dimmed)
            }
            
            // Waveform with trim handles
            trimWaveformView
                .frame(height: 120)
                .padding(.horizontal, 20)
            
            // Buttons
            HStack(spacing: 20) {
                // Play preview
                Button {
                    playTrimmedPreview()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12))
                        Text("PLAY")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .tracking(1)
                    }
                    .foregroundStyle(RecTheme.bg)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(RecTheme.text, in: Capsule())
                }
                
                // Save
                Button {
                    saveAndDismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                        Text("SAVE")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .tracking(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.green.opacity(0.8), in: Capsule())
                }
            }
            
            // Re-record
            Button {
                phase = .ready
            } label: {
                Text("RE-RECORD")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(RecTheme.dimmed)
                    .tracking(1)
            }
        }
    }
    
    private var trimWaveformView: some View {
        let trimColor = Color(red: 0.2, green: 0.7, blue: 1.0)
        let handleW: CGFloat = 12
        
        return GeometryReader { geo in
            let waveformData = waveformSamples(width: geo.size.width)
            let barCount = waveformData.count
            let barWidth: CGFloat = 2
            let barSpacing: CGFloat = 1
            let startX = CGFloat(trimStart) * geo.size.width
            let endX = CGFloat(trimEnd) * geo.size.width
            let h = geo.size.height
            
            ZStack(alignment: .topLeading) {
                // Full waveform — all bars in cyan
                HStack(alignment: .center, spacing: barSpacing) {
                    ForEach(0..<barCount, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(trimColor)
                            .frame(width: barWidth, height: max(2, CGFloat(waveformData[i]) * h * 0.85))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                
                // Dark overlay on LEFT excluded region (up to handle edge)
                if startX > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.7))
                        .frame(width: startX, height: h)
                        .allowsHitTesting(false)
                }
                
                // Dark overlay on RIGHT excluded region (from handle edge)
                if endX < geo.size.width {
                    Rectangle()
                        .fill(Color.black.opacity(0.7))
                        .frame(width: geo.size.width - endX, height: h)
                        .offset(x: endX)
                        .allowsHitTesting(false)
                }
                
                // Left handle bar (inside trim region)
                RoundedRectangle(cornerRadius: 3)
                    .fill(trimColor)
                    .frame(width: handleW, height: h)
                    .offset(x: startX)
                    .overlay(alignment: .leading) {
                        // Grip lines
                        VStack(spacing: 3) {
                            ForEach(0..<3, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 0.5)
                                    .fill(RecTheme.bg)
                                    .frame(width: 6, height: 1.5)
                            }
                        }
                        .offset(x: startX + 3)
                    }
                    .allowsHitTesting(false)
                
                // Right handle bar (inside trim region)
                RoundedRectangle(cornerRadius: 3)
                    .fill(trimColor)
                    .frame(width: handleW, height: h)
                    .offset(x: endX - handleW)
                    .overlay(alignment: .leading) {
                        VStack(spacing: 3) {
                            ForEach(0..<3, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 0.5)
                                    .fill(RecTheme.bg)
                                    .frame(width: 6, height: 1.5)
                            }
                        }
                        .offset(x: endX - handleW + 3)
                    }
                    .allowsHitTesting(false)
                
                // Top/bottom border connecting the two handles
                Rectangle()
                    .fill(trimColor)
                    .frame(width: max(0, endX - startX), height: 2)
                    .offset(x: startX)
                    .allowsHitTesting(false)
                
                Rectangle()
                    .fill(trimColor)
                    .frame(width: max(0, endX - startX), height: 2)
                    .offset(x: startX, y: h - 2)
                    .allowsHitTesting(false)
                
                // Time labels inside the waveform area (top corners)
                let totalDuration = recorder.recordingDuration
                let startSec = trimStart * totalDuration
                let endSec = trimEnd * totalDuration
                
                Text(String(format: "%04.2f", startSec))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(RecTheme.bg)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(trimColor.opacity(0.9), in: RoundedRectangle(cornerRadius: 2))
                    .offset(x: startX + handleW + 2, y: 4)
                    .allowsHitTesting(false)
                
                Text(String(format: "%04.2f", endSec))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(RecTheme.bg)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(trimColor.opacity(0.9), in: RoundedRectangle(cornerRadius: 2))
                    .offset(x: endX - handleW - 38, y: 4)
                    .allowsHitTesting(false)
                
                // Left handle hit area
                Color.clear
                    .frame(width: 44, height: h)
                    .contentShape(Rectangle())
                    .offset(x: startX - 16)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                handleStartDrag(fraction: Double(value.location.x / geo.size.width))
                            }
                    )
                
                // Right handle hit area
                Color.clear
                    .frame(width: 44, height: h)
                    .contentShape(Rectangle())
                    .offset(x: endX - 28)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                handleEndDrag(fraction: Double(value.location.x / geo.size.width))
                            }
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .background(RecTheme.surface.cornerRadius(8))
        }
    }
    
    // MARK: - Helpers
    
    private func waveformSamples(width: CGFloat) -> [Float] {
        guard let buffer = recorder.recordedBuffer else { return [] }
        let barWidth: CGFloat = 2
        let barSpacing: CGFloat = 1
        let count = max(1, Int(width / (barWidth + barSpacing)))
        return CustomSoundManager.waveformSamples(from: buffer, count: count)
    }
    
    private func initializeTrimRange() {
        let totalDuration = recorder.recordingDuration
        guard totalDuration > 0 else { return }
        
        trimStart = 0
        if totalDuration > maxTrimDuration {
            trimEnd = maxTrimDuration / totalDuration
        } else {
            trimEnd = 1.0
        }
    }
    
    /// Drag the START handle: move start, push end if range > maxTrimDuration
    private func handleStartDrag(fraction: Double) {
        let totalDuration = recorder.recordingDuration
        guard totalDuration > 0 else { return }
        let maxFraction = maxTrimDuration / totalDuration
        let minGap = 0.02 // minimum gap between handles
        
        var newStart = max(0, min(fraction, 1.0 - minGap))
        
        // If expanding beyond max duration, push end
        if (trimEnd - newStart) > maxFraction {
            let newEnd = min(1.0, newStart + maxFraction)
            trimEnd = newEnd
            // If end hit the wall, clamp start too
            if newEnd >= 1.0 {
                newStart = max(0, 1.0 - maxFraction)
            }
        }
        
        // Don't let start pass end
        newStart = min(newStart, trimEnd - minGap)
        trimStart = max(0, newStart)
    }
    
    /// Drag the END handle: move end, push start if range > maxTrimDuration
    private func handleEndDrag(fraction: Double) {
        let totalDuration = recorder.recordingDuration
        guard totalDuration > 0 else { return }
        let maxFraction = maxTrimDuration / totalDuration
        let minGap = 0.02
        
        var newEnd = min(1.0, max(fraction, minGap))
        
        // If expanding beyond max duration, push start
        if (newEnd - trimStart) > maxFraction {
            let newStart = max(0, newEnd - maxFraction)
            trimStart = newStart
            // If start hit the wall, clamp end too
            if newStart <= 0 {
                newEnd = min(1.0, maxFraction)
            }
        }
        
        // Don't let end pass start
        newEnd = max(newEnd, trimStart + minGap)
        trimEnd = min(1.0, newEnd)
    }
    
    private func playTrimmedPreview() {
        guard let buffer = recorder.recordedBuffer else { return }
        let totalFrames = Int(buffer.frameLength)
        let startFrame = AVAudioFramePosition(trimStart * Double(totalFrames))
        let endFrame = AVAudioFramePosition(trimEnd * Double(totalFrames))
        
        guard let trimmed = CustomSoundManager.trimBuffer(buffer, startFrame: startFrame, endFrame: endFrame) else { return }
        // Apply fade for preview too
        CustomSoundManager.applyFades(trimmed)
        recorder.playPreview(buffer: trimmed)
    }
    
    private func saveAndDismiss() {
        guard let buffer = recorder.recordedBuffer else { return }
        let totalFrames = Int(buffer.frameLength)
        let startFrame = AVAudioFramePosition(trimStart * Double(totalFrames))
        let endFrame = AVAudioFramePosition(trimEnd * Double(totalFrames))
        
        guard let trimmed = CustomSoundManager.trimBuffer(buffer, startFrame: startFrame, endFrame: endFrame) else { return }
        CustomSoundManager.applyFades(trimmed)
        
        do {
            try CustomSoundManager.saveRecording(buffer: trimmed, slot: slot)
            onSaved()
        } catch {
            print("SoundRecorderView: failed to save recording: \(error)")
            onCancel()
        }
    }
}
