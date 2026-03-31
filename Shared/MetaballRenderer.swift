//
//  MetaballRenderer.swift
//  Magnetic
//
//  Metal renderer for 3D ray-marched metaballs.
//  Platform-agnostic — shared between iOS and macOS targets.
//

import SwiftUI
import MetalKit
import simd
import AVFoundation

final class MetaballRenderer: NSObject, MTKViewDelegate {
    
    var simulation: MetaballSimulation
    
    // Camera state (set by platform-specific view via CameraController)
    var cameraOrientation = simd_quatf(angle: 0.3, axis: SIMD3<Float>(1, 0, 0))
    var cameraDistance: Float = 3.0
    var baseCameraDistance: Float = 3.0
    
    // Console stats callback (throttled to ~10Hz)
    var onConsoleUpdate: ((Float, Float) -> Void)?
    private var lastConsoleUpdate: CFTimeInterval = 0
    
    // Material state (set by SwiftUI)
    var materialMode: UInt32 = 0
    var colorHue: Float = 0
    var colorBri: Float = 0.9
    var envMapIndex: UInt32 = 0
    var envIntensity: Float = 1.0
    var bgMode: UInt32 = 0
    var bgColor: (Float, Float, Float) = (0, 0, 0)
    var autoBgHue: Bool = false
    var bgCustomHue: Float = 0.6
    var bgCustomSat: Float = 0.8
    var bgCustomBri: Float = 0.5
    var envLocked: UInt32 = 0
    var blendK: Float = 0.35
    var autoHue: Bool = false
    var fps: Int = 60
    var manualBPM: Float = 120
    private var autoHueValue: Float = 0
    private var autoBgHueValue: Float = 0
    private var manualBeatPhase: Double = 0
    
    // Mic-driven brightness boost
    private var micBrightnessBoost: Float = 1.0
    
    // Audio bridge
    weak var audioEngine: AudioEngine?
    var isBPMEnabled: Bool = true
    var brightnessSync: Bool = false
    var brightnessSyncMax: Float = 3.0
    
    // Screenshot capture
    var screenshotCompletion: ((PlatformImage?) -> Void)?
    
    // Video recording
    private var videoRecorder: VideoRecorder?
    var isRecording: Bool { videoRecorder?.state == .recording }
    var onRecordingFinished: ((Bool) -> Void)?
    
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var renderPipeline: MTLRenderPipelineState!
    
    // Line rendering pipeline (for LINES orbit pattern)
    private var linePipelineState: MTLRenderPipelineState?

    private var lineVertexBuffer: MTLBuffer?
    private var lineVertexCount: Int = 0
    /// Number of segments already fully written to GPU buffer (progress == 1.0, won't change)
    private var frozenSegmentCount: Int = 0
    private let maxLineVertices = 100_000  // 50,000 segments × 2 vertices
    
    // Point cloud rendering pipeline (for POINT CLOUD orbit pattern)
    private var pointPipelineState: MTLRenderPipelineState?
    private var pointVertexBuffer: MTLBuffer?
    private let maxPointVertices = 30_000
    
    // Box rendering pipeline (for BOX orbit pattern)
    private var boxPipelineState: MTLRenderPipelineState?
    private var boxCubeVertexBuffer: MTLBuffer?
    private var boxInstanceBuffer: MTLBuffer?
    private let boxInstanceCount = 4096    // max shell voxels
    private let boxCubeVertexCount = 36    // 12 triangles
    private var boxDepthStencilState: MTLDepthStencilState?
    private var boxDepthTexture: MTLTexture?
    // (pedestal removed)
    
    // PLY (Play) rendering pipeline
    private var plyLinePipelineState: MTLRenderPipelineState?
    private var plyPointPipelineState: MTLRenderPipelineState?
    private var plyVertexBuffer: MTLBuffer?
    private let maxPlyVertices = 10_000
    
    // PLY collision sound playback
    private var plyWallSoundPlayer: AVAudioPlayer?
    // Block sound uses AVAudioEngine for pitch shifting
    private var plyAudioEngine: AVAudioEngine?
    private var plyPlayerNode: AVAudioPlayerNode?
    private var plyTimePitch: AVAudioUnitTimePitch?
    private var plyBlockAudioFile: AVAudioFile?
    /// Scale mode: 0=OFF, 1=PENTATONIC, 2=MAJOR, 3=MINOR, 4=BLUES
    var plyScaleMode: Int = 0
    
    // Musical scale definitions: semitones from C4 (the base note of Block_reflect.wav ≈ 262 Hz)
    // Negative = lower pitch, positive = higher pitch
    // Big blocks → low notes (index 0), small blocks → high notes (last index)
    // Each scale spans ~2 octaves centered around C4
    private let plyScales: [[Float]] = [
        [],                                                              // 0: OFF
        [-12, -10, -7, -5, -3, 0, 2, 5, 7, 9, 12],                    // 1: C PENTATONIC (C D E G A)
        [-12, -10, -8, -7, -5, -3, -1, 0, 2, 4, 5, 7, 9, 11, 12],    // 2: C MAJOR (C D E F G A B)
        [-12, -10, -9, -7, -5, -4, -2, 0, 2, 3, 5, 7, 8, 10, 12],    // 3: C MINOR (C D Eb F G Ab Bb)
        [-12, -10, -7, -6, -5, -2, 0, 2, 5, 6, 7, 10, 12],           // 4: C BLUES (C Eb F F# G Bb)
    ]
    
    // Semitone offset from C → note name
    // C=0, C#=1, D=2, D#=3, E=4, F=5, F#=6, G=7, G#=8, A=9, A#=10, B=11
    private func noteNameForSemitones(_ semitones: Float) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        var idx = Int(semitones) % 12
        if idx < 0 { idx += 12 }
        return names[idx]
    }
    
    /// Compute semitones and note name for a block of given area using current scale
    func plyNoteForBlockArea(_ area: Float) -> (semitones: Float, noteName: String) {
        guard plyScaleMode > 0 && plyScaleMode < plyScales.count else {
            return (0, "")
        }
        let scale = plyScales[plyScaleMode]
        guard !scale.isEmpty else { return (0, "") }
        // Map area logarithmically: big blocks → index 0 (low), small blocks → last index (high)
        let logArea = log10(max(area, 0.0001))  // ~-4 (tiny) to ~-0.6 (huge)
        let t = min(max(1.0 - (logArea + 4.0) / 3.4, 0), 1)  // 0=big, 1=small
        let noteIndex = Int(t * Float(scale.count - 1))
        let semitones = scale[min(noteIndex, scale.count - 1)]
        let name = noteNameForSemitones(semitones)
        return (semitones, name)
    }
    
    private var ballBuffer: MTLBuffer!
    private var paramsBuffer: MTLBuffer!
    
    // HDRI environment textures
    private var envTextures: [MTLTexture] = []
    private var envSamplerState: MTLSamplerState!
    private var fallbackTexture: MTLTexture!
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
        
        let maxBalls = 64
        ballBuffer = device.makeBuffer(length: maxBalls * MemoryLayout<Ball>.stride, options: .storageModeShared)
        paramsBuffer = device.makeBuffer(length: MemoryLayout<SimParams>.stride, options: .storageModeShared)
        
        // Line rendering pipeline for LINES orbit pattern
        let lineVertexSize = 28  // packed_float3 (12) + packed_float4 (16)
        lineVertexBuffer = device.makeBuffer(length: maxLineVertices * lineVertexSize, options: .storageModeShared)
        
        if let lineVert = library.makeFunction(name: "lineVertex"),
           let lineFrag = library.makeFunction(name: "lineFragment") {
            let linePipeDesc = MTLRenderPipelineDescriptor()
            linePipeDesc.vertexFunction = lineVert
            linePipeDesc.fragmentFunction = lineFrag
            linePipeDesc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            // Enable alpha blending for line fade
            linePipeDesc.colorAttachments[0].isBlendingEnabled = true
            linePipeDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            linePipeDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            linePipeDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
            linePipeDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            linePipelineState = try? device.makeRenderPipelineState(descriptor: linePipeDesc)
        }
        
        // Point cloud rendering pipeline for POINT CLOUD orbit pattern
        let pointVertexSize = 32  // packed_float3 (12) + packed_float4 (16) + float (4)
        pointVertexBuffer = device.makeBuffer(length: maxPointVertices * pointVertexSize, options: .storageModeShared)
        
        if let pointVert = library.makeFunction(name: "pointVertex"),
           let pointFrag = library.makeFunction(name: "pointFragment") {
            let pointPipeDesc = MTLRenderPipelineDescriptor()
            pointPipeDesc.vertexFunction = pointVert
            pointPipeDesc.fragmentFunction = pointFrag
            pointPipeDesc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            // Additive blending for glowing points
            pointPipeDesc.colorAttachments[0].isBlendingEnabled = true
            pointPipeDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            pointPipeDesc.colorAttachments[0].destinationRGBBlendFactor = .one
            pointPipeDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
            pointPipeDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pointPipelineState = try? device.makeRenderPipelineState(descriptor: pointPipeDesc)
        }
        
        // Box rendering pipeline for BOX orbit pattern
        boxCubeVertexBuffer = Self.createUnitCubeBuffer(device: device)
        let boxInstanceSize = 52  // packed_float3 pos (12) + packed_float3 scale (12) + packed_float3 rotation (12) + packed_float4 color (16)
        boxInstanceBuffer = device.makeBuffer(length: boxInstanceCount * boxInstanceSize, options: .storageModeShared)
        
        if let boxVert = library.makeFunction(name: "boxVertex"),
           let boxFrag = library.makeFunction(name: "boxFragment") {
            let boxPipeDesc = MTLRenderPipelineDescriptor()
            boxPipeDesc.vertexFunction = boxVert
            boxPipeDesc.fragmentFunction = boxFrag
            boxPipeDesc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            // Alpha blending for smooth fade in/out
            boxPipeDesc.colorAttachments[0].isBlendingEnabled = true
            boxPipeDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            boxPipeDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            boxPipeDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
            boxPipeDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            boxPipeDesc.depthAttachmentPixelFormat = .depth32Float
            boxPipelineState = try? device.makeRenderPipelineState(descriptor: boxPipeDesc)
        }
        
        // Depth stencil for BOX mode (proper z-ordering for opaque cubes)
        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled = true
        boxDepthStencilState = device.makeDepthStencilState(descriptor: depthDesc)
        
        // (pedestal removed)
        
        // PLY (Play) rendering pipelines
        let plyVertexSize = 28  // packed_float2 (8) + packed_float4 (16) + float (4)
        plyVertexBuffer = device.makeBuffer(length: maxPlyVertices * plyVertexSize, options: .storageModeShared)
        
        // PLY line pipeline (arena borders + block outlines)
        if let plyVert = library.makeFunction(name: "plyVertex"),
           let plyFrag = library.makeFunction(name: "plyFragment") {
            let plyLinePipeDesc = MTLRenderPipelineDescriptor()
            plyLinePipeDesc.vertexFunction = plyVert
            plyLinePipeDesc.fragmentFunction = plyFrag
            plyLinePipeDesc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            plyLinePipeDesc.colorAttachments[0].isBlendingEnabled = true
            plyLinePipeDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            plyLinePipeDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            plyLinePipeDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
            plyLinePipeDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            plyLinePipelineState = try? device.makeRenderPipelineState(descriptor: plyLinePipeDesc)
        }
        
        // PLY point pipeline (ball + particles, additive blending)
        if let plyVert = library.makeFunction(name: "plyVertex"),
           let plyPointFrag = library.makeFunction(name: "plyPointFragment") {
            let plyPointPipeDesc = MTLRenderPipelineDescriptor()
            plyPointPipeDesc.vertexFunction = plyVert
            plyPointPipeDesc.fragmentFunction = plyPointFrag
            plyPointPipeDesc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            plyPointPipeDesc.colorAttachments[0].isBlendingEnabled = true
            plyPointPipeDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            plyPointPipeDesc.colorAttachments[0].destinationRGBBlendFactor = .one
            plyPointPipeDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
            plyPointPipeDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            plyPointPipelineState = try? device.makeRenderPipelineState(descriptor: plyPointPipeDesc)
        }
        
        // Load PLY collision sounds
        if let wallURL = Bundle.main.url(forResource: "Wall_reflect", withExtension: "wav") {
            plyWallSoundPlayer = try? AVAudioPlayer(contentsOf: wallURL)
            plyWallSoundPlayer?.enableRate = true
            plyWallSoundPlayer?.prepareToPlay()
        }
        // Set up AVAudioEngine with TimePitch for block sounds (pitch shifting)
        if let blockURL = Bundle.main.url(forResource: "Block_reflect", withExtension: "wav") {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let timePitch = AVAudioUnitTimePitch()
            timePitch.rate = 1.0   // keep speed constant
            timePitch.pitch = 0    // semitones * 100 = cents
            
            engine.attach(player)
            engine.attach(timePitch)
            
            let audioFile = try? AVAudioFile(forReading: blockURL)
            if let format = audioFile?.processingFormat {
                engine.connect(player, to: timePitch, format: format)
                engine.connect(timePitch, to: engine.mainMixerNode, format: format)
            }
            
            try? engine.start()
            
            plyAudioEngine = engine
            plyPlayerNode = player
            plyTimePitch = timePitch
            plyBlockAudioFile = audioFile
        }
        
        loadEnvironmentTextures(device: device)
        
        lastTime = CACurrentMediaTime()
    }
    
    /// Create a Metal buffer with 36 vertices (12 triangles) for a unit cube centered at origin.
    private static func createUnitCubeBuffer(device: MTLDevice) -> MTLBuffer? {
        struct V { var px: Float; var py: Float; var pz: Float; var nx: Float; var ny: Float; var nz: Float }
        let h: Float = 0.5
        let faces: [([SIMD3<Float>], SIMD3<Float>)] = [
            ([SIMD3(-h,-h, h), SIMD3( h,-h, h), SIMD3( h, h, h), SIMD3(-h, h, h)], SIMD3(0,0,1)),   // front
            ([SIMD3( h,-h,-h), SIMD3(-h,-h,-h), SIMD3(-h, h,-h), SIMD3( h, h,-h)], SIMD3(0,0,-1)),  // back
            ([SIMD3(-h, h, h), SIMD3( h, h, h), SIMD3( h, h,-h), SIMD3(-h, h,-h)], SIMD3(0,1,0)),   // top
            ([SIMD3(-h,-h,-h), SIMD3( h,-h,-h), SIMD3( h,-h, h), SIMD3(-h,-h, h)], SIMD3(0,-1,0)),  // bottom
            ([SIMD3( h,-h, h), SIMD3( h,-h,-h), SIMD3( h, h,-h), SIMD3( h, h, h)], SIMD3(1,0,0)),   // right
            ([SIMD3(-h,-h,-h), SIMD3(-h,-h, h), SIMD3(-h, h, h), SIMD3(-h, h,-h)], SIMD3(-1,0,0)),  // left
        ]
        var verts: [V] = []
        for (c, n) in faces {
            verts.append(V(px: c[0].x, py: c[0].y, pz: c[0].z, nx: n.x, ny: n.y, nz: n.z))
            verts.append(V(px: c[1].x, py: c[1].y, pz: c[1].z, nx: n.x, ny: n.y, nz: n.z))
            verts.append(V(px: c[2].x, py: c[2].y, pz: c[2].z, nx: n.x, ny: n.y, nz: n.z))
            verts.append(V(px: c[0].x, py: c[0].y, pz: c[0].z, nx: n.x, ny: n.y, nz: n.z))
            verts.append(V(px: c[2].x, py: c[2].y, pz: c[2].z, nx: n.x, ny: n.y, nz: n.z))
            verts.append(V(px: c[3].x, py: c[3].y, pz: c[3].z, nx: n.x, ny: n.y, nz: n.z))
        }
        return device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<V>.stride, options: .storageModeShared)
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
        
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .repeat
        samplerDesc.tAddressMode = .clampToEdge
        envSamplerState = device.makeSamplerState(descriptor: samplerDesc)
        
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
    
    /// Load a PlatformImage as a Metal texture for use as custom environment map
    func loadCustomEnvTexture(from image: PlatformImage, slot: Int) {
        guard let device = device,
              let cgImage = image.platformCGImage,
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
        
        if !dt.isFinite || dt <= 0 || dt > 1.0 {
            dt = 1.0 / 30.0
        }
        
        // Bridge audio data directly from AudioEngine
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
            if !isBPMEnabled && manualBPM > 0 {
                let bps = Double(manualBPM) / 60.0
                manualBeatPhase += bps * Double(dt)
                manualBeatPhase = manualBeatPhase.truncatingRemainder(dividingBy: 1.0)
                simulation.predictedBeatPulse = manualBeatPhase < 0.1 ? Float(1.0 - manualBeatPhase / 0.1) : 0
                simulation.detectedBPM = manualBPM
            } else {
                simulation.detectedBPM = manualBPM > 0 ? manualBPM : 120
            }
        }
        
        // LINES draw speed: scale from 5x at BPM20 to 200x at BPM200
        if simulation.orbitPattern == .lines {
            let bpm = max(min(simulation.detectedBPM, 200), 20)
            let t = (bpm - 20) / (200 - 20)  // 0..1
            simulation.lineSpeedMultiplier = 2.0 + t * 48.0  // BPM20=2x, BPM200=50x
        }
        
        // BOX: bridge FFT magnitudes from AudioEngine → Simulation
        if simulation.orbitPattern == .box {
            if let audio = audioEngine {
                simulation.fftMagnitudes = audio.fftMagnitudes
            }
            let bpm = max(min(simulation.detectedBPM, 200), 20)
            let t = (bpm - 20) / (200 - 20)
            simulation.boxSpeedMultiplier = 0.5 + t * 2.5
        }
        
        // PLY: ball speed driven by BPM
        if simulation.orbitPattern == .polygon {
            let bpm = max(min(simulation.detectedBPM, 200), 20)
            let t = (bpm - 20) / (200 - 20)
            simulation.plySpeedMultiplier = 0.5 + t * 2.5
        }
        
        // Mic-driven brightness boost
        if audioEngine != nil && brightnessSync {
            let level = simulation.inputLevel
            if level > 0.8 {
                micBrightnessBoost += 2.0 * dt
            } else if level > 0.5 {
                micBrightnessBoost += 0.5 * dt
            } else {
                micBrightnessBoost += (1.0 - micBrightnessBoost) * 2.0 * dt
            }
            micBrightnessBoost = min(max(micBrightnessBoost, 1.0), brightnessSyncMax)
        } else {
            micBrightnessBoost = 1.0
        }
        
        // BPM-synced hue cycle
        let clampedBPM = max(min(Double(simulation.detectedBPM), 200), 20)
        let t = (clampedBPM - 20.0) / (200.0 - 20.0)
        let hueCycleDuration = 180.0 - t * 120.0
        
        if autoHue {
            autoHueValue += dt / Float(hueCycleDuration)
            if autoHueValue > 1.0 { autoHueValue -= 1.0 }
        }
        
        if autoBgHue && bgMode == 3 {
            autoBgHueValue += dt / Float(hueCycleDuration)
            if autoBgHueValue > 1.0 { autoBgHueValue -= 1.0 }
            let c = PlatformColor.fromHSB(hue: CGFloat(autoBgHueValue), saturation: CGFloat(bgCustomSat), brightness: CGFloat(bgCustomBri))
            let rgb = c.getRGBComponents()
            let r = rgb.r, g = rgb.g, b = rgb.b
            bgColor = (Float(r), Float(g), Float(b))
            view.clearColor = MTLClearColor(red: Double(r), green: Double(g), blue: Double(b), alpha: 1)
        }
        
        simulation.update(dt: min(dt, 1.0 / 15.0))
        
        // Long-press camera zoom
        let lpp = simulation.longPressProgress
        if lpp > 0 {
            let eased = lpp * lpp * (3.0 - 2.0 * lpp)
            let zoomTarget = min(baseCameraDistance * 4.667, 14.0)
            cameraDistance = baseCameraDistance + (zoomTarget - baseCameraDistance) * eased
        } else {
            cameraDistance = baseCameraDistance
        }
        
        // Report stats to console (~10Hz)
        if now - lastConsoleUpdate > 0.1 {
            lastConsoleUpdate = now
            onConsoleUpdate?(cameraDistance, simulation.longPressProgress)
        }
        
        // Upload ball data
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
            colorBri: colorBri,
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
        
        let isLinesMode = simulation.orbitPattern == .lines
        let isBoxMode = simulation.orbitPattern == .box
        let isPlyMode = simulation.orbitPattern == .polygon
        
        if isPlyMode {
            // PLY mode: 2D bouncing ball game on black background
            descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            
            // Pass safe area insets to simulation for arena bounds
            #if os(iOS)
            let safeInsets = view.safeAreaInsets
            let viewH = view.bounds.height
            let viewW = view.bounds.width
            if viewH > 0 && viewW > 0 {
                // Top: safe area + small margin
                simulation.plyArenaTop = Float((safeInsets.top + 8) / viewH)
                // Bottom: safe area + extra for UI icons (~70pt)
                simulation.plyArenaBottom = Float((safeInsets.bottom + 70) / viewH)
                // Left/Right: safe area + small margin
                simulation.plyArenaLeft = Float((safeInsets.left + 8) / viewW)
                simulation.plyArenaRight = Float((safeInsets.right + 8) / viewW)
            }
            #else
            simulation.plyArenaTop = 0.05
            simulation.plyArenaBottom = 0.1
            simulation.plyArenaLeft = 0.03
            simulation.plyArenaRight = 0.03
            #endif
            
            // Play collision sounds
            if simulation.plyWallHit {
                plyWallSoundPlayer?.currentTime = 0
                plyWallSoundPlayer?.rate = 1.0
                plyWallSoundPlayer?.play()
            }
            if simulation.plyBlockHit {
                if let player = plyPlayerNode, let file = plyBlockAudioFile {
                    player.stop()
                    // Set pitch in cents (100 cents = 1 semitone)
                    plyTimePitch?.pitch = simulation.plyBlockHitSemitones * 100
                    file.framePosition = 0
                    player.scheduleFile(file, at: nil)
                    player.play()
                }
            }
            
            if let plyLinePipeline = plyLinePipelineState,
               let plyPointPipeline = plyPointPipelineState,
               let plyBuffer = plyVertexBuffer,
               let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
                
                let plyVertexSize = 28
                let ptr = plyBuffer.contents()
                var vertexCount = 0
                
                // Helper: write a PLY vertex into the buffer
                func writePlyVertex(x: Float, y: Float, r: Float, g: Float, b: Float, a: Float, size: Float) {
                    let off = vertexCount * plyVertexSize
                    guard off + plyVertexSize <= plyBuffer.length else { return }
                    let ndcX = (x - 0.5) * 2.0
                    let ndcY = -(y - 0.5) * 2.0
                    ptr.storeBytes(of: ndcX, toByteOffset: off,      as: Float.self)
                    ptr.storeBytes(of: ndcY, toByteOffset: off + 4,  as: Float.self)
                    ptr.storeBytes(of: r,    toByteOffset: off + 8,  as: Float.self)
                    ptr.storeBytes(of: g,    toByteOffset: off + 12, as: Float.self)
                    ptr.storeBytes(of: b,    toByteOffset: off + 16, as: Float.self)
                    ptr.storeBytes(of: a,    toByteOffset: off + 20, as: Float.self)
                    ptr.storeBytes(of: size, toByteOffset: off + 24, as: Float.self)
                    vertexCount += 1
                }
                
                // --- Pass 1: Lines (arena border + block outlines) ---
                renderEncoder.setRenderPipelineState(plyLinePipeline)
                renderEncoder.setVertexBuffer(plyBuffer, offset: 0, index: 0)
                
                let lineVertexStart = vertexCount
                
                // Arena border (4 lines forming a rectangle, respecting safe areas)
                let aLeft = simulation.plyArenaLeft
                let aRight = simulation.plyArenaRight
                let aTop = simulation.plyArenaTop
                let aBottom = simulation.plyArenaBottom
                let corners: [(Float, Float)] = [
                    (aLeft, aTop),
                    (1.0 - aRight, aTop),
                    (1.0 - aRight, 1.0 - aBottom),
                    (aLeft, 1.0 - aBottom)
                ]
                for i in 0..<4 {
                    let (x0, y0) = corners[i]
                    let (x1, y1) = corners[(i + 1) % 4]
                    writePlyVertex(x: x0, y: y0, r: 1, g: 1, b: 1, a: 0.8, size: 1)
                    writePlyVertex(x: x1, y: y1, r: 1, g: 1, b: 1, a: 0.8, size: 1)
                }
                
                // Block outlines + note names
                for block in simulation.plyBlocks {
                    let bx = block.rect.x
                    let by = block.rect.y
                    let bw = block.rect.z
                    let bh = block.rect.w
                    let blockCorners: [(Float, Float)] = [
                        (bx, by), (bx + bw, by), (bx + bw, by + bh), (bx, by + bh)
                    ]
                    for j in 0..<4 {
                        let (cx0, cy0) = blockCorners[j]
                        let (cx1, cy1) = blockCorners[(j + 1) % 4]
                        writePlyVertex(x: cx0, y: cy0, r: 1, g: 1, b: 1, a: 0.9, size: 1)
                        writePlyVertex(x: cx1, y: cy1, r: 1, g: 1, b: 1, a: 0.9, size: 1)
                    }
                    // Draw note name in center of block
                    if !block.noteName.isEmpty {
                        let cx = bx + bw * 0.5
                        let cy = by + bh * 0.5
                        let charH = min(bh * 0.5, bw * 0.4, 0.03) // character height, capped
                        let charW = charH * 0.6
                        let totalW = charW * Float(block.noteName.count) + charW * 0.2 * Float(block.noteName.count - 1)
                        var penX = cx - totalW * 0.5
                        for ch in block.noteName {
                            drawPlyChar(ch, x: penX, y: cy - charH * 0.5, w: charW, h: charH, write: writePlyVertex)
                            penX += charW * 1.2
                        }
                    }
                }
                
                // Pending swipe preview block
                if let pending = simulation.plyPendingBlock {
                    let px = pending.x, py = pending.y, pw = pending.z, ph = pending.w
                    let previewCorners: [(Float, Float)] = [
                        (px, py), (px + pw, py), (px + pw, py + ph), (px, py + ph)
                    ]
                    for j in 0..<4 {
                        let (cx0, cy0) = previewCorners[j]
                        let (cx1, cy1) = previewCorners[(j + 1) % 4]
                        writePlyVertex(x: cx0, y: cy0, r: 0.5, g: 0.5, b: 0.5, a: 0.4, size: 1)
                        writePlyVertex(x: cx1, y: cy1, r: 0.5, g: 0.5, b: 0.5, a: 0.4, size: 1)
                    }
                }
                
                let lineVertexCount = vertexCount - lineVertexStart
                if lineVertexCount > 0 {
                    renderEncoder.drawPrimitives(type: .line, vertexStart: lineVertexStart, vertexCount: lineVertexCount)
                }
                
                // --- Pass 2: Points (ball + particles) ---
                renderEncoder.setRenderPipelineState(plyPointPipeline)
                
                let pointVertexStart = vertexCount
                
                // Ball
                let ballScreenSize = simulation.plyBallRadius * Float(view.drawableSize.height) * 2.0
                writePlyVertex(x: simulation.plyBallPos.x, y: simulation.plyBallPos.y,
                               r: 1, g: 1, b: 1, a: 1, size: max(ballScreenSize, 4))
                
                // Particles
                for particle in simulation.plyParticles {
                    let pSize = max(particle.life * 6.0, 1.0)
                    writePlyVertex(x: particle.position.x, y: particle.position.y,
                                   r: 1, g: 1, b: 1, a: particle.life * 0.8,
                                   size: pSize)
                }
                
                let pointVertexCount = vertexCount - pointVertexStart
                if pointVertexCount > 0 {
                    renderEncoder.drawPrimitives(type: .point, vertexStart: pointVertexStart, vertexCount: pointVertexCount)
                }
                
                renderEncoder.endEncoding()
            }
            
        } else if isBoxMode {
            // BOX mode: respect bgMode setting
            switch bgMode {
            case 0:  // WHT
                descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)
            case 2:  // GRN
                descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 1, blue: 0, alpha: 1)
            case 3:  // CLR (custom)
                descriptor.colorAttachments[0].clearColor = MTLClearColor(red: Double(bgColor.0), green: Double(bgColor.1), blue: Double(bgColor.2), alpha: 1)
            default: // BLK
                descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            }
            
            // Create/recreate depth texture if needed
            let drawableSize = view.drawableSize
            if boxDepthTexture == nil ||
               boxDepthTexture!.width != Int(drawableSize.width) ||
               boxDepthTexture!.height != Int(drawableSize.height) {
                let depthTexDesc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .depth32Float,
                    width: Int(drawableSize.width),
                    height: Int(drawableSize.height),
                    mipmapped: false
                )
                depthTexDesc.usage = .renderTarget
                depthTexDesc.storageMode = .private
                boxDepthTexture = device.makeTexture(descriptor: depthTexDesc)
            }
            
            // Attach depth buffer
            descriptor.depthAttachment.texture = boxDepthTexture
            descriptor.depthAttachment.loadAction = .clear
            descriptor.depthAttachment.storeAction = .dontCare
            descriptor.depthAttachment.clearDepth = 1.0
            
            if let boxPipeline = boxPipelineState,
               let cubeBuffer = boxCubeVertexBuffer,
               let instanceBuffer = boxInstanceBuffer,
               let depthState = boxDepthStencilState,
               let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
                
                renderEncoder.setDepthStencilState(depthState)
                renderEncoder.setRenderPipelineState(boxPipeline)
                renderEncoder.setVertexBuffer(cubeBuffer, offset: 0, index: 0)
                renderEncoder.setVertexBuffer(paramsBuffer, offset: 0, index: 2)
                renderEncoder.setFragmentBuffer(paramsBuffer, offset: 0, index: 0)
                
                // ENV texture + sampler for environment reflections
                let texIndex = Int(envMapIndex)
                if texIndex >= 13 && texIndex <= 15,
                   let customTex = customEnvTextures[texIndex - 13] {
                    renderEncoder.setFragmentTexture(customTex, index: 0)
                } else if texIndex > 0 && texIndex <= envTextures.count {
                    renderEncoder.setFragmentTexture(envTextures[texIndex - 1], index: 0)
                } else {
                    renderEncoder.setFragmentTexture(fallbackTexture, index: 0)
                }
                renderEncoder.setFragmentSamplerState(envSamplerState, index: 0)
                
                // Draw sculpture voxels
                let instances = simulation.boxInstances
                let count = min(instances.count, boxInstanceCount)
                
                if count > 0 {
                    let instanceSize = 52
                    let ptr = instanceBuffer.contents()
                    
                    for i in 0..<count {
                        let inst = instances[i]
                        let off = i * instanceSize
                        guard off + instanceSize <= instanceBuffer.length else { break }
                        
                        ptr.storeBytes(of: inst.position.x,  toByteOffset: off,      as: Float.self)
                        ptr.storeBytes(of: inst.position.y,  toByteOffset: off + 4,   as: Float.self)
                        ptr.storeBytes(of: inst.position.z,  toByteOffset: off + 8,   as: Float.self)
                        ptr.storeBytes(of: inst.scale.x,     toByteOffset: off + 12,  as: Float.self)
                        ptr.storeBytes(of: inst.scale.y,     toByteOffset: off + 16,  as: Float.self)
                        ptr.storeBytes(of: inst.scale.z,     toByteOffset: off + 20,  as: Float.self)
                        ptr.storeBytes(of: inst.rotation.x,  toByteOffset: off + 24,  as: Float.self)
                        ptr.storeBytes(of: inst.rotation.y,  toByteOffset: off + 28,  as: Float.self)
                        ptr.storeBytes(of: inst.rotation.z,  toByteOffset: off + 32,  as: Float.self)
                        ptr.storeBytes(of: inst.color.x,     toByteOffset: off + 36,  as: Float.self)
                        ptr.storeBytes(of: inst.color.y,     toByteOffset: off + 40,  as: Float.self)
                        ptr.storeBytes(of: inst.color.z,     toByteOffset: off + 44,  as: Float.self)
                        ptr.storeBytes(of: inst.color.w,     toByteOffset: off + 48,  as: Float.self)
                    }
                    
                    renderEncoder.setVertexBuffer(instanceBuffer, offset: 0, index: 1)
                    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: boxCubeVertexCount, instanceCount: count)
                }
                
                renderEncoder.endEncoding()
            }
            
        } else if isLinesMode {
            // LINES mode: always black background
            descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            
            // Pass 1: Draw lines
            if let linePipeline = linePipelineState,
               let lineBuffer = lineVertexBuffer,
               let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
                
                // Upload line vertices: 2 vertices per segment
                // Frozen segments (progress == 1.0) are already in the buffer from previous frames.
                // Only write new/in-progress segments to avoid redundant CPU work.
                let segments = simulation.accumulatedLines
                let lineVertexSize = 28  // packed_float3 (12) + packed_float4 (16)
                
                // CLR mode: triadic color spread — compute hue-based tint per segment
                let isColorMode = (materialMode == 3)
                let baseHue = autoHue ? autoHueValue : colorHue
                
                // Reset frozen count if lines were cleared (e.g., orbit change / recycling)
                if segments.count < frozenSegmentCount {
                    frozenSegmentCount = 0
                }
                
                // If oldest segments are fading (alpha < 1), unfreeze them so they get re-uploaded
                // Check if the first frozen segment has reduced alpha
                if frozenSegmentCount > 0 && segments.count > 0 && segments[0].color.w < 0.99 {
                    frozenSegmentCount = 0
                }
                
                // CLR mode with AUTO hue: colors shift every frame, can't freeze
                if isColorMode && autoHue {
                    frozenSegmentCount = 0
                }
                
                var actualVertexCount = frozenSegmentCount * 2  // frozen segments already in buffer
                
                if segments.count > 0 {
                    let ptr = lineBuffer.contents()
                    
                    // Count newly frozen segments this frame
                    var newFrozenCount = frozenSegmentCount
                    
                    // Only process segments from frozenSegmentCount onward
                    for i in frozenSegmentCount..<segments.count {
                        let seg = segments[i]
                        guard seg.progress > 0.001 else { continue }
                        guard seg.color.w > 0.001 else { continue }  // skip fully faded segments
                        
                        let baseOffset0 = actualVertexCount * lineVertexSize
                        let baseOffset1 = (actualVertexCount + 1) * lineVertexSize
                        guard baseOffset1 + lineVertexSize <= lineBuffer.length else { break }
                        
                        let visibleEnd = seg.currentEnd
                        
                        // Compute final RGB color for this segment
                        let r: Float, g: Float, b: Float, a: Float
                        if isColorMode {
                            // Time-based triadic color: slowly shift hue over 60s across 120° of color wheel
                            // hueT stores linesElapsedTime (seconds) when segment was created
                            let timeHue = (seg.hueT / 60.0 * 0.333).truncatingRemainder(dividingBy: 1.0)
                            let segHue = (baseHue + timeHue).truncatingRemainder(dividingBy: 1.0)
                            let rgb = hsvToRGB(h: segHue, s: 1.0, v: 1.0)
                            let bri = seg.color.x  // brightness stored in R channel
                            r = rgb.0 * bri
                            g = rgb.1 * bri
                            b = rgb.2 * bri
                            a = seg.color.w
                        } else {
                            r = seg.color.x
                            g = seg.color.y
                            b = seg.color.z
                            a = seg.color.w
                        }
                        
                        // Vertex 0: start
                        ptr.storeBytes(of: seg.start.x, toByteOffset: baseOffset0, as: Float.self)
                        ptr.storeBytes(of: seg.start.y, toByteOffset: baseOffset0 + 4, as: Float.self)
                        ptr.storeBytes(of: seg.start.z, toByteOffset: baseOffset0 + 8, as: Float.self)
                        ptr.storeBytes(of: r, toByteOffset: baseOffset0 + 12, as: Float.self)
                        ptr.storeBytes(of: g, toByteOffset: baseOffset0 + 16, as: Float.self)
                        ptr.storeBytes(of: b, toByteOffset: baseOffset0 + 20, as: Float.self)
                        ptr.storeBytes(of: a, toByteOffset: baseOffset0 + 24, as: Float.self)
                        
                        // Vertex 1: current visible end (animated)
                        ptr.storeBytes(of: visibleEnd.x, toByteOffset: baseOffset1, as: Float.self)
                        ptr.storeBytes(of: visibleEnd.y, toByteOffset: baseOffset1 + 4, as: Float.self)
                        ptr.storeBytes(of: visibleEnd.z, toByteOffset: baseOffset1 + 8, as: Float.self)
                        ptr.storeBytes(of: r, toByteOffset: baseOffset1 + 12, as: Float.self)
                        ptr.storeBytes(of: g, toByteOffset: baseOffset1 + 16, as: Float.self)
                        ptr.storeBytes(of: b, toByteOffset: baseOffset1 + 20, as: Float.self)
                        ptr.storeBytes(of: a, toByteOffset: baseOffset1 + 24, as: Float.self)
                        
                        actualVertexCount += 2
                        
                        // Track frozen: segment won't change if progress is 1.0 AND alpha is full
                        // (fading segments have reduced alpha and must be re-uploaded)
                        // CLR+AUTO: never freeze (colors shift every frame)
                        if seg.progress >= 1.0 && seg.color.w >= 0.99 && i == newFrozenCount && !(isColorMode && autoHue) {
                            newFrozenCount = i + 1
                        }
                    }
                    
                    frozenSegmentCount = newFrozenCount
                    
                    if actualVertexCount > 0 {
                        renderEncoder.setRenderPipelineState(linePipeline)
                        renderEncoder.setVertexBuffer(lineBuffer, offset: 0, index: 0)
                        renderEncoder.setVertexBuffer(paramsBuffer, offset: 0, index: 1)
                        renderEncoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: actualVertexCount)
                    }
                }
                
                renderEncoder.endEncoding()
            }
            
        } else {
            // Normal metaball rendering
            if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
                renderEncoder.setRenderPipelineState(renderPipeline)
                renderEncoder.setFragmentBuffer(ballBuffer, offset: 0, index: 0)
                renderEncoder.setFragmentBuffer(paramsBuffer, offset: 0, index: 1)
                
                let texIndex = Int(envMapIndex)
                if texIndex >= 13 && texIndex <= 15,
                   let customTex = customEnvTextures[texIndex - 13] {
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
        }
        
        // Video recording
        if let recorder = videoRecorder, recorder.state == .recording {
            recorder.captureFrame(commandBuffer: commandBuffer, sourceTexture: drawable.texture)
        }
        
        // Screenshot capture
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
                        let image = PlatformImage.fromCGImage(cgImage)
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
    
    /// Draw a single character using line segments for PLY block note names
    /// Uses a simple vector font. x,y = top-left corner, w/h = character cell size.
    private func drawPlyChar(
        _ ch: Character,
        x: Float, y: Float, w: Float, h: Float,
        write: (Float, Float, Float, Float, Float, Float, Float) -> Void
    ) {
        let a: Float = 0.6  // alpha for note text
        // Define line segments for each character as pairs of (x0,y0,x1,y1) in 0..1 space
        let segments: [(Float, Float, Float, Float)]
        switch ch {
        case "A":
            segments = [
                (0, 1, 0, 0.3),    // left vertical
                (0, 0.3, 0.5, 0),   // left diagonal to top
                (0.5, 0, 1, 0.3),   // right diagonal from top
                (1, 0.3, 1, 1),     // right vertical
                (0, 0.55, 1, 0.55)  // crossbar
            ]
        case "B":
            segments = [
                (0, 0, 0, 1),       // left vertical
                (0, 0, 0.7, 0),     // top horizontal
                (0.7, 0, 1, 0.15),  // top-right curve
                (1, 0.15, 1, 0.35), // right side upper
                (1, 0.35, 0.7, 0.5),// mid curve
                (0, 0.5, 0.7, 0.5), // middle bar
                (0.7, 0.5, 1, 0.65),// lower curve
                (1, 0.65, 1, 0.85), // right side lower
                (1, 0.85, 0.7, 1),  // bottom-right curve
                (0, 1, 0.7, 1)      // bottom horizontal
            ]
        case "C":
            segments = [
                (1, 0.15, 0.5, 0),  // top right to top
                (0.5, 0, 0, 0.15),  // top to left
                (0, 0.15, 0, 0.85), // left side
                (0, 0.85, 0.5, 1),  // bottom left
                (0.5, 1, 1, 0.85)   // bottom to right
            ]
        case "D":
            segments = [
                (0, 0, 0, 1),       // left vertical
                (0, 0, 0.6, 0),     // top horizontal
                (0.6, 0, 1, 0.3),   // top-right diagonal
                (1, 0.3, 1, 0.7),   // right vertical
                (1, 0.7, 0.6, 1),   // bottom-right diagonal
                (0, 1, 0.6, 1)      // bottom horizontal
            ]
        case "E":
            segments = [
                (0, 0, 0, 1),       // left vertical
                (0, 0, 1, 0),       // top horizontal
                (0, 0.5, 0.7, 0.5), // middle bar
                (0, 1, 1, 1)        // bottom horizontal
            ]
        case "F":
            segments = [
                (0, 0, 0, 1),       // left vertical
                (0, 0, 1, 0),       // top horizontal
                (0, 0.5, 0.7, 0.5)  // middle bar
            ]
        case "G":
            segments = [
                (1, 0.15, 0.5, 0),  // top curve
                (0.5, 0, 0, 0.15),  // top-left
                (0, 0.15, 0, 0.85), // left side
                (0, 0.85, 0.5, 1),  // bottom-left
                (0.5, 1, 1, 0.85),  // bottom-right
                (1, 0.85, 1, 0.5),  // right lower
                (0.5, 0.5, 1, 0.5)  // middle bar
            ]
        case "#":
            segments = [
                (0.3, 0, 0.2, 1),   // left vertical (slight slant)
                (0.8, 0, 0.7, 1),   // right vertical (slight slant)
                (0, 0.3, 1, 0.3),   // top horizontal
                (0, 0.7, 1, 0.7)    // bottom horizontal
            ]
        default:
            segments = []
        }
        for (x0, y0, x1, y1) in segments {
            write(x + x0 * w, y + y0 * h, 1, 1, 1, a, 1)
            write(x + x1 * w, y + y1 * h, 1, 1, 1, a, 1)
        }
    }
    
    /// Convert HSV (h: 0..1, s: 0..1, v: 0..1) to RGB tuple
    private func hsvToRGB(h: Float, s: Float, v: Float) -> (Float, Float, Float) {
        let h6 = h * 6.0
        let sector = Int(h6) % 6
        let f = h6 - Float(sector)
        let p = v * (1.0 - s)
        let q = v * (1.0 - s * f)
        let t = v * (1.0 - s * (1.0 - f))
        switch sector {
        case 0:  return (v, t, p)
        case 1:  return (q, v, p)
        case 2:  return (p, v, t)
        case 3:  return (p, q, v)
        case 4:  return (t, p, v)
        default: return (v, p, q)
        }
    }
}
