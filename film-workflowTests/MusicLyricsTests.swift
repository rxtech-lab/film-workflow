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

    @Test("Removing lyrics detaches only that recording and preserves captions, versions and audio")
    func removeLyrics() async throws {
        let document = try document()
        defer { Task { @MainActor in await document.close() } }
        let context = document.container.mainContext
        let first = try take(in: document)
        let second = try take(in: document, project: first.project)
        let source = try captions(in: context)
        let firstID = DocumentMediaResolver.sourceID(.music, first.id)
        let secondID = DocumentMediaResolver.sourceID(.music, second.id)
        let lyrics = try await MusicLyrics.prepare(for: firstID, context: context)
        let otherLyrics = try await MusicLyrics.prepare(for: secondID, context: context)
        try MusicLyrics.merge(source, into: lyrics, context: context)
        try MusicLyrics.merge(source, into: lyrics, context: context)
        try MusicLyrics.merge(source, into: otherLyrics, context: context)
        try MusicLyrics.remove(from: firstID, context: context)
        let fresh = ModelContext(document.container)
        #expect(try MusicLyrics.project(for: firstID, context: fresh) == nil)
        #expect(try MusicLyrics.project(for: secondID, context: fresh)?.activeSegmentCount == 2)
        let id = lyrics.projectUUID
        let detached = try #require(try fresh.fetch(FetchDescriptor<CaptionProject>(predicate: #Predicate { $0.projectUUID == id })).first)
        #expect(detached.versions.count == 2 && detached.segments.count == 4)
        #expect(detached.orderedSegments.first?.translation("zh-Hans")?.text == "第一行")
        #expect(source.orderedSegments.count == 2)
        #expect(FileManager.default.fileExists(atPath: first.audioURL.path))
        #expect(try MusicLyrics.tracks(forAudioURL: first.audioURL, context: fresh).isEmpty)
        #expect(try MusicLyrics.tracks(forAudioURL: second.audioURL, context: fresh).count == 2)
        try MusicLyrics.remove(from: firstID, context: context)
        let replacement = try await MusicLyrics.prepare(for: firstID, context: context)
        #expect(replacement.projectUUID != detached.projectUUID && replacement.activeSegmentCount == 0)
    }

    @Test("The original-language picker updates the current lyrics version and published metadata")
    func originalLanguagePicker() async throws {
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let document = try document()
        defer { Task { @MainActor in await document.close() } }
        let context = document.container.mainContext
        let take = try take(in: document)
        let source = try captions(in: context)
        source.versions[0].languageCode = "und"
        source.languageHint = ""
        let sourceID = DocumentMediaResolver.sourceID(.music, take.id)
        let lyrics = try await MusicLyrics.prepare(for: sourceID, context: context)
        try MusicLyrics.merge(source, into: lyrics, context: context)
        try CaptionLanguage.setOriginal("ja", for: lyrics, context: context)
        let previousVersion = try #require(lyrics.activeVersionID)
        try MusicLyrics.merge(source, into: lyrics, context: context)
        lyrics.languageHint = "ru"
        try context.save()
        #expect(lyrics.sourceLanguageCode.isEmpty)
        #expect(MusicLyrics.tracks(for: lyrics).first?.language == "und")
        let host = NSHostingView(rootView: MusicLyricsInspector(project: lyrics).modelContainer(document.container))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 460, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        for _ in 0..<60 {
            if hostedAccessibilityDescendants(host).contains(where: { $0.accessibilityIdentifier() == "caption-original-language" }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try choose(CaptionTranslationAvailability.displayName("en"), in: host)
        for _ in 0..<40 where lyrics.sourceLanguageCode != "en" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(lyrics.sourceLanguageCode == "en")
        #expect(lyrics.languageHint == "ru")
        #expect(lyrics.activeSegments.allSatisfy { $0.locale == "en" })
        #expect(lyrics.versions.first { $0.id == previousVersion }?.languageCode == "ja")
        #expect(lyrics.segments.filter { $0.versionID == previousVersion }.allSatisfy { $0.locale == "ja" })
        #expect(source.sourceLanguageCode.isEmpty)
        let fresh = ModelContext(document.container)
        let saved = try #require(try MusicLyrics.project(for: sourceID, context: fresh))
        let tracks = MusicLyrics.tracks(for: saved)
        #expect(tracks.map(\.language) == ["en", "zh-Hans"])
        #expect(tracks[0].cues[0].text == "First line" && tracks[0].cues[0].start == 0.1)
        #expect(tracks[1].cues[0].text == "第一行")

        try CaptionLanguage.setOriginal("", for: lyrics, context: context)
        #expect(lyrics.sourceLanguageCode.isEmpty && lyrics.activeVersion?.languageCode == "und")
        try CaptionLanguage.setOriginal(" zh_hans ", for: lyrics, context: context)
        #expect(lyrics.sourceLanguageCode == "zh-Hans")
        #expect(throws: (any Error).self) { try CaptionLanguage.setOriginal("en!", for: lyrics, context: context) }
        #expect(lyrics.sourceLanguageCode == "zh-Hans")
    }

    private func waitForSheet(on window: NSWindow) async throws -> NSWindow {
        for _ in 0..<60 {
            if let sheet = window.attachedSheet { return sheet }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try #require(window.attachedSheet)
    }

    private func press(_ label: String, in view: NSView) async throws {
        func find() -> HostedAccessibilityElement? {
            hostedAccessibilityDescendants(view).first {
                $0.accessibilityRole() == .button && $0.accessibilityLabel() == label
            }
        }
        for _ in 0..<60 {
            if find() != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let button = try #require(find(), "Expected the visible button: \(label)")
        _ = button.accessibilityPerformPress()
    }

    private func choose(_ title: String, in view: NSView) throws {
        func popups(_ view: NSView) -> [NSPopUpButton] {
            view.subviews.flatMap { ($0 as? NSPopUpButton).map { [$0] } ?? popups($0) }
        }
        let menu = try #require(popups(view).first?.menu)
        let index = try #require(menu.items.firstIndex { $0.title == title })
        menu.performActionForItem(at: index)
    }

    @Observable final class Requests { var value: MusicLyricsRequest? }

    private struct InspectorHarness: View {
        let document: ProjectDocument
        let state: EditorWindowState
        let sequence: SequenceProject
        @Query private var music: [MusicProject]
        @Query private var captions: [CaptionProject]
        @Query private var imported: [ImportedAsset]

        var body: some View {
            InspectorPanel(index: LibraryIndex(music: music, captions: captions, imported: imported),
                           state: state, document: document, sequence: sequence, onRender: {})
        }
    }

    @Test("The inspector displays the selected recording's merged lyrics from the library and timeline")
    func inspectorLyrics() async throws {
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let document = try document()
        defer { Task { @MainActor in await document.close() } }
        let context = document.container.mainContext
        let first = try take(in: document)
        let second = try take(in: document, project: first.project)
        second.createdAt = first.createdAt.addingTimeInterval(1)
        let music = try #require(first.project)
        let source = try captions(in: context)
        let firstID = DocumentMediaResolver.sourceID(.music, first.id)
        let lyrics = try await MusicLyrics.prepare(for: firstID, context: context)
        try MusicLyrics.merge(source, into: lyrics, context: context)
        lyrics.displayedTranslationLanguage = "zh-Hans"
        let sequence = SequenceProject(name: "Cut")
        var timeline = sequence.timeline
        let track = try #require(timeline.tracks.first { $0.kind == .audio })
        let clip = Clip(source: first.dragItem.source, start: 0, duration: 3, sourceDuration: 3)
        try TimelineEditor.insert(&timeline, clip: clip, on: track.id)
        sequence.timeline = timeline
        context.insert(sequence)
        try context.save()
        let state = EditorWindowState(defaults: UserDefaults(suiteName: "LyricsInspector-\(UUID())")!)
        state.select(music.libraryItemID)
        let host = NSHostingView(rootView: InspectorHarness(document: document, state: state, sequence: sequence)
            .modelContainer(document.container))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 460, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }

        func textVisible(_ text: String) -> Bool {
            hostedAccessibilityDescendants(host).contains {
                $0.accessibilityValue() as? String == text || $0.accessibilityLabel() == text
            }
        }
        func waitForText(_ text: String) async throws {
            for _ in 0..<60 {
                if textVisible(text) { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(textVisible(text), "Expected the inspector to show: \(text)")
        }
        func inspectorContext() throws -> InspectorContext {
            InspectorContext(document: document, state: state,
                             index: LibraryIndex(music: [music], captions: try context.fetch(FetchDescriptor<CaptionProject>())),
                             sequence: sequence, onRender: {})
        }

        // The library defaults to the newest take, which has no linked lyrics.
        try await Task.sleep(for: .milliseconds(200))
        #expect(try inspectorContext().sourceID == DocumentMediaResolver.sourceID(.music, second.id))
        #expect(try inspectorContext().lyricsProject == nil)
        #expect(!textVisible("First line"))

        state.setCurrentVersion(first.id, for: music.libraryItemID)
        try await waitForText("First line")
        try await waitForText("第一行")
        #expect(state.inspectorTabID == InspectorTabResolver.lyricsTabID)
        #expect(hostedAccessibilityDescendants(host).contains { $0.accessibilityIdentifier() == "music-lyrics-translate" })

        // Changing a tab manually still works while this recording stays selected.
        let settings = try #require(hostedAccessibilityDescendants(host).first { $0.accessibilityLabel() == "Settings" })
        // AppKit's segment can perform the action while returning false; the
        // selected tab is the observable result that matters here.
        _ = settings.accessibilityPerformPress()
        try await Task.sleep(for: .milliseconds(100))
        #expect(state.inspectorTabID == InspectorTabResolver.settingsTabID)

        // A merge into the selected take appears without selecting it again.
        state.setCurrentVersion(second.id, for: music.libraryItemID)
        let secondLyrics = try await MusicLyrics.prepare(for: DocumentMediaResolver.sourceID(.music, second.id), context: context)
        source.orderedSegments[0].text = "Second recording lyric"
        try MusicLyrics.merge(source, into: secondLyrics, context: context)
        try await waitForText("Second recording lyric")
        #expect(!textVisible("First line"))

        // The timeline points at the older take even while the library holds v2.
        state.selectedClipID = clip.id
        try await waitForText("First line")
        #expect(!textVisible("Second recording lyric"))
        #expect(try inspectorContext().sourceID == firstID)
        #expect(try inspectorContext().footage === music)
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/music-lyrics-inspector.png"))
        }

        // Clicking the library's already-current v2 must release the clip selection.
        state.setCurrentVersion(second.id, for: music.libraryItemID)
        try await waitForText("Second recording lyric")
        #expect(state.selectedClipIDs.isEmpty)
        #expect(!textVisible("First line"))

        // Imported audio uses the same panel, without a music project.
        let asset = ImportedAsset(name: "Imported song", kind: .audio, originalPath: first.audioURL.path)
        context.insert(asset)
        let importedLyrics = try await MusicLyrics.prepare(for: DocumentMediaResolver.sourceID(.imported, asset.id), context: context)
        try MusicLyrics.merge(source, into: importedLyrics, context: context)
        state.select(asset.libraryItemID)
        try await waitForText("Second recording lyric")
        #expect(state.selectedClipIDs.isEmpty)
        #expect(state.inspectorTabID == InspectorTabResolver.lyricsTabID)

        state.selectedClipIDs = [clip.id, UUID()]
        try await Task.sleep(for: .milliseconds(100))
        #expect(try inspectorContext().lyricsProject == nil)
        #expect(!textVisible("Second recording lyric"))

        state.select(asset.libraryItemID)
        try await waitForText("Second recording lyric")
        let remove = try #require(hostedAccessibilityDescendants(host).first { $0.accessibilityIdentifier() == "music-lyrics-remove" })
        _ = remove.accessibilityPerformPress()
        let cancelAlert = try await waitForSheet(on: window)
        #expect(importedLyrics.lyricsSourceID != nil)
        try await press("Cancel", in: try #require(cancelAlert.contentView))
        for _ in 0..<40 where window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(importedLyrics.lyricsSourceID != nil)
        _ = remove.accessibilityPerformPress()
        let removeAlert = try await waitForSheet(on: window)
        try await press("Remove Lyrics", in: try #require(removeAlert.contentView))
        for _ in 0..<40 where importedLyrics.lyricsSourceID != nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(importedLyrics.lyricsSourceID == nil)
        #expect(importedLyrics.activeSegmentCount == 2)
        #expect(FileManager.default.fileExists(atPath: importedLyrics.audioURL.path))
        #expect(try MusicLyrics.project(for: DocumentMediaResolver.sourceID(.imported, asset.id), context: ModelContext(document.container)) == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!textVisible("Second recording lyric"))
    }

    private struct Harness: View {
        @Bindable var requests: Requests
        var body: some View { Color.gray.frame(width: 900, height: 750).musicLyricsHost($requests.value) }
    }

    @Test("The real menu merges captions, opens the caption editor and offers retiming from either source")
    func menusAndEditor() async throws {
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let document = try document()
        defer { Task { @MainActor in await document.close() } }
        let firstTake = try take(in: document)
        let take = try take(in: document, project: firstTake.project)
        let sourceID = DocumentMediaResolver.sourceID(.music, take.id)
        let captions = try captions(in: document.container.mainContext)
        let requests = Requests()
        let host = NSHostingView(rootView: Harness(requests: requests).modelContainer(document.container))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 750), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        defer { for sheet in window.sheets { window.endSheet(sheet) }; window.close() }
        let menu = NSHostingMenu(rootView: MusicLyricsContextMenu(sourceID: DocumentMediaResolver.sourceID(.music, firstTake.id)) { requests.value = $0 }.modelContainer(document.container))
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
        // The context menu preselects the destination, but only the Merge
        // button and its second confirmation may write a lyric version.
        #expect(try MusicLyrics.project(for: sourceID, context: document.container.mainContext) == nil)
        #expect(hostedAccessibilityDescendants(view).contains { $0.accessibilityIdentifier() == "music-lyrics-target-picker" })
        let target = try #require(MusicLyrics.targets(music: [firstTake, take], imported: []).first { $0.id == sourceID })
        try choose(target.title, in: view)
        try await Task.sleep(for: .milliseconds(100))
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/music-lyrics-merge-picker.png"))
        }
        let mergeButton = try #require(hostedAccessibilityDescendants(view).first { $0.accessibilityIdentifier() == "music-lyrics-merge" })
        _ = mergeButton.accessibilityPerformPress()
        let cancelConfirmation = try await waitForSheet(on: sheet)
        #expect(try MusicLyrics.project(for: sourceID, context: document.container.mainContext) == nil)
        try await press("Cancel", in: try #require(cancelConfirmation.contentView))
        for _ in 0..<40 where sheet.attachedSheet != nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try MusicLyrics.project(for: sourceID, context: document.container.mainContext) == nil)
        _ = mergeButton.accessibilityPerformPress()
        let confirmation = try await waitForSheet(on: sheet)
        try await press("Merge", in: try #require(confirmation.contentView))
        for _ in 0..<60 {
            if hostedAccessibilityDescendants(view).contains(where: { $0.accessibilityIdentifier() == "music-lyrics-done" }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/music-lyrics-editor.png"))
        }
        #expect(hostedAccessibilityDescendants(view).contains { $0.accessibilityIdentifier() == "music-lyrics-editor" })
        #expect(hostedAccessibilityDescendants(view).contains { $0.accessibilityIdentifier() == "music-lyrics-translate" })
        let lyrics = try #require(try MusicLyrics.project(for: sourceID, context: document.container.mainContext))
        #expect(try MusicLyrics.project(for: DocumentMediaResolver.sourceID(.music, firstTake.id), context: document.container.mainContext) == nil)
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

    @Test("Choosing captions for music does not attach lyrics until Merge is confirmed")
    func captionPickerConfirmation() async throws {
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let document = try document()
        defer { Task { @MainActor in await document.close() } }
        let context = document.container.mainContext
        let take = try take(in: document)
        let sourceID = DocumentMediaResolver.sourceID(.music, take.id)
        let first = try captions(in: context)
        first.name = "A captions"
        let second = try captions(in: context)
        second.name = "B captions"
        second.orderedSegments[0].text = "Chosen caption"
        try context.save()
        let requests = Requests()
        let host = NSHostingView(rootView: Harness(requests: requests).modelContainer(document.container))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 750), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { for sheet in window.sheets { window.endSheet(sheet) }; window.close() }
        requests.value = .init(sourceID: sourceID, action: .chooseCaptions)
        let sheet = try await waitForSheet(on: window)
        try await Task.sleep(for: .milliseconds(200))
        let view = try #require(sheet.contentView)
        try choose(second.name, in: view)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try MusicLyrics.project(for: sourceID, context: context) == nil)
        let merge = try #require(hostedAccessibilityDescendants(view).first { $0.accessibilityIdentifier() == "music-lyrics-merge" })
        _ = merge.accessibilityPerformPress()
        let confirmation = try await waitForSheet(on: sheet)
        #expect(try MusicLyrics.project(for: sourceID, context: context) == nil)
        try await press("Merge", in: try #require(confirmation.contentView))
        for _ in 0..<60 where try MusicLyrics.project(for: sourceID, context: context)?.activeSegmentCount != 2 {
            try await Task.sleep(for: .milliseconds(50))
        }
        let lyrics = try #require(try MusicLyrics.project(for: sourceID, context: context))
        #expect(lyrics.orderedSegments.first?.text == "Chosen caption")
        #expect(lyrics.versions.count == 1)
        #expect(first.orderedSegments.first?.text == "First line")
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
