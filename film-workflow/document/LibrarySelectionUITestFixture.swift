#if DEBUG
import AppKit
import Foundation
import SwiftData
import VideoEditorCore

/// A film with two library cards and room to spare underneath them, for the
/// tests that click the empty part of the library: the gap past the last card
/// has to clear the selection and offer the creation menu, rather than swallow
/// the click the way a bare scroll view does.
@MainActor
enum LibrarySelectionUITestFixture {
    /// The two cards the tests select and deselect.
    private static let blueID = UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!
    private static let redID = UUID(uuidString: "00000000-0000-0000-0000-0000000000E2")!

    static func openIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-uiTesting"),
              let path = ProcessInfo.processInfo.environment["RXFILM_LIBRARY_UI_TEST_ROOT"] else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let url = root.appendingPathComponent("Library Selection UI Test.rxfilmstudio")
        do {
            let controller = ProjectDocumentController.shared
            if !FileManager.default.fileExists(atPath: url.path) {
                let document = try controller.createDocument(at: url)
                let context = document.container.mainContext

                for (id, name, color) in [(blueID, "Blue Card", NSColor.blue), (redID, "Red Card", NSColor.red)] {
                    let file = root.appendingPathComponent("\(name).png")
                    try png(color).write(to: file)
                    let asset = ImportedAsset(name: name, kind: .image, originalPath: file.path)
                    asset.id = id
                    asset.relativePath = try document.storage.copyFile(from: file, kind: .imported, fallbackExtension: "png")
                    context.insert(asset)
                }

                let sequence = SequenceProject(name: "Cut")
                sequence.timeline = Timeline(width: 320, height: 180, fps: 30)
                context.insert(sequence)

                try context.save()
                document.setFootageBrowserVisible(true)
                // Two cards in one row, in a tall pane: everything below the
                // first row of the grid is the empty space under test.
                document.setPanelSizes([460, 160], for: .libraryRows)
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

    private static func png(_ color: NSColor) throws -> Data {
        let size = NSSize(width: 320, height: 180)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
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
