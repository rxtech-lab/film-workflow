import AVFoundation
import CoreMedia
import Foundation

public enum SubtitleMuxError: Error, Sendable {
    case noVideoTrack
    case cannotStart(String)
    case writeFailed(String)
    case cancelled
}

/// Adds soft subtitle tracks to a finished movie.
///
/// `AVAssetExportSession` cannot write subtitle tracks, so the exporter's
/// output is read back with `AVAssetReader` (video and audio passed through
/// untouched) and rewritten with `AVAssetWriter`, which accepts 3GPP timed
/// text (`tx3g`) samples. One track per language, grouped as alternates so
/// players offer them in a Subtitles menu; the first is the default.
public enum SubtitleTrackMuxer {
    /// Writes `movie` plus `tracks` to `output`, replacing any file there.
    /// Cancelling the task removes the partial file. `duration` is the
    /// timeline length; every subtitle track spans exactly that.
    public static func mux(
        movie: URL,
        tracks: [CaptionTrack],
        style: TextStyle,
        frameSize: CGSize,
        duration: CMTime,
        fileType: AVFileType,
        to output: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let asset = AVURLAsset(url: movie)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw SubtitleMuxError.noVideoTrack }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let assetDuration = try await asset.load(.duration)
        let end = CMTimeMaximum(duration, assetDuration)

        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = true

        var passthrough: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput, isVideo: Bool)] = []
        for track in videoTracks + audioTracks {
            let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            trackOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(trackOutput) else { throw SubtitleMuxError.cannotStart("Cannot read track \(track.trackID)") }
            reader.add(trackOutput)
            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw SubtitleMuxError.cannotStart("Cannot copy track \(track.trackID)") }
            writer.add(input)
            passthrough.append((trackOutput, input, track.mediaType == .video))
        }

        let format = try SubtitleSampleFactory.formatDescription(style: style, frameSize: frameSize)
        var subtitles: [(input: AVAssetWriterInput, samples: [CMSampleBuffer])] = []
        for track in tracks {
            let plan = SubtitleSampleFactory.samplePlan(cues: track.cues, duration: end)
            guard !plan.isEmpty else { continue }
            let samples = try plan.map { try SubtitleSampleFactory.sample(text: $0.text, start: $0.start, duration: $0.duration, format: format) }
            let input = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            input.languageCode = SubtitleSampleFactory.iso639_2(track.languageCode) ?? "und"
            if !track.languageCode.isEmpty { input.extendedLanguageTag = track.languageCode }
            guard writer.canAdd(input) else { throw SubtitleMuxError.cannotStart("Cannot add a subtitle track to \(fileType.rawValue)") }
            writer.add(input)
            subtitles.append((input, samples))
        }
        if subtitles.count > 1 {
            let group = AVAssetWriterInputGroup(inputs: subtitles.map(\.input), defaultInput: subtitles[0].input)
            if writer.canAdd(group) { writer.add(group) }
        }

        guard writer.startWriting() else {
            throw SubtitleMuxError.cannotStart(writer.error?.localizedDescription ?? "Could not start writing")
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw SubtitleMuxError.cannotStart(reader.error?.localizedDescription ?? "Could not start reading")
        }
        writer.startSession(atSourceTime: .zero)

        var finished = Array(repeating: false, count: passthrough.count)
        var cursors = Array(repeating: 0, count: subtitles.count)
        let totalSeconds = max(CMTimeGetSeconds(end), 0.001)
        do {
            while finished.contains(false) || zip(cursors, subtitles).contains(where: { $0 < $1.samples.count }) {
                try Task.checkCancellation()
                guard writer.status == .writing else {
                    throw SubtitleMuxError.writeFailed(writer.error?.localizedDescription ?? "Writer stopped")
                }
                var advanced = false
                for i in passthrough.indices where !finished[i] && passthrough[i].input.isReadyForMoreMediaData {
                    if let sample = passthrough[i].output.copyNextSampleBuffer() {
                        guard passthrough[i].input.append(sample) else {
                            throw SubtitleMuxError.writeFailed(writer.error?.localizedDescription ?? "Could not copy media")
                        }
                        if passthrough[i].isVideo {
                            progress(min(1, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) / totalSeconds))
                        }
                    } else {
                        finished[i] = true
                        passthrough[i].input.markAsFinished()
                    }
                    advanced = true
                }
                for i in subtitles.indices where cursors[i] < subtitles[i].samples.count && subtitles[i].input.isReadyForMoreMediaData {
                    guard subtitles[i].input.append(subtitles[i].samples[cursors[i]]) else {
                        throw SubtitleMuxError.writeFailed(writer.error?.localizedDescription ?? "Could not write subtitles")
                    }
                    cursors[i] += 1
                    if cursors[i] == subtitles[i].samples.count { subtitles[i].input.markAsFinished() }
                    advanced = true
                }
                if !advanced { try await Task.sleep(for: .milliseconds(2)) }
            }
            guard reader.status != .failed else {
                throw SubtitleMuxError.writeFailed(reader.error?.localizedDescription ?? "Could not read the movie")
            }
            writer.endSession(atSourceTime: end)
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw SubtitleMuxError.writeFailed(writer.error?.localizedDescription ?? "Could not finish the movie")
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            if error is CancellationError { throw SubtitleMuxError.cancelled }
            throw error
        }
        progress(1)
    }
}

/// Builds the tx3g format description and samples. Kept separate from the
/// mux loop so the sample plan can be unit-tested without writing a movie.
enum SubtitleSampleFactory {
    static let timescale: CMTimeScale = 1000

    struct PlannedSample: Equatable {
        /// Nil is a gap: an empty sample that clears the previous text.
        var text: String?
        var start: CMTime
        var duration: CMTime
    }

    /// Continuous samples from 0 to `duration`: text where a cue plays, empty
    /// samples in the gaps and after the last cue. tx3g tracks must not have
    /// holes, or players keep the last text on screen.
    static func samplePlan(cues: [TextCue], duration: CMTime) -> [PlannedSample] {
        let total = CMTimeConvertScale(duration, timescale: timescale, method: .roundHalfAwayFromZero)
        guard total > .zero else { return [] }
        var plan: [PlannedSample] = []
        var cursor = CMTime(value: 0, timescale: timescale)
        for cue in cues.flattened() {
            let start = CMTimeMaximum(cursor, CMTime(seconds: cue.start, preferredTimescale: timescale))
            let end = CMTimeMinimum(total, CMTime(seconds: cue.end, preferredTimescale: timescale))
            guard end > start else { continue }
            if start > cursor { plan.append(PlannedSample(text: nil, start: cursor, duration: start - cursor)) }
            plan.append(PlannedSample(text: cue.text, start: start, duration: end - start))
            cursor = end
        }
        if cursor < total { plan.append(PlannedSample(text: nil, start: cursor, duration: total - cursor)) }
        return plan
    }

    /// ISO 639-2 for `AVAssetWriterInput.languageCode`; nil when unknown.
    static func iso639_2(_ bcp47: String) -> String? {
        let trimmed = bcp47.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Locale.Language(identifier: trimmed).languageCode?.identifier(.alpha3)
    }

    /// 3GPP timed text description carrying the style's font, size, weight,
    /// colours, alignment and vertical placement. Outline has no tx3g field.
    static func formatDescription(style: TextStyle, frameSize: CGSize) throws -> CMFormatDescription {
        let width = max(16, Int(frameSize.width.rounded()))
        let height = max(16, Int(frameSize.height.rounded()))
        let fontSize = max(8, min(255, Int((Double(height) * style.fontSize).rounded())))
        let boxHeight = min(height, Int((Double(fontSize) * 1.2 * 2.5 + Double(fontSize) * 0.7).rounded()))
        let top = Int((Double(height - boxHeight) * style.verticalPosition).rounded())
        let horizontal: Int
        switch style.alignment {
        case .leading: horizontal = -1
        case .center: horizontal = 0
        case .trailing: horizontal = 1
        }
        let vertical = style.verticalPosition < 0.33 ? -1 : (style.verticalPosition < 0.66 ? 0 : 1)
        var face = 0
        if style.bold { face |= 1 }
        if style.italic { face |= 2 }

        let extensions: [CFString: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags: 0,
            kCMTextFormatDescriptionExtension_HorizontalJustification: horizontal,
            kCMTextFormatDescriptionExtension_VerticalJustification: vertical,
            kCMTextFormatDescriptionExtension_BackgroundColor: color(style.backgroundHex, alpha: style.backgroundOpacity),
            kCMTextFormatDescriptionExtension_DefaultTextBox: [
                kCMTextFormatDescriptionRect_Top: top,
                kCMTextFormatDescriptionRect_Left: 0,
                kCMTextFormatDescriptionRect_Bottom: top + boxHeight,
                kCMTextFormatDescriptionRect_Right: width,
            ] as [CFString: Any],
            kCMTextFormatDescriptionExtension_DefaultStyle: [
                kCMTextFormatDescriptionStyle_StartChar: 0,
                kCMTextFormatDescriptionStyle_EndChar: 0,
                kCMTextFormatDescriptionStyle_Font: 1,
                kCMTextFormatDescriptionStyle_FontFace: face,
                kCMTextFormatDescriptionStyle_FontSize: fontSize,
                kCMTextFormatDescriptionStyle_ForegroundColor: color(style.colorHex, alpha: 1),
            ] as [CFString: Any],
            kCMTextFormatDescriptionExtension_FontTable: ["1": style.fontName] as [String: String],
        ]
        var description: CMFormatDescription?
        let status = CMFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            mediaType: kCMMediaType_Subtitle,
            mediaSubType: kCMSubtitleFormatType_3GText,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw SubtitleMuxError.cannotStart("Could not describe the subtitle track (\(status))")
        }
        return description
    }

    /// A tx3g sample: big-endian UInt16 byte length followed by UTF-8 text.
    /// Nil text is the two-byte empty sample.
    static func sample(text: String?, start: CMTime, duration: CMTime, format: CMFormatDescription) throws -> CMSampleBuffer {
        let payload = payloadBytes(text)
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: payload.count, flags: 0, blockBufferOut: &block
        )
        guard status == kCMBlockBufferNoErr, let block else { throw SubtitleMuxError.writeFailed("Could not allocate a subtitle sample (\(status))") }
        status = CMBlockBufferAssureBlockMemory(block)
        guard status == kCMBlockBufferNoErr else { throw SubtitleMuxError.writeFailed("Could not allocate a subtitle sample (\(status))") }
        status = payload.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count)
        }
        guard status == kCMBlockBufferNoErr else { throw SubtitleMuxError.writeFailed("Could not fill a subtitle sample (\(status))") }

        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: start, decodeTimeStamp: .invalid)
        var size = payload.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { throw SubtitleMuxError.writeFailed("Could not create a subtitle sample (\(status))") }
        return sample
    }

    static func payloadBytes(_ text: String?) -> [UInt8] {
        let utf8 = Array((text ?? "").utf8.prefix(Int(UInt16.max)))
        let length = UInt16(utf8.count)
        return [UInt8(length >> 8), UInt8(length & 0xFF)] + utf8
    }

    private static func color(_ hex: String, alpha: Double) -> [CFString: Any] {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        let value = (s.count == 6 || s.count == 8) ? UInt64(s, radix: 16) ?? 0 : 0
        let shift: UInt64 = s.count == 8 ? 8 : 0
        let r = Int((value >> (16 + shift)) & 0xFF)
        let g = Int((value >> (8 + shift)) & 0xFF)
        let b = Int((value >> shift) & 0xFF)
        return [
            kCMTextFormatDescriptionColor_Red: r,
            kCMTextFormatDescriptionColor_Green: g,
            kCMTextFormatDescriptionColor_Blue: b,
            kCMTextFormatDescriptionColor_Alpha: Int((max(0, min(1, alpha)) * 255).rounded()),
        ]
    }
}
