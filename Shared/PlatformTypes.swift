//
//  PlatformTypes.swift
//  Magnetic
//
//  Cross-platform type aliases and helpers for iOS/macOS compatibility
//

import SwiftUI

#if os(iOS)
import UIKit
public typealias PlatformImage = UIImage
public typealias PlatformColor = UIColor
#elseif os(macOS)
import AppKit
public typealias PlatformImage = NSImage
public typealias PlatformColor = NSColor
#endif

// MARK: - Cross-platform Image Helpers

extension PlatformImage {
    /// Create image from data
    static func fromData(_ data: Data) -> PlatformImage? {
        #if os(iOS)
        return UIImage(data: data)
        #elseif os(macOS)
        return NSImage(data: data)
        #endif
    }
    
    /// Create image from file path
    static func fromFile(_ path: String) -> PlatformImage? {
        #if os(iOS)
        return UIImage(contentsOfFile: path)
        #elseif os(macOS)
        return NSImage(contentsOfFile: path)
        #endif
    }
    
    /// Create image from CGImage
    static func fromCGImage(_ cgImage: CGImage) -> PlatformImage {
        #if os(iOS)
        return UIImage(cgImage: cgImage)
        #elseif os(macOS)
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        return NSImage(cgImage: cgImage, size: size)
        #endif
    }
    
    /// Get CGImage from platform image
    var platformCGImage: CGImage? {
        #if os(iOS)
        return self.cgImage
        #elseif os(macOS)
        return self.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }
    
    /// Get JPEG data
    func platformJpegData(compressionQuality: CGFloat) -> Data? {
        #if os(iOS)
        return self.jpegData(compressionQuality: compressionQuality)
        #elseif os(macOS)
        guard let tiffData = self.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
        #endif
    }
}

// MARK: - Cross-platform Color Helpers

extension PlatformColor {
    /// Create color from HSB values
    static func fromHSB(hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat = 1) -> PlatformColor {
        #if os(iOS)
        return UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
        #elseif os(macOS)
        return NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
        #endif
    }
    
    /// Extract RGB components
    func getRGBComponents() -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        #if os(iOS)
        self.getRed(&r, green: &g, blue: &b, alpha: nil)
        #elseif os(macOS)
        let color = self.usingColorSpace(.deviceRGB) ?? self
        color.getRed(&r, green: &g, blue: &b, alpha: nil)
        #endif
        return (r, g, b)
    }
}

// MARK: - Cross-platform Graphics Helpers

enum PlatformGraphics {
    /// Render an image at a given size
    static func renderImage(size: CGSize, opaque: Bool = true, scale: CGFloat = 1.0, draw: (CGContext) -> Void) -> PlatformImage? {
        #if os(iOS)
        UIGraphicsBeginImageContextWithOptions(size, opaque, scale)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }
        draw(ctx)
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
        #elseif os(macOS)
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return nil
        }
        draw(ctx)
        image.unlockFocus()
        return image
        #endif
    }
    
    /// Scale factor for the main screen
    static var mainScreenScale: CGFloat {
        #if os(iOS)
        return UIScreen.main.scale
        #elseif os(macOS)
        return NSScreen.main?.backingScaleFactor ?? 2.0
        #endif
    }
}

// MARK: - SwiftUI Image from PlatformImage

extension Image {
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #elseif os(macOS)
        self.init(nsImage: platformImage)
        #endif
    }
}


