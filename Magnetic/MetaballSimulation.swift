//
//  MetaballSimulation.swift
//  Magnetic
//
//  CPU-side metaball physics simulation
//

import Foundation
import simd

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
}

// MARK: - Frequency Band Role

/// Each metaball is assigned a frequency band that determines its size and reactivity.
/// Bass = large, slow throb; Mid = medium, moderate pulse; High = small, twitchy/jittery.
enum FreqBand {
    case bass   // 0–120 Hz: kick drums, sub-bass → large balls, heavy mass
    case mid    // 120–2000 Hz: snare, melodic → medium balls, moderate reactivity
    case high   // 2000 Hz+: hi-hats, cymbals → small balls, light mass, rapid jitter
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
    
    func update(dt: Float) {
        // Guard against bad dt
        let safeDt = sanitize(dt, fallback: 1.0 / 30.0)
        guard safeDt > 0 else { return }
        
        time += safeDt * animSpeed
        
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
