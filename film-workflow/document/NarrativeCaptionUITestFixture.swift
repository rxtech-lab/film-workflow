#if DEBUG
import Foundation
import SwiftData
import VideoEditorCore

/// A film holding one narration, already laid on the timeline, for the UI test
/// that creates its captions from the clip's context menu. The audio is a real
/// (silent) file so the preview builds the way it does for a generated take.
@MainActor
enum NarrativeCaptionUITestFixture {
    /// Ids the test addresses: the narration clip it right-clicks.
    static let narrationClipID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private static let narrationID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    private static let audioID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!

    static func openIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-uiTesting"),
              let path = ProcessInfo.processInfo.environment["RXFILM_CAPTION_UI_TEST_ROOT"] else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let url = root.appendingPathComponent("Caption UI Test.rxfilmstudio")
        do {
            let controller = ProjectDocumentController.shared
            if !FileManager.default.fileExists(atPath: url.path) {
                let document = try controller.createDocument(at: url)
                let context = document.container.mainContext

                let narrative = NarrativeProject(name: "Story")
                narrative.paragraphs = [
                    NarrativeParagraph(speakerId: narrative.speakers[0].id, emotion: "",
                                       content: "Hello from the narration.")
                ]
                context.insert(narrative)

                // The caption project links back to the take by its filename,
                // so the audio has to be named for a UUID like a real one.
                let relativePath = "\(ProjectStorage.MediaKind.narration.rawValue)/\(audioID.uuidString).wav"
                try silentAudio(seconds: 6).write(to: document.storage.absoluteURL(for: relativePath))
                let generated = GeneratedNarrative(audioFilePath: relativePath,
                                                   transcriptText: "Hello from the narration.",
                                                   project: narrative)
                generated.id = narrationID
                generated.durationSeconds = 6
                context.insert(generated)

                let sequence = SequenceProject(name: "Cut")
                var timeline = Timeline(width: 320, height: 180, fps: 30)
                let audio = timeline.tracks.first { $0.kind == .audio }!
                var clip = Clip(
                    source: ClipSource(id: DocumentMediaResolver.sourceID(.narration, narrationID),
                                       kind: .audio, displayName: "Story"),
                    start: 0, duration: 6, sourceDuration: 6
                )
                clip.id = narrationClipID
                try TimelineEditor.insert(&timeline, clip: clip, on: audio.id)
                sequence.timeline = timeline
                context.insert(sequence)
                try context.save()

                document.setPanelSizes([400, 340], for: .editorRows)
                document.save()
                document.focusTimeline(sequenceID: sequence.id, time: 0)
            }
            controller.requestOpen(url)
        } catch {
            try? error.localizedDescription.write(to: root.appendingPathComponent("fixture-error.txt"),
                                                 atomically: true, encoding: .utf8)
        }
    }

    /// Silent 16-bit mono WAV, written by hand so the fixture needs no encoder.
    private static func silentAudio(seconds: Int) -> Data {
        let rate = 44_100, channels = 1, bits = 16
        let bytes = seconds * rate * channels * bits / 8
        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(36 + bytes); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(channels); u32(rate)
        u32(rate * channels * bits / 8); u16(channels * bits / 8); u16(bits)
        ascii("data"); u32(bytes)
        data.append(Data(count: bytes))
        return data
    }
}
#endif
