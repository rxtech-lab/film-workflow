import Foundation
import SwiftData
import Testing
import VideoEditorCore
import VideoEditorUI

@testable import film_workflow

@Suite("Caption alignment with its original audio")
@MainActor
struct CaptionAudioAlignmentTests {
    private let projectUUID = UUID()
    private let narrativeID = UUID()

    private func captionClip(_ uuid: UUID) -> Clip {
        Clip(source: ClipSource(id: DocumentMediaResolver.sourceID(.caption, uuid), kind: .captions, displayName: "Captions"), start: 0, duration: 3)
    }

    private func audioClip(_ prefix: DocumentMediaResolver.SourceKindPrefix, _ id: UUID, start: TimeInterval) -> Clip {
        Clip(source: ClipSource(id: DocumentMediaResolver.sourceID(prefix, id), kind: .audio, displayName: "Audio"), start: start, duration: 4)
    }

    @Test("Offered for captions with audio, enabled only when a clip playing that audio is on the timeline")
    func offerRules() throws {
        var timeline = Timeline(width: 1920, height: 1080, fps: 30)
        let overlay = try #require(timeline.tracks.first { $0.kind == .caption }?.id)
        let audio = try #require(timeline.tracks.first { $0.kind == .audio }?.id)
        let captions = captionClip(projectUUID)
        try TimelineEditor.insert(&timeline, clip: captions, on: overlay)
        let narrationID = DocumentMediaResolver.sourceID(.narration, narrativeID)

        // No audio on the project: no item.
        #expect(CaptionAudioAlignment.alignment(for: captions, in: timeline) { _ in nil } == nil)
        // Non-caption clips never get the item.
        #expect(CaptionAudioAlignment.alignment(for: audioClip(.narration, UUID(), start: 0), in: timeline) { _ in [narrationID] } == nil)

        // Linked audio that isn't placed yet: disabled item.
        let disabled = try #require(CaptionAudioAlignment.alignment(for: captions, in: timeline) { $0 == projectUUID ? [narrationID] : nil })
        #expect(disabled.targetClipID == nil)

        // The earliest clip of that audio is the target; other audio doesn't count.
        try TimelineEditor.insert(&timeline, clip: audioClip(.narration, UUID(), start: 0), on: audio)
        let later = audioClip(.narration, narrativeID, start: 20)
        let earlier = audioClip(.narration, narrativeID, start: 10)
        try TimelineEditor.insert(&timeline, clip: later, on: audio)
        try TimelineEditor.insert(&timeline, clip: earlier, on: audio)
        let enabled = try #require(CaptionAudioAlignment.alignment(for: captions, in: timeline) { $0 == projectUUID ? [narrationID] : nil })
        #expect(enabled.targetClipID == earlier.id)

        // Music or imported takes of the same file count too.
        let musicID = UUID()
        let music = audioClip(.music, musicID, start: 5)
        try TimelineEditor.insert(&timeline, clip: music, on: audio)
        let viaMusic = try #require(CaptionAudioAlignment.alignment(for: captions, in: timeline) { _ in [DocumentMediaResolver.sourceID(.music, musicID)] })
        #expect(viaMusic.targetClipID == music.id)

        try TimelineEditor.align(&timeline, clipID: captions.id, with: earlier.id)
        #expect(timeline.clip(id: captions.id)?.start == 10)
        #expect(timeline.clip(id: captions.id)?.duration == 4)
    }

    @Test("Origin ids come from the audio path, the narrative's filename link and its back-link")
    func originLookup() throws {
        let container = try ModelContainer(for: CaptionProject.self, GeneratedNarrative.self, NarrativeProject.self, GeneratedMusic.self, MusicProject.self, ImportedAsset.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let fileID = UUID()
        let narrativeProject = NarrativeProject(name: "Story")
        context.insert(narrativeProject)
        let narration = GeneratedNarrative(audioFilePath: "generated/\(fileID.uuidString).m4a", transcriptText: "Hi", project: narrativeProject)
        context.insert(narration)
        let other = GeneratedNarrative(audioFilePath: "generated/\(UUID().uuidString).m4a", transcriptText: "Other", project: narrativeProject)
        context.insert(other)

        let project = CaptionProject(name: "Captions")
        project.sourceKindEnum = .generatedNarrative
        project.sourceNarrativeID = fileID
        project.audioFilePath = narration.audioFilePath
        project.ownsAudioFile = false
        context.insert(project)
        try context.save()

        #expect(CaptionAudioAlignment.originSourceIDs(for: project, context: context) == [DocumentMediaResolver.sourceID(.narration, narration.id)])

        // A project whose path moved on still resolves through the filename link.
        project.audioFilePath = "captions/moved.m4a"
        #expect(CaptionAudioAlignment.originSourceIDs(for: project, context: context) == [DocumentMediaResolver.sourceID(.narration, narration.id)])

        // And through the narrative's own back-link when even that is gone.
        project.sourceNarrativeID = nil
        other.captionProjectID = project.projectUUID
        #expect(CaptionAudioAlignment.originSourceIDs(for: project, context: context) == [DocumentMediaResolver.sourceID(.narration, other.id)])
    }
}
