//
//  ImageCropView.swift
//  Magnetic
//
//  SNS-style image crop UI for environment map photo selection
//

import SwiftUI
import PhotosUI

// MARK: - Crop Shape

enum CropShape {
    case square
    case circle
}

// MARK: - Image Crop View

struct ImageCropView: View {
    @State private var currentImage: UIImage
    let onCropped: (UIImage) -> Void
    let onCancel: () -> Void
    let onNewImage: ((UIImage) -> Void)?  // notify parent of new photo selection
    
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var rotation: Angle = .zero
    @State private var lastRotation: Angle = .zero
    @State private var cropShape: CropShape = .square
    @State private var tileCount: Int = 1  // 1 (no tile), 4 (2x2), 8 (2x4), 16 (4x4)
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    
    init(inputImage: UIImage,
         onCropped: @escaping (UIImage) -> Void,
         onCancel: @escaping () -> Void,
         onNewImage: ((UIImage) -> Void)? = nil) {
        _currentImage = State(initialValue: inputImage)
        self.onCropped = onCropped
        self.onCancel = onCancel
        self.onNewImage = onNewImage
    }
    
    var body: some View {
        GeometryReader { geo in
            let cropSize = min(geo.size.width - 40, geo.size.height - 220)  // leave room for top/bottom controls
            
            ZStack {
                Color.black.ignoresSafeArea()
                
                // Image layer (pannable + zoomable)
                Image(uiImage: currentImage)
                    .resizable()
                    .scaledToFit()
                    .rotationEffect(rotation)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        SimultaneousGesture(
                            SimultaneousGesture(
                                DragGesture()
                                    .onChanged { value in
                                        offset = CGSize(
                                            width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height
                                        )
                                    }
                                    .onEnded { _ in
                                        lastOffset = offset
                                        clampOffset(cropSize: cropSize, geoSize: geo.size)
                                    },
                                MagnificationGesture()
                                    .onChanged { value in
                                        let minScale = minimumScale(cropSize: cropSize, geoSize: geo.size)
                                        scale = max(minScale, lastScale * value)
                                    }
                                    .onEnded { _ in
                                        let minScale = minimumScale(cropSize: cropSize, geoSize: geo.size)
                                        scale = max(minScale, scale)
                                        lastScale = scale
                                        clampOffset(cropSize: cropSize, geoSize: geo.size)
                                    }
                            ),
                            RotationGesture()
                                .onChanged { angle in
                                    rotation = lastRotation + angle
                                }
                                .onEnded { angle in
                                    rotation = lastRotation + angle
                                    lastRotation = rotation
                                }
                        )
                    )
                
                // Crop overlay
                CropOverlay(cropSize: cropSize, shape: cropShape)
                    .allowsHitTesting(false)
                
                // Center crosshair
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .thin))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .allowsHitTesting(false)
                
                // Controls
                VStack(spacing: 0) {
                    // Top bar: Cancel / Done
                    HStack {
                        Button {
                            onCancel()
                        } label: {
                            Text("CANCEL")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color(white: 0.5))
                                .tracking(2)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                        }
                        
                        Spacer()
                        
                        // Pick new photo from camera roll
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 16))
                                .foregroundStyle(Color(white: 0.5))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                        }
                        .onChange(of: selectedPhotoItem) { newItem in
                            guard let newItem = newItem else { return }
                            Task {
                                if let data = try? await newItem.loadTransferable(type: Data.self),
                                   let image = UIImage(data: data) {
                                    currentImage = image
                                    onNewImage?(image)
                                    // Reset position/scale/rotation for new image
                                    offset = .zero
                                    lastOffset = .zero
                                    scale = 1.0
                                    lastScale = 1.0
                                    rotation = .zero
                                    lastRotation = .zero
                                }
                            }
                        }
                        
                        Spacer()
                        
                        Button {
                            if let cropped = cropImage(cropSize: cropSize, geoSize: geo.size) {
                                let final = tileCount > 1 ? tileImage(cropped, count: tileCount) ?? cropped : cropped
                                onCropped(final)
                            }
                        } label: {
                            Text("DONE")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .tracking(2)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.horizontal, 8)
                    
                    Spacer()
                    
                    // Bottom bar: shape toggle + tile selector
                    VStack(spacing: 20) {
                        // Shape toggle
                        HStack(spacing: 24) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    cropShape = .square
                                }
                            } label: {
                                Image(systemName: "square")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(cropShape == .square ? .white : Color(white: 0.4))
                            }
                            
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    cropShape = .circle
                                }
                            } label: {
                                Image(systemName: "circle")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(cropShape == .circle ? .white : Color(white: 0.4))
                            }
                        }
                        
                        // Tile selector
                        HStack(spacing: 4) {
                            Text("TILE")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color(white: 0.5))
                                .tracking(2)
                            
                            ForEach([1, 4, 8, 16], id: \.self) { count in
                                Button {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        tileCount = count
                                    }
                                } label: {
                                    Text(count == 1 ? "OFF" : "\(count)")
                                        .font(.system(size: 11, weight: tileCount == count ? .bold : .medium, design: .monospaced))
                                        .foregroundStyle(tileCount == count ? .white : Color(white: 0.4))
                                        .frame(width: 36, height: 28)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(tileCount == count ? Color(white: 0.2) : Color.clear)
                                        )
                                }
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
            .onAppear {
                // Set initial scale so image fills crop area
                let minScale = minimumScale(cropSize: cropSize, geoSize: geo.size)
                scale = minScale
                lastScale = minScale
            }
            .onChange(of: currentImage) { _ in
                let minScale = minimumScale(cropSize: cropSize, geoSize: geo.size)
                scale = minScale
                lastScale = minScale
                offset = .zero
                lastOffset = .zero
                rotation = .zero
                lastRotation = .zero
            }
        }
        .statusBarHidden(true)
        .background(Color.black)
        .persistentSystemOverlays(.hidden)
    }
    
    // MARK: - Geometry Helpers
    
    /// Image size when fitted to screen (before user scaling)
    private func fittedSize(geoSize: CGSize) -> CGSize {
        let imageAspect = currentImage.size.width / currentImage.size.height
        let screenAspect = geoSize.width / geoSize.height
        if imageAspect > screenAspect {
            return CGSize(width: geoSize.width, height: geoSize.width / imageAspect)
        } else {
            return CGSize(width: geoSize.height * imageAspect, height: geoSize.height)
        }
    }
    
    /// Minimum scale to ensure image covers the crop area
    private func minimumScale(cropSize: CGFloat, geoSize: CGSize) -> CGFloat {
        let fitted = fittedSize(geoSize: geoSize)
        return max(cropSize / fitted.width, cropSize / fitted.height)
    }
    
    /// Clamp offset so image edges don't enter the crop area
    private func clampOffset(cropSize: CGFloat, geoSize: CGSize) {
        let fitted = fittedSize(geoSize: geoSize)
        let scaledW = fitted.width * scale
        let scaledH = fitted.height * scale
        
        let maxX = max(0, (scaledW - cropSize) / 2)
        let maxY = max(0, (scaledH - cropSize) / 2)
        
        withAnimation(.easeOut(duration: 0.2)) {
            offset.width = min(maxX, max(-maxX, offset.width))
            offset.height = min(maxY, max(-maxY, offset.height))
        }
        lastOffset = offset
    }
    
    // MARK: - Crop Logic
    
    private func cropImage(cropSize: CGFloat, geoSize: CGSize) -> UIImage? {
        let normalized = currentImage.normalizedOrientation()
        let fitted = fittedSize(geoSize: geoSize)
        
        // Output size in pixels (use cropSize as output resolution)
        let outputPx = cropSize * UIScreen.main.scale
        let outputSize = CGSize(width: outputPx, height: outputPx)
        
        UIGraphicsBeginImageContextWithOptions(outputSize, false, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }
        
        // The crop area center is at screen center.
        // Image center on screen = screen center + offset.
        // So image center relative to crop center = offset.
        // In the output image, crop center = (outputPx/2, outputPx/2).
        
        let imgW = fitted.width * scale
        let imgH = fitted.height * scale
        
        // Scale from screen points to output pixels
        let screenToPx = outputPx / cropSize
        
        ctx.translateBy(x: outputPx / 2, y: outputPx / 2)
        
        // Apply offset (image center relative to crop center)
        ctx.translateBy(x: offset.width * screenToPx, y: offset.height * screenToPx)
        
        // Apply rotation
        ctx.rotate(by: rotation.radians)
        
        // Apply scale
        ctx.scaleBy(x: scale * screenToPx, y: scale * screenToPx)
        
        // Draw image centered at origin (in fitted coordinates)
        let drawRect = CGRect(x: -fitted.width / 2, y: -fitted.height / 2,
                              width: fitted.width, height: fitted.height)
        normalized.draw(in: drawRect)
        
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        guard let result else { return nil }
        
        if cropShape == .circle {
            return applyCircleMask(uiImage: result)
        }
        
        return result
    }
    
    /// Apply circular mask to a square UIImage
    private func applyCircleMask(uiImage: UIImage) -> UIImage? {
        let rect = CGRect(x: 0, y: 0, width: uiImage.size.width, height: uiImage.size.height)
        
        UIGraphicsBeginImageContextWithOptions(rect.size, false, 1.0)
        
        // Clip to circle
        UIBezierPath(ovalIn: rect).addClip()
        uiImage.draw(in: rect)
        
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }
    
    /// Tile an image into a grid: 4→2x2, 8→4x2, 16→4x4
    private func tileImage(_ image: UIImage, count: Int) -> UIImage? {
        let cols: Int
        let rows: Int
        switch count {
        case 4:  cols = 2; rows = 2
        case 8:  cols = 4; rows = 2
        case 16: cols = 4; rows = 4
        default: return image
        }
        
        let tileW = image.size.width
        let tileH = image.size.height
        let totalSize = CGSize(width: tileW * CGFloat(cols), height: tileH * CGFloat(rows))
        
        UIGraphicsBeginImageContextWithOptions(totalSize, true, 1.0)
        
        // Use UIImage.draw for correct Y orientation
        for row in 0..<rows {
            for col in 0..<cols {
                let rect = CGRect(x: tileW * CGFloat(col),
                                  y: tileH * CGFloat(row),
                                  width: tileW,
                                  height: tileH)
                image.draw(in: rect)
            }
        }
        
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }
}

// MARK: - Crop Overlay

private struct CropOverlay: View {
    let cropSize: CGFloat
    let shape: CropShape
    
    var body: some View {
        GeometryReader { geo in
            Canvas { context, canvasSize in
                // Fill entire canvas with semi-transparent black
                context.fill(
                    Path(CGRect(origin: .zero, size: canvasSize)),
                    with: .color(.black.opacity(0.6))
                )
                
                // Cut out the crop area (clear)
                let cropRect = CGRect(
                    x: (canvasSize.width - cropSize) / 2,
                    y: (canvasSize.height - cropSize) / 2,
                    width: cropSize,
                    height: cropSize
                )
                
                let cutoutPath: Path
                switch shape {
                case .square:
                    cutoutPath = Path(roundedRect: cropRect, cornerRadius: 2)
                case .circle:
                    cutoutPath = Path(ellipseIn: cropRect)
                }
                
                context.blendMode = .destinationOut
                context.fill(cutoutPath, with: .color(.white))
            }
            .compositingGroup()
            
            // Border
            let cropRect = CGRect(
                x: (geo.size.width - cropSize) / 2,
                y: (geo.size.height - cropSize) / 2,
                width: cropSize,
                height: cropSize
            )
            
            switch shape {
            case .square:
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.white.opacity(0.6), lineWidth: 0.5)
                    .frame(width: cropSize, height: cropSize)
                    .position(x: cropRect.midX, y: cropRect.midY)
            case .circle:
                Circle()
                    .stroke(Color.white.opacity(0.6), lineWidth: 0.5)
                    .frame(width: cropSize, height: cropSize)
                    .position(x: cropRect.midX, y: cropRect.midY)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - UIImage Orientation Helper

extension UIImage {
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        draw(in: CGRect(origin: .zero, size: size))
        let normalized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return normalized ?? self
    }
}
