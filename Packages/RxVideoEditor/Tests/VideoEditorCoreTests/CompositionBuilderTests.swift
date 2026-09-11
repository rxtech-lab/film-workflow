import AVFoundation
import AppKit
import Foundation
import Synchronization
import Testing

@testable import VideoEditorCore

/// Resolves ids to fixture files written by the test.
struct FixtureResolver: MediaResolver {
    var files: [String: ResolvedMedia]
    var unrendered: Set<String> = []

    func resolve(_ source: ClipSource) async throws -> ResolvedMedia {
        if unrendered.contains(source.id) { throw MediaResolverError.unrendered(source) }
        guard let media = files[source.id] else { throw MediaResolverError.missing(source) }
        return media
    }

    func thumbnail(for source: ClipSource, at time: TimeInterval) async -> CGImage? { nil }
}

enum Fixtures {
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VideoEditorCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A solid-colour PNG.
    static func png(color: NSColor, size: CGSize, at url: URL) throws {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    /// A short solid-colour H.264 clip with no audio.
    static func video(color: NSColor, seconds: Double, fps: Int32 = 30, size: (Int, Int) = (320, 180), image: CGImage? = nil, at url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.0,
            AVVideoHeightKey: size.1,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.0,
            kCVPixelBufferHeightKey as String: size.1,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, size.0, size.1, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let rgb = color.usingColorSpace(.sRGB)!
        let (r, g, b) = (UInt8(rgb.redComponent * 255), UInt8(rgb.greenComponent * 255), UInt8(rgb.blueComponent * 255))
        let count = CVPixelBufferGetDataSize(pixelBuffer) / 4
        for i in 0..<count { base[i * 4] = b; base[i * 4 + 1] = g; base[i * 4 + 2] = r; base[i * 4 + 3] = 255 }
        if let image {
            let context = try #require(CGContext(data: base, width: size.0, height: size.1, bitsPerComponent: 8,
                                                 bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: size.0, height: size.1))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        let frames = Int(seconds * Double(fps))
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(500) }
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await_finish(writer)
        #expect(writer.status == .completed)
    }

    private static func await_finish(_ writer: AVAssetWriter) {
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
    }

    /// Average colour of a frame at `time`.
    static func averageColor(of url: URL, at time: TimeInterval) async throws -> (r: Double, g: Double, b: Double) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var r = 0.0, g = 0.0, b = 0.0
        let pixels = Double(width * height)
        for i in 0..<(width * height) {
            r += Double(data[i * 4]); g += Double(data[i * 4 + 1]); b += Double(data[i * 4 + 2])
        }
        return (r / pixels / 255, g / pixels / 255, b / pixels / 255)
    }
}

@Suite("Composition builder and exporter")
@MainActor
struct CompositionBuilderTests {
    @Test("Instructions tile the whole duration without gaps")
    func instructionsAreContiguous() async throws {
        let dir = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let still = dir.appendingPathComponent("red.png")
        try Fixtures.png(color: .red, size: CGSize(width: 64, height: 64), at: still)

        var t = Timeline(width: 320, height: 180, fps: 30)
        let v = t.tracks.first { $0.kind == .video }!.id
        let source = ClipSource(id: "image:red", kind: .image, displayName: "Red")
        try TimelineEditor.insert(&t, clip: Clip(source: source, start: 1, duration: 2), on: v)
        try TimelineEditor.insert(&t, clip: Clip(source: source, start: 5, duration: 1), on: v)

        let resolver = FixtureResolver(files: ["image:red": .file(still, naturalDuration: nil, naturalSize: nil)])
        let built = try await TimelineCompositionBuilder(resolver: resolver).build(t, allowPlaceholders: false)
        let instructions = built.videoComposition.instructions.compactMap { $0 as? TimelineCompositionInstruction }
        #expect(instructions.count == 4)   // [0,1) [1,3) [3,5) [5,6)
        var cursor = CMTime.zero
        for instruction in instructions {
            #expect(instruction.timeRange.start == cursor)
            cursor = instruction.timeRange.end
            #expect(instruction.requiredSourceTrackIDs?.isEmpty == false)
        }
        #expect(cursor == built.duration)
        #expect(CMTimeGetSeconds(built.duration) == 6)
        #expect(built.videoComposition.customVideoCompositorClass == TimelineVideoCompositor.self)
    }

    @Test("Unrendered clips are slates in preview and refused for export")
    func placeholders() async throws {
        var t = Timeline(width: 320, height: 180, fps: 30)
        let v = t.tracks.first { $0.kind == .video }!.id
        let remotion = ClipSource(id: "remotion:1", kind: .remotion, displayName: "Title")
        try TimelineEditor.insert(&t, clip: Clip(source: remotion, start: 0, duration: 2), on: v)
        let resolver = FixtureResolver(files: [:], unrendered: ["remotion:1"])

        let preview = try await TimelineCompositionBuilder(resolver: resolver).build(t, allowPlaceholders: true)
        #expect(preview.placeholders == [remotion])

        await #expect(throws: CompositionBuildError.self) {
            _ = try await TimelineCompositionBuilder(resolver: resolver).build(t, allowPlaceholders: false)
        }
    }

    @Test("Exports a still, a video and a caption to an mp4 with the expected frames")
    func exportsFrames() async throws {
        let dir = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let still = dir.appendingPathComponent("green.png")
        try Fixtures.png(color: .green, size: CGSize(width: 320, height: 180), at: still)
        let movie = dir.appendingPathComponent("blue.mp4")
        try Fixtures.video(color: .blue, seconds: 2, at: movie)

        var t = Timeline(width: 320, height: 180, fps: 30)
        let v = t.tracks.first { $0.kind == .video }!.id
        let o = t.tracks.first { $0.kind == .overlay }!.id
        try TimelineEditor.insert(&t, clip: Clip(source: ClipSource(id: "image:g", kind: .image, displayName: "G"), start: 0, duration: 1), on: v)
        try TimelineEditor.insert(&t, clip: Clip(source: ClipSource(id: "video:b", kind: .video, displayName: "B"), start: 1, duration: 2), on: v)
        try TimelineEditor.insert(&t, clip: Clip(source: ClipSource(id: "caption:c", kind: .captions, displayName: "C"), start: 0, duration: 3,
                                                 text: TextStyle(fontSize: 0.5, colorHex: "#FFFFFF", backgroundOpacity: 0, verticalPosition: 0.5)), on: o)

        let resolver = FixtureResolver(files: [
            "image:g": .file(still, naturalDuration: nil, naturalSize: nil),
            "video:b": .file(movie, naturalDuration: 2, naturalSize: CGSize(width: 320, height: 180)),
            "caption:c": .captions([TextCue(start: 2.2, end: 3, text: "HELLO")]),
        ])
        let output = dir.appendingPathComponent("out.mp4")
        let lastProgress = Mutex(0.0)
        try await TimelineExporter.export(t, resolver: resolver, to: output, preset: .h264) { p in lastProgress.withLock { $0 = p } }
        #expect(lastProgress.withLock { $0 } == 1)
        #expect(FileManager.default.fileExists(atPath: output.path))

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        #expect(abs(CMTimeGetSeconds(duration) - 3) < 0.1)

        let green = try await Fixtures.averageColor(of: output, at: 0.5)
        #expect(green.g > 0.6 && green.r < 0.3 && green.b < 0.3)
        let blue = try await Fixtures.averageColor(of: output, at: 1.5)
        #expect(blue.b > 0.6 && blue.r < 0.3 && blue.g < 0.3)
        // White text over blue lifts red and green at the cue.
        let captioned = try await Fixtures.averageColor(of: output, at: 2.6)
        #expect(captioned.r > blue.r + 0.05 && captioned.g > blue.g + 0.05)
    }

    @Test("Leaving captions out of the picture drops their layers and edges")
    func excludesCaptions() async throws {
        var t = Timeline(width: 320, height: 180, fps: 30)
        let o = t.tracks.first { $0.kind == .overlay }!.id
        try TimelineEditor.insert(&t, clip: Clip(source: ClipSource(id: "caption:c", kind: .captions, displayName: "C"), start: 1, duration: 2, inPoint: 0.5), on: o)
        let resolver = FixtureResolver(files: ["caption:c": .captions([TextCue(start: 0, end: 1, text: "HELLO"), TextCue(start: 1, end: 3, text: "WORLD")])])

        let drawn = try await TimelineCompositionBuilder(resolver: resolver).build(t, allowPlaceholders: false)
        let layers = drawn.videoComposition.instructions.compactMap { $0 as? TimelineCompositionInstruction }.flatMap(\.layers)
        let texts = layers.compactMap { layer -> [TextCue]? in if case .text(let cues, _) = layer { return cues } else { return nil } }
        #expect(texts.count == 1)
        #expect(texts.first == [TextCue(start: 1, end: 1.5, text: "HELLO"), TextCue(start: 1.5, end: 3, text: "WORLD")])

        let stripped = try await TimelineCompositionBuilder(resolver: resolver).build(t, allowPlaceholders: false, includeCaptions: false)
        let strippedLayers = stripped.videoComposition.instructions.compactMap { $0 as? TimelineCompositionInstruction }.flatMap(\.layers)
        #expect(strippedLayers.isEmpty)
        #expect(stripped.videoComposition.instructions.count == 1)
    }
}
