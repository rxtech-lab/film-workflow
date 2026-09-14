import Foundation
import SwiftData
import Testing
import VideoEditorCore

@testable import film_workflow

@Suite("Captions created from a narration")
@MainActor
struct NarrativeCaptionClipTests {

    private func narration(_ context: ModelContext, duration: Double = 12) -> GeneratedNarrative {
        let project = NarrativeProject(name: "Story")
        context.insert(project)
        let file = GeneratedNarrative(audioFilePath: "generated/\(UUID().uuidString).m4a", transcriptText: "Hi", project: project)
        file.durationSeconds = duration
        context.insert(file)
        return file
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: CaptionProject.self, GeneratedNarrative.self, NarrativeProject.self,
                           GeneratedMusic.self, MusicProject.self, ImportedAsset.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func narrationClip(_ generated: GeneratedNarrative, start: TimeInterval, duration: TimeInterval, inPoint: TimeInterval = 0) -> Clip {
        Clip(source: ClipSource(id: DocumentMediaResolver.sourceID(.narration, generated.id), kind: .audio, displayName: "Narration"),
             start: start, duration: duration, inPoint: inPoint)
    }

    private func captionSource() -> ClipSource {
        ClipSource(id: DocumentMediaResolver.sourceID(.caption, UUID()), kind: .captions, displayName: "Captions")
    }

    @Test("The captions take the narration's place, and the playhead only when it isn't on the timeline")
    func placementFollowsTheNarration() throws {
        // The container has to outlive its context; a temporary one takes
        // `mainContext` down with it.
        let container = try container()
        let generated = narration(container.mainContext, duration: 12)
        var timeline = Timeline(width: 1920, height: 1080, fps: 30)
        let audio = try #require(timeline.tracks.first { $0.kind == .audio }?.id)

        // Nothing placed: the whole take starts at the playhead.
        let fallback = try #require(NarrativeCaptionClip.placement(for: generated, in: timeline, audioDuration: 12, fallbackStart: 4))
        #expect(fallback == NarrativeCaptionClip.Placement(start: 4, duration: 12, inPoint: 0))

        // A trimmed narration hands over its in point too, so the cues stay in
        // step with the words that are actually heard.
        let later = narrationClip(generated, start: 30, duration: 5)
        let earlier = narrationClip(generated, start: 10, duration: 6, inPoint: 2)
        try TimelineEditor.insert(&timeline, clip: later, on: audio)
        try TimelineEditor.insert(&timeline, clip: earlier, on: audio)
        let placed = try #require(NarrativeCaptionClip.placement(for: generated, in: timeline, audioDuration: 12, fallbackStart: 4))
        #expect(placed == NarrativeCaptionClip.Placement(start: 10, duration: 6, inPoint: 2))
        #expect(NarrativeCaptionClip.narrationClip(for: generated, in: timeline)?.id == earlier.id)

        // Another narration's clips are not this narration's.
        let other = narration(container.mainContext)
        #expect(NarrativeCaptionClip.narrationClip(for: other, in: timeline) == nil)
        #expect(NarrativeCaptionClip.placement(for: other, in: timeline, audioDuration: 0, fallbackStart: 4) == nil)
    }

    @Test("Captions land on a free caption track, and a new one when every track is busy")
    func insertionFindsRoom() throws {
        var timeline = Timeline(width: 1920, height: 1080, fps: 30)
        let lane = try #require(timeline.tracks.first { $0.kind == .caption }?.id)
        let placement = NarrativeCaptionClip.Placement(start: 10, duration: 6, inPoint: 2)

        let first = try NarrativeCaptionClip.insert(source: captionSource(), style: .caption, placement: placement,
                                                    sourceDuration: 12, into: &timeline)
        let clip = try #require(timeline.clip(id: first))
        #expect(timeline.track(containing: first)?.id == lane)
        #expect(clip.start == 10)
        #expect(clip.duration == 6)
        #expect(clip.inPoint == 2)
        #expect(clip.sourceDuration == 12)
        // The style comes along so the clip draws the way the Style tab says.
        #expect(clip.text == .caption)

        // A second caption project at the same time gets a caption lane of its
        // own, above the one the first took.
        let second = try NarrativeCaptionClip.insert(source: captionSource(), style: .caption, placement: placement,
                                                     sourceDuration: 12, into: &timeline)
        let added = try #require(timeline.track(containing: second))
        #expect(added.id != lane)
        #expect(added.kind == .caption)
        #expect(timeline.tracks.map(\.name) == ["C2", "C1", "V1", "A1", "A2"])

        // A third one takes the first lane with room at its own time rather
        // than stacking up another.
        let later = NarrativeCaptionClip.Placement(start: 30, duration: 6, inPoint: 0)
        let third = try NarrativeCaptionClip.insert(source: captionSource(), style: .caption, placement: later,
                                                    sourceDuration: 12, into: &timeline)
        #expect(timeline.track(containing: third)?.id == added.id)
        #expect(timeline.tracks.filter { $0.kind == .caption }.count == 2)
    }

    @Test("A caption project created for a narration is readable by the viewer's own context")
    func createdProjectIsSavedBeforeItsClipIsPreviewed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NarrativeCaptions-\(UUID().uuidString)")
        let document = try ProjectDocument.create(at: root.appendingPathComponent("Test.rxfilmstudio"))
        defer { Task { @MainActor in await document.close() }; try? FileManager.default.removeItem(at: root) }
        let context = document.container.mainContext

        let narrative = NarrativeProject(name: "Story")
        narrative.paragraphs = [NarrativeParagraph(speakerId: narrative.speakers[0].id, emotion: "", content: "Hello there.")]
        context.insert(narrative)
        // The audio only has to exist; its length is already on the record.
        let path = "\(ProjectStorage.MediaKind.narration.rawValue)/\(UUID().uuidString).m4a"
        try Data().write(to: document.storage.absoluteURL(for: path))
        let generated = GeneratedNarrative(audioFilePath: path, transcriptText: "Hello there.", project: narrative)
        generated.durationSeconds = 6
        context.insert(generated)

        let sequence = SequenceProject(name: "Cut")
        var timeline = Timeline(width: 320, height: 180, fps: 30)
        let audio = try #require(timeline.tracks.first { $0.kind == .audio })
        try TimelineEditor.insert(&timeline, clip: narrationClip(generated, start: 0, duration: 6), on: audio.id)
        sequence.timeline = timeline
        context.insert(sequence)
        try context.save()

        let result = try await NarrativeCaptionClip.create(for: generated, narrative: narrative, sequence: sequence,
                                                           playhead: 0, context: context, undoManager: nil)
        let clipID = try #require(result.clipID)
        let clip = try #require(sequence.timeline.clip(id: clipID))

        // The viewer resolves through a context of its own, which reads the
        // store: an unsaved project would come back as missing media and the
        // sequence would refuse to preview.
        let resolver = DocumentMediaResolver(document: document, width: 320, height: 180, fps: 30)
        let resolved = try await resolver.resolve(clip.source)
        if case .captions = resolved {} else { Issue.record("Expected the caption clip to resolve to cues, got \(resolved)") }
        let projectUUID = result.project.projectUUID
        let fresh = ModelContext(document.container)
        #expect(try fresh.fetch(FetchDescriptor<CaptionProject>(predicate: #Predicate { $0.projectUUID == projectUUID })).count == 1)
    }

    @Test("Captions already on the timeline are reused where the user left them")
    func existingClipIsLeftAlone() throws {
        var timeline = Timeline(width: 1920, height: 1080, fps: 30)
        let lane = try #require(timeline.tracks.first { $0.kind == .caption }?.id)
        let source = captionSource()
        let existing = Clip(source: source, start: 3, duration: 4)
        try TimelineEditor.insert(&timeline, clip: existing, on: lane)

        let before = timeline
        let id = try NarrativeCaptionClip.insert(source: source, style: .caption,
                                                 placement: .init(start: 40, duration: 9, inPoint: 0),
                                                 sourceDuration: 12, into: &timeline)
        #expect(id == existing.id)
        #expect(timeline == before)
    }
}
