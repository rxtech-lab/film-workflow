import Foundation
import SwiftData
import VideoEditorCore

/// Creates the captions for a narration and lays them over it on the timeline.
///
/// Nothing is transcribed here. The caption project is pointed at the
/// narration's audio and script and a clip for it is placed where the
/// narration plays, so the cues land in the right part of the film the moment
/// the user presses Transcribe — which stays their decision, since a
/// transcription run costs time and, for a hosted provider, money.
@MainActor
enum NarrativeCaptionClip {

    enum Failure: LocalizedError {
        case noAudio
        case missingFile(String)

        var errorDescription: String? {
            switch self {
            case .noAudio:
                return String(localized: "Generate this narration’s audio first.")
            case .missingFile(let path):
                return String(localized: "The narration audio file is missing: \(path)")
            }
        }
    }

    /// What the caption clip inherits: the narration's place on the timeline
    /// when it is there, otherwise the whole audio starting at a fallback.
    struct Placement: Equatable {
        var start: TimeInterval
        var duration: TimeInterval
        var inPoint: TimeInterval
    }

    /// The clip playing this narration, earliest first.
    ///
    /// A split narration leaves several clips; the first one carries the start
    /// of the audio, which is where the cues begin — the same rule
    /// `CaptionAudioAlignment` uses to align captions after the fact.
    static func narrationClip(for generated: GeneratedNarrative, in timeline: Timeline) -> Clip? {
        let sourceID = DocumentMediaResolver.sourceID(.narration, generated.id)
        return timeline.allClips
            .filter { $0.source.id == sourceID }
            .min { ($0.start, $0.inPoint) < ($1.start, $1.inPoint) }
    }

    /// Where the captions go. Following the narration clip's in point as well
    /// as its length keeps a trimmed narration's cues in step with the words.
    static func placement(
        for generated: GeneratedNarrative,
        in timeline: Timeline,
        audioDuration: TimeInterval,
        fallbackStart: TimeInterval
    ) -> Placement? {
        if let clip = narrationClip(for: generated, in: timeline) {
            return Placement(start: clip.start, duration: clip.duration, inPoint: clip.inPoint)
        }
        guard audioDuration > 0 else { return nil }
        return Placement(start: timeline.quantized(max(0, fallbackStart)), duration: audioDuration, inPoint: 0)
    }

    /// The narration's caption project plus the clip that shows it, creating
    /// either as needed. `clipID` is nil when there is no sequence to put it
    /// on; everything else throws.
    @discardableResult
    static func create(
        for generated: GeneratedNarrative,
        narrative: NarrativeProject,
        sequence: SequenceProject?,
        playhead: TimeInterval,
        context: ModelContext,
        undoManager: UndoManager?
    ) async throws -> (project: CaptionProject, clipID: UUID?) {
        guard !generated.audioFilePath.isEmpty else { throw Failure.noAudio }
        let audioURL = generated.audioURL
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw Failure.missingFile(generated.audioFilePath)
        }

        // Older narrations were recorded before lengths were stored, and the
        // caption clip is sized from this, so it is worth reading the file.
        var audioDuration = generated.durationSeconds
        if audioDuration <= 0, let measured = await MediaDurationCache.duration(of: audioURL) {
            generated.durationSeconds = measured
            audioDuration = measured
        }

        let project = try CaptionTranscriptionService.prepareNarrativeProject(
            for: generated, narrative: narrative, context: context
        )
        generated.captionProjectID = project.projectUUID
        // The viewer and the exporter resolve caption sources through a context
        // of their own, which reads the store. A project still pending in this
        // context would resolve as `.missing`, and the clip laid down below
        // would draw an error instead of its captions.
        try context.save()

        guard let sequence else { return (project, nil) }
        var timeline = sequence.timeline
        guard let placement = placement(for: generated, in: timeline, audioDuration: audioDuration, fallbackStart: playhead) else {
            return (project, nil)
        }
        let clipID = try insert(
            source: project.dragItem.source,
            style: project.captionStyle,
            placement: placement,
            sourceDuration: audioDuration > 0 ? audioDuration : nil,
            into: &timeline
        )
        sequence.editTimeline(timeline, undoManager: undoManager, actionName: String(localized: "Add Captions"))
        return (project, clipID)
    }

    /// Puts the captions on the first caption or overlay track with room at
    /// that time, adding a caption track when every one of them is busy.
    ///
    /// Captions already on the timeline are left exactly where the user put
    /// them: this action is about creating them, and "Align with Original
    /// Audio" is the item for moving them back onto their narration.
    static func insert(
        source: ClipSource,
        style: TextStyle,
        placement: Placement,
        sourceDuration: TimeInterval?,
        into timeline: inout Timeline
    ) throws -> UUID {
        if let existing = timeline.allClips.first(where: { $0.source.id == source.id }) {
            return existing.id
        }

        let clip = Clip(source: source, start: placement.start, duration: placement.duration,
                        inPoint: placement.inPoint, sourceDuration: sourceDuration,
                        text: style)
        for trackID in timeline.tracks.filter({ $0.kind.accepts(source.kind) }).map(\.id) {
            if (try? TimelineEditor.insert(&timeline, clip: clip, on: trackID)) != nil { return clip.id }
        }
        let trackID = TimelineEditor.addTrack(&timeline, kind: .caption)
        try TimelineEditor.insert(&timeline, clip: clip, on: trackID)
        return clip.id
    }
}
