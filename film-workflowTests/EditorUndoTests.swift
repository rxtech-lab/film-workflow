import AppKit
import SwiftData
import Testing
import VideoEditorCore

@testable import film_workflow

@Suite("Editor undo and redo", .serialized)
@MainActor
struct EditorUndoTests {
    private func commit(_ timeline: Timeline, to sequence: SequenceProject, using manager: UndoManager) {
        manager.beginUndoGrouping()
        sequence.editTimeline(timeline, undoManager: manager)
        manager.endUndoGrouping()
    }

    @Test("Clip edits undo and redo in order, including split and delete")
    func timelineHistory() throws {
        let sequence = SequenceProject(name: "Edit")
        let manager = UndoManager()
        manager.groupsByEvent = false
        var timeline = sequence.timeline
        let trackID = try #require(timeline.tracks.first { $0.kind == .audio }?.id)
        let clip = Clip(source: ClipSource(id: "test", kind: .audio, displayName: "Clip"),
                        start: 0, duration: 8, sourceDuration: 20)
        var snapshots = [timeline]
        try TimelineEditor.insert(&timeline, clip: clip, on: trackID)
        commit(timeline, to: sequence, using: manager)
        snapshots.append(timeline)
        try TimelineEditor.move(&timeline, clipID: clip.id, to: 2)
        commit(timeline, to: sequence, using: manager)
        snapshots.append(timeline)
        try TimelineEditor.trimTrailing(&timeline, clipID: clip.id, by: -2)
        commit(timeline, to: sequence, using: manager)
        snapshots.append(timeline)
        try TimelineEditor.changeSpeed(&timeline, clipID: clip.id, rate: 2)
        commit(timeline, to: sequence, using: manager)
        snapshots.append(timeline)
        try TimelineEditor.reverse(&timeline, clipID: clip.id)
        commit(timeline, to: sequence, using: manager)
        snapshots.append(timeline)
        let right = try #require(TimelineEditor.split(&timeline, clipID: clip.id, at: 3))
        commit(timeline, to: sequence, using: manager)
        snapshots.append(timeline)
        TimelineEditor.remove(&timeline, clipID: right)
        commit(timeline, to: sequence, using: manager)
        snapshots.append(timeline)

        for expected in snapshots.dropLast().reversed() {
            #expect(manager.canUndo)
            manager.undo()
            #expect(sequence.timeline == expected)
            #expect(try TimelineCodec.decode(sequence.timelineData) == expected)
        }
        #expect(!manager.canUndo)
        for expected in snapshots.dropFirst() {
            #expect(manager.canRedo)
            manager.redo()
            #expect(sequence.timeline == expected)
        }
        #expect(!manager.canRedo)
    }

    @Test("No-op edits preserve redo; a new edit discards the redo branch")
    func redoBranch() {
        let sequence = SequenceProject(name: "Edit")
        let manager = UndoManager()
        manager.groupsByEvent = false
        sequence.editTimeline(sequence.timeline, undoManager: manager)
        #expect(!manager.canUndo)
        var changed = sequence.timeline
        changed.fps = 60
        commit(changed, to: sequence, using: manager)
        manager.undo()
        sequence.editTimeline(sequence.timeline, undoManager: manager)
        #expect(manager.canRedo)
        changed.fps = 24
        commit(changed, to: sequence, using: manager)
        #expect(!manager.canRedo)
        #expect(sequence.fps == 24)
        manager.undo()
        #expect(sequence.fps == 30)
    }

    @Test("Undo restores sequence settings and leaves other windows independent")
    func settingsAndWindowIsolation() {
        let first = SequenceProject(name: "First")
        let second = SequenceProject(name: "Second")
        let firstManager = UndoManager()
        let secondManager = UndoManager()
        firstManager.groupsByEvent = false
        secondManager.groupsByEvent = false
        let original = first.timeline
        var changed = original
        changed.width = 1080
        changed.height = 1920
        changed.fps = 60
        changed.backgroundHex = "#123456"
        commit(changed, to: first, using: firstManager)
        var other = second.timeline
        other.fps = 24
        commit(other, to: second, using: secondManager)
        firstManager.undo()
        #expect(first.timeline == original)
        #expect(first.width == 1920 && first.height == 1080 && first.fps == 30)
        #expect(second.timeline == other)
        #expect(secondManager.canUndo)
        firstManager.redo()
        #expect(first.timeline == changed)
        #expect(first.width == 1080 && first.height == 1920 && first.fps == 60)
    }

    @Test("Native Command-Z and Shift-Command-Z undo and restore an editor change")
    func nativeKeyboardShortcuts() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorUndo-\(UUID().uuidString).rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let sequence = SequenceProject(name: "Keyboard")
        document.container.mainContext.insert(sequence)
        document.save()
        let controller = ProjectDocumentController.shared
        controller.requestOpen(url)
        var editorWindow: NSWindow?
        for _ in 0..<40 {
            editorWindow = NSApp.windows.first { $0.title == document.displayName }
            if editorWindow != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let window = try #require(editorWindow)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        let opened = try #require(controller.document(for: url))
        let editedSequence = try #require(opened.container.mainContext.fetch(FetchDescriptor<SequenceProject>()).first)
        let manager = try #require(window.undoManager)
        let original = editedSequence.timeline
        var changed = original
        TimelineEditor.addTrack(&changed, kind: .video)
        commit(changed, to: editedSequence, using: manager)
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager.canUndo)

        func command(_ action: Selector, in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.action == action { return item }
                if let submenu = item.submenu, let found = command(action, in: submenu) { return found }
            }
            return nil
        }
        // XCTest's host may not become the active application. Copy the real
        // menu shortcuts and explicitly target this editor to make dispatch
        // independent of which application the user currently has in front.
        let appMenu = try #require(NSApp.mainMenu)
        let menu = NSMenu()
        for action in [Selector(("undo:")), Selector(("redo:"))] {
            let native = try #require(command(action, in: appMenu))
            let item = NSMenuItem(title: native.title, action: action, keyEquivalent: native.keyEquivalent)
            item.keyEquivalentModifierMask = native.keyEquivalentModifierMask
            item.target = window
            menu.addItem(item)
        }
        for redo in [false, true] {
            let key = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 6, keyDown: true))
            key.flags = redo ? [.maskCommand, .maskShift] : [.maskCommand]
            let event = try #require(NSEvent(cgEvent: key))
            menu.update()
            #expect(menu.performKeyEquivalent(with: event))
            try await Task.sleep(for: .milliseconds(100))
            #expect(editedSequence.timeline.tracks.count == original.tracks.count + (redo ? 1 : 0))
        }
        window.close()
        await controller.close(opened)
        await document.close()
    }
}
