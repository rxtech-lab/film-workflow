import Foundation
import SwiftData
import VideoEditorCore

/// The audio already in a film that captions can be made from: generated music
/// takes and imported audio files.
///
/// Narrations are deliberately absent. They carry the author's script, so they
/// go through ``CaptionTranscriptionService/prepareNarrativeProject(for:narrative:context:)``,
/// which aligns known text rather than transcribing what it hears.
///
/// One recording has one caption project, whether its text was transcribed here
/// or typed in the lyrics editor — both sides use `CaptionProject.lyricsSourceID`
/// as the link, so neither can leave a second project behind.
@MainActor
enum CaptionAudioSource {

    /// One choice in the audio menus, named the way the timeline names it.
    struct Entry: Identifiable, Hashable {
        let id: String
        let title: String
        let systemImage: String
    }

    /// What a source id points at, resolved to everything a caption project
    /// needs from it.
    struct Resolved {
        let url: URL
        let title: String
        /// Recorded when the audio was made or imported; 0 when only the file
        /// knows, which is what `duration(of:)` is for.
        let knownDuration: Double
        let groupID: UUID?
    }

    enum Failure: LocalizedError {
        case missingAudio

        var errorDescription: String? {
            String(localized: "That audio is unavailable. Restore or import the file, then try again.")
        }
    }

    /// Every recording in the film, music first, in the order the library
    /// lists them.
    static func entries(music: [GeneratedMusic], imported: [ImportedAsset]) -> [Entry] {
        let takes = music.sorted { $0.createdAt < $1.createdAt }
        return takes.map { take in
            Entry(id: DocumentMediaResolver.sourceID(.music, take.id),
                  title: takeTitle(take, among: takes.filter { $0.project?.id == take.project?.id }),
                  systemImage: "music.note")
        } + imported.filter { $0.kind == ImportedAssetKind.audio.rawValue }.map {
            Entry(id: DocumentMediaResolver.sourceID(.imported, $0.id), title: $0.name, systemImage: "waveform")
        }
    }

    static func resolve(_ sourceID: String, context: ModelContext) -> Resolved? {
        guard let (prefix, id) = DocumentMediaResolver.parse(sourceID) else { return nil }
        switch prefix {
        case .music:
            guard let take = try? context.fetch(
                FetchDescriptor<GeneratedMusic>(predicate: #Predicate { $0.id == id })
            ).first else { return nil }
            let siblings = take.project?.generatedFiles.sorted { $0.createdAt < $1.createdAt } ?? [take]
            return Resolved(url: take.audioURL, title: takeTitle(take, among: siblings),
                            knownDuration: take.durationSeconds, groupID: take.project?.groupID)
        case .imported:
            guard let asset = try? context.fetch(
                FetchDescriptor<ImportedAsset>(predicate: #Predicate { $0.id == id })
            ).first, asset.kind == ImportedAssetKind.audio.rawValue, let url = asset.resolveURL()
            else { return nil }
            return Resolved(url: url, title: asset.name, knownDuration: asset.durationSeconds, groupID: asset.groupID)
        case .screenRecording:
            guard let (take, component) = try? RecordingTimelineService.resolve(id: id, context: context), component.sourceKind == .audio else { return nil }
            return Resolved(url: ProjectStorage.forContainer(context.container).absoluteURL(for: component.filePath), title: component.name, knownDuration: component.duration, groupID: take.project?.groupID)
        case .narration, .image, .video, .remotion, .caption, .recordingZoom:
            return nil
        }
    }

    /// The name this audio goes by wherever it is offered, resolved from the
    /// store. Nil for audio that is no longer in the film.
    static func title(of sourceID: String, context: ModelContext) -> String? {
        resolve(sourceID, context: context)?.title
    }

    /// The caption project for this recording, creating one when it has none.
    /// **Nothing is transcribed** — that costs time and, for a hosted provider,
    /// money, so it stays the user's decision in the inspector.
    @discardableResult
    static func prepareProject(for sourceID: String, context: ModelContext) async throws -> CaptionProject {
        if let existing = try existingProject(for: sourceID, context: context) { return existing }
        guard let resolved = resolve(sourceID, context: context),
              FileManager.default.fileExists(atPath: resolved.url.path)
        else { throw Failure.missingAudio }

        let duration = await duration(of: resolved)
        // Awaiting media metadata can let a second menu action finish first.
        if let existing = try existingProject(for: sourceID, context: context) { return existing }

        let project = CaptionProject(name: String(localized: "\(resolved.title) captions"))
        project.groupID = resolved.groupID
        context.insert(project)
        try point(project, at: sourceID, resolved: resolved, seconds: duration, context: context)
        try context.save()
        return project
    }

    /// Repoints an existing caption project at one of the film's recordings,
    /// replacing whatever source it had.
    static func attach(_ sourceID: String, to project: CaptionProject, context: ModelContext) async throws {
        guard let resolved = resolve(sourceID, context: context),
              FileManager.default.fileExists(atPath: resolved.url.path)
        else { throw Failure.missingAudio }
        let duration = await duration(of: resolved)
        try point(project, at: sourceID, resolved: resolved, seconds: duration, context: context)
        try context.save()
    }

    static func existingProject(for sourceID: String, context: ModelContext) throws -> CaptionProject? {
        try context.fetch(
            FetchDescriptor<CaptionProject>(predicate: #Predicate { $0.lyricsSourceID == sourceID })
        ).first
    }

    // MARK: - Internals

    /// Music takes carry no version number of their own; they are numbered by
    /// age within their project, the way the library labels them.
    private static func takeTitle(_ take: GeneratedMusic, among siblings: [GeneratedMusic]) -> String {
        let version = (siblings.firstIndex { $0.id == take.id } ?? 0) + 1
        return "\(take.project?.name ?? String(localized: "Music")) · v\(version)"
    }

    private static func duration(of resolved: Resolved) async -> Double {
        resolved.knownDuration > 0 ? resolved.knownDuration : (await MediaDurationCache.duration(of: resolved.url) ?? 0)
    }

    /// Writes the source onto the project. Not async, so the checks above and
    /// the write below can't be separated by an await.
    private static func point(
        _ project: CaptionProject,
        at sourceID: String,
        resolved: Resolved,
        seconds: Double,
        context: ModelContext
    ) throws {
        let storage = ProjectStorage.forContainer(context.container)
        // Referenced in place when the file already lives in the package — a
        // music take does — and copied in only when it doesn't, which is the
        // case for audio the user referenced rather than imported.
        let relative = storage.relativePath(for: resolved.url)
        // Audio this project imported for an earlier source is its own, and
        // dropping it keeps copies from piling up in the package.
        if project.ownsAudioFile, !project.audioFilePath.isEmpty, project.audioFilePath != relative {
            storage.deleteFile(at: project.audioFilePath)
        }

        project.audioFilePath = try relative ?? storage.importAudio(from: resolved.url)
        project.ownsAudioFile = relative == nil
        project.audioDurationMs = seconds > 0 ? Int((seconds * 1000).rounded()) : 0

        // One recording, one caption project: where another already claims this
        // audio, this project simply plays it without taking the link.
        let claimed = try existingProject(for: sourceID, context: context)
        project.lyricsSourceID = (claimed == nil || claimed === project) ? sourceID : nil

        project.sourceKindEnum = .importedFile
        project.sourceNarrativeID = nil
        project.sourceNarrativeName = ""
        project.referenceUnits = []
        project.alignmentQualityEnum = .none
        project.alignmentMatchRatio = 0
        if project.name == "Untitled Captions" {
            project.name = String(localized: "\(resolved.title) captions")
        }
        project.updatedAt = Date()
    }
}
