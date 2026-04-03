//
//  CustomSoundManager.swift
//  Magnetic
//
//  Persistence and utility for custom recorded WALL HIT sounds (REC1/2/3)
//

import AVFoundation

enum CustomSoundManager {
    
    private static let directoryName = "CustomSounds"
    
    // MARK: - File Paths
    
    private static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    static func soundURL(for slot: Int) -> URL {
        directory.appendingPathComponent("rec_wall_\(slot).wav")
    }
    
    // MARK: - Query
    
    static func hasRecording(slot: Int) -> Bool {
        FileManager.default.fileExists(atPath: soundURL(for: slot).path)
    }
    
    // MARK: - Save
    
    /// Save a trimmed + faded AVAudioPCMBuffer as WAV
    static func saveRecording(buffer: AVAudioPCMBuffer, slot: Int) throws {
        let url = soundURL(for: slot)
        // Write as standard PCM float32 WAV
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: buffer.format.sampleRate,
            AVNumberOfChannelsKey: buffer.format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: buffer.format.isInterleaved ? false : true
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }
    
    // MARK: - Load
    
    /// Load a saved WAV into an AVAudioPCMBuffer for playback
    static func loadBuffer(slot: Int) -> AVAudioPCMBuffer? {
        let url = soundURL(for: slot)
        guard FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url) else { return nil }
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else { return nil }
        do {
            try file.read(into: buffer)
            return buffer
        } catch {
            return nil
        }
    }
    
    // MARK: - Delete
    
    static func deleteRecording(slot: Int) {
        let url = soundURL(for: slot)
        try? FileManager.default.removeItem(at: url)
    }
    
    // MARK: - Trim + Fade
    
    /// Extract a sub-range from the buffer (startFrame ..< endFrame)
    static func trimBuffer(_ buffer: AVAudioPCMBuffer,
                           startFrame: AVAudioFramePosition,
                           endFrame: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        let length = AVAudioFrameCount(endFrame - startFrame)
        guard length > 0,
              let trimmed = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: length) else { return nil }
        trimmed.frameLength = length
        
        let channels = Int(buffer.format.channelCount)
        guard let srcData = buffer.floatChannelData,
              let dstData = trimmed.floatChannelData else { return nil }
        
        let start = Int(startFrame)
        for ch in 0..<channels {
            dstData[ch].update(from: srcData[ch].advanced(by: start), count: Int(length))
        }
        return trimmed
    }
    
    /// Apply fade-in and fade-out to avoid clicks/noise
    /// Default: 15ms fade-in, 40ms fade-out
    static func applyFades(_ buffer: AVAudioPCMBuffer,
                           fadeInSeconds: Double = 0.015,
                           fadeOutSeconds: Double = 0.040) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let sampleRate = buffer.format.sampleRate
        
        let fadeInFrames = min(Int(fadeInSeconds * sampleRate), frameCount / 2)
        let fadeOutFrames = min(Int(fadeOutSeconds * sampleRate), frameCount / 2)
        
        for ch in 0..<channels {
            let data = channelData[ch]
            // Fade in (linear ramp 0→1)
            for i in 0..<fadeInFrames {
                data[i] *= Float(i) / Float(fadeInFrames)
            }
            // Fade out (linear ramp 1→0)
            for i in 0..<fadeOutFrames {
                let idx = frameCount - 1 - i
                data[idx] *= Float(i) / Float(fadeOutFrames)
            }
        }
    }
    
    // MARK: - Waveform Visualization
    
    /// Downsample buffer amplitude to `count` bars for waveform display
    static func waveformSamples(from buffer: AVAudioPCMBuffer, count: Int) -> [Float] {
        guard let channelData = buffer.floatChannelData,
              buffer.frameLength > 0, count > 0 else {
            return Array(repeating: 0, count: max(count, 1))
        }
        
        let frameCount = Int(buffer.frameLength)
        let data = channelData[0] // mono or first channel
        let samplesPerBar = max(frameCount / count, 1)
        
        var result: [Float] = []
        result.reserveCapacity(count)
        
        for i in 0..<count {
            let start = i * samplesPerBar
            let end = min(start + samplesPerBar, frameCount)
            guard start < frameCount else {
                result.append(0)
                continue
            }
            var maxAmp: Float = 0
            for j in start..<end {
                let amp = abs(data[j])
                if amp > maxAmp { maxAmp = amp }
            }
            result.append(maxAmp)
        }
        return result
    }
}
