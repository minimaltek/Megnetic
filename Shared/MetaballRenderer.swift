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
    
    // RAIN (Play) rendering pipeline
    private var rainLinePipelineState: MTLRenderPipelineState?
    private var rainPointPipelineState: MTLRenderPipelineState?
    private var rainVertexBuffer: MTLBuffer?
    private let maxRainVertices = 10_000
    
    // RAIN collision sound playback (single AVAudioEngine)
    // Instruments: 0=BASE, 1=PIANO, 2=VOICE, 3=WOOD, 4-6=REC1-3 (custom Block only)
    private var rainAudioEngine: AVAudioEngine?
    static let instCount = 7
    static let instNames = ["BASE", "PIANO", "VOICE", "WOOD", "REC1", "REC2", "REC3"]
    // Per-instrument sample players: [inst][0=block, 1=wall]
    private var rainPlayers: [[AVAudioPlayerNode?]] = Array(repeating: [nil, nil], count: instCount)
    private var rainBuffers: [[AVAudioPCMBuffer?]] = Array(repeating: [nil, nil], count: instCount)
    private var rainVarispeeds: [[AVAudioUnitVarispeed?]] = Array(repeating: [nil, nil], count: instCount)
    // Base MIDI note per instrument per role [inst][0=block, 1=wall]
    private let rainBaseMidi: [[Int]] = [
        [48, 36],  // 0: BASE — Block=C3(48), Wall=C2(36)
        [48, 24],  // 1: PIANO — Block=C3(48), Wall=C1(24)
        [48, 36],  // 2: VOICE — Block=C3(48), Wall=C2(36)
        [48, 24],  // 3: WOOD — Block=C3(48), Wall=C1(24)
        [48, 48],  // 4: REC1 — Block only, C3(48) base
        [48, 48],  // 5: REC2 — Block only, C3(48) base
        [48, 48],  // 6: REC3 — Block only, C3(48) base
    ]
    private var rainDelayNode: AVAudioUnitDelay?         // Delay effect on block sounds
    /// Scale mode: 0=OFF, 1=PENTATONIC, 2=MAJOR, 3=MINOR, 4=BLUES
    var rainScaleMode: Int = 0
    /// Instrument for block sounds: 0=BASE, 1=PIANO, 2=VOICE, 3=WOOD, 4-6=REC1-3
    var rainBlockInst: Int = 0
    /// Instrument for wall sounds: 0=BASE, 1=PIANO, 2=VOICE, 3=WOOD
    var rainWallInst: Int = 0
    /// Root note: 0=C, 1=C#, 2=D, ... 11=B
    var rainRootNote: Int = 0
    /// Sequential scale index: cycles through scale notes in order
    private var rainScaleNoteIndex: Int = 0
    /// Octave offset: -2 to +2 (0 = default C4 center)
    var rainOctave: Int = 0
    /// Delay enabled (wall sounds only)
    var rainDelayEnabled: Bool = true
    /// Delay sync division: index into delaySyncDivisions
    var rainDelaySync: Int = 2  // default = 1/8D (index into delaySyncNames)
    /// Delay feedback: 0.0 ~ 0.95
    var rainDelayFeedback: Float = 0.65
    /// Delay wet/dry amount: 0.0 ~ 1.0
    var rainDelayAmount: Float = 0.10
    
    // Delay sync note divisions: beat multiplier relative to 1 beat (quarter note)
    // 1BAR=4, 1/2=2, 1/4=1, 1/8=0.5, 1/16=0.25, dotted=×1.5
    static let delaySyncNames = ["1/2D", "1/4D", "1/8D", "1/16D"]
    static let delaySyncBeats: [Double] = [3.0, 1.5, 0.75, 0.375]
    
    // RAIN category: 0=Fall, 1=PinBall
    var rainCategory: Int = 0
    
    // Scale definitions as semitone intervals from root note
    // These are relative intervals, applied on top of rainRootNote (OCT is Wall only)
    static let scaleIntervals: [[Int]] = [
        [],                                          // 0: OFF
        [0, 2, 4, 7, 9, 12, 14, 16, 19, 21, 24],  // 1: PENTATONIC
        [0, 2, 4, 5, 7, 9, 11, 12, 14, 16, 17, 19, 21, 23, 24], // 2: MAJOR
        [0, 2, 3, 5, 7, 8, 10, 12, 14, 15, 17, 19, 20, 22, 24], // 3: MINOR
        [0, 3, 5, 6, 7, 10, 12, 15, 17, 18, 19, 22, 24],        // 4: BLUES
    ]
    
    /// Build the current scale as MIDI note numbers based on root (OCT is Wall only)
    private func currentScale() -> [UInt8] {
        guard rainScaleMode > 0 && rainScaleMode < Self.scaleIntervals.count else { return [] }
        let intervals = Self.scaleIntervals[rainScaleMode]
        // Base MIDI note: C2=36, adjust by root note only (OCT does NOT affect Block)
        let baseMidi = 36 + rainRootNote
        return intervals.compactMap { interval in
            let midi = baseMidi + interval
            guard midi >= 0 && midi <= 127 else { return nil }
            return UInt8(midi)
        }
    }
    
    // MIDI note number → note name
    private func noteNameForMidi(_ midi: UInt8) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return names[Int(midi) % 12]
    }
    
    /// Pick the next MIDI note from the current scale in order (sequential cycling)
    func rainRandomNoteForBlock() -> (midiNote: UInt8, noteName: String) {
        let scale = currentScale()
        guard !scale.isEmpty else {
            // No scale: use root note (C2=36 base, OCT does NOT affect Block)
            let midi = UInt8(clamping: 36 + rainRootNote)
            let name = noteNameForMidi(midi)
            return (midi, name)
        }
        let idx = rainScaleNoteIndex % scale.count
        rainScaleNoteIndex += 1
        let midi = scale[idx]
        let name = noteNameForMidi(midi)
        return (midi, name)
    }
    
    /// Play a note using the specified sample instrument
    /// All instruments are sample-based: 0=BASE, 1=PIANO, 2=VOICE, 3=WOOD
    private func playRainNote(inst: Int, midiNote: UInt8, isWall: Bool = false) {
        let idx = min(inst, Self.instCount - 1)
        let role = isWall ? 1 : 0
        guard let player = rainPlayers[idx][role],
              let buffer = rainBuffers[idx][role] else { return }
        let baseMidi = rainBaseMidi[idx][role]
        let semitones = Float(Int(midiNote) - baseMidi)
        let tuningRatio: Float = 432.0 / 440.0
        rainVarispeeds[idx][role]?.rate = powf(2.0, semitones / 12.0) * tuningRatio
        // Use .interrupts to retrigger without pop/click from abrupt stop()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }
    
    /// Stop all rain audio players and reset delay effect (e.g. before opening recorder)
    func stopAllRainAudio() {
        // Stop every player
        for instPlayers in rainPlayers {
            for player in instPlayers {
                player?.stop()
            }
        }
        // Reset delay: zero out wet mix and feedback so tail dies immediately
        if let delay = rainDelayNode {
            delay.wetDryMix = 0
            delay.feedback = 0
            // Re-apply after a brief moment so the tail is fully flushed
            delay.reset()
        }
    }
    
    /// Reload a custom REC slot buffer after recording is saved (Block only)
    func reloadCustomBlockBuffer(slot: Int) {
        let instIdx = 4 + slot
        guard instIdx < Self.instCount else { return }
        guard let rawBuf = CustomSoundManager.loadBuffer(slot: slot) else {
            rainBuffers[instIdx] = [nil, nil]
            return
        }
        // Convert to match player's expected format (channel count / sample rate)
        let playerFmt = rainPlayers[instIdx][0]?.outputFormat(forBus: 0)
        let blockBuf = Self.convertBuffer(rawBuf, to: playerFmt)
        rainBuffers[instIdx] = [blockBuf, nil]
    }
    
    /// Convert a buffer to match the target format's channel count and sample rate.
    /// If already matching or conversion not needed, returns the original buffer.
    private static func convertBuffer(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat?) -> AVAudioPCMBuffer? {
        guard let target = targetFormat else { return buffer }
        // Already matches
        if buffer.format.channelCount == target.channelCount &&
           buffer.format.sampleRate == target.sampleRate {
            return buffer
        }
        // Build a compatible target: same channel count & sample rate, but standard PCM float
        guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: target.sampleRate,
                                            channels: target.channelCount) else { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: outFormat) else { return buffer }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outFrames + 100) else { return buffer }
        
        var error: NSError?
        var inputDone = false
        converter.convert(to: outBuf, error: &error) { _, outStatus in
            if inputDone {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputDone = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let error = error {
            print("MetaballRenderer: audio conversion failed: \(error)")
            return buffer
        }
        return outBuf
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
    private var needsResumeReset = false
    
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
        
        // RAIN (Play) rendering pipelines
        let rainVertexSize = 28  // packed_float2 (8) + packed_float4 (16) + float (4)
        rainVertexBuffer = device.makeBuffer(length: maxRainVertices * rainVertexSize, options: .storageModeShared)
        
        // RAIN line pipeline (arena borders + block outlines)
        if let rainVert = library.makeFunction(name: "rainVertex"),
           let rainFrag = library.makeFunction(name: "rainFragment") {
            let rainLinePipeDesc = MTLRenderPipelineDescriptor()
            rainLinePipeDesc.vertexFunction = rainVert
            rainLinePipeDesc.fragmentFunction = rainFrag
            rainLinePipeDesc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            rainLinePipeDesc.colorAttachments[0].isBlendingEnabled = true
            rainLinePipeDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            rainLinePipeDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            rainLinePipeDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
            rainLinePipeDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            rainLinePipelineState = try? device.makeRenderPipelineState(descriptor: rainLinePipeDesc)
        }
        
        // RAIN point pipeline (ball + particles, additive blending)
        if let rainVert = library.makeFunction(name: "rainVertex"),
           let rainPointFrag = library.makeFunction(name: "rainPointFragment") {
            let rainPointPipeDesc = MTLRenderPipelineDescriptor()
            rainPointPipeDesc.vertexFunction = rainVert
            rainPointPipeDesc.fragmentFunction = rainPointFrag
            rainPointPipeDesc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            rainPointPipeDesc.colorAttachments[0].isBlendingEnabled = true
            rainPointPipeDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            rainPointPipeDesc.colorAttachments[0].destinationRGBBlendFactor = .one
            rainPointPipeDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
            rainPointPipeDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            rainPointPipelineState = try? device.makeRenderPipelineState(descriptor: rainPointPipeDesc)
        }
        
        // Ensure audio session supports Bluetooth output
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.defaultToSpeaker, .mixWithOthers, .allowBluetoothA2DP])
        try? session.setActive(true)
        #endif
        
        // Set up AVAudioEngine with sample players for all instruments
        let engine = AVAudioEngine()
        
        // Sample file definitions: [inst][0=block, 1=wall] → (resource, ext)
        let sampleFiles: [[(String, String)]] = [
            [("Block_reflect", "wav"),      ("Wall_reflect_C2_New", "wav")],  // 0: BASE
            [("Piano_C3_Block", "mp3"),     ("Piano_C1_Wall", "mp3")],       // 1: PIANO
            [("Voice02_C3_Block", "wav"),   ("Voice02_C2_Wall", "wav")],     // 2: VOICE
            [("Wood_C3_Block", "wav"),      ("Wood_C1_Wall", "wav")],        // 3: WOOD
        ]
        
        let delayNode = AVAudioUnitDelay()
        delayNode.delayTime = 0.375
        delayNode.feedback = 40
        delayNode.wetDryMix = 0
        delayNode.lowPassCutoff = 8000
        
        // Block submixer → delay → main
        let blockMixer = AVAudioMixerNode()
        engine.attach(blockMixer)
        engine.attach(delayNode)
        
        let mainMixer = engine.mainMixerNode
        engine.connect(blockMixer, to: delayNode, format: nil)
        engine.connect(delayNode, to: mainMixer, format: nil)
        
        // Create player + varispeed for each instrument × block/wall
        var players: [[AVAudioPlayerNode?]] = []
        var varispeeds: [[AVAudioUnitVarispeed?]] = []
        
        for _ in 0..<Self.instCount {
            var instPlayers: [AVAudioPlayerNode?] = []
            var instVarispeeds: [AVAudioUnitVarispeed?] = []
            for role in 0..<2 {  // 0=block, 1=wall
                let player = AVAudioPlayerNode()
                let varispeed = AVAudioUnitVarispeed()
                varispeed.rate = 1.0
                engine.attach(player)
                engine.attach(varispeed)
                engine.connect(player, to: varispeed, format: nil)
                if role == 0 {
                    // Block → submixer → delay → main
                    engine.connect(varispeed, to: blockMixer, format: nil)
                } else {
                    // Wall → main (no delay)
                    engine.connect(varispeed, to: mainMixer, format: nil)
                }
                instPlayers.append(player)
                instVarispeeds.append(varispeed)
            }
            players.append(instPlayers)
            varispeeds.append(instVarispeeds)
        }
        
        try? engine.start()
        
        // Preload audio samples into PCM buffers
        func loadBuffer(resource: String, ext: String) -> AVAudioPCMBuffer? {
            guard let url = Bundle.main.url(forResource: resource, withExtension: ext),
                  let file = try? AVAudioFile(forReading: url) else { return nil }
            let frameCount = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else { return nil }
            try? file.read(into: buffer)
            return buffer
        }
        
        // Get the player's input format (what scheduleBuffer expects)
        let playerFormat = players[0][0]?.outputFormat(forBus: 0)
        
        var buffers: [[AVAudioPCMBuffer?]] = []
        // Load preset instruments (0-3) from bundle
        for inst in 0..<sampleFiles.count {
            let blockBuf = loadBuffer(resource: sampleFiles[inst][0].0, ext: sampleFiles[inst][0].1)
            let wallBuf = loadBuffer(resource: sampleFiles[inst][1].0, ext: sampleFiles[inst][1].1)
            buffers.append([blockBuf, wallBuf])
        }
        // Load custom REC slots (4-6) from Documents — Block only
        // Convert to player format if channel count differs
        for customSlot in 0..<3 {
            let rawBuf = CustomSoundManager.loadBuffer(slot: customSlot)
            let blockBuf = rawBuf.flatMap { Self.convertBuffer($0, to: playerFormat) }
            buffers.append([blockBuf, nil])
        }
        
        rainAudioEngine = engine
        rainPlayers = players
        rainBuffers = buffers
        rainVarispeeds = varispeeds
        rainDelayNode = delayNode
        
        loadEnvironmentTextures(device: device)
        
        lastTime = CACurrentMediaTime()
        
        // Listen for app returning from background to reset timing + restart audio
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.needsResumeReset = true
            // Audio engine may have been stopped by iOS during background
            if let engine = self?.rainAudioEngine, !engine.isRunning {
                try? engine.start()
            }
        }
        #endif
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
        // Kill all playing sounds and reset delay before recording starts
        stopAllRainAudio()
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
            fps: fps,
            audioEngine: rainAudioEngine
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
        
        // After returning from background/sleep, reset timing to avoid stale frames
        if needsResumeReset {
            needsResumeReset = false
            lastTime = now
            // Fall through to render a clean frame with correct timing
        }
        
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
        
        // RAIN: ball speed driven by BPM
        if simulation.orbitPattern == .polygon {
            // rainSpeedMultiplier は各物理箇所で直接 bpmT を使うため 1.0 固定
            simulation.rainSpeedMultiplier = 1.0
            
            // Update delay on block sounds (synced to BPM)
            if let delay = rainDelayNode {
                if rainDelayEnabled {
                    let syncIdx = min(rainDelaySync, Self.delaySyncBeats.count - 1)
                    let bpm = max(min(simulation.detectedBPM, 200), 20)
                    let beatDuration = 60.0 / Double(max(bpm, 20))
                    let delayTime = beatDuration * Self.delaySyncBeats[syncIdx]
                    delay.delayTime = min(delayTime, 2.0)
                    delay.feedback = Float(rainDelayFeedback * 100)
                    delay.wetDryMix = Float(rainDelayAmount * 100)
                } else {
                    delay.wetDryMix = 0  // bypass
                }
            }
            
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
        let isRainMode = simulation.orbitPattern == .polygon
        
        if isRainMode {
            // RAIN mode: 2D bouncing ball game on black background
            descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            
            // Pass safe area insets to simulation for arena bounds
            #if os(iOS)
            let safeInsets = view.safeAreaInsets
            let viewH = view.bounds.height
            let viewW = view.bounds.width
            if viewH > 0 && viewW > 0 {
                // Top: safe area + small margin
                simulation.rainArenaTop = Float((safeInsets.top + 8) / viewH)
                // Bottom: safe area + margin for HUD (compact in RAIN)
                let bottomMargin: CGFloat = 36
                simulation.rainArenaBottom = Float((safeInsets.bottom + bottomMargin) / viewH)
                // Left/Right: safe area + small margin
                simulation.rainArenaLeft = Float((safeInsets.left + 8) / viewW)
                simulation.rainArenaRight = Float((safeInsets.right + 8) / viewW)
                simulation.rainScreenAspect = aspect
            }
            #else
            simulation.rainArenaTop = 0.05
            simulation.rainArenaBottom = 0.1
            simulation.rainArenaLeft = 0.03
            simulation.rainArenaRight = 0.03
            simulation.rainScreenAspect = aspect
            #endif
            
            // Play collision sounds
            if simulation.rainWallHit {
                // Wall: ROOT + OCT を反映（ベース=C1=24、rootNote と octave で移調）
                let wallMidi = UInt8(clamping: 24 + rainRootNote + (rainOctave * 12))
                playRainNote(inst: rainWallInst, midiNote: wallMidi, isWall: true)
            }
            if simulation.rainBlockHit {
                playRainNote(inst: rainBlockInst, midiNote: simulation.rainBlockHitMidiNote, isWall: false)
            }
            
            if let rainLinePipeline = rainLinePipelineState,
               let rainPointPipeline = rainPointPipelineState,
               let rainBuffer = rainVertexBuffer,
               let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
                
                let rainVertexSize = 28
                let ptr = rainBuffer.contents()
                var vertexCount = 0
                
                // Helper: write a RAIN vertex into the buffer
                func writeRainVertex(x: Float, y: Float, r: Float, g: Float, b: Float, a: Float, size: Float) {
                    let off = vertexCount * rainVertexSize
                    guard off + rainVertexSize <= rainBuffer.length else { return }
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
                renderEncoder.setRenderPipelineState(rainLinePipeline)
                renderEncoder.setVertexBuffer(rainBuffer, offset: 0, index: 0)
                
                let lineVertexStart = vertexCount
                
                // Arena border (respecting safe areas)
                let aLeft = simulation.rainArenaLeft
                let aRight = simulation.rainArenaRight
                let aTop = simulation.rainArenaTop
                let aBottom = simulation.rainArenaBottom
                
                // Wall hit animation: expand outward + brightness flash
                let wallExpand = simulation.rainWallHitScale * 0.006
                let wallAlpha: Float = 0.8 + simulation.rainWallHitScale * 0.2
                
                if rainCategory == 0 {
                    // Fall mode: FLOOR only (no walls — balls exit left, right, and top)
                    let floorY = 1.0 - aBottom + wallExpand
                    writeRainVertex(x: aLeft - wallExpand, y: floorY, r: 1, g: 1, b: 1, a: wallAlpha, size: 1)
                    writeRainVertex(x: 1.0 - aRight + wallExpand, y: floorY, r: 1, g: 1, b: 1, a: wallAlpha, size: 1)
                } else {
                    // PinBall mode: all 4 walls
                    let corners: [(Float, Float)] = [
                        (aLeft - wallExpand, aTop - wallExpand),
                        (1.0 - aRight + wallExpand, aTop - wallExpand),
                        (1.0 - aRight + wallExpand, 1.0 - aBottom + wallExpand),
                        (aLeft - wallExpand, 1.0 - aBottom + wallExpand)
                    ]
                    for i in 0..<4 {
                        let (x0, y0) = corners[i]
                        let (x1, y1) = corners[(i + 1) % 4]
                        writeRainVertex(x: x0, y: y0, r: 1, g: 1, b: 1, a: wallAlpha, size: 1)
                        writeRainVertex(x: x1, y: y1, r: 1, g: 1, b: 1, a: wallAlpha, size: 1)
                    }
                }
                
                // Block outlines + note names
                for block in simulation.rainBlocks {
                    // Expand block rect based on hitScale (pop effect)
                    let expand = block.hitScale * 0.012  // max ~1.2% expansion
                    let bx = block.rect.x - expand
                    let by = block.rect.y - expand
                    let bw = block.rect.z + expand * 2
                    let bh = block.rect.w + expand * 2
                    // Brightness flash on hit
                    let hitAlpha: Float = 0.9 + block.hitScale * 0.1
                    let blockCorners: [(Float, Float)] = [
                        (bx, by), (bx + bw, by), (bx + bw, by + bh), (bx, by + bh)
                    ]
                    for j in 0..<4 {
                        let (cx0, cy0) = blockCorners[j]
                        let (cx1, cy1) = blockCorners[(j + 1) % 4]
                        writeRainVertex(x: cx0, y: cy0, r: 1, g: 1, b: 1, a: hitAlpha, size: 1)
                        writeRainVertex(x: cx1, y: cy1, r: 1, g: 1, b: 1, a: hitAlpha, size: 1)
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
                            drawRainChar(ch, x: penX, y: cy - charH * 0.5, w: charW, h: charH, write: writeRainVertex)
                            penX += charW * 1.2
                        }
                    }
                }
                
                // Pending swipe preview block
                if let pending = simulation.rainPendingBlock {
                    let px = pending.x, py = pending.y, pw = pending.z, ph = pending.w
                    let previewCorners: [(Float, Float)] = [
                        (px, py), (px + pw, py), (px + pw, py + ph), (px, py + ph)
                    ]
                    for j in 0..<4 {
                        let (cx0, cy0) = previewCorners[j]
                        let (cx1, cy1) = previewCorners[(j + 1) % 4]
                        writeRainVertex(x: cx0, y: cy0, r: 0.5, g: 0.5, b: 0.5, a: 0.4, size: 1)
                        writeRainVertex(x: cx1, y: cy1, r: 0.5, g: 0.5, b: 0.5, a: 0.4, size: 1)
                    }
                }
                
                // ── Dandelion stems / flowers (line segments) ──
                for dandelion in simulation.rainDandelions {
                    drawRainDandelion(dandelion, aspect: aspect, write: writeRainVertex)
                }
                
                // (seeds moved to point pass below)
                
                let lineVertexCount = vertexCount - lineVertexStart
                if lineVertexCount > 0 {
                    renderEncoder.drawPrimitives(type: .line, vertexStart: lineVertexStart, vertexCount: lineVertexCount)
                }
                
                // --- Pass 2: Points (ball + particles) ---
                renderEncoder.setRenderPipelineState(rainPointPipeline)
                
                let pointVertexStart = vertexCount
                
                // Balls (red when inside a block, white otherwise)
                for ball in simulation.rainBalls {
                    let ballScreenSize = ball.radius * Float(view.drawableSize.height) * 2.0
                    if ball.insideBlock {
                        writeRainVertex(x: ball.pos.x, y: ball.pos.y,
                                       r: 1, g: 0, b: 0, a: 1, size: max(ballScreenSize, 4))
                    } else {
                        writeRainVertex(x: ball.pos.x, y: ball.pos.y,
                                       r: 1, g: 1, b: 1, a: 1, size: max(ballScreenSize, 4))
                    }
                }
                
                // Particles — twinkling dots (キラキラ点滅)
                let currentTime = Float(CACurrentMediaTime())
                for particle in simulation.rainParticles {
                    // キラキラ点滅: sin波で明滅しながら飛んでいく
                    let twinkle = (sin(currentTime * 12.0 + particle.position.x * 50.0 + particle.position.y * 37.0) + 1.0) * 0.5
                    let alpha = particle.life * (0.2 + twinkle * 0.8) * 0.9
                    let pSize = max(particle.life * 5.0 * (0.4 + twinkle * 0.6), 1.5)
                    writeRainVertex(x: particle.position.x, y: particle.position.y,
                                   r: 1, g: 1, b: 1, a: alpha,
                                   size: pSize)
                }
                
                // Dandelion glow ball — seedHead(綿毛)だけボールと同じ表現
                let ballScreenR = 0.012 * Float(view.drawableSize.height) * 2.0
                for dandelion in simulation.rainDandelions {
                    let stemH = dandelionPointStemHeight(dandelion)
                    let dUp = dandelion.growDirection
                    let dRight = SIMD2<Float>(-dUp.y, dUp.x)
                    // 揺れオフセット（先端 t=1.0）— aspect補正付き
                    let dSwayVal = sin(dandelion.totalAge * 3.5 + dandelion.swayPhase) * dandelion.swayAmount * 0.012
                    let headPos = dandelion.position
                        + SIMD2<Float>(dUp.x * stemH, dUp.y * stemH * aspect)
                        + SIMD2<Float>(dRight.x * dSwayVal, dRight.y * dSwayVal * aspect)
                    let fa = dandelion.fadeAlpha
                    if dandelion.stage == .seedHead || dandelion.stage == .dispersing {
                        // 綿毛/飛散中 — グロー球をフェードアウト表示
                        writeRainVertex(x: headPos.x, y: headPos.y,
                                       r: 1, g: 1, b: 1, a: fa, size: max(ballScreenR * fa, 4))
                    }
                }
                
                // Dispersing seeds — twinkling dots (point sprites)
                for dandelion in simulation.rainDandelions where dandelion.stage == .dispersing {
                    for seed in dandelion.seeds {
                        // キラキラ点滅: sin波で明滅
                        let twinkle = (sin(currentTime * 18.0 + seed.angle * 7.0) + 1.0) * 0.5  // 0..1 faster blink
                        let alpha = seed.life * (0.05 + twinkle * 0.95) * dandelion.fadeAlpha
                        let dotSize: Float = max(seed.life * 5.0 * (0.3 + twinkle * 0.7), 1.5)
                        writeRainVertex(x: seed.position.x, y: seed.position.y,
                                       r: 1, g: 1, b: 1, a: alpha, size: dotSize)
                    }
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
    
    /// Draw a single character using line segments for RAIN block note names
    /// Uses a simple vector font. x,y = top-left corner, w/h = character cell size.
    private func drawRainChar(
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
    
    /// Stem height for point-sprite glow ball positioning (must match line drawing)
    private func dandelionPointStemHeight(_ d: RainDandelion) -> Float {
        switch d.stage {
        case .sprout:       return 0.008
        case .doubleLeaves: return 0.016
        case .leavesSpread: return 0.028
        case .bud:          return 0.036
        case .bloom:        return 0.040
        case .wither:       return 0.040
        case .seedHead:     return 0.040
        case .dispersing:   return 0.040
        case .dead:         return 0.030
        case .dormant:      return 0.0
        }
    }
    
    /// Draw a single dandelion at its lifecycle stage using white line segments
    private func drawRainDandelion(
        _ d: RainDandelion,
        aspect: Float,
        write: (Float, Float, Float, Float, Float, Float, Float) -> Void
    ) {
        let p = d.position
        let up = d.growDirection
        let right = SIMD2<Float>(-up.y, up.x)
        let a = d.fadeAlpha
        guard a > 0.01 else { return }
        
        // Aspect correction for round circles on non-square screen
        // aspect = width/height ≈ 0.46 portrait, ≈ 2.1 landscape.
        // In NDC (0..1), Y physically stretches more in portrait. We scale
        // the Y-component of every offset vector by `ac` so shapes stay round.
        let ac = aspect
        
        // Aspect-corrected direction helpers: scale Y component by ac
        func acVec(_ v: SIMD2<Float>, _ len: Float) -> SIMD2<Float> {
            return SIMD2<Float>(v.x * len, v.y * len * ac)
        }
        
        // Entrance animation (0..1 over 0.4s)
        let ent = min(d.stageTime / 0.4, 1.0)
        
        // Stem point with sway: t=0 at base, t=1 at tip
        // 揺れはt²で先端ほど大きく、sin波でゆさゆさ
        let swayAmp = d.swayAmount * 0.012  // 揺れ幅
        let swayVal = sin(d.totalAge * 3.5 + d.swayPhase) * swayAmp
        func sp(_ t: Float, _ h: Float) -> SIMD2<Float> {
            let base = p + acVec(up, h * t)
            let sway = acVec(right, swayVal * t * t)  // 根元固定、先端で最大
            return base + sway
        }
        
        // Draw line segment
        func ln(_ a0: SIMD2<Float>, _ a1: SIMD2<Float>, _ alpha: Float = a) {
            write(a0.x, a0.y, 1, 1, 1, alpha, 1)
            write(a1.x, a1.y, 1, 1, 1, alpha, 1)
        }
        
        // Draw ellipse outline (aspect-corrected)
        func ellipse(center: SIMD2<Float>, rx: Float, ry: Float, segs: Int = 10, _ alpha: Float = a) {
            for s in 0..<segs {
                let a0 = Float(s) / Float(segs) * 2.0 * .pi
                let a1 = Float(s + 1) / Float(segs) * 2.0 * .pi
                let p0 = center + acVec(right, cos(a0) * rx) + acVec(up, sin(a0) * ry)
                let p1 = center + acVec(right, cos(a1) * rx) + acVec(up, sin(a1) * ry)
                ln(p0, p1, alpha)
            }
        }
        
        // Draw a leaf loop: a circle that passes through 'base'.
        // The circle center is offset to the side, so the loop bulges outward
        // and returns to the base — like one lobe of ∞.
        // side: +1 for right leaf, -1 for left leaf
        // r = radius of the circle loop
        func leafLoop(base: SIMD2<Float>, side: Float, r: Float, segs: Int = 12) {
            // Circle centered at (side * r, 0) from base, radius = r
            // This circle passes through base (at angle π for right, 0 for left)
            let cx = base + acVec(right, r * side)
            for s in 0..<segs {
                let a0 = Float(s) / Float(segs) * 2.0 * .pi
                let a1 = Float(s + 1) / Float(segs) * 2.0 * .pi
                let pt0 = cx + acVec(right, cos(a0) * r) + acVec(up, sin(a0) * r)
                let pt1 = cx + acVec(right, cos(a1) * r) + acVec(up, sin(a1) * r)
                ln(pt0, pt1)
            }
        }
        
        // Symmetric pair of circle loops (∞ shape — for 双葉 stage)
        // r = radius of each circle
        func leafPair(at base: SIMD2<Float>, r: Float) {
            leafLoop(base: base, side: -1, r: r)
            leafLoop(base: base, side: 1, r: r)
        }
        
        // ギザギザの葉（たんぽぽの成長した葉）
        // 根元(base)から横に広がり、鋸歯状の縁を持つ葉を片側描画
        // side: +1=右, -1=左, w=横幅, h=高さ, teeth=ギザギザ数
        func jaggedLeaf(base: SIMD2<Float>, side: Float, w: Float, h: Float, teeth: Int = 3) {
            // 葉の輪郭: base → 斜め上外側にギザギザ → 先端 → 内側を戻る
            let tipPt = base + acVec(right, w * side) + acVec(up, h * 0.7)
            var pts: [SIMD2<Float>] = [base]
            
            for t in 0..<teeth {
                let frac = Float(t + 1) / Float(teeth + 1)
                let peak = base + acVec(right, frac * w * side * 1.1) + acVec(up, h * (0.15 + frac * 0.55))
                let valley = base + acVec(right, frac * w * side * 0.8) + acVec(up, h * (0.25 + frac * 0.45))
                pts.append(peak)
                pts.append(valley)
            }
            pts.append(tipPt)
            
            // 下辺（内側）: 滑らかに戻る
            for t in stride(from: teeth - 1, through: 0, by: -1) {
                let frac = Float(t + 1) / Float(teeth + 1)
                let inner = base + acVec(right, frac * w * side * 0.45) + acVec(up, h * 0.05 * frac)
                pts.append(inner)
            }
            pts.append(base)
            
            // 線で結ぶ
            for i in 0..<(pts.count - 1) {
                ln(pts[i], pts[i + 1])
            }
        }
        
        // 左右対称のギザギザ葉ペア
        func jaggedLeafPair(base: SIMD2<Float>, w: Float, h: Float, teeth: Int = 3) {
            jaggedLeaf(base: base, side: -1, w: w, h: h, teeth: teeth)
            jaggedLeaf(base: base, side: 1, w: w, h: h, teeth: teeth)
        }
        
        // Growth progress within current stage (0.0 → 1.0 based on hitCount)
        // Hits needed per stage: sprout=5, doubleLeaves=5, leavesSpread=5, bud=4, bloom=4, wither=3, seedHead=3
        let hitsNeeded: Float
        switch d.stage {
        case .sprout:       hitsNeeded = 5
        case .doubleLeaves: hitsNeeded = 5
        case .leavesSpread: hitsNeeded = 5
        case .bud:          hitsNeeded = 4
        case .bloom:        hitsNeeded = 4
        case .wither:       hitsNeeded = 3
        case .seedHead:     hitsNeeded = 3
        default:            hitsNeeded = 1
        }
        let g = Float(d.hitCount) / hitsNeeded  // 0.0 at stage start → ~1.0 near next stage
        
        // Interpolation helper: lerp from start to end based on growth g
        func mix(_ start: Float, _ end: Float) -> Float {
            return start + (end - start) * g
        }
        
        switch d.stage {
        case .sprout:
            // 芽: 短い茎 + 先端に小さな蕾
            let h: Float = mix(0.004, 0.008) * ent
            let tip = sp(1.0, h)
            ln(p, tip)
            let cr: Float = mix(0.001, 0.003) * ent
            ellipse(center: tip + acVec(up, cr), rx: cr, ry: cr, segs: 8)
            
        case .doubleLeaves:
            // 双葉: 短い茎 + 葉ループ + 先端に小さな蕾
            let h: Float = mix(0.008, 0.016)
            let tip = sp(1.0, h)
            ln(p, tip)
            let lr: Float = mix(0.001, 0.006) * ent
            if lr > 0.001 {
                leafPair(at: tip, r: lr)
            }
            // 先端に蕾
            let budR: Float = mix(0.001, 0.002) * ent
            ellipse(center: tip + acVec(up, budR), rx: budR, ry: budR, segs: 6)
            
        case .leavesSpread:
            // ギザギザ葉のみ（双葉は消える） + 先端に蕾
            let h: Float = mix(0.016, 0.028)
            let tip = sp(1.0, h)
            ln(p, tip)
            // ギザギザ葉が成長
            let lBase = sp(0.08, h)
            let lw = mix(0.005, 0.020) * ent
            let lh = mix(0.004, 0.015) * ent
            jaggedLeafPair(base: lBase, w: lw, h: lh, teeth: 3)
            // 先端に蕾（小→大）
            let budR2: Float = mix(0.002, 0.006) * ent
            ellipse(center: tip + acVec(up, budR2), rx: budR2, ry: budR2 * 1.3, segs: 8)
            
        case .bud:
            // 蕾: ギザギザ葉（控えめサイズ） + 大きな丸い蕾
            let h: Float = mix(0.028, 0.036)
            let tip = sp(1.0, h)
            ln(p, tip)
            // ギザギザ葉（2番目の大きさでキープ）
            let lBase = sp(0.06, h)
            jaggedLeafPair(base: lBase, w: 0.020, h: 0.015, teeth: 4)
            // 蕾: 花より小さい丸
            let budR: Float = mix(0.004, 0.010) * ent
            ellipse(center: tip + acVec(up, budR), rx: budR, ry: budR)
            
        case .bloom:
            // 開花: ギザギザ葉 + 星形の花（角丸スター）
            let h: Float = 0.040
            let tip = sp(1.0, h)
            // 茎は花の下端で止める（花の中心まで描かない）
            let bloomInnerR: Float = 0.018 * ent * 0.5
            let stemEnd = tip - acVec(up, bloomInnerR)
            ln(p, stemEnd)
            // ギザギザ葉
            let lBase = sp(0.05, h)
            jaggedLeafPair(base: lBase, w: 0.020, h: 0.015, teeth: 4)
            // 花: 星形（外側と内側を交互に、丸く繋ぐ）
            let starPoints = 12
            let outerR: Float = 0.018 * ent
            let innerR: Float = outerR * 0.5
            let totalPts = starPoints * 2  // 外・内交互
            let smoothSegs = 3  // 各頂点間を滑らかに補間
            for j in 0..<totalPts {
                let ang0 = Float(j) / Float(totalPts) * 2.0 * .pi
                let ang1 = Float(j + 1) / Float(totalPts) * 2.0 * .pi
                let r0 = (j % 2 == 0) ? outerR : innerR
                let r1 = ((j + 1) % 2 == 0) ? outerR : innerR
                for s in 0..<smoothSegs {
                    let t0 = Float(s) / Float(smoothSegs)
                    let t1 = Float(s + 1) / Float(smoothSegs)
                    // 角度と半径を補間（丸みを出す）
                    let a0 = ang0 + (ang1 - ang0) * t0
                    let a1 = ang0 + (ang1 - ang0) * t1
                    let rad0 = r0 + (r1 - r0) * (t0 * t0 * (3.0 - 2.0 * t0))  // smoothstep
                    let rad1 = r0 + (r1 - r0) * (t1 * t1 * (3.0 - 2.0 * t1))
                    let pt0 = tip + acVec(right, cos(a0) * rad0) + acVec(up, sin(a0) * rad0)
                    let pt1 = tip + acVec(right, cos(a1) * rad1) + acVec(up, sin(a1) * rad1)
                    ln(pt0, pt1)
                }
            }
            
        case .wither:
            // 枯れ: 同じ星形が透明度だけ下がってフェードアウト
            let h: Float = 0.040
            let tip = sp(1.0, h)
            // 茎は花の下端で止める
            let witherInnerR: Float = 0.018 * 0.5
            let wStemEnd = tip - acVec(up, witherInnerR)
            ln(p, wStemEnd)
            // ギザギザ葉
            let lBase = sp(0.05, h)
            jaggedLeafPair(base: lBase, w: 0.020, h: 0.015, teeth: 4)
            // bloom と同じ星形、透明度だけ下がる
            let wStarPoints = 12
            let wOuterR: Float = 0.018
            let wInnerR: Float = wOuterR * 0.5
            let wTotalPts = wStarPoints * 2
            let wSmoothSegs = 3
            let fadeA = a * max(1.0 - g * 0.6, 0.3)
            for j in 0..<wTotalPts {
                let ang0 = Float(j) / Float(wTotalPts) * 2.0 * .pi
                let ang1 = Float(j + 1) / Float(wTotalPts) * 2.0 * .pi
                let r0 = (j % 2 == 0) ? wOuterR : wInnerR
                let r1 = ((j + 1) % 2 == 0) ? wOuterR : wInnerR
                for s in 0..<wSmoothSegs {
                    let t0 = Float(s) / Float(wSmoothSegs)
                    let t1 = Float(s + 1) / Float(wSmoothSegs)
                    let a0 = ang0 + (ang1 - ang0) * t0
                    let a1 = ang0 + (ang1 - ang0) * t1
                    let rad0 = r0 + (r1 - r0) * (t0 * t0 * (3.0 - 2.0 * t0))
                    let rad1 = r0 + (r1 - r0) * (t1 * t1 * (3.0 - 2.0 * t1))
                    let pt0 = tip + acVec(right, cos(a0) * rad0) + acVec(up, sin(a0) * rad0)
                    let pt1 = tip + acVec(right, cos(a1) * rad1) + acVec(up, sin(a1) * rad1)
                    ln(pt0, pt1, fadeA)
                }
            }
            
        case .seedHead:
            // 綿毛: 茎 + ギザギザ葉 — 綿毛はグロー球で描画
            let h: Float = 0.040
            let tip = sp(1.0, h)
            // 茎はグロー球の下端で止める（球半径≒0.012相当）
            let seedStemOffset: Float = 0.012
            let seedStemEnd = tip - acVec(up, seedStemOffset)
            ln(p, seedStemEnd)
            // ギザギザ葉（同サイズ維持）
            let lBase = sp(0.05, h)
            jaggedLeafPair(base: lBase, w: 0.020, h: 0.015, teeth: 4)
            
        case .dispersing:
            // 種飛散: 茎は種が消えるのに合わせてゆっくりフェードアウト
            let fadeOut = d.fadeAlpha
            if fadeOut > 0.01 {
                let h: Float = 0.040
                let tip = sp(1.0, h)
                ln(p, tip, a * fadeOut)
            }
            
        case .dead, .dormant:
            // 何も描画しない
            break
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
