import AppKit
import SwiftData
import SwiftUI
import Testing
import VideoEditorCore
@testable import film_workflow

@MainActor @Suite("Recording take removal", .serialized)
struct RecordingTakeLibraryTests {
    @Test func removalPreservesTimelineMediaAndVersionNumbersThroughUndoAndReopen() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RemoveTake-\(UUID()).rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let context = document.container.mainContext
        let project = ScreenRecordingProject(name: "Demo")
        context.insert(project)
        let older = RecordingTake(name: "Take 1"); older.createdAt = Date(timeIntervalSince1970: 1); older.project = project
        let newer = RecordingTake(name: "Take 2"); newer.createdAt = Date(timeIntervalSince1970: 2); newer.project = project
        older.duration = 2; newer.duration = 2
        let file = document.storage.absoluteURL(for: "Media/recording.mov")
        try Data([1, 2, 3]).write(to: file)
        newer.components = [.init(role: .screen, name: "Screen", filePath: "Media/recording.mov", duration: 2, width: 640, height: 480),
                            .init(role: .shortcuts, name: "Shortcuts", filePath: "", duration: 2, cues: [.init(start: 0, end: 1, text: "⌘K")])]
        context.insert(older); context.insert(newer)
        let sequence = SequenceProject(name: "Edit"); context.insert(sequence)
        try RecordingTimelineService.insert(take: newer, into: sequence, at: 0)
        try context.save()
        let timeline = sequence.timeline, takeID = newer.id, componentID = try #require(newer.primary?.id)
        let item = LibraryItemID(kind: .screenRecording, id: project.id)
        let undo = UndoManager(); undo.groupsByEvent = false; undo.beginUndoGrouping()
        try RecordingTakeLibrary.remove(older, context: context, undoManager: undo)
        undo.endUndoGrouping()
        #expect(LibraryIndex(recordings: [project]).versions(for: item).map(\.label) == ["v2"])
        #expect(LibraryIndex(recordings: [project]).footage(for: item).map(\.id) == [newer.id])
        undo.undo(); #expect(project.visibleTakes.count == 2)
        undo.redo(); #expect(project.visibleTakes.count == 1)
        try RecordingTakeLibrary.remove(newer, context: context)
        #expect(project.visibleTakes.isEmpty)
        #expect(LibraryIndex(recordings: [project]).rows().first?.dragItem == nil)
        #expect(LibraryIndex(recordings: [project]).versions(for: item).isEmpty)
        #expect(LibraryIndex(recordings: [project]).footage(for: item).isEmpty)
        #expect(sequence.timeline == timeline)
        #expect(try RecordingTimelineService.resolve(id: componentID, context: context).0.id == takeID)
        let resolver = DocumentMediaResolver(document: document, width: 640, height: 480, fps: 30)
        let media = try await resolver.resolve(try #require(timeline.allClips.first { $0.source.kind == .video }).source)
        #expect(media.fileURL == file)
        #expect(try Data(contentsOf: file) == Data([1, 2, 3]))
        await document.close()
        let reopened = try ProjectDocument.open(url)
        let restored = try RecordingTimelineService.take(id: takeID, context: reopened.container.mainContext)
        #expect(restored.isRemovedFromLibrary)
        #expect(restored.project?.visibleTakes.isEmpty == true)
        #expect(try RecordingTimelineService.resolve(id: componentID, context: reopened.container.mainContext).0.id == takeID)
        await reopened.close()
    }

    /// The button no longer removes on its own — it arms the confirmation — so
    /// the harness stands in for the list that owns that pending take.
    @Test func removeButtonArmsOnlyItsOwnTake() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TakeButton-\(UUID()).rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let project = ScreenRecordingProject(name: "Demo"); document.container.mainContext.insert(project)
        let first = RecordingTake(name: "First"), second = RecordingTake(name: "Second")
        first.project = project; second.project = project
        document.container.mainContext.insert(first); document.container.mainContext.insert(second)
        try document.container.mainContext.save()
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let pending = PendingTakeBox()
        let host = NSHostingView(rootView: RemoveButtonHarness(take: first, pending: pending).modelContainer(document.container))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 120), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let button = try #require(hostedAccessibilityDescendants(host).first { $0.accessibilityIdentifier() == "recording.take.remove.\(first.id.uuidString)" })
        #expect(button.accessibilityPerformPress())
        #expect(pending.take === first)
        #expect(!first.isRemovedFromLibrary, "pressing only asks; the dialog does the removing")

        try RecordingTakeLibrary.remove(try #require(pending.take), context: document.container.mainContext)
        #expect(first.isRemovedFromLibrary)
        #expect(!second.isRemovedFromLibrary)
        #expect(project.visibleTakes.map(\.id) == [second.id])
        await document.close()
    }
}

/// Holds what the button armed, since a test cannot read a view's `@State`.
@MainActor private final class PendingTakeBox {
    var take: RecordingTake?
}

private struct RemoveButtonHarness: View {
    let take: RecordingTake
    let pending: PendingTakeBox

    var body: some View {
        RecordingTakeRemoveButton(
            take: take,
            selection: Binding(get: { pending.take }, set: { pending.take = $0 })
        )
    }
}
