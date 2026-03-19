//
//  VideoRecorder.swift
//  Magnetic
//
//  Records Metal frames to H.264 .mp4 and saves to Camera Roll.
//

import Foundation
import AVFoundation
import Metal
import CoreVideo
import Photos

@MainActor
final class VideoRecorder {
    
    enum State { case idle, recording, finishing }
    private(set) var state: State = .idle
    
    // Serial queue for AVAssetWriter appends (avoids blocking main thread)
    private let writerQueue = DispatchQueue(label: "com.magnetic.videowriter")
    
    // AVAssetWriter pipeline
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    
    // CVPixelBuffer-backed Metal texture for zero-copy capture
    private var captureTexture: MTLTexture?
    private var capturePixelBuffer: CVPixelBuffer?
    private var textureCache: CVMetalTextureCache?
    
    // Timing
    private var startTime: CFTimeInterval = 0
    
    // Output
    private var outputURL: URL?
    
    // Completion callback
    var onRecordingFinished: ((Result<URL, Error>) -> Void)?
    
    // MARK: - Start Recording
    
    func startRecording(device: MTLDevice, width: Int, height: Int, fps: Int = 30) {
        guard state == .idle else { return }
        
        // Ensure even dimensions for H.264
        let w = width & ~1
        let h = height & ~1
        guard w > 0 && h > 0 else { return }
        
        // Clean up any previous temp file
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("magnetic_recording.mp4")
        try? FileManager.default.removeItem(at: tempURL)
        outputURL = tempURL
        
        // Create CVMetalTextureCache
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let textureCache = cache else { return }
        self.textureCache = textureCache
        
        // Create CVPixelBuffer backed by IOSurface (shared CPU/GPU memory)
        let pixelBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                            kCVPixelFormatType_32BGRA,
                            pixelBufferAttrs as CFDictionary,
                            &pixelBuffer)
        guard let pb = pixelBuffer else { return }
        self.capturePixelBuffer = pb
        
        // Create MTLTexture wrapping the CVPixelBuffer
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pb, nil,
            .bgra8Unorm, w, h, 0, &cvTexture)
        guard let cvTex = cvTexture,
              let metalTexture = CVMetalTextureGetTexture(cvTex) else { return }
        self.captureTexture = metalTexture
        
        // Create AVAssetWriter
        guard let writer = try? AVAssetWriter(outputURL: tempURL, fileType: .mp4) else { return }
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: w * h * 4, // ~4 bits per pixel
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        )
        
        writer.add(input)
        self.assetWriter = writer
        self.videoInput = input
        self.pixelBufferAdaptor = adaptor
        
        // Start writing
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        
        startTime = CACurrentMediaTime()
        state = .recording
    }
    
    // MARK: - Capture Frame
    
    func captureFrame(commandBuffer: MTLCommandBuffer, sourceTexture: MTLTexture) {
        guard state == .recording,
              let captureTexture = captureTexture,
              let capturePixelBuffer = capturePixelBuffer,
              let adaptor = pixelBufferAdaptor,
              let input = videoInput,
              input.isReadyForMoreMediaData else { return }
        
        // Blit from drawable texture to capture texture
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }
        
        let w = min(sourceTexture.width, captureTexture.width)
        let h = min(sourceTexture.height, captureTexture.height)
        
        blitEncoder.copy(
            from: sourceTexture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: w, height: h, depth: 1),
            to: captureTexture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blitEncoder.endEncoding()
        
        // After GPU completes blit, append pixel buffer to writer on a dedicated queue
        let recordStartTime = startTime
        let pb = capturePixelBuffer
        let adp = adaptor
        let inp = input
        let queue = writerQueue
        commandBuffer.addCompletedHandler { _ in
            let elapsed = CACurrentMediaTime() - recordStartTime
            let time = CMTime(seconds: elapsed, preferredTimescale: 600)
            queue.async {
                if inp.isReadyForMoreMediaData {
                    adp.append(pb, withPresentationTime: time)
                }
            }
        }
    }
    
    // MARK: - Stop Recording
    
    func stopRecording() {
        guard state == .recording else { return }
        state = .finishing
        
        videoInput?.markAsFinished()
        assetWriter?.finishWriting { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error = self.assetWriter?.error {
                    self.state = .idle
                    self.onRecordingFinished?(.failure(error))
                    self.cleanup()
                    return
                }
                if let url = self.outputURL {
                    self.saveToPhotoLibrary(url: url)
                } else {
                    self.state = .idle
                    self.cleanup()
                }
            }
        }
    }
    
    // MARK: - Save to Photo Library
    
    private func saveToPhotoLibrary(url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized || status == .limited else {
                    self.state = .idle
                    self.onRecordingFinished?(.failure(RecordingError.photoLibraryDenied))
                    self.cleanup()
                    return
                }
                
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } completionHandler: { success, error in
                    DispatchQueue.main.async {
                        self.state = .idle
                        if success {
                            self.onRecordingFinished?(.success(url))
                        } else if let error = error {
                            self.onRecordingFinished?(.failure(error))
                        }
                        // Clean up temp file
                        try? FileManager.default.removeItem(at: url)
                        self.cleanup()
                    }
                }
            }
        }
    }
    
    private func cleanup() {
        captureTexture = nil
        capturePixelBuffer = nil
        textureCache = nil
        assetWriter = nil
        videoInput = nil
        pixelBufferAdaptor = nil
    }
    
    enum RecordingError: LocalizedError {
        case photoLibraryDenied
        
        var errorDescription: String? {
            switch self {
            case .photoLibraryDenied:
                return "Photo library access denied"
            }
        }
    }
}
