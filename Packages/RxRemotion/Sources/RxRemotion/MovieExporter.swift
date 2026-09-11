import AVFoundation
import CoreGraphics
import Foundation

extension RemotionEngine {
    public func renderMovie(project: RemotionPreparedProject, compositionID: String = "Main", to output: URL,
                            inputProps: [String: RemotionJSON] = [:], settings: RemotionRenderSettings = .init(),
                            onProgress: @escaping @MainActor (RemotionProgress) -> Void = { _ in }) async throws {
        if let count = settings.concurrency, !(1...4).contains(count) {
            throw RemotionError.rendering("Render concurrency must be between 1 and 4, or nil for automatic")
        }
        onProgress(.init(stage: .compiling))
        try await project.withFrozenCopy { frozen in
            try await self.renderFrozenMovie(project: frozen, compositionID: compositionID, to: output,
                                             inputProps: inputProps, settings: settings, onProgress: onProgress)
        }
    }

    private func renderFrozenMovie(project: RemotionPreparedProject, compositionID: String, to output: URL,
                                   inputProps: [String: RemotionJSON], settings: RemotionRenderSettings,
                                   onProgress: @escaping @MainActor (RemotionProgress) -> Void) async throws {
        let first = try await RemotionWebPage(project: project, mode: "render", compositionID: compositionID,
                                              inputProps: inputProps, settings: settings)
        var workers = [MovieFrameWorker(index: 0, page: first)]
        defer { workers.forEach { $0.page.dispose() } }
        guard let c = first.compositions.first, c.width > 0, c.height > 0, c.width <= 8192, c.height <= 8192,
              c.fps > 0, c.fps <= 240, c.durationInFrames > 0 else { throw RemotionError.rendering("Invalid render dimensions or timing") }
        let captured = settings.capturedComposition(c)
        if settings.codec == .h264, captured.width % 2 != 0 || captured.height % 2 != 0 {
            throw RemotionError.rendering("H.264 export requires even pixel dimensions")
        }
        let count = settings.workerCount(for: c)
        for index in 1..<count {
            let page = try await RemotionWebPage(project: project, mode: "render", compositionID: compositionID,
                                                inputProps: inputProps, settings: settings)
            guard page.compositions.first == c else {
                page.dispose(); throw RemotionError.rendering("Composition metadata differs between render workers")
            }
            workers.append(MovieFrameWorker(index: index, page: page))
        }
        let fm = FileManager.default
        try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let work = output.deletingLastPathComponent().appendingPathComponent(".rxremotion-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let silent = work.appendingPathComponent("picture.mov")
        do {
            let encoder = try await NativeVideoEncoder.make(output: silent, composition: captured, codec: settings.codec)
            do {
                var samples: [RemotionAudioSample] = []
                let preserveAlpha = settings.codec == .proRes4444
                try await withThrowingTaskGroup(of: MovieFrame.self) { group in
                    for worker in workers {
                        let frame = worker.index
                        group.addTask { try await worker.render(frame: frame, preserveAlpha: preserveAlpha) }
                    }
                    // At most one pending frame per worker. Do not schedule more until
                    // the next ordered frame has passed through the bounded encoder.
                    var ready: [Int: MovieFrame] = [:]
                    for frame in 0..<c.durationInFrames {
                        try Task.checkCancellation()
                        while ready[frame] == nil {
                            guard let result = try await group.next() else { throw RemotionError.rendering("A render worker stopped before completing its frames") }
                            ready[result.frame] = result
                        }
                        let result = ready.removeValue(forKey: frame)!
                        samples.append(contentsOf: result.audio)
                        try await encoder.append(result.image, frame: frame)
                        let next = frame + count
                        if next < c.durationInFrames {
                            let worker = workers[result.worker]
                            group.addTask { try await worker.render(frame: next, preserveAlpha: preserveAlpha) }
                        }
                        onProgress(.init(stage: .rendering, fraction: Double(frame + 1) / Double(c.durationInFrames),
                                         detail: "\(frame + 1) / \(c.durationInFrames)"))
                    }
                }
                try await encoder.finish()
                workers.forEach { $0.page.dispose() }
                onProgress(.init(stage: .encoding))
                var sources: [String: URL] = [:]
                for source in Set(samples.map(\.src)) { sources[source] = try project.media.resolve(source, base: project.baseURL) }
                let final = work.appendingPathComponent(settings.codec == .proRes4444 ? "final.mov" : "final.mp4")
                try await NativeAudioMuxer.mux(video: silent, samples: samples, sources: sources, composition: c,
                                               codec: settings.codec, output: final)
                try Task.checkCancellation()
                if fm.fileExists(atPath: output.path) { _ = try fm.replaceItemAt(output, withItemAt: final) }
                else { try fm.moveItem(at: final, to: output) }
                onProgress(.init(stage: .encoding, fraction: 1))
            } catch { await encoder.cancel(); throw error }
        } catch { await ProjectFiles.remove(work); throw error }
        await ProjectFiles.remove(work)
    }
}

private struct MovieFrame: Sendable {
    let frame: Int
    let worker: Int
    let image: CGImage
    let audio: [RemotionAudioSample]
}

@MainActor private final class MovieFrameWorker {
    let index: Int
    let page: RemotionWebPage
    private var previous = -1
    init(index: Int, page: RemotionWebPage) { self.index = index; self.page = page }
    func render(frame: Int, preserveAlpha: Bool) async throws -> MovieFrame {
        var audio: [RemotionAudioSample] = []
        // Replay intervening frames in every worker, preserving stateful canvases,
        // seeded randomness, effects and audio registration across worker boundaries.
        for position in (previous + 1)...frame {
            try Task.checkCancellation()
            audio = try await page.advance(to: position)
            previous = position
        }
        let image = try await page.capture(preserveAlpha: preserveAlpha)
        try Task.checkCancellation()
        return MovieFrame(frame: frame, worker: index, image: image, audio: audio)
    }
}

enum NativeAudioMuxer {
    struct Run {
        var samples: [RemotionAudioSample]
        var first: RemotionAudioSample { samples[0] }
        var last: RemotionAudioSample { samples[samples.count - 1] }
    }
    static func runs(_ samples: [RemotionAudioSample]) throws -> [Run] {
        var result: [Run] = []
        for group in Dictionary(grouping: samples, by: { $0.id }).values {
            for sample in group.sorted(by: { $0.frame < $1.frame }) {
                guard sample.playbackRate.isFinite, sample.playbackRate > 0, sample.volume.isFinite, sample.volume >= 0,
                      sample.toneFrequency == nil || sample.toneFrequency == 1 else {
                    throw RemotionError.unsupported("Audio requires a positive playback rate and finite gain; toneFrequency pitch shifts are not supported")
                }
                if let last = result.last, last.last.id == sample.id, last.last.src == sample.src,
                   last.last.frame + 1 == sample.frame, abs(last.last.mediaFrame + 1 - sample.mediaFrame) < 0.0001,
                   last.last.playbackRate == sample.playbackRate, last.last.audioStreamIndex == sample.audioStreamIndex {
                    result[result.count - 1].samples.append(sample)
                } else { result.append(Run(samples: [sample])) }
            }
        }
        return result.sorted {
            if $0.first.frame != $1.first.frame { return $0.first.frame < $1.first.frame }
            if $0.first.src != $1.first.src { return $0.first.src < $1.first.src }
            return $0.first.id < $1.first.id
        }
    }
    @concurrent static func mux(video: URL, samples: [RemotionAudioSample], sources: [String: URL],
                    composition: RemotionComposition, codec: RemotionRenderSettings.Codec, output: URL) async throws {
        let timeline = AVMutableComposition()
        let picture = AVURLAsset(url: video)
        guard let sourceVideo = try await picture.loadTracks(withMediaType: .video).first,
              let videoTrack = timeline.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RemotionError.rendering("Encoded video track is missing")
        }
        let duration = CMTime(seconds: composition.duration, preferredTimescale: 60000)
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceVideo, at: .zero)
        var audioTracks: [AVMutableCompositionTrack] = []
        var mixes: [AVMutableAudioMixInputParameters] = []
        var occupiedUntil: [Double] = []
        var assets: [URL: AVURLAsset] = [:]
        let allRuns = try runs(samples)
        for run in allRuns {
            try Task.checkCancellation()
            let sample = run.first
            guard let url = sources[sample.src] else { throw RemotionError.resource("Missing audio source") }
            let asset = assets[url] ?? AVURLAsset(url: url); assets[url] = asset
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            if tracks.isEmpty { continue }
            let stream = sample.audioStreamIndex ?? 0
            guard tracks.indices.contains(stream) else { throw RemotionError.rendering("Requested audio stream does not exist") }
            let source = tracks[stream]
            let trim = sample.audioStartFrame ?? 0
            let sourceStart = max(0, (trim + (sample.mediaFrame - trim) * sample.playbackRate) / composition.fps)
            let available = try await asset.load(.duration).seconds - sourceStart
            let targetDuration = min(Double(run.samples.count) / composition.fps, available / sample.playbackRate)
            guard targetDuration > 0 else { continue }
            let startSeconds = Double(sample.frame) / composition.fps
            let slot: Int
            if let reusable = occupiedUntil.firstIndex(where: { $0 <= startSeconds + 0.000001 }) { slot = reusable }
            else {
                guard let track = timeline.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw RemotionError.rendering("Cannot create audio track")
                }
                slot = audioTracks.count
                audioTracks.append(track)
                let mix = AVMutableAudioMixInputParameters(track: track)
                mix.audioTimePitchAlgorithm = .spectral
                mixes.append(mix); occupiedUntil.append(0)
            }
            let track = audioTracks[slot], mix = mixes[slot]
            let start = CMTime(seconds: startSeconds, preferredTimescale: 60000)
            let sourceDuration = CMTime(seconds: targetDuration * sample.playbackRate, preferredTimescale: 60000)
            try track.insertTimeRange(CMTimeRange(start: CMTime(seconds: sourceStart, preferredTimescale: 60000), duration: sourceDuration), of: source, at: start)
            track.scaleTimeRange(CMTimeRange(start: start, duration: sourceDuration), toDuration: CMTime(seconds: targetDuration, preferredTimescale: 60000))
            occupiedUntil[slot] = startSeconds + targetDuration
            for (index, item) in run.samples.enumerated() {
                let next = index + 1 < run.samples.count ? run.samples[index + 1].volume : item.volume
                let range = CMTimeRange(start: CMTime(seconds: Double(item.frame) / composition.fps, preferredTimescale: 60000),
                    duration: CMTime(seconds: 1 / composition.fps, preferredTimescale: 60000))
                mix.setVolumeRamp(fromStartVolume: Float(item.volume), toEndVolume: Float(next), timeRange: range)
            }
        }
        // Reuse tracks for nonoverlapping runs and pad their empty tail. This
        // keeps loops from allocating thousands of mixer tracks or ending the
        // mixed audio output before the requested movie duration.
        for (index, track) in audioTracks.enumerated() where occupiedUntil[index] < composition.duration {
            let end = CMTime(seconds: occupiedUntil[index], preferredTimescale: 60000)
            track.insertEmptyTimeRange(CMTimeRange(start: end, duration: duration - end))
        }
        let reader = try AVAssetReader(asset: timeline)
        reader.timeRange = CMTimeRange(start: .zero, duration: duration)
        let pictureOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        reader.add(pictureOutput)
        let writer = try AVAssetWriter(outputURL: output, fileType: codec == .proRes4444 ? .mov : .mp4)
        let format = try await sourceVideo.load(.formatDescriptions).first
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        writer.add(videoInput)
        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioInput: AVAssetWriterInput?
        if !audioTracks.isEmpty {
            let mix = AVMutableAudioMix(); mix.inputParameters = mixes
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false
            ])
            output.audioTimePitchAlgorithm = .spectral
            output.audioMix = mix; reader.add(output); audioOutput = output
            let settings: [String: Any] = codec == .proRes4444 ? [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ] : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            writer.add(input); audioInput = input
        }
        guard writer.startWriting(), reader.startReading() else { throw writer.error ?? reader.error ?? RemotionError.rendering("Could not start audio mux") }
        writer.startSession(atSourceTime: .zero)
        do {
            var videoDone = false, audioDone = audioInput == nil
            while !videoDone || !audioDone {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw writer.error ?? RemotionError.rendering("Mux encoder stopped") }
                var advanced = false
                if !videoDone, videoInput.isReadyForMoreMediaData {
                    if let sample = pictureOutput.copyNextSampleBuffer() {
                        guard videoInput.append(sample) else { throw writer.error ?? RemotionError.rendering("Video mux failed") }
                    } else { videoDone = true; videoInput.markAsFinished() }
                    advanced = true
                }
                if !audioDone, let audioInput, audioInput.isReadyForMoreMediaData {
                    if let sample = audioOutput?.copyNextSampleBuffer() {
                        guard audioInput.append(sample) else { throw writer.error ?? RemotionError.rendering("Audio mux failed") }
                    } else { audioDone = true; audioInput.markAsFinished() }
                    advanced = true
                }
                if !advanced { try await Task.sleep(for: .milliseconds(2)) }
            }
            guard reader.status != .failed else { throw reader.error ?? RemotionError.rendering("Audio decoding failed") }
            writer.endSession(atSourceTime: duration); await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? RemotionError.rendering("Mux failed") }
        } catch { reader.cancelReading(); writer.cancelWriting(); throw error }
    }

}
