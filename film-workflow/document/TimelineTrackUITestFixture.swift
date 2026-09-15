#if DEBUG
import AppKit
import Foundation
import SwiftData
import VideoEditorCore

@MainActor
enum TimelineTrackUITestFixture {
    static func openIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-uiTesting"),
              let path = ProcessInfo.processInfo.environment["RXFILM_TRACK_UI_TEST_ROOT"] else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let url = root.appendingPathComponent("Track Order UI Test.rxfilmstudio")
        do {
            let controller = ProjectDocumentController.shared
            if !FileManager.default.fileExists(atPath: url.path) {
                let document = try controller.createDocument(at: url)
                let sequence = SequenceProject(name: "Track Order")
                var tracks: [Track] = []
                for (index, color) in [NSColor.blue, .red].enumerated() {
                    let image = NSImage(size: CGSize(width: 64, height: 64))
                    image.lockFocus(); color.setFill(); NSRect(x: 0, y: 0, width: 64, height: 64).fill(); image.unlockFocus()
                    let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
                    let file = root.appendingPathComponent("\(index).png")
                    try png.write(to: file)
                    let asset = ImportedAsset(name: index == 0 ? "Blue" : "Red", kind: .image, originalPath: file.path)
                    asset.relativePath = try document.storage.copyFile(from: file, kind: .imported, fallbackExtension: "png")
                    document.container.mainContext.insert(asset)
                    let source = ClipSource(id: DocumentMediaResolver.sourceID(.imported, asset.id), kind: .image, displayName: asset.name)
                    tracks.append(Track(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                                        kind: index == 0 ? .overlay : .video, name: index == 0 ? "T1" : "V1",
                                        clips: [Clip(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 11))!,
                                                     source: source, start: 0, duration: 5)]))
                }
                tracks.append(Track(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, kind: .audio, name: "A1"))
                tracks.append(Track(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, kind: .audio, name: "A2"))
                sequence.timeline = Timeline(width: 320, height: 180, tracks: tracks)
                document.container.mainContext.insert(sequence)
                document.setPanelSizes([400, 340], for: .editorRows)
                document.save()
                document.focusTimeline(sequenceID: sequence.id, time: 0)
            }
            controller.requestOpen(url)
        } catch {
            try? error.localizedDescription.write(to: root.appendingPathComponent("fixture-error.txt"), atomically: true, encoding: .utf8)
        }
    }
}
#endif
