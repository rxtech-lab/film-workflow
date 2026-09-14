import AppKit
import AVFoundation
import Foundation
import RxRemotion
import SwiftData
import SwiftUI
import Testing
import VideoEditorCore
import VideoEditorUI

@testable import film_workflow

@Suite("Shared library previews", .serialized)
@MainActor
struct LibPreviewableTests {
    private func imageBytes(_ image: CGImage) -> Data? { image.dataProvider?.data as Data? }

    @Test("Caption cards use cue duration, render changing text, and scrub the caption viewer")
    func captions() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CaptionPreview-\(UUID()).rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let project = CaptionProject(name: "Timed captions")
        document.container.mainContext.insert(project)
        let first = CaptionSegment(startMs: 0, endMs: 1000, text: "FIRST")
        let last = CaptionSegment(startMs: 1000, endMs: 3000, text: "SECOND CAPTION")
        first.project = project; last.project = project
        document.container.mainContext.insert(first); document.container.mainContext.insert(last)
        project.segments = [first, last]
        try document.container.mainContext.save()
        let source = project.makeLibPreviewSource()
        #expect(source.duration == 3 && source.canScrub && source.isTemporal)
        let one = try #require(await source.thumbnail(at: 0.5, maximumSize: CGSize(width: 320, height: 180)))
        let two = try #require(await source.thumbnail(at: 2, maximumSize: CGSize(width: 320, height: 180)))
        #expect(imageBytes(one) != imageBytes(two))
        let resolver = DocumentMediaResolver(document: document, width: 320, height: 180, fps: 30)
        #expect(await resolver.libraryPreview(for: project.clipSource) == source)

        let cell = try #require(LibraryIndex(captions: [project]).footage(for: .init(kind: .caption, id: project.projectUUID)).first)
        let player = FootagePlayer()
        await player.load(cell, document: document)
        player.generatedPreview.setVisible(true)
        player.skim(toFraction: 2.0 / 3)
        #expect(player.currentTime == 2)
        for _ in 0..<100 where player.generatedPreview.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        #expect(player.generatedPreview.lastError == nil)
        let layer = try #require(player.generatedPreview.layers.first)
        if case .media(.captions(let cues)) = layer.source {
            #expect(cues.first(where: { $0.start <= player.currentTime && player.currentTime < $0.end })?.text == "SECOND CAPTION")
        } else { Issue.record("Caption preview must resolve timed text") }
        player.endSkim()
        #expect(player.currentTime == 0)
        player.unload()

        first.text = "UPDATED CAPTION"
        let edited = project.makeLibPreviewSource()
        #expect(edited != source)
        let refreshed = try #require(await edited.thumbnail(at: 0.5, maximumSize: CGSize(width: 320, height: 180)))
        #expect(imageBytes(refreshed) != imageBytes(one))
        await document.close()
    }

    @Test("Remotion thumbnails render different composition frames without adding render versions")
    func remotion() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RemotionLibraryPreview-\(UUID()).rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let project = RemotionProject(name: "Changing colors")
        project.durationSeconds = 2
        project.compositionWidth = 320; project.compositionHeight = 180; project.compositionFps = 2
        document.container.mainContext.insert(project)
        let code = """
        import React from 'react'; import {AbsoluteFill,useCurrentFrame} from 'remotion';
        export const COMPOSITION_WIDTH=320,COMPOSITION_HEIGHT=180,COMPOSITION_FPS=2,COMPOSITION_DURATION_IN_FRAMES=4;
        export function MyComposition(){return <AbsoluteFill style={{backgroundColor:useCurrentFrame()<2?'red':'blue'}}/>}
        """
        project.compositionSource = code
        try RemotionCodeBuilder.writeComposition(project: project, source: code)
        try document.container.mainContext.save()
        let source = project.makeLibPreviewSource()
        #expect(source.canScrub && source.duration == 2)
        let red = try #require(await source.thumbnail(at: 0, maximumSize: CGSize(width: 160, height: 90)))
        let blue = try #require(await source.thumbnail(at: 1.5, maximumSize: CGSize(width: 160, height: 90)))
        let r = NSBitmapImageRep(cgImage: red).colorAt(x: 40, y: 40)?.usingColorSpace(.deviceRGB)
        let b = NSBitmapImageRep(cgImage: blue).colorAt(x: 40, y: 40)?.usingColorSpace(.deviceRGB)
        #expect((r?.redComponent ?? 0) > 0.9 && (r?.blueComponent ?? 1) < 0.1)
        #expect((b?.blueComponent ?? 0) > 0.9 && (b?.redComponent ?? 1) < 0.1)
        #expect(try document.container.mainContext.fetchCount(FetchDescriptor<RemotionRender>()) == 0)
        let player = FootagePlayer()
        let cell = FootageCell(id: project.id, title: project.name, subtitle: "", footage: project)
        player.commitPosition(fraction: 0.75, cellID: cell.id)
        await player.load(cell, document: document)
        #expect(player.usesGeneratedPreview && player.currentTime == 1.5)
        player.skim(toFraction: 0.25)
        #expect(player.currentTime == 0.5)
        player.endSkim()
        #expect(player.currentTime == 1.5)
        player.unload()
        await document.close()
    }

    @Test("Saved Remotion renders show changing frames and support library playback", arguments: [false, true])
    func renderedRemotion(preserveAlpha: Bool) async throws {
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RenderedLibraryPreview-\(UUID()).rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let project = RemotionProject(name: "Rendered animation")
        project.durationSeconds = 2
        project.compositionWidth = 320; project.compositionHeight = 180; project.compositionFps = 10
        document.container.mainContext.insert(project)
        let code = """
        import React from 'react'; import {AbsoluteFill,useCurrentFrame} from 'remotion';
        export const COMPOSITION_WIDTH=320,COMPOSITION_HEIGHT=180,COMPOSITION_FPS=10,COMPOSITION_DURATION_IN_FRAMES=20;
        export function MyComposition(){return <AbsoluteFill style={{backgroundColor:useCurrentFrame()<10?'red':'blue'}}/>}
        """
        project.compositionSource = code
        try RemotionCodeBuilder.writeComposition(project: project, source: code)
        let render = try await RemotionRenderService.ensureRender(project: project, width: 320, height: 180, fps: 10,
            context: document.container.mainContext, preserveAlpha: preserveAlpha) { _ in }
        // Change the live source after rendering. Selecting a saved version must
        // still decode that version's red/blue movie, not the current composition.
        project.compositionSource = code.replacingOccurrences(of: "'red':'blue'", with: "'green':'green'")
        try RemotionCodeBuilder.writeComposition(project: project, source: project.compositionSource)
        let index = LibraryIndex(remotions: [project], remotionRenders: [render])
        let cell = try #require(index.footage(for: .init(kind: .remotion, id: project.id)).first)
        let source = try #require(cell.previewSource)
        #expect(source.isTemporal && source.canScrub && source.duration == 2)
        let red = try #require(await source.thumbnail(at: 0, maximumSize: CGSize(width: 160, height: 90)))
        let blue = try #require(await source.thumbnail(at: 1.5, maximumSize: CGSize(width: 160, height: 90)))
        let r = NSBitmapImageRep(cgImage: red).colorAt(x: 40, y: 40)?.usingColorSpace(.deviceRGB)
        let b = NSBitmapImageRep(cgImage: blue).colorAt(x: 40, y: 40)?.usingColorSpace(.deviceRGB)
        #expect((r?.redComponent ?? 0) > 0.8 && (r?.blueComponent ?? 1) < 0.2)
        #expect((b?.blueComponent ?? 0) > 0.8 && (b?.redComponent ?? 1) < 0.2)

        let player = FootagePlayer()
        let host = NSHostingView(rootView: VStack {
            FootageFilmstrip(cell: cell, duration: cell.duration, isSelected: true, player: player,
                             onSkim: { if let fraction = $0 { player.skim(toFraction: fraction) } else { player.endSkim() } },
                             onSeek: { player.commitPosition(fraction: $0, cellID: cell.id) })
            FootageViewer(cell: cell, name: project.name, versions: [cell], onSelectVersion: { _ in },
                          player: player, document: document)
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        defer { window.close(); player.unload() }
        for _ in 0..<100 {
            if player.player.currentItem?.status == .readyToPlay, player.duration > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!player.usesGeneratedPreview)
        #expect((player.player.currentItem?.asset as? AVURLAsset)?.url == render.videoURL)
        let elements = hostedAccessibilityDescendants(host)
        let play = try #require(elements.first { $0.accessibilityIdentifier() == "viewer.play" })
        #expect(!elements.contains { $0.accessibilityValue() as? String == "Still" || $0.accessibilityLabel() == "Still" })
        #expect(play.accessibilityPerformPress())
        for _ in 0..<60 where player.currentTime < 0.2 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(player.isPlaying && player.currentTime >= 0.2)
        #expect(play.accessibilityPerformPress())
        #expect(!player.isPlaying)
        player.seek(to: 0)
        player.skim(toFraction: 0.75)
        #expect(abs(player.currentTime - 1.5) < 0.01)
        player.endSkim()
        #expect(player.currentTime == 0)
        player.commitPosition(fraction: 0.75, cellID: cell.id)
        player.endSkim()
        #expect(abs(player.currentTime - 1.5) < 0.01)
        #expect(try document.container.mainContext.fetchCount(FetchDescriptor<RemotionRender>()) == 1)
        player.unload()
        await document.close()
    }

    @MainActor
    private final class RecordingResolver: MediaResolver {
        var times: [Double] = []
        func resolve(_ source: ClipSource) async throws -> ResolvedMedia { throw MediaResolverError.missing(source) }
        func thumbnail(for source: ClipSource, at time: TimeInterval) async -> CGImage? { nil }
        func libraryPreview(for source: ClipSource) async -> LibPreviewSource? {
            LibPreviewSource(id: source.id, revision: UUID().uuidString, duration: 60, isTemporal: true, canScrub: true) { [weak self] time, size in
                self?.times.append(time)
                let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.setFillColor(NSColor(calibratedRed: time / 30, green: 0.2, blue: 1 - time / 30, alpha: 1).cgColor)
                context?.fill(CGRect(origin: .zero, size: size))
                return context?.makeImage()
            }
        }
    }

    @Test("Timeline clips request a series of frames from the trimmed, retimed source range")
    func timelineFrames() async throws {
        let resolver = RecordingResolver()
        let clip = Clip(source: .init(id: "frames", kind: .video, displayName: "Trimmed footage"), start: 0,
                        duration: 8, inPoint: 10, playbackRate: 2, sourceDuration: 60)
        let timeline = Timeline(tracks: [Track(kind: .video, name: "Video", clips: [clip])])
        let host = NSHostingView(rootView: SequenceTimelineView(timeline: .constant(timeline), playhead: .constant(0),
                                                               selectedClipIDs: .constant([]), pixelsPerSecond: .constant(40),
                                                               resolver: resolver, onDrop: { _, _, _ in }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(500))
        #expect(resolver.times.count >= 3)
        #expect(Set(resolver.times).count >= 3)
        #expect(resolver.times.allSatisfy { $0 > 10 && $0 < 26 })
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/film-timeline-frame-strip.png"))
    }
}
