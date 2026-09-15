import Foundation
import SwiftData
import Testing
import VideoEditorCore

@testable import film_workflow

@Suite("Long caption library preview", .serialized)
@MainActor
struct CaptionLibraryPreviewPerformanceTests {
    @Test("Repeated skim updates reuse the transcript and direct edits invalidate it immediately")
    func longTranscript() throws {
        let container = try ModelContainer(for: CaptionProject.self, CaptionSegment.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = CaptionProject(name: "Long captions")
        container.mainContext.insert(project)
        let active = UUID(), inactive = UUID()
        project.activeVersionID = active
        project.segments = (0..<4000).map { index in
            let segment = CaptionSegment(orderIndex: index % 2000, startMs: (index % 2000) * 2000,
                                         endMs: (index % 2000) * 2000 + 1800,
                                         text: "Caption \(index)", words: (0..<10).map {
                CaptionWord(text: "word \($0)", offsetMs: $0 * 100, durationMs: 90)
            })
            segment.versionID = index < 2000 ? active : inactive
            segment.setTranslation("字幕 \(index)", language: "zh-Hans")
            return segment
        }
        let index = LibraryIndex(captions: [project])
        let item = LibraryItemID(kind: .caption, id: project.projectUUID)
        let original = try #require(index.footage(for: item).first?.previewSource)
        let started = ContinuousClock.now
        var matching = 0
        for _ in 0..<1000 {
            if index.footage(for: item).first?.previewSource == original { matching += 1 }
            #expect(index.name(of: item) == "Long captions")
        }
        let elapsed = started.duration(to: .now)
        print("Caption preview: 1000 viewer updates with 4000 stored captions in \(elapsed)")
        #expect(matching == 1000)
        #expect(elapsed < .seconds(1))
        #expect(project.libraryPreviewCaptionCount == 2000)

        // These deliberately do not update project.updatedAt.
        try #require(project.orderedSegments.first).text = "Edited directly"
        let edited = project.makeLibPreviewSource()
        #expect(edited != original)
        try #require(project.orderedSegments.last).endMs += 5000
        let retimed = project.makeLibPreviewSource()
        #expect(try #require(retimed.duration) > #require(edited.duration))
        project.activeVersionID = inactive
        let switched = project.makeLibPreviewSource()
        #expect(switched != retimed)
        #expect(switched.duration == original.duration)
        project.captionStyle.fontSize += 1
        #expect(project.makeLibPreviewSource() != switched)
        project.segments.removeAll()
        #expect(index.footage(for: item).isEmpty)
    }
}
