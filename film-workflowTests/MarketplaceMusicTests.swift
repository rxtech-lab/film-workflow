import AppKit
import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import film_workflow

@Suite("Marketplace music playback and lyrics", .serialized) @MainActor
struct MarketplaceMusicTests {
    private let srt = "1\n00:00:00,000 --> 00:00:01,000\nFirst line\n\n2\n00:00:01,500 --> 00:00:03,000\nSecond line"

    @Test("Caption import preserves timing, translations, gaps, and old metadata")
    func captions() throws {
        let original = try MarketplaceLyricTrack.parse(srt, language: "en")
        let translation = try MarketplaceLyricTrack.parse("WEBVTT\n\n00:00.000 --> 00:01.000 align:center\n第一行\n\n00:01.500 --> 00:03.000\n第二行", language: "zh-Hans")
        #expect(original.text(at: 0.5) == "First line")
        #expect(original.text(at: 1) == "")
        #expect(original.text(at: 1.5) == "Second line")
        #expect(translation.text(at: 1.5) == "第二行")
        var metadata = MarketplaceItemMetadata()
        metadata.lyricTracks = [original, translation]
        metadata.preview = .init(startSeconds: 1.5)
        let encoded = try JSONEncoder().encode(metadata)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        #expect(try decoder.decode(MarketplaceItemMetadata.self, from: encoded) == metadata)
        #expect(try decoder.decode(MarketplaceItemMetadata.self, from: Data("{}".utf8)).lyricTracks == nil)
    }

    @Test("Malformed caption files fail without creating empty tracks")
    func invalidCaptions() {
        for text in ["plain lyrics", "", "1\n00:00:02,000 --> 00:00:01,000\nBackwards", "1\n00:61:00,000 --> 00:62:00,000\nInvalid", "1\n00:00:00,000 --> 00:00:01,000\n"] {
            #expect(throws: (any Error).self) { try MarketplaceLyricTrack.parse(text, language: "en") }
        }
    }

    @Test("An audio item without a preview video plays through the detail controls, pauses, seeks, replays and unloads")
    func audioPlayback() async throws {
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MarketplaceMusic-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tone.wav")
        try tone(url)
        var metadata = MarketplaceItemMetadata(durationSeconds: 3)
        metadata.lyricTracks = [try MarketplaceLyricTrack.parse(srt, language: "en"),
                                try MarketplaceLyricTrack.parse(srt.replacingOccurrences(of: "Second line", with: "第二行"), language: "zh-Hans")]
        let item = MarketplaceItem(id: "music", kind: .audio, category: "test", title: "Music without video", contentFilename: "tone.wav", metadata: metadata)
        let transport = FakeMarketplaceTransport(page: .init(items: [item]), downloadFile: url)
        let store = MarketplaceStore(client: MarketplaceClient(transport: transport), root: root.appendingPathComponent("installed"))
        let playback = MarketplaceAudioPlayer()
        let host = NSHostingView(rootView: MarketplaceMusicPreview(item: item, resolveSource: { try await store.audioPreviewSource(for: item) }, playback: playback))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        defer { playback.unload(); window.close() }
        try await Task.sleep(for: .milliseconds(300))
        let play = try #require(hostedAccessibilityDescendants(host).first { $0.accessibilityIdentifier() == "marketplace-music-play" })
        #expect(play.accessibilityPerformPress())
        for _ in 0..<100 where playback.currentTime < 0.2 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(playback.error == nil)
        #expect(playback.isPlaying && playback.currentTime >= 0.2)
        #expect(!playback.player.isMuted && playback.player.volume > 0)
        #expect(transport.downloadCalls == 1)
        let caption = try #require(hostedAccessibilityDescendants(host).first { $0.accessibilityIdentifier() == "marketplace-music-caption" })
        #expect(caption.accessibilityValue() as? String == "First line" || caption.accessibilityLabel() == "First line")
        let pause = try #require(hostedAccessibilityDescendants(host).first { $0.accessibilityIdentifier() == "marketplace-music-play" })
        #expect(pause.accessibilityPerformPress())
        #expect(!playback.isPlaying)
        playback.seek(to: 2)
        try await Task.sleep(for: .milliseconds(150))
        #expect(abs(playback.currentTime - 2) < 0.1)
        let secondCaption = try #require(hostedAccessibilityDescendants(host).first { $0.accessibilityIdentifier() == "marketplace-music-caption" })
        #expect(secondCaption.accessibilityValue() as? String == "Second line" || secondCaption.accessibilityLabel() == "Second line")
        func popups(_ view: NSView) -> [NSPopUpButton] {
            view.subviews.flatMap { ($0 as? NSPopUpButton).map { [$0] } ?? popups($0) }
        }
        let language = try #require(popups(host).first)
        #expect(language.numberOfItems == 3)
        let menu = try #require(language.menu)
        menu.performActionForItem(at: 2)
        try await Task.sleep(for: .milliseconds(100))
        let translatedCaption = try #require(hostedAccessibilityDescendants(host).first { $0.accessibilityIdentifier() == "marketplace-music-caption" })
        #expect(translatedCaption.accessibilityValue() as? String == "第二行" || translatedCaption.accessibilityLabel() == "第二行")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/marketplace-music-preview.png"))
        }
        playback.seek(to: playback.duration)
        playback.toggle { (url, 0) }
        for _ in 0..<40 where !playback.isPlaying { try await Task.sleep(for: .milliseconds(50)) }
        #expect(playback.isPlaying && playback.currentTime < 1)
        window.contentView = NSView()
        for _ in 0..<20 where playback.player.currentItem != nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(playback.player.currentItem == nil && !playback.isPlaying)
    }

    @Test("Public excerpts preserve lyric offset and paid content requires entitlement")
    func sources() async throws {
        let url = URL(fileURLWithPath: "/tmp/music-preview.wav")
        let transport = FakeMarketplaceTransport(page: .init(), downloadFile: url)
        let store = MarketplaceStore(client: MarketplaceClient(transport: transport), root: url.appendingPathComponent(UUID().uuidString))
        var metadata = MarketplaceItemMetadata(); metadata.preview = .init(startSeconds: 42)
        let preview = MarketplaceItem(id: "paid-preview", kind: .audio, category: "test", title: "Song", pricePoints: 100, previewVideoUrl: url, metadata: metadata)
        let source = try await store.audioPreviewSource(for: preview)
        #expect(source.url == url && source.start == 42 && transport.downloadCalls == 0)
        let paid = MarketplaceItem(id: "paid", kind: .audio, category: "test", title: "Song", pricePoints: 100)
        await #expect(throws: MarketplaceError.self) { try await store.audioPreviewSource(for: paid) }
        #expect(transport.downloadCalls == 0)
    }

    private func tone(_ url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData)[0]
        for index in 0..<Int(buffer.frameLength) { samples[index] = Float(sin(2 * .pi * 440 * Double(index) / 48_000)) * 0.1 }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }
}
