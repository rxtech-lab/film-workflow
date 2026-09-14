import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import VideoEditorCore

@MainActor private final class LiveFixtureResolver: TimelinePreviewResolver {
    var released = false
    var renders = 0
    var fail = false
    func preview(_ source: ClipSource) async throws -> TimelinePreviewSource {
        if fail { throw MediaResolverError.missing(source) }
        return .live(LivePreviewDescriptor(url: URL(string: "http://localhost:8123/preview/")!, fps: 24,
                                          frames: 240, width: 320, height: 180))
    }
    func renderedPreview(_ source: ClipSource, progress: @escaping @MainActor (String) -> Void) async throws -> ResolvedMedia {
        renders += 1
        progress("Rendering fixture")
        return .captions([])
    }
    func release() { released = true }
}

@Suite("Live timeline preview") @MainActor
struct LivePreviewTests {
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(predicate(), "Preview did not reach the expected state")
    }

    @Test("Instances share source resolution but keep independent source clocks across cuts and speeds")
    func instances() async throws {
        let source = ClipSource(id: "remotion:fixture", kind: .remotion, displayName: "Fixture")
        let first = Clip(source: source, start: 0, duration: 3, inPoint: 1, playbackRate: 2, sourceDuration: 10)
        let second = Clip(source: source, start: 0, duration: 4, inPoint: 4, playbackRate: 0.5, sourceDuration: 10)
        let timeline = Timeline(width: 320, height: 180, fps: 60, tracks: [
            Track(kind: .video, name: "Top", clips: [second]), Track(kind: .video, name: "Bottom", clips: [first])])
        let transport = TimelinePlayerController()
        let preview = TimelinePreviewController(transport: transport)
        let resolver = LiveFixtureResolver()
        preview.setVisible(true); preview.load(timeline, resolver: resolver)
        defer { preview.unload(); transport.unload() }
        try await wait { preview.layers.count == 2 && !transport.isLoading }
        #expect(preview.layers.map(\.id) == [first.id, second.id])
        let a = try #require(preview.layers[0].live), b = try #require(preview.layers[1].live)
        #expect(a !== b)
        a.received(type: "ready"); b.received(type: "ready")
        transport.seek(to: 1)
        #expect(a.command.frame == 72) // (1 + 1 * 2) * 24, independent of sequence's 60 fps.
        #expect(b.command.frame == 108)
        transport.seek(to: 3)
        #expect(!preview.layers[0].active && preview.layers[1].active)
        #expect(!a.command.playing && a.command.muted)
        transport.seek(to: 15)
        #expect(preview.layers.allSatisfy { !$0.active && !$0.mounted })
        #expect(transport.currentTime == 15)
    }

    @Test("Live preview follows the reordered video and overlay tracks")
    func reorderedLayers() async throws {
        let source = ClipSource(id: "still", kind: .image, displayName: "Still")
        let overlay = Track(kind: .overlay, name: "T1", clips: [Clip(source: source, start: 0, duration: 3)])
        let video = Track(kind: .video, name: "V1", clips: [Clip(source: source, start: 0, duration: 3)])
        var timeline = Timeline(tracks: [overlay, video])
        let transport = TimelinePlayerController()
        let preview = TimelinePreviewController(transport: transport)
        let resolver = LiveFixtureResolver()
        defer { preview.unload(); transport.unload() }
        preview.load(timeline, resolver: resolver)
        try await wait { !preview.isLoading }
        #expect(preview.layers.map(\.id) == [video.clips[0].id, overlay.clips[0].id])
        try TimelineEditor.reorderTracks(&timeline, trackIDs: [video.id, overlay.id])
        preview.load(timeline, resolver: resolver)
        try await wait { !preview.isLoading }
        #expect(preview.layers.map(\.id) == [overlay.clips[0].id, video.clips[0].id])
    }

    @Test("One buffering layer stops every surface without losing play intent")
    func buffering() async throws {
        let source = ClipSource(id: "live", kind: .remotion, displayName: "Live")
        let clip = Clip(source: source, start: 0, duration: 5)
        let timeline = Timeline(width: 320, height: 180, tracks: [Track(kind: .video, name: "V1", clips: [clip])])
        let transport = TimelinePlayerController(), resolver = LiveFixtureResolver()
        let preview = TimelinePreviewController(transport: transport)
        preview.setVisible(true); preview.load(timeline, resolver: resolver)
        defer { preview.unload(); transport.unload() }
        // The sequence audio item must be ready to play, or the transport is
        // blocked on it rather than on the live layer under test.
        try await wait { preview.layers.count == 1 && !transport.isLoading && transport.player.currentItem?.status == .readyToPlay }
        let live = try #require(preview.layers.first?.live)
        live.received(type: "ready")
        transport.play()
        #expect(live.command.playing)
        live.received(type: "buffering", buffering: true)
        #expect(transport.isPlaying && transport.isBuffering && transport.player.rate == 0)
        #expect(!live.command.playing)
        transport.pause()
        live.received(type: "buffering", buffering: false)
        #expect(!transport.isPlaying && !transport.isBuffering && !live.command.playing)
        transport.seek(to: 2)
        live.received(type: "building")
        #expect(!live.ready && transport.isBuffering && transport.currentTime == 2)
        live.received(type: "error", message: "Syntax error")
        #expect(live.error == "Syntax error" && resolver.renders == 0)
        live.received(type: "ready")
        #expect(!transport.isBuffering && live.command.frame == 48)
    }

    @Test("Unsupported playback shares one fallback and does not modify clip edits")
    func fallback() async throws {
        let source = ClipSource(id: "live", kind: .remotion, displayName: "Live")
        let clip = Clip(source: source, start: 0, duration: 0.5, playbackRate: 20, volume: 1.5)
        let timeline = Timeline(width: 320, height: 180, tracks: [Track(kind: .video, name: "V1", clips: [clip])])
        let transport = TimelinePlayerController(), resolver = LiveFixtureResolver()
        let preview = TimelinePreviewController(transport: transport)
        preview.setVisible(true); preview.load(timeline, resolver: resolver)
        defer { preview.unload(); transport.unload() }
        try await wait { !preview.isLoading && preview.layers.count == 1 }
        preview.layers.first?.live?.received(type: "ready")
        try await wait { resolver.renders == 1 && preview.layers.first?.live == nil && !preview.isLoading }
        #expect(preview.timeline == timeline)
        #expect(preview.layers.first?.clip == clip)
        for _ in 0..<5 { preview.synchronize() }
        #expect(resolver.renders == 1)
    }

    @Test("A failed replacement clears old surfaces and releases resolver leases")
    func failureAndCleanup() async throws {
        let source = ClipSource(id: "live", kind: .remotion, displayName: "Live")
        let timeline = Timeline(tracks: [Track(kind: .video, name: "V1", clips: [Clip(source: source, start: 0, duration: 1)])])
        let transport = TimelinePlayerController(), first = LiveFixtureResolver(), second = LiveFixtureResolver()
        let preview = TimelinePreviewController(transport: transport)
        preview.load(timeline, resolver: first)
        try await wait { !preview.isLoading }
        second.fail = true
        preview.load(timeline, resolver: second)
        try await wait { preview.lastError != nil }
        #expect(preview.layers.isEmpty && first.released)
        preview.unload(); transport.unload()
        #expect(second.released)
    }

    @Test("Shared placement respects export coordinates, fit, fill, stretch and offsets")
    func geometry() {
        let source = CGSize(width: 100, height: 100), canvas = CGSize(width: 400, height: 200)
        #expect(PreviewGeometry.placement(source: source, canvas: canvas, transform: .identity) == CGRect(x: 100, y: 0, width: 200, height: 200))
        #expect(PreviewGeometry.placement(source: source, canvas: canvas, transform: ClipTransform(fit: .fill)) == CGRect(x: 0, y: -100, width: 400, height: 400))
        #expect(PreviewGeometry.placement(source: source, canvas: canvas, transform: ClipTransform(fit: .stretch, scale: 0.5, offsetX: 0.25, offsetY: -0.25)) == CGRect(x: 200, y: 0, width: 200, height: 100))
    }
}
