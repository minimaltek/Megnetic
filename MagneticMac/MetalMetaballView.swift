//
//  MetalMetaballView.swift
//  MagneticMac
//
//  macOS-specific MetalKit view: NSViewRepresentable wrapper + InteractiveMTKView.
//  Uses shared MetaballRenderer and CameraController.
//

#if os(macOS)
import SwiftUI
import MetalKit
import simd
import AppKit

// MARK: - SwiftUI Wrapper

struct MetalMetaballView: NSViewRepresentable {
    @Binding var simulation: MetaballSimulation
    var isPaused: Bool = false
    var materialMode: Int = 0
    var colorHue: Double = 0
    var colorBri: Double = 0.9
    var envMapIndex: Int = 0
    var envIntensity: Double = 1.0
    var customEnvImages: [PlatformImage?] = [nil, nil, nil]
    var customEnvImageVersions: [Int] = [0, 0, 0]
    var audioEngine: AudioEngine? = nil
    var isBPMEnabled: Bool = true
    var bgMode: Int = 0
    var bgColor: (Float, Float, Float) = (0, 0, 0)
    var autoBgHue: Bool = false
    var bgCustomHue: Double = 0.6
    var bgCustomSat: Double = 0.8
    var bgCustomBri: Double = 0.5
    var envLocked: Int = 0
    var blendK: Double = 0.35
    var autoHue: Bool = false
    var fps: Int = 30
    var manualBPM: Double = 120
    var brightnessSync: Bool = false
    var brightnessSyncMax: Double = 3.0
    var onDoubleTap: (() -> Void)? = nil
    var viewCameraDistance: Float? = nil
    var onPinchDistance: ((Float) -> Void)? = nil
    @Binding var isRecording: Bool
    var onRecordingFinished: ((Bool) -> Void)? = nil
    var onRendererReady: ((MetaballRenderer) -> Void)? = nil
    var onConsoleUpdate: ((Float, Float) -> Void)? = nil
    /// When true, camera rotation is locked (LINES mode)
    var linesCameraLocked: Bool = false
    var onCameraLockChanged: ((Bool) -> Void)? = nil
    
    func makeCoordinator() -> MetaballRenderer {
        MetaballRenderer(simulation: simulation)
    }
    
    func makeNSView(context: Context) -> InteractiveMTKView {
        let mtkView = InteractiveMTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.delegate = context.coordinator
        mtkView.preferredFramesPerSecond = fps
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        mtkView.framebufferOnly = false
        
        // Render at native resolution on macOS (Retina)
        if let screen = NSScreen.main {
            mtkView.layer?.contentsScale = screen.backingScaleFactor
        }
        
        mtkView.renderer = context.coordinator
        mtkView.onDoubleTap = onDoubleTap
        mtkView.onPinchDistance = onPinchDistance
        mtkView.setupGestures()
        context.coordinator.setup(mtkView: mtkView)
        
        return mtkView
    }
    
    func updateNSView(_ nsView: InteractiveMTKView, context: Context) {
        nsView.onDoubleTap = onDoubleTap
        nsView.onPinchDistance = onPinchDistance
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
        if nsView.preferredFramesPerSecond != fps {
            nsView.preferredFramesPerSecond = fps
        }
        switch bgMode {
        case 0:
            nsView.clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        case 2:
            nsView.clearColor = MTLClearColor(red: 0, green: 1, blue: 0, alpha: 1)
        case 3:
            nsView.clearColor = MTLClearColor(red: Double(bgColor.0), green: Double(bgColor.1), blue: Double(bgColor.2), alpha: 1)
        default:
            nsView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        }
        if let viewDist = viewCameraDistance {
            context.coordinator.cameraDistance = viewDist
            nsView.setCameraDistance(viewDist)
        }
        for i in 0..<3 {
            if let image = customEnvImages[i],
               context.coordinator.loadedCustomEnvVersions[i] != customEnvImageVersions[i] {
                context.coordinator.loadCustomEnvTexture(from: image, slot: i)
                context.coordinator.loadedCustomEnvVersions[i] = customEnvImageVersions[i]
            }
        }
        if nsView.isPaused != isPaused {
            nsView.isPaused = isPaused
        }
        
        // Video recording state
        if isRecording && !context.coordinator.isRecording {
            context.coordinator.onRecordingFinished = { [self] success in
                self.isRecording = false
                self.onRecordingFinished?(success)
            }
            context.coordinator.startRecording(drawableSize: nsView.drawableSize)
        } else if !isRecording && context.coordinator.isRecording {
            context.coordinator.stopRecording()
        }
        
        // Camera lock for LINES mode
        nsView.onCameraLockChanged = onCameraLockChanged
        nsView.setCameraLocked(linesCameraLocked)
        
        onRendererReady?(context.coordinator)
    }
}

// MARK: - Interactive MTKView with mouse/trackpad camera orbit + metaball interaction

final class InteractiveMTKView: MTKView {
    weak var renderer: MetaballRenderer?
    private let camera = CameraController()
    private let mouseHandler = MouseHandler()
    var onDoubleTap: (() -> Void)?
    var onPinchDistance: ((Float) -> Void)?
    var onCameraLockChanged: ((Bool) -> Void)?
    
    // Display link for inertia updates
    private var displayLink: CVDisplayLink?
    private var lastInertiaTime: CFTimeInterval = 0
    
    /// Push current camera state to renderer
    private func syncCamera() {
        renderer?.cameraOrientation = camera.cameraOrientation
    }
    
    func setupGestures() {
        // Double-click
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)
        
        // Pan (drag) for camera orbit
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
        
        // Magnify (pinch) for zoom
        let magnify = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify(_:)))
        addGestureRecognizer(magnify)
        
        // Long press
        let longPress = NSPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.8
        addGestureRecognizer(longPress)
        
        // Set initial camera
        syncCamera()
        
        // Start display link for inertia
        startDisplayLink()
    }
    
    // MARK: - Display Link
    
    private func startDisplayLink() {
        lastInertiaTime = CACurrentMediaTime()
        
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let displayLink = link else { return }
        
        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            let view = Unmanaged<InteractiveMTKView>.fromOpaque(userInfo!).takeUnretainedValue()
            DispatchQueue.main.async {
                view.inertiaUpdate()
            }
            return kCVReturnSuccess
        }
        
        CVDisplayLinkSetOutputCallback(displayLink, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(displayLink)
        self.displayLink = displayLink
    }
    
    deinit {
        if let link = displayLink {
            CVDisplayLinkStop(link)
        }
    }
    
    private func inertiaUpdate() {
        let now = CACurrentMediaTime()
        let dt = Float(now - lastInertiaTime)
        lastInertiaTime = now
        
        let lpp = renderer?.simulation.longPressProgress ?? 0
        let pressing = renderer?.simulation.longPressActive ?? false
        
        if camera.update(dt: dt, longPressProgress: lpp, longPressActive: pressing) {
            syncCamera()
        }
    }
    
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
    
    // MARK: - Gesture Handlers
    
    @objc private func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
        onDoubleTap?()
    }
    
    @objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            camera.panBegan()
            
        case .changed:
            let translation = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            if camera.panChanged(dx: Float(translation.x), dy: Float(-translation.y)) {
                syncCamera()
            }
            
        case .ended, .cancelled:
            camera.panEnded()
            
        default:
            break
        }
    }
    
    @objc private func handleMagnify(_ gesture: NSMagnificationGestureRecognizer) {
        switch gesture.state {
        case .changed:
            let scale = Float(1.0 + gesture.magnification)
            gesture.magnification = 0
            let orbitPat = renderer?.simulation.orbitPattern
            let isTrailMode = orbitPat == .lines
            let minDist: Float = isTrailMode ? 0.1 : 3.0
            let dist = camera.applyZoom(scale: scale, minDistance: minDist)
            renderer?.cameraDistance = dist
            renderer?.baseCameraDistance = dist
            onPinchDistance?(dist)
            
        default:
            break
        }
    }
    
    @objc private func handleLongPress(_ gesture: NSPressGestureRecognizer) {
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
    
    // MARK: - Scroll wheel zoom
    
    override func scrollWheel(with event: NSEvent) {
        // Trackpad pinch is handled by magnify gesture; scroll wheel handles discrete zoom
        let orbitPat2 = renderer?.simulation.orbitPattern
        let isTrailMode2 = orbitPat2 == .lines
        let minDist: Float = isTrailMode2 ? 0.1 : 3.0
        if event.hasPreciseScrollingDeltas {
            // Trackpad two-finger scroll → vertical scroll = zoom
            let scrollScale = Float(1.0 - event.scrollingDeltaY * 0.01)
            let dist = camera.applyZoom(scale: scrollScale, minDistance: minDist)
            renderer?.cameraDistance = dist
            renderer?.baseCameraDistance = dist
            onPinchDistance?(dist)
        } else {
            // Mouse scroll wheel
            let scrollScale = Float(1.0 - event.scrollingDeltaY * 0.05)
            let dist = camera.applyZoom(scale: scrollScale, minDistance: minDist)
            renderer?.cameraDistance = dist
            renderer?.baseCameraDistance = dist
            onPinchDistance?(dist)
        }
    }
    
    // MARK: - Mouse events for metaball interaction
    
    override var acceptsFirstResponder: Bool { true }
    
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let point = convert(event.locationInWindow, from: nil)
        mouseHandler.mouseDown(at: point, in: bounds.size, isRightClick: false)
        updateTouchPoints()
    }
    
    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        let point = convert(event.locationInWindow, from: nil)
        mouseHandler.mouseMoved(to: point, in: bounds.size)
        updateTouchPoints()
    }
    
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        mouseHandler.mouseUp()
        updateTouchPoints()
    }
    
    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
        let point = convert(event.locationInWindow, from: nil)
        mouseHandler.mouseDown(at: point, in: bounds.size, isRightClick: true)
        updateTouchPoints()
    }
    
    override func rightMouseDragged(with event: NSEvent) {
        super.rightMouseDragged(with: event)
        let point = convert(event.locationInWindow, from: nil)
        mouseHandler.mouseMoved(to: point, in: bounds.size)
        updateTouchPoints()
    }
    
    override func rightMouseUp(with event: NSEvent) {
        super.rightMouseUp(with: event)
        mouseHandler.mouseUp()
        updateTouchPoints()
    }
    
    private func updateTouchPoints() {
        renderer?.simulation.touchPoints = mouseHandler.getTouchPoints()
    }
}
#endif
