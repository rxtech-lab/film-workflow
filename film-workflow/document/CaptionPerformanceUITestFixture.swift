#if DEBUG
import Foundation
import SwiftData

/// A persisted, hour-long transcript with word timings, translations and an
/// inactive take. The UI tests open the normal editor against this store.
@MainActor
enum CaptionPerformanceUITestFixture {
    static let projectID = UUID(uuidString: "00000000-0000-0000-0000-00000000CA00")!
    static let firstSegmentID = UUID(uuidString: "00000000-0000-0000-0000-00000000CA01")!

    static func openIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-uiTesting"),
              let path = ProcessInfo.processInfo.environment["RXFILM_CAPTION_PERFORMANCE_UI_TEST_ROOT"] else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let url = root.appendingPathComponent("Long Caption UI Test.rxfilmstudio")
        do {
            let controller = ProjectDocumentController.shared
            if !FileManager.default.fileExists(atPath: url.path) {
                let document = try controller.createDocument(at: url)
                let context = document.container.mainContext
                context.autosaveEnabled = false
                let project = CaptionProject(name: "Long transcript — 2000 captions")
                project.projectUUID = projectID
                project.audioDurationMs = 4_000_000
                project.languageHint = "en"
                project.speakers = [CaptionSpeaker(label: "Alice"), CaptionSpeaker(label: "Bob")]
                project.audioFilePath = "\(ProjectStorage.MediaKind.captions.rawValue)/performance.wav"
                context.insert(project)
                try writeSilentAudio(to: document.storage.absoluteURL(for: project.audioFilePath))

                var segments: [CaptionSegment] = []
                for versionNumber in 1...2 {
                    var version = CaptionTranscriptVersion(number: versionNumber, languageCode: "en", segmentCount: 2000)
                    if versionNumber == 2 {
                        version.id = UUID(uuidString: "00000000-0000-0000-0000-00000000CB00")!
                    }
                    project.versions.append(version)
                    project.activeVersionID = version.id
                    for index in 0..<2000 {
                        let start = index * 2000
                        let text = "Caption \(index + 1): a long interview about filmmaking and editing."
                        let words = text.split(separator: " ").enumerated().map {
                            CaptionWord(text: String($0.element), offsetMs: start + $0.offset * 150, durationMs: 140)
                        }
                        let segment = CaptionSegment(orderIndex: index, startMs: start, endMs: start + 1800,
                                                     text: text, speakerId: project.speakers[index % 2].id,
                                                     locale: "en", words: words)
                        segment.versionID = version.id
                        if versionNumber == 2, index == 0 { segment.uuid = firstSegmentID }
                        segment.setTranslation("字幕第 \(index + 1) 行：这是一段关于电影制作和剪辑的长篇访谈。", language: "zh-Hans")
                        context.insert(segment)
                        segments.append(segment)
                    }
                }
                // Assign once: repeatedly appending a SwiftData relationship
                // would benchmark fixture construction instead of the editor.
                project.segments = segments
                project.refreshTranslationSummary()
                project.displayedTranslationLanguage = "zh-Hans"
                try context.save()
                context.autosaveEnabled = true
                document.setFootageBrowserVisible(true)
                document.setPanelSizes([240, 380], for: .libraryRows)
                document.setPanelSizes([560, 180], for: .editorRows)
                document.save()
            }
            controller.requestOpen(url)
        } catch {
            try? error.localizedDescription.write(to: root.appendingPathComponent("fixture-error.txt"),
                                                 atomically: true, encoding: .utf8)
        }
    }

    /// A sparse PCM file keeps the full 66-minute playback duration without
    /// allocating a large audio buffer during fixture setup.
    private static func writeSilentAudio(to url: URL) throws {
        let rate = 8000, byteCount = 4000 * rate * 2
        var header = Data()
        func ascii(_ value: String) { header.append(contentsOf: value.utf8) }
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { header.append(contentsOf: $0) } }
        func u16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { header.append(contentsOf: $0) } }
        ascii("RIFF"); u32(36 + byteCount); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        ascii("data"); u32(byteCount)
        try header.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(header.count + byteCount))
    }
}
#endif
