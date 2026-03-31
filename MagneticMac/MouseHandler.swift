//
//  MouseHandler.swift
//  MagneticMac
//
//  Handles mouse input and converts to attraction/repulsion forces.
//  Left-click = attract, Right-click = repel.
//

#if os(macOS)
import Foundation
import simd

final class MouseHandler {
    
    private var isActive: Bool = false
    private var normalizedPosition: SIMD2<Float> = .zero
    private var strength: Float = 0  // +0.5 attract, -0.5 repel
    
    /// Mouse button pressed
    func mouseDown(at point: CGPoint, in viewSize: CGSize, isRightClick: Bool) {
        isActive = true
        // macOS coordinate system: origin is bottom-left, flip Y to match iOS convention (top-left)
        normalizedPosition = SIMD2<Float>(
            Float(point.x / viewSize.width),
            Float(1.0 - point.y / viewSize.height)
        )
        strength = isRightClick ? -0.5 : 0.5
    }
    
    /// Mouse moved while button held
    func mouseMoved(to point: CGPoint, in viewSize: CGSize) {
        guard isActive else { return }
        normalizedPosition = SIMD2<Float>(
            Float(point.x / viewSize.width),
            Float(1.0 - point.y / viewSize.height)
        )
    }
    
    /// Mouse button released
    func mouseUp() {
        isActive = false
        strength = 0
    }
    
    /// Returns normalized touch points for the simulation (padded to 10)
    func getTouchPoints() -> [TouchPoint] {
        var points: [TouchPoint] = []
        
        if isActive {
            points.append(TouchPoint(
                position: normalizedPosition,
                strength: strength,
                active: 1.0
            ))
        }
        
        // Pad to 10
        while points.count < 10 {
            points.append(TouchPoint(position: .zero, strength: 0, active: 0))
        }
        
        return Array(points.prefix(10))
    }
}
#endif
