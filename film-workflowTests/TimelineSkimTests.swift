import Foundation
import Testing
import VideoEditorCore

@testable import film_workflow

@Suite("Timeline skimming", .serialized)
@MainActor
struct TimelineSkimTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "TimelineSkimTests-\(UUID().uuidString)")!
    }

    @Test("Skimming previews the pointer's frame and leaves the playhead alone")
    func skimKeepsPlayhead() {
        let state = EditorWindowState(defaults: defaults())
        state.skimsTimeline = true
        state.playhead = 4
        state.skim(to: 9)
        #expect(state.player.currentTime == 9)
        #expect(state.playhead == 4)
        state.skim(to: 12)
        #expect(state.player.currentTime == 12)
        #expect(state.playhead == 4)
        state.endSkim()
        #expect(state.player.currentTime == 4)
        #expect(state.playhead == 4)
    }

    @Test("A click while skimming moves the playhead for good")
    func clickWins() {
        let state = EditorWindowState(defaults: defaults())
        state.skimsTimeline = true
        state.playhead = 4
        state.skim(to: 9)
        state.playhead = 9
        state.skim(to: 10)
        state.endSkim()
        #expect(state.playhead == 9)
        #expect(state.player.currentTime == 9)
    }

    @Test("Skimming is inert while off, and turning it off restores the playhead")
    func toggle() {
        let state = EditorWindowState(defaults: defaults())
        state.playhead = 4
        state.skim(to: 9)
        #expect(state.player.currentTime == 4)
        state.skimsTimeline = true
        state.skim(to: 9)
        #expect(state.player.currentTime == 9)
        state.skimsTimeline = false
        #expect(state.player.currentTime == 4)
        #expect(state.playhead == 4)
    }

    @Test("Skimming footage shows that take in the viewer and leaves the selection alone")
    func footageSkimShowsTake() {
        let state = EditorWindowState(defaults: defaults())
        let video = LibraryItemID(kind: .video, id: UUID())
        let take = UUID()
        state.select(LibraryItemID(kind: .sequence, id: UUID()))
        state.skimFootage(video, cellID: take, fraction: 0.25)
        #expect(state.footageSkim == FootageSkim(item: video, cellID: take, fraction: 0.25))
        #expect(state.viewerSelection?.kind == .sequence)
        state.skimFootage(video, cellID: take, fraction: 1.5)
        #expect(state.footageSkim?.fraction == 1)
        state.endFootageSkim()
        #expect(state.footageSkim == nil)
        #expect(state.viewerSelection?.kind == .sequence)
    }

    @Test("Choosing an item or a version ends a skim that never reported its end")
    func selectionOutranksSkim() {
        let state = EditorWindowState(defaults: defaults())
        let video = LibraryItemID(kind: .video, id: UUID())
        let still = LibraryItemID(kind: .image, id: UUID())
        // The pointer left over the take with the app, so no hover ended: the
        // skim is still standing in for the selection when the user comes back.
        state.skimFootage(video, cellID: UUID(), fraction: 0.5)
        #expect(state.footageSkim != nil)
        state.select(still)
        #expect(state.footageSkim == nil, "A still has no frames to skim and must not keep previewing the take")
        #expect(state.viewerSelection == still)

        let take = UUID()
        state.skimFootage(video, cellID: UUID(), fraction: 0.5)
        state.setCurrentVersion(take, for: still)
        #expect(state.footageSkim == nil)
        #expect(state.currentVersion(for: still) == take)
    }

    @Test("Footage skimming ignores the timeline Skim switch and skips items with their own viewer")
    func footageSkimGates() {
        let state = EditorWindowState(defaults: defaults())
        let video = LibraryItemID(kind: .video, id: UUID())
        for kind in [FootageKind.sequence] {
            state.skimFootage(LibraryItemID(kind: kind, id: UUID()), cellID: UUID(), fraction: 0.5)
            #expect(state.footageSkim == nil)
        }
        #expect(state.skimsTimeline == false)
        state.skimFootage(video, cellID: UUID(), fraction: 0.5)
        #expect(state.footageSkim != nil)
        state.skimsTimeline = true
        state.skimsTimeline = false
        #expect(state.footageSkim != nil)
    }

    @Test("The skim preference survives a relaunch")
    func persisted() {
        let store = defaults()
        #expect(EditorWindowState(defaults: store).skimsTimeline == false)
        EditorWindowState(defaults: store).skimsTimeline = true
        #expect(EditorWindowState(defaults: store).skimsTimeline == true)
    }
}
