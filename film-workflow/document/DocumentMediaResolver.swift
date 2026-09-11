import AVFoundation
import AppKit
import Foundation
import SwiftData
import VideoEditorCore

/// Which text a caption clip shows: the transcript, one translation, or both.
/// Chosen per render; the preview and the timeline always show the original.
nonisolated enum CaptionTextSelection: Sendable, Hashable {
    case original
    /// The translation, falling back to the original for captions without one.
    case translation(String)
    /// Original on the first line, translation underneath.
    case bilingual(String)

    /// BCP-47 of the translation involved; empty for the original.
    var languageCode: String {
        switch self {
        case .original: return ""
        case .translation(let code), .bilingual(let code): return code
        }
    }

    /// The cue text for one caption, given its rendered original and its
    /// rendered translations.
    func text(original: String, translations: [String: String]) -> String {
        switch self {
        case .original:
            return original
        case .translation(let code):
            return translations[code].flatMap { $0.isEmpty ? nil : $0 } ?? original
        case .bilingual(let code):
            guard let translated = translations[code], !translated.isEmpty else { return original }
            return original + "\n" + translated
        }
    }
}

/// Maps timeline source ids to files inside a film.
///
/// Id grammar: `<kind>:<uuid>` where kind is `music`, `narration`, `image`,
/// `video`, `remotion`, `imported` or `caption`. Remotion resolves to the
/// newest render whose hash matches the project's current source; without
/// one it reports `.unrendered` so the preview draws a slate and the exporter
/// refuses to run until `SequenceRenderService` has rendered it.
struct DocumentMediaResolver: MediaResolver {
    let container: ModelContainer
    let storage: ProjectStorage
    /// The sequence size a Remotion render must match to count as current.
    var renderWidth: Int
    var renderHeight: Int
    var renderFps: Int
    /// What caption clips resolve to. Glossary placeholders are resolved
    /// either way, so a burned-in caption reads like an exported one.
    var captionText: CaptionTextSelection

    init(document: ProjectDocument, width: Int, height: Int, fps: Int, captionText: CaptionTextSelection = .original) {
        self.container = document.container
        self.storage = document.storage
        self.renderWidth = width
        self.renderHeight = height
        self.renderFps = fps
        self.captionText = captionText
    }

    enum SourceKindPrefix: String {
        case music, narration, image, video, remotion, imported, caption
    }

    static func sourceID(_ prefix: SourceKindPrefix, _ id: UUID) -> String {
        "\(prefix.rawValue):\(id.uuidString)"
    }

    static func parse(_ id: String) -> (SourceKindPrefix, UUID)? {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let prefix = SourceKindPrefix(rawValue: parts[0]), let uuid = UUID(uuidString: parts[1]) else { return nil }
        return (prefix, uuid)
    }

    func resolve(_ source: ClipSource) async throws -> ResolvedMedia {
        try await MainActor.run { try resolveOnMain(source) }
    }

    @MainActor
    private func resolveOnMain(_ source: ClipSource) throws -> ResolvedMedia {
        guard let (prefix, uuid) = Self.parse(source.id) else { throw MediaResolverError.missing(source) }
        let context = ModelContext(container)
        switch prefix {
        case .music:
            let rows = try context.fetch(FetchDescriptor<GeneratedMusic>(predicate: #Predicate { $0.id == uuid }))
            guard let row = rows.first else { throw MediaResolverError.missing(source) }
            return try fileMedia(storage.absoluteURL(for: row.audioFilePath), source: source)
        case .narration:
            let rows = try context.fetch(FetchDescriptor<GeneratedNarrative>(predicate: #Predicate { $0.id == uuid }))
            guard let row = rows.first else { throw MediaResolverError.missing(source) }
            return try fileMedia(storage.absoluteURL(for: row.audioFilePath), source: source)
        case .image:
            let rows = try context.fetch(FetchDescriptor<GeneratedImage>(predicate: #Predicate { $0.id == uuid }))
            guard let row = rows.first else { throw MediaResolverError.missing(source) }
            return try fileMedia(storage.absoluteURL(for: row.imageFilePath), source: source, duration: nil)
        case .video:
            let rows = try context.fetch(FetchDescriptor<GeneratedVideo>(predicate: #Predicate { $0.id == uuid }))
            guard let row = rows.first else { throw MediaResolverError.missing(source) }
            return .file(storage.absoluteURL(for: row.videoFilePath), naturalDuration: row.durationSeconds > 0 ? row.durationSeconds : nil, naturalSize: CGSize(width: row.width, height: row.height))
        case .remotion:
            let projects = try context.fetch(FetchDescriptor<RemotionProject>(predicate: #Predicate { $0.id == uuid }))
            guard let project = projects.first else { throw MediaResolverError.missing(source) }
            guard let render = RemotionRenderService.cachedRender(project: project, width: renderWidth, height: renderHeight, fps: project.compositionFps, context: context, preserveAlpha: true) else {
                throw MediaResolverError.unrendered(source)
            }
            return .file(storage.absoluteURL(for: render.filePath), naturalDuration: render.durationSeconds, naturalSize: CGSize(width: render.width, height: render.height))
        case .imported:
            let rows = try context.fetch(FetchDescriptor<ImportedAsset>(predicate: #Predicate { $0.id == uuid }))
            guard let row = rows.first, let url = row.resolveURL() else { throw MediaResolverError.missing(source) }
            if row.kindEnum == .image { return .file(url, naturalDuration: nil, naturalSize: nil) }
            return .file(url, naturalDuration: row.durationSeconds > 0 ? row.durationSeconds : nil, naturalSize: row.width > 0 ? CGSize(width: row.width, height: row.height) : nil)
        case .caption:
            let rows = try context.fetch(FetchDescriptor<CaptionProject>(predicate: #Predicate { $0.projectUUID == uuid }))
            guard let project = rows.first else { throw MediaResolverError.missing(source) }
            return .captions(Self.cues(for: project, text: captionText))
        }
    }

    /// A caption project's active transcript as cues on its own clock, in the
    /// chosen language with `{{term}}` placeholders rendered.
    @MainActor
    static func cues(for project: CaptionProject, text selection: CaptionTextSelection) -> [TextCue] {
        let snapshot = project.snapshot()
        let resolver = CaptionTermResolver(terms: project.usableTerms)
        return snapshot.segments.compactMap { segment in
            let original = resolver.render(segment.text, language: snapshot.sourceLanguage)
            let text = selection.text(original: original, translations: segment.translations)
            guard !text.isEmpty, segment.endMs > segment.startMs else { return nil }
            return TextCue(start: Double(segment.startMs) / 1000, end: Double(segment.endMs) / 1000, text: text)
        }
    }

    private func fileMedia(_ url: URL, source: ClipSource, duration: TimeInterval? = -1) throws -> ResolvedMedia {
        guard FileManager.default.fileExists(atPath: url.path) else { throw MediaResolverError.missing(source) }
        if duration == nil {
            return .file(url, naturalDuration: nil, naturalSize: nil)
        }
        // Audio duration is not stored on the row; ask the file.
        let seconds = CMTimeGetSeconds(AVURLAsset(url: url).duration)
        return .file(url, naturalDuration: seconds.isFinite && seconds > 0 ? seconds : nil, naturalSize: nil)
    }

    func thumbnail(for source: ClipSource, at time: TimeInterval) async -> CGImage? {
        guard let media = try? await resolve(source), let url = media.fileURL else { return nil }
        switch source.kind {
        case .image:
            return NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        case .video, .remotion:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            return try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        default:
            return nil
        }
    }
}
