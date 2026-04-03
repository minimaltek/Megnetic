//
//  MetaballSimulation.swift
//  Magnetic
//
//  CPU-side metaball physics simulation
//

import Foundation
import simd
import QuartzCore

// MARK: - Float clamping helper

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Shared Structures (must match Metal)

struct Ball {
    var data: SIMD4<Float>   // xyz = position in normalized 0..1 space (z=0.5 is center), w = radius
    
    var radius: Float {
        get { data.w }
        set { data.w = newValue }
    }
    
    /// XYZ position as SIMD3 (for physics calculations)
    var pos: SIMD3<Float> {
        get { SIMD3<Float>(data.x, data.y, data.z) }
        set { data.x = newValue.x; data.y = newValue.y; data.z = newValue.z }
    }
    
    init(position: SIMD3<Float>, radius: Float) {
        self.data = SIMD4<Float>(position.x, position.y, position.z, radius)
    }
}

struct TouchPoint {
    var position: SIMD2<Float>
    var strength: Float
    var active: Float
}

struct SimParams {
    var time: Float = 0
    var bassEnergy: Float = 0
    var midEnergy: Float = 0
    var highEnergy: Float = 0
    var ballCount: UInt32 = 0
    var gridWidth: UInt32 = 0
    var gridHeight: UInt32 = 0
    var threshold: Float = 1.0
    var screenAspect: Float = 1.0
    var touchCount: UInt32 = 0
    var animSpeed: Float = 1.0
    // Camera orientation as 3x3 matrix columns (avoid SIMD3 alignment issues)
    var camR0: Float = 1; var camR1: Float = 0; var camR2: Float = 0  // right
    var camU0: Float = 0; var camU1: Float = 1; var camU2: Float = 0  // up
    var camF0: Float = 0; var camF1: Float = 0; var camF2: Float = -1 // -forward
    var cameraDistance: Float = 4.0
    var materialMode: UInt32 = 0    // 0=black, 1=mercury, 2=wireframe, 3=custom color
    var colorHue: Float = 0         // 0..1 hue for custom color mode
    var colorBri: Float = 0.9       // 0..1 brightness for custom color mode
    var envMapIndex: UInt32 = 0     // 0=none (procedural), 1-5=HDRI maps
    var envIntensity: Float = 1.0   // HDRI brightness multiplier
    var bgMode: UInt32 = 0          // 0=white, 1=black, 2=green, 3=custom color
    var bgR: Float = 0              // custom background color R
    var bgG: Float = 0              // custom background color G
    var bgB: Float = 0              // custom background color B
    var envLocked: UInt32 = 0       // 0=FREE(camera-relative), 1=FIXED(天地固定), 2=FRONT(camera-local)
    var blendK: Float = 0.35        // smin blend factor (0.05=sharp, 1.0=gooey)
}

// MARK: - Orbit Pattern

enum OrbitPattern: Int, CaseIterable {
    case random = 0
    case circle = 1
    case sphere = 2
    case torus = 3
    case spiral = 4
    case satellite = 5
    case dna = 6
    case figure8 = 7
    case wave = 8
    case lines = 9
    case box = 11
    case polygon = 12
}

/// Noise type for BOX sculpture
enum BoxNoiseType: Int, CaseIterable {
    case perlin = 0
    case voronoi = 1
    case simplex = 2
    case fbm = 3
    
    var name: String {
        switch self {
        case .perlin:  return "PERLIN"
        case .voronoi: return "VORONOI"
        case .simplex: return "SIMPLEX"
        case .fbm:     return "FBM"
        }
    }
}

// MARK: - Frequency Band Role

/// Each metaball is assigned a frequency band that determines its size and reactivity.
/// Bass = large, slow throb; Mid = medium, moderate pulse; High = small, twitchy/jittery.
enum FreqBand {
    case bass   // 0–120 Hz: kick drums, sub-bass → large balls, heavy mass
    case mid    // 120–2000 Hz: snare, melodic → medium balls, moderate reactivity
    case high   // 2000 Hz+: hi-hats, cymbals → small balls, light mass, rapid jitter
}

// MARK: - Line Segment (for LINES pattern)

struct LineSegment {
    var start: SIMD3<Float>   // endpoint A in normalized 0..1 space
    var end: SIMD3<Float>     // endpoint B (final target)
    var color: SIMD4<Float>   // RGBA
    var progress: Float = 0   // 0..1, how much of the line has been drawn
    var drawSpeed: Float = 1.0 // progress units per second
    var hueT: Float = 0       // tracer position on orbit (0..1), used for triadic color spread
    
    /// Current visible endpoint (interpolated from start toward end)
    var currentEnd: SIMD3<Float> {
        return start + (end - start) * min(progress, 1.0)
    }
}

// MARK: - Box Instance (for BOX pattern)

struct BoxInstance {
    var position: SIMD3<Float>   // center of box in normalized 0..1 space
    var scale: SIMD3<Float>      // (width, height, depth)
    var rotation: SIMD3<Float>   // Euler angles (radians) for XYZ rotation
    var color: SIMD4<Float>      // RGBA
}

// MARK: - RAIN (Play) Game Structures

struct RainBlock {
    var rect: SIMD4<Float>    // (x, y, width, height) in normalized 0..1 space
    var midiNote: UInt8 = 60  // MIDI note number (C4=60, set at creation, used for sound)
    var noteName: String = "" // display name (e.g. "A", "C#") — empty when scale is OFF
    var hitScale: Float = 0   // 0..1, briefly 1.0 on hit then decays — drives visual pop
}

struct RainParticle {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var life: Float           // 1.0 → 0.0, removed when <= 0
}

struct RainBall {
    var pos: SIMD2<Float>
    var vel: SIMD2<Float>
    var radius: Float
    var bounceCount: Int = 0   // Floor bounce count (Fall mode only)
    var insideBlock: Bool = false  // True when ball center is inside a block (debug)
}

enum DandelionStage: Int {
    case sprout = 0       // 芽 — tiny curving stem + leaf tip
    case doubleLeaves = 1 // 双葉 — two small leaves on short stem
    case leavesSpread = 2 // 葉が広がる — larger leaves, taller stem
    case bud = 3          // 蕾 — stem with closed bud on top
    case bloom = 4        // 開花 — full radial petals
    case wither = 5       // 枯れ — flower droops
    case seedHead = 6     // 綿毛 — round puff ball
    case dispersing = 7   // 種が飛ぶ — seeds flying with physics
    case dead = 8         // 枯れ茎 — fading out
    case dormant = 9      // 休眠 — invisible, waiting for hits to regrow
}

struct RainDandelionSeed {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var angle: Float        // rotation for visual "/" line
    var life: Float         // 1.0 → 0.0
    var driftSpeed: Float   // per-seed random drift speed for natural dispersal
}

struct RainDandelion {
    var position: SIMD2<Float>       // anchor point on collision surface
    var growDirection: SIMD2<Float>  // surface normal (growth direction)
    var stage: DandelionStage = .sprout
    var stageTime: Float = 0        // elapsed time in current stage
    var totalAge: Float = 0
    var seeds: [RainDandelionSeed] = []
    var fadeAlpha: Float = 1.0
    var swayPhase: Float = 0        // random sway offset
    var swayAmount: Float = 0       // sway intensity (1.0 on hit, decays to 0)
    var hitCount: Int = 0           // hits accumulated in current stage
}

// MARK: - Simulation

final class MetaballSimulation {
    
    var balls: [Ball] = []
    var velocities: [SIMD3<Float>] = []
    /// Rest positions in 3D (0..1 normalized, center = 0.5)
    var restPositions: [SIMD3<Float>] = []
    var orbitAngles: [Float] = []
    var orbitRadii: [Float] = []
    var orbitSpeeds: [Float] = []
    var baseRadii: [Float] = []
    // Legacy 2D orbit centers (used only for random pattern)
    var orbitCenters: [SIMD2<Float>] = []
    /// Frequency band role per ball (determines size and audio reactivity)
    var freqBands: [FreqBand] = []
    
    var touchPoints: [TouchPoint] = Array(repeating: TouchPoint(position: .zero, strength: 0, active: 0), count: 10)
    
    var time: Float = 0
    var bassEnergy: Float = 0
    var midEnergy: Float = 0
    var highEnergy: Float = 0
    var animSpeed: Float = 1.0
    
    // BPM-predicted beat pulse (from AudioEngine)
    var predictedBeatPulse: Float = 0
    
    // Current orbit pattern
    var orbitPattern: OrbitPattern = .random
    
    // LINES pattern state
    var accumulatedLines: [LineSegment] = []
    var linesElapsedTime: Float = 0
    /// Sub-orbit pattern for LINE mode: 0=RND (walkers), 1-8=orbit paths (CRC..WAV)
    var lineSubOrbit: Int = 0
    /// Base color for line segments (white on black background)
    private let lineBaseColor: SIMD3<Float> = SIMD3<Float>(1, 1, 1)
    /// Speed multiplier for line drawing (set externally based on BPM)
    var lineSpeedMultiplier: Float = 2.0
    private var lineSpawnTimer: Float = 0
    /// Active walkers (ants) — each walks a connected path
    private var lineWalkers: [LineWalker] = []
    /// Active orbit tracers — each follows an orbit path drawing lines
    private var orbitTracers: [OrbitTracer] = []
    /// GRID OFF: base drift direction (all tracers mirror this for crystal symmetry)
    private var gridOffBaseDrift: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    /// Polygon sides for RAIN orbit (3=triangle, 4=square, ..., 8=octagon)
    var polygonSides: Int = 4
    /// Polygon inset factor: 0 = normal polygon, 1 = fully collapsed midpoints to center (star shape)
    var polygonInset: Float = 0.0
    
    // BOX pattern state — Noise sculpture with hysteresis
    var boxInstances: [BoxInstance] = []
    var boxElapsedTime: Float = 0
    var boxSpeedMultiplier: Float = 1.0
    var boxDensity: Float = 10                        // maps from ballCount (4..20), controls voxel density
    private let boxGridRes: Int = 16          // 16^3 grid = 4,096 candidates
    private let boxMaxInstances: Int = 1024
    var fftMagnitudes: [Float] = [Float](repeating: 0, count: 512)
    // Noise type and crossfade
    var boxNoiseType: BoxNoiseType = .perlin
    private var boxPrevNoiseType: BoxNoiseType = .perlin
    private var boxCrossfade: Float = 1.0     // 1.0 = fully current, 0..1 = transitioning
    private var boxCrossfadeDir: Float = 0    // 0 = idle, >0 = transitioning
    // Per-cell hysteresis: tracks which cells are currently "on"
    private var boxCellAlpha: [Float] = []    // alpha per grid cell (0..1), indexed by flat grid index
    
    // RAIN (Play) game state
    var rainBalls: [RainBall] = []
    var rainBallCount: Int = 1  // 1-4, set from UI
    var rainBlocks: [RainBlock] = []
    var rainParticles: [RainParticle] = []
    var rainSpeedMultiplier: Float = 1.0
    var rainPendingBlock: SIMD4<Float>? = nil
    var rainPaused: Bool = false
    
    // Fall sub-category
    var rainCategory: Int = 0              // 0=Fall, 1=PinBall
    var rainFallPipePositions: [Float] = [] // X positions of pipes in normalized space
    var rainFallLastBeatTime: Double = 0   // CACurrentMediaTime of bar start
    var rainFallNextPipeIndex: Int = 0     // Which pipe spawns next within current bar
    private var rainPrevCategory: Int = 0  // For detecting category changes
    var rainScreenAspect: Float = 1.0
    /// Arena insets in normalized 0..1 space (set by renderer from safe area + UI margins)
    var rainArenaTop: Float = 0.08
    var rainArenaBottom: Float = 0.12
    var rainArenaLeft: Float = 0.03
    var rainArenaRight: Float = 0.03
    /// Collision events consumed by renderer for sound playback (cleared each frame)
    var rainWallHit: Bool = false
    var rainBlockHit: Bool = false
    /// Wall/floor hit animation scale (1.0 = just hit, decays to 0)
    var rainWallHitScale: Float = 0
    /// MIDI note of the block that was hit (pre-computed at block creation)
    var rainBlockHitMidiNote: UInt8 = 60
    
    // Dandelion lifecycle
    var rainDandelions: [RainDandelion] = []
    private let maxDandelions = 20
    
    // Ball size multiplier (user-adjustable, 0.3..3.0, default 1.0)
    var ballSizeMultiplier: Float = 1.0
    
    // Spacing multiplier: controls minimum distance between balls (0.5..2.0, default 1.0)
    var spacingMultiplier: Float = 1.0
    
    // Orbit range multiplier: scales orbit radii (0.3..2.0, default 1.0)
    var orbitRangeMultiplier: Float = 1.0
    
    // Grid mode: balls follow the path like a flock of birds (geometric patterns only)
    var gridMode: Bool = false
    
    // Audio reactivity multiplier (driven by sensitivity slider, 0.5..3.0, default 1.5)
    var reactivity: Float = 1.0
    
    // Mic input level (0..1, for clipping/frenzy detection)
    var inputLevel: Float = 0
    
    // Detected BPM from AudioEngine (for orbit speed sync)
    var detectedBPM: Float = 0
    
    // Long-press zoom: when true, orbit shrinks gradually; when false, restores
    var longPressActive: Bool = false
    /// Current long-press orbit shrink factor (0=no shrink, 1=fully shrunk)
    private(set) var longPressProgress: Float = 0
    
    // Reference ball count: 30 balls = full shape. Fewer balls = partial arc.
    private let refCount: Int = 30
    
    var ballCount: Int {
        balls.count
    }
    
    init(count: Int = 10) {
        resetBalls(count: count)
    }
    
    // Per-ball individual rhythm phase offsets
    var phaseOffsets: [Float] = []
    // Per-ball "personality" for size pulsing
    var pulseSpeeds: [Float] = []
    // Pre-computed per-ball jitter values (updated per frame to avoid Float.random in hot loop)
    private var jitterX: [Float] = []
    private var jitterY: [Float] = []
    private var jitterZ: [Float] = []
    private var jitterSeed: UInt32 = 0
    
    // Path-following phase per ball (0..1 position along the path, used in grid mode)
    private var pathPhases: [Float] = []
    
    // Satellite pattern: 4 orbit groups, each a tilted great circle
    private var satGroupIndex: [Int] = []      // which group (0..3) this ball belongs to
    private var satTiltX: [Float] = []         // per-GROUP tilt around X axis
    private var satTiltZ: [Float] = []         // per-GROUP tilt around Z axis
    private var satOrbitRadius: Float = 0.25   // uniform orbit radius (same for all)
    private var satGroupPhase: [Float] = [0, 0, 0, 0]  // per-group orbit phase
    private var satGroupTiltX: [Float] = [0, 0, 0, 0] // per-group tilt around X (shared by all balls in group)
    private var satGroupTiltZ: [Float] = [0, 0, 0, 0] // per-group tilt around Z
    private static let satGroupCount = 4
    

    
    func resetBalls(count: Int) {
        // TEST mode: like LINES but user places origin via long press
        // LINES mode: clear accumulated lines, no balls needed
        if orbitPattern == .lines {
            accumulatedLines = []
            fadeHeadIndex = 0
            linesElapsedTime = 0
            lineSpawnTimer = 0
            lineWalkers = []
            orbitTracers = []
            gridOffBaseDrift = SIMD3<Float>(0, 0, 0)
            balls = [Ball(position: SIMD3(0.5, 0.5, 0.5), radius: 0.001)]
            velocities = [.zero]
            restPositions = [SIMD3(0.5, 0.5, 0.5)]
            orbitCenters = [SIMD2(0.5, 0.5)]
            orbitAngles = [0]
            orbitRadii = [0]
            orbitSpeeds = [0]
            baseRadii = [0.001]
            freqBands = [.bass]
            phaseOffsets = [0]
            pulseSpeeds = [0]
            jitterX = [0]
            jitterY = [0]
            jitterZ = [0]
            pathPhases = [0]
            satGroupIndex = [0]
            satTiltX = [0]
            satTiltZ = [0]
            return
        }
        
        // BOX mode: Noise sculpture
        if orbitPattern == .box {
            boxElapsedTime = 0
            let totalCells = boxGridRes * boxGridRes * boxGridRes
            boxCellAlpha = [Float](repeating: 0, count: totalCells)
            boxCrossfade = 1.0
            boxCrossfadeDir = 0
            boxPrevNoiseType = boxNoiseType
            regenerateBoxSculpture(timeOffset: 0, dt: 1.0 / 30.0)
            
            balls = [Ball(position: SIMD3(0.5, 0.5, 0.5), radius: 0.001)]
            velocities = [.zero]
            restPositions = [SIMD3(0.5, 0.5, 0.5)]
            orbitCenters = [SIMD2(0.5, 0.5)]
            orbitAngles = [0]
            orbitRadii = [0]
            orbitSpeeds = [0]
            baseRadii = [0.001]
            freqBands = [.bass]
            phaseOffsets = [0]
            pulseSpeeds = [0]
            jitterX = [0]
            jitterY = [0]
            jitterZ = [0]
            pathPhases = [0]
            satGroupIndex = [0]
            satTiltX = [0]
            satTiltZ = [0]
            return
        }
        
        // RAIN mode: bouncing ball game
        if orbitPattern == .polygon {
            if rainCategory == 0 {
                // Fall mode: start with no balls — they spawn from pipes on beat
                rainBalls = []
                rainFallLastBeatTime = CACurrentMediaTime()  // start timing from now
                rainFallNextPipeIndex = 0
                updateFallPipePositions()
            } else {
                // PinBall mode (existing behavior)
                rainBalls = []
                for i in 0..<max(1, rainBallCount) {
                    let angle = Float.random(in: 0...(2.0 * Float.pi))
                    let offset = Float(i) * 0.1
                    rainBalls.append(RainBall(
                        pos: SIMD2(0.5 + offset - Float(max(1, rainBallCount) - 1) * 0.05, 0.5),
                        vel: SIMD2(cos(angle), sin(angle)),
                        radius: 0.012
                    ))
                }
            }
            rainPrevCategory = rainCategory
            rainBlocks = []
            rainParticles = []
            rainDandelions = []
            rainPendingBlock = nil
            rainPaused = false
            
            balls = [Ball(position: SIMD3(0.5, 0.5, 0.5), radius: 0.001)]
            velocities = [.zero]
            restPositions = [SIMD3(0.5, 0.5, 0.5)]
            orbitCenters = [SIMD2(0.5, 0.5)]
            orbitAngles = [0]
            orbitRadii = [0]
            orbitSpeeds = [0]
            baseRadii = [0.001]
            freqBands = [.bass]
            phaseOffsets = [0]
            pulseSpeeds = [0]
            jitterX = [0]
            jitterY = [0]
            jitterZ = [0]
            pathPhases = [0]
            satGroupIndex = [0]
            satTiltX = [0]
            satTiltZ = [0]
            return
        }
        
        // SAT mode: double the ball count for 4 orbits with enough balls per line
        let count = (orbitPattern == .satellite) ? count * 2 : count
        balls = []
        velocities = []
        restPositions = []
        orbitCenters = []
        orbitAngles = []
        orbitRadii = []
        orbitSpeeds = []
        baseRadii = []
        freqBands = []
        phaseOffsets = []
        pulseSpeeds = []
        jitterX = [Float](repeating: 0, count: count)
        jitterY = [Float](repeating: 0, count: count)
        jitterZ = [Float](repeating: 0, count: count)
        pathPhases = []
        satGroupIndex = []
        satTiltX = []
        satTiltZ = []

        // Paired groups start on opposite sides (~π offset)
        // Pairs: 0&2, 1&3. Each pair is ~π/2 apart from the other pair.
        let jitter0 = Float.random(in: -0.2...0.2)
        let jitter1 = Float.random(in: -0.2...0.2)
        // Group 0 starts at ~0, Group 2 (its pair) at ~π (opposite)
        // Group 1 starts at ~π/2, Group 3 (its pair) at ~3π/2 (opposite)
        satGroupPhase = [
            0 + jitter0,                          // group 0
            Float.pi / 2.0 + jitter1,             // group 1 (~90° away from 0)
            Float.pi + jitter0,                    // group 2 (opposite of 0)
            Float.pi * 3.0 / 2.0 + jitter1        // group 3 (opposite of 1)
        ]
        // Generate per-GROUP tilt once (all balls in a group share the same orbit plane)
        // 4 groups each occupy a distinct 30° sector of the unit circle (no overlap)
        // Group 0 (red):   60°~ 90° (π/3 ~ π/2)
        // Group 1 (yellow): 30°~ 60° (π/6 ~ π/3)
        // Group 2 (blue):  330°~360° (-π/6 ~ 0)
        // Group 3 (cyan):  300°~330° (-π/3 ~ -π/6)
        satGroupTiltX = [
            Float.random(in: (Float.pi / 3)...(Float.pi / 2)),       // group 0: 60°~90°
            Float.random(in: (Float.pi / 6)...(Float.pi / 3)),       // group 1: 30°~60°
            Float.random(in: (-Float.pi / 6)...0),                   // group 2: 330°~360°
            Float.random(in: (-Float.pi / 3)...(-Float.pi / 6))      // group 3: 300°~330°
        ]
        satGroupTiltZ = [
            Float.random(in: -0.15...0.15),
            Float.random(in: -0.15...0.15),
            Float.random(in: -0.15...0.15),
            Float.random(in: -0.15...0.15)
        ]
        
        // Assign frequency bands: distribute bass/mid/high across all balls
        // Bass gets ~30%, Mid gets ~35%, High gets ~35%
        for i in 0..<count {
            let t = Float(i) / Float(max(count, 1))
            if t < 0.3 {
                freqBands.append(.bass)
            } else if t < 0.65 {
                freqBands.append(.mid)
            } else {
                freqBands.append(.high)
            }
        }
        
        // Spacing controls the arc span that balls occupy:
        // spacing 0.5 → ~90° arc (clustered)
        // spacing 1.0 → ~180° arc (default)
        // spacing 2.0 → 360° arc (full orbit)
        let arcFraction = spacingMultiplier * 0.5  // 0.5→0.25, 1.0→0.5, 2.0→1.0
        
        for i in 0..<count {
            // For geometric patterns, distribute balls evenly across the arc
            let spacedT: Float
            if orbitPattern != .random && count > 1 {
                // Map ball index to [0..arcFraction] so last ball is exactly at arcFraction
                spacedT = (Float(i) / Float(count - 1) * arcFraction).truncatingRemainder(dividingBy: 1.0)
            } else if orbitPattern != .random {
                spacedT = 0
            } else {
                spacedT = Float(i) / Float(max(count, 1))
            }
            
            let params = orbitParameters(for: orbitPattern, index: i, count: count, t: spacedT)
            
            let pos = SIMD3<Float>(
                params.cx + params.orbitR * cos(params.angle),
                params.cy + params.orbitR * sin(params.angle),
                params.cz
            )
            
            let scaledRadius = params.radius * ballSizeMultiplier
            balls.append(Ball(position: pos, radius: scaledRadius))
            velocities.append(.zero)
            restPositions.append(SIMD3<Float>(params.cx, params.cy, params.cz))
            orbitCenters.append(SIMD2<Float>(params.cx, params.cy))
            orbitAngles.append(params.angle)
            orbitRadii.append(params.orbitR)
            orbitSpeeds.append(params.speed)
            baseRadii.append(scaledRadius)
            phaseOffsets.append(Float.random(in: 0...(2 * .pi)))
            pulseSpeeds.append(Float.random(in: 0.8...2.5))
            // Path phase uses the same spacing-adjusted distribution
            pathPhases.append(spacedT)
            
            // Satellite: 4 orbit groups, each a tilted great circle at the SAME radius
            if orbitPattern == .satellite {
                satOrbitRadius = 0.25 * orbitRangeMultiplier
                let group = i % Self.satGroupCount
                satGroupIndex.append(group)
                if gridMode {
                    // GRID: all balls in a group share the exact same orbit plane
                    satTiltX.append(satGroupTiltX[group])
                    satTiltZ.append(satGroupTiltZ[group])
                } else {
                    // Non-GRID: each ball gets a slight random offset from the group tilt
                    satTiltX.append(satGroupTiltX[group] + Float.random(in: -0.25...0.25))
                    satTiltZ.append(satGroupTiltZ[group] + Float.random(in: -0.15...0.15))
                }
            } else {
                satGroupIndex.append(0)
                satTiltX.append(0)
                satTiltZ.append(0)
            }
            

        }
    }
    
    // MARK: - Orbit Parameter Generation
    
    private struct OrbitParams {
        var cx: Float
        var cy: Float
        var cz: Float = 0.5  // Z center (0.5 = middle)
        var angle: Float
        var orbitR: Float
        var speed: Float
        var radius: Float
    }
    
    private func orbitParameters(for pattern: OrbitPattern, index i: Int, count: Int, t: Float? = nil) -> OrbitParams {
        switch pattern {
        case .random:
            return randomOrbitParams(index: i, count: count)
        case .circle:
            return circleOrbitParams(index: i, count: count, t: t)
        case .sphere:
            return sphereOrbitParams(index: i, count: count, t: t)
        case .torus:
            return torusOrbitParams(index: i, count: count, t: t)
        case .spiral:
            return spiralOrbitParams(index: i, count: count, t: t)
        case .satellite:
            return satelliteOrbitParams(index: i, count: count, t: t)
        case .dna:
            return dnaOrbitParams(index: i, count: count, t: t)
        case .figure8:
            return figure8OrbitParams(index: i, count: count, t: t)
        case .wave:
            return waveOrbitParams(index: i, count: count, t: t)
        case .lines:
            // LINES mode doesn't use ball orbits; return dummy params
            return OrbitParams(cx: 0.5, cy: 0.5, angle: 0, orbitR: 0, speed: 0, radius: 0.001)
        case .box:
            return OrbitParams(cx: 0.5, cy: 0.5, angle: 0, orbitR: 0, speed: 0, radius: 0.001)
        case .polygon:
            return OrbitParams(cx: 0.5, cy: 0.5, angle: 0, orbitR: 0, speed: 0, radius: 0.001)
        }
    }
    
    private func ballRadius(index i: Int) -> Float {
        guard i < freqBands.count else {
            return 0.05
        }
        switch freqBands[i] {
        case .bass:
            return Float.random(in: 0.09...0.15)   // large
        case .mid:
            return Float.random(in: 0.05...0.08)   // medium
        case .high:
            return Float.random(in: 0.02...0.04)   // small
        }
    }
    
    /// Size for geometric patterns: uniform base size (traveling wave handles variation)
    private func geometricBallRadius(index i: Int) -> Float {
        return 0.045  // uniform size; traveling wave adds dynamic variation
    }
    
    private func randomOrbitParams(index i: Int, count: Int) -> OrbitParams {
        return OrbitParams(
            cx: Float.random(in: 0.2...0.8),
            cy: Float.random(in: 0.2...0.8),
            cz: Float.random(in: 0.3...0.7),
            angle: Float.random(in: 0...(2 * .pi)),
            orbitR: Float.random(in: 0.08...0.3) * orbitRangeMultiplier,
            speed: Float.random(in: 0.4...1.5) * (Bool.random() ? 1 : -1),
            radius: ballRadius(index: i)
        )
    }
    
    private func circleOrbitParams(index i: Int, count: Int, t: Float? = nil) -> OrbitParams {
        // Circle in XZ plane (horizontal ring), Y = 0.5 (center height)
        let tVal = t ?? (Float(i) / Float(refCount))
        let angle = 2 * Float.pi * tVal
        let r: Float = 0.30 * orbitRangeMultiplier
        return OrbitParams(
            cx: 0.5 + r * cos(angle),
            cy: 0.5,
            cz: 0.5 + r * sin(angle),
            angle: angle,
            orbitR: 0.0,  // no individual orbit for geometric
            speed: 0.6,
            radius: geometricBallRadius(index: i)
        )
    }
    
    private func sphereOrbitParams(index i: Int, count: Int, t tOverride: Float? = nil) -> OrbitParams {
        // Precessing great-circle: traces sphere surface continuously
        let t = tOverride ?? (Float(i) / Float(refCount))
        let sphereR: Float = 0.28 * orbitRangeMultiplier
        
        let angle = 2.0 * Float.pi * t
        let precession = 2.0 * Float.pi * 3.0 * t
        let px = sphereR * cos(angle)
        var py = sphereR * sin(angle)
        var pz: Float = 0
        let tiltAngle = Float.pi * 0.45 * sin(precession)
        let newY = py * cos(tiltAngle) - pz * sin(tiltAngle)
        let newZ = py * sin(tiltAngle) + pz * cos(tiltAngle)
        py = newY; pz = newZ
        
        return OrbitParams(
            cx: 0.5 + px,
            cy: 0.5 + py,
            cz: 0.5 + pz,
            angle: 0,
            orbitR: 0.0,
            speed: 0.6,
            radius: geometricBallRadius(index: i)
        )
    }
    
    private func torusOrbitParams(index i: Int, count: Int, t tOverride: Float? = nil) -> OrbitParams {
        let majorR: Float = 0.22 * orbitRangeMultiplier
        let minorR: Float = 0.08 * orbitRangeMultiplier
        let wraps: Float = 5.0
        
        let t = tOverride ?? (Float(i) / Float(refCount))
        
        // θ = angle around the torus ring
        let theta = 2.0 * Float.pi * t
        // φ = angle around the tube cross-section
        let phi = 2.0 * Float.pi * wraps * t
        
        // True 3D torus: ring in XZ plane, tube cross-section adds Y and radial offset
        let x = (majorR + minorR * cos(phi)) * cos(theta)
        let y = minorR * sin(phi)
        let z = (majorR + minorR * cos(phi)) * sin(theta)
        
        return OrbitParams(
            cx: 0.5 + x,
            cy: 0.5 + y,
            cz: 0.5 + z,
            angle: 0,
            orbitR: 0.0,
            speed: 0.5,
            radius: geometricBallRadius(index: i)
        )
    }
    
    private func spiralOrbitParams(index i: Int, count: Int, t tOverride: Float? = nil) -> OrbitParams {
        // Conical helix using golden angle (137.5°) for natural phyllotaxis spacing
        let goldenAngle: Float = Float.pi * (3.0 - sqrt(5.0)) // ~2.3999 rad = 137.508°
        let t = tOverride ?? (Float(i) / Float(refCount))
        let coneHeight: Float = 0.50 * orbitRangeMultiplier
        let baseRadius: Float = 0.28 * orbitRangeMultiplier
        
        // Radius shrinks from base to apex (sqrt gives more even area distribution)
        let r = baseRadius * sqrt(1.0 - t)
        // Golden angle rotation per ball — creates non-repeating spiral
        let angle = goldenAngle * Float(i)
        // Y position rises linearly, centered at 0.5
        let y = 0.5 + (t - 0.5) * coneHeight
        
        return OrbitParams(
            cx: 0.5 + r * cos(angle),
            cy: y,
            cz: 0.5 + r * sin(angle),
            angle: 0,
            orbitR: 0.0,
            speed: 0.4 + t * 1.0,
            radius: geometricBallRadius(index: i)
        )
    }
    
    private func satelliteOrbitParams(index i: Int, count: Int, t tOverride: Float? = nil) -> OrbitParams {
        // 4 orbit groups, each a tilted great circle at the SAME radius
        let orbitR: Float = 0.25 * orbitRangeMultiplier
        let group = i % Self.satGroupCount
        
        // Count balls in this group and this ball's index within the group
        var groupSize = 0
        var indexInGroup = 0
        for j in 0..<count {
            if j % Self.satGroupCount == group {
                if j < i { indexInGroup += 1 }
                groupSize += 1
            }
        }
        
        // Position within group: balls are spaced along the orbit as a line
        let groupT = Float(indexInGroup) / Float(max(groupSize, 1))
        let baseAngle = 2.0 * Float.pi * (tOverride ?? groupT)
        
        // Start on equatorial circle (XZ plane), then rotate by group tilt
        var px = orbitR * cos(baseAngle)
        var py: Float = 0
        var pz = orbitR * sin(baseAngle)
        
        if i < satTiltX.count {
            let tx = satTiltX[i]
            let tz = satTiltZ[i]
            let cy1 = py * cos(tx) - pz * sin(tx)
            let cz1 = py * sin(tx) + pz * cos(tx)
            py = cy1; pz = cz1
            let cx2 = px * cos(tz) - py * sin(tz)
            let cy2 = px * sin(tz) + py * cos(tz)
            px = cx2; py = cy2
        }
        
        // Same speed magnitude, paired groups (0&2, 1&3) rotate in opposite directions
        let spd: Float = 0.7
        let groupSpeeds: [Float] = [spd, spd, -spd, -spd]
        
        // Ball size: clear taper from head (biggest) to tail (smallest)
        let sizeT = Float(indexInGroup) / Float(max(groupSize - 1, 1))  // 0=tail, 1=front
        let taperT = sqrt(sizeT)  // sqrt: gradual taper, head doesn't dominate
        let radius: Float = 0.012 + taperT * 0.036  // 0.012 → 0.048 (4x range)
        
        return OrbitParams(
            cx: 0.5 + px,
            cy: 0.5 + py,
            cz: 0.5 + pz,
            angle: baseAngle,
            orbitR: 0.0,
            speed: groupSpeeds[group],
            radius: radius  // no ballSizeMultiplier here — applied in resetBalls
        )
    }
    
    private func dnaOrbitParams(index i: Int, count: Int, t tOverride: Float? = nil) -> OrbitParams {
        // Double helix with golden ratio vertical spacing
        let goldenRatio: Float = (1.0 + sqrt(5.0)) / 2.0  // φ ≈ 1.618
        let t = tOverride ?? (Float(i) / Float(refCount))
        let helixR: Float = 0.18 * orbitRangeMultiplier
        let height: Float = 0.55 * orbitRangeMultiplier
        let wraps: Float = 3.0
        
        // Alternate balls between strand A and strand B (180° offset)
        let strand: Float = (i % 2 == 0) ? 0 : Float.pi
        // Golden ratio modulates the twist — irrational spacing prevents exact overlap
        let goldenPhase = Float(i) / goldenRatio
        let angle = 2.0 * Float.pi * wraps * t + strand + goldenPhase
        // Golden ratio vertical spacing: fractional part of i*φ gives quasi-random uniform distribution
        let goldenT = (Float(i) * goldenRatio).truncatingRemainder(dividingBy: 1.0)
        let y = 0.5 + (goldenT - 0.5) * height
        
        return OrbitParams(
            cx: 0.5 + helixR * cos(angle),
            cy: y,
            cz: 0.5 + helixR * sin(angle),
            angle: 0,
            orbitR: 0.0,
            speed: 0.5,
            radius: geometricBallRadius(index: i)
        )
    }
    
    private func figure8OrbitParams(index i: Int, count: Int, t tOverride: Float? = nil) -> OrbitParams {
        // Lemniscate with golden angle spacing — balls distributed by φ for asymmetric beauty
        let goldenAngle: Float = Float.pi * (3.0 - sqrt(5.0)) // ~137.508°
        let scale: Float = 0.28 * orbitRangeMultiplier
        // Golden angle distributes balls at irrational intervals along the curve
        let angle = tOverride.map { 2.0 * Float.pi * $0 } ?? (goldenAngle * Float(i))
        
        // Parametric lemniscate: x = cos(t) / (1 + sin²(t)), y = sin(t)cos(t) / (1 + sin²(t))
        let sinA = sin(angle)
        let cosA = cos(angle)
        let denom = 1.0 + sinA * sinA
        let x = scale * cosA / denom
        let y = scale * sinA * cosA / denom
        // Golden ratio Z offset per ball — adds 3D depth to the figure-8
        let goldenRatio: Float = (1.0 + sqrt(5.0)) / 2.0
        let zOffset = 0.06 * orbitRangeMultiplier * sin(goldenAngle * Float(i) * goldenRatio)
        
        return OrbitParams(
            cx: 0.5 + x,
            cy: 0.5 + y,
            cz: 0.5 + zOffset,
            angle: 0,
            orbitR: 0.0,
            speed: 0.6,
            radius: geometricBallRadius(index: i)
        )
    }
    
    private func waveOrbitParams(index i: Int, count: Int, t tOverride: Float? = nil) -> OrbitParams {
        // Dual sine wave with golden ratio frequency relationship
        let goldenRatio: Float = (1.0 + sqrt(5.0)) / 2.0  // φ ≈ 1.618
        let goldenAngle: Float = Float.pi * (3.0 - sqrt(5.0))
        let t = tOverride ?? (Float(i) / Float(refCount))
        let width: Float = 0.55 * orbitRangeMultiplier
        let amplitude: Float = 0.15 * orbitRangeMultiplier
        
        // Golden angle spacing along X axis for non-uniform distribution
        let goldenT = tOverride ?? ((Float(i) * goldenAngle / (2.0 * Float.pi)).truncatingRemainder(dividingBy: 1.0))
        let x = 0.5 + (goldenT - 0.5) * width
        // Primary wave + secondary wave at golden ratio frequency — never repeats
        let y = 0.5 + amplitude * (sin(2.0 * Float.pi * 2.0 * t) + 0.3 * sin(2.0 * Float.pi * 2.0 * goldenRatio * t))
        // Z displacement: golden ratio phase creates organic 3D wave
        let z = 0.5 + amplitude * 0.5 * sin(2.0 * Float.pi * goldenRatio * t + goldenAngle)
        
        return OrbitParams(
            cx: x,
            cy: y,
            cz: z,
            angle: 0,
            orbitR: 0.0,
            speed: 0.5,
            radius: geometricBallRadius(index: i)
        )
    }
    
    /// Evaluate a point on the path for the given pattern at parameter t (0..1)
    func pathPosition(for pattern: OrbitPattern, t: Float) -> SIMD3<Float> {
        switch pattern {
        case .random:
            return SIMD3<Float>(0.5, 0.5, 0.5)
        case .sphere:
            // Looping tilted great-circle that precesses around Y axis
            // This traces the sphere surface continuously and loops seamlessly
            let sphereR: Float = 0.28 * orbitRangeMultiplier
            // Primary orbit: circle in XZ plane
            let angle = 2.0 * Float.pi * t
            // Precession: orbit plane slowly tilts as t advances (3 full precession cycles per loop)
            let precession = 2.0 * Float.pi * 3.0 * t
            // Start on equatorial circle
            let px = sphereR * cos(angle)
            var py = sphereR * sin(angle)
            var pz: Float = 0
            // Tilt the orbit plane around X axis by a precessing angle
            let tiltAngle = Float.pi * 0.45 * sin(precession)  // tilt oscillates ±81°
            let newY = py * cos(tiltAngle) - pz * sin(tiltAngle)
            let newZ = py * sin(tiltAngle) + pz * cos(tiltAngle)
            py = newY; pz = newZ
            return SIMD3<Float>(0.5 + px, 0.5 + py, 0.5 + pz)
        case .satellite:
            // Tilted great-circle orbit on a sphere at constant radius
            let orbitR: Float = 0.25 * orbitRangeMultiplier
            let angle = 2.0 * Float.pi * t
            // Orbit tilted ~50° for a nice diagonal path
            let tilt: Float = 0.87  // radians (~50°)
            let x = orbitR * cos(angle)
            let y = orbitR * sin(angle) * sin(tilt)
            let z = orbitR * sin(angle) * cos(tilt)
            return SIMD3<Float>(0.5 + x, 0.5 + y, 0.5 + z)
        default:
            // All other geometric patterns: evaluate via orbit params
            let params = orbitParameters(for: pattern, index: 0, count: 1, t: t)
            return SIMD3<Float>(params.cx, params.cy, params.cz)
        }
    }
    
    // Global turntable angle for geometric patterns (zoetrope rotation)
    private var turntableAngle: Float = 0
    
    // --- Smoothed energy accumulators ---
    private var smoothBass: Float = 0
    private var smoothMid: Float = 0
    private var smoothHigh: Float = 0
    private var prevSmoothBass: Float = 0
    
    // Slow-moving energy: tracks overall "loudness" over seconds
    private var energyLevel: Float = 0      // 0..1, slow accumulator of total energy
    
    // Beat state
    private var beatPulse: Float = 0        // 0..1, raw spike from BPM
    private var smoothBeat: Float = 0       // smoothed beat for rendering
    private var beatPhaseAnim: Float = 1    // 0..1, heartbeat cycle (1 = idle)
    
    // Frenzy state: smoothed clipping intensity (0..1)
    private var smoothFrenzy: Float = 0
    private var frenzyFlickActive: Bool = false
    private var frenzyFlickVelocity: Float = 0
    private var frenzyFlickDirection: Float = 1.0  // alternates +1/-1 when camMode is on
    private var frenzyFlickCooldown: Float = 0     // seconds remaining before next flick allowed
    
    // CAM mode flag (for alternating frenzy flick direction)
    var camMode: Bool = false
    
    /// Sanitize a Float: replace NaN/Inf with a fallback value
    private func sanitize(_ v: Float, fallback: Float = 0) -> Float {
        v.isFinite ? v : fallback
    }
    
    // MARK: - RAIN Helpers
    
    private func spawnRainParticles(at position: SIMD2<Float>, normal: SIMD2<Float>, count: Int = 6) {
        for _ in 0..<count {
            let spread = Float.random(in: -0.3...0.3)
            let speed = Float.random(in: 0.15...0.35)
            let perpX = -normal.y
            let perpY = normal.x
            let dir = SIMD2<Float>(
                normal.x * speed + perpX * spread * speed,
                normal.y * speed + perpY * spread * speed
            )
            let particle = RainParticle(
                position: position,
                velocity: dir,
                life: 1.0
            )
            rainParticles.append(particle)
        }
        if rainParticles.count > 800 {
            rainParticles.removeFirst(rainParticles.count - 800)
        }
    }
    
    // MARK: - Dandelion Lifecycle
    
    private let dandelionProximity: Float = 0.03
    
    func handleDandelionHit(at position: SIMD2<Float>, normal: SIMD2<Float>) {
        // Find nearby existing dandelion that can still grow or is dormant
        var closestIndex: Int? = nil
        var closestDist: Float = dandelionProximity
        
        for i in 0..<rainDandelions.count {
            let stage = rainDandelions[i].stage
            // Allow hits on growing stages and dormant stage
            guard stage.rawValue < DandelionStage.dispersing.rawValue || stage == .dormant else { continue }
            let dist = simd_length(rainDandelions[i].position - position)
            if dist < closestDist {
                closestDist = dist
                closestIndex = i
            }
        }
        
        if let idx = closestIndex {
            if rainDandelions[idx].stage == .dormant {
                // Dormant: count hits, regrow after 5
                rainDandelions[idx].hitCount += 1
                if rainDandelions[idx].hitCount >= 5 {
                    rainDandelions[idx].stage = .sprout
                    rainDandelions[idx].stageTime = 0
                    rainDandelions[idx].hitCount = 0
                    rainDandelions[idx].fadeAlpha = 1.0
                    rainDandelions[idx].totalAge = 0
                }
            } else {
                rainDandelions[idx].hitCount += 1
                // ヒットで揺れを発生（全ステージ）
                rainDandelions[idx].swayAmount = 1.0
                let hitsNeeded = hitsForStage(rainDandelions[idx].stage)
                if rainDandelions[idx].hitCount >= hitsNeeded {
                    rainDandelions[idx].hitCount = 0
                    advanceDandelion(at: idx)
                }
            }
        } else {
            spawnDandelion(at: position, normal: normal)
        }
    }
    
    private func advanceDandelion(at index: Int) {
        let current = rainDandelions[index].stage
        guard current.rawValue < DandelionStage.dispersing.rawValue,
              let next = DandelionStage(rawValue: current.rawValue + 1) else { return }
        rainDandelions[index].stage = next
        rainDandelions[index].stageTime = 0
        if next == .dispersing {
            spawnDandelionSeeds(for: &rainDandelions[index])
        }
    }
    
    private func hitsForStage(_ stage: DandelionStage) -> Int {
        switch stage {
        case .sprout:       return 5   // 芽 → 双葉
        case .doubleLeaves: return 5   // 双葉 → 葉が広がる
        case .leavesSpread: return 5   // 葉 → 蕾
        case .bud:          return 4   // 蕾 → 開花
        case .bloom:        return 4   // 開花 → 枯れ（花を楽しむ）
        case .wither:       return 2   // 枯れ → 綿毛
        case .seedHead:     return 2   // 綿毛 → 種が飛ぶ
        default:            return 1
        }
    }
    
    private func spawnDandelion(at position: SIMD2<Float>, normal: SIMD2<Float>) {
        let d = RainDandelion(
            position: position,
            growDirection: normal,
            stage: .sprout,
            stageTime: 0,
            totalAge: 0,
            seeds: [],
            fadeAlpha: 1.0,
            swayPhase: Float.random(in: 0...(2 * .pi))
        )
        rainDandelions.append(d)
        if rainDandelions.count > maxDandelions {
            if let deadIdx = rainDandelions.firstIndex(where: { $0.stage == .dead }) {
                rainDandelions.remove(at: deadIdx)
            } else {
                rainDandelions.removeFirst()
            }
        }
    }
    
    private func spawnDandelionSeeds(for dandelion: inout RainDandelion) {
        let stemH = dandelionStemHeight(for: dandelion.stage)
        let dir = dandelion.growDirection
        let acDir = SIMD2<Float>(dir.x * stemH, dir.y * stemH * rainScreenAspect)
        let headCenter = dandelion.position + acDir
        let seedCount = 180
        let ballR: Float = 0.006  // グロー球の内側に密集（小さい円）
        for j in 0..<seedCount {
            // 円の内部にランダム分布（中心に密集）
            let baseAngle = Float(j) / Float(seedCount) * 2.0 * .pi + Float.random(in: -0.3...0.3)
            let rFrac = sqrt(Float.random(in: 0...1))  // sqrt で均一面積分布
            let r = ballR * rFrac
            let startPos = headCenter + SIMD2<Float>(cos(baseAngle) * r, sin(baseAngle) * r)
            // 各種子に固有の飛散方向（大きくバラつかせる）
            let flyAngle = Float.random(in: 0...(2.0 * .pi))
            let drift = Float.random(in: 0.005...0.06)  // 速い子と遅い子の差を大きく
            let seed = RainDandelionSeed(
                position: startPos,
                velocity: SIMD2<Float>(0, 0),
                angle: flyAngle,
                life: Float.random(in: 0.7...1.0),  // 寿命もバラす
                driftSpeed: drift
            )
            dandelion.seeds.append(seed)
        }
    }
    
    private func dandelionStemHeight(for stage: DandelionStage) -> Float {
        switch stage {
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
    
    private func updateDandelions(dt: Float) {
        for i in (0..<rainDandelions.count).reversed() {
            rainDandelions[i].stageTime += dt
            rainDandelions[i].totalAge += dt
            // 揺れの減衰（ゆっくり収まる）
            if rainDandelions[i].swayAmount > 0 {
                rainDandelions[i].swayAmount *= (1.0 - dt * 1.2)
                if rainDandelions[i].swayAmount < 0.01 { rainDandelions[i].swayAmount = 0 }
            }
            
            switch rainDandelions[i].stage {
            case .sprout, .doubleLeaves, .leavesSpread, .bud, .bloom, .wither:
                break  // advance only via collision hits
                
            case .seedHead:
                // Auto-transition to dispersing after 2 seconds without hits
                if rainDandelions[i].stageTime > 2.0 {
                    rainDandelions[i].stage = .dispersing
                    rainDandelions[i].stageTime = 0
                    spawnDandelionSeeds(for: &rainDandelions[i])
                }
                
            case .dispersing:
                var allGone = true
                let stageT = rainDandelions[i].stageTime
                // 最初0.3秒は円形を維持、その後各種子が自分のペースで散る
                let rampT = min(stageT / 0.3, 1.0)  // 0→1 over 0.3s
                // 白丸＆茎をフェードアウト（2倍速）
                let disperseFade: Float = max(1.0 - stageT / 10.0, 0.0)
                rainDandelions[i].fadeAlpha = disperseFade
                let dDir = rainDandelions[i].growDirection
                let dStemH = dandelionStemHeight(for: .seedHead)
                let headCenter = rainDandelions[i].position + SIMD2<Float>(dDir.x * dStemH, dDir.y * dStemH * rainScreenAspect)
                for si in (0..<rainDandelions[i].seeds.count).reversed() {
                    let seedRef = rainDandelions[i].seeds[si]
                    // 各種子固有の飛散方向 — 上方向に偏らせる（Y負=上）
                    let rawDir = SIMD2<Float>(cos(seedRef.angle), sin(seedRef.angle))
                    let biasedDir = SIMD2<Float>(rawDir.x, min(rawDir.y, rawDir.y * 0.3 - 0.3))
                    let dLen = sqrt(biasedDir.x * biasedDir.x + biasedDir.y * biasedDir.y)
                    let driftDir = dLen > 0.001 ? biasedDir / dLen : SIMD2<Float>(0, -1)
                    // 速度1/2
                    let driftForce = driftDir * seedRef.driftSpeed * 0.5 * rampT
                    // 上昇気流（弱め）
                    let updraft = SIMD2<Float>(0.005, -0.01) * rampT
                    // スパイラル turbulence（中心からの距離と角度で渦を巻く）
                    let fromC = seedRef.position - headCenter
                    let distC = sqrt(fromC.x * fromC.x + fromC.y * fromC.y)
                    let spiralPhase = stageT * 2.0 + seedRef.angle * 3.0 + distC * 80.0
                    // 渦: 進行方向の垂直成分（螺旋運動）
                    let perpX = -driftDir.y
                    let perpY = driftDir.x
                    let spiralStrength: Float = 0.015 * rampT * min(distC * 20.0, 1.0)
                    let spiral = SIMD2<Float>(
                        perpX * sin(spiralPhase) * spiralStrength,
                        perpY * sin(spiralPhase) * spiralStrength
                    )
                    // ふわふわ揺れ（種子ごとに位相が違う）
                    let wobble = SIMD2<Float>(
                        sin(stageT * 2.0 + seedRef.angle * 5.0) * 0.006,
                        cos(stageT * 1.5 + seedRef.angle * 7.0) * 0.004
                    ) * rampT
                    rainDandelions[i].seeds[si].velocity += (driftForce + updraft + spiral + wobble) * dt
                    rainDandelions[i].seeds[si].velocity *= (1.0 - dt * 0.6)  // 強めの空気抵抗（ゆっくり漂う）
                    rainDandelions[i].seeds[si].position += rainDandelions[i].seeds[si].velocity * dt
                    rainDandelions[i].seeds[si].angle += dt * 0.2  // さらにゆっくり回転
                    rainDandelions[i].seeds[si].life -= dt * 0.005  // 寿命長め（~200秒）
                    if rainDandelions[i].seeds[si].life <= 0 {
                        rainDandelions[i].seeds.remove(at: si)
                    } else {
                        allGone = false
                    }
                }
                if allGone || rainDandelions[i].stageTime > 210.0 {
                    rainDandelions[i].stage = .dead
                    rainDandelions[i].stageTime = 0
                    rainDandelions[i].seeds = []
                }
                
            case .dead:
                // dispersingの残りalphaからさらにフェード (2秒で完全に消える)
                let deadStart = rainDandelions[i].fadeAlpha
                let deadFade = max(0, deadStart - dt / 2.0)
                rainDandelions[i].fadeAlpha = deadFade
                if rainDandelions[i].fadeAlpha <= 0 {
                    // 消えたら休眠状態に — 同じ位置で5回ヒットで再生
                    rainDandelions[i].stage = .dormant
                    rainDandelions[i].stageTime = 0
                    rainDandelions[i].hitCount = 0
                    rainDandelions[i].fadeAlpha = 0
                }
                
            case .dormant:
                // 何も描画しない。ヒットカウントは handleDandelionHit で管理
                // 長時間放置で削除（メモリ節約）
                if rainDandelions[i].stageTime > 120.0 {
                    rainDandelions.remove(at: i)
                }
            }
        }
    }
    
    // MARK: - Fall Mode Helpers
    
    /// Fixed pipe position at top-left of arena
    func updateFallPipePositions() {
        let pipeX = rainArenaLeft + 0.07
        rainFallPipePositions = [pipeX]
    }
    
    /// Fall mode physics: gravity, open right/top walls, BPM-synced spawn from pipes
    private func updateFallMode(dt: Float) {
        // BPM-driven parameters (BPM20=最低速、BPM200=旧BPM100相当)
        let bpmClamped = max(min(detectedBPM, 200), 20)
        let bpmT = (bpmClamped - 20) / (200 - 20)  // 0~1
        let gravity: Float = 0.15 + bpmT * 0.79
        // 反発率: BPM高いほど弾む (0.8 → 0.95)
        let energyLoss: Float = 0.8 + bpmT * 0.15
        let rightwardVel: Float = 0.05 + bpmT * 0.05
        
        // Arena bounds
        let maxY = 1.0 - rainArenaBottom  // Floor
        
        // Beat-synced spawning: all balls from same pipe with rhythmic timing
        // 1 ball = 1 per bar, 2 = eighth notes (♪♪), 3 = triplets, 4 = sixteenths
        let beatDuration = Double(60.0 / max(bpmClamped, 20))
        let barDuration = beatDuration * 4.0
        let now = CACurrentMediaTime()
        let count = max(1, rainBallCount)
        
        if rainFallLastBeatTime == 0 {
            rainFallLastBeatTime = now
            updateFallPipePositions()
            rainFallNextPipeIndex = 0
        }
        
        // If time has jumped far ahead (sleep/background), fast-forward
        let maxLag = barDuration * 1.5
        if now - rainFallLastBeatTime > maxLag {
            rainFallLastBeatTime = now
            rainFallNextPipeIndex = 0
            updateFallPipePositions()
        }
        
        // Spawn interval within a beat group:
        // 1 ball: full bar, 2: eighth (half-beat), 3: triplet (1/3 beat), 4: sixteenth (quarter-beat)
        let groupInterval = beatDuration / Double(count)
        let nextSpawnTime = rainFallLastBeatTime + groupInterval * Double(rainFallNextPipeIndex)
        
        if now >= nextSpawnTime {
            let pipeX = rainFallPipePositions.first ?? 0.3
            let pipeBottomY = rainArenaTop + 0.065
            rainBalls.append(RainBall(
                pos: SIMD2(pipeX, pipeBottomY),
                vel: SIMD2(rightwardVel, 0),
                radius: 0.012,
                bounceCount: 0
            ))
            rainFallNextPipeIndex += 1
            
            // All balls in this group spawned — wait for next bar, pick new pipe position
            if rainFallNextPipeIndex >= count {
                rainFallNextPipeIndex = 0
                rainFallLastBeatTime += barDuration
                updateFallPipePositions()
            }
        }
        
        // Physics for each ball (reversed for safe removal)
        for bi in (0..<rainBalls.count).reversed() {
            let r = rainBalls[bi].radius
            
            // Reset inside-block flag each frame
            rainBalls[bi].insideBlock = false
            
            // Apply gravity (positive Y = downward in this coord system)
            rainBalls[bi].vel.y += gravity * dt
            
            // Move ball
            rainBalls[bi].pos += rainBalls[bi].vel * dt
            
            // Minimum impact speed to trigger sound/particles (skip weak bounces)
            let minImpactSpeed: Float = 0.06
            
            // NO left wall — balls exit freely to the left
            
            // FLOOR (bottom wall) collision
            if rainBalls[bi].pos.y + r > maxY {
                let impactSpeed = abs(rainBalls[bi].vel.y)
                rainBalls[bi].pos.y = maxY - r
                rainBalls[bi].vel.y = -abs(rainBalls[bi].vel.y) * energyLoss
                rainBalls[bi].bounceCount += 1
                if impactSpeed > minImpactSpeed {
                    spawnRainParticles(at: SIMD2<Float>(rainBalls[bi].pos.x, maxY), normal: SIMD2<Float>(0, -1))
                    // Floor — no dandelion (Fall mode: only block top surface)
                    rainWallHit = true
                    rainWallHitScale = 1.0
                }
            }
            
            // Remove ball if it's resting on the floor with negligible velocity
            let speed = sqrt(rainBalls[bi].vel.x * rainBalls[bi].vel.x + rainBalls[bi].vel.y * rainBalls[bi].vel.y)
            if speed < 0.01 && rainBalls[bi].pos.y + r >= maxY - 0.002 {
                rainBalls.remove(at: bi)
                continue
            }
            
            // NO right wall, NO top wall — balls exit freely
            
            // Block collisions (AABB vs circle — same as PinBall)
            for i in 0..<rainBlocks.count {
                let block = rainBlocks[i]
                let bx = block.rect.x
                let by = block.rect.y
                let bw = block.rect.z
                let bh = block.rect.w
                
                let closestX = max(bx, min(rainBalls[bi].pos.x, bx + bw))
                let closestY = max(by, min(rainBalls[bi].pos.y, by + bh))
                let dx = rainBalls[bi].pos.x - closestX
                let dy = rainBalls[bi].pos.y - closestY
                let distSq = dx * dx + dy * dy
                
                if distSq < r * r {
                    let dist = sqrt(distSq)
                    if dist > 0.0001 {
                        let nx = dx / dist
                        let ny = dy / dist
                        let dot = rainBalls[bi].vel.x * nx + rainBalls[bi].vel.y * ny
                        // Standard elastic reflection
                        rainBalls[bi].vel.x -= 2.0 * dot * nx
                        rainBalls[bi].vel.y -= 2.0 * dot * ny
                        // Clamp max speed to prevent excessively large bounces
                        let spd = sqrt(rainBalls[bi].vel.x * rainBalls[bi].vel.x + rainBalls[bi].vel.y * rainBalls[bi].vel.y)
                        let maxSpd: Float = 0.6
                        if spd > maxSpd {
                            rainBalls[bi].vel.x *= maxSpd / spd
                            rainBalls[bi].vel.y *= maxSpd / spd
                        }
                        rainBalls[bi].pos.x = closestX + nx * (r + 0.002)
                        rainBalls[bi].pos.y = closestY + ny * (r + 0.002)
                        spawnRainParticles(at: SIMD2<Float>(closestX, closestY), normal: SIMD2<Float>(nx, ny))
                        // Fall mode: only spawn dandelion on block top surface (ny < -0.5)
                        if ny < -0.5 {
                            handleDandelionHit(at: SIMD2<Float>(closestX, closestY), normal: SIMD2<Float>(0, -1))
                        }
                        rainBlocks[i].hitScale = 1.0
                        rainBlockHit = true
                        rainBlockHitMidiNote = block.midiNote
                    } else {
                        // Ball center is inside block — use block top surface as hit point
                        rainBalls[bi].insideBlock = true
                        rainBalls[bi].vel.y = -rainBalls[bi].vel.y * energyLoss
                        rainBalls[bi].pos.y += (rainBalls[bi].vel.y > 0 ? 1 : -1) * (r + 0.002)
                        let hitY = by  // block top surface
                        handleDandelionHit(at: SIMD2<Float>(rainBalls[bi].pos.x, hitY), normal: SIMD2<Float>(0, -1))
                        rainBlocks[i].hitScale = 1.0
                        rainBlockHit = true
                        rainBlockHitMidiNote = block.midiNote
                    }
                }
            }
            
            // Remove ball if it exits screen (left, right, or above top)
            if rainBalls[bi].pos.x < -0.05 || rainBalls[bi].pos.x > 1.05 || rainBalls[bi].pos.y < -0.05 {
                rainBalls.remove(at: bi)
            }
        }
    }
    
    /// Fast deterministic hash for jitter (avoids Float.random in hot loop)
    private func fastHash(_ seed: UInt32) -> UInt32 {
        var x = seed
        x ^= x &<< 13
        x ^= x &>> 17
        x ^= x &<< 5
        return x
    }
    
    /// Convert hash to Float in -1...1
    private func hashToFloat(_ h: UInt32) -> Float {
        return Float(h & 0xFFFF) / 32767.5 - 1.0
    }
    
    // MARK: - LINES Pattern
    
    /// A walker (ant) that traces a connected axis-aligned path
    // MARK: - 3D Noise (for Point Cloud fluid motion)
    
    private func hash3D(_ ix: Int, _ iy: Int, _ iz: Int) -> Float {
        var h = ix &* 374761393 &+ iy &* 668265263 &+ iz &* 1274126177
        h = (h ^ (h >> 13)) &* 1274126177
        h = h ^ (h >> 16)
        return Float(h & 0x7FFFFFFF) / Float(0x7FFFFFFF)
    }
    
    private func noise3D(_ x: Float, _ y: Float, _ z: Float) -> Float {
        let ix = Int(floor(x)), iy = Int(floor(y)), iz = Int(floor(z))
        let fx = x - floor(x), fy = y - floor(y), fz = z - floor(z)
        let sx = fx * fx * (3 - 2 * fx)
        let sy = fy * fy * (3 - 2 * fy)
        let sz = fz * fz * (3 - 2 * fz)
        let c000 = hash3D(ix, iy, iz),     c100 = hash3D(ix+1, iy, iz)
        let c010 = hash3D(ix, iy+1, iz),   c110 = hash3D(ix+1, iy+1, iz)
        let c001 = hash3D(ix, iy, iz+1),   c101 = hash3D(ix+1, iy, iz+1)
        let c011 = hash3D(ix, iy+1, iz+1), c111 = hash3D(ix+1, iy+1, iz+1)
        let x00 = c000 + sx * (c100 - c000), x10 = c010 + sx * (c110 - c010)
        let x01 = c001 + sx * (c101 - c001), x11 = c011 + sx * (c111 - c011)
        let xy0 = x00 + sy * (x10 - x00), xy1 = x01 + sy * (x11 - x01)
        return xy0 + sz * (xy1 - xy0)
    }
    
    /// Curl noise: divergence-free velocity field for fluid-like motion
    private func curlNoise3D(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
        let e: Float = 0.01
        // Three offset noise fields (A at +100, B at +200, C at +300)
        let dAdy = noise3D(x, y + e, z + 100) - noise3D(x, y - e, z + 100)
        let dAdz = noise3D(x, y, z + e + 100) - noise3D(x, y, z - e + 100)
        let dBdx = noise3D(x + e, y + 200, z) - noise3D(x - e, y + 200, z)
        let dBdz = noise3D(x, y + 200, z + e) - noise3D(x, y + 200, z - e)
        let dCdx = noise3D(x + e + 300, y, z) - noise3D(x - e + 300, y, z)
        let dCdy = noise3D(x + 300, y + e, z) - noise3D(x + 300, y - e, z)
        return SIMD3<Float>(dAdy - dAdz, dBdz - dCdx, dCdy - dBdx) / (2 * e)
    }
    
    /// Fractal Brownian Motion — 4 octaves of value noise
    private func fbm3D(_ x: Float, _ y: Float, _ z: Float) -> Float {
        var value: Float = 0
        var amp: Float = 0.5
        var px = x, py = y, pz = z
        for _ in 0..<4 {
            value += noise3D(px, py, pz) * amp
            px *= 2.0; py *= 2.0; pz *= 2.0
            amp *= 0.5
        }
        return value
    }
    
    /// Voronoi (cellular) noise — returns distance to nearest cell center
    private func voronoi3D(_ x: Float, _ y: Float, _ z: Float) -> Float {
        let ix = Int(floor(x)), iy = Int(floor(y)), iz = Int(floor(z))
        let fx = x - floor(x), fy = y - floor(y), fz = z - floor(z)
        var minDist: Float = 1.0
        for dz in -1...1 {
            for dy in -1...1 {
                for dx in -1...1 {
                    let cx = hash3D(ix + dx, iy + dy, iz + dz)
                    let cy = hash3D(ix + dx + 127, iy + dy + 127, iz + dz + 127)
                    let cz = hash3D(ix + dx + 251, iy + dy + 251, iz + dz + 251)
                    let rx = Float(dx) + cx - fx
                    let ry = Float(dy) + cy - fy
                    let rz = Float(dz) + cz - fz
                    let d = rx * rx + ry * ry + rz * rz
                    minDist = min(minDist, d)
                }
            }
        }
        return sqrt(minDist)
    }
    
    /// Simplex-like noise (gradient noise approximation using 3D value noise with quintic interp)
    private func simplex3D(_ x: Float, _ y: Float, _ z: Float) -> Float {
        let ix = Int(floor(x)), iy = Int(floor(y)), iz = Int(floor(z))
        let fx = x - floor(x), fy = y - floor(y), fz = z - floor(z)
        // Quintic interpolation for smoother result
        let sx = fx * fx * fx * (fx * (fx * 6 - 15) + 10)
        let sy = fy * fy * fy * (fy * (fy * 6 - 15) + 10)
        let sz = fz * fz * fz * (fz * (fz * 6 - 15) + 10)
        let c000 = hash3D(ix, iy, iz),     c100 = hash3D(ix+1, iy, iz)
        let c010 = hash3D(ix, iy+1, iz),   c110 = hash3D(ix+1, iy+1, iz)
        let c001 = hash3D(ix, iy, iz+1),   c101 = hash3D(ix+1, iy, iz+1)
        let c011 = hash3D(ix, iy+1, iz+1), c111 = hash3D(ix+1, iy+1, iz+1)
        let x00 = c000 + sx * (c100 - c000), x10 = c010 + sx * (c110 - c010)
        let x01 = c001 + sx * (c101 - c001), x11 = c011 + sx * (c111 - c011)
        let xy0 = x00 + sy * (x10 - x00), xy1 = x01 + sy * (x11 - x01)
        return xy0 + sz * (xy1 - xy0)
    }
    
    /// Sample the noise field for a given noise type at a position
    private func sampleBoxNoise(_ type: BoxNoiseType, _ x: Float, _ y: Float, _ z: Float) -> Float {
        switch type {
        case .perlin:
            return noise3D(x, y, z)
        case .voronoi:
            // Voronoi: invert so cells become bumps (0 at center → 1)
            return 1.0 - voronoi3D(x * 0.8, y * 0.8, z * 0.8)
        case .simplex:
            return simplex3D(x, y, z)
        case .fbm:
            return fbm3D(x, y, z) * 1.1  // scale up slightly
        }
    }
    
    /// Trigger crossfade to a new noise type
    func setBoxNoiseType(_ type: BoxNoiseType) {
        guard type != boxNoiseType else { return }
        boxPrevNoiseType = boxNoiseType
        boxNoiseType = type
        boxCrossfade = 0
        boxCrossfadeDir = 1
    }
    
    /// Regenerate the voxel sculpture using noise field with hysteresis + crossfade.
    /// Uses BALL parameters: ballSizeMultiplier→cube scale, orbitRangeMultiplier→sculpture radius,
    /// spacingMultiplier→jitter/spread
    private func regenerateBoxSculpture(timeOffset: Float, dt: Float) {
        let g = boxGridRes
        let totalCells = g * g * g
        let cellSize: Float = 1.0 / Float(g)
        
        // Map BALL parameters to BOX:
        // SIZE (0.3..0.75) → cube scale multiplier
        let sizeScale = ballSizeMultiplier / 0.5      // normalize around default (0.5) → 0.6x..1.5x
        let cubeScale: Float = cellSize * 1.1 * sizeScale
        
        // ORBIT SIZE (0.3..2.0) → sculpture radius (how far from center boxes extend)
        let sculptureRadius: Float = orbitRangeMultiplier  // 1.0 = default sphere, <1 = compact, >1 = expanded
        
        // SPACING (0.5..2.0) → jitter amount + shell width (more spacing = more spread & fewer boxes)
        let spacingScale = spacingMultiplier            // 1.0 = default
        let jitterAmount: Float = cellSize * 0.45 * spacingScale
        // COUNT (4..20) → density via noise frequency and shell width boost
        // Fewer balls = lower freq = bigger blobs = sparser; More balls = higher freq = finer detail = denser
        let countNorm = (boxDensity - 4.0) / 16.0         // 0..1 (clamped by slider range)
        let noiseFreq: Float = 2.4 + countNorm * 1.6      // 2.4 (sparse) .. 4.0 (dense)
        let densityBoost: Float = countNorm * 0.06         // widen shell for higher counts
        
        let shellWidth: Float = (0.22 + densityBoost) * (1.0 + (1.0 - spacingScale) * 0.4)
        
        let threshold: Float = 0.38
        let hysteresisIn: Float = 0.12
        let hysteresisOut: Float = 0.12
        
        // Alpha fade speeds — slow enough for graceful transitions, no "pop"
        let fadeInSpeed: Float = 2.0
        let fadeOutSpeed: Float = 0.8                 // slow fade-out → dissolve, not flicker
        
        // Audio reactivity — attenuated to prevent threshold jitter
        let bassBoost = sanitize(bassEnergy).clamped(to: 0...5) * reactivity * 0.008
        let effectiveThreshold = threshold - bassBoost
        
        // Ensure alpha array is sized
        if boxCellAlpha.count != totalCells {
            boxCellAlpha = [Float](repeating: 0, count: totalCells)
        }
        
        var newInstances: [BoxInstance] = []
        newInstances.reserveCapacity(boxMaxInstances)
        
        let halfG = Float(g) / 2.0
        
        // Separate slow time for position/scale/rotation — these evolve much slower
        // so that boxes don't visibly jump around each frame
        let slowTime = timeOffset * 0.3
        
        for iz in 0..<g {
            for iy in 0..<g {
                for ix in 0..<g {
                    let idx = iz * g * g + iy * g + ix
                    
                    // Normalized coordinates centered at origin (-1..1)
                    let nx = (Float(ix) + 0.5 - halfG) / halfG
                    let ny = (Float(iy) + 0.5 - halfG) / halfG
                    let nz = (Float(iz) + 0.5 - halfG) / halfG
                    
                    // Spherical falloff — scaled by orbitRange (sculptureRadius)
                    // r is distance from center in normalized space
                    let r = sqrt(nx * nx + ny * ny + nz * nz)
                    let effectiveR = r / sculptureRadius  // larger sculptureRadius → cells further out are included
                    
                    if effectiveR > 1.2 {
                        boxCellAlpha[idx] = max(boxCellAlpha[idx] - fadeOutSpeed * dt, 0)
                        continue
                    }
                    
                    // Edge fade: smoothly reduce alpha at the boundary instead of hard cutoff
                    // This prevents the edge flickering entirely
                    let edgeFade: Float
                    if effectiveR > 0.85 {
                        // Smooth fade from r=0.85 to r=1.15 (covers the entire boundary zone)
                        let raw = max(1.0 - (effectiveR - 0.85) / 0.3, 0)
                        // Smoothstep for organic falloff
                        edgeFade = raw * raw * (3.0 - 2.0 * raw)
                    } else {
                        edgeFade = 1.0
                    }
                    
                    let sphereFalloff = max(1.0 - effectiveR * effectiveR * 0.55, 0)
                    
                    // Noise coordinates for shell test (normal time evolution)
                    let sx = Float(ix) * cellSize * noiseFreq + timeOffset
                    let sy = Float(iy) * cellSize * noiseFreq + timeOffset * 0.7
                    let sz = Float(iz) * cellSize * noiseFreq + timeOffset * 1.3
                    
                    // Sample noise (with crossfade between types)
                    let nCurrent = sampleBoxNoise(boxNoiseType, sx, sy, sz) * sphereFalloff
                    let n: Float
                    if boxCrossfadeDir > 0 && boxCrossfade < 1.0 {
                        let nPrev = sampleBoxNoise(boxPrevNoiseType, sx, sy, sz) * sphereFalloff
                        n = nPrev * (1.0 - boxCrossfade) + nCurrent * boxCrossfade
                    } else {
                        n = nCurrent
                    }
                    
                    // Shell test with hysteresis
                    let diff = n - effectiveThreshold
                    let currentAlpha = boxCellAlpha[idx]
                    
                    let shouldBeOn: Bool
                    if currentAlpha > 0.1 {
                        // Cell is currently visible — use wider band to keep it on (resist turning off)
                        shouldBeOn = diff > -(shellWidth + hysteresisOut) && diff < (shellWidth + hysteresisOut)
                    } else {
                        // Cell is currently off — use narrower band to turn it on (resist turning on)
                        shouldBeOn = diff > -(shellWidth - hysteresisIn) && diff < (shellWidth - hysteresisIn)
                    }
                    
                    // Fade alpha — modulated by edgeFade so boundary cells max out at reduced alpha
                    let targetAlpha: Float = shouldBeOn ? edgeFade : 0
                    if currentAlpha < targetAlpha {
                        boxCellAlpha[idx] = min(currentAlpha + fadeInSpeed * dt, targetAlpha)
                    } else {
                        boxCellAlpha[idx] = max(currentAlpha - fadeOutSpeed * dt, 0)
                    }
                    
                    let alpha = boxCellAlpha[idx]
                    if alpha > 0.01 && newInstances.count < boxMaxInstances {
                        // Slow noise coordinates for position/scale/rotation — decoupled from shell noise
                        // so that visual properties evolve smoothly and slowly
                        let px0 = Float(ix) * cellSize * noiseFreq + slowTime
                        let py0 = Float(iy) * cellSize * noiseFreq + slowTime * 0.7
                        let pz0 = Float(iz) * cellSize * noiseFreq + slowTime * 1.3
                        
                        // Position: grid center + noise-based jitter for organic displacement
                        let jx = noise3D(px0 * 2.0 + 31.7, py0 * 2.0 + 5.3, pz0 * 2.0 + 13.1) - 0.5
                        let jy = noise3D(px0 * 2.0 + 47.3, py0 * 2.0 + 19.7, pz0 * 2.0 + 7.9) - 0.5
                        let jz = noise3D(px0 * 2.0 + 61.1, py0 * 2.0 + 29.3, pz0 * 2.0 + 41.7) - 0.5
                        let px = (Float(ix) + 0.5) * cellSize + jx * jitterAmount
                        let py = (Float(iy) + 0.5) * cellSize + jy * jitterAmount
                        let pz = (Float(iz) + 0.5) * cellSize + jz * jitterAmount
                        
                        // Scale modulated by alpha (grow in, shrink out)
                        let scaleFactor = alpha * alpha * (3.0 - 2.0 * alpha)  // smoothstep
                        let baseS = cubeScale * scaleFactor
                        
                        // Uniform cube scaling (all boxes are perfect cubes)
                        let xMod: Float = 1.0
                        let yMod: Float = 1.0
                        let zMod: Float = 1.0
                        
                        // Per-box rotation: noise-driven Euler angles (±30°)
                        let maxRot: Float = 0.52  // ~30 degrees
                        let rx = (noise3D(px0 * 1.5 + 71.3, py0 * 1.5 + 13.7, pz0 * 1.5 + 53.9) - 0.5) * maxRot * 2.0
                        let ry = (noise3D(px0 * 1.5 + 83.1, py0 * 1.5 + 37.3, pz0 * 1.5 + 67.1) - 0.5) * maxRot * 2.0
                        let rz = (noise3D(px0 * 1.5 + 97.7, py0 * 1.5 + 51.9, pz0 * 1.5 + 79.3) - 0.5) * maxRot * 2.0
                        
                        let heightBri = 0.7 + ny * 0.15
                        let noiseBri = noise3D(px0 * 3, py0 * 3, pz0 * 3) * 0.15
                        let bri = min(max(heightBri + noiseBri, 0.55), 0.95)
                        
                        newInstances.append(BoxInstance(
                            position: SIMD3<Float>(px, py, pz),
                            scale: SIMD3<Float>(baseS * xMod, baseS * yMod, baseS * zMod),
                            rotation: SIMD3<Float>(rx, ry, rz),
                            color: SIMD4<Float>(bri, bri, bri, alpha)
                        ))
                    }
                }
            }
        }
        
        boxInstances = newInstances
    }
    
    private struct LineWalker {
        var position: SIMD3<Float>       // current head position
        var lastAxis: Int = -1           // last axis moved along (-1 = none)
        var brightness: Float            // consistent brightness for this walker
        var currentSegmentIndex: Int = -1 // index of the segment currently being drawn
        var waitTimer: Float = 0         // pause between segments
    }
    
    /// Orbit tracer: follows an orbit path by sampling sequential t values
    private struct OrbitTracer {
        var t: Float                     // current parameter position on orbit (0..1)
        var speed: Float                 // direction multiplier (+1 or -1) and speed variation
        var brightness: Float            // consistent brightness for this tracer
        var currentSegmentIndex: Int = -1 // index of segment being drawn
        var orbitIndex: Int              // which "lane" on the orbit (for satellite groups etc.)
        var tiltX: Float = 0             // per-tracer tilt for SAT pattern
        var tiltZ: Float = 0             // per-tracer tilt for SAT pattern
        var strand: Int = 0              // DNA strand index (0 or 1)
        // Spirograph: after each loop, rotate the orbit plane slightly
        var loopCount: Int = 0           // how many full loops completed
        var totalTraveled: Float = 0     // accumulated t distance to detect loop completion
        var spirographAngle: Float = 0   // accumulated rotation angle (radians)
        // Random rotation axis for spirograph (normalized, per-tracer)
        var spirographAxis: SIMD3<Float> = SIMD3<Float>(1, 0, 0)
        // GRID OFF: center orbits along a toroidal drift path
        var centerOffset: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
        var centerDrift: SIMD3<Float> = SIMD3<Float>(0, 0, 0)  // legacy
        var driftAngle: Float = 0           // current angle on drift circle
        var driftAngleStep: Float = 0       // radians per loop
        var driftRadius: Float = 0          // radius of drift circle
        var driftPlaneU: SIMD3<Float> = SIMD3<Float>(1, 0, 0) // drift circle basis U
        var driftPlaneV: SIMD3<Float> = SIMD3<Float>(0, 1, 0) // drift circle basis V
    }
    
    /// Maximum segments before oldest start fading out
    private static let maxLineSegments = 50000
    /// How many faded-out (alpha=0) segments to remove in one batch
    private static let purgeThreshold = 2000
    /// Index of the next segment to start fading (FIFO head pointer)
    private var fadeHeadIndex: Int = 0
    
    /// Gradually fade the oldest segments one-by-one as new ones are added.
    /// Called each frame; fades `newCount` segments from the head to match newly added ones.
    private func fadeOldSegmentsGradually(newCount: Int, dt: Float) {
        guard accumulatedLines.count > Self.maxLineSegments else {
            // Not at capacity yet — nothing to fade
            fadeHeadIndex = 0
            return
        }
        // Fade `newCount` segments from the head (1:1 with newly added)
        let fadeSpeed: Float = 2.0 * dt  // smooth fade over ~0.5 sec
        let end = min(fadeHeadIndex + newCount, accumulatedLines.count)
        for i in fadeHeadIndex..<end {
            accumulatedLines[i].color.w = max(accumulatedLines[i].color.w - fadeSpeed, 0)
        }
        fadeHeadIndex = end
    }
    
    /// Purge fully-transparent segments from the front of the array.
    /// Only runs when enough dead segments have accumulated to amortize the cost.
    private func purgeDeadSegments() {
        // Count consecutive dead (alpha=0) segments from the front
        var deadCount = 0
        while deadCount < accumulatedLines.count && accumulatedLines[deadCount].color.w <= 0 {
            deadCount += 1
        }
        guard deadCount >= Self.purgeThreshold else { return }
        
        accumulatedLines.removeFirst(deadCount)
        fadeHeadIndex = max(fadeHeadIndex - deadCount, 0)
        
        // Adjust walker segment indices
        for w in 0..<lineWalkers.count {
            lineWalkers[w].currentSegmentIndex -= deadCount
            if lineWalkers[w].currentSegmentIndex < 0 {
                lineWalkers[w].currentSegmentIndex = -1
            }
        }
        
        // Adjust orbit tracer segment indices
        for t in 0..<orbitTracers.count {
            orbitTracers[t].currentSegmentIndex -= deadCount
            if orbitTracers[t].currentSegmentIndex < 0 {
                orbitTracers[t].currentSegmentIndex = -1
            }
        }
        

    }
    
    /// Spawn the next segment for a walker: pick a random axis (different from last), random length, random direction
    private func nextSegmentForWalker(_ walker: inout LineWalker) {
        // Room will be made by recycling if needed; no hard cap
        
        // Pick axis different from last move (forces 90-degree turns)
        var axis: Int
        if walker.lastAxis < 0 {
            axis = Int.random(in: 0...2)
        } else {
            // Pick from the other two axes
            let options = [0, 1, 2].filter { $0 != walker.lastAxis }
            axis = options[Int.random(in: 0..<options.count)]
        }
        walker.lastAxis = axis
        
        // Random length with variety
        let lengthRoll = Float.random(in: 0...1)
        let lineLength: Float
        if lengthRoll < 0.35 {
            lineLength = Float.random(in: 0.01...0.06)   // short
        } else if lengthRoll < 0.75 {
            lineLength = Float.random(in: 0.06...0.25)    // medium
        } else {
            lineLength = Float.random(in: 0.25...0.6)     // long
        }
        
        // Random direction: positive or negative along this axis
        let direction: Float = Bool.random() ? 1.0 : -1.0
        
        var delta = SIMD3<Float>(0, 0, 0)
        delta[axis] = lineLength * direction
        
        var endPos = walker.position + delta
        
        // Clamp to 0.05...0.95 bounds and adjust length
        endPos = SIMD3(
            min(max(endPos.x, 0.05), 0.95),
            min(max(endPos.y, 0.05), 0.95),
            min(max(endPos.z, 0.05), 0.95)
        )
        
        let startPos = walker.position
        let b = walker.brightness
        let color = SIMD4<Float>(lineBaseColor.x * b, lineBaseColor.y * b, lineBaseColor.z * b, 1.0)
        
        // Draw speed: proportional to length so all segments take roughly similar time
        let actualLen = length(endPos - startPos)
        let speed = max(actualLen, 0.01) * Float.random(in: 3.0...8.0)
        
        let segIndex = accumulatedLines.count
        accumulatedLines.append(LineSegment(start: startPos, end: endPos, color: color, progress: 0, drawSpeed: speed, hueT: linesElapsedTime))
        
        walker.position = endPos
        walker.currentSegmentIndex = segIndex
    }
    
    /// Map lineSubOrbit (1-8) to the corresponding OrbitPattern for path evaluation
    private func orbitPatternForLineSubOrbit(_ subOrbit: Int) -> OrbitPattern {
        switch subOrbit {
        case 1: return .circle
        case 2: return .sphere
        case 3: return .torus
        case 4: return .spiral
        case 5: return .satellite
        case 6: return .dna
        case 7: return .figure8
        case 8: return .wave
        case 9: return .polygon
        default: return .circle
        }
    }
    
    /// How many tracers should run simultaneously for each orbit pattern
    private func tracerCountForPattern(_ subOrbit: Int) -> Int {
        switch subOrbit {
        case 1: return 1   // CRC: single circle
        case 2: return 2   // SPH: precessing great-circle, 2 tracers at different phases
        case 3: return 2   // TOR: torus knot, 2 tracers
        case 4: return 3   // SPI: spiral cone, 3 tracers at different heights
        case 5: return 4   // SAT: 4 orbit groups (core identity of the pattern)
        case 6: return 2   // DNA: 2 strands
        case 7: return 2   // FIG8: lemniscate, 2 tracers going opposite ways
        case 8: return 2   // WAV: dual wave, 2 tracers
        case 9: return 1   // RAIN: single polygon tracer
        default: return 1
        }
    }
    
    /// Evaluate orbit position for a specific tracer.
    /// For LINE spirograph mode, each pattern uses a SIMPLE base shape (single loop).
    /// The spirograph rotation handles 3D space-filling — the base shape stays simple.
    private func tracerPathPosition(pattern: OrbitPattern, t: Float, tracer: OrbitTracer) -> SIMD3<Float> {
        let r: Float = 0.28 * orbitRangeMultiplier
        let angle = 2.0 * Float.pi * t
        
        // Base shape: a simple closed curve in XZ plane (Y=0), centered at origin
        // Spirograph rotation will tilt this into 3D on each loop
        var px: Float = 0, py: Float = 0, pz: Float = 0
        
        switch pattern {
        case .circle:
            // Simple circle in XZ plane
            px = r * cos(angle)
            pz = r * sin(angle)
            
        case .sphere:
            // Sphere-filling precession: latitude sweeps while longitude rotates
            // This traces a path that naturally covers the sphere surface
            let precessionRate: Float = 7.0  // longitude rotations per latitude sweep
            let lat = Float.pi * t - Float.pi / 2.0  // -π/2 to π/2 (pole to pole)
            let lon = 2.0 * Float.pi * precessionRate * t
            px = r * cos(lat) * cos(lon)
            py = r * sin(lat)
            pz = r * cos(lat) * sin(lon)
            
        case .torus:
            // Torus cross-section: circle with a wobble
            let majorR: Float = 0.22 * orbitRangeMultiplier
            let minorR: Float = 0.08 * orbitRangeMultiplier
            let wraps: Float = 5.0
            let phi = 2.0 * Float.pi * wraps * t
            px = (majorR + minorR * cos(phi)) * cos(angle)
            py = minorR * sin(phi)
            pz = (majorR + minorR * cos(phi)) * sin(angle)
            
        case .spiral:
            // Conical spiral: radius shrinks with height
            let coneH: Float = 0.45 * orbitRangeMultiplier
            let baseR: Float = 0.25 * orbitRangeMultiplier
            let spiralR = baseR * (1.0 - t)
            px = spiralR * cos(angle * 3.0)  // 3 wraps
            py = (t - 0.5) * coneH
            pz = spiralR * sin(angle * 3.0)
            
        case .satellite:
            // Each tracer follows its own tilted great-circle orbit
            let orbitR: Float = 0.25 * orbitRangeMultiplier
            px = orbitR * cos(angle)
            pz = orbitR * sin(angle)
            // Apply per-tracer tilt
            let tx = tracer.tiltX
            let tz = tracer.tiltZ
            let cy1 = py * cos(tx) - pz * sin(tx)
            let cz1 = py * sin(tx) + pz * cos(tx)
            py = cy1; pz = cz1
            let cx2 = px * cos(tz) - py * sin(tz)
            let cy2 = px * sin(tz) + py * cos(tz)
            px = cx2; py = cy2
            
        case .dna:
            // Single helix strand
            let helixR: Float = 0.18 * orbitRangeMultiplier
            let height: Float = 0.50 * orbitRangeMultiplier
            let wraps: Float = 3.0
            let strandOffset: Float = Float(tracer.strand) * Float.pi
            px = helixR * cos(2.0 * Float.pi * wraps * t + strandOffset)
            py = (t - 0.5) * height
            pz = helixR * sin(2.0 * Float.pi * wraps * t + strandOffset)
            
        case .figure8:
            // Lemniscate (figure-8)
            let scale: Float = 0.28 * orbitRangeMultiplier
            let sinA = sin(angle)
            let cosA = cos(angle)
            let denom = 1.0 + sinA * sinA
            px = scale * cosA / denom
            pz = scale * sinA * cosA / denom
            
        case .wave:
            // Sine wave along X axis
            let width: Float = 0.50 * orbitRangeMultiplier
            let amp: Float = 0.15 * orbitRangeMultiplier
            px = (t - 0.5) * width
            py = amp * sin(angle * 2.0)
            pz = amp * 0.5 * sin(angle * 3.0)  // slight Z wobble
            
        case .polygon:
            // Regular polygon (3-8 sides) or star shape in XZ plane
            let sides = Float(max(3, min(8, polygonSides)))
            let n = Int(sides)
            // Clamp t to [0, 1) to prevent segFrac overflow at boundary
            var tc = t.truncatingRemainder(dividingBy: 1.0)
            if tc < 0 { tc += 1.0 }
            
            if polygonInset <= 0.0001 {
                // Normal polygon path (N segments)
                let segment = tc * sides
                let edgeIndex = Int(segment) % n
                let edgeFrac = segment - Float(edgeIndex)
                let a0 = 2.0 * Float.pi * Float(edgeIndex) / sides
                let a1 = 2.0 * Float.pi * Float(edgeIndex + 1) / sides
                let x0 = r * cos(a0), z0 = r * sin(a0)
                let x1 = r * cos(a1), z1 = r * sin(a1)
                px = x0 + (x1 - x0) * edgeFrac
                pz = z0 + (z1 - z0) * edgeFrac
            } else {
                // Star path: 2N segments (vertex -> inset midpoint -> next vertex -> ...)
                let totalSegs = n * 2
                let segment = tc * Float(totalSegs)
                let segIndex = Int(segment) % totalSegs
                let segFrac = segment - Float(segIndex)
                
                let edgeIndex = segIndex / 2
                let isFirstHalf = (segIndex % 2 == 0)
                
                let a0 = 2.0 * Float.pi * Float(edgeIndex) / sides
                let a1 = 2.0 * Float.pi * Float(edgeIndex + 1) / sides
                let vx0 = r * cos(a0), vz0 = r * sin(a0)
                let vx1 = r * cos(a1), vz1 = r * sin(a1)
                
                // Midpoint of edge, pulled toward center by polygonInset
                let midX = (vx0 + vx1) * 0.5 * (1.0 - polygonInset)
                let midZ = (vz0 + vz1) * 0.5 * (1.0 - polygonInset)
                
                if isFirstHalf {
                    // vertex[i] -> midpoint[i]
                    px = vx0 + (midX - vx0) * segFrac
                    pz = vz0 + (midZ - vz0) * segFrac
                } else {
                    // midpoint[i] -> vertex[i+1]
                    px = midX + (vx1 - midX) * segFrac
                    pz = midZ + (vz1 - midZ) * segFrac
                }
            }
            
        default:
            px = r * cos(angle)
            pz = r * sin(angle)
        }
        
        // Apply spirograph tilt: rotate around per-tracer random axis by accumulated angle
        let a = tracer.spirographAngle
        if abs(a) > 0.001 {
            let axis = tracer.spirographAxis
            let cosA = cos(a)
            let sinA = sin(a)
            let oneMinusCos = 1.0 - cosA
            // Rodrigues' rotation formula
            let p = SIMD3<Float>(px, py, pz)
            let dotAP = dot(axis, p)
            let crossAP = cross(axis, p)
            let rotated = p * cosA + crossAP * sinA + axis * dotAP * oneMinusCos
            px = rotated.x
            py = rotated.y
            pz = rotated.z
        }
        
        let center = SIMD3<Float>(0.5, 0.5, 0.5) + tracer.centerOffset
        return SIMD3<Float>(center.x + px, center.y + py, center.z + pz)
    }
    
    /// Angle increment per loop for spirograph effect.
    /// Each loop tilts the orbit plane by this many radians around X axis.
    /// ~3° per loop = gradual 3D filling, ~60 loops to cover half-sphere.
    private static let spirographIncrement: Float = 3.0 * Float.pi / 180.0  // 3 degrees
    
    /// Spawn the next segment for an orbit tracer: advance t and connect to next waypoint
    private func nextSegmentForOrbitTracer(_ tracer: inout OrbitTracer) {
        // Room will be made by recycling if needed; no hard cap
        
        let pattern = orbitPatternForLineSubOrbit(lineSubOrbit)
        
        // Current position on the orbit path
        let startPos = tracerPathPosition(pattern: pattern, t: tracer.t, tracer: tracer)
        
        // Step size: fine enough for smooth circles (~200 segments per loop)
        let absSpeed = abs(tracer.speed)
        let stepSize: Float = Float.random(in: 0.004...0.006) * absSpeed
        let direction: Float = tracer.speed >= 0 ? 1.0 : -1.0
        var newT = tracer.t + stepSize * direction
        tracer.totalTraveled += stepSize
        
        // Detect loop completion but DON'T update angle yet — 
        // both startPos and endPos must use the same spirographAngle
        let loopCompleted = tracer.totalTraveled >= 1.0
        
        // Wrap t to 0..1
        if newT > 1.0 { newT -= 1.0 }
        if newT < 0.0 { newT += 1.0 }
        
        // endPos uses same spirographAngle as startPos (no jump mid-segment)
        let endPos = tracerPathPosition(pattern: pattern, t: newT, tracer: tracer)
        
        // Skip the wrap-around segment for open curves (WAV, DNA) to avoid drawing
        // a line from one end to the other when t wraps from ~1.0 back to ~0.0
        let isOpenCurve = (pattern == .wave || pattern == .dna || pattern == .spiral)
        let wrappedAround = (direction > 0 && newT < tracer.t - 0.5) || (direction < 0 && newT > tracer.t + 0.5)
        let skipSegment = isOpenCurve && wrappedAround
        
        let b = tracer.brightness
        let color = SIMD4<Float>(lineBaseColor.x * b, lineBaseColor.y * b, lineBaseColor.z * b, 1.0)
        
        // Draw speed: high base speed, multiplied by lineSpeedMultiplier in update()
        let segLen = length(endPos - startPos)
        let speed = max(segLen, 0.05) * Float.random(in: 120.0...200.0)
        
        tracer.t = newT
        
        if skipSegment {
            // Don't append a segment — just update t and keep the old segment index
        } else {
            let segIndex = accumulatedLines.count
            accumulatedLines.append(LineSegment(start: startPos, end: endPos, color: color, progress: 0, drawSpeed: speed, hueT: linesElapsedTime))
            tracer.currentSegmentIndex = segIndex
        }
        
        // Apply per-loop effects
        if loopCompleted {
            tracer.loopCount += 1
            tracer.totalTraveled = 0
            
            let hasDrift = tracer.driftRadius > 0.0001
            if hasDrift {
                // GRID OFF: center orbits along a toroidal path
                tracer.driftAngle += tracer.driftAngleStep
                tracer.centerOffset = tracer.driftRadius * (
                    cos(tracer.driftAngle) * tracer.driftPlaneU +
                    sin(tracer.driftAngle) * tracer.driftPlaneV
                )
            } else {
                // GRID ON: spirograph rotation, no drift
                tracer.spirographAngle += Self.spirographIncrement
            }
        }
    }
    
    func update(dt: Float) {
        // Guard against bad dt
        let safeDt = sanitize(dt, fallback: 1.0 / 30.0)
        guard safeDt > 0 else { return }
        
        time += safeDt * animSpeed
        
        // LINES mode: walkers trace connected paths
        if orbitPattern == .lines {
            let segCountBeforeFrame = accumulatedLines.count
            linesElapsedTime += safeDt
            
            if lineSubOrbit == 0 {
                // --- RND mode: random axis-aligned walkers (existing behavior) ---
                
                // Spawn new walkers over time: start with 1, add more gradually
                let desiredWalkers: Int
                if linesElapsedTime < 2 {
                    desiredWalkers = 1
                } else if linesElapsedTime < 6 {
                    desiredWalkers = 2
                } else if linesElapsedTime < 12 {
                    desiredWalkers = 3
                } else if linesElapsedTime < 20 {
                    desiredWalkers = 5
                } else {
                    desiredWalkers = 8
                }
                
                while lineWalkers.count < desiredWalkers {
                    let startPos = SIMD3<Float>(
                        Float.random(in: 0.2...0.8),
                        Float.random(in: 0.2...0.8),
                        Float.random(in: 0.2...0.8)
                    )
                    let brightness = Float.random(in: 0.5...1.0)
                    var walker = LineWalker(position: startPos, brightness: brightness)
                    nextSegmentForWalker(&walker)
                    lineWalkers.append(walker)
                }
                
                // For each walker: batch-spawn segments based on BPM speed
                let walkerSegsPerFrame = max(1, Int(lineSpeedMultiplier * safeDt * 3))
                for w in 0..<lineWalkers.count {
                    for _ in 0..<walkerSegsPerFrame {
                        let segIdx = lineWalkers[w].currentSegmentIndex
                        if segIdx >= 0 && segIdx < accumulatedLines.count {
                            if accumulatedLines[segIdx].progress >= 1.0 {
                                lineWalkers[w].waitTimer -= safeDt
                                if lineWalkers[w].waitTimer <= 0 {
                                    lineWalkers[w].waitTimer = Float.random(in: 0.0...0.05)
                                    nextSegmentForWalker(&lineWalkers[w])
                                    // Instantly complete if speed is high enough
                                    let newIdx = lineWalkers[w].currentSegmentIndex
                                    if newIdx >= 0 && newIdx < accumulatedLines.count {
                                        let spd = accumulatedLines[newIdx].drawSpeed * lineSpeedMultiplier * safeDt
                                        if spd >= 1.0 {
                                            accumulatedLines[newIdx].progress = 1.0
                                        }
                                    }
                                } else {
                                    break
                                }
                            } else {
                                break
                            }
                        }
                    }
                }
                
            } else {
                // --- Orbit path tracing mode (CRC, SPH, TOR, SPI, SAT, DNA, FIG8, WAV) ---
                
                let pattern = orbitPatternForLineSubOrbit(lineSubOrbit)
                
                if gridMode {
                    // GRID ON: fixed number of tracers, evenly spaced on orbit
                    let desiredTracers = tracerCountForPattern(lineSubOrbit)
                    
                    while orbitTracers.count < desiredTracers {
                        let idx = orbitTracers.count
                        // All tracers start at t=0 (orbit origin) for clean layer starts
                        let baseT: Float = 0.0
                        let brightness = Float.random(in: 0.6...1.0)
                        
                        var speed: Float = Float.random(in: 0.9...1.1)
                        var tiltX: Float = 0
                        var tiltZ: Float = 0
                        var strand: Int = 0
                        
                        switch pattern {
                        case .satellite:
                            let groupSpeeds: [Float] = [1.0, 1.0, -1.0, -1.0]
                            speed = groupSpeeds[idx % 4] * Float.random(in: 0.9...1.1)
                            tiltX = satGroupTiltX[idx % 4]
                            tiltZ = satGroupTiltZ[idx % 4]
                        case .dna:
                            strand = idx % 2
                        case .figure8:
                            speed = (idx == 0) ? 1.0 : -1.0
                        default:
                            break
                        }
                        
                        let rndTheta = Float.random(in: 0...(2.0 * Float.pi))
                        let rndZ = Float.random(in: -1.0...1.0)
                        let rndR = sqrt(1.0 - rndZ * rndZ)
                        let spiroAxis = SIMD3<Float>(rndR * cos(rndTheta), rndR * sin(rndTheta), rndZ)
                        
                        var tracer = OrbitTracer(
                            t: max(baseT, 0),
                            speed: speed,
                            brightness: brightness,
                            orbitIndex: idx,
                            tiltX: tiltX,
                            tiltZ: tiltZ,
                            strand: strand,
                            spirographAxis: spiroAxis
                        )
                        nextSegmentForOrbitTracer(&tracer)
                        orbitTracers.append(tracer)
                    }
                    
                } else {
                    // GRID OFF: always 1 tracer with toroidal drift → asymmetric expanding shapes
                    let clampedDesired = 1
                    
                    while orbitTracers.count < clampedDesired {
                        let idx = orbitTracers.count
                        // Start at t=0 (orbit origin) for clean layer starts
                        let baseT: Float = 0.0
                        let brightness = Float.random(in: 0.5...1.0)
                        
                        // Random speed with random direction
                        var speed: Float = Float.random(in: 0.8...1.2) * (Bool.random() ? 1.0 : -1.0)
                        var tiltX: Float = 0
                        var tiltZ: Float = 0
                        var strand: Int = 0
                        
                        switch pattern {
                        case .satellite:
                            let group = idx % 4
                            let groupSpeeds: [Float] = [1.0, 1.0, -1.0, -1.0]
                            speed = groupSpeeds[group] * Float.random(in: 0.8...1.2)
                            tiltX = satGroupTiltX[group] + Float.random(in: -0.3...0.3)
                            tiltZ = satGroupTiltZ[group] + Float.random(in: -0.2...0.2)
                        case .dna:
                            strand = idx % 2
                        case .figure8:
                            speed = (Bool.random() ? 1.0 : -1.0) * Float.random(in: 0.9...1.1)
                        default:
                            break
                        }
                        
                        // Each tracer gets a fully random spirograph axis
                        let rndTheta = Float.random(in: 0...(2.0 * Float.pi))
                        let rndZ = Float.random(in: -1.0...1.0)
                        let rndR = sqrt(1.0 - rndZ * rndZ)
                        let spiroAxis = SIMD3<Float>(rndR * cos(rndTheta), rndR * sin(rndTheta), rndZ)
                        
                        // Random initial spirograph angle
                        let initialSpiroAngle: Float
                        if idx < tracerCountForPattern(lineSubOrbit) {
                            initialSpiroAngle = 0
                        } else {
                            initialSpiroAngle = Float.random(in: 0...(Float.pi * 0.5))
                        }
                        
                        // Toroidal drift: center orbits on a circle in a random plane
                        let driftRadius: Float = 0.15 * orbitRangeMultiplier
                        let driftAngleStep: Float = 0.08  // radians per loop (~12.5 loops per full drift circle)
                        // Random drift plane: pick a random normal, then compute orthogonal U/V
                        let dnTheta = Float.random(in: 0...(2.0 * Float.pi))
                        let dnZ = Float.random(in: -1.0...1.0)
                        let dnR = sqrt(1.0 - dnZ * dnZ)
                        let driftNormal = SIMD3<Float>(dnR * cos(dnTheta), dnR * sin(dnTheta), dnZ)
                        // Build orthonormal basis for drift plane
                        let arbitrary = abs(driftNormal.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
                        let driftU = normalize(cross(driftNormal, arbitrary))
                        let driftV = normalize(cross(driftNormal, driftU))
                        let initialDriftAngle = Float.random(in: 0...(2.0 * Float.pi))
                        
                        var tracer = OrbitTracer(
                            t: baseT,
                            speed: speed,
                            brightness: brightness,
                            orbitIndex: idx,
                            tiltX: tiltX,
                            tiltZ: tiltZ,
                            strand: strand,
                            spirographAxis: spiroAxis
                        )
                        tracer.spirographAngle = initialSpiroAngle
                        tracer.driftAngle = initialDriftAngle
                        tracer.driftAngleStep = driftAngleStep
                        tracer.driftRadius = driftRadius
                        tracer.driftPlaneU = driftU
                        tracer.driftPlaneV = driftV
                        // Set initial offset on the drift circle
                        tracer.centerOffset = driftRadius * (
                            cos(initialDriftAngle) * driftU +
                            sin(initialDriftAngle) * driftV
                        )
                        nextSegmentForOrbitTracer(&tracer)
                        orbitTracers.append(tracer)
                    }
                }
                
                // For each tracer: spawn multiple segments per frame based on BPM speed
                // At high BPM, segments complete instantly, so we batch-generate them
                let segmentsPerFrame = max(1, Int(lineSpeedMultiplier * safeDt * 8))
                for i in 0..<orbitTracers.count {
                    for _ in 0..<segmentsPerFrame {
                        let segIdx = orbitTracers[i].currentSegmentIndex
                        if segIdx >= 0 && segIdx < accumulatedLines.count {
                            if accumulatedLines[segIdx].progress >= 1.0 {
                                nextSegmentForOrbitTracer(&orbitTracers[i])
                                // Instantly complete the new segment too at high speed
                                let newIdx = orbitTracers[i].currentSegmentIndex
                                if newIdx >= 0 && newIdx < accumulatedLines.count {
                                    let spd = accumulatedLines[newIdx].drawSpeed * lineSpeedMultiplier * safeDt
                                    if spd >= 1.0 {
                                        accumulatedLines[newIdx].progress = 1.0
                                    }
                                }
                            } else {
                                break  // current segment still drawing, wait
                            }
                        }
                    }
                }
            }
            
            // Advance drawing progress — only check segments that might still be in-progress
            // Start from the end (newest) since older segments are almost certainly complete
            var allComplete = true
            for i in stride(from: accumulatedLines.count - 1, through: 0, by: -1) {
                if accumulatedLines[i].progress < 1.0 {
                    accumulatedLines[i].progress = min(accumulatedLines[i].progress + accumulatedLines[i].drawSpeed * lineSpeedMultiplier * safeDt, 1.0)
                    allComplete = false
                } else if allComplete {
                    continue  // already 1.0, skip
                }
            }
            
            // Gradually fade oldest segments (1:1 with new additions) and purge dead ones
            let newSegCount = accumulatedLines.count - segCountBeforeFrame
            fadeOldSegmentsGradually(newCount: max(newSegCount, 0), dt: safeDt)
            purgeDeadSegments()
            
            // Audio reactive: beat pulse spawns an extra walker temporarily
            let safePredictedBeat = sanitize(predictedBeatPulse).clamped(to: 0...1)
            if safePredictedBeat > 0.5 && beatPulse < 0.3 {
                beatPulse = min(beatPulse + 0.4, 1.0)
            }
            let decayRate: Float = 3.0
            beatPulse = max(beatPulse - decayRate * safeDt, 0)
            
            // Keep a dummy ball so the simulation array isn't empty
            balls = [Ball(position: SIMD3(0.5, 0.5, 0.5), radius: 0.001)]
            
            return
        }
        
        // BOX mode: slowly morphing noise sculpture
        if orbitPattern == .box {
            boxElapsedTime += safeDt
            
            // Advance crossfade if transitioning
            if boxCrossfadeDir > 0 {
                boxCrossfade += safeDt * 0.8  // ~1.25 sec transition
                if boxCrossfade >= 1.0 {
                    boxCrossfade = 1.0
                    boxCrossfadeDir = 0
                }
            }
            
            regenerateBoxSculpture(timeOffset: boxElapsedTime * 0.02 * boxSpeedMultiplier, dt: safeDt)
            
            balls = [Ball(position: SIMD3(0.5, 0.5, 0.5), radius: 0.001)]
            return
        }
        
        // RAIN mode: 2D bouncing ball physics
        if orbitPattern == .polygon {
            // Clear collision flags (consumed by renderer each frame)
            rainWallHit = false
            rainBlockHit = false
            
            // Reset on category change
            if rainCategory != rainPrevCategory {
                rainPrevCategory = rainCategory
                rainBalls = []
                rainParticles = []
                rainDandelions = []
                rainFallLastBeatTime = CACurrentMediaTime()
                rainFallNextPipeIndex = 0
                if rainCategory == 1 {
                    // Re-init PinBall balls
                    for i in 0..<max(1, rainBallCount) {
                        let angle = Float.random(in: 0...(2.0 * Float.pi))
                        let offset = Float(i) * 0.1
                        rainBalls.append(RainBall(
                            pos: SIMD2(0.5 + offset - Float(max(1, rainBallCount) - 1) * 0.05, 0.5),
                            vel: SIMD2(cos(angle), sin(angle)),
                            radius: 0.012
                        ))
                    }
                } else {
                    updateFallPipePositions()
                }
            }
            
            // Skip physics when paused (still allow block creation via swipe)
            if rainPaused {
                // Update particles even when paused (let them fade out)
                for i in (0..<rainParticles.count).reversed() {
                    rainParticles[i].life -= safeDt * 2.0
                    if rainParticles[i].life <= 0 {
                        rainParticles.remove(at: i)
                    }
                }
                // Keep dandelion animations running when paused (seeds float)
                updateDandelions(dt: safeDt)
                balls = [Ball(position: SIMD3(0.5, 0.5, 0.5), radius: 0.001)]
                return
            }
            
            if rainCategory == 0 {
                // ===== FALL MODE =====
                updateFallMode(dt: safeDt)
            } else {
                // ===== PINBALL MODE (existing) =====
                
                // Ensure ball count matches setting
                while rainBalls.count < max(1, rainBallCount) {
                    let angle = Float.random(in: 0...(2.0 * Float.pi))
                    rainBalls.append(RainBall(pos: SIMD2(0.5, 0.5), vel: SIMD2(cos(angle), sin(angle)), radius: 0.012))
                }
                while rainBalls.count > max(1, rainBallCount) {
                    rainBalls.removeLast()
                }
                
                // BPM-driven speed (BPM20=最低速、BPM200=旧BPM100相当)
                let bpmClamped = max(min(detectedBPM, 200), 20)
                let bpmT = (bpmClamped - 20) / (200 - 20)
                let speed: Float = 0.075 + bpmT * 0.53
                
                // Arena bounds (from safe area insets)
                let minX = rainArenaLeft
                let maxX = 1.0 - rainArenaRight
                let minY = rainArenaTop
                let maxY = 1.0 - rainArenaBottom
                
                // Physics for each ball
                for bi in 0..<rainBalls.count {
                    let r = rainBalls[bi].radius
                    rainBalls[bi].insideBlock = false
                    
                    // Normalize velocity direction and move
                    let velLen = simd_length(rainBalls[bi].vel)
                    if velLen > 0.0001 {
                        let dir = rainBalls[bi].vel / velLen
                        rainBalls[bi].pos += dir * speed * safeDt
                    }
                    
                    // Wall collisions
                    if rainBalls[bi].pos.x - r < minX {
                        rainBalls[bi].pos.x = minX + r
                        rainBalls[bi].vel.x = abs(rainBalls[bi].vel.x)
                        spawnRainParticles(at: SIMD2<Float>(minX, rainBalls[bi].pos.y), normal: SIMD2<Float>(1, 0))
                        handleDandelionHit(at: SIMD2<Float>(minX, rainBalls[bi].pos.y), normal: SIMD2<Float>(1, 0))
                        rainWallHit = true
                        rainWallHitScale = 1.0
                    }
                    if rainBalls[bi].pos.x + r > maxX {
                        rainBalls[bi].pos.x = maxX - r
                        rainBalls[bi].vel.x = -abs(rainBalls[bi].vel.x)
                        spawnRainParticles(at: SIMD2<Float>(maxX, rainBalls[bi].pos.y), normal: SIMD2<Float>(-1, 0))
                        handleDandelionHit(at: SIMD2<Float>(maxX, rainBalls[bi].pos.y), normal: SIMD2<Float>(-1, 0))
                        rainWallHit = true
                        rainWallHitScale = 1.0
                    }
                    if rainBalls[bi].pos.y - r < minY {
                        rainBalls[bi].pos.y = minY + r
                        rainBalls[bi].vel.y = abs(rainBalls[bi].vel.y)
                        spawnRainParticles(at: SIMD2<Float>(rainBalls[bi].pos.x, minY), normal: SIMD2<Float>(0, 1))
                        handleDandelionHit(at: SIMD2<Float>(rainBalls[bi].pos.x, minY), normal: SIMD2<Float>(0, 1))
                        rainWallHit = true
                        rainWallHitScale = 1.0
                    }
                    if rainBalls[bi].pos.y + r > maxY {
                        rainBalls[bi].pos.y = maxY - r
                        rainBalls[bi].vel.y = -abs(rainBalls[bi].vel.y)
                        spawnRainParticles(at: SIMD2<Float>(rainBalls[bi].pos.x, maxY), normal: SIMD2<Float>(0, -1))
                        handleDandelionHit(at: SIMD2<Float>(rainBalls[bi].pos.x, maxY), normal: SIMD2<Float>(0, -1))
                        rainWallHit = true
                        rainWallHitScale = 1.0
                    }
                    
                    // Block collisions (AABB vs circle)
                    for i in 0..<rainBlocks.count {
                        let block = rainBlocks[i]
                        let bx = block.rect.x
                        let by = block.rect.y
                        let bw = block.rect.z
                        let bh = block.rect.w
                        
                        let closestX = max(bx, min(rainBalls[bi].pos.x, bx + bw))
                        let closestY = max(by, min(rainBalls[bi].pos.y, by + bh))
                        let dx = rainBalls[bi].pos.x - closestX
                        let dy = rainBalls[bi].pos.y - closestY
                        let distSq = dx * dx + dy * dy
                        
                        if distSq < r * r {
                            let dist = sqrt(distSq)
                            if dist > 0.0001 {
                                let nx = dx / dist
                                let ny = dy / dist
                                let dot = rainBalls[bi].vel.x * nx + rainBalls[bi].vel.y * ny
                                rainBalls[bi].vel.x -= 2.0 * dot * nx
                                rainBalls[bi].vel.y -= 2.0 * dot * ny
                                rainBalls[bi].pos.x = closestX + nx * (r + 0.002)
                                rainBalls[bi].pos.y = closestY + ny * (r + 0.002)
                                spawnRainParticles(at: SIMD2<Float>(closestX, closestY), normal: SIMD2<Float>(nx, ny))
                                handleDandelionHit(at: SIMD2<Float>(closestX, closestY), normal: SIMD2<Float>(nx, ny))
                                rainBlocks[i].hitScale = 1.0
                                rainBlockHit = true
                                rainBlockHitMidiNote = block.midiNote
                            } else {
                                // Ball center is inside block — use block top surface
                                rainBalls[bi].insideBlock = true
                                rainBalls[bi].vel.y = -rainBalls[bi].vel.y
                                rainBalls[bi].pos.y += (rainBalls[bi].vel.y > 0 ? 1 : -1) * (r + 0.002)
                                let hitY = by  // block top surface
                                handleDandelionHit(at: SIMD2<Float>(rainBalls[bi].pos.x, hitY), normal: SIMD2<Float>(0, -1))
                                rainBlocks[i].hitScale = 1.0
                                rainBlockHit = true
                                rainBlockHitMidiNote = block.midiNote
                            }
                        }
                    }
                }
            } // end PinBall/Fall branch
            
            // Update dandelion lifecycle
            updateDandelions(dt: safeDt)
            
            // Update particles — quick spark, fast fade
            for i in (0..<rainParticles.count).reversed() {
                rainParticles[i].life -= safeDt * 3.5
                rainParticles[i].position += rainParticles[i].velocity * safeDt
                rainParticles[i].velocity *= (1.0 - safeDt * 5.0)
                if rainParticles[i].life <= 0 {
                    rainParticles.remove(at: i)
                }
            }
            
            // Decay block hit scale (fast pop → return to normal)
            for i in 0..<rainBlocks.count {
                if rainBlocks[i].hitScale > 0 {
                    rainBlocks[i].hitScale -= safeDt * 6.0  // ~0.17s full decay
                    if rainBlocks[i].hitScale < 0 { rainBlocks[i].hitScale = 0 }
                }
            }
            
            // Decay wall hit scale
            if rainWallHitScale > 0 {
                rainWallHitScale -= safeDt * 6.0
                if rainWallHitScale < 0 { rainWallHitScale = 0 }
            }
            
            balls = [Ball(position: SIMD3(0.5, 0.5, 0.5), radius: 0.001)]
            return
        }
        
        // --- Sanitize incoming audio values ---
        let safeBass = sanitize(bassEnergy).clamped(to: 0...10)
        let safeMid = sanitize(midEnergy).clamped(to: 0...10)
        let safeHigh = sanitize(highEnergy).clamped(to: 0...10)
        let safePredictedBeat = sanitize(predictedBeatPulse).clamped(to: 0...1)
        
        // --- Smooth energy tracking (gradual attack, moderate decay) ---
        prevSmoothBass = smoothBass
        let bassAlpha: Float = safeBass > smoothBass ? 0.15 : 0.12  // gentle rise, gentle fall
        smoothBass = (smoothBass * (1.0 - bassAlpha) + safeBass * bassAlpha).clamped(to: 0...8)
        let midAlpha: Float = safeMid > smoothMid ? 0.12 : 0.10
        smoothMid = (smoothMid * (1.0 - midAlpha) + safeMid * midAlpha).clamped(to: 0...8)
        let highAlpha: Float = safeHigh > smoothHigh ? 0.15 : 0.15  // high band: balanced rise/fall, avoids lingering noise
        smoothHigh = (smoothHigh * (1.0 - highAlpha) + safeHigh * highAlpha).clamped(to: 0...8)
        
        // Overall energy level — rises faster with sound, decays moderately
        let totalEnergy = (smoothBass + smoothMid * 0.7 + smoothHigh * 0.3)
        let energyAlpha: Float = totalEnergy > energyLevel ? 0.02 : 0.003
        energyLevel = (energyLevel * (1.0 - energyAlpha) + totalEnergy * energyAlpha).clamped(to: 0...4)
        let energy = min(energyLevel * 2.0, 1.0)  // normalized 0..1
        
        // --- Beat pulse from BPM ---
        let bassRise = smoothBass - prevSmoothBass
        var reactivePulse: Float = 0
        if bassRise > 0.03 {
            reactivePulse = min(bassRise * 5.0, 0.8)
        }
        
        let newBeat: Bool
        if safePredictedBeat > 0.5 && beatPulse < 0.3 {
            beatPulse = min(beatPulse + 0.4, 1.0)  // ramp up, not instant jump
            newBeat = true
        } else if reactivePulse > 0.3 && beatPulse < 0.3 && safePredictedBeat <= 0.5 {
            beatPulse = min(beatPulse + reactivePulse * 0.5, 1.0)  // gradual reactive pulse
            newBeat = true
        } else {
            newBeat = false
        }
        
        // Beat envelope: quick squeeze → expand → settle
        if newBeat {
            beatPhaseAnim = 0
        }
        
        var targetBeat: Float = 0
        if beatPhaseAnim < 1.0 {
            beatPhaseAnim += safeDt * 2.5  // ~0.4s cycle (slower, more gradual)
            if beatPhaseAnim > 1.0 { beatPhaseAnim = 1.0 }
            let p = beatPhaseAnim
            if p < 0.15 {
                let t = p / 0.15
                targetBeat = -t * 0.25  // gentle contract (was -0.5)
            } else if p < 0.4 {
                let t = (p - 0.15) / 0.25
                let s = t * t * (3.0 - 2.0 * t)
                targetBeat = -0.25 + s * 0.65  // expand to +0.4 (was +0.7)
            } else {
                let t = (p - 0.4) / 0.6
                let s = t * t * (3.0 - 2.0 * t)
                targetBeat = 0.4 * (1.0 - s)  // settle to 0
            }
        }
        smoothBeat += (targetBeat - smoothBeat) * min(safeDt * 12.0, 0.3)
        smoothBeat = sanitize(smoothBeat).clamped(to: -1...1)
        
        beatPulse *= (1.0 - safeDt * 8.0)
        if beatPulse < 0.001 { beatPulse = 0 }
        beatPulse = beatPulse.clamped(to: 0...1)
        
        // ===== ORGANIC WAVES =====
        
        // BPM tempo factor: all speeds scale proportionally to BPM
        // 120 BPM = 1.0x (reference), 60 BPM = 0.5x, 20 BPM = 0.167x (deep-sea), 200 BPM = 1.67x
        let bpmFactor: Float = detectedBPM > 10 ? (detectedBPM / 120.0) : 0.08
        
        // --- Long-press zoom progress: animate toward 1.0 when held, back to 0.0 when released ---
        // Fixed speed, independent of BPM — ~4s to reach full zoom
        let longPressSpeed: Float = 0.25
        if longPressActive {
            longPressProgress = min(longPressProgress + safeDt * longPressSpeed, 1.0)
        } else {
            longPressProgress = max(longPressProgress - safeDt * longPressSpeed, 0.0)
        }
        
        // Breathing rate scales with BPM
        let breatheRate: Float = detectedBPM > 10 ? bpmFactor : 0.08
        
        // Wave 1: Breathing — slow, always-on, life-like
        let breatheA = sin(time * 0.6 * breatheRate) * 0.06
        let breatheB = sin(time * 0.23 * breatheRate + 1.5) * 0.04
        let breathe: Float = 1.0 + breatheA + breatheB  // ~0.90..1.10
        
        // Wave 2: Tidal — medium speed, position undulation
        let tidalPhase = time * 0.4 * breatheRate
        
        // Reactivity factor: sensitivity slider amplifies all audio-driven responses
        let react = reactivity  // 0.5..3.0, default 1.5
        
        // --- Frenzy mode: triggered when input level hits red (>0.8) ---
        // Matches LevelMeterView red threshold (level > 0.8)
        let frenzyTarget: Float = inputLevel > 0.8 ? min((inputLevel - 0.8) * 5.0 + 0.5, 1.0) : 0
        let frenzyAlpha: Float = frenzyTarget > smoothFrenzy ? 0.5 : 0.06
        smoothFrenzy = (smoothFrenzy * (1.0 - frenzyAlpha) + frenzyTarget * frenzyAlpha).clamped(to: 0...1)
        let frenzy = smoothFrenzy  // 0..1, ramps up when clipping
        
        // Frenzy multiplier: at full frenzy, everything reacts 3x harder
        let frenzyMul: Float = 1.0 + frenzy * 2.0
        
        // Frenzy size boost: balls swell up when clipping (up to +60%)
        let frenzySizeBoost: Float = 1.0 + frenzy * 0.6
        
        // Frenzy flick spin: inject angular velocity impulse when frenzy starts
        // Cooldown prevents continuous peaks from firing flicks every frame
        frenzyFlickCooldown = max(frenzyFlickCooldown - safeDt, 0)
        if frenzyTarget > 0.3 && !frenzyFlickActive && frenzyFlickCooldown <= 0 {
            frenzyFlickActive = true
            frenzyFlickCooldown = 3.0  // ignore peaks for 3 seconds after a flick
            if camMode {
                // CAM mode: alternate left/right on each peak
                frenzyFlickDirection *= -1.0
            } else {
                // Normal: random direction
                frenzyFlickDirection = Bool.random() ? 1.0 : -1.0
            }
            frenzyFlickVelocity = frenzyFlickDirection * (3.0 + frenzy * 5.0)
        }
        if frenzyTarget < 0.1 {
            frenzyFlickActive = false
        }
        // Flick velocity decays with friction (like a real flick)
        turntableAngle += frenzyFlickVelocity * safeDt
        frenzyFlickVelocity *= (1.0 - safeDt * 2.5)  // friction decay
        if abs(frenzyFlickVelocity) < 0.01 { frenzyFlickVelocity = 0 }
        
        // Wave 3: Energy swell — size grows/shrinks with sustained loudness (gradual)
        let energySwell: Float = 1.0 + energy * 0.22 * react * frenzyMul
        
        // Beat contribution to size (±) — gentle swell
        let beatScale: Float = 1.0 + smoothBeat * 0.12 * react * frenzyMul
        
        // Energy drives orbit spread: louder → more separation (moderate)
        let energySpread: Float = 1.0 + energy * 0.7 * react * frenzyMul + max(smoothBeat, 0) * 0.25 * react
        
        // Energy drives speed (scaled by BPM tempo and reactivity)
        let speedBoost: Float = (1.0 + energy * 1.0 * react * frenzyMul + smoothMid * 1.0 * react) * bpmFactor
        
        // --- Turntable rotation for geometric patterns ---
        // Satellite uses individual orbit animation, not turntable
        let isGeometric = (orbitPattern != .random && orbitPattern != .satellite)
        let turntableSpeed: Float
        if isGeometric {
            if detectedBPM > 10 {
                // Sync to BPM: one full rotation per 8 beats (slower base), scaled by bpmFactor
                // At 60 BPM: very slow rotation. At 120: moderate. At 200: lively.
                turntableSpeed = bpmFactor * 0.5 * 2.0 * .pi * 0.25 * frenzyMul  // ~0.785 at 120 BPM, 3x when clipping
            } else {
                // No BPM: deep-sea drift — extremely slow, meditative rotation
                turntableSpeed = 0.06 * animSpeed * (1.0 + energy * 0.3) * frenzyMul
            }
            turntableAngle += turntableSpeed * safeDt
            // Wrap to prevent unbounded growth
            if turntableAngle > 100 * .pi {
                turntableAngle = turntableAngle.truncatingRemainder(dividingBy: 2 * .pi)
            }
        }
        
        // Per-band jitter: high-freq balls get lots of fast jitter, others get less
        // Reactivity amplifies jitter so higher sensitivity = more twitchy
        // Frenzy adds massive chaotic jitter on top
        let frenzyJitter: Float = frenzy * 0.15  // huge displacement when clipping
        jitterSeed &+= 1
        for i in 0..<balls.count {
            let band = i < freqBands.count ? freqBands[i] : .mid
            let jitterAmount: Float
            switch band {
            case .bass:
                jitterAmount = smoothBass * 0.008 * react + frenzyJitter * 0.5
            case .mid:
                jitterAmount = smoothMid * 0.015 * react + frenzyJitter * 0.8
            case .high:
                jitterAmount = smoothHigh * 0.06 * react + frenzyJitter
            }
            let h1 = fastHash(jitterSeed &* UInt32(i + 1))
            let h2 = fastHash(h1)
            let h3 = fastHash(h2)
            jitterX[i] = hashToFloat(h1) * jitterAmount
            jitterY[i] = hashToFloat(h2) * jitterAmount
            jitterZ[i] = hashToFloat(h3) * jitterAmount
        }
        
        // Zoetrope wave parameters (scaled by BPM)
        let waveCycles: Float = 2.0
        let wavePhase = isGeometric ? time * 3.0 * bpmFactor : 0
        
        // Turntable rotation: Y-axis rotation matrix components
        let cosT = cos(turntableAngle)
        let sinT = sin(turntableAngle)
        
        for i in 0..<balls.count {
            let t_norm = Float(i) / Float(max(balls.count - 1, 1))  // 0..1
            let phase = phaseOffsets[i]
            
            var target: SIMD3<Float>
            
            if isGeometric && gridMode {
                // --- Grid mode: single line of balls flowing along the path ---
                
                // Only the leader (ball 0) advances the shared phase
                if i == 0 {
                    let pathSpeed: Float
                    if detectedBPM > 10 {
                        pathSpeed = bpmFactor * 0.125
                    } else {
                        pathSpeed = 0.03 * animSpeed * (1.0 + energy * 0.3)
                    }
                    pathPhases[0] += pathSpeed * safeDt
                    if pathPhases[0] > 1.0 { pathPhases[0] -= 1.0 }
                }
                
                // Comet spacing: head (high i) is dense, tail (low i) gently spreads out
                let n = Float(max(balls.count - 1, 1))
                let distFromHead = Float(balls.count - 1 - i) / n  // 0=head, 1=tail
                // Gentle power curve (1.5) — less aggressive than quadratic
                let cometOffset = pow(distFromHead, 1.5) * spacingMultiplier * 0.25
                let effectivePhase = (pathPhases[0] - cometOffset).truncatingRemainder(dividingBy: 1.0)
                let wrappedPhase = effectivePhase < 0 ? effectivePhase + 1.0 : effectivePhase
                
                // Evaluate position on path — single unified comet line
                target = pathPosition(for: orbitPattern, t: wrappedPhase)
                
            } else if isGeometric {
                // --- Zoetrope 3D: rotate rest positions around Y axis ---
                let rest = restPositions[i]
                // Translate to origin-centered
                let rx = rest.x - 0.5
                let ry = rest.y - 0.5
                let rz = rest.z - 0.5
                
                // Rotate around Y axis (turntable)
                let rotX = rx * cosT + rz * sinT
                let rotZ = -rx * sinT + rz * cosT
                
                // Beat push: expand outward from center
                let beatExpand = max(smoothBeat, 0)
                let pushScale = 1.0 + beatExpand * 0.12
                
                target = SIMD3<Float>(
                    0.5 + rotX * pushScale * energySpread,
                    0.5 + ry * pushScale * energySpread,
                    0.5 + rotZ * pushScale * energySpread
                )
                
                // Zoetrope wave: vertical bobbing propagating through the chain
                let waveT = t_norm * waveCycles * 2.0 * .pi + wavePhase
                let bob = sin(waveT) * 0.04 * (1.0 + energy * 1.5)
                target.y += bob
                
            } else if orbitPattern == .satellite {
                // --- Satellite: 4 orbit groups as lines on tilted great circles ---
                let orbitR = satOrbitRadius
                let group = i < satGroupIndex.count ? satGroupIndex[i] : 0
                
                // Advance group phase (all balls in same group share the same base phase)
                if i == 0 {
                    // Advance all 4 group phases once per frame
                    let orbitSpeedMul: Float = detectedBPM > 10 ? speedBoost : (0.15 + energy * 0.2)
                    // Same speed magnitude, paired groups (0&2, 1&3) rotate in opposite directions
                    let spd: Float = 0.7
                    let groupSpeeds: [Float] = [spd, spd, -spd, -spd]
                    for g in 0..<Self.satGroupCount {
                        satGroupPhase[g] += groupSpeeds[g] * safeDt * animSpeed * orbitSpeedMul
                        if abs(satGroupPhase[g]) > 100 * .pi {
                            satGroupPhase[g] = satGroupPhase[g].truncatingRemainder(dividingBy: 2 * .pi)
                        }
                    }
                }
                
                // Ball's position within its group line
                // Count how many balls before index i belong to the same group
                let ballCount = balls.count
                var indexInGroup = 0
                for j in 0..<i {
                    if j < satGroupIndex.count && satGroupIndex[j] == group {
                        indexInGroup += 1
                    }
                }
                var groupSize = 0
                for j in 0..<ballCount {
                    if j < satGroupIndex.count && satGroupIndex[j] == group {
                        groupSize += 1
                    }
                }
                
                // Comet spacing: spacing=2.0 → tail nearly catches head (full orbit)
                let gn = Float(max(groupSize - 1, 1))
                let distFromHead = Float(groupSize - 1 - indexInGroup) / gn  // 0=head, 1=tail
                let cometAngle = pow(distFromHead, 1.5) * spacingMultiplier * (.pi / 3.0)
                
                // Reverse groups rotate in negative direction, so tail offset flips
                let isReverse = (group == 2 || group == 3)
                let angle = satGroupPhase[group] + (isReverse ? cometAngle : -cometAngle)
                
                // Start on equatorial circle, then apply group tilt
                var px = orbitR * cos(angle)
                var py: Float = 0
                var pz = orbitR * sin(angle)
                
                if i < satTiltX.count {
                    let tx = satTiltX[i]
                    let tz = satTiltZ[i]
                    let cy1 = py * cos(tx) - pz * sin(tx)
                    let cz1 = py * sin(tx) + pz * cos(tx)
                    py = cy1; pz = cz1
                    let cx2 = px * cos(tz) - py * sin(tz)
                    let cy2 = px * sin(tz) + py * cos(tz)
                    px = cx2; py = cy2
                }
                
                // Constant distance from center — no audio position push
                target = SIMD3<Float>(
                    0.5 + px,
                    0.5 + py,
                    0.5 + pz
                )
                
            } else {
                // --- Random pattern: 2D orbit on z=0.5 plane ---
                // Scale orbit speed: BPM-proportional boost, or gentle drift
                let orbitSpeedMul: Float = detectedBPM > 10 ? speedBoost : (0.12 + energy * 0.15)
                orbitAngles[i] += orbitSpeeds[i] * safeDt * animSpeed * orbitSpeedMul + frenzyFlickVelocity * safeDt * 0.3
                if orbitAngles[i] > 100 * .pi {
                    orbitAngles[i] = orbitAngles[i].truncatingRemainder(dividingBy: 2 * .pi)
                }
                
                let tidalOffset = sin(tidalPhase + t_norm * 4.0) * 0.03 * (1.0 + energy * 2.0)
                let tidalOffsetY = cos(tidalPhase * 0.7 + t_norm * 3.0 + 1.0) * 0.02 * (1.0 + energy * 2.0)
                
                let beatExpand = max(smoothBeat, 0)
                let toCenterX = orbitCenters[i].x - 0.5
                let toCenterY = orbitCenters[i].y - 0.5
                let pushX = toCenterX * beatExpand * 0.08
                let pushY = toCenterY * beatExpand * 0.08
                
                let effCenterX = orbitCenters[i].x + tidalOffset + pushX
                let effCenterY = orbitCenters[i].y + tidalOffsetY + pushY
                
                let dynOrbitR = orbitRadii[i] * energySpread
                let wobble: Float = 0.3
                let lissajousX = cos(orbitAngles[i]) + wobble * sin(orbitAngles[i] * 2.0 + phase)
                let lissajousY = sin(orbitAngles[i]) + wobble * cos(orbitAngles[i] * 1.5 + phase)
                
                target = SIMD3<Float>(
                    effCenterX + dynOrbitR * lissajousX,
                    effCenterY + dynOrbitR * lissajousY,
                    restPositions[i].z
                )
            }
            
            // Apply per-ball jitter (band-dependent amount was pre-computed above)
            // Skip jitter for geometric grid mode (preserves perfect circle/sphere shapes)
            // and satellite pattern (keeps constant orbit radius)
            let skipJitter = (isGeometric && gridMode) || (orbitPattern == .satellite)
            if !skipJitter {
                target.x += jitterX[i]
                target.y += jitterY[i]
                target.z += jitterZ[i]
            }
            
            // Long-press orbit shrink: pull all balls toward center
            // Smoothstep ease-in-out: gentle start, gentle finish
            if longPressProgress > 0 {
                let eased = longPressProgress * longPressProgress * (3.0 - 2.0 * longPressProgress)
                let shrink = 1.0 - eased * 0.6  // shrink orbit to 40% at full press
                target.x = 0.5 + (target.x - 0.5) * shrink
                target.y = 0.5 + (target.y - 0.5) * shrink
                target.z = 0.5 + (target.z - 0.5) * shrink
            }
            
            let band = i < freqBands.count ? freqBands[i] : .mid
            
            let directPlacement = (orbitPattern == .satellite) || (isGeometric && gridMode)
            
            if directPlacement {
                // --- Direct placement: no spring physics (SAT + GRID modes) ---
                // Touch forces: temporary displacement only
                var touchOffset = SIMD3<Float>.zero
                for t in 0..<touchPoints.count {
                    guard touchPoints[t].active > 0.5 else { continue }
                    let tp = SIMD3<Float>(touchPoints[t].position.x, touchPoints[t].position.y, balls[i].pos.z)
                    let diff = tp - target
                    let dist = length(diff)
                    if dist > 0.01 {
                        let strength = touchPoints[t].strength / (dist * dist + 0.01)
                        touchOffset += normalize(diff) * strength * 0.008
                    }
                }
                // Place directly on path — no spring lag, perfect line formation
                balls[i].pos = target + touchOffset
                velocities[i] = .zero
            } else {
                // --- Touch forces (applied in XY plane, mapped to 3D) ---
                var touchForce = SIMD3<Float>.zero
                for t in 0..<touchPoints.count {
                    guard touchPoints[t].active > 0.5 else { continue }
                    let tp = SIMD3<Float>(touchPoints[t].position.x, touchPoints[t].position.y, balls[i].pos.z)
                    let diff = tp - balls[i].pos
                    let dist = length(diff)
                    if dist > 0.01 {
                        let strength = touchPoints[t].strength / (dist * dist + 0.01)
                        touchForce += normalize(diff) * strength * 0.008
                    }
                }
                
                // --- Physics: spring + damping (3D) - band-dependent mass ---
                // Lower BPM → softer springs, more damping → dreamy, slow motion
                // Higher reactivity → stiffer springs → snappier audio response
                let tempoStiffness = max(bpmFactor, 0.3) * max(react * 0.7, 0.5)
                let springK: Float
                let damping: Float
                switch band {
                case .bass:
                    // Heavy mass: slow, weighty response
                    springK = (isGeometric ? (3.0 + energy * 2.0 * react) : (1.5 + energy * 1.5 * react)) * tempoStiffness
                    damping = isGeometric ? (5.0 + energy * 1.0) : (3.5 + energy * 0.8)
                case .mid:
                    // Moderate mass
                    springK = (isGeometric ? (4.0 + energy * 3.0 * react) : (2.5 + energy * 2.0 * react)) * tempoStiffness
                    damping = isGeometric ? (4.0 + energy * 1.5) : (2.5 + energy * 1.0)
                case .high:
                    // Light mass: snappy, twitchy
                    springK = (isGeometric ? (6.0 + energy * 5.0 * react) : (4.0 + energy * 4.0 * react)) * tempoStiffness
                    damping = isGeometric ? (3.0 + energy * 2.0) : (1.8 + energy * 1.5)
                }
                
                // --- Inter-ball repulsion (prevent overlap) ---
                var interBallForce = SIMD3<Float>.zero
                for j in 0..<balls.count where j != i {
                    let diff = balls[j].pos - balls[i].pos
                    let dist = length(diff)
                    guard dist > 0.001 else { continue }
                    let dir = diff / dist
                    
                    let combinedR = balls[i].radius + balls[j].radius
                    if dist < combinedR {
                        let overlap = combinedR - dist
                        interBallForce -= dir * overlap * 6.0
                    }
                }
                
                let displacement = target - balls[i].pos
                let springForce = displacement * springK
                let dampForce = -velocities[i] * damping
                
                velocities[i] += (springForce + dampForce + touchForce + interBallForce) * safeDt
                let maxSpeed: Float = (band == .high) ? 8.0 : 5.0
                let speed = length(velocities[i])
                if speed > maxSpeed {
                    velocities[i] = velocities[i] / speed * maxSpeed
                }
                balls[i].pos += velocities[i] * safeDt
            }
            
            // --- Radius: band-specific pulsing + traveling wave ---
            
            // Band-specific audio reactivity multiplier (scaled by BPM tempo)
            let pulseIntensity = bpmFactor  // calmer pulsing at low BPM
            let bandPulse: Float
            switch band {
            case .bass:
                let bassThrob = 1.0 + smoothBass * 0.35 * pulseIntensity
                let beatDelay = t_norm * 0.08
                let staggeredBeat = beatPhaseAnim < beatDelay ? Float(1.0) : beatScale
                bandPulse = bassThrob * staggeredBeat * breathe * energySwell
            case .mid:
                let midThrob = 1.0 + smoothMid * 0.25 * pulseIntensity
                let sizeWave = sin(time * pulseSpeeds[i] * bpmFactor + phase) * 0.08 + 1.0
                bandPulse = midThrob * sizeWave * breathe * energySwell
            case .high:
                let highFlutter = 1.0 + smoothHigh * 0.35 * pulseIntensity
                let flutter = sin(time * 8.0 * bpmFactor + phase) * smoothHigh * 0.15 + 1.0
                bandPulse = highFlutter * flutter
            }
            
            // Size modulation for geometric patterns
            let travelWave: Float
            if isGeometric && gridMode {
                // GRID mode: comet gradient — leading ball (high i) big, trailing (low i) tiny
                let headT = Float(i) / Float(max(balls.count - 1, 1))  // 0=tail, 1=head
                // Cubic curve: tail shrinks rapidly, head swells dramatically
                let curve = headT * headT  // quadratic — steeper at tail end
                travelWave = 0.08 + curve * 3.92  // 0.08x..4.0x — 50:1 ratio
            } else if isGeometric {
                // Zoetrope mode: traveling wave ("snake swallowing an egg")
                let waveSpeed: Float = detectedBPM > 10
                    ? bpmFactor * 0.25
                    : 0.04
                
                let wavePos = (time * waveSpeed).truncatingRemainder(dividingBy: 1.0)
                var dist = abs(t_norm - wavePos)
                if dist > 0.5 { dist = 1.0 - dist }
                
                let sigma: Float = 0.12
                let gaussian = exp(-dist * dist / (2.0 * sigma * sigma))
                
                let wavePos2 = ((time * waveSpeed * 1.7) + 0.5).truncatingRemainder(dividingBy: 1.0)
                var dist2 = abs(t_norm - wavePos2)
                if dist2 > 0.5 { dist2 = 1.0 - dist2 }
                let gaussian2 = exp(-dist2 * dist2 / (2.0 * 0.08 * 0.08))
                
                travelWave = 1.0 + gaussian * 1.5 + gaussian2 * 0.6
            } else if orbitPattern == .satellite {
                // SAT: comet gradient is baked into baseRadii (6x range)
                // Keep travelWave neutral — the large baseRadii range dominates bandPulse
                travelWave = 1.0
            } else {
                travelWave = 1.0  // random / fish non-grid
            }
            
            let rawRadius = baseRadii[i] * bandPulse * travelWave * frenzySizeBoost
            let clampedRadius = min(rawRadius, baseRadii[i] * 5.0)  // allow larger range for frenzy + wave peaks
            balls[i].radius = sanitize(clampedRadius, fallback: baseRadii[i])
            
            // Final NaN guard
            balls[i].pos.x = sanitize(balls[i].pos.x, fallback: 0.5)
            balls[i].pos.y = sanitize(balls[i].pos.y, fallback: 0.5)
            balls[i].pos.z = sanitize(balls[i].pos.z, fallback: 0.5)
        }
    }
}
