import AVFoundation
import AppKit
import Foundation
import MotionCore
import MotionSwiftUI
import SkiaKit
import SwiftUI
import Testing
import VideoEditorCore
import VideoEditorUI
import VideoEffectsCore
@testable import film_workflow

/// The generated sequence film compiled and rendered by MotionSwift end to end: native video,
/// stills, host-processed captions and effects, and a nested Remotion project with its own assets.
@Suite("MotionSwift sequences", .serialized) @MainActor
struct MotionSequenceRenderingTests {
    private let nestedSource = """
    import {AbsoluteFill, Img, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
    export const COMPOSITION_WIDTH = 160;
    export const COMPOSITION_HEIGHT = 90;
    export const COMPOSITION_FPS = 30;
    export const COMPOSITION_DURATION_IN_FRAMES = 60;
    export const MyComposition = () => {
      const {width} = useVideoConfig();
      return <AbsoluteFill>
        <Img src={staticFile('green.png')} style={{position: 'absolute', left: 0, top: 0, width: width / 2, height: 90, objectFit: 'fill'}} />
      </AbsoluteFill>;
    };
    """

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MotionSequence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func png(_ color: NSColor, size: CGSize, at url: URL) throws {
        let image = NSImage(size: size)
        image.lockFocus(); color.setFill(); NSRect(origin: .zero, size: size).fill(); image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    /// A two-second solid blue H.264 clip.
    private func video(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 180,
        ])
        writer.add(input)
        writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for index in 0..<60 {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            for offset in stride(from: 0, to: CVPixelBufferGetBytesPerRow(pixels) * 180, by: 4) {
                base[offset] = 255; base[offset + 1] = 0; base[offset + 2] = 0; base[offset + 3] = 255
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30))
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
    }

    private func color(_ image: CGImage, x: Int, y: Int) throws -> NSColor {
        try #require(NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y))
    }

    @Test("Changing preview resolution re-renders the same frame at the new pixel size")
    func changesPreviewResolutionInPlace() async throws {
        let clip = Clip(source: ClipSource(id: "still", kind: .image, displayName: "Still"),
                        start: 0, duration: 2, isEnabled: false)
        let timeline = Timeline(width: 1080, height: 1920, tracks: [Track(kind: .video, name: "V1", clips: [clip])])
        let film = try MotionSequenceComposer.compose(timeline, sources: MotionSequenceSources())
        let compiled = try await MotionSequenceEngine.compile(film)
        let suite = "PreviewResolution-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(PreviewResolution.low.rawValue, forKey: PreviewResolution.storageKey)

        let player = MotionPlayer(configuration: .init(scale: 1, backend: .gpu))
        let host = NSHostingView(rootView: Color.clear
            .modifier(MotionPreviewResolution(player: player, width: timeline.width, height: timeline.height))
            .defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }

        let menu = NSHostingMenu(rootView: PreviewResolutionPicker()
            .defaultAppStorage(defaults)
            .environment(\.locale, Locale(identifier: "en")))
        menu.update()
        let options = menu.item(withTitle: "Preview Resolution")?.submenu ?? menu
        options.update()

        await player.load(.bundle(compiled.bundle), compositionID: MotionSequenceComposition.compositionID)
        player.seek(to: 12)
        for (title, width, height) in [("Low", 360, 640), ("Standard", 720, 1280), ("Low", 360, 640)] {
            let index = options.indexOfItem(withTitle: title)
            try #require(index >= 0, "Available preview options: \(options.items.map(\.title))")
            options.performActionForItem(at: index)
            func hasExpectedFrame() -> Bool {
                guard let frame = player.displayedFrame else { return false }
                return frame.frame == 12 && frame.image.width == width && frame.image.height == height
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while !hasExpectedFrame(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(hasExpectedFrame(), "Expected frame 12 at \(width)×\(height) in \(title)")
            #expect(player.currentFrame == 12)
        }
        #expect(player.composition?.width == timeline.width && player.composition?.height == timeline.height)
    }

    @Test("Video, captions, effects and a nested Remotion project export through MotionSwift")
    func exportsMixedTimeline() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let videoURL = root.appendingPathComponent("blue.mp4")
        try await video(at: videoURL)
        let stillURL = root.appendingPathComponent("red.png")
        try png(.red, size: CGSize(width: 40, height: 40), at: stillURL)
        let project = root.appendingPathComponent("Intro")
        try RemotionRuntime.scaffold(at: project)
        try nestedSource.write(to: project.appendingPathComponent("src/Composition.tsx"), atomically: true, encoding: .utf8)
        try png(.green, size: CGSize(width: 8, height: 8), at: project.appendingPathComponent("public/green.png"))

        let videoClip = Clip(source: ClipSource(id: "video:1", kind: .video, displayName: "Blue"), start: 0, duration: 2)
        // A desaturated red still in the top-right corner, drawn by the host processor.
        var still = Clip(source: ClipSource(id: "image:1", kind: .image, displayName: "Red"), start: 0, duration: 2,
                         transform: ClipTransform(fit: .fit, scale: 0.25, offsetX: 0.375, offsetY: 0.375))
        still.effects = [EffectInstance(definitionID: "rx.saturation", parameters: ["amount": .number(0)])]
        // The nested film fills the right half of the frame from 1 s.
        let nested = Clip(source: ClipSource(id: "remotion:1", kind: .remotion, displayName: "Intro"), start: 1, duration: 1)
        let caption = Clip(source: ClipSource(id: "caption:1", kind: .captions, displayName: "Captions"), start: 0, duration: 2)
        let timeline = Timeline(width: 320, height: 180, fps: 30, tracks: [
            Track(kind: .caption, name: "C1", clips: [caption]),
            Track(kind: .overlay, name: "O1", clips: [nested]),
            Track(kind: .video, name: "V2", clips: [still]),
            Track(kind: .video, name: "V1", clips: [videoClip]),
        ])
        let stillSize = try #require(MotionSequenceEngine.imageSize(stillURL))
        let sources = MotionSequenceSources(
            media: ["video:1": .file(videoURL, naturalDuration: 2, naturalSize: CGSize(width: 320, height: 180)),
                    "image:1": .file(stillURL, naturalDuration: nil, naturalSize: nil),
                    "caption:1": .captions([TextCue(start: 0, end: 0.5, text: "HELLO")])],
            naturalSizes: [videoURL: CGSize(width: 320, height: 180), stillURL: stillSize],
            durations: [videoURL: 2],
            nested: ["remotion:1": try MotionSequenceEngine.nestedProject(at: project)])
        let film = try MotionSequenceComposer.compose(timeline, sources: sources)
        let compiled = try await MotionSequenceEngine.compile(film)
        film.processor.register()
        defer { film.processor.unregister() }

        let output = root.appendingPathComponent("out/sequence.mp4")
        let cancellation = CancellationFlag()
        try await MotionSwiftEngine.run(on: MotionSwiftEngine.renderQueue) {
            try MotionSequenceEngine.write(compiled, to: output, scale: 1, codec: .h264, audioOnly: false, includeAudio: true,
                                           cancellation: cancellation) { _ in }
        }

        let asset = AVURLAsset(url: output)
        #expect(abs(try await asset.load(.duration).seconds - 2) < 0.1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let early = try await generator.image(at: CMTime(value: 10, timescale: 30)).image
        let late = try await generator.image(at: CMTime(value: 45, timescale: 30)).image
        // Native video fills the frame.
        let background = try color(early, x: 40, y: 150)
        #expect(background.blueComponent > 0.8 && background.redComponent < 0.2)
        // The still is grey: placed by the transform, desaturated by the processor.
        let grey = try color(early, x: 280, y: 22)
        #expect(abs(grey.redComponent - grey.greenComponent) < 0.1 && grey.redComponent > 0.2)
        // The nested composition draws its own public/ asset over the left half of its box.
        let green = try color(late, x: 40, y: 90)
        #expect(green.greenComponent > 0.6 && green.blueComponent < 0.3)
        // Captions burn in near the bottom while their cue is active, and are gone after it.
        func hasCaption(_ image: CGImage) -> Bool {
            (140..<170).contains { y in
                (100..<220).contains { x in
                    guard let c = try? color(image, x: x, y: y) else { return false }
                    return c.redComponent > 0.75 && c.greenComponent > 0.75 && c.blueComponent > 0.75
                }
            }
        }
        #expect(hasCaption(early))
        #expect(!hasCaption(late))
    }
}
