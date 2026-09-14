import AppKit
import AVFoundation
import SwiftData
import SwiftUI
import Testing
import VideoEditorCore
@testable import film_workflow

@Suite("Music lyrics context menus and caption editing", .serialized) @MainActor
struct MusicLyricsTests {
    private func document() throws -> ProjectDocument {
        try ProjectDocument.create(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicLyrics-\(UUID()).rxfilmstudio"))
    }

    private func take(in document: ProjectDocument, project: MusicProject? = nil) throws -> GeneratedMusic {
        let project = project ?? MusicProject(name: "Song")
        let context = document.container.mainContext
        context.insert(project)
        let path = "\(ProjectStorage.MediaKind.music.rawValue)/\(UUID()).wav"
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData)[0]
        for index in 0..<Int(buffer.frameLength) { samples[index] = Float(sin(2 * .pi * 440 * Double(index) / 48_000)) * 0.1 }
        try AVAudioFile(forWriting: document.storage.absoluteURL(for: path), settings: format.settings).write(from: buffer)
        let take = GeneratedMusic(audioFilePath: path, lyricsText: "First line\nSecond line", project: project)
        take.durationSeconds = 3
        context.insert(take)
        try context.save()
        return take
    }

    private func captions(in context: ModelContext) throws -> CaptionProject {
        let project = CaptionProject(name: "Translated captions")
        project.languageHint = "en"
        context.insert(project)
        let first = CaptionSegment(startMs: 100, endMs: 900, text: "First line", locale: "en",
                                   words: [.init(text: "First", offsetMs: 100, durationMs: 300),
                                           .init(text: "line", offsetMs: 500, durationMs: 400)])
        context.insert(first); first.project = project
        first.setTranslation("第一行", language: "zh-Hans", isUserEdited: true)
        let second = CaptionSegment(orderIndex: 1, startMs: 1500, endMs: 2800, text: "Second line", locale: "en")
        context.insert(second); second.project = project
        second.setTranslation("第二行", language: "zh-Hans", isUserEdited: true)
        project.ensureVersioned()
        try context.save()
        return project
    }

    @Test("Merging preserves source captions, translations and old lyric versions, and isolates music takes")
    func mergeAndPersistence() async throws {
        let document = try document()
        defer { Task { @MainActor in await document.close() } }
        let context = document.container.mainContext
        let first = try take(in: document)
        let second = try take(in: document, project: first.project)
        let sourceID = DocumentMediaResolver.sourceID(.music, first.id)
        let source = try captions(in: context)
        let lyrics = try await MusicLyrics.prepare(for: sourceID, context: context)
        #expect(!lyrics.ownsAudioFile && lyrics.audioURL == first.audioURL)
        #expect(lyrics.audioDurationMs == 3000)
        try MusicLyrics.merge(source, into: lyrics, context: context)
        #expect(lyrics.orderedSegments.count == 2)
        #expect(lyrics.orderedSegments.first?.words == source.orderedSegments.first?.words)
        #expect(lyrics.orderedSegments.first?.uuid != source.orderedSegments.first?.uuid)
        #expect(lyrics.translatedLanguages == ["zh-Hans"])
        #expect(try MusicLyrics.project(for: DocumentMediaResolver.sourceID(.music, second.id), context: context) == nil)
        let firstVersion = lyrics.activeVersionID
        let edited = try #require(lyrics.orderedSegments.first)
        edited.retime(toStartMs: 300, endMs: 1100)
        edited.text = "Edited lyric"
        lyrics.updatedAt = Date()
        try context.save()
        #expect(source.orderedSegments.first?.startMs == 100 && source.orderedSegments.first?.text == "First line")
        let tracks = try MusicLyrics.tracks(forAudioURL: first.audioURL, context: context)
        #expect(tracks.first?.text(at: 0.2) == "")
        #expect(tracks.first?.text(at: 0.4) == "Edited lyric")
        #expect(tracks.last?.text(at: 0.4) == "第一行")
        try MusicLyrics.merge(source, into: lyrics, context: context)
        #expect(lyrics.versions.count == 2)
        #expect(lyrics.segments.first { $0.versionID == firstVersion } != nil)
        let fresh = ModelContext(document.container)
        let reloaded = try #require(try MusicLyrics.project(for: sourceID, context: fresh))
        #expect(reloaded.activeSegments.count == 2 && reloaded.segments.count == 4)
        #expect(reloaded.orderedSegments.first?.translation("zh-Hans")?.text == "第一行")
        #expect(try await MusicLyrics.prepare(for: sourceID, context: context) === lyrics)
    }

    @Test("Referenced audio gets a portable caption-player copy and draft lyric timings stay within the song")
    func referenceAndDraft() async throws {
        let document = try document()
        defer { Task { @MainActor in await document.close() } }
        let context = document.container.mainContext
        let generated = try take(in: document)
        let external = FileManager.default.temporaryDirectory.appendingPathComponent("Referenced-\(UUID()).wav")
        try FileManager.default.copyItem(at: generated.audioURL, to: external)
        defer { try? FileManager.default.removeItem(at: external) }
        let asset = ImportedAsset(name: "Reference", kind: .audio, originalPath: external.path)
        context.insert(asset)
        let lyrics = try await MusicLyrics.prepare(for: DocumentMediaResolver.sourceID(.imported, asset.id), context: context)
        #expect(lyrics.ownsAudioFile && lyrics.audioURL != external)
        #expect(FileManager.default.fileExists(atPath: lyrics.audioURL.path))
        #expect(abs(lyrics.audioDurationMs - 3000) < 5)
        try MusicLyrics.addLines("One\n\nTwo\nThree", language: "en", to: lyrics, context: context)
        #expect(lyrics.orderedSegments.map(\.startMs) == [0, 1000, 2000])
        #expect(lyrics.orderedSegments.map(\.endMs) == [1000, 2000, 3000])
        #expect(lyrics.activeAlignmentQuality == .estimated)
        #expect(try MusicLyrics.tracks(forAudioURL: external, context: context).first?.text(at: 2.5) == "Three")
        #expect(throws: MusicLyrics.LyricsError.self) {
            try MusicLyrics.addLines("Replace", language: "en", to: lyrics, context: context)
        }
        #expect(lyrics.activeSegments.count == 3)
    }

    @Observable final class Requests { var value: MusicLyricsRequest? }
    private struct Harness: View {
        @Bindable var requests: Requests
        var body: some View { Color.gray.frame(width: 900, height: 750).musicLyricsHost($requests.value) }
    }

    @Test("The real menu merges captions, opens the caption editor and offers retiming from either source")
    func menusAndEditor() async throws {
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let document = try document()
        defer { Task { @MainActor in await document.close() } }
        let take = try take(in: document)
        let sourceID = DocumentMediaResolver.sourceID(.music, take.id)
        let captions = try captions(in: document.container.mainContext)
        let requests = Requests()
        let host = NSHostingView(rootView: Harness(requests: requests).modelContainer(document.container))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 750), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        defer { for sheet in window.sheets { window.endSheet(sheet) }; window.close() }
        let menu = NSHostingMenu(rootView: MusicLyricsContextMenu(sourceID: sourceID) { requests.value = $0 }.modelContainer(document.container))
        menu.update()
        try await Task.sleep(for: .milliseconds(200))
        #expect(menu.items.contains { $0.title == "Add Lyrics Timing…" })
        let merge = try #require(menu.items.first { $0.title == "Merge Captions as Lyrics" }?.submenu)
        merge.update()
        let index = try #require(merge.items.firstIndex { $0.title == captions.name })
        merge.performActionForItem(at: index)
        for _ in 0..<60 where window.attachedSheet == nil { try await Task.sleep(for: .milliseconds(50)) }
        let sheet = try #require(window.attachedSheet)
        try await Task.sleep(for: .milliseconds(300))
        let view = try #require(sheet.contentView)
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/music-lyrics-editor.png"))
        }
        #expect(hostedAccessibilityDescendants(view).contains { $0.accessibilityIdentifier() == "music-lyrics-editor" })
        #expect(hostedAccessibilityDescendants(view).contains { $0.accessibilityIdentifier() == "music-lyrics-translate" })
        let lyrics = try #require(try MusicLyrics.project(for: sourceID, context: document.container.mainContext))
        #expect(lyrics.orderedSegments.count == 2)
        let done = try #require(hostedAccessibilityDescendants(view).first { $0.accessibilityIdentifier() == "music-lyrics-done" })
        #expect(done.accessibilityPerformPress())
        for _ in 0..<40 where window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(50)) }
        let updated = NSHostingMenu(rootView: MusicLyricsContextMenu(sourceID: sourceID) { requests.value = $0 }.modelContainer(document.container))
        updated.update()
        let retime = try #require(updated.items.firstIndex { $0.title == "Retime Lyrics…" })
        updated.performActionForItem(at: retime)
        for _ in 0..<60 where window.attachedSheet == nil { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(300))
        let retimer = try #require(window.attachedSheet?.contentView)
        #expect(hostedAccessibilityDescendants(retimer).contains { $0.accessibilityLabel() == "Retime Lyrics" || $0.accessibilityValue() as? String == "Retime Lyrics" })
        let play = try #require(hostedAccessibilityDescendants(retimer).first { $0.accessibilityIdentifier() == "caption-retime-play" })
        #expect(play.accessibilityPerformPress())
        try await Task.sleep(for: .milliseconds(400))
        #expect(play.accessibilityPerformPress())
        let boundary = try #require(hostedAccessibilityDescendants(retimer).first { $0.accessibilityIdentifier() == "caption-retime-set-boundary" })
        #expect(boundary.accessibilityPerformPress())
        try await Task.sleep(for: .milliseconds(100))
        let save = try #require(hostedAccessibilityDescendants(retimer).first { $0.accessibilityIdentifier() == "caption-retime-save" })
        #expect(save.accessibilityPerformPress())
        for _ in 0..<40 where window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try #require(lyrics.orderedSegments.first).startMs > 100)
        #expect(captions.orderedSegments.first?.startMs == 100)
        let fresh = ModelContext(document.container)
        #expect(try MusicLyrics.project(for: sourceID, context: fresh)?.orderedSegments.first?.startMs == lyrics.orderedSegments.first?.startMs)
        let captionMenu = NSHostingMenu(rootView: MusicLyricsContextMenu(sourceID: DocumentMediaResolver.sourceID(.caption, captions.projectUUID)) { requests.value = $0 }.modelContainer(document.container))
        captionMenu.update()
        #expect(captionMenu.items.contains { $0.title == "Merge as Lyrics into Music" })
    }

    @Test("Music preview follows saved lyric retiming, selectable translations and caption gaps")
    func preview() async throws {
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let document = try document()
        defer { Task { @MainActor in await document.close() } }
        let context = document.container.mainContext
        let take = try take(in: document)
        let sourceID = DocumentMediaResolver.sourceID(.music, take.id)
        let lyrics = try await MusicLyrics.prepare(for: sourceID, context: context)
        try MusicLyrics.merge(captions(in: context), into: lyrics, context: context)
        let cell = FootageCell(id: take.id, title: "v1", subtitle: "3s", footage: take)
        let player = FootagePlayer()
        await player.load(cell)
        let host = NSHostingView(rootView: MusicLyricsPlayback(sourceID: sourceID, player: player).modelContainer(document.container).background(.black))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 220), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        defer { player.unload(); window.close() }
        func current() -> String? {
            let caption = hostedAccessibilityDescendants(host).first { $0.accessibilityIdentifier() == "music-lyrics-caption" }
            return caption?.accessibilityValue() as? String ?? caption?.accessibilityLabel() ?? ""
        }
        player.seek(to: 0.5)
        try await Task.sleep(for: .milliseconds(200))
        #expect(current() == "First line")
        player.seek(to: 1.2)
        try await Task.sleep(for: .milliseconds(150))
        #expect(current() == "")
        player.seek(to: 2)
        try await Task.sleep(for: .milliseconds(150))
        #expect(current() == "Second line")
        func popups(_ view: NSView) -> [NSPopUpButton] {
            view.subviews.flatMap { ($0 as? NSPopUpButton).map { [$0] } ?? popups($0) }
        }
        let languages = try #require(popups(host).first?.menu)
        languages.performActionForItem(at: 2)
        try await Task.sleep(for: .milliseconds(150))
        #expect(current() == "第二行")
        lyrics.orderedSegments[1].retime(toStartMs: 2200, endMs: 2900)
        lyrics.updatedAt = Date()
        try context.save()
        try await Task.sleep(for: .milliseconds(200))
        #expect(current() == "")
        player.seek(to: 2.5)
        try await Task.sleep(for: .milliseconds(150))
        #expect(current() == "第二行")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/music-lyrics-preview.png"))
        }
        languages.performActionForItem(at: 0)
        try await Task.sleep(for: .milliseconds(150))
        #expect(current() == "")
    }
}
