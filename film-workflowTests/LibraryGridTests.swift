import AppKit
import Observation
import SwiftUI
import Testing
import VideoEditorCore

@testable import film_workflow

@Suite("Library footage grid", .serialized)
@MainActor
struct LibraryGridTests {
    @Observable
    final class Selection {
        var item: LibraryItemID?
    }

    private struct Footage: LibPreviewableProtocol {
        let clipSource: ClipSource
        let thumbnailURL: URL?
        let storedDuration: TimeInterval?
        var mediaURL: URL? { nil }
    }

    private func descendants(_ value: Any) -> [HostedAccessibilityElement] {
        hostedAccessibilityDescendants(value)
    }

    @Test("Library and version cards share rows, wrap with panel width, and display their footage", arguments: [false, true])
    func layoutAndSelection(versions: Bool) async throws {
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let posterURL = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryPoster-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: posterURL) }
        let poster = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 90,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<90 {
            for x in 0..<160 { poster.setColor(NSColor(deviceRed: 0.9, green: 0.2, blue: 0.15, alpha: 1), atX: x, y: y) }
        }
        try #require(poster.representation(using: .png, properties: [:])).write(to: posterURL)

        let group = ProjectGroup(name: "Location footage")
        let rows = ["Harbor sunrise", "City skyline", "Evening traffic"].map { name in
            LibraryRow(id: .init(kind: .imported, id: UUID()), name: name, subtitle: "1920×1080",
                       updatedAt: Date(), groupID: group.id, dragItem: nil, versions: [])
        }
        let cells = Dictionary(uniqueKeysWithValues: rows.enumerated().map { index, row in
            (row.id, FootageCell(id: row.id.id, title: row.name, subtitle: row.subtitle,
                                footage: Footage(clipSource: .init(id: row.id.id.uuidString, kind: .video, displayName: row.name),
                                                 thumbnailURL: posterURL, storedDuration: [12, 18, 70][index])))
        })
        let selection = Selection()
        let grid = LibraryGrid(rows: rows, groups: [group],
                               selection: Binding(get: { selection.item }, set: { selection.item = $0 }),
                               onMove: { _, _ in }, onCreate: { _, _ in }, onImport: {}, onCreateGroup: {},
                               onRenameGroup: { _ in }, onDeleteGroup: { _ in }, onRename: { _ in },
                               onDelete: { _ in }, onExport: { _ in }, onShowVersions: { _, _ in },
                               currentVersion: { cells[$0]?.id }, onSelectVersion: { _, _ in },
                               dragPayload: { row in cells[row.id].map { FootageDragPayload(item: $0.drag, thumbnailURL: $0.thumbnailURL) } },
                               footage: { cells[$0] })
        let browser = FootageBrowserView(libraryItem: rows[0].id, title: "Versions",
                                        cells: rows.compactMap { cells[$0.id] }, selectedID: nil,
                                        onSelect: { _ in }, onDeselect: {})
        let host = NSHostingView(rootView: versions ? AnyView(browser) : AnyView(grid))
        let screenshotName = versions ? "versions-flow" : "library-grid"
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 560),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }

        for width in [240, 420, 960, 240] {
            window.setContentSize(NSSize(width: width, height: 560))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            let elements = descendants(host)
            let dump = elements.map { "\($0.accessibilityIdentifier() ?? "-") | \($0.accessibilityLabel() ?? "-") | \($0.accessibilityFrame())" }.joined(separator: "\n")
            try dump.write(toFile: "/tmp/film-\(screenshotName)-accessibility.txt", atomically: true, encoding: .utf8)
            let preview = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: preview)
            try #require(preview.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/film-\(screenshotName)-\(width).png"))
            let cards = try rows.map { row in
                let prefix = versions ? "footage.cell" : "library.item"
                return try #require(elements.first { $0.accessibilityIdentifier() == "\(prefix).\(row.id.id.uuidString)" })
            }
            let first = cards[0].accessibilityFrame()
            let second = cards[1].accessibilityFrame()
            let third = cards[2].accessibilityFrame()
            #expect(first.width < second.width && second.width < third.width)
            #expect(cards.allSatisfy { $0.accessibilityFrame().maxX <= window.frame.maxX })
            if width == 240 {
                #expect(abs(second.minX - first.minX) < 1)
                #expect(second.maxY < first.minY && third.maxY < second.minY)
            } else {
                #expect(second.minX > first.maxX && abs(second.maxY - first.maxY) < 1,
                        "Short footage should share a row when there is space")
                if width == 420 {
                    #expect(abs(third.minX - first.minX) < 1 && third.maxY < first.minY,
                            "Footage that does not fit should move to the next row")
                } else {
                    #expect(third.minX > second.maxX && abs(third.maxY - first.maxY) < 1)
                }
            }
            #expect(width < 960 ? third.height > first.height + 60 : abs(third.height - first.height) < 1,
                    "Footage wider than the panel must continue on additional lines")
            if !versions {
                #expect(cards[0].accessibilityLabel()?.contains("0:12") == true)
                #expect(cards[0].accessibilityPerformPress())
                #expect(selection.item == rows[0].id)
            }

            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            var redPixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.redComponent > 0.7, color.greenComponent < 0.4, color.blueComponent < 0.4 { redPixels += 1 }
                }
            }
            #expect(redPixels > 2_000, "The cards must render decoded poster images")
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/film-\(screenshotName)-\(width).png"))
        }

        guard !versions else { return }
        let folder = try #require(descendants(host).first { $0.accessibilityIdentifier() == "library.folder.\(group.id.uuidString)" })
        #expect(folder.accessibilityPerformPress())
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let collapsedBitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: collapsedBitmap)
        try #require(collapsedBitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/film-library-collapsed.png"))
        // SwiftUI keeps virtual nodes in its lazy layout cache after collapse.
        // Check the rendered surface so cached accessibility nodes cannot mask
        // footage that is still visibly on screen.
        var visiblePosterPixels = 0
        for y in 0..<collapsedBitmap.pixelsHigh {
            for x in 0..<collapsedBitmap.pixelsWide {
                if let color = collapsedBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent > 0.7, color.greenComponent < 0.4 { visiblePosterPixels += 1 }
            }
        }
        #expect(visiblePosterPixels == 0)
        #expect(folder.accessibilityPerformPress())
        try await Task.sleep(for: .milliseconds(300))
        #expect(descendants(host).contains { $0.accessibilityIdentifier() == "library.item.\(rows[0].id.id.uuidString)" })
    }
}
