import AppKit
import AVFoundation
import FilmTemplateKit
import SwiftData
import SwiftUI
import Testing
import VideoEditorCore

@testable import film_workflow

@Suite("Wizard preview", .serialized) @MainActor
struct SimpleModePreviewTests {
    @Test("A stored timeline update replaces the empty cached cut")
    func refreshesCachedTimeline() throws {
        let sequence = SequenceProject(name: "First cut")
        #expect(sequence.timeline.allClips.isEmpty)
        var updated = sequence.timeline
        let clip = Clip(source: .init(id: "remotion:test", kind: .remotion, displayName: "Title"), start: 0, duration: 4)
        try TimelineEditor.insert(&updated, clip: clip, on: #require(updated.tracks.first { $0.kind == .video }).id)
        // SwiftData can refresh the stored property after an agent saves in a
        // different context, without invoking the computed timeline setter.
        sequence.timelineData = try TimelineCodec.encode(updated)
        #expect(sequence.timeline.duration == 4)
        #expect(sequence.timeline.allClips.map(\.id) == [clip.id])
    }

    @Test("The wizard plays and seeks an unrendered Remotion cut")
    func livePlayback() async throws {
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WizardPreview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let document = try ProjectDocument.create(at: root.appendingPathComponent("Preview.rxfilmstudio"))
        let context = document.container.mainContext
        let project = RemotionProject(name: "Changing color")
        project.durationSeconds = 4
        project.compositionWidth = 320; project.compositionHeight = 180; project.compositionFps = 10
        context.insert(project)
        project.compositionSource = """
        import React from 'react'; import {AbsoluteFill,useCurrentFrame} from 'remotion';
        export const COMPOSITION_WIDTH=320,COMPOSITION_HEIGHT=180,COMPOSITION_FPS=10,COMPOSITION_DURATION_IN_FRAMES=40;
        export function MyComposition(){return <AbsoluteFill style={{backgroundColor:useCurrentFrame()<20?'magenta':'cyan'}}/>}
        """
        try RemotionCodeBuilder.writeComposition(project: project, source: project.compositionSource)
        let sequence = SequenceProject(name: "First cut")
        context.insert(sequence)
        var timeline = Timeline(width: 320, height: 180, fps: 10)
        let clip = Clip(source: .init(id: DocumentMediaResolver.sourceID(.remotion, project.id), kind: .remotion, displayName: "Title"), start: 0, duration: 4)
        try TimelineEditor.insert(&timeline, clip: clip, on: #require(timeline.tracks.first { $0.kind == .video }).id)
        sequence.timeline = timeline
        try context.save()
        let session = SimpleModeSession(template: FilmTemplateCatalog.companyIntro)
        session.document = document
        session.finishBuilding(summary: String(repeating: "A long build note that should stay inside the notes panel. ", count: 40))
        let playback = SimpleModePlayback()
        let host = NSHostingView(rootView: SimpleModePreviewHost(session: session, document: document,
            onOpenEditor: {}, onCancel: {}, playback: playback))
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1000, height: 740),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        defer {
            window.close()
            playback.unload()
            Task { await document.close(); try? FileManager.default.removeItem(at: root) }
        }
        try await wait { playback.player.player.currentItem != nil && !playback.player.isBuffering && !playback.player.isLoading }
        #expect(playback.usesLivePreview)
        #expect(playback.preview.layers.first?.live?.ready == true)
        #expect(playback.player.duration == 4)
        let controls = hostedAccessibilityDescendants(host)
        let live = try #require(controls.first { $0.accessibilityIdentifier() == "remotion.livePreview" })
        try await assertColor(.magenta, of: live, in: host)
        let play = try #require(controls.first { $0.accessibilityIdentifier() == "sequence.viewer.play" })
        #expect(play.accessibilityPerformPress())
        try await wait { playback.player.currentTime > 2.2 }
        playback.player.pause()
        #expect((playback.preview.layers.first?.live?.command.frame ?? 0) > 20)
        try await assertColor(.cyan, of: live, in: host)
        playback.player.seek(to: 0.5)
        try await wait { playback.preview.layers.first?.live?.command.frame == 5 }
        try await assertColor(.magenta, of: live, in: host)
        #expect(controls.contains { $0.accessibilityIdentifier() == "wizard.preview.notes" })
        let stage = try #require(controls.first { $0.accessibilityIdentifier() == "sequence.viewer.stage" })
        #expect(stage.accessibilityFrame().height > 260, "Long notes must not crowd out the movie")
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/film-wizard-preview.png"))
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Preview did not reach the expected playback state")
    }

    /// Checks a snapshot of the host: the composition is the only magenta or cyan
    /// content, so the expected colour must cover a large share of the pixels and
    /// the other colour must be absent. Coordinate-free, so it is independent of
    /// how the hosted accessibility frame maps to the bitmap.
    private func assertColor(_ color: NSColor, of element: HostedAccessibilityElement, in host: NSView) async throws {
        let expected = try #require(color.usingColorSpace(.sRGB))
        // Saturated colours have two channels above 0.8 and one below 0.6; HDR
        // snapshots lift a nominally zero channel to around 0.5.
        func dominant(_ c: NSColor) -> (Bool, Bool, Bool) { (c.redComponent > 0.8, c.greenComponent > 0.8, c.blueComponent > 0.8) }
        // Magenta (R, B) and cyan (G, B) differ in red and green.
        let target = dominant(expected)
        let opposite = (!target.0, !target.1, target.2)
        var last = (0, 0, 0)
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                var hits = 0, misses = 0, total = 0
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                        guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        total += 1
                        let high = [c.redComponent, c.greenComponent, c.blueComponent].filter { $0 > 0.8 }.count
                        let low = [c.redComponent, c.greenComponent, c.blueComponent].filter { $0 < 0.6 }.count
                        guard high == 2, low == 1 else { continue }
                        let d = dominant(c)
                        if d == target { hits += 1 } else if d == opposite { misses += 1 }
                    }
                }
                last = (hits, misses, total)
                if hits * 20 > total, misses * 100 < total { return }
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/film-wizard-live.png"))
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("The live preview did not show \(color): \(last.0) matching, \(last.1) opposite of \(last.2) samples; see /tmp/film-wizard-live.png")
    }
}
