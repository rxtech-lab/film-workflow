import AVFoundation
import CoreGraphics
import Foundation

/// `cancelExport` is documented as safe from any thread; the box only exists
/// to say so to the compiler.
private final class SessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

public enum TimelineExportError: Error, Sendable {
    case cannotCreateSession
    /// Video and audio were both turned off, or an audio-only export found no audio.
    case nothingToExport
    case failed(String)
    case cancelled
}

/// Writes a timeline to a movie or audio file through `AVAssetExportSession`.
@MainActor
public enum TimelineExporter {
    public enum VideoCodec: String, CaseIterable, Sendable, Codable {
        case h264
        case hevc

        public var displayName: String {
            switch self {
            case .h264: return "H.264"
            case .hevc: return "HEVC"
            }
        }

        var exportPreset: String {
            switch self {
            case .h264: return AVAssetExportPresetHighestQuality
            case .hevc: return AVAssetExportPresetHEVCHighestQuality
            }
        }
    }

    /// The codec picker's old name.
    public typealias Preset = VideoCodec

    public enum AudioCodec: String, CaseIterable, Sendable, Codable {
        case aac

        public var displayName: String {
            switch self {
            case .aac: return "AAC"
            }
        }
    }

    public enum Container: String, CaseIterable, Sendable, Codable {
        case mp4
        case mov
        case m4a

        public var displayName: String {
            switch self {
            case .mp4: return "MP4"
            case .mov: return "QuickTime Movie"
            case .m4a: return "M4A Audio"
            }
        }

        public var fileExtension: String { rawValue }

        public var fileType: AVFileType {
            switch self {
            case .mp4: return .mp4
            case .mov: return .mov
            case .m4a: return .m4a
            }
        }

        /// Whether the container carries a picture at all.
        public var holdsVideo: Bool { self != .m4a }

        /// Containers that can hold the given kind of export.
        public static func choices(audioOnly: Bool) -> [Container] {
            audioOnly ? [.m4a] : [.mp4, .mov]
        }
    }

    /// Output picture size. Presets name the longest edge so portrait and
    /// square timelines scale as expected; aspect ratio is always kept.
    public enum Resolution: String, CaseIterable, Sendable, Codable {
        case source
        case p480
        case p720
        case p1080
        case p1440
        case p2160

        public var displayName: String {
            switch self {
            case .source: return "Source"
            case .p480: return "480p"
            case .p720: return "720p"
            case .p1080: return "1080p"
            case .p1440: return "1440p"
            case .p2160: return "4K"
            }
        }

        public var longEdge: Int? {
            switch self {
            case .source: return nil
            case .p480: return 854
            case .p720: return 1280
            case .p1080: return 1920
            case .p1440: return 2560
            case .p2160: return 3840
            }
        }

        /// The output size for a timeline of `source` pixels: the longest edge
        /// becomes the preset's, both edges rounded to even numbers for the
        /// encoder. `source` and degenerate sizes pass through unchanged.
        public func size(for source: CGSize) -> CGSize {
            guard let edge = longEdge, source.width > 0, source.height > 0 else { return source }
            let scale = CGFloat(edge) / max(source.width, source.height)
            func even(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded() * 2) }
            return CGSize(width: even(source.width * scale), height: even(source.height * scale))
        }
    }

    /// What to write. `video == nil` exports audio only; `audio == nil` drops
    /// every audio track. `normalized` fixes the container to match.
    public struct Options: Equatable, Sendable, Codable {
        public var video: VideoCodec?
        public var audio: AudioCodec?
        public var resolution: Resolution
        public var container: Container

        public init(video: VideoCodec? = .h264, audio: AudioCodec? = .aac, resolution: Resolution = .source, container: Container = .mp4) {
            self.video = video
            self.audio = audio
            self.resolution = resolution
            self.container = container
        }

        public var isAudioOnly: Bool { video == nil }

        /// The same options with a container AVFoundation can actually write.
        public var normalized: Options {
            var copy = self
            let allowed = Container.choices(audioOnly: isAudioOnly)
            if !allowed.contains(copy.container) { copy.container = allowed[0] }
            return copy
        }

        public var fileExtension: String { normalized.container.fileExtension }

        var exportPreset: String {
            video?.exportPreset ?? AVAssetExportPresetAppleM4A
        }

        /// The picture size for a timeline of `source` pixels, or nil for audio-only.
        public func outputSize(for source: CGSize) -> CGSize? {
            isAudioOnly ? nil : resolution.size(for: source)
        }

        /// "H.264 + AAC · MP4", "HEVC · QuickTime Movie", "AAC · M4A Audio".
        public var summary: String {
            let codecs = [video?.displayName, audio?.displayName].compactMap { $0 }.joined(separator: " + ")
            return "\(codecs) · \(normalized.container.displayName)"
        }
    }

    /// Renders `timeline` to `url` with the default H.264 + AAC options.
    public static func export(
        _ timeline: Timeline,
        resolver: any MediaResolver,
        to url: URL,
        preset: VideoCodec,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await export(timeline, resolver: resolver, to: url, options: Options(video: preset), progress: progress)
    }

    /// Renders `timeline` to `url`, replacing any existing file. Cancelling the
    /// task cancels the export and removes the partial file.
    public static func export(
        _ timeline: Timeline,
        resolver: any MediaResolver,
        to url: URL,
        options: Options,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let options = options.normalized
        guard options.video != nil || options.audio != nil else { throw TimelineExportError.nothingToExport }

        let built = try await TimelineCompositionBuilder(resolver: resolver).build(timeline, allowPlaceholders: false, audioOnly: options.isAudioOnly)
        let composition = built.asset
        if options.audio == nil {
            for track in composition.tracks(withMediaType: .audio) { composition.removeTrack(track) }
        }
        if options.isAudioOnly {
            for track in composition.tracks(withMediaType: .video) { composition.removeTrack(track) }
            guard !composition.tracks(withMediaType: .audio).isEmpty else { throw TimelineExportError.nothingToExport }
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: options.exportPreset) else {
            throw TimelineExportError.cannotCreateSession
        }
        if let size = options.outputSize(for: timeline.size) {
            built.videoComposition.renderSize = size
            session.videoComposition = built.videoComposition
        }
        session.audioMix = options.audio == nil ? nil : built.audioMix
        session.shouldOptimizeForNetworkUse = true
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let progressTask = Task {
            for await state in session.states(updateInterval: 0.25) {
                if case .exporting(let p) = state {
                    progress(p.fractionCompleted)
                }
            }
        }
        defer { progressTask.cancel() }

        let box = SessionBox(session)
        let fileType = options.container.fileType
        do {
            try await withTaskCancellationHandler {
                try await box.session.export(to: url, as: fileType)
            } onCancel: {
                box.session.cancelExport()
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            if Task.isCancelled { throw TimelineExportError.cancelled }
            throw TimelineExportError.failed(error.localizedDescription)
        }
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: url)
            throw TimelineExportError.cancelled
        }
        progress(1)
    }
}
