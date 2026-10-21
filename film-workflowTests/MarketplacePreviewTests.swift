import AppKit
import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import film_workflow

@Suite("Marketplace preview rendering", .serialized) @MainActor
struct MarketplacePreviewTests {
    @Test("Template previews require an authored workspace movie and never generate a slideshow")
    func mockTemplate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MarketplaceAuthoringService(root: root, authenticated: { true }, transport: { _, _, _ in Data(#"{"can_author":true,"user_id":"test"}"#.utf8) })
        try await service.requireAdmin()
        let id = UUID().uuidString, directory = try service.directory(for: id)
        let path = try mockPNG(directory, width: 720, height: 1280)
        // A deterministic movie fixture; this test verifies ingestion/excerpting,
        // while the agent remains responsible for authoring and visual review.
        let fixture = MarketplaceAuthoringItem(item: .init(id: id, kind: .footage, category: "test", title: "Fixture", metadata: .init(mediaType: "image")), categoryId: "test", status: "draft", updatedAt: "1")
        let movie = try await MarketplacePreviewRenderer.render(item: fixture, start: 0, duration: 1, demoPath: nil, service: service, contentFile: { _ in path }) { _ in }
        var definition = ProjectTemplateTests().template(); definition.width = 720; definition.height = 1280
        definition.shots[0].durationSeconds = 60
        let item = MarketplaceAuthoringItem(item: .init(id: id, kind: .projectTemplate, category: "test", title: "Portrait"), categoryId: "test", status: "draft", updatedAt: "1", contentText: try definition.json())
        #expect(throws: (any Error).self) {
            try MarketplacePreviewRenderer.demonstrationURL(item: item, demoPath: nil, directory: directory)
        }
        let outside = root.appendingPathComponent("outside.mp4")
        try Data().write(to: outside)
        #expect(throws: (any Error).self) {
            try MarketplacePreviewRenderer.demonstrationURL(item: item, demoPath: outside.path, directory: directory)
        }
        let link = directory.appendingPathComponent("linked.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: (any Error).self) {
            try MarketplacePreviewRenderer.demonstrationURL(item: item, demoPath: link.path, directory: directory)
        }
        let output = try await MarketplacePreviewRenderer.render(item: item, start: 0.25, duration: 0.5, demoPath: movie.video.path, service: service, contentFile: { _ in Issue.record("Template requested source media"); throw MarketplaceAuthoringError.invalid("No source media permitted") }, mockAsset: { _, _ in Issue.record("Template must not generate a slideshow"); return path }) { _ in }
        let asset = AVURLAsset(url: output.video)
        #expect(try await asset.load(.duration).seconds <= 0.54)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(abs(size.width / size.height - 720.0 / 1280.0) < 0.01)
        let formats = try await track.load(.formatDescriptions)
        #expect(formats.first.map { CMFormatDescriptionGetMediaSubType($0) } == kCMVideoCodecType_H264)
        #expect(FileManager.default.fileExists(atPath: output.cover.path))
    }
    @Test("Music and sound previews contain audible content and footage excerpts keep the real media", arguments: [MarketplaceKind.audio, .soundEffect])
    func audiblePreview(kind: MarketplaceKind) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MarketplaceAuthoringService(root: root, authenticated: { true }, transport: { _, _, _ in Data(#"{"can_author":true,"user_id":"test"}"#.utf8) })
        try await service.requireAdmin()
        let id = UUID().uuidString, directory = try service.directory(for: id)
        let image = try mockPNG(directory), tone = directory.appendingPathComponent("tone.wav")
        try writeTone(tone)
        let item = MarketplaceAuthoringItem(item: .init(id: id, kind: kind, category: "test", title: "Tone"), categoryId: "test", status: "draft", updatedAt: "1")
        let output = try await MarketplacePreviewRenderer.render(item: item, start: 0.25, duration: 0.5, demoPath: nil, service: service, contentFile: { _ in tone }, mockAsset: { _, _ in image }) { _ in }
        try await assertAudible(output.video)
        let footage = MarketplaceAuthoringItem(item: .init(id: UUID().uuidString, kind: .footage, category: "test", title: "Actual clip"), categoryId: "test", status: "draft", updatedAt: "1")
        let excerpt = try await MarketplacePreviewRenderer.render(item: footage, start: 0.1, duration: 0.25, demoPath: nil, service: service, contentFile: { _ in output.video }, mockAsset: { _, _ in Issue.record("Footage must demonstrate the original clip"); return image }) { _ in }
        try await assertAudible(excerpt.video)
        #expect(try await AVURLAsset(url: excerpt.video).load(.duration).seconds < 0.31)
    }
    private func mockPNG(_ directory: URL, width: Int = 1280, height: Int = 720) throws -> URL {
        let path = directory.appendingPathComponent("mock.png")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try #require(bitmap.bitmapData)
        for row in 0..<height {
            for column in 0..<width {
                let index = row * bitmap.bytesPerRow + column * 4
                pixels[index] = 20; pixels[index + 1] = 140; pixels[index + 2] = 120; pixels[index + 3] = 255
            }
        }
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: path)
        return path
    }
    private func writeTone(_ url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)); buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData)
        for index in 0..<Int(buffer.frameLength) { samples[0][index] = Float(sin(2 * .pi * 440 * Double(index) / 48_000)) * 0.2 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer)
    }
    private func assertAudible(_ url: URL) async throws {
        let asset = AVURLAsset(url: url), reader = try AVAssetReader(asset: AVURLAsset(url: url))
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        // A reader's output must use a track from its own asset.
        let readerTrack = try #require(try await reader.asset.loadTracks(withMediaType: .audio).first)
        #expect(track.mediaType == .audio)
        let output = AVAssetReaderTrackOutput(track: readerTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32])
        reader.add(output); #expect(reader.startReading())
        var audible = false
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var count = 0; var data: UnsafeMutablePointer<Int8>?
            if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &count, dataPointerOut: &data) == kCMBlockBufferNoErr, let data {
                data.withMemoryRebound(to: Float.self, capacity: count / 4) { values in
                    if (0..<(count / 4)).contains(where: { abs(values[$0]) > 0.01 }) { audible = true }
                }
            }
        }
        #expect(audible)
    }
}
