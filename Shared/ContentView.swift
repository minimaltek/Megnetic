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
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    
    @State private var simulation = MetaballSimulation(count: 10)
    @StateObject private var audioEngine = AudioEngine()
    
    @State private var showSettings = false
    @State private var isInBackground = false
    #if os(iOS)
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "onboardingCompleted")
    #else
    @State private var showOnboarding = true
    #endif

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
    @AppStorage("basicMode") private var basicMode: Int = 0  // 0=METABALL, 1=LINE, 2=BOX, 3=RAIN
    @AppStorage("polygonSides") private var polygonSides: Double = 4  // RAIN: 3-8
    @AppStorage("polygonInset") private var polygonInset: Double = 0.0  // RAIN star: 0=polygon, 1=fully collapsed
    @State private var customEnvImages: [PlatformImage?] = [nil, nil, nil]
    @State private var customEnvImageVersions: [Int] = [0, 0, 0]
    @State private var originalPhotoImages: [PlatformImage?] = [nil, nil, nil]
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
    @AppStorage("gridMode") private var gridMode: Bool = true
    @AppStorage("fps") private var fps: Int = 60
    @AppStorage("manualBPM") private var manualBPM: Double = 60
    @AppStorage("manualBPM_metaball") private var manualBPM_metaball: Double = 60
    @AppStorage("manualBPM_line") private var manualBPM_line: Double = 120
    @AppStorage("manualBPM_rain") private var manualBPM_rain: Double = 30
    @AppStorage("recEnabled") private var recEnabled: Bool = false
    @AppStorage("consoleMode") private var consoleMode: Bool = false
    @AppStorage("brightnessSync") private var brightnessSync: Bool = false
    @AppStorage("brightnessSyncMax") private var brightnessSyncMax: Double = 3.0
    @AppStorage("blendK") private var blendK: Double = 0.35
    @AppStorage("boxNoiseType") private var boxNoiseType: Int = 0
    @AppStorage("plyScaleMode") private var rainScaleMode: Int = 1  // 1=PENTA, 2=MAJOR, 3=MINOR, 4=BLUES
    @AppStorage("plyBlockInst") private var rainBlockInst: Int = 0  // 0=BASE, 1=PIANO, 2=VOICE, 3=WOOD
    @AppStorage("plyWallInst") private var rainWallInst: Int = 0   // 0=BASE, 1=PIANO, 2=VOICE, 3=WOOD
    @AppStorage("plyRootNote") private var rainRootNote: Int = 0  // 0=C, 1=C#, 2=D, ... 11=B
    @AppStorage("plyOctave") private var rainOctave: Int = 0      // -2 to +2 octave offset
    @AppStorage("plyBallCount") private var rainBallCount: Int = 1 // 1-3 balls in RAIN mode
    @AppStorage("plyDelayEnabled") private var rainDelayEnabled: Bool = true
    @AppStorage("plyDelaySync") private var rainDelaySync: Int = 2  // index: default 2 = 1/8D
    @AppStorage("plyDelayFeedback") private var rainDelayFeedback: Double = 0.65
    @AppStorage("plyDelayAmount") private var rainDelayAmount: Double = 0.10
    @AppStorage("plyCategory") private var rainCategory: Int = 0  // 0=Fall, 1=PinBall
    
    @State private var micBrightnessBoost: Float = 1.0
    @State private var rendererRef: MetaballRenderer?
    @State private var screenshotPending = false
    @State private var isRecording = false
    @State private var showRecordingSaved = false
    @State private var recordingStartTime: Date = .now
    
    // Console live stats (updated from renderer at ~10Hz)
    @State private var liveActualCamDistance: Float = 3.0
    @State private var liveLongPressProgress: Float = 0
    
    // LINES mode camera lock (toggled by double-tap)
    @State private var linesCameraLocked: Bool = false
    
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
    @State private var camPauseTimer: Double = 0          // seconds remaining to pause at origin
    private let viewTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
    
    private var bgCustomRGB: (Float, Float, Float) {
        let c = PlatformColor.fromHSB(hue: bgCustomHue, saturation: bgCustomSat, brightness: bgCustomBri)
        let rgb = c.getRGBComponents()
        return (Float(rgb.r), Float(rgb.g), Float(rgb.b))
    }
    
    /// Landscape detection: on iOS, verticalSizeClass == .compact means landscape
    private var isLandscape: Bool {
        #if os(iOS)
        return verticalSizeClass == .compact
        #else
        return false
        #endif
    }
    
    var body: some View {
        Group {
        ZStack {
            mainContent
            #if os(iOS)
                .sheet(isPresented: isLandscape ? .constant(false) : $showSettings) {
                    settingsSheet
                }
                .fullScreenCover(isPresented: $showOnboarding) {
                    OnboardingView {
                        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
                        showOnboarding = false
                    }
                }
            #else
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView {
                        showOnboarding = false
                    }
                }
            #endif

            #if os(iOS)
            // Landscape: right-aligned overlay panel (portrait width preserved)
            if isLandscape && showSettings {
                HStack(spacing: 0) {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showSettings = false
                            }
                        }
                    
                    settingsSheetLandscape
                        .frame(width: 380)
                        .background(Color(white: 0.06))
                        .ignoresSafeArea(edges: .bottom)
                        .transition(.move(edge: .trailing))
                }
                .transition(.opacity)
            }
            #endif

            // macOS: settings as centered overlay (dismissible by tapping background)
            #if os(macOS)
            if showSettings {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        showSettings = false
                    }
                
                settingsSheet
                    .frame(width: 500, height: 600)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(radius: 30)
            }
            #endif
        }
            .onAppear { handleOnAppear() }
            // reactivity is now driven by auto-gain in the render loop
            .onChange(of: ballCount) { handleBallCountChange($0) }
            .onChange(of: isMicEnabled) { handleMicEnabledChange($0) }
            .onChange(of: orbitPattern) { handleOrbitPatternChange($0) }
            .onChange(of: basicMode) { _ in handleBasicModeChange() }
        } // Group — split here to help Swift type-checker
            .onChange(of: ballSize) { handleBallSizeChange($0) }
            .onChange(of: spacing) { handleSpacingChange($0) }
            .onChange(of: orbitRange) { handleOrbitRangeChange($0) }
            .onChange(of: gridMode) { simulation.gridMode = $0 }
            .onChange(of: polygonSides) { handlePolygonSidesChange($0) }
            .onChange(of: polygonInset) { simulation.polygonInset = Float($0) }
            .onChange(of: recEnabled) { if !$0 && isRecording { isRecording = false } }
            .onChange(of: camMode) { handleCamModeChange($0) }
            .onChange(of: gainMode) { audioEngine.gainMode = $0 }
            .onChange(of: boxNoiseType) { handleBoxNoiseChange($0) }
            .onChange(of: rainCategory) { simulation.rainCategory = $0; simulation.resetBalls(count: Int(ballCount)) }
            .onChange(of: manualGain) { audioEngine.manualGainValue = Float($0) }
            .onChange(of: manualBPM) { newVal in
                switch basicMode {
                case 1:  manualBPM_line = newVal
                case 3:  manualBPM_rain = newVal
                default: manualBPM_metaball = newVal
                }
            }
            .onChange(of: scenePhase) { isInBackground = ($0 != .active) }
            .onReceive(viewTimer) { _ in handleCamModeTick() }
            .onReceive(viewTimer) { _ in handleBrightnessSyncTick() }
    }
    
    private var mainContent: some View {
        ZStack {
            MetalMetaballView(simulation: $simulation, isPaused: (showSettings && !screenshotPending) || isInBackground, materialMode: materialMode, colorHue: colorHue, colorBri: colorBri, envMapIndex: envMapIndex, envIntensity: envIntensity, customEnvImages: customEnvImages, customEnvImageVersions: customEnvImageVersions, audioEngine: isMicEnabled ? audioEngine : nil, isBPMEnabled: isBPMEnabled, bgMode: bgMode, bgColor: bgCustomRGB, autoBgHue: autoBgHue, bgCustomHue: bgCustomHue, bgCustomSat: bgCustomSat, bgCustomBri: bgCustomBri, envLocked: envLocked, blendK: blendK, autoHue: autoHue, fps: fps, manualBPM: manualBPM, brightnessSync: brightnessSync, brightnessSyncMax: brightnessSyncMax, onDoubleTap: {
                    handleDoubleTap()
                }, viewCameraDistance: camMode ? Float(viewCameraDistance) : nil, onPinchDistance: { dist in
                    if camMode {
                        // Match auto-camera direction to user's pinch intent
                        let newDist = Double(dist)
                        if newDist < viewCameraDistance {
                            viewCamDirection = -1  // user is zooming in → continue approaching
                        } else if newDist > viewCameraDistance {
                            viewCamDirection = 1   // user is zooming out → continue pulling back
                        }
                        viewCameraDistance = newDist
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
                },
                linesCameraLocked: linesCameraLocked,
                onCameraLockChanged: { locked in
                    linesCameraLocked = locked
                },
                rainScaleMode: rainScaleMode,
                rainBlockInst: rainBlockInst,
                rainWallInst: rainWallInst,
                rainRootNote: rainRootNote,
                rainOctave: rainOctave,
                rainBallCount: rainBallCount,
                rainDelayEnabled: rainDelayEnabled,
                rainDelaySync: rainDelaySync,
                rainDelayFeedback: Float(rainDelayFeedback),
                rainDelayAmount: Float(rainDelayAmount),
                rainCategory: rainCategory)
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
                        if basicMode == 3 {
                            // RAIN mode: single-line HUD (icon + BPM)
                            RainHUDView(manualBPM: manualBPM)
                        } else {
                            // Active toggle indicators (persistent)
                            ActiveModesView(
                                tapOrbit: tapOrbit,
                                tapColor: tapColor,
                                tapBall: tapBall,
                                camMode: camMode,
                                orbitPattern: orbitPattern,
                                basicMode: basicMode
                            )
                            
                            // BPM indicator (always visible)
                            BPMDisplayView(
                                audioEngine: audioEngine,
                                isMicEnabled: isMicEnabled,
                                isBPMAutoMode: isBPMEnabled,
                                manualBPM: manualBPM
                            )
                        }
                    }
                    Spacer()
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
                                basicMode: basicMode,
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
    
    private func handleBallCountChange(_ newValue: Double) {
        simulation.boxDensity = Float(newValue)
        simulation.resetBalls(count: Int(newValue))
    }
    
    private func handleMicEnabledChange(_ newValue: Bool) {
        if newValue { audioEngine.requestPermissionAndStart() } else { audioEngine.stop() }
        // BPM AUTO requires mic — force Manual when mic is off
        if !newValue && isBPMEnabled { isBPMEnabled = false }
    }
    
    private func handleBallSizeChange(_ newValue: Double) {
        simulation.ballSizeMultiplier = Float(newValue)
        simulation.resetBalls(count: Int(ballCount))
    }
    
    private func handleSpacingChange(_ newValue: Double) {
        simulation.spacingMultiplier = Float(newValue)
        simulation.resetBalls(count: Int(ballCount))
    }
    
    private func handleOrbitRangeChange(_ newValue: Double) {
        simulation.orbitRangeMultiplier = Float(newValue)
        simulation.resetBalls(count: Int(ballCount))
    }
    
    private func handlePolygonSidesChange(_ newValue: Double) {
        simulation.polygonSides = Int(newValue)
        if orbitPattern == 9 { simulation.resetBalls(count: Int(ballCount)) }
    }
    
    private func handleCamModeChange(_ newValue: Bool) {
        simulation.camMode = newValue
        if newValue {
            viewCamDirection = -1
            viewSpacing = spacing
            viewSpacingDirection = 1
        } else {
            simulation.spacingMultiplier = Float(spacing)
        }
    }
    
    private func handleBoxNoiseChange(_ newValue: Int) {
        if let t = BoxNoiseType(rawValue: newValue) { simulation.setBoxNoiseType(t) }
    }
    
    private func handleOrbitPatternChange(_ newValue: Int) {
        if basicMode == 0 {
            if let pattern = OrbitPattern(rawValue: newValue) {
                simulation.orbitPattern = pattern
                simulation.resetBalls(count: Int(ballCount))
                linesCameraLocked = false
            }
        } else if basicMode == 1 {
            simulation.lineSubOrbit = newValue
            simulation.orbitPattern = .lines
            simulation.resetBalls(count: Int(ballCount))
        }
    }
    
    private func handleBasicModeChange() {
        if let pattern = OrbitPattern(rawValue: effectiveOrbitPattern) {
            simulation.orbitPattern = pattern
            if basicMode == 1 {
                simulation.lineSubOrbit = orbitPattern
            }
            simulation.resetBalls(count: Int(ballCount))
            linesCameraLocked = (pattern == .lines || pattern == .polygon)
        }
        // RAIN mode has no mic — force BPM Manual
        if basicMode == 3 && isBPMEnabled { isBPMEnabled = false }
        // Restore per-mode manual BPM
        switch basicMode {
        case 1:  manualBPM = manualBPM_line
        case 3:  manualBPM = manualBPM_rain
        default: manualBPM = manualBPM_metaball
        }
    }
    
    private func handleCamModeTick() {
        guard camMode else { return }
        let isTrailMode = basicMode == 1
        let camMin: Double = isTrailMode ? 0.1 : 3.0
        let camMax: Double = isTrailMode ? 6.0 : 6.0
        let bpm = max(manualBPM, 10)
        let beatsPerSec = bpm / 60.0
        let halfCycleBeats: Double = 240
        let halfCycleSec = halfCycleBeats / beatsPerSec
        let camSpeed = (camMax - camMin) / halfCycleSec / 30.0
        if camPauseTimer > 0 {
            camPauseTimer -= 1.0 / 30.0
        } else {
            viewCameraDistance += viewCamDirection * camSpeed
        }
        if viewCameraDistance <= camMin {
            viewCameraDistance = camMin
            if isTrailMode && camPauseTimer <= 0 && viewCamDirection < 0 {
                camPauseTimer = 10.0
            }
            viewCamDirection = 1
        } else if viewCameraDistance >= camMax {
            viewCameraDistance = camMax
            viewCamDirection = -1
        }
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
        simulation.spacingMultiplier = Float(viewSpacing)
    }
    
    private func handleBrightnessSyncTick() {
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
    
    private func handleOnAppear() {
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
        simulation.boxDensity = Float(ballCount)
        simulation.polygonSides = Int(polygonSides)
        simulation.polygonInset = Float(polygonInset)
        simulation.rainCategory = rainCategory
        // Backward compat: migrate old orbitPattern 9-11 to basicMode
        if orbitPattern >= 9 {
            switch orbitPattern {
            case 9:  basicMode = 1  // LINE
            case 10: basicMode = 1  // was PCD, fallback to LINE
            case 11: basicMode = 2  // BOX
            case 12: basicMode = 3  // RAIN
            default: break
            }
            orbitPattern = 0  // reset to RND for metaball sub-orbit
        }
        if let pattern = OrbitPattern(rawValue: effectiveOrbitPattern) {
            simulation.orbitPattern = pattern
        }
        if basicMode == 1 {
            simulation.lineSubOrbit = orbitPattern
        }
        if let noiseType = BoxNoiseType(rawValue: boxNoiseType) {
            simulation.boxNoiseType = noiseType
        }
        simulation.resetBalls(count: Int(ballCount))
        // Restore per-mode manual BPM on launch
        switch basicMode {
        case 1:  manualBPM = manualBPM_line
        case 3:  manualBPM = manualBPM_rain
        default: manualBPM = manualBPM_metaball
        }
        // BPM AUTO requires mic — force Manual when mic unavailable
        if (!isMicEnabled || basicMode == 3) && isBPMEnabled {
            isBPMEnabled = false
        }
        if isMicEnabled {
            audioEngine.requestPermissionAndStart()
        }
        loadCustomEnvImages()
    }
    
    @State private var doubleTapCount: Int = 0
    @State private var wirePhase: Bool = false  // true = currently showing WIRE reveal
    
    private func handleDoubleTap() {
        // RAIN mode: double-tap resets balls (both PinBall and Fall)
        if basicMode == 3 {
            simulation.resetBalls(count: Int(ballCount))
            return
        }
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
        // LINE mode: wider range (0.5–12.0) so camera can go inside and see sphere at half size
        if camMode {
            let isTrailMode = basicMode == 1  // LINE
            viewCameraDistance = 6.0  // max distance (wide shot)
            viewCamDirection = -1             // will start approaching
            viewSpacing = isTrailMode ? spacing : 2.0  // trail modes: keep current, others: max
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
    
    /// Maps basicMode + orbitPattern into a single OrbitPattern rawValue (0-11)
    private var effectiveOrbitPattern: Int {
        switch basicMode {
        case 1: return 9   // LINE
        case 2: return 11  // BOX
        case 3: return 12  // RAIN
        default: return orbitPattern  // 0-8 (metaball orbits)
        }
    }
    
    private func randomizeOrbit() {
        if basicMode == 0 {
            // Cycle through metaball orbits (0-8: RND..WAV)
            let maxPattern = 8
            let next = orbitPattern + 1
            orbitPattern = next > maxPattern ? 0 : next
        } else if basicMode == 1 {
            // LINE: cycle through sub-orbits (0-9: RND..RAIN)
            let maxSub = 9
            let next = orbitPattern + 1
            orbitPattern = next > maxSub ? 0 : next
        } else {
            // Cycle through basic modes, skipping BOX (2) which is hidden
            var next = basicMode + 1
            if next == 2 { next = 3 }  // skip BOX
            if next > 3 { next = 0 }
            basicMode = next
        }
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
        // LINE mode: also randomize RAIN params and force redraw
        if basicMode == 1 {
            if orbitPattern == 9 {
                polygonSides = Double(Int.random(in: 3...8))
                polygonInset = Double.random(in: 0..<1) < 0.4 ? 0.0 : Double.random(in: 0.2...0.8)
            }
            simulation.resetBalls(count: Int(ballCount))
        }
    }
    
    private var settingsButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                showSettings = true
            }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.body)
                .foregroundStyle(.gray)
        }
        .padding(.trailing, 24)
        .padding(.bottom, 12)
    }
    
    private var settingsSheet: some View {
        settingsContent
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(white: 0.06))
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .large))
        .interactiveDismissDisabled(false)
        #else
        .background(Color(white: 0.06))
        #endif
    }
    
    #if os(iOS)
    /// Landscape overlay version — no sheet presentation modifiers
    private var settingsSheetLandscape: some View {
        settingsContent
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    #endif
    
    /// Shared settings content used by both sheet and landscape overlay
    private var settingsContent: some View {
        SettingsView(
            ballCount: $ballCount,
            isMicEnabled: $isMicEnabled,
            isBPMEnabled: $isBPMEnabled,
            orbitPattern: $orbitPattern,
            basicMode: $basicMode,
            polygonSides: $polygonSides,
            polygonInset: $polygonInset,
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
            boxNoiseType: $boxNoiseType,
            rainScaleMode: $rainScaleMode,
            rainBlockInst: $rainBlockInst,
            rainWallInst: $rainWallInst,
            rainRootNote: $rainRootNote,
            rainOctave: $rainOctave,
            rainBallCount: $rainBallCount,
            rainDelayEnabled: $rainDelayEnabled,
            rainDelaySync: $rainDelaySync,
            rainDelayFeedback: $rainDelayFeedback,
            rainDelayAmount: $rainDelayAmount,
            rainCategory: $rainCategory,
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
            },
            onCustomSoundSaved: { slot in
                rendererRef?.reloadCustomBlockBuffer(slot: slot)
            },
            onRecorderOpen: {
                rendererRef?.stopAllRainAudio()
            }
        )
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
            if let data = try? Data(contentsOf: croppedURL), let image = PlatformImage.fromData(data) {
                customEnvImages[slot] = image
                customEnvImageVersions[slot] += 1
            }
            if let data = try? Data(contentsOf: originalURL), let image = PlatformImage.fromData(data) {
                originalPhotoImages[slot] = image
            }
        }
    }
    
    static func saveCustomEnvImage(cropped: PlatformImage, original: PlatformImage?, slot: Int) {
        guard slot >= 0 && slot < 3 else { return }
        if let data = cropped.platformJpegData(compressionQuality: 0.85) {
            try? data.write(to: envImageDir.appendingPathComponent("env_cropped_\(slot).jpg"))
        }
        if let orig = original, let data = orig.platformJpegData(compressionQuality: 0.85) {
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
        simulation.boxDensity = Float(ballCount)
        simulation.polygonSides = Int(polygonSides)
        simulation.polygonInset = Float(polygonInset)
        simulation.rainCategory = rainCategory
        // Backward compat: migrate old preset orbitPattern 9-12 → basicMode
        if orbitPattern >= 9 {
            switch orbitPattern {
            case 9:  basicMode = 1
            case 10: basicMode = 1  // was PCD, fallback to LINE
            case 11: basicMode = 2  // BOX
            case 12: basicMode = 3  // RAIN
            default: break
            }
            orbitPattern = 0
        }
        if let pattern = OrbitPattern(rawValue: effectiveOrbitPattern) {
            simulation.orbitPattern = pattern
        }
        if basicMode == 1 {
            simulation.lineSubOrbit = orbitPattern
        }
        if let noiseType = BoxNoiseType(rawValue: boxNoiseType) {
            simulation.boxNoiseType = noiseType
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
    let basicMode: Int
    
    private let orbitIcons = [
        "dice", "circle", "globe", "circle.circle",
        "hurricane", "atom", "lungs", "infinity", "water.waves", "hexagon"
    ]
    private let basicIcons = ["drop.fill", "line.3.horizontal", "square.grid.3x3.topleft.filled", "cloud.rain"]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Row 1: BASE mode indicator (icon only)
            HStack(spacing: 4) {
                let baseIcon = basicMode >= 0 && basicMode < basicIcons.count
                    ? basicIcons[basicMode] : "drop.fill"
                Image(systemName: baseIcon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            
            // Row 2: Double-tap enabled modes
            let hasAnyTap = tapOrbit || tapColor || tapBall || camMode
            if hasAnyTap {
                HStack(spacing: 4) {
                    if tapOrbit {
                        Image(systemName: "arrow.trianglehead.2.clockwise")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.gray)
                        let icon: String = {
                            if basicMode == 0 {
                                return orbitPattern >= 0 && orbitPattern < orbitIcons.count
                                    ? orbitIcons[orbitPattern] : "circle"
                            } else if basicMode == 1 {
                                // LINE: show sub-orbit icon
                                return orbitPattern >= 0 && orbitPattern < orbitIcons.count
                                    ? orbitIcons[orbitPattern] : "circle"
                            } else {
                                return basicMode >= 0 && basicMode < basicIcons.count
                                    ? basicIcons[basicMode] : "circle"
                            }
                        }()
                        Image(systemName: icon)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.gray)
                    }
                    if tapBall {
                        Image(systemName: "circle.grid.2x2.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.gray)
                    }
                    if camMode {
                        Image(systemName: "video.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.gray)
                    }
                }
            }
        }
        .padding(.leading, 18)
        .allowsHitTesting(false)
    }
}

// MARK: - Rain HUD (single line: icon + BPM)

struct RainHUDView: View {
    let manualBPM: Double
    
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60.0 / max(manualBPM, 1))) { context in
            HStack(spacing: 6) {
                Image(systemName: "cloud.rain")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                
                ManualBeatDot(date: context.date)
                
                Text("\(Int(manualBPM))")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.gray)
            }
        }
        .padding(.leading, 16)
        .padding(.bottom, 16)
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
    let basicMode: Int
    let brightness: Double
    let pinchDistance: Double
    let longPressProgress: Float
    let orbitShrink: Float
    
    private let orbitNames = ["RND", "CRC", "SPH", "TOR", "SPI", "SAT", "DNA", "FIG8", "WAV"]
    private let basicNames = ["META", "LINE", "BOX", "RAIN"]
    
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            line("ORB", String(format: "%.2f", orbitRange))
            line("CAM", String(format: "%.1f", cameraDistance))
            line("PCH", String(format: "%.1f", pinchDistance))
            line("CNT", "\(ballCount)")
            line("SIZ", String(format: "%.2f", ballSize))
            line("SPC", String(format: "%.2f", spacing))
            let ptnLabel: String = {
                if basicMode == 0 {
                    return orbitPattern < orbitNames.count ? orbitNames[orbitPattern] : "?"
                } else {
                    return basicMode < basicNames.count ? basicNames[basicMode] : "?"
                }
            }()
            line("PTN", ptnLabel)
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
