import AppKit
import AVFoundation
import SwiftUI
import Testing
import VideoEditorCore

@testable import film_workflow

@Suite("Footage filmstrip and viewer", .serialized)
@MainActor
struct FootageFilmstripTests {
    private struct Media: TimelineDraggable {
        let clipSource: ClipSource
        let mediaURL: URL?
        var storedDuration: TimeInterval? { nil }
    }

    @Test("Wrapped rows cover the full duration and map clicks to continuous time")
    func wrappedTime() {
        let layout = FilmstripLayout(duration: 100, availableWidth: 300, isTemporal: true)
        #expect(layout.rowCount == 3)
        #expect(layout.rowWidth(2) == 200)
        #expect(layout.fraction(row: 0, x: 300) == layout.fraction(row: 1, x: 0))
        #expect(layout.fraction(row: 1, x: 100) == 0.5)
        #expect(layout.fraction(row: 2, x: 200) == 1)
        #expect(layout.position(fraction: 0.5, row: 0) == nil)
        #expect(layout.position(fraction: 0.5, row: 1) == 100)
        #expect(FilmstripLayout(duration: 5, availableWidth: 300, isTemporal: true).rowCount == 1)
        #expect(FilmstripLayout(duration: .infinity, availableWidth: 300, isTemporal: true).rowCount == 1)
        #expect(FilmstripLayout(duration: 100, availableWidth: 300, isTemporal: false).rowCount == 1)
    }

    private func audioCell(at url: URL) throws -> FootageCell {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData)
        for index in 0..<Int(buffer.frameLength) { samples[0][index] = 0 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        let id = UUID()
        return FootageCell(id: id, title: "Version 1", subtitle: "Audio",
                           footage: Media(clipSource: .init(id: id.uuidString, kind: .audio, displayName: "Test footage"), mediaURL: url))
    }

    @Test("Clicking before media loads selects the take, commits time, and survives hover exit")
    func playbackAndSkimming() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Filmstrip-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let cell = try audioCell(at: url)
        let item = LibraryItemID(kind: .imported, id: cell.id)
        let state = EditorWindowState(defaults: UserDefaults(suiteName: "Filmstrip-\(UUID())")!)
        let player = state.footagePlayer
        defer { player.unload() }
        state.seekFootage(item, cellID: cell.id, fraction: 0.5)
        #expect(state.selection == item && state.viewerSelection == item)
        #expect(state.currentVersion(for: item) == cell.id)
        await player.load(cell)
        #expect(abs(player.currentTime - 1) < 0.01)
        player.skim(toFraction: 0.75)
        #expect(abs(player.currentTime - 1.5) < 0.01)
        #expect(player.playbackFraction == 0.5)
        player.endSkim()
        #expect(abs(player.currentTime - 1) < 0.01)
        player.skim(toFraction: 0.75)
        state.seekFootage(item, cellID: cell.id, fraction: 0.75)
        player.endSkim()
        #expect(abs(player.currentTime - 1.5) < 0.01)
        player.play()
        state.skimFootage(item, cellID: UUID(), fraction: 0.1)
        #expect(state.footageSkim == nil, "Hover must not replace a playing take")
        player.pause()
    }

    private func descendants(_ value: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
        guard depth < 20, let element = value as? any NSAccessibilityProtocol else { return [] }
        let children = element.accessibilityChildren() ?? element.accessibilityContents() ?? []
        return [element] + children.flatMap { descendants($0, depth: depth + 1) }
    }

    @Test("The narrow viewer keeps metadata above, controls below, and has no slider")
    func compactViewer() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CompactViewer-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let cell = try audioCell(at: url)
        let player = FootagePlayer()
        let host = NSHostingView(rootView: FootageViewer(cell: cell, name: "Harbor sunrise", versions: [cell],
                                                       onSelectVersion: { _ in }, player: player))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close(); player.unload() }
        try await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()
        let elements = descendants(host)
        let name = try #require(elements.first { $0.accessibilityValue() as? String == "Harbor sunrise" || $0.accessibilityLabel() == "Harbor sunrise" })
        let timecode = try #require(elements.first { $0.accessibilityIdentifier() == "viewer.timecode" })
        #expect(name.accessibilityFrame().minY > timecode.accessibilityFrame().maxY)
        #expect(!elements.contains { $0.accessibilityRole() == .slider })
        let timeFrame = timecode.accessibilityFrame()
        #expect(timeFrame.width > 100 && timeFrame.minX >= window.frame.minX && timeFrame.maxX <= window.frame.maxX)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/film-viewer-compact.png"))
    }
}
