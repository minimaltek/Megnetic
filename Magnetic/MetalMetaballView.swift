//
//  MetalMetaballView.swift
//  Magnetic
//
//  MetalKit-based view for rendering metaballs via 3D Ray Marching
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
    var envMapIndex: Int = 0
    var envIntensity: Double = 1.0
    var customEnvImages: [UIImage?] = [nil, nil, nil]
    /// Incremented each time a new custom image is picked (per slot)
    var customEnvImageVersions: [Int] = [0, 0, 0]
    /// AudioEngine reference for direct audio data bridging (avoids SwiftUI onChange overhead)
    var audioEngine: AudioEngine? = nil
    var isBPMEnabled: Bool = true
    var bgMode: Int = 0
    var bgColor: (Float, Float, Float) = (0, 0, 0)  // custom background RGB
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
        context.coordinator.envMapIndex = UInt32(envMapIndex)
        context.coordinator.envIntensity = Float(envIntensity)
        context.coordinator.audioEngine = audioEngine
        context.coordinator.isBPMEnabled = isBPMEnabled
        context.coordinator.bgMode = UInt32(bgMode)
        context.coordinator.bgColor = bgColor
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
            (uiView as TouchableMTKView).setCameraDistance(viewDist)
        }
        // Load custom env textures when a new image is picked (version changed)
        for i in 0..<3 {
            if let image = customEnvImages[i],
               context.coordinator.loadedCustomEnvVersions[i] != customEnvImageVersions[i] {
                context.coordinator.loadCustomEnvTexture(from: image, slot: i)
                context.coordinator.loadedCustomEnvVersions[i] = customEnvImageVersions[i]
            }
        }
        // Only set isPaused when it actually changes — setting it repeatedly
        // can restart MTKView's internal display link timer, preventing draws.
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
        
        // Notify parent of renderer reference
        onRendererReady?(context.coordinator)
    }
}

// MARK: - Touchable MTKView with camera orbit + metaball touch

final class TouchableMTKView: MTKView, UIGestureRecognizerDelegate {
    weak var renderer: MetaballRenderer?
    private let touchHandler = TouchHandler()
    var onDoubleTap: (() -> Void)?
    var onPinchDistance: ((Float) -> Void)?
    
    // Long-press zoom: camera zooms in + orbit shrinks while held
    private(set) var isLongPressing = false
    private var longPressBaseCameraDistance: Float = 3.0  // saved on press start
    
    // Long-press spin: figure-skater effect
    private var longPressSpinAxis: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
    private var longPressWasActive: Bool = false
    private var longPressSpinSpeed: Float = 0  // persists after release
    
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
    
    // Camera orbit: pure quaternion with local-axis rotation
    // Rotations are applied around the camera's own local axes,
    // enabling full spherical orbit with no gimbal lock or clamping.
    private var cameraOrientation: simd_quatf = simd_quatf(angle: 0.3, axis: SIMD3<Float>(1, 0, 0))
    private var cameraDistance: Float = 3.0
    
    // Inertia: angular velocity as screen-space dx/dy (radians/sec)
    private var angularVelocityX: Float = 0  // horizontal screen velocity
    private var angularVelocityY: Float = 0  // vertical screen velocity
    private var inertiaStartTime: CFTimeInterval = 0
    private var initialAngularVelocityX: Float = 0
    private var initialAngularVelocityY: Float = 0
    private let minVelocity: Float = 0.0005
    
    // Pan gesture tracking
    private var lastPanTime: CFTimeInterval = 0
    private var isDragging = false
    
    // Display link for inertia updates
    private var displayLink: CADisplayLink?
    
    // Gesture recognizers
    private var panGesture: UIPanGestureRecognizer!
    private var pinchGesture: UIPinchGestureRecognizer!
    private var longPressGesture: UILongPressGestureRecognizer!
    
    /// Apply incremental rotation around camera's LOCAL axes.
    /// dx/dy are in screen-space radians (from swipe gesture).
    private func applyRotation(dx: Float, dy: Float) {
        // Get the camera's local axes from the current orientation
        let rotMatrix = simd_matrix3x3(cameraOrientation)
        let localRight = SIMD3<Float>(rotMatrix.columns.0.x, rotMatrix.columns.0.y, rotMatrix.columns.0.z)
        let localUp = SIMD3<Float>(rotMatrix.columns.1.x, rotMatrix.columns.1.y, rotMatrix.columns.1.z)
        
        // Horizontal swipe → rotate around camera's local UP axis
        let rotH = simd_quatf(angle: -dx, axis: localUp)
        // Vertical swipe → rotate around camera's local RIGHT axis
        // (positive dy = swipe down → pitch increases = look down, as user requested)
        let rotV = simd_quatf(angle: dy, axis: localRight)
        
        cameraOrientation = simd_normalize(rotH * rotV * cameraOrientation)
    }
    
    /// Push current orientation to renderer
    private func syncCamera() {
        renderer?.cameraOrientation = cameraOrientation
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
        longPressGesture.minimumPressDuration = 0.4
        longPressGesture.numberOfTouchesRequired = 1
        longPressGesture.delegate = self
        longPressGesture.allowableMovement = 10  // allow slight finger drift
        addGestureRecognizer(longPressGesture)
        
        // Set initial camera
        syncCamera()
    }
    
    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        onDoubleTap?()
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
    
    private var lastInertiaTime: CFTimeInterval = 0
    
    @objc private func inertiaUpdate(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = Float(now - lastInertiaTime)
        lastInertiaTime = now
        let clampedDt = min(dt, 0.1)
        
        var needsSync = false
        
        // --- Swipe inertia (only when not dragging) ---
        if !isDragging {
            let speed = abs(initialAngularVelocityX) + abs(initialAngularVelocityY)
            if speed > minVelocity {
                let elapsed = Float(now - inertiaStartTime)
                let tau: Float = 15.0
                let factor = 1.0 / ((1.0 + elapsed / tau) * (1.0 + elapsed / tau))
                
                angularVelocityX = initialAngularVelocityX * factor
                angularVelocityY = initialAngularVelocityY * factor
                
                let currentSpeed = abs(angularVelocityX) + abs(angularVelocityY)
                if currentSpeed < minVelocity {
                    angularVelocityX = 0
                    angularVelocityY = 0
                    initialAngularVelocityX = 0
                    initialAngularVelocityY = 0
                } else {
                    applyRotation(dx: angularVelocityX * clampedDt, dy: angularVelocityY * clampedDt)
                    needsSync = true
                }
            }
        }
        
        // --- Long-press spin: adds on top of existing inertia ---
        let lpp = renderer?.simulation.longPressProgress ?? 0
        let pressing = renderer?.simulation.longPressActive ?? false
        
        if pressing && !longPressWasActive {
            // New press — spin in the SAME direction as existing inertia
            let currentInertia = sqrt(angularVelocityX * angularVelocityX + angularVelocityY * angularVelocityY)
            if currentInertia > 0.01 {
                // Build combined axis from camera-local axes weighted by angular velocities
                let rotMatrix = simd_matrix3x3(cameraOrientation)
                let localUp = SIMD3<Float>(rotMatrix.columns.1.x, rotMatrix.columns.1.y, rotMatrix.columns.1.z)
                let localRight = SIMD3<Float>(rotMatrix.columns.0.x, rotMatrix.columns.0.y, rotMatrix.columns.0.z)
                // Horizontal swipe (angularVelocityX) rotates around localUp with negative sign
                // Vertical swipe (angularVelocityY) rotates around localRight with positive sign
                let combined = -angularVelocityX * localUp + angularVelocityY * localRight
                let len = length(combined)
                if len > 0.001 {
                    longPressSpinAxis = combined / len
                } else {
                    longPressSpinAxis = Bool.random() ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
                }
                // Start from current inertia speed — seamless transition
                longPressSpinSpeed = max(longPressSpinSpeed, currentInertia)
            } else {
                // No existing spin → random axis
                longPressSpinAxis = Bool.random()
                    ? SIMD3<Float>(0, 1, 0)
                    : SIMD3<Float>(1, 0, 0)
                longPressSpinSpeed = max(longPressSpinSpeed, 0.0)
            }
        }
        longPressWasActive = pressing
        
        if pressing {
            // Continuously accelerate while held — no speed cap
            let accel: Float = 3.0  // rad/s² — steady acceleration
            longPressSpinSpeed += accel * clampedDt
        } else if longPressSpinSpeed > 0.001 {
            // Released — very slow deceleration, like a spinning top winding down
            // Same feel as swipe inertia: spins for a long time after release
            let decay: Float = 0.15  // lose 15% per second → ~6-8s to fully stop
            longPressSpinSpeed *= (1.0 - decay * clampedDt)
            if longPressSpinSpeed < 0.05 {
                longPressSpinSpeed = 0
            }
        }
        
        if abs(longPressSpinSpeed) > 0.001 {
            let spinAngle = longPressSpinSpeed * clampedDt
            let spinQuat = simd_quatf(angle: spinAngle, axis: longPressSpinAxis)
            cameraOrientation = simd_normalize(spinQuat * cameraOrientation)
            needsSync = true
        }
        
        if needsSync {
            syncCamera()
        }
    }
    
    /// Set camera distance externally (e.g. VIEW mode)
    func setCameraDistance(_ dist: Float) {
        cameraDistance = dist
        renderer?.cameraDistance = dist
        renderer?.baseCameraDistance = dist
    }
    
    // MARK: - Pan gesture (camera orbit)
    
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let now = CACurrentMediaTime()
        
        switch gesture.state {
        case .began:
            isDragging = true
            angularVelocityX = 0
            angularVelocityY = 0
            initialAngularVelocityX = 0
            initialAngularVelocityY = 0
            lastPanTime = now
            
        case .changed:
            // Skip camera orbit while long-pressing (spin handles rotation)
            guard !isLongPressing else {
                gesture.setTranslation(.zero, in: self)
                lastPanTime = now
                return
            }
            let translation = gesture.translation(in: self)
            let dx = Float(translation.x)
            let dy = Float(translation.y)
            gesture.setTranslation(.zero, in: self)
            
            let sensitivity: Float = 0.006
            let rotDx = dx * sensitivity
            let rotDy = dy * sensitivity
            
            // Apply rotation around camera's local axes (no clamping needed)
            applyRotation(dx: rotDx, dy: rotDy)
            syncCamera()
            
            // Track velocity for inertia (in screen-space radians/sec)
            let dt = Float(now - lastPanTime)
            if dt > 0.001 {
                angularVelocityX = rotDx / dt
                angularVelocityY = rotDy / dt
            }
            lastPanTime = now
            
        case .ended, .cancelled:
            initialAngularVelocityX = angularVelocityX
            initialAngularVelocityY = angularVelocityY
            inertiaStartTime = CACurrentMediaTime()
            isDragging = false
            
        default:
            break
        }
    }
    
    // MARK: - Pinch gesture (camera zoom)
    
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .changed:
            let scale = Float(gesture.scale)
            cameraDistance /= scale
            cameraDistance = max(3.0, min(8.0, cameraDistance))
            renderer?.cameraDistance = cameraDistance
            renderer?.baseCameraDistance = cameraDistance
            gesture.scale = 1.0  // Reset to get incremental scale
            onPinchDistance?(cameraDistance)
            
        default:
            break
        }
    }
    
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            isLongPressing = true
            longPressBaseCameraDistance = cameraDistance
            renderer?.simulation.longPressActive = true
        case .ended, .cancelled, .failed:
            isLongPressing = false
            renderer?.simulation.longPressActive = false
        default:
            break
        }
    }
    
    // MARK: - Raw touches for metaball interaction (multi-touch)
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        let allTouches = event?.allTouches ?? touches
        if allTouches.count >= 2 {
            touchHandler.touchesBegan(touches, in: self)
            updateTouchPoints()
        }
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
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

// MARK: - Renderer

final class MetaballRenderer: NSObject, MTKViewDelegate {
    
    var simulation: MetaballSimulation
    
    // Camera state (set by TouchableMTKView)
    var cameraOrientation = simd_quatf(angle: 0.3, axis: SIMD3<Float>(1, 0, 0))
    var cameraDistance: Float = 3.0
    var baseCameraDistance: Float = 3.0  // user's pinch-set distance (before long-press zoom)
    
    
    
    // Console stats callback (throttled to ~10Hz)
    var onConsoleUpdate: ((Float, Float) -> Void)?
    private var lastConsoleUpdate: CFTimeInterval = 0
    
    // Material state (set by SwiftUI)
    var materialMode: UInt32 = 0
    var colorHue: Float = 0
    var envMapIndex: UInt32 = 0
    var envIntensity: Float = 1.0
    var bgMode: UInt32 = 0
    var bgColor: (Float, Float, Float) = (0, 0, 0)
    var envLocked: UInt32 = 0
    var blendK: Float = 0.35
    var autoHue: Bool = false
    var fps: Int = 30
    var manualBPM: Float = 120
    private var autoHueValue: Float = 0  // 0..1, cycles slowly
    private var manualBeatPhase: Double = 0  // 0..1, cycles at manual BPM rate
    
    // Mic-driven brightness boost (ramps up on orange/red input levels, decays on green)
    private var micBrightnessBoost: Float = 1.0
    
    // Audio bridge (direct read, bypasses SwiftUI onChange)
    weak var audioEngine: AudioEngine?
    var isBPMEnabled: Bool = true
    var brightnessSync: Bool = false
    var brightnessSyncMax: Float = 3.0
    
    // Screenshot capture (one-shot: set completion, next frame captures, then clears)
    var screenshotCompletion: ((UIImage?) -> Void)?
    
    // Video recording
    private var videoRecorder: VideoRecorder?
    var isRecording: Bool { videoRecorder?.state == .recording }
    var onRecordingFinished: ((Bool) -> Void)?
    
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var renderPipeline: MTLRenderPipelineState!
    
    private var ballBuffer: MTLBuffer!
    private var paramsBuffer: MTLBuffer!
    
    // HDRI environment textures
    private var envTextures: [MTLTexture] = []
    private var envSamplerState: MTLSamplerState!
    // 1x1 black fallback texture for when no HDRI is selected
    private var fallbackTexture: MTLTexture!
    // User-selected custom environment textures (from Photos) — 3 slots
    var customEnvTextures: [MTLTexture?] = [nil, nil, nil]
    var loadedCustomEnvVersions: [Int] = [-1, -1, -1]
    
    private var lastTime: CFTimeInterval = 0
    
    init(simulation: MetaballSimulation) {
        self.simulation = simulation
        super.init()
    }
    
    func setup(mtkView: MTKView) {
        guard let device = mtkView.device else { return }
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        
        guard let library = device.makeDefaultLibrary() else {
            print("Failed to load Metal library")
            return
        }
        
        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        pipelineDesc.fragmentFunction = library.makeFunction(name: "metaballFragment")
        pipelineDesc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        
        renderPipeline = try? device.makeRenderPipelineState(descriptor: pipelineDesc)
        
        let maxBalls = 64  // supports up to 64 balls (SAT doubles the count)
        ballBuffer = device.makeBuffer(length: maxBalls * MemoryLayout<Ball>.stride, options: .storageModeShared)
        paramsBuffer = device.makeBuffer(length: MemoryLayout<SimParams>.stride, options: .storageModeShared)
        
        // Load HDRI environment textures
        loadEnvironmentTextures(device: device)
        
        lastTime = CACurrentMediaTime()
    }
    
    private func loadEnvironmentTextures(device: MTLDevice) {
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue
        ]
        
        let hdriFiles: [(name: String, ext: String)] = [
            ("hdri_studio", "jpg"), ("hdri_loft", "jpg"), ("hdri_sunset", "jpg"),
            ("hdri_sky", "jpg"), ("hdri_garden", "jpg"),
            ("hdri_studio2", "hdr"), ("hdri_studio3", "hdr"),
            ("hdri_cloudy", "hdr"), ("hdri_morning", "hdr"), ("hdri_suburb", "hdr"),
            ("2k_moon", "jpg"), ("flat_earth03", "jpg")
        ]
        
        for file in hdriFiles {
            if let url = Bundle.main.url(forResource: file.name, withExtension: file.ext),
               let texture = try? loader.newTexture(URL: url, options: options) {
                envTextures.append(texture)
            } else {
                print("Failed to load HDRI: \(file.name).\(file.ext)")
            }
        }
        
        // Create sampler for HDRI sampling
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .repeat      // wrap horizontally
        samplerDesc.tAddressMode = .clampToEdge // clamp vertically
        envSamplerState = device.makeSamplerState(descriptor: samplerDesc)
        
        // Create 1x1 black fallback texture
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false
        )
        texDesc.usage = .shaderRead
        fallbackTexture = device.makeTexture(descriptor: texDesc)
        var black: [UInt8] = [0, 0, 0, 255]
        fallbackTexture?.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &black,
            bytesPerRow: 4
        )
    }
    
    /// Load a UIImage as a Metal texture for use as custom environment map
    func loadCustomEnvTexture(from image: UIImage, slot: Int) {
        guard let device = device,
              let cgImage = image.cgImage,
              slot >= 0 && slot < 3 else { return }
        
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue
        ]
        
        if let texture = try? loader.newTexture(cgImage: cgImage, options: options) {
            customEnvTextures[slot] = texture
        }
    }
    
    func startRecording(drawableSize: CGSize) {
        guard let device = device, videoRecorder == nil else { return }
        let recorder = VideoRecorder()
        recorder.onRecordingFinished = { [weak self] result in
            let success: Bool
            switch result {
            case .success: success = true
            case .failure: success = false
            }
            self?.videoRecorder = nil
            self?.onRecordingFinished?(success)
        }
        self.videoRecorder = recorder
        recorder.startRecording(
            device: device,
            width: Int(drawableSize.width),
            height: Int(drawableSize.height),
            fps: fps
        )
    }
    
    func stopRecording() {
        videoRecorder?.stopRecording()
    }
    
    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    
    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            performDraw(in: view)
        }
    }
    
    private func performDraw(in view: MTKView) {
        let now = CACurrentMediaTime()
        var dt = Float(now - lastTime)
        lastTime = now
        
        // Guard against bad dt (first frame, large gap, or negative)
        if !dt.isFinite || dt <= 0 || dt > 1.0 {
            dt = 1.0 / 30.0
        }
        
        // Bridge audio data directly from AudioEngine (bypasses SwiftUI onChange overhead)
        if let audio = audioEngine {
            simulation.bassEnergy = audio.bassEnergy
            simulation.midEnergy = audio.midEnergy
            simulation.highEnergy = audio.highEnergy
            simulation.inputLevel = audio.inputLevel
            simulation.reactivity = audio.effectiveGain
            if isBPMEnabled {
                simulation.predictedBeatPulse = audio.predictedBeatPulse
                simulation.detectedBPM = audio.detectedBPM
            } else if manualBPM > 0 {
                let bps = Double(manualBPM) / 60.0
                manualBeatPhase += bps * Double(dt)
                manualBeatPhase = manualBeatPhase.truncatingRemainder(dividingBy: 1.0)
                simulation.predictedBeatPulse = manualBeatPhase < 0.1 ? Float(1.0 - manualBeatPhase / 0.1) : 0
                simulation.detectedBPM = manualBPM
            } else {
                simulation.predictedBeatPulse = 0
                simulation.detectedBPM = 0
            }
        } else {
            // Mic is OFF — manual BPM still drives orbit speed and beat pulse
            if !isBPMEnabled && manualBPM > 0 {
                let bps = Double(manualBPM) / 60.0
                manualBeatPhase += bps * Double(dt)
                manualBeatPhase = manualBeatPhase.truncatingRemainder(dividingBy: 1.0)
                simulation.predictedBeatPulse = manualBeatPhase < 0.1 ? Float(1.0 - manualBeatPhase / 0.1) : 0
                simulation.detectedBPM = manualBPM
            } else {
                // Default BPM so orbits still move at reference speed
                simulation.detectedBPM = manualBPM > 0 ? manualBPM : 120
            }
        }
        
        // Mic-driven brightness boost: ramp up on orange/red input, decay on green
        if audioEngine != nil && brightnessSync {
            let level = simulation.inputLevel
            if level > 0.8 {
                // Red zone: fast ramp up
                micBrightnessBoost += 2.0 * dt
            } else if level > 0.5 {
                // Orange zone: slow ramp up
                micBrightnessBoost += 0.5 * dt
            } else {
                // Green zone: decay back to 1.0
                micBrightnessBoost += (1.0 - micBrightnessBoost) * 2.0 * dt
            }
            // Clamp to reasonable range
            micBrightnessBoost = min(max(micBrightnessBoost, 1.0), brightnessSyncMax)
        } else {
            micBrightnessBoost = 1.0
        }
        
        // Auto hue: slowly cycle through all colors (~30s per full rotation)
        if autoHue {
            autoHueValue += dt / 30.0  // full cycle in 30 seconds
            if autoHueValue > 1.0 { autoHueValue -= 1.0 }
        }
        
        // Clamp dt to avoid large jumps (e.g. after unpause)
        simulation.update(dt: min(dt, 1.0 / 15.0))
        
        // Long-press camera zoom: pull camera OUT so balls appear as a small cluster
        // Smoothstep ease-in-out: gentle start, gentle finish
        let lpp = simulation.longPressProgress
        if lpp > 0 {
            let eased = lpp * lpp * (3.0 - 2.0 * lpp)  // smoothstep
            let zoomTarget = min(baseCameraDistance * 4.667, 14.0)  // max 14.0
            cameraDistance = baseCameraDistance + (zoomTarget - baseCameraDistance) * eased
        } else {
            cameraDistance = baseCameraDistance
        }
        
        // Report stats to console (~10Hz to avoid SwiftUI overhead)
        if now - lastConsoleUpdate > 0.1 {
            lastConsoleUpdate = now
            onConsoleUpdate?(cameraDistance, simulation.longPressProgress)
        }
        
        // Upload ball data (NaN validation handled in MetaballSimulation.update)
        let ballCount = simulation.balls.count
        simulation.balls.withUnsafeBufferPointer { ptr in
            memcpy(ballBuffer.contents(), ptr.baseAddress!, ballCount * MemoryLayout<Ball>.stride)
        }
        
        // Upload params with camera
        let aspect = Float(view.drawableSize.width / view.drawableSize.height)
        let m = simd_matrix3x3(cameraOrientation)
        var params = SimParams(
            time: simulation.time,
            bassEnergy: simulation.bassEnergy,
            midEnergy: simulation.midEnergy,
            highEnergy: simulation.highEnergy,
            ballCount: UInt32(simulation.balls.count),
            gridWidth: 0,
            gridHeight: 0,
            threshold: 1.0,
            screenAspect: aspect,
            touchCount: 0,
            animSpeed: simulation.animSpeed,
            camR0: m.columns.0.x, camR1: m.columns.0.y, camR2: m.columns.0.z,
            camU0: m.columns.1.x, camU1: m.columns.1.y, camU2: m.columns.1.z,
            camF0: m.columns.2.x, camF1: m.columns.2.y, camF2: m.columns.2.z,
            cameraDistance: cameraDistance,
            materialMode: materialMode,
            colorHue: autoHue ? autoHueValue : colorHue,
            envMapIndex: envMapIndex,
            envIntensity: envIntensity * micBrightnessBoost,
            bgMode: bgMode,
            bgR: bgColor.0,
            bgG: bgColor.1,
            bgB: bgColor.2,
            envLocked: envLocked,
            blendK: blendK
        )
        memcpy(paramsBuffer.contents(), &params, MemoryLayout<SimParams>.size)
        
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        
        if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
            renderEncoder.setRenderPipelineState(renderPipeline)
            renderEncoder.setFragmentBuffer(ballBuffer, offset: 0, index: 0)
            renderEncoder.setFragmentBuffer(paramsBuffer, offset: 0, index: 1)
            
            // Bind HDRI texture (or fallback)
            let texIndex = Int(envMapIndex)
            if texIndex >= 13 && texIndex <= 15,
               let customTex = customEnvTextures[texIndex - 13] {
                // Custom photo environment (slot 0-2)
                renderEncoder.setFragmentTexture(customTex, index: 0)
            } else if texIndex > 0 && texIndex <= envTextures.count {
                renderEncoder.setFragmentTexture(envTextures[texIndex - 1], index: 0)
            } else {
                renderEncoder.setFragmentTexture(fallbackTexture, index: 0)
            }
            renderEncoder.setFragmentSamplerState(envSamplerState, index: 0)
            
            renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            renderEncoder.endEncoding()
        }
        
        // Video recording: blit drawable to capture texture
        if let recorder = videoRecorder, recorder.state == .recording {
            recorder.captureFrame(commandBuffer: commandBuffer, sourceTexture: drawable.texture)
        }
        
        // Screenshot capture: blit drawable to shared texture, read pixels on completion
        if let completion = screenshotCompletion {
            screenshotCompletion = nil
            let srcTexture = drawable.texture
            let w = srcTexture.width
            let h = srcTexture.height
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false
            )
            desc.storageMode = .shared
            desc.usage = [.shaderRead]
            if let sharedTex = device.makeTexture(descriptor: desc) {
                if let blit = commandBuffer.makeBlitCommandEncoder() {
                    blit.copy(from: srcTexture, sourceSlice: 0, sourceLevel: 0,
                              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                              sourceSize: MTLSize(width: w, height: h, depth: 1),
                              to: sharedTex, destinationSlice: 0, destinationLevel: 0,
                              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                    blit.endEncoding()
                }
                commandBuffer.addCompletedHandler { _ in
                    let bytesPerRow = 4 * w
                    let totalBytes = bytesPerRow * h
                    var pixelData = [UInt8](repeating: 0, count: totalBytes)
                    sharedTex.getBytes(&pixelData, bytesPerRow: bytesPerRow,
                                       from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                                       size: MTLSize(width: w, height: h, depth: 1)),
                                       mipmapLevel: 0)
                    // BGRA → RGBA
                    for i in stride(from: 0, to: totalBytes, by: 4) {
                        let b = pixelData[i]
                        pixelData[i] = pixelData[i + 2]
                        pixelData[i + 2] = b
                    }
                    let colorSpace = CGColorSpaceCreateDeviceRGB()
                    if let context = CGContext(data: &pixelData, width: w, height: h,
                                              bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                              space: colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                       let cgImage = context.makeImage() {
                        let image = UIImage(cgImage: cgImage)
                        DispatchQueue.main.async { completion(image) }
                    } else {
                        DispatchQueue.main.async { completion(nil) }
                    }
                }
            } else {
                DispatchQueue.main.async { completion(nil) }
            }
        }
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
