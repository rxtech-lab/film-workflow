import Foundation
import Observation
import SwiftData
import Testing
import VideoEditorCore
import VideoEffectsCore
@testable import film_workflow

@Suite("Modifier inspector and history", .serialized)
@MainActor
struct ModifierInspectorTests {
    @Test("Modifier inspection is temporary and keeps the remembered footage tab")
    func temporarySelection() {
        let defaults = UserDefaults(suiteName: "ModifierInspectorTests-\(UUID())")!
        let state = EditorWindowState(defaults: defaults)
        state.inspectorTabID = "captions"
        let id = UUID()
        state.inspectEffects(id)
        #expect(state.modifierSelection == .effects(id))
        #expect(state.selectedClipID == id)
        #expect(state.inspectorTabID == "captions")
        state.inspectTransition(id)
        #expect(state.selectedTransitionID == id)
        #expect(state.selectedClipIDs.isEmpty)
        #expect(state.inspectorTabID == "captions")
        state.selectedClipID = UUID()
        #expect(state.modifierSelection == nil)
        #expect(state.inspectorTabID == "captions")
        state.modifierSelection = .catalog(.init(kind: .effect, definitionID: "rx.saturation"))
        state.select(nil)
        #expect(state.modifierSelection == nil)
    }

    @Test("Cached timeline reads still notify the inspector when parameters change")
    func parameterObservation() async throws {
        let sequence = SequenceProject(name: "Observation")
        let clip = Clip(source: .init(id: "still", kind: .image, displayName: "Still"), start: 0, duration: 4)
        sequence.timeline = Timeline(tracks: [Track(kind: .video, name: "V1", clips: [clip])])
        var initial = sequence.timeline
        try TimelineEditor.addEffect(&initial, definitionID: "rx.saturation", clipID: clip.id)
        sequence.timeline = initial
        try await confirmation("Inspector timeline dependency") { notified in
            withObservationTracking {
                _ = sequence.timeline.clip(id: clip.id)?.effects
            } onChange: { notified() }
            var changed = sequence.timeline
            try TimelineEditor.update(&changed, clipID: clip.id) { $0.effects[0].parameters["saturation"] = .number(1.5) }
            sequence.editTimeline(changed, undoManager: nil)
        }
    }

    @Test("Modifier edits undo and redo with the timeline and survive reopening")
    func historyAndReopen() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ModifierHistory-\(UUID()).rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let sequence = SequenceProject(name: "Effects")
        document.container.mainContext.insert(sequence)
        let a = Clip(source: .init(id: "still", kind: .image, displayName: "Still"), start: 0, duration: 4)
        let b = Clip(source: a.source, start: 4, duration: 4)
        sequence.timeline = Timeline(tracks: [Track(kind: .video, name: "V1", clips: [a, b])])
        let before = sequence.timeline
        let manager = UndoManager(); manager.groupsByEvent = false
        var edited = before
        try TimelineEditor.addEffect(&edited, definitionID: "rx.saturation", clipID: a.id)
        let transition = try TimelineEditor.addTransition(&edited, definitionID: "rx.cross-dissolve", attachment: .between(outgoing: a.id, incoming: b.id))
        manager.beginUndoGrouping(); sequence.editTimeline(edited, undoManager: manager); manager.endUndoGrouping()
        var resized = edited
        try TimelineEditor.updateTransition(&resized, id: transition) { $0.duration = 2 }
        manager.beginUndoGrouping(); sequence.editTimeline(resized, undoManager: manager); manager.endUndoGrouping()
        manager.undo(); #expect(sequence.timeline == edited)
        manager.undo(); #expect(sequence.timeline == before)
        manager.redo(); manager.redo(); #expect(sequence.timeline == resized)
        document.setPanelSizes([800, 310], for: .timelineColumns)
        document.setEffectsBrowserVisible(false)
        document.save()
        await document.close()
        let reopened = try ProjectDocument.open(url)
        let stored = try #require(reopened.container.mainContext.fetch(FetchDescriptor<SequenceProject>()).first)
        #expect(stored.timeline == resized)
        #expect(reopened.panelLayout.sizes(for: .timelineColumns) == [800, 310])
        #expect(reopened.panelLayout.effectsBrowserVisible == false)
        await reopened.close()
    }
}
