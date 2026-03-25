//
//  ContentView.swift
//  Magnetic
//
//  Created by minimaltek on 2026/03/14.
//

import SwiftUI
import Combine

struct ContentView: View {
    
    @Environment(\.scenePhase) private var scenePhase
    
    @State private var simulation = MetaballSimulation(count: 10)
    @StateObject private var audioEngine = AudioEngine()
    
    @State private var showSettings = false
    @State private var isInBackground = false
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "onboardingCompleted")

    @AppStorage("tapOrbit") private var tapOrbit: Bool = true
    @AppStorage("tapColor") private var tapColor: Bool = true
    @AppStorage("tapBall") private var tapBall: Bool = true
    @AppStorage("camMode") private var camMode: Bool = true
    
    // Audio gain settings
    @AppStorage("gainMode") private var gainMode: Int = 0      // 0=AUTO, 1=MANUAL
    @AppStorage("manualGain") private var manualGain: Double = 3.0
    
    @AppStorage("ballCount") private var ballCount: Double = 10
    @AppStorage("isMicEnabled") private var isMicEnabled: Bool = false
    @AppStorage("materialMode") private var materialMode: Int = 0
    @AppStorage("colorHue") private var colorHue: Double = 0
    @AppStorage("colorBri") private var colorBri: Double = 0.9
    @AppStorage("envMapIndex") private var envMapIndex: Int = 0
    @AppStorage("envIntensity") private var envIntensity: Double = 1.0
    @AppStorage("isBPMEnabled") private var isBPMEnabled: Bool = true
    @AppStorage("orbitPattern") private var orbitPattern: Int = 0
    @State private var customEnvImages: [UIImage?] = [nil, nil, nil]
    @State private var customEnvImageVersions: [Int] = [0, 0, 0]
    @State private var originalPhotoImages: [UIImage?] = [nil, nil, nil]
    @AppStorage("ballSize") private var ballSize: Double = 0.5
    @AppStorage("bgMode") private var bgMode: Int = 0
    @AppStorage("bgCustomHue") private var bgCustomHue: Double = 0.6
    @AppStorage("bgCustomSat") private var bgCustomSat: Double = 0.8
    @AppStorage("bgCustomBri") private var bgCustomBri: Double = 0.5
    @AppStorage("envLocked") private var envLocked: Int = 0  // 0=FREE, 1=FIXED, 2=FRONT
    @AppStorage("autoHue") private var autoHue: Bool = false
    @AppStorage("autoBgHue") private var autoBgHue: Bool = false
    @AppStorage("spacing") private var spacing: Double = 1.0
    @AppStorage("orbitRange") private var orbitRange: Double = 1.0
    @AppStorage("gridMode") private var gridMode: Bool = false
    @AppStorage("fps") private var fps: Int = 30
    @AppStorage("manualBPM") private var manualBPM: Double = 60
    @AppStorage("recEnabled") private var recEnabled: Bool = false
    @AppStorage("consoleMode") private var consoleMode: Bool = false
    @AppStorage("brightnessSync") private var brightnessSync: Bool = false
    @AppStorage("brightnessSyncMax") private var brightnessSyncMax: Double = 3.0
    @AppStorage("blendK") private var blendK: Double = 0.35
    
    @State private var micBrightnessBoost: Float = 1.0
    @State private var rendererRef: MetaballRenderer?
    @State private var screenshotPending = false
    @State private var isRecording = false
    @State private var showRecordingSaved = false
    @State private var recordingStartTime: Date = .now
    
    // Console live stats (updated from renderer at ~10Hz)
    @State private var liveActualCamDistance: Float = 3.0
    @State private var liveLongPressProgress: Float = 0
    
    // Individual parameter locks (toggled by double-tap on label in settings)
    @State private var lockCount: Bool = false
    @State private var lockSize: Bool = false
    @State private var lockSpacing: Bool = false
    @State private var lockOrbit: Bool = false
    
    // VIEW mode state
    @State private var viewCamDirection: Double = -1    // -1=approaching, 1=pulling back
    @State private var viewCameraDistance: Double = 3.0
    @State private var viewSpacingDirection: Double = 1  // 1=expanding, -1=contracting
    @State private var viewSpacing: Double = 1.0         // internal spacing for CAM mode
    private let viewTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
    
    private var bgCustomRGB: (Float, Float, Float) {
        let c = UIColor(hue: bgCustomHue, saturation: bgCustomSat, brightness: bgCustomBri, alpha: 1)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: nil)
        return (Float(r), Float(g), Float(b))
    }
    
    var body: some View {
        mainContent
            .sheet(isPresented: $showSettings) {
                settingsSheet
            }
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView {
                    UserDefaults.standard.set(true, forKey: "onboardingCompleted")
                    showOnboarding = false
                }
            }
            .onAppear {
                // Clamp saved values to current ranges
                if ballSize > 0.75 { ballSize = 0.75 }
                if ballCount > 20 { ballCount = 20 }
                if orbitRange > 2.0 { orbitRange = 2.0 }
                if bgMode > 3 { bgMode = 1 }  // fallback to BLK
                // Apply saved settings to simulation and audio engine on launch
                audioEngine.gainMode = gainMode
                audioEngine.manualGainValue = Float(manualGain)
                simulation.reactivity = audioEngine.effectiveGain
                simulation.ballSizeMultiplier = Float(ballSize)
                simulation.spacingMultiplier = Float(spacing)
                simulation.orbitRangeMultiplier = Float(orbitRange)
                simulation.gridMode = gridMode
                simulation.camMode = camMode
                if let pattern = OrbitPattern(rawValue: orbitPattern) {
                    simulation.orbitPattern = pattern
                }
                simulation.resetBalls(count: Int(ballCount))
                if isMicEnabled {
                    audioEngine.requestPermissionAndStart()
                }
                loadCustomEnvImages()
            }
            // reactivity is now driven by auto-gain in the render loop
            .onChange(of: ballCount) { newValue in
                simulation.resetBalls(count: Int(newValue))
            }
            .onChange(of: isMicEnabled) { newValue in
                if newValue {
                    audioEngine.requestPermissionAndStart()
                } else {
                    audioEngine.stop()
                }
            }
            .onChange(of: orbitPattern) { newValue in
                if let pattern = OrbitPattern(rawValue: newValue) {
                    simulation.orbitPattern = pattern
                    simulation.resetBalls(count: Int(ballCount))
                }
            }
            .onChange(of: ballSize) { newValue in
                simulation.ballSizeMultiplier = Float(newValue)
                simulation.resetBalls(count: Int(ballCount))
            }
            .onChange(of: spacing) { newValue in
                simulation.spacingMultiplier = Float(newValue)
                simulation.resetBalls(count: Int(ballCount))
            }
            .onChange(of: orbitRange) { newValue in
                simulation.orbitRangeMultiplier = Float(newValue)
                simulation.resetBalls(count: Int(ballCount))
            }
            .onChange(of: gridMode) { newValue in
                simulation.gridMode = newValue
            }
            .onChange(of: recEnabled) { newValue in
                if !newValue && isRecording {
                    isRecording = false
                }
            }
            .onChange(of: camMode) { newValue in
                simulation.camMode = newValue
                if newValue {
                    viewCamDirection = -1  // start approaching
                    viewSpacing = spacing  // start from current user setting
                    viewSpacingDirection = 1
                } else {
                    // Restore user's spacing setting
                    simulation.spacingMultiplier = Float(spacing)
                }
            }
            .onChange(of: gainMode) { newValue in
                audioEngine.gainMode = newValue
            }
            .onChange(of: manualGain) { newValue in
                audioEngine.manualGainValue = Float(newValue)
            }
            .onChange(of: scenePhase) { newPhase in
                isInBackground = (newPhase != .active)
            }
            .onReceive(viewTimer) { _ in
                guard camMode else { return }
                
                // Camera range
                let camMin: Double = 3.0
                let camMax: Double = 6.0
                
                // Speed based on BPM: full cycle = 16 beats per half
                // BPM60 → 16 sec, BPM120 → 8 sec, BPM200 → 4.8 sec
                let bpm = max(manualBPM, 10)
                let beatsPerSec = bpm / 60.0
                let halfCycleBeats: Double = 16  // beats per half-cycle
                let halfCycleSec = halfCycleBeats / beatsPerSec
                let camSpeed = (camMax - camMin) / halfCycleSec / 30.0  // per tick
                
                // Update camera distance
                viewCameraDistance += viewCamDirection * camSpeed
                if viewCameraDistance <= camMin {
                    viewCameraDistance = camMin
                    viewCamDirection = 1   // start pulling back
                } else if viewCameraDistance >= camMax {
                    viewCameraDistance = camMax
                    viewCamDirection = -1  // start approaching
                }
                
                // Spacing oscillation: same speed, opposite to camera (close cam = wide spacing)
                let spcMin: Double = 0.5
                let spcMax: Double = 2.0
                let spcSpeed = (spcMax - spcMin) / halfCycleSec / 30.0
                viewSpacing += viewSpacingDirection * spcSpeed
                if viewSpacing <= spcMin {
                    viewSpacing = spcMin
                    viewSpacingDirection = 1
                } else if viewSpacing >= spcMax {
                    viewSpacing = spcMax
                    viewSpacingDirection = -1
                }
                // Directly update simulation (bypass onChange/resetBalls)
                simulation.spacingMultiplier = Float(viewSpacing)
            }
            .onReceive(viewTimer) { _ in
                // Track mic brightness boost for console display
                guard isMicEnabled && brightnessSync else {
                    micBrightnessBoost = 1.0
                    return
                }
                let level = audioEngine.inputLevel
                let dt: Float = 1.0 / 30.0
                if level > 0.8 {
                    micBrightnessBoost += 2.0 * dt
                } else if level > 0.5 {
                    micBrightnessBoost += 0.5 * dt
                } else {
                    micBrightnessBoost += (1.0 - micBrightnessBoost) * 2.0 * dt
                }
                micBrightnessBoost = min(max(micBrightnessBoost, 1.0), Float(brightnessSyncMax))
            }
    }
    
    private var mainContent: some View {
        ZStack {
            MetalMetaballView(simulation: $simulation, isPaused: (showSettings && !screenshotPending) || isInBackground, materialMode: materialMode, colorHue: colorHue, colorBri: colorBri, envMapIndex: envMapIndex, envIntensity: envIntensity, customEnvImages: customEnvImages, customEnvImageVersions: customEnvImageVersions, audioEngine: isMicEnabled ? audioEngine : nil, isBPMEnabled: isBPMEnabled, bgMode: bgMode, bgColor: bgCustomRGB, autoBgHue: autoBgHue, bgCustomHue: bgCustomHue, bgCustomSat: bgCustomSat, bgCustomBri: bgCustomBri, envLocked: envLocked, blendK: blendK, autoHue: autoHue, fps: fps, manualBPM: manualBPM, brightnessSync: brightnessSync, brightnessSyncMax: brightnessSyncMax, onDoubleTap: {
                    handleDoubleTap()
                }, viewCameraDistance: camMode ? Float(viewCameraDistance) : nil, onPinchDistance: { dist in
                    if camMode {
                        viewCameraDistance = Double(dist)
                    }
                }, isRecording: $isRecording, onRecordingFinished: { success in
                    if success {
                        showRecordingSaved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { showRecordingSaved = false }
                        }
                    }
                }, onRendererReady: { renderer in
                    if rendererRef == nil {
                        DispatchQueue.main.async {
                            rendererRef = renderer
                        }
                    }
                }, onConsoleUpdate: { camDist, lpp in
                    liveActualCamDistance = camDist
                    liveLongPressProgress = lpp
                })
                .onChange(of: isRecording) { newValue in
                    if newValue {
                        recordingStartTime = .now
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(!showSettings)
                .overlay {
                    // Tap background to dismiss settings sheet
                    if showSettings {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                showSettings = false
                            }
                    }
                }
            
            VStack {
                // Record button — top-left (only when REC enabled in settings)
                if recEnabled {
                    HStack {
                        VStack(spacing: 4) {
                            RecordButton(isRecording: $isRecording)
                                .scaleEffect(0.75)
                            
                            if isRecording {
                                RecordingTimerView(startTime: recordingStartTime)
                            }
                        }
                        Spacer()
                    }
                    .padding(.leading, 12)
                    .padding(.top, 8)
                }
                
                Spacer()
                
                // Save confirmation
                if showRecordingSaved {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                        .padding(.bottom, 20)
                }
                
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        // Active toggle indicators (persistent)
                        ActiveModesView(
                            tapOrbit: tapOrbit,
                            tapColor: tapColor,
                            tapBall: tapBall,
                            camMode: camMode,
                            orbitPattern: orbitPattern
                        )
                        
                        // BPM indicator (always visible)
                        BPMDisplayView(
                            audioEngine: audioEngine,
                            isMicEnabled: isMicEnabled,
                            isBPMAutoMode: isBPMEnabled,
                            manualBPM: manualBPM
                        )
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        if consoleMode {
                            ConsoleView(
                                orbitRange: orbitRange,
                                cameraDistance: Double(liveActualCamDistance),
                                ballCount: Int(ballCount),
                                ballSize: ballSize,
                                spacing: spacing,
                                orbitPattern: orbitPattern,
                                brightness: Double(envIntensity) * Double(micBrightnessBoost),
                                pinchDistance: viewCameraDistance,
                                longPressProgress: liveLongPressProgress,
                                orbitShrink: liveLongPressProgress > 0 ? 1.0 - liveLongPressProgress * liveLongPressProgress * (3.0 - 2.0 * liveLongPressProgress) * 0.6 : 1.0
                            )
                        }
                        settingsButton
                            .disabled(isRecording)
                            .opacity(isRecording ? 0.3 : 1.0)
                    }
                }
            }
        }
    }
    
    // MARK: - Double Tap Handler
    
    @State private var doubleTapCount: Int = 0
    @State private var wirePhase: Bool = false  // true = currently showing WIRE reveal
    
    private func handleDoubleTap() {
        guard tapOrbit || tapColor || tapBall || camMode else { return }
        
        doubleTapCount += 1
        
        // WIRE reveal phase (step 2→3): previous tap showed WIRE.
        // Now change material + color only. Orbit/Ball/CAM stay as they were.
        if wirePhase && tapColor {
            wirePhase = false
            randomizeColorAfterWire()
            return
        }
        
        // Pre-roll: check if WIRE will be selected (step 1→2)
        // If so, only switch material to WIRE — skip Orbit/Ball/CAM entirely
        if tapColor && rollIsWire() {
            materialMode = 2
            wirePhase = true
            return
        }
        
        // Normal flow (non-WIRE)
        // CAM mode: every double-tap resets to wide panoramic shot
        // Camera oscillation will naturally bring it back in
        if camMode {
            viewCameraDistance = 6.0          // max distance (wide shot)
            viewCamDirection = -1             // will start approaching
            viewSpacing = 2.0                 // max spacing
            viewSpacingDirection = -1         // will start contracting
            simulation.spacingMultiplier = Float(viewSpacing)
            
            // 1/5 chance: also max out orbit size
            if Int.random(in: 0..<5) == 0 {
                orbitRange = 2.0
            }
        }
        
        if tapOrbit {
            randomizeOrbit()
        }
        if tapColor {
            randomizeColor()
        }
        if tapBall {
            randomizeBall()
        }
    }
    
    /// 5% chance for WIRE
    private func rollIsWire() -> Bool {
        Double.random(in: 0..<1) >= 0.95
    }
    
    private func randomizeOrbit() {
        // Cycle sequentially through all orbit patterns (0..8), including RND
        let maxPattern = 8
        let next = orbitPattern + 1
        orbitPattern = next > maxPattern ? 0 : next
        // Randomly toggle GRID on/off
        gridMode = Bool.random()
    }
    
    private func randomizeColor() {
        // Randomize material (WIRE is handled in handleDoubleTap)
        // BLK=32%, HG=32%, CLR=26%, GLS=10%
        let roll = Double.random(in: 0..<1)
        if roll < 0.32 { materialMode = 0 }       // BLK
        else if roll < 0.64 { materialMode = 1 }   // HG
        else if roll < 0.90 { materialMode = 3 }   // CLR
        else { materialMode = 4 }                   // GLS
        
        colorHue = Double.random(in: 0...1)
        // AUTO HUE always on when CLR is selected
        if materialMode == 3 {
            autoHue = true
        }
        // Randomize environment map: 85% chance ENV on (1-12), 15% OFF
        envMapIndex = Double.random(in: 0..<1) < 0.85 ? Int.random(in: 1...12) : 0
        // Randomize brightness
        envIntensity = Double.random(in: 0.3...2.0)
        // Randomize ENV mapping mode: FREE=60%, FIXED=25%, FRONT=15%
        let envRoll = Double.random(in: 0..<1)
        if envRoll < 0.60 { envLocked = 0 }       // FREE
        else if envRoll < 0.85 { envLocked = 1 }   // FIXED
        else { envLocked = 2 }                      // FRONT
    }
    
    /// Called after WIRE reveal phase — randomize material (non-WIRE) + color only
    private func randomizeColorAfterWire() {
        // Pick a non-WIRE material: BLK=32%, HG=32%, CLR=26%, GLS=10%
        let roll = Double.random(in: 0..<1)
        if roll < 0.32 { materialMode = 0 }       // BLK
        else if roll < 0.64 { materialMode = 1 }   // HG
        else if roll < 0.90 { materialMode = 3 }   // CLR
        else { materialMode = 4 }                   // GLS
        
        colorHue = Double.random(in: 0...1)
        if materialMode == 3 {
            autoHue = true
        }
        // Randomize environment map + brightness + mapping mode
        envMapIndex = Double.random(in: 0..<1) < 0.85 ? Int.random(in: 1...12) : 0
        envIntensity = Double.random(in: 0.3...2.0)
        let envRoll = Double.random(in: 0..<1)
        if envRoll < 0.60 { envLocked = 0 }
        else if envRoll < 0.85 { envLocked = 1 }
        else { envLocked = 2 }
    }
    
    private func randomizeBall() {
        if !lockCount {
            // 60% chance of 15-20, 40% chance of 4-14
            if Double.random(in: 0..<1) < 0.6 {
                ballCount = Double(Int.random(in: 15...20))
            } else {
                ballCount = Double(Int.random(in: 4...14))
            }
        }
        if !lockSize { ballSize = Double.random(in: 0.3...0.75) }
        if !lockSpacing { spacing = Double.random(in: 0.5...2.0) }
        if !lockOrbit {
            // 60% chance of max orbit size
            orbitRange = Double.random(in: 0..<1) < 0.6 ? 2.0 : Double.random(in: 0.3...2.0)
        }
    }
    
    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.body)
                .foregroundStyle(.gray)
        }
        .padding(.trailing, 24)
        .padding(.bottom, 12)
    }
    
    private var settingsSheet: some View {
        SettingsView(
            ballCount: $ballCount,
            isMicEnabled: $isMicEnabled,
            isBPMEnabled: $isBPMEnabled,
            orbitPattern: $orbitPattern,
            ballSize: $ballSize,
            materialMode: $materialMode,
            colorHue: $colorHue,
            colorBri: $colorBri,
            envMapIndex: $envMapIndex,
            envIntensity: $envIntensity,
            customEnvImages: $customEnvImages,
            customEnvImageVersions: $customEnvImageVersions,
            bgMode: $bgMode,
            bgCustomHue: $bgCustomHue,
            bgCustomSat: $bgCustomSat,
            bgCustomBri: $bgCustomBri,
            envLocked: $envLocked,
            autoHue: $autoHue,
            autoBgHue: $autoBgHue,
            spacing: $spacing,
            orbitRange: $orbitRange,
            gridMode: $gridMode,
            tapOrbit: $tapOrbit,
            tapColor: $tapColor,
            tapBall: $tapBall,
            fps: $fps,
            manualBPM: $manualBPM,
            recEnabled: $recEnabled,
            camMode: $camMode,
            consoleMode: $consoleMode,
            brightnessSync: $brightnessSync,
            brightnessSyncMax: $brightnessSyncMax,
            lockCount: $lockCount,
            lockSize: $lockSize,
            lockSpacing: $lockSpacing,
            lockOrbit: $lockOrbit,
            gainMode: $gainMode,
            manualGain: $manualGain,
            originalPhotoImages: $originalPhotoImages,
            onLoadPreset: { resyncAfterPresetLoad() },
            onSavePreset: { slotIndex, completion in
                screenshotPending = true
                rendererRef?.screenshotCompletion = { image in
                    screenshotPending = false
                    if let image = image {
                        PresetManager.saveThumbnail(image, to: slotIndex)
                    }
                    completion(image)
                }
            }
        )
        .presentationDetents([.medium])
        .presentationBackground(Color(white: 0.06))
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .interactiveDismissDisabled(false)
    }
    
    // MARK: - Custom ENV Image Persistence
    
    private static let envImageDir: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CustomEnv", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    
    private func loadCustomEnvImages() {
        for slot in 0..<3 {
            let croppedURL = Self.envImageDir.appendingPathComponent("env_cropped_\(slot).jpg")
            let originalURL = Self.envImageDir.appendingPathComponent("env_original_\(slot).jpg")
            if let data = try? Data(contentsOf: croppedURL), let image = UIImage(data: data) {
                customEnvImages[slot] = image
                customEnvImageVersions[slot] += 1
            }
            if let data = try? Data(contentsOf: originalURL), let image = UIImage(data: data) {
                originalPhotoImages[slot] = image
            }
        }
    }
    
    static func saveCustomEnvImage(cropped: UIImage, original: UIImage?, slot: Int) {
        guard slot >= 0 && slot < 3 else { return }
        if let data = cropped.jpegData(compressionQuality: 0.85) {
            try? data.write(to: envImageDir.appendingPathComponent("env_cropped_\(slot).jpg"))
        }
        if let orig = original, let data = orig.jpegData(compressionQuality: 0.85) {
            try? data.write(to: envImageDir.appendingPathComponent("env_original_\(slot).jpg"))
        }
    }
    
    // MARK: - Preset Load Sync
    
    private func resyncAfterPresetLoad() {
        consoleMode = false
        simulation.ballSizeMultiplier = Float(ballSize)
        simulation.spacingMultiplier = Float(spacing)
        simulation.orbitRangeMultiplier = Float(orbitRange)
        simulation.gridMode = gridMode
        simulation.camMode = camMode
        if let pattern = OrbitPattern(rawValue: orbitPattern) {
            simulation.orbitPattern = pattern
        }
        simulation.resetBalls(count: Int(ballCount))
        if isMicEnabled && !audioEngine.isRunning {
            audioEngine.requestPermissionAndStart()
        } else if !isMicEnabled && audioEngine.isRunning {
            audioEngine.stop()
        }
    }
}

// MARK: - BPM Display (always visible, supports auto and manual modes)

struct BPMDisplayView: View {
    @ObservedObject var audioEngine: AudioEngine
    var isMicEnabled: Bool
    var isBPMAutoMode: Bool
    var manualBPM: Double
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Mic input level meter (only when mic is on)
            if isMicEnabled {
                LevelMeterView(level: audioEngine.inputLevel)
            }
            
            // BPM display with beat dot
            if isBPMAutoMode && isMicEnabled {
                // Auto mode: use audioEngine's beat detection
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                        .opacity(audioEngine.beatFired ? 1.0 : 0.12)
                        .scaleEffect(audioEngine.beatFired ? 1.5 : 1.0)
                        .animation(.easeOut(duration: 0.1), value: audioEngine.beatFired)
                    
                    Text(audioEngine.detectedBPM > 0 ? "\(Int(audioEngine.detectedBPM))" : "---")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.gray)
                }
            } else {
                // Manual mode: flash at manual BPM rate
                ManualBeatView(bpm: manualBPM)
            }
        }
        .padding(.leading, 16)
        .padding(.bottom, 16)
    }
}

// Beat dot that flashes at manual BPM using TimelineView
struct ManualBeatView: View {
    let bpm: Double
    
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60.0 / max(bpm, 1))) { context in
            HStack(spacing: 5) {
                ManualBeatDot(date: context.date)
                
                Text("\(Int(bpm))")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.gray)
            }
        }
    }
}

struct ManualBeatDot: View {
    let date: Date
    @State private var flash = false
    
    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 6, height: 6)
            .opacity(flash ? 1.0 : 0.12)
            .scaleEffect(flash ? 1.5 : 1.0)
            .animation(.easeOut(duration: 0.1), value: flash)
            .onChange(of: date) { _ in
                flash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    flash = false
                }
            }
    }
}

// MARK: - Mic Input Level Meter

struct LevelMeterView: View {
    let level: Float  // 0..1
    
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fillWidth = CGFloat(level) * w
            
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.gray.opacity(0.2))
                
                Capsule()
                    .fill(meterColor)
                    .frame(width: max(fillWidth, 0))
            }
        }
        .frame(width: 60, height: 3)
    }
    
    private var meterColor: Color {
        if level > 0.8 { return .red }
        if level > 0.5 { return .yellow }
        return .green
    }
}

// MARK: - Active Modes Indicator (persistent display of enabled toggles)

struct ActiveModesView: View {
    let tapOrbit: Bool
    let tapColor: Bool
    let tapBall: Bool
    let camMode: Bool
    let orbitPattern: Int
    
    private let orbitIcons = [
        "dice", "circle", "globe", "circle.circle",
        "hurricane", "atom", "lungs", "infinity", "water.waves"
    ]
    
    var body: some View {
        HStack(spacing: 6) {
            if tapOrbit {
                let icon = orbitPattern >= 0 && orbitPattern < orbitIcons.count
                    ? orbitIcons[orbitPattern] : "circle"
                Image(systemName: "arrow.trianglehead.2.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.gray)
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.gray)
            }
            if tapColor {
                Image(systemName: "paintbrush.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.gray)
            }
            if tapBall {
                Image(systemName: "circle.grid.2x2.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.gray)
            }
            if camMode {
                Image(systemName: "video.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.gray)
            }
        }
        .padding(.leading, 18)
        .allowsHitTesting(false)
    }
}

// MARK: - Console (parameter monitor)

struct ConsoleView: View {
    let orbitRange: Double
    let cameraDistance: Double
    let ballCount: Int
    let ballSize: Double
    let spacing: Double
    let orbitPattern: Int
    let brightness: Double
    let pinchDistance: Double
    let longPressProgress: Float
    let orbitShrink: Float
    
    private let patternNames = ["RND", "CRC", "SPH", "TOR", "SPI", "SAT", "DNA", "FIG8", "WAV"]
    
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            line("ORB", String(format: "%.2f", orbitRange))
            line("CAM", String(format: "%.1f", cameraDistance))
            line("PCH", String(format: "%.1f", pinchDistance))
            line("CNT", "\(ballCount)")
            line("SIZ", String(format: "%.2f", ballSize))
            line("SPC", String(format: "%.2f", spacing))
            line("PTN", orbitPattern < patternNames.count ? patternNames[orbitPattern] : "?")
            line("BRT", String(format: "%.2f", brightness))
            line("LPR", String(format: "%.2f", longPressProgress))
            line("OSZ", String(format: "%.2f", orbitShrink))
        }
        .padding(.trailing, 24)
        .allowsHitTesting(false)
    }
    
    private func line(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.gray.opacity(0.5))
            Text(value)
                .foregroundStyle(.gray)
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
    }
}

// MARK: - Record Button

struct RecordButton: View {
    @Binding var isRecording: Bool
    @State private var pulse = false
    
    var body: some View {
        Button {
            isRecording.toggle()
        } label: {
            ZStack {
                // Outer ring
                Circle()
                    .stroke(Color.red.opacity(0.5), lineWidth: 1.5)
                    .frame(width: 32, height: 32)
                
                // Inner dot — circle when idle, rounded square when recording
                if isRecording {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.red)
                        .frame(width: 12, height: 12)
                        .scaleEffect(pulse ? 1.15 : 0.85)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 14, height: 14)
                }
            }
        }
        .onChange(of: isRecording) { recording in
            if recording {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else {
                withAnimation(.default) {
                    pulse = false
                }
            }
        }
    }
}

// MARK: - Recording Timer

struct RecordingTimerView: View {
    let startTime: Date
    
    var body: some View {
        TimelineView(.periodic(from: startTime, by: 1)) { context in
            let elapsed = Int(context.date.timeIntervalSince(startTime))
            let minutes = elapsed / 60
            let seconds = elapsed % 60
            Text(String(format: "%d:%02d", minutes, seconds))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.red)
        }
    }
}

#Preview {
    ContentView()
}
