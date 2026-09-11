import Foundation
import SwiftData
import VideoEditorCore
import VideoEditorUI

/// Offers "Align with Original Audio" on caption clips: the item appears for
/// any caption project that has audio, and enables while a clip playing that
/// same audio (a narration, a music take or an imported asset) is on the
/// timeline.
enum CaptionAudioAlignment {
    /// `originSourceIDs` maps a caption project's UUID to the clip source ids
    /// that play the audio it was transcribed from. Nil means the project is
    /// unknown or has no audio, so no item is offered; an empty set shows the
    /// item disabled.
    static func alignment(
        for clip: Clip,
        in timeline: Timeline,
        originSourceIDs: (UUID) -> Set<String>?
    ) -> ClipAlignment? {
        guard clip.source.kind == .captions,
              let (prefix, projectUUID) = DocumentMediaResolver.parse(clip.source.id), prefix == .caption,
              let origins = originSourceIDs(projectUUID) else { return nil }
        // A split origin leaves several clips; the earliest carries the start
        // of the audio, which is where the cues begin.
        let target = timeline.allClips
            .filter { origins.contains($0.source.id) }
            .min { ($0.start, $0.inPoint) < ($1.start, $1.inPoint) }
        return ClipAlignment(title: String(localized: "Align with Original Audio"), targetClipID: target?.id)
    }

    @MainActor
    static func alignment(for clip: Clip, in timeline: Timeline, context: ModelContext) -> ClipAlignment? {
        alignment(for: clip, in: timeline) { projectUUID in
            let rows = try? context.fetch(FetchDescriptor<CaptionProject>(predicate: #Predicate { $0.projectUUID == projectUUID }))
            guard let project = rows?.first, project.hasAudio else { return nil }
            return originSourceIDs(for: project, context: context)
        }
    }

    /// Every footage row whose file is the caption's audio. The path match
    /// covers narrations, music and library assets alike; the two narrative
    /// links are kept for projects whose path no longer matches (the
    /// `sourceNarrativeID` is the UUID in the audio filename, not the row id).
    @MainActor
    static func originSourceIDs(for project: CaptionProject, context: ModelContext) -> Set<String> {
        var ids = Set<String>()
        let path = project.audioFilePath
        let projectUUID = project.projectUUID

        let narrations = (try? context.fetch(FetchDescriptor<GeneratedNarrative>(
            predicate: #Predicate { $0.audioFilePath == path || $0.captionProjectID == projectUUID }))) ?? []
        for row in narrations { ids.insert(DocumentMediaResolver.sourceID(.narration, row.id)) }
        if let audioID = project.sourceNarrativeID {
            let fragment = audioID.uuidString
            let byName = (try? context.fetch(FetchDescriptor<GeneratedNarrative>(
                predicate: #Predicate { $0.audioFilePath.contains(fragment) }))) ?? []
            for row in byName where row.captionSourceID == audioID { ids.insert(DocumentMediaResolver.sourceID(.narration, row.id)) }
        }

        let music = (try? context.fetch(FetchDescriptor<GeneratedMusic>(predicate: #Predicate { $0.audioFilePath == path }))) ?? []
        for row in music { ids.insert(DocumentMediaResolver.sourceID(.music, row.id)) }

        let assets = (try? context.fetch(FetchDescriptor<ImportedAsset>(predicate: #Predicate { $0.relativePath == path }))) ?? []
        for row in assets { ids.insert(DocumentMediaResolver.sourceID(.imported, row.id)) }
        return ids
    }
}
