import AVFoundation
import AudioToolbox
import Foundation

public struct StereoAudioLevel: Sendable, Equatable {
    public var left: Float
    public var right: Float
    public static let silence = StereoAudioLevel(left: 0, right: 0)

    public init(left: Float, right: Float) {
        self.left = left
        self.right = right
    }
}

/// An immutable playback snapshot. AVFoundation owns the asset; the mix is copied
/// so subsequent viewer edits cannot change an in-flight read.
public struct AudioLevelSource: @unchecked Sendable {
    let asset: AVAsset
    let mix: AVAudioMix?

    public init(asset: AVAsset, mix: AVAudioMix?) {
        self.asset = asset
        self.mix = mix?.copy() as? AVAudioMix
    }
}

/// Decodes only audio, off the UI thread, using the player's composition and mix.
/// Keeping a sequential reader avoids reopening media at every meter refresh.
/// Stereo conversion and summing happen in AVFoundation before peak measurement,
/// so overlapping clips, volume ramps, mono sources and phase cancellation count.
public actor AudioLevelReader {
    private var reader: AVAssetReader?
    private var output: AVAssetReaderAudioMixOutput?
    private var source: AudioLevelSource?
    private var pending: CMSampleBuffer?
    private var lastTime: Double = -.infinity

    public init() {}

    public func setSource(_ source: AudioLevelSource?) {
        reader?.cancelReading()
        reader = nil
        output = nil
        pending = nil
        lastTime = -.infinity
        self.source = source
    }

    public func level(at time: Double) async -> StereoAudioLevel {
        guard time.isFinite, time >= 0, let source else { return .silence }
        do {
            if reader == nil || time < lastTime || time - lastTime > 0.5 {
                reader?.cancelReading()
                pending = nil
                let tracks = try await source.asset.loadTracks(withMediaType: .audio)
                guard !tracks.isEmpty else { return .silence }
                let next = try AVAssetReader(asset: source.asset)
                let audio = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ])
                audio.audioMix = source.mix
                audio.alwaysCopiesSampleData = false
                guard next.canAdd(audio) else { return .silence }
                next.add(audio)
                next.timeRange = CMTimeRange(start: CMTime(seconds: time, preferredTimescale: 48_000), duration: .positiveInfinity)
                guard next.startReading() else { return .silence }
                reader = next
                output = audio
            }
            lastTime = time
            var level = StereoAudioLevel.silence
            let end = time + 0.05
            while let buffer = pending ?? output?.copyNextSampleBuffer() {
                pending = nil
                let start = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
                let count = CMSampleBufferGetNumSamples(buffer)
                if start >= end { pending = buffer; break }
                guard let block = CMSampleBufferGetDataBuffer(buffer), count > 0 else { continue }
                let first = max(0, Int(((time - start) * 48_000).rounded(.up)))
                let last = min(count, Int(((end - start) * 48_000).rounded(.up)))
                if first < last {
                    var samples = [Float](repeating: 0, count: count * 2)
                    let status = samples.withUnsafeMutableBytes {
                        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                    }
                    if status == kCMBlockBufferNoErr {
                        for frame in first..<last {
                            level.left = max(level.left, abs(samples[frame * 2]))
                            level.right = max(level.right, abs(samples[frame * 2 + 1]))
                        }
                    }
                }
                if start + Double(count) / 48_000 > end { pending = buffer; break }
            }
            return level
        } catch {
            reader?.cancelReading()
            reader = nil
            output = nil
            return .silence
        }
    }
}
