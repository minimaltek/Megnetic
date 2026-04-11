//
//  MetalMetaballView.swift
//  Magnetic
//
//  iOS-specific MetalKit view: UIViewRepresentable wrapper + TouchableMTKView.
//  The MetaballRenderer and CameraController live in their own shared files.
//

import SwiftUI
import MetalKit
import simd

// MARK: - SwiftUI Wrapper

struct MetalMetaballView: UIViewRepresentable {
    @Binding var simulation: MetaballSimulation
    var isPaused: Bool = false
    var materialMode: Int = 0
    var colorHue: Double = 0
    var colorBri: Double = 0.9
    var envMapIndex: Int = 0
    var envIntensity: Double = 1.0
    var customEnvImages: [PlatformImage?] = [nil, nil, nil]
    /// Incremented each time a new custom image is picked (per slot)
    var customEnvImageVersions: [Int] = [0, 0, 0]
    /// AudioEngine reference for direct audio data bridging (avoids SwiftUI onChange overhead)
    var audioEngine: AudioEngine? = nil
    var isBPMEnabled: Bool = true
    var bgMode: Int = 0
    var bgColor: (Float, Float, Float) = (0, 0, 0)  // custom background RGB
    var autoBgHue: Bool = false
    var bgCustomHue: Double = 0.6
    var bgCustomSat: Double = 0.8
    var bgCustomBri: Double = 0.5
    var envLocked: Int = 0  // 0=FREE, 1=FIXED, 2=FRONT
    var blendK: Double = 0.35
    var autoHue: Bool = false
    var fps: Int = 30
    var manualBPM: Double = 120
    var brightnessSync: Bool = false
    var brightnessSyncMax: Double = 3.0
    /// Called on double-tap to cycle orbit pattern
    var onDoubleTap: (() -> Void)? = nil
    /// Camera distance override driven by VIEW mode (nil = user pinch controls it)
    var viewCameraDistance: Float? = nil
    /// Called when user pinches to zoom (reports new camera distance)
    var onPinchDistance: ((Float) -> Void)? = nil
    @Binding var isRecording: Bool
    var onRecordingFinished: ((Bool) -> Void)? = nil
    var onRendererReady: ((MetaballRenderer) -> Void)? = nil
    /// Console stats callback: (actualCameraDistance, longPressProgress)
    var onConsoleUpdate: ((Float, Float) -> Void)? = nil
    /// When true, camera rotation is locked (LINES mode)
    var linesCameraLocked: Bool = false
    /// Called when long press toggles camera lock state in LINES mode
    var onCameraLockChanged: ((Bool) -> Void)? = nil
    /// RAIN scale mode: 0=OFF, 1=PENTATONIC, 2=MAJOR, 3=MINOR, 4=BLUES
    var rainScaleMode: Int = 0
    /// RAIN instrument for block/wall sounds: 0=BASE, 1=PIANO, 2=VOICE, 3=WOOD
    var rainBlockInst: Int = 0
    var rainWallInst: Int = 0
    /// Root note: 0=C, 1=C#, 2=D, ... 11=B
    var rainRootNote: Int = 0
    /// Octave offset: -2 to +2
    var rainOctave: Int = 0
    /// Number of balls in RAIN mode (1-3)
    var rainBallCount: Int = 1
    /// Delay enabled (wall sounds)
    var rainDelayEnabled: Bool = false
    /// Delay sync division index
    var rainDelaySync: Int = 2
    /// Delay feedback 0~0.95
    var rainDelayFeedback: Float = 0.4
    /// Delay wet/dry amount 0~1
    var rainDelayAmount: Float = 0.3
    /// RAIN category: 0=Fall, 1=PinBall
    var rainCategory: Int = 0
    
    func makeCoordinator() -> MetaballRenderer {
        MetaballRenderer(simulation: simulation)
    }
    
    func makeUIView(context: Context) -> TouchableMTKView {
        let mtkView = TouchableMTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.delegate = context.coordinator
        mtkView.preferredFramesPerSecond = fps
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        mtkView.framebufferOnly = false  // Allow blit read for video recording
        mtkView.isMultipleTouchEnabled = true
        
        // Render at 75% resolution to reduce GPU load
        mtkView.contentScaleFactor = UIScreen.main.scale * 0.75
        
        mtkView.renderer = context.coordinator
        mtkView.onDoubleTap = onDoubleTap
        mtkView.setupGestures()
        context.coordinator.setup(mtkView: mtkView)
        
        return mtkView
    }
    
    func updateUIView(_ uiView: TouchableMTKView, context: Context) {
        uiView.onDoubleTap = onDoubleTap
        uiView.onPinchDistance = onPinchDistance
        context.coordinator.onConsoleUpdate = onConsoleUpdate
        context.coordinator.simulation = simulation
        context.coordinator.materialMode = UInt32(materialMode)
        context.coordinator.colorHue = Float(colorHue)
        context.coordinator.colorBri = Float(colorBri)
        context.coordinator.envMapIndex = UInt32(envMapIndex)
        context.coordinator.envIntensity = Float(envIntensity)
        context.coordinator.audioEngine = audioEngine
        context.coordinator.isBPMEnabled = isBPMEnabled
        context.coordinator.bgMode = UInt32(bgMode)
        context.coordinator.bgColor = bgColor
        context.coordinator.autoBgHue = autoBgHue
        context.coordinator.bgCustomHue = Float(bgCustomHue)
        context.coordinator.bgCustomSat = Float(bgCustomSat)
        context.coordinator.bgCustomBri = Float(bgCustomBri)
        context.coordinator.envLocked = UInt32(envLocked)
        context.coordinator.blendK = Float(blendK)
        context.coordinator.autoHue = autoHue
        context.coordinator.fps = fps
        context.coordinator.manualBPM = Float(manualBPM)
        context.coordinator.brightnessSync = brightnessSync
        context.coordinator.brightnessSyncMax = Float(brightnessSyncMax)
        if uiView.preferredFramesPerSecond != fps {
            uiView.preferredFramesPerSecond = fps
        }
        switch bgMode {
        case 0:
            uiView.clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        case 2:
            uiView.clearColor = MTLClearColor(red: 0, green: 1, blue: 0, alpha: 1)
        case 3:
            uiView.clearColor = MTLClearColor(red: Double(bgColor.0), green: Double(bgColor.1), blue: Double(bgColor.2), alpha: 1)
        default:
            uiView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        }
        // VIEW mode camera distance override
        if let viewDist = viewCameraDistance {
            context.coordinator.cameraDistance = viewDist
            uiView.setCameraDistance(viewDist)
        }
        // Load custom env textures when a new image is picked (version changed)
        for i in 0..<3 {
            if let image = customEnvImages[i],
               context.coordinator.loadedCustomEnvVersions[i] != customEnvImageVersions[i] {
                context.coordinator.loadCustomEnvTexture(from: image, slot: i)
                context.coordinator.loadedCustomEnvVersions[i] = customEnvImageVersions[i]
            }
        }
        // Only set isPaused when it actually changes
        if uiView.isPaused != isPaused {
            uiView.isPaused = isPaused
        }
        
        // Video recording state
        if isRecording && !context.coordinator.isRecording {
            context.coordinator.onRecordingFinished = { [self] success in
                self.isRecording = false
                self.onRecordingFinished?(success)
            }
            context.coordinator.startRecording(drawableSize: uiView.drawableSize)
        } else if !isRecording && context.coordinator.isRecording {
            context.coordinator.stopRecording()
        }
        
        // Camera lock for LINES mode / DRAW mode
        uiView.onCameraLockChanged = onCameraLockChanged
        if simulation.isDrawingMode {
            // DRAW mode: force front view lock
            uiView.lockCameraToFront()
        } else {
            uiView.setCameraLocked(linesCameraLocked)
        }
        
        // RAIN settings
        context.coordinator.rainScaleMode = rainScaleMode
        context.coordinator.rainBlockInst = rainBlockInst
        context.coordinator.rainWallInst = rainWallInst
        context.coordinator.rainRootNote = rainRootNote
        context.coordinator.rainOctave = rainOctave
        context.coordinator.simulation.rainBallCount = rainBallCount
        context.coordinator.rainDelayEnabled = rainDelayEnabled
        context.coordinator.rainDelaySync = rainDelaySync
        context.coordinator.rainDelayFeedback = rainDelayFeedback
        context.coordinator.rainDelayAmount = rainDelayAmount
        context.coordinator.rainCategory = rainCategory
        context.coordinator.simulation.rainCategory = rainCategory
        
        // Notify parent of renderer reference
        onRendererReady?(context.coordinator)
    }
}

// MARK: - Touchable MTKView with camera orbit + metaball touch

final class TouchableMTKView: MTKView, UIGestureRecognizerDelegate {
    weak var renderer: MetaballRenderer?
    private let touchHandler = TouchHandler()
    private let camera = CameraController()
    var onDoubleTap: (() -> Void)?
    var onPinchDistance: ((Float) -> Void)?
    var onCameraLockChanged: ((Bool) -> Void)?
    
    // Allow taps in the settings button area to pass through to SwiftUI
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Settings button area: bottom-right corner
        let safeBottom: CGFloat = safeAreaInsets.bottom
        let buttonArea: CGFloat = 60
        let buttonRight: CGFloat = 10
        
        let buttonRect = CGRect(
            x: bounds.width - buttonArea - buttonRight,
            y: bounds.height - buttonArea - safeBottom,
            width: buttonArea + buttonRight,
            height: buttonArea + safeBottom
        )
        
        if buttonRect.contains(point) {
            return false  // Let SwiftUI handle this touch
        }
        
        // Record button area: top-left
        let safeTop: CGFloat = safeAreaInsets.top
        let recordRect = CGRect(
            x: 0,
            y: 0,
            width: 60,
            height: safeTop + 70
        )
        if recordRect.contains(point) {
            return false
        }
        
        return super.point(inside: point, with: event)
    }
    
    // Gesture recognizers
    private var panGesture: UIPanGestureRecognizer!
    private var pinchGesture: UIPinchGestureRecognizer!
    private var longPressGesture: UILongPressGestureRecognizer!
    
    // Display link for inertia updates
    private var displayLink: CADisplayLink?
    private var lastInertiaTime: CFTimeInterval = 0
    
    /// Push current camera state to renderer
    private func syncCamera() {
        renderer?.cameraOrientation = camera.cameraOrientation
    }
    
    func setupGestures() {
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        addGestureRecognizer(doubleTap)
        
        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.maximumNumberOfTouches = 1
        panGesture.delegate = self
        addGestureRecognizer(panGesture)
        
        pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinchGesture.delegate = self
        addGestureRecognizer(pinchGesture)
        
        longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.8
        longPressGesture.numberOfTouchesRequired = 1
        longPressGesture.delegate = self
        longPressGesture.allowableMovement = 10
        addGestureRecognizer(longPressGesture)
        
        // 2-finger double tap: align ball velocity to X or Y axis
        let twoFingerDoubleTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerDoubleTap(_:)))
        twoFingerDoubleTap.numberOfTapsRequired = 2
        twoFingerDoubleTap.numberOfTouchesRequired = 2
        twoFingerDoubleTap.delegate = self
        addGestureRecognizer(twoFingerDoubleTap)
        
        // Set initial camera
        syncCamera()
    }
    
    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        onDoubleTap?()
    }
    
    @objc private func handleTwoFingerDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard let sim = renderer?.simulation else { return }
        // Align all balls to random X or Y axis, preserving speed
        for i in 0..<sim.rainBalls.count {
            let speed = length(sim.rainBalls[i].vel)
            guard speed > 0 else { continue }
            let useX = Bool.random()
            if useX {
                // Align to X axis: keep sign of x velocity
                let sign: Float = sim.rainBalls[i].vel.x >= 0 ? 1 : -1
                sim.rainBalls[i].vel = SIMD2(sign * speed, 0)
            } else {
                // Align to Y axis: keep sign of y velocity
                let sign: Float = sim.rainBalls[i].vel.y >= 0 ? 1 : -1
                sim.rainBalls[i].vel = SIMD2(0, sign * speed)
            }
        }
    }
    
    // Allow all gestures to work simultaneously
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return true
    }
    
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil && displayLink == nil {
            lastInertiaTime = CACurrentMediaTime()
            let link = CADisplayLink(target: self, selector: #selector(inertiaUpdate(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if window == nil {
            displayLink?.invalidate()
            displayLink = nil
        }
    }
    
    @objc private func inertiaUpdate(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = Float(now - lastInertiaTime)
        lastInertiaTime = now
        
        let lpp = renderer?.simulation.longPressProgress ?? 0
        let pressing = renderer?.simulation.longPressActive ?? false
        
        if camera.update(dt: dt, longPressProgress: lpp, longPressActive: pressing) {
            syncCamera()
        }
    }
    
    /// Set camera distance externally (e.g. VIEW mode)
    func setCameraDistance(_ dist: Float) {
        camera.setCameraDistance(dist)
        renderer?.cameraDistance = dist
        renderer?.baseCameraDistance = dist
    }
    
    /// Lock/unlock camera rotation (LINES mode). Snaps to next sequential axis when locking.
    func setCameraLocked(_ locked: Bool) {
        guard locked != camera.isLocked else { return }
        if locked {
            camera.snapToNextAxis()
        } else {
            camera.advanceAxisIndex()
        }
        camera.isLocked = locked
    }
    
    /// Force camera to front view and lock (for DRAW mode)
    func lockCameraToFront() {
        guard !camera.isLocked else { return }
        camera.snapToFront()
        renderer?.cameraDistance = 3.0
        renderer?.baseCameraDistance = 3.0
    }
    
    // MARK: - Pan gesture (camera orbit)
    
    // Track swipe start for RAIN block creation
    private var rainSwipeStart: CGPoint?
    
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        // DRAW mode: capture path instead of rotating camera
        if renderer?.simulation.isDrawingMode == true {
            handleDrawInput(gesture)
            return
        }
        
        // RAIN mode: pan creates blocks instead of rotating camera
        if renderer?.simulation.orbitPattern == .polygon {
            handleRainSwipe(gesture)
            return
        }
        
        switch gesture.state {
        case .began:
            camera.panBegan()
            
        case .changed:
            let translation = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            if camera.panChanged(dx: Float(translation.x), dy: Float(translation.y)) {
                syncCamera()
            }
            
        case .ended, .cancelled:
            camera.panEnded()
            
        default:
            break
        }
    }
    
    private func handleRainSwipe(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)
        
        switch gesture.state {
        case .began:
            rainSwipeStart = location
            
        case .changed:
            guard let start = rainSwipeStart else { return }
            let startNorm = SIMD2<Float>(
                Float(start.x / bounds.width),
                Float(start.y / bounds.height)
            )
            let currentNorm = SIMD2<Float>(
                Float(location.x / bounds.width),
                Float(location.y / bounds.height)
            )
            let minX = min(startNorm.x, currentNorm.x)
            let minY = min(startNorm.y, currentNorm.y)
            let w = abs(currentNorm.x - startNorm.x)
            let h = abs(currentNorm.y - startNorm.y)
            renderer?.simulation.rainPendingBlock = SIMD4<Float>(minX, minY, max(w, 0.01), max(h, 0.01))
            
        case .ended, .cancelled:
            if let pending = renderer?.simulation.rainPendingBlock {
                // Minimum size threshold to avoid accidental tiny blocks
                if pending.z > 0.02 || pending.w > 0.02 {
                    let note = renderer?.rainRandomNoteForBlock() ?? (midiNote: 60, noteName: "")
                    var block = RainBlock(rect: pending)
                    block.midiNote = note.midiNote
                    block.noteName = note.noteName
                    renderer?.simulation.rainBlocks.append(block)
                }
            }
            renderer?.simulation.rainPendingBlock = nil
            rainSwipeStart = nil
            
        default:
            break
        }
    }
    
    // MARK: - DRAW mode touch input
    
    private func handleDrawInput(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)
        let normalized = SIMD2<Float>(
            Float(location.x / bounds.width),
            Float(location.y / bounds.height)
        )
        
        switch gesture.state {
        case .began:
            // Add a break marker (NaN) to separate strokes, then start new stroke
            if !(renderer?.simulation.drawPath.isEmpty ?? true) {
                renderer?.simulation.drawPath.append(SIMD2<Float>(Float.nan, Float.nan))
            }
            renderer?.simulation.drawPath.append(normalized)
            
        case .changed:
            guard let sim = renderer?.simulation else { return }
            if let last = sim.drawPath.last {
                // Skip distance check if last point was a stroke break (NaN)
                let isNewStroke = last.x.isNaN
                let dx = normalized.x - last.x
                let dy = normalized.y - last.y
                let dist = sqrt(dx * dx + dy * dy)
                if isNewStroke || dist > 0.005 {
                    renderer?.simulation.drawPath.append(normalized)
                    // Add preview segment (skip if starting a new stroke)
                    if !isNewStroke {
                        let from = SIMD3<Float>((last.x - 0.5) * 0.6, (0.5 - last.y) * 0.6, 0)
                        let to = SIMD3<Float>((normalized.x - 0.5) * 0.6, (0.5 - normalized.y) * 0.6, 0)
                        let center = SIMD3<Float>(0.5, 0.5, 0.5)
                        let seg = LineSegment(
                            start: center + from,
                            end: center + to,
                            color: SIMD4<Float>(1, 1, 1, 0.4),
                            progress: 1.0,
                            drawSpeed: 1.0,
                            hueT: 0
                        )
                        renderer?.simulation.accumulatedLines.append(seg)
                    }
                }
            }
            
        case .ended, .cancelled:
            break  // Path finalized when user taps OK
            
        default:
            break
        }
    }
    
    // MARK: - Pinch gesture (camera zoom)
    
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        // RAIN mode / DRAW mode: no zoom
        if renderer?.simulation.orbitPattern == .polygon { return }
        if renderer?.simulation.isDrawingMode == true { return }
        
        switch gesture.state {
        case .changed:
            // LINE/PCD mode allows camera all the way to the orbit origin
            let orbitPat = renderer?.simulation.orbitPattern
            let isTrailMode = orbitPat == .lines
            let minDist: Float = isTrailMode ? 0.1 : 3.0
            let dist = camera.applyZoom(scale: Float(gesture.scale), minDistance: minDist)
            renderer?.cameraDistance = dist
            renderer?.baseCameraDistance = dist
            gesture.scale = 1.0
            onPinchDistance?(dist)
            
        default:
            break
        }
    }
    
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        // RAIN mode: long press toggles pause/resume
        if renderer?.simulation.orbitPattern == .polygon {
            if gesture.state == .began {
                renderer?.simulation.rainPaused.toggle()
            }
            return
        }
        
        // DRAW mode: ignore long press (camera must stay locked to front)
        if renderer?.simulation.isDrawingMode == true { return }
        
        // LINES / POINT CLOUD mode: long press cycles through 6 axis views
        // LP → lock(front) → LP → unlock → LP → lock(right) → LP → unlock → ...
        if renderer?.simulation.orbitPattern == .lines {
            if gesture.state == .began {
                if camera.isLocked {
                    // Currently locked → unlock and advance to next axis for next lock
                    camera.isLocked = false
                    camera.advanceAxisIndex()
                    camera.nudgeRandom()
                    onCameraLockChanged?(false)
                } else {
                    // Currently unlocked → snap to current axis and lock
                    camera.snapToNextAxis()
                    camera.isLocked = true
                    onCameraLockChanged?(true)
                }
            }
            return
        }
        
        switch gesture.state {
        case .began:
            camera.longPressBegan()
            renderer?.simulation.longPressActive = true
        case .ended, .cancelled, .failed:
            camera.longPressEnded()
            renderer?.simulation.longPressActive = false
        default:
            break
        }
    }
    
    // MARK: - Raw touches for metaball interaction (multi-touch)
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        if renderer?.simulation.orbitPattern == .polygon { return }
        let allTouches = event?.allTouches ?? touches
        if allTouches.count >= 2 {
            touchHandler.touchesBegan(touches, in: self)
            updateTouchPoints()
        }
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        if renderer?.simulation.orbitPattern == .polygon { return }
        let allTouches = event?.allTouches ?? touches
        if allTouches.count >= 2 {
            touchHandler.touchesMoved(touches, in: self)
            updateTouchPoints()
        }
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        touchHandler.touchesEnded(touches, in: self)
        updateTouchPoints()
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        touchHandler.touchesCancelled(touches, in: self)
        updateTouchPoints()
    }
    
    private func updateTouchPoints() {
        renderer?.simulation.touchPoints = touchHandler.getTouchPoints(viewSize: bounds.size)
    }
}
