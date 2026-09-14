#if DEBUG
import AppKit
import Foundation
import SwiftData
import VideoEditorCore

/// A film holding one take the pointer can skim, one still, and a sequence
/// carrying the take, for the UI tests that move the viewer between them. The
/// media is real, so the viewer builds it the way it does for generated footage.
@MainActor
enum StillPreviewUITestFixture {
    /// Ids the tests address: the two library cards, the take they skim, and
    /// the clip whose selection sends the viewer back to the sequence.
    private static let narrationID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    private static let narrationTakeID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!
    private static let imageID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!
    private static let imageTakeID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C4")!
    private static let narrationClipID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C5")!
    /// The still is one flat colour so the test can read the viewer's pixels
    /// rather than trust a label. Named in sRGB at both ends of the comparison,
    /// and short of the primaries, which a wide-gamut display moves far enough
    /// to fail a pixel match.
    private static let stillColor = NSColor(srgbRed: 0.2, green: 0.45, blue: 0.85, alpha: 1)

    static func openIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-uiTesting"),
              let path = ProcessInfo.processInfo.environment["RXFILM_STILL_UI_TEST_ROOT"] else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let url = root.appendingPathComponent("Still Preview UI Test.rxfilmstudio")
        do {
            let controller = ProjectDocumentController.shared
            if !FileManager.default.fileExists(atPath: url.path) {
                let document = try controller.createDocument(at: url)
                let context = document.container.mainContext

                let narrative = NarrativeProject(name: "Voice Over")
                narrative.id = narrationID
                narrative.paragraphs = [
                    NarrativeParagraph(speakerId: narrative.speakers[0].id, emotion: "",
                                       content: "Hello from the narration.")
                ]
                context.insert(narrative)
                let audioPath = try document.storage.saveAudio(silentAudio(seconds: 6), extension: "wav", kind: .narration)
                let take = GeneratedNarrative(audioFilePath: audioPath,
                                              transcriptText: "Hello from the narration.",
                                              project: narrative)
                take.id = narrationTakeID
                take.durationSeconds = 6
                context.insert(take)

                let still = ImageGenProject(name: "Still Frame")
                still.id = imageID
                context.insert(still)
                let imagePath = try document.storage.saveImage(try stillPNG(), fileExtension: "png")
                let generated = GeneratedImage(imageFilePath: imagePath, prompt: "A flat colour", project: still)
                generated.id = imageTakeID
                context.insert(generated)

                let sequence = SequenceProject(name: "Cut")
                var timeline = Timeline(width: 320, height: 180, fps: 30)
                let audio = timeline.tracks.first { $0.kind == .audio }!
                var clip = Clip(
                    source: ClipSource(id: DocumentMediaResolver.sourceID(.narration, narrationTakeID),
                                       kind: .audio, displayName: "Voice Over"),
                    start: 0, duration: 6, sourceDuration: 6
                )
                clip.id = narrationClipID
                try TimelineEditor.insert(&timeline, clip: clip, on: audio.id)
                sequence.timeline = timeline
                context.insert(sequence)

                try context.save()
                document.setFootageBrowserVisible(true)
                document.setPanelSizes([380, 220], for: .libraryRows)
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

    /// A 16:9 fill, so the still covers the middle of the viewer whichever way
    /// the stage fits it.
    private static func stillPNG() throws -> Data {
        let size = NSSize(width: 640, height: 360)
        let image = NSImage(size: size)
        image.lockFocus()
        stillColor.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return png
    }
}
#endif
