//
//  CameraController.swift
//  Magnetic
//
//  Camera orbit, inertia, and long-press spin logic.
//  Shared between iOS (TouchableMTKView) and macOS (InteractiveMTKView).
//

import simd
import QuartzCore  // CACurrentMediaTime

/// Manages camera orientation (quaternion), distance/zoom, swipe inertia,
/// and long-press figure-skater spin — all platform-agnostic math.
final class CameraController {
    
    // MARK: - Camera state
    
    var cameraOrientation: simd_quatf = simd_quatf(angle: 0.3, axis: SIMD3<Float>(1, 0, 0))
    var cameraDistance: Float = 3.0
    
    /// When true, pan/rotation input is ignored (used for LINES mode lock)
    var isLocked: Bool = false
    
    // MARK: - Smooth snap-to-axis animation
    
    /// Whether a snap animation is in progress
    private(set) var isSnapping: Bool = false
    private var snapStartOrientation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var snapTargetOrientation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var snapProgress: Float = 0
    private let snapDuration: Float = 0.6  // seconds for smooth transition
    
    /// Reset camera to front-facing view and clear all inertia
    func resetToFrontView() {
        cameraOrientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)  // identity quaternion
        angularVelocityX = 0
        angularVelocityY = 0
        initialAngularVelocityX = 0
        initialAngularVelocityY = 0
        longPressSpinSpeed = 0
        isSnapping = false
    }
    
    // MARK: - Sequential axis snap (6 directions)
    
    /// 6 canonical axis views: Front, Right, Back, Left, Top, Bottom
    private static let axisViews: [simd_quatf] = [
        // Front (identity — looking along -Z)
        simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
        // Right (-90° around Y)
        simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(0, 1, 0)),
        // Back (180° around Y)
        simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)),
        // Left (90° around Y)
        simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0)),
        // Top (looking down, -90° around X)
        simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0)),
        // Bottom (looking up, 90° around X)
        simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0)),
    ]
    
    private static let axisNames = ["FRT", "RGT", "BCK", "LFT", "TOP", "BTM"]
    
    /// Current index in the sequential axis cycle (0-5)
    private(set) var sequentialAxisIndex: Int = 0
    
    /// Current axis name for UI display (nil when unlocked)
    var currentAxisName: String? {
        isLocked ? Self.axisNames[sequentialAxisIndex] : nil
    }
    
    /// Snap to the next axis in sequence. Called on each lock long-press.
    func snapToNextAxis() {
        var target = Self.axisViews[sequentialAxisIndex]
        
        // Ensure shortest path slerp
        if simd_dot(cameraOrientation, target) < 0 {
            target = simd_quatf(ix: -target.imag.x, iy: -target.imag.y, iz: -target.imag.z, r: -target.real)
        }
        
        // Clear all velocities
        angularVelocityX = 0
        angularVelocityY = 0
        initialAngularVelocityX = 0
        initialAngularVelocityY = 0
        longPressSpinSpeed = 0
        
        // Start snap animation
        snapStartOrientation = cameraOrientation
        snapTargetOrientation = target
        snapProgress = 0
        isSnapping = true
    }
    
    /// Advance to next axis index (wraps around 0-5)
    func advanceAxisIndex() {
        sequentialAxisIndex = (sequentialAxisIndex + 1) % Self.axisViews.count
    }
    
    /// Force snap to front view (index 0), reset distance, and lock
    func snapToFront() {
        sequentialAxisIndex = 0
        cameraDistance = 3.0
        snapToNextAxis()
        isLocked = true
    }
    
    /// Smoothly snap camera to the nearest axis-aligned view (front/back/left/right/top/bottom)
    func snapToNearestAxisView() {
        // Find closest by quaternion dot product (closest = largest |dot|)
        var bestDot: Float = -1
        var bestIndex = 0
        for (i, q) in Self.axisViews.enumerated() {
            let d = abs(simd_dot(cameraOrientation, q))
            if d > bestDot {
                bestDot = d
                bestIndex = i
            }
        }
        sequentialAxisIndex = bestIndex
        snapToNextAxis()
    }
    
    /// Give a gentle random nudge (like a slow swipe) to signal unlock
    func nudgeRandom() {
        let angle = Float.random(in: 0 ..< 2 * .pi)
        let speed: Float = 0.25  // gentle — like a slow finger swipe
        initialAngularVelocityX = cos(angle) * speed
        initialAngularVelocityY = sin(angle) * speed
        angularVelocityX = initialAngularVelocityX
        angularVelocityY = initialAngularVelocityY
        inertiaStartTime = CACurrentMediaTime()
        isDragging = false
    }
    
    // MARK: - Inertia
    
    private var angularVelocityX: Float = 0
    private var angularVelocityY: Float = 0
    private var initialAngularVelocityX: Float = 0
    private var initialAngularVelocityY: Float = 0
    private var inertiaStartTime: CFTimeInterval = 0
    private let minVelocity: Float = 0.0005
    
    // MARK: - Pan tracking
    
    private var lastPanTime: CFTimeInterval = 0
    var isDragging: Bool = false
    
    // MARK: - Long-press spin
    
    var isLongPressing: Bool = false
    private var longPressBaseCameraDistance: Float = 3.0
    private var longPressSpinAxis: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
    private var longPressWasActive: Bool = false
    private var longPressSpinSpeed: Float = 0
    
    // MARK: - Rotation math
    
    /// Apply incremental rotation around camera's LOCAL axes.
    /// dx/dy are in screen-space radians.
    func applyRotation(dx: Float, dy: Float) {
        let rotMatrix = simd_matrix3x3(cameraOrientation)
        let localRight = SIMD3<Float>(rotMatrix.columns.0.x, rotMatrix.columns.0.y, rotMatrix.columns.0.z)
        let localUp = SIMD3<Float>(rotMatrix.columns.1.x, rotMatrix.columns.1.y, rotMatrix.columns.1.z)
        
        let rotH = simd_quatf(angle: -dx, axis: localUp)
        let rotV = simd_quatf(angle: dy, axis: localRight)
        
        cameraOrientation = simd_normalize(rotH * rotV * cameraOrientation)
    }
    
    // MARK: - Pan handling
    
    func panBegan() {
        isDragging = true
        angularVelocityX = 0
        angularVelocityY = 0
        initialAngularVelocityX = 0
        initialAngularVelocityY = 0
        lastPanTime = CACurrentMediaTime()
    }
    
    /// Process pan translation. Returns true if camera was updated (not long-pressing).
    @discardableResult
    func panChanged(dx: Float, dy: Float, sensitivity: Float = 0.006) -> Bool {
        guard !isLocked else { return false }
        guard !isLongPressing else {
            lastPanTime = CACurrentMediaTime()
            return false
        }
        let now = CACurrentMediaTime()
        let rotDx = dx * sensitivity
        let rotDy = dy * sensitivity  // swipe up → camera orbits downward (natural globe feel)
        
        applyRotation(dx: rotDx, dy: rotDy)
        
        let dt = Float(now - lastPanTime)
        if dt > 0.001 {
            angularVelocityX = rotDx / dt
            angularVelocityY = rotDy / dt
        }
        lastPanTime = now
        return true
    }
    
    func panEnded() {
        initialAngularVelocityX = angularVelocityX
        initialAngularVelocityY = angularVelocityY
        inertiaStartTime = CACurrentMediaTime()
        isDragging = false
    }
    
    // MARK: - Zoom handling
    
    /// Apply incremental zoom. Returns clamped camera distance.
    @discardableResult
    func applyZoom(scale: Float, minDistance: Float = 3.0, maxDistance: Float = 8.0) -> Float {
        cameraDistance /= scale
        cameraDistance = max(minDistance, min(maxDistance, cameraDistance))
        return cameraDistance
    }
    
    // MARK: - Long press
    
    func longPressBegan() {
        isLongPressing = true
        longPressBaseCameraDistance = cameraDistance
    }
    
    func longPressEnded() {
        isLongPressing = false
    }
    
    /// Set camera distance externally (e.g. VIEW mode).
    func setCameraDistance(_ dist: Float) {
        cameraDistance = dist
    }
    
    // MARK: - Per-frame update (inertia + spin)
    
    /// Called every frame via display link. Returns true if camera orientation changed.
    @discardableResult
    func update(dt: Float, longPressProgress: Float, longPressActive: Bool) -> Bool {
        let now = CACurrentMediaTime()
        let clampedDt = min(dt, 0.1)
        var needsSync = false
        
        // --- Swipe inertia (only when not dragging and not locked) ---
        if !isDragging && !isLocked {
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
        
        // --- Long-press spin ---
        if longPressActive && !longPressWasActive {
            let currentInertia = sqrt(angularVelocityX * angularVelocityX + angularVelocityY * angularVelocityY)
            if currentInertia > 0.01 {
                let rotMatrix = simd_matrix3x3(cameraOrientation)
                let localUp = SIMD3<Float>(rotMatrix.columns.1.x, rotMatrix.columns.1.y, rotMatrix.columns.1.z)
                let localRight = SIMD3<Float>(rotMatrix.columns.0.x, rotMatrix.columns.0.y, rotMatrix.columns.0.z)
                let combined = -angularVelocityX * localUp + angularVelocityY * localRight
                let len = length(combined)
                if len > 0.001 {
                    longPressSpinAxis = combined / len
                } else {
                    longPressSpinAxis = Bool.random() ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
                }
                longPressSpinSpeed = max(longPressSpinSpeed, currentInertia)
            } else {
                longPressSpinAxis = Bool.random()
                    ? SIMD3<Float>(0, 1, 0)
                    : SIMD3<Float>(1, 0, 0)
                longPressSpinSpeed = max(longPressSpinSpeed, 0.0)
            }
        }
        longPressWasActive = longPressActive
        
        if longPressActive {
            let accel: Float = 3.0
            longPressSpinSpeed += accel * clampedDt
        } else if longPressSpinSpeed > 0.001 {
            let decay: Float = 0.15
            longPressSpinSpeed *= (1.0 - decay * clampedDt)
            if longPressSpinSpeed < 0.05 {
                longPressSpinSpeed = 0
            }
        }
        
        if abs(longPressSpinSpeed) > 0.001 && !isLocked {
            let spinAngle = longPressSpinSpeed * clampedDt
            let spinQuat = simd_quatf(angle: spinAngle, axis: longPressSpinAxis)
            cameraOrientation = simd_normalize(spinQuat * cameraOrientation)
            needsSync = true
        }
        
        // --- Smooth snap-to-axis animation ---
        if isSnapping {
            snapProgress += clampedDt / snapDuration
            if snapProgress >= 1.0 {
                snapProgress = 1.0
                cameraOrientation = snapTargetOrientation
                isSnapping = false
            } else {
                // Smoothstep ease-in-out
                let t = snapProgress * snapProgress * (3.0 - 2.0 * snapProgress)
                cameraOrientation = simd_slerp(snapStartOrientation, snapTargetOrientation, t)
            }
            needsSync = true
        }
        
        return needsSync
    }
}
