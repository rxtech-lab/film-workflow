import AVFoundation
import Foundation
import MotionCore

/// Offline stereo mix of the `<Audio>`/`<Video>` voices MotionSwift evaluated for each
/// rendered frame, decoded and encoded with AVFoundation (MotionSwift's own `AudioMix`
/// shells out to ffmpeg, which the app does not ship). Sampling matches `AudioMix`:
/// source seconds = sample.time + offset × playbackRate, scaled by volume.
final class MotionSwiftAudioMix {
    private static let sampleRate = 48_000.0
    private let directory: URL
    private let fps: Double
    private var frames: [[ActiveMedia]] = []
    private var decoded: [String: Data] = [:]
    private var silent: Set<String> = []

    init(directory: URL, fps: Double) {
        self.directory = directory
        self.fps = fps
    }

    /// Records the voices active in the next output frame.
    func append(_ media: [ActiveMedia]) { frames.append(media.filter { $0.sample.volume > 0 }) }

    var isSilent: Bool { frames.allSatisfy(\.isEmpty) }

    /// Mixes the recorded voices into an AAC file, or returns nil when nothing is audible.
    func render(cancellation: CancellationFlag) throws -> URL? {
        guard !isSilent else { return nil }
        let rate = Self.sampleRate
        let output = directory.appendingPathComponent("mix.m4a")
        try? FileManager.default.removeItem(at: output)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false) else {
            throw MotionSwiftEngine.Failure("Cannot create the audio mix format")
        }
        let file = try AVAudioFile(forWriting: output, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        for (index, voices) in frames.enumerated() {
            try cancellation.check()
            let first = Int((Double(index) * rate / fps).rounded())
            let last = Int((Double(index + 1) * rate / fps).rounded())
            let count = last - first
            guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channels = buffer.floatChannelData else { continue }
            buffer.frameLength = AVAudioFrameCount(count)
            let left = channels[0], right = channels[1]
            left.initialize(repeating: 0, count: count)
            right.initialize(repeating: 0, count: count)
            for voice in voices {
                guard let source = try decode(voice.src) else { continue }
                source.withUnsafeBytes { bytes in
                    let samples = bytes.bindMemory(to: Float.self)
                    let available = samples.count / 2
                    let gain = Float(voice.sample.volume)
                    for offset in 0..<count {
                        let position = (voice.sample.time + Double(offset) / rate * voice.sample.playbackRate) * rate
                        guard position.isFinite, position >= 0, position < Double(available) else { continue }
                        let lower = Int(position)
                        let upper = min(lower + 1, available - 1)
                        let fraction = Float(position - Double(lower))
                        left[offset] += (samples[lower * 2] * (1 - fraction) + samples[upper * 2] * fraction) * gain
                        right[offset] += (samples[lower * 2 + 1] * (1 - fraction) + samples[upper * 2 + 1] * fraction) * gain
                    }
                }
            }
            for offset in 0..<count {
                left[offset] = min(1, max(-1, left[offset]))
                right[offset] = min(1, max(-1, right[offset]))
            }
            try file.write(from: buffer)
        }
        return output
    }

    /// Decodes a source's first audio track to interleaved 48 kHz stereo Float32 in a
    /// memory-mapped scratch file. Sources without audio are remembered as silent.
    private func decode(_ source: String) throws -> Data? {
        if let data = decoded[source] { return data }
        if silent.contains(source) { return nil }
        let url = try MediaSource.url(source)
        let asset = AVURLAsset(url: url)
        let tracks = try blocking { try await asset.loadTracks(withMediaType: .audio) }
        guard let track = tracks.first else { silent.insert(source); return nil }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { silent.insert(source); return nil }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MotionSwiftEngine.Failure("Cannot read audio from \(url.lastPathComponent)") }
        let scratch = directory.appendingPathComponent("audio-\(decoded.count + silent.count).f32")
        FileManager.default.createFile(atPath: scratch.path, contents: nil)
        let handle = try FileHandle(forWritingTo: scratch)
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var bytes = Data(count: length)
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            try handle.write(contentsOf: bytes)
        }
        try handle.close()
        guard reader.status == .completed else { throw reader.error ?? MotionSwiftEngine.Failure("Audio decoding failed") }
        let data = try Data(contentsOf: scratch, options: .alwaysMapped)
        decoded[source] = data
        return data
    }

    /// Replaces `video` with a copy carrying `audio`, without re-encoding the picture.
    static func mux(video: URL, audio: URL, duration: CMTime) throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: audio)
        let range = CMTimeRange(start: .zero, duration: duration)
        let (videoTrack, audioTrack) = try blocking {
            (try await videoAsset.loadTracks(withMediaType: .video).first,
             try await audioAsset.loadTracks(withMediaType: .audio).first)
        }
        guard let videoTrack,
              let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MotionSwiftEngine.Failure("The rendered picture has no video track")
        }
        try target.insertTimeRange(range, of: videoTrack, at: .zero)
        if let audioTrack, let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioDuration = try blocking { try await audioAsset.load(.duration) }
            try sound.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, audioDuration)), of: audioTrack, at: .zero)
        }
        let muxed = video.deletingLastPathComponent().appendingPathComponent("muxed-" + video.lastPathComponent)
        try? FileManager.default.removeItem(at: muxed)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw MotionSwiftEngine.Failure("Cannot mux the audio mix")
        }
        let type: AVFileType = video.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
        try blocking { try await session.export(to: muxed, as: type) }
        _ = try FileManager.default.replaceItemAt(video, withItemAt: muxed)
    }

    /// Waits for async AVFoundation loading from the synchronous render thread.
    private static func blocking<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        nonisolated(unsafe) var result: Result<T, Error>?
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try result!.get()
    }

    private func blocking<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        try Self.blocking(operation)
    }
}
