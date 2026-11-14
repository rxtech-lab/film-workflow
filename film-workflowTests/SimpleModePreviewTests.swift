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

    /// Samples the centre of the native live preview from a snapshot of the host.
    private func assertColor(_ color: NSColor, of element: HostedAccessibilityElement, in host: NSView) async throws {
        let expected = try #require(color.usingColorSpace(.sRGB))
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            if let window = host.window, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let screen = element.accessibilityFrame()
                let local = host.convert(window.convertFromScreen(screen), from: nil)
                let scale = Double(bitmap.pixelsWide) / host.bounds.width
                let x = Int(local.midX * scale)
                let y = Int((host.isFlipped ? local.midY : host.bounds.height - local.midY) * scale)
                if let actual = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   (actual.redComponent > 0.5) == (expected.redComponent > 0.5),
                   (actual.greenComponent > 0.5) == (expected.greenComponent > 0.5),
                   (actual.blueComponent > 0.5) == (expected.blueComponent > 0.5) { return }
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/film-wizard-live.png"))
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("The live preview did not show \(color) (\(String(describing: element.accessibilityValue())), frame \(String(describing: element.accessibilityFrame()))); see /tmp/film-wizard-live.png")
    }
}
