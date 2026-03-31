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
#if os(iOS)
import Photos
#elseif os(macOS)
import AppKit
#endif

@MainActor
final class VideoRecorder {
    
    enum State { case idle, recording, finishing }
    private(set) var state: State = .idle
    
    // Serial queue for AVAssetWriter appends — guarantees frame ordering
    private let writerQueue = DispatchQueue(label: "com.magnetic.videowriter")
    
    // AVAssetWriter pipeline
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    
    // Triple-buffer: 3 pixel buffers to handle GPU pipeline depth
    // While buffer N is being blitted by GPU, buffer N-1 may still be held by
    // the writer queue waiting to append. Buffer N-2 is free.
    private var captureTextures: [MTLTexture] = []
    private var capturePixelBuffers: [CVPixelBuffer] = []
    private var textureCache: CVMetalTextureCache?
    private var currentBufferIndex: Int = 0
    private let bufferCount = 3
    
    // Timing
    private var startTime: CFTimeInterval = 0
    private var lastCaptureTime: CFTimeInterval = 0
    private var captureInterval: CFTimeInterval = 1.0 / 30.0
    private var frameCount: Int64 = 0
    private var recordFPS: Int = 30
    
    // writerQueue: last appended frame number — enforces monotonic order
    // Accessed only from writerQueue
    private var lastAppendedFrame: Int64 = -1
    
    // Track writer failure to stop blitting early
    private var writerFailed: Bool = false
    
    // Output
    private var outputURL: URL?
    
    // Recording dimensions
    private var recordWidth: Int = 0
    private var recordHeight: Int = 0
    
    // Completion callback
    var onRecordingFinished: ((Result<URL, Error>) -> Void)?
    
    // MARK: - Start Recording
    
    func startRecording(device: MTLDevice, width: Int, height: Int, fps: Int = 30) {
        guard state == .idle else { return }
        
        // Ensure even dimensions for H.264
        let w = width & ~1
        let h = height & ~1
        guard w > 0 && h > 0 else { return }
        
        recordWidth = w
        recordHeight = h
        recordFPS = fps
        
        // Clean up any previous temp file
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("magnetic_recording.mp4")
        try? FileManager.default.removeItem(at: tempURL)
        outputURL = tempURL
        
        // Create CVMetalTextureCache
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let textureCache = cache else {
            print("[VideoRecorder] Failed to create texture cache")
            return
        }
        self.textureCache = textureCache
        
        // Create triple pixel buffer + texture pairs
        captureTextures = []
        capturePixelBuffers = []
        for i in 0..<bufferCount {
            guard let (pb, tex) = createCaptureBuffer(device: device, cache: textureCache, width: w, height: h) else {
                print("[VideoRecorder] Failed to create capture buffer \(i)")
                cleanup()
                return
            }
            capturePixelBuffers.append(pb)
            captureTextures.append(tex)
        }
        currentBufferIndex = 0
        
        // Create AVAssetWriter
        guard let writer = try? AVAssetWriter(outputURL: tempURL, fileType: .mp4) else {
            print("[VideoRecorder] Failed to create AVAssetWriter")
            return
        }
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: w * h * 10,
                AVVideoMaxKeyFrameIntervalKey: fps,
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
        
        if writer.status == .failed {
            print("[VideoRecorder] Writer failed to start: \(writer.error?.localizedDescription ?? "unknown")")
            cleanup()
            return
        }
        
        startTime = CACurrentMediaTime()
        lastCaptureTime = 0
        captureInterval = 1.0 / Double(fps)
        frameCount = 0
        lastAppendedFrame = -1
        writerFailed = false
        state = .recording
        print("[VideoRecorder] Recording started at \(w)x\(h) @ \(fps)fps")
    }
    
    /// Create a CVPixelBuffer + MTLTexture pair backed by IOSurface (zero-copy GPU/CPU sharing)
    private func createCaptureBuffer(device: MTLDevice, cache: CVMetalTextureCache, width: Int, height: Int) -> (CVPixelBuffer, MTLTexture)? {
        let pixelBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            pixelBufferAttrs as CFDictionary,
                            &pixelBuffer)
        guard status == kCVReturnSuccess, let pb = pixelBuffer else {
            print("[VideoRecorder] CVPixelBufferCreate failed: \(status)")
            return nil
        }
        
        var cvTexture: CVMetalTexture?
        let texStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pb, nil,
            .bgra8Unorm, width, height, 0, &cvTexture)
        guard texStatus == kCVReturnSuccess,
              let cvTex = cvTexture,
              let metalTexture = CVMetalTextureGetTexture(cvTex) else {
            print("[VideoRecorder] CVMetalTextureCacheCreateTextureFromImage failed: \(texStatus)")
            return nil
        }
        
        return (pb, metalTexture)
    }
    
    // MARK: - Capture Frame
    
    /// Blit the drawable into a capture buffer (added to the render command buffer).
    /// After GPU completes, append the pixel buffer on writerQueue in frame order.
    func captureFrame(commandBuffer: MTLCommandBuffer, sourceTexture: MTLTexture) {
        guard state == .recording, !writerFailed else { return }
        
        // Frame throttle
        let now = CACurrentMediaTime()
        let elapsed = now - startTime
        if elapsed - lastCaptureTime < captureInterval * 0.9 { return }
        lastCaptureTime = elapsed
        
        guard let input = videoInput, input.isReadyForMoreMediaData else { return }
        
        // Assign frame number (sequential on main thread)
        let thisFrame = frameCount
        frameCount += 1
        
        // Round-robin buffer selection
        let bufIdx = currentBufferIndex % bufferCount
        currentBufferIndex += 1
        let captureTex = captureTextures[bufIdx]
        let capturePB = capturePixelBuffers[bufIdx]
        
        // Blit inside the main render command buffer (drawable texture is still valid here)
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }
        let w = min(sourceTexture.width, captureTex.width)
        let h = min(sourceTexture.height, captureTex.height)
        blitEncoder.copy(
            from: sourceTexture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: w, height: h, depth: 1),
            to: captureTex, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blitEncoder.endEncoding()
        
        // After GPU completes blit, dispatch append to serial writerQueue
        let adp = pixelBufferAdaptor!
        let inp = input
        let writer = assetWriter
        let fps = recordFPS
        let queue = writerQueue
        
        commandBuffer.addCompletedHandler { [weak self] _ in
            queue.async { [weak self] in
                guard let self else { return }
                guard !self.writerFailed else { return }
                
                if writer?.status == .failed {
                    self.writerFailed = true
                    return
                }
                
                // Enforce monotonic frame ordering:
                // If this frame arrived out of order, skip it (drop the late frame)
                guard thisFrame > self.lastAppendedFrame else { return }
                
                guard inp.isReadyForMoreMediaData else { return }
                
                let time = CMTime(value: thisFrame, timescale: CMTimeScale(fps))
                if !adp.append(capturePB, withPresentationTime: time) {
                    let errMsg = writer?.error?.localizedDescription ?? "unknown"
                    print("[VideoRecorder] Failed to append frame \(thisFrame) (error: \(errMsg))")
                    self.writerFailed = true
                } else {
                    self.lastAppendedFrame = thisFrame
                }
            }
        }
    }
    
    // MARK: - Stop Recording
    
    func stopRecording() {
        guard state == .recording else { return }
        state = .finishing
        
        let totalFrames = frameCount
        print("[VideoRecorder] Stopping recording... (\(totalFrames) frames captured)")
        
        // Drain writerQueue first so all pending appends complete before finishing
        let writer = assetWriter
        let url = outputURL
        let input = videoInput
        let queue = writerQueue
        
        queue.async {
            // All pending appends have now completed (serial queue)
            Task { @MainActor [weak self] in
                guard let self else { return }
                
                input?.markAsFinished()
                
                writer?.finishWriting {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        
                        if let error = writer?.error {
                            print("[VideoRecorder] Writer finished with error: \(error.localizedDescription)")
                            self.state = .idle
                            self.onRecordingFinished?(.failure(error))
                            self.cleanup()
                            return
                        }
                        
                        guard writer?.status == .completed else {
                            print("[VideoRecorder] Writer status: \(String(describing: writer?.status.rawValue))")
                            self.state = .idle
                            self.cleanup()
                            return
                        }
                        
                        print("[VideoRecorder] Writer finished successfully")
                        
                        if let url = url {
                            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                            print("[VideoRecorder] Output file size: \(fileSize) bytes, \(self.lastAppendedFrame + 1) frames written")
                            
                            if fileSize > 0 {
                                self.saveToPhotoLibrary(url: url)
                            } else {
                                print("[VideoRecorder] Output file is empty!")
                                self.state = .idle
                                self.onRecordingFinished?(.failure(RecordingError.emptyFile))
                                self.cleanup()
                            }
                        } else {
                            self.state = .idle
                            self.cleanup()
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Save Recording
    
    private func saveToPhotoLibrary(url: URL) {
        #if os(iOS)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard status == .authorized || status == .limited else {
                    print("[VideoRecorder] Photo library access denied: \(status.rawValue)")
                    self.state = .idle
                    self.onRecordingFinished?(.failure(RecordingError.photoLibraryDenied))
                    self.cleanup()
                    return
                }
                
                print("[VideoRecorder] Saving to photo library...")
                
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } completionHandler: { success, error in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.state = .idle
                        if success {
                            print("[VideoRecorder] Saved to camera roll successfully!")
                            self.onRecordingFinished?(.success(url))
                        } else if let error = error {
                            print("[VideoRecorder] Failed to save: \(error.localizedDescription)")
                            self.onRecordingFinished?(.failure(error))
                        } else {
                            print("[VideoRecorder] Save failed with no error")
                        }
                        try? FileManager.default.removeItem(at: url)
                        self.cleanup()
                    }
                }
            }
        }
        #elseif os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "Magnetic_Recording.mp4"
        panel.canCreateDirectories = true
        
        panel.begin { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state = .idle
                if response == .OK, let destURL = panel.url {
                    do {
                        // Remove existing file at destination if present
                        if FileManager.default.fileExists(atPath: destURL.path) {
                            try FileManager.default.removeItem(at: destURL)
                        }
                        try FileManager.default.moveItem(at: url, to: destURL)
                        print("[VideoRecorder] Saved to \(destURL.path)")
                        self.onRecordingFinished?(.success(destURL))
                    } catch {
                        print("[VideoRecorder] Failed to save: \(error.localizedDescription)")
                        self.onRecordingFinished?(.failure(error))
                    }
                } else {
                    print("[VideoRecorder] Save cancelled by user")
                    try? FileManager.default.removeItem(at: url)
                    self.onRecordingFinished?(.failure(RecordingError.saveCancelled))
                }
                self.cleanup()
            }
        }
        #endif
    }
    
    private func cleanup() {
        captureTextures = []
        capturePixelBuffers = []
        textureCache = nil
        assetWriter = nil
        videoInput = nil
        pixelBufferAdaptor = nil
    }
    
    enum RecordingError: LocalizedError {
        case photoLibraryDenied
        case emptyFile
        case saveCancelled
        
        var errorDescription: String? {
            switch self {
            case .photoLibraryDenied:
                return "Photo library access denied"
            case .emptyFile:
                return "Recording produced an empty file"
            case .saveCancelled:
                return "Save cancelled by user"
            }
        }
    }
}
