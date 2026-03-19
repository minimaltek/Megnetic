//
//  TouchHandler.swift
//  Magnetic
//
//  Handles multi-touch input and converts to attraction/repulsion forces
//

import UIKit

final class TouchHandler {
    
    struct ActiveTouch {
        var location: CGPoint
        var isLongPress: Bool = false
        var startTime: CFTimeInterval = 0
    }
    
    private var activeTouches: [UITouch: ActiveTouch] = [:]
    private let longPressDuration: CFTimeInterval = 0.5
    
    /// Returns normalized touch points (0..1) for the simulation
    func getTouchPoints(viewSize: CGSize) -> [TouchPoint] {
        var points: [TouchPoint] = []
        
        let now = CACurrentMediaTime()
        
        for (_, touch) in activeTouches {
            let nx = Float(touch.location.x / viewSize.width)
            let ny = Float(touch.location.y / viewSize.height)
            
            let isLongPress = (now - touch.startTime) > longPressDuration
            let strength: Float = isLongPress ? -0.5 : 0.5  // Negative = repel
            
            points.append(TouchPoint(
                position: SIMD2<Float>(nx, ny),
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
    
    func touchesBegan(_ touches: Set<UITouch>, in view: UIView) {
        let now = CACurrentMediaTime()
        for touch in touches {
            activeTouches[touch] = ActiveTouch(
                location: touch.location(in: view),
                startTime: now
            )
        }
    }
    
    func touchesMoved(_ touches: Set<UITouch>, in view: UIView) {
        for touch in touches {
            activeTouches[touch]?.location = touch.location(in: view)
        }
    }
    
    func touchesEnded(_ touches: Set<UITouch>, in view: UIView) {
        for touch in touches {
            activeTouches.removeValue(forKey: touch)
        }
    }
    
    func touchesCancelled(_ touches: Set<UITouch>, in view: UIView) {
        for touch in touches {
            activeTouches.removeValue(forKey: touch)
        }
    }
}
