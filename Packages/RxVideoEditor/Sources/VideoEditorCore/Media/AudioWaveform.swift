import AVFoundation
import AudioToolbox
import Foundation

public struct AudioWaveform: Sendable {
    public let duration: TimeInterval
    public let peaks: [Float]

    /// Peak in a source-time interval, so zooming and trimming never stretch a
    /// whole-file waveform into the wrong part of a clip.
    public func peak(from start: TimeInterval, to end: TimeInterval) -> Float {
        guard duration > 0, !peaks.isEmpty, start.isFinite, end.isFinite,
              end > start, end > 0, start < duration else { return 0 }
        let lower = max(0, Int(floor(max(0, start) / duration * Double(peaks.count))))
        let upper = min(peaks.count, Int(ceil(min(duration, end) / duration * Double(peaks.count))))
        guard lower < upper else { return 0 }
        return peaks[lower..<upper].max() ?? 0
    }

    /// Interpolate between summary bins when zoomed in instead of repeating
    /// each bin as a wide, flat step. Zoomed-out columns retain their peak.
    public func displayPeak(from start: TimeInterval, to end: TimeInterval) -> Float {
        guard duration > 0, !peaks.isEmpty, start.isFinite, end.isFinite,
              end > start, end > 0, start < duration else { return 0 }
        let binDuration = duration / Double(peaks.count)
        guard end - start < binDuration else { return peak(from: start, to: end) }
        let center = (max(0, start) + min(duration, end)) / 2
        let position = min(Double(peaks.count - 1), max(0, center / binDuration - 0.5))
        let lower = Int(floor(position))
        let upper = min(peaks.count - 1, lower + 1)
        let fraction = Float(position - Double(lower))
        // Smoothstep stays within neighboring peaks, without ringing or overshoot.
        let blend = fraction * fraction * (3 - 2 * fraction)
        return peaks[lower] + (peaks[upper] - peaks[lower]) * blend
    }

}

/// Bounded, shared summaries: repeated timeline clips decode a file only once.
public actor AudioWaveformCache {
    public static let shared = AudioWaveformCache()
    private struct Key: Hashable {
        let url: URL
        let modified: Date?
        let size: Int?
    }
    private var jobs: [Key: Task<AudioWaveform?, Never>] = [:]
    private var order: [Key] = []

    public func waveform(for url: URL) async -> AudioWaveform? {
        let attributes = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = Key(url: url, modified: attributes?.contentModificationDate, size: attributes?.fileSize)
        if let job = jobs[key] { return await job.value }
        let job = Task.detached(priority: .utility) { await Self.decode(url) }
        jobs[key] = job
        order.append(key)
        if order.count > 16 { jobs.removeValue(forKey: order.removeFirst()) }
        return await job.value
    }

    private static func decode(_ url: URL) async -> AudioWaveform? {
        do {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let duration = CMTimeGetSeconds(try await asset.load(.duration))
            guard !tracks.isEmpty, duration.isFinite, duration > 0 else { return nil }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 8_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            guard reader.startReading() else { return nil }
            defer { reader.cancelReading() }
            let count = Int(min(100_000, max(1, ceil(duration * 100))))
            var peaks = [Float](repeating: 0, count: count)
            while let buffer = output.copyNextSampleBuffer() {
                guard !Task.isCancelled else { return nil }
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let frames = CMSampleBufferGetNumSamples(buffer)
                let start = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
                var samples = [Float](repeating: 0, count: frames * 2)
                let status = samples.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { continue }
                for frame in 0..<frames {
                    let time = start + Double(frame) / 8_000
                    let bin = min(count - 1, max(0, Int(time / duration * Double(count))))
                    peaks[bin] = max(peaks[bin], abs(samples[frame * 2]), abs(samples[frame * 2 + 1]))
                }
            }
            guard reader.status == .completed else { return nil }
            return AudioWaveform(duration: duration, peaks: peaks)
        } catch { return nil }
    }
}
