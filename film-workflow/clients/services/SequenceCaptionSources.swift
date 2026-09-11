import Foundation
import SwiftData
import VideoEditorCore

/// The caption clips on a sequence's timeline, as the render needs them:
/// which projects and languages are involved, their cues on the timeline
/// clock for a subtitle track, and a merged transcript for sidecar files.
/// Timing goes through `Clip.timelineInterval`, the same shift burn-in uses.
@MainActor
enum SequenceCaptionSources {
    /// Overlay clips whose source is a caption project, in timeline order.
    static func captionClips(in sequence: SequenceProject, context: ModelContext) -> [(clip: Clip, project: CaptionProject)] {
        var projects: [UUID: CaptionProject] = [:]
        var result: [(clip: Clip, project: CaptionProject)] = []
        for track in sequence.timeline.tracks where track.kind == .overlay {
            for clip in track.sortedClips where clip.source.kind == .captions {
                guard let (prefix, id) = DocumentMediaResolver.parse(clip.source.id), prefix == .caption else { continue }
                if projects[id] == nil {
                    projects[id] = try? context.fetch(FetchDescriptor<CaptionProject>(predicate: #Predicate { $0.projectUUID == id })).first
                }
                if let project = projects[id] { result.append((clip, project)) }
            }
        }
        return result.sorted { $0.clip.start < $1.clip.start }
    }

    static func hasCaptions(in sequence: SequenceProject) -> Bool {
        sequence.timeline.allClips.contains { $0.source.kind == .captions }
    }

    /// The original first, then every translated language across the caption
    /// projects on the timeline, sorted.
    static func availableLanguages(in sequence: SequenceProject, context: ModelContext) -> [String] {
        var codes = Set<String>()
        for (_, project) in captionClips(in: sequence, context: context) {
            codes.formUnion(project.translatedLanguages)
        }
        return [""] + codes.sorted()
    }

    /// BCP-47 of the transcript itself, from the first caption project.
    static func sourceLanguage(in sequence: SequenceProject, context: ModelContext) -> String {
        captionClips(in: sequence, context: context).first?.project.sourceLanguageCode ?? ""
    }

    /// The style the render sheet edits and the subtitle track copies: the
    /// first caption clip's, since every caption clip usually shares one.
    static func effectiveStyle(in sequence: SequenceProject) -> TextStyle {
        for track in sequence.timeline.tracks where track.kind == .overlay {
            if let clip = track.sortedClips.first(where: { $0.source.kind == .captions }) { return clip.text ?? .caption }
        }
        return .caption
    }

    /// Cues per language on the timeline clock, across every caption clip.
    /// The original is tagged with the transcript's own language.
    static func captionTracks(in sequence: SequenceProject, document: ProjectDocument, languages: [String]) async throws -> [CaptionTrack] {
        let context = sequence.modelContext ?? document.container.mainContext
        let clips = captionClips(in: sequence, context: context)
        let source = clips.first?.project.sourceLanguageCode ?? ""
        var tracks: [CaptionTrack] = []
        for language in languages {
            let resolver = DocumentMediaResolver(document: document, width: sequence.width, height: sequence.height, fps: sequence.fps,
                                                 captionText: language.isEmpty ? .original : .translation(language))
            var cues: [TextCue] = []
            for (clip, _) in clips {
                guard case .captions(let sourceCues) = try await resolver.resolve(clip.source) else { continue }
                cues += clip.timelineCues(sourceCues)
            }
            cues.sort { $0.start < $1.start }
            tracks.append(CaptionTrack(languageCode: language.isEmpty ? source : language, cues: cues))
        }
        return tracks
    }

    /// One transcript per sequence for the sidecar exporter: every caption
    /// clip's segments shifted onto the timeline and clipped, in time order.
    /// Word timings are dropped (sentence cues never read them) and speakers
    /// are pooled. Nil when the timeline has no caption clips.
    static func sidecarSnapshot(in sequence: SequenceProject, context: ModelContext) -> CaptionTranscriptSnapshot? {
        let clips = captionClips(in: sequence, context: context)
        guard !clips.isEmpty else { return nil }
        var segments: [CaptionSegmentSnapshot] = []
        var speakers: [CaptionSpeaker] = []
        var languages: [String] = []
        for (clip, project) in clips {
            let snapshot = project.snapshot()
            let resolver = CaptionTermResolver(terms: project.usableTerms)
            for speaker in snapshot.speakers where !speakers.contains(where: { $0.id == speaker.id }) { speakers.append(speaker) }
            for code in snapshot.availableTranslations where !languages.contains(code) { languages.append(code) }
            for segment in snapshot.segments {
                guard let interval = clip.timelineInterval(sourceStart: Double(segment.startMs) / 1000, sourceEnd: Double(segment.endMs) / 1000) else { continue }
                segments.append(CaptionSegmentSnapshot(
                    id: segment.id,
                    startMs: Int((interval.start * 1000).rounded()),
                    endMs: Int((interval.end * 1000).rounded()),
                    text: resolver.render(segment.text, language: snapshot.sourceLanguage),
                    speakerId: segment.speakerId,
                    speakerLabel: segment.speakerLabel,
                    isEstimatedTiming: segment.isEstimatedTiming,
                    translations: segment.translations
                ))
            }
        }
        segments.sort { $0.startMs == $1.startMs ? $0.endMs < $1.endMs : $0.startMs < $1.startMs }
        return CaptionTranscriptSnapshot(
            projectName: sequence.name,
            audioDurationMs: Int((sequence.timeline.duration * 1000).rounded()),
            speakers: speakers,
            segments: segments,
            sourceLanguage: clips.first?.project.sourceLanguageCode ?? "",
            availableTranslations: languages
        )
    }

    /// `<movie stem>.<language>.<ext>`, so files for several languages sit
    /// beside one movie without colliding. The original is named with the
    /// transcript's language, or `original` when that is unknown.
    static func sidecarFilename(movieStem: String, languageCode: String, sourceLanguage: String, format: CaptionExportFormat) -> String {
        let code = languageCode.isEmpty ? (sourceLanguage.isEmpty ? "original" : sourceLanguage) : languageCode
        return "\(movieStem).\(CaptionExporter.sanitize(code)).\(format.fileExtension)"
    }
}
