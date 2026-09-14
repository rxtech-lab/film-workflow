import AppKit
import AVFoundation
import FilmTemplateKit
import SwiftData
import SwiftUI
import Testing
import VideoEditorCore
import WebKit

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
        let webView = try #require(webViews(in: host).first)
        try await assertColor(.magenta, in: webView)
        let controls = hostedAccessibilityDescendants(host)
        let play = try #require(controls.first { $0.accessibilityIdentifier() == "sequence.viewer.play" })
        #expect(play.accessibilityPerformPress())
        try await wait { playback.player.currentTime > 2.2 }
        playback.player.pause()
        #expect((playback.preview.layers.first?.live?.command.frame ?? 0) > 20)
        try await assertColor(.cyan, in: webView)
        playback.player.seek(to: 0.5)
        try await wait { playback.preview.layers.first?.live?.command.frame == 5 }
        try await assertColor(.magenta, in: webView)
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

    private func webViews(in view: NSView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews(in: $0) }
    }

    private func assertColor(_ color: NSColor, in webView: WKWebView) async throws {
        let expected = try #require(color.usingColorSpace(.sRGB))
        for _ in 0..<40 {
            let image = try await webView.takeSnapshot(configuration: nil)
            if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/film-wizard-web.png"))
            }
            if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                if let actual = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB),
                   // HDR snapshots can lift a nominally zero channel to 0.25.
                   // Distinguish magenta from cyan by their dominant channels.
                   (actual.redComponent > 0.5) == (expected.redComponent > 0.5),
                   (actual.greenComponent > 0.5) == (expected.greenComponent > 0.5),
                   (actual.blueComponent > 0.5) == (expected.blueComponent > 0.5) { return }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let details = try await webView.evaluateJavaScript("JSON.stringify({html:document.getElementById('stage').innerHTML, visible:document.visibilityState})")
        try String(describing: details).write(toFile: "/tmp/film-wizard-web.txt", atomically: true, encoding: .utf8)
        let image = try await webView.takeSnapshot(configuration: nil)
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cg)
        let actual = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB)
        Issue.record("The visible video frame \(String(describing: actual)) did not match \(expected)")
    }
}
