//
//  PresetManager.swift
//  Magnetic
//
//  Save/load all settings to numbered preset slots via UserDefaults
//

import Foundation
import SwiftUI

enum PresetManager {
    
    /// All AppStorage keys that constitute a preset
    static let settingKeys: [String] = [
        "tapOrbit", "tapColor", "tapBall", "camMode",
        "basicMode",
        "ballCount", "isMicEnabled", "materialMode", "colorHue", "colorBri",
        "envMapIndex", "envIntensity", "isBPMEnabled", "orbitPattern",
        "ballSize", "bgMode", "bgCustomHue", "bgCustomSat",
        "bgCustomBri", "envLocked", "autoHue", "autoBgHue", "spacing",
        "orbitRange", "gridMode", "fps", "manualBPM",
        "recEnabled", "consoleMode", "brightnessSync", "brightnessSyncMax",
        "blendK"
    ]
    
    /// UserDefaults key for slot N
    private static func slotKey(_ index: Int) -> String {
        "preset_slot_\(index)"
    }
    
    /// UserDefaults key for thumbnail N
    private static func thumbKey(_ index: Int) -> String {
        "preset_thumb_\(index)"
    }
    
    /// Save current AppStorage values into a slot
    static func save(to slotIndex: Int) {
        let defaults = UserDefaults.standard
        var dict: [String: Any] = [:]
        for key in settingKeys {
            if let value = defaults.object(forKey: key) {
                dict[key] = value
            }
        }
        dict["_savedAt"] = Date().timeIntervalSince1970
        
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            defaults.set(data, forKey: slotKey(slotIndex))
        }
    }
    
    /// Save a thumbnail image for a slot (center-cropped to square, 200x200 JPEG)
    static func saveThumbnail(_ image: PlatformImage, to slotIndex: Int) {
        guard let cgImage = image.platformCGImage else { return }
        let side = min(cgImage.width, cgImage.height)
        let x = (cgImage.width - side) / 2
        let y = (cgImage.height - side) / 2
        let cropRect = CGRect(x: x, y: y, width: side, height: side)
        guard let cropped = cgImage.cropping(to: cropRect) else { return }
        
        let size = CGSize(width: 200, height: 200)
        let scaled = PlatformGraphics.renderImage(size: size, opaque: true, scale: 1.0) { ctx in
            ctx.draw(cropped, in: CGRect(origin: .zero, size: size))
        }
        
        if let data = scaled?.platformJpegData(compressionQuality: 0.5) {
            UserDefaults.standard.set(data, forKey: thumbKey(slotIndex))
        }
    }
    
    /// Load thumbnail image for a slot
    static func loadThumbnail(from slotIndex: Int) -> PlatformImage? {
        guard let data = UserDefaults.standard.data(forKey: thumbKey(slotIndex)) else { return nil }
        return PlatformImage.fromData(data)
    }
    
    /// Load settings dictionary from a slot (nil if empty)
    static func load(from slotIndex: Int) -> [String: Any]? {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: slotKey(slotIndex)),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict
    }
    
    /// Apply a loaded dictionary to UserDefaults
    static func apply(_ dict: [String: Any]) {
        let defaults = UserDefaults.standard
        for key in settingKeys {
            if let value = dict[key] {
                defaults.set(value, forKey: key)
            }
        }
    }
    
    /// Check if a slot has saved data
    static func isSlotOccupied(_ index: Int) -> Bool {
        UserDefaults.standard.data(forKey: slotKey(index)) != nil
    }
    
    /// Delete a slot and its thumbnail
    static func delete(slotIndex: Int) {
        UserDefaults.standard.removeObject(forKey: slotKey(slotIndex))
        UserDefaults.standard.removeObject(forKey: thumbKey(slotIndex))
    }
}
