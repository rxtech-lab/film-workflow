import Foundation
import SwiftData
import Testing

@testable import film_workflow

@Suite("Caption retimer draft")
@MainActor
struct CaptionRetimeDraftTests {
    @Test("Edits stay in the draft and reverting a time removes it from Save")
    func editsAndReverts() {
        let first = CaptionSegment(startMs: 0, endMs: 1000, text: "First")
        let second = CaptionSegment(startMs: 1200, endMs: 2000, text: "Second")
        var draft = CaptionRetimeDraft(segments: [first, second])
        #expect(draft.changedCount == 0)
        #expect(draft.pendingIDs.isEmpty)

        draft.apply(2100, to: .end, for: second.uuid)
        draft.apply(100, to: .start, for: first.uuid)
        #expect(draft.changedCount == 2)
        #expect(draft.pendingIDs == [first.uuid, second.uuid])
        #expect(first.startMs == 0)
        #expect(second.endMs == 2000)

        draft.apply(0, to: .start, for: first.uuid)
        #expect(draft.changedCount == 1)
        #expect(draft.pendingIDs == [second.uuid])
        draft.apply(2000, to: .end, for: second.uuid)
        #expect(draft.changedCount == 0)
        #expect(draft.pendingIDs.isEmpty)
    }

    @Test("Invalid input is tracked and boundary edits preserve the timing rules")
    func invalidRanges() {
        let negative = CaptionSegment(startMs: -10, endMs: 100, text: "Negative")
        let reversed = CaptionSegment(startMs: 100, endMs: 90, text: "Reversed")
        var draft = CaptionRetimeDraft(segments: [negative, reversed])
        #expect(draft.hasInvalidRange)
        draft.apply(-30, to: .start, for: negative.uuid)
        #expect(draft[negative.uuid]?.startMs == 0)
        #expect(draft.hasInvalidRange)
        draft.apply(90, to: .end, for: reversed.uuid)
        #expect(draft[reversed.uuid]?.endMs == 101)
        #expect(!draft.hasInvalidRange)
        draft.apply(300, to: .start, for: reversed.uuid)
        #expect(draft[reversed.uuid] == .init(startMs: 300, endMs: 301))
        #expect(draft.originalRange(for: reversed.uuid) == .init(startMs: 100, endMs: 90))
        #expect(reversed.endMs == 90)
    }

    @Test("Each session follows the current version and timing order")
    func versionAndOrder() throws {
        let container = try ModelContainer(for: CaptionProject.self, CaptionSegment.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = CaptionProject(name: "Versions")
        container.mainContext.insert(project)
        let version = UUID()
        let later = CaptionSegment(orderIndex: 2, startMs: 1000, endMs: 2000, text: "Later")
        let first = CaptionSegment(orderIndex: 0, startMs: 0, endMs: 800, text: "First")
        let tied = CaptionSegment(orderIndex: 1, startMs: 0, endMs: 900, text: "Tied")
        let inactive = CaptionSegment(startMs: 0, endMs: 900, text: "Inactive")
        inactive.versionID = version
        project.segments = [later, inactive, tied, first]

        let draft = CaptionRetimeDraft(segments: project.orderedSegments)
        #expect(draft.order == [first.uuid, tied.uuid, later.uuid])
        #expect(draft.index(of: first.uuid) == 0)
        #expect(draft.index(of: later.uuid) == 2)
        #expect(draft.index(of: inactive.uuid) == nil)
        #expect(draft[inactive.uuid] == nil)
        project.activeVersionID = version
        let reopened = CaptionRetimeDraft(segments: project.orderedSegments)
        #expect(reopened.order == [inactive.uuid])
        #expect(reopened.changedCount == 0)
    }

    @Test("An empty draft ignores edits to missing captions")
    func empty() {
        var draft = CaptionRetimeDraft()
        draft.apply(1000, to: .start, for: UUID())
        #expect(draft.order.isEmpty)
        #expect(draft.pendingIDs.isEmpty)
        #expect(!draft.hasInvalidRange)
    }

    @Test("A long transcript supports repeated playback reads and boundary edits")
    func longTranscript() {
        let segments = (0..<2000).map {
            CaptionSegment(orderIndex: $0, startMs: $0 * 1000, endMs: $0 * 1000 + 900, text: "Caption \($0)")
        }
        let start = ContinuousClock.now
        var draft = CaptionRetimeDraft(segments: segments)
        let loaded = ContinuousClock.now
        var changedCounts = 0
        var positions = 0
        for index in draft.order.indices {
            let id = draft.order[index]
            draft.apply(index * 1000 + 950, to: .end, for: id)
            // The header, footer and focus queries used on every playback tick.
            for _ in 0..<10 {
                changedCounts += draft.changedCount
                positions += draft.index(of: id) ?? -1
            }
        }
        let elapsed = loaded.duration(to: .now)
        print("Caption retimer: 2000 captions loaded in \(start.duration(to: loaded)); 2000 edits and 20000 playback reads in \(elapsed)")
        #expect(changedCounts == 20_010_000)
        #expect(positions == 19_990_000)
        #expect(draft.changedCount == 2000)
        #expect(draft.pendingIDs == draft.order)
        #expect(!draft.hasInvalidRange)
        // A broad regression budget: UI reads must not sort/fault the full
        // SwiftData relationship for every caption or playback update.
        #expect(elapsed < .seconds(2))
    }
}
