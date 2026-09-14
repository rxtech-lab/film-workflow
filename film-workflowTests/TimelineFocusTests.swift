import Foundation
import SwiftData
import Testing
import VideoEditorCore

@testable import film_workflow

@Suite("Timeline focus")
@MainActor
struct TimelineFocusTests {
    private func makeDocument() throws -> ProjectDocument {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelineFocus-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Focus")
            .appendingPathExtension("rxfilmstudio")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try ProjectDocumentController.shared.createDocument(at: url)
    }

    private func clip(_ start: TimeInterval, _ duration: TimeInterval, id: UUID = UUID()) -> Clip {
        Clip(
            id: id,
            source: ClipSource(id: "image:\(UUID().uuidString)", kind: .image, displayName: "Shot"),
            start: start,
            duration: duration
        )
    }

    @Test("Adding a clip asks the views to show that clip")
    func addClipFocuses() async throws {
        let document = try makeDocument()
        let parent = document.packageURL.deletingLastPathComponent()
        defer {
            Task { await ProjectDocumentController.shared.close(document) }
            try? FileManager.default.removeItem(at: parent)
        }

        // A generated still is the cheapest source a clip can point at.
        let context = document.container.mainContext
        let project = ImageGenProject(name: "Still")
        context.insert(project)
        context.insert(GeneratedImage(imageFilePath: "Media/Images/missing.png", prompt: "x", project: project))
        let sequence = SequenceProject(name: "Cut")
        context.insert(sequence)
        try context.save()

        var timeline = sequence.timeline
        let placed = clip(3, 4)
        try TimelineEditor.insert(&timeline, clip: placed, on: #require(timeline.tracks.first { $0.kind == .video }).id)
        sequence.timeline = timeline
        try context.save()

        document.focusTimeline(sequenceID: sequence.id, clipID: placed.id, time: placed.start)
        let focus = try #require(document.pendingTimelineFocus)
        #expect(focus.sequenceID == sequence.id)
        #expect(focus.clipID == placed.id)
        #expect(focus.time == 3)
    }

    @Test("The same clip twice still counts as a new request")
    func repeatedFocusIsDistinct() {
        let sequenceID = UUID(), clipID = UUID()
        let first = TimelineFocus(sequenceID: sequenceID, clipID: clipID, time: 2)
        let second = TimelineFocus(sequenceID: sequenceID, clipID: clipID, time: 2)
        // `.task(id:)` only re-runs when the value changes, so two identical
        // edits must not compare equal or the second would be ignored.
        #expect(first != second)
    }

    @Test("A negative time is clamped rather than seeking before the start")
    func clampsTime() {
        #expect(TimelineFocus(sequenceID: UUID(), time: -5).time == 0)
    }

    @Test("A rearranged timeline focuses the clip that moved")
    func focusTargetPicksTheChange() {
        let stableID = UUID(), movedID = UUID()
        var before = Timeline(width: 1920, height: 1080, fps: 30)
        let videoTrack = before.tracks.first { $0.kind == .video }!.id
        try? TimelineEditor.insert(&before, clip: clip(0, 5, id: stableID), on: videoTrack)
        try? TimelineEditor.insert(&before, clip: clip(5, 5, id: movedID), on: videoTrack)

        var after = Timeline(width: 1920, height: 1080, fps: 30)
        let afterTrack = after.tracks.first { $0.kind == .video }!.id
        try? TimelineEditor.insert(&after, clip: clip(0, 5, id: stableID), on: afterTrack)
        try? TimelineEditor.insert(&after, clip: clip(5, 9, id: movedID), on: afterTrack)

        let target = SequenceProject.focusTarget(before: before, after: after)
        #expect(target?.clipID == movedID)

        // A brand-new clip wins over an unchanged one.
        let addedID = UUID()
        var grown = after
        try? TimelineEditor.insert(&grown, clip: clip(14, 3, id: addedID), on: afterTrack)
        #expect(SequenceProject.focusTarget(before: after, after: grown)?.clipID == addedID)

        // Nothing at all: no focus rather than a wrong one.
        #expect(SequenceProject.focusTarget(before: nil, after: Timeline(width: 1920, height: 1080, fps: 30)) == nil)
    }
}
