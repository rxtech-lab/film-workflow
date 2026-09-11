import AVFoundation
import AppKit
import CoreImage
import Foundation
import Testing
import VideoEffectsCore
@testable import VideoEditorCore

@Suite("Effect and transition movie frames", .serialized)
@MainActor
struct ModifierCompositionTests {
    @Test("Two clips blend across an unchanged cut, including held source edges", arguments: [false, true])
    func pairFrames(held: Bool) async throws {
        let dir = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let aURL = dir.appendingPathComponent("red.mp4"), bURL = dir.appendingPathComponent("blue.mp4")
        try Fixtures.video(color: .red, seconds: held ? 2 : 4, at: aURL)
        try Fixtures.video(color: .blue, seconds: held ? 2 : 4, at: bURL)
        let a = Clip(source: .init(id: "red", kind: .video, displayName: "Red"), start: 0, duration: 2, inPoint: held ? 0 : 1)
        let b = Clip(source: .init(id: "blue", kind: .video, displayName: "Blue"), start: 2, duration: 2, inPoint: held ? 0 : 1)
        var timeline = Timeline(width: 320, height: 180, tracks: [Track(kind: .video, name: "V1", clips: [a, b])])
        try TimelineEditor.addTransition(&timeline, definitionID: "rx.cross-dissolve", attachment: .between(outgoing: a.id, incoming: b.id))
        let resolver = FixtureResolver(files: ["red": .file(aURL, naturalDuration: held ? 2 : 4, naturalSize: nil),
                                               "blue": .file(bURL, naturalDuration: held ? 2 : 4, naturalSize: nil)])
        // The sources must decode as pure colours before the blend is judged.
        let sourceRed = try await Fixtures.averageColor(of: aURL, at: 1)
        let sourceBlue = try await Fixtures.averageColor(of: bURL, at: 1)
        #expect(sourceRed.r > 0.9 && sourceRed.g < 0.05 && sourceRed.b < 0.05, "source red: \(sourceRed)")
        #expect(sourceBlue.b > 0.9 && sourceBlue.r < 0.05 && sourceBlue.g < 0.05, "source blue: \(sourceBlue)")
        let built = try await TimelineCompositionBuilder(resolver: resolver).build(timeline, allowPlaceholders: true)
        #expect(CMTimeGetSeconds(built.duration) == 4)
        let generator = AVAssetImageGenerator(asset: built.asset)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let preview = try generator.copyCGImage(at: CMTime(seconds: 2, preferredTimescale: 600), actualTime: nil)
        let output = dir.appendingPathComponent("transition.mp4")
        try await TimelineExporter.export(timeline, resolver: resolver, to: output, preset: .h264) { _ in }
        let start = try await Fixtures.averageColor(of: output, at: 1.5)
        let middle = try await Fixtures.averageColor(of: output, at: 2)
        let end = try await Fixtures.averageColor(of: output, at: 2.5)
        #expect(start.r > 0.9 && start.b < 0.1)
        // Core Image blends in linear light; 50% becomes about 0.735 in encoded sRGB.
        let half = encodeSRGB(0.5)
        #expect(abs(middle.r - half) < 0.08 && abs(middle.b - half) < 0.08 && middle.g < 0.12, "midpoint: \(middle)")
        #expect(end.b > 0.9 && end.r < 0.1, "end: \(end)")
        let previewColor = sample(preview)
        #expect(abs(previewColor.0 - middle.r) < 0.06)
        #expect(abs(previewColor.2 - middle.b) < 0.06)
    }

    @Test("Edge fades reveal the lower track, and effects apply to stills")
    func stillEffectsAndEdgeFade() async throws {
        let dir = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let redURL = dir.appendingPathComponent("red.png"), blueURL = dir.appendingPathComponent("blue.png")
        try Fixtures.png(color: .red, size: CGSize(width: 320, height: 180), at: redURL)
        try Fixtures.png(color: .blue, size: CGSize(width: 320, height: 180), at: blueURL)
        let red = Clip(source: .init(id: "red", kind: .image, displayName: "Red"), start: 0, duration: 3)
        let blue = Clip(source: .init(id: "blue", kind: .image, displayName: "Blue"), start: 0, duration: 3)
        var timeline = Timeline(width: 320, height: 180, tracks: [Track(kind: .video, name: "Top", clips: [red]), Track(kind: .video, name: "Bottom", clips: [blue])])
        try TimelineEditor.addEffect(&timeline, definitionID: "rx.saturation", clipID: red.id)
        try TimelineEditor.addTransition(&timeline, definitionID: "rx.cross-dissolve", attachment: .start(red.id))
        try TimelineEditor.addTransition(&timeline, definitionID: "rx.cross-dissolve", attachment: .end(red.id))
        let resolver = FixtureResolver(files: ["red": .file(redURL, naturalDuration: nil, naturalSize: nil), "blue": .file(blueURL, naturalDuration: nil, naturalSize: nil)])
        let output = dir.appendingPathComponent("edges.mp4")
        try await TimelineExporter.export(timeline, resolver: resolver, to: output, preset: .h264) { _ in }
        let start = try await Fixtures.averageColor(of: output, at: 0)
        let middle = try await Fixtures.averageColor(of: output, at: 1.5)
        let end = try await Fixtures.averageColor(of: output, at: 2.9)
        #expect(start.b > 0.9 && start.r < 0.1)
        #expect(abs(middle.r - middle.b) < 0.03 && abs(middle.r - middle.g) < 0.03)
        let expectedRed = encodeSRGB(decodeSRGB(middle.r) * 0.1)
        #expect(end.b > 0.9 && abs(end.r - expectedRed) < 0.04, "fade end: \(end)")
    }

    @Test("Retimed and cached Remotion pictures use the same transition compositor")
    func retimedRemotionFrames() async throws {
        let dir = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("remotion.mp4")
        try Fixtures.video(color: .green, seconds: 2, at: url)
        let clip = Clip(source: .init(id: "remotion", kind: .remotion, displayName: "Composition"), start: 0, duration: 1, playbackRate: 2)
        var timeline = Timeline(width: 320, height: 180, tracks: [Track(kind: .video, name: "V1", clips: [clip])])
        try TimelineEditor.addTransition(&timeline, definitionID: "rx.fade-color", attachment: .start(clip.id), duration: 0.5)
        let resolver = FixtureResolver(files: ["remotion": .file(url, naturalDuration: 2, naturalSize: nil)])
        let output = dir.appendingPathComponent("retimed.mp4")
        try await TimelineExporter.export(timeline, resolver: resolver, to: output, preset: .h264) { _ in }
        let first = try await Fixtures.averageColor(of: output, at: 0)
        let last = try await Fixtures.averageColor(of: output, at: 0.5)
        #expect(first.g < 0.05)
        #expect(last.g > 0.9)
        #expect(abs(CMTimeGetSeconds(try await AVURLAsset(url: output).load(.duration)) - 1) < 0.04)
    }

    private func encodeSRGB(_ value: Double) -> Double { value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055 }
    private func decodeSRGB(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }

    private func sample(_ image: CGImage) -> (Double, Double, Double) {
        var bytes = [UInt8](repeating: 0, count: 4)
        CIContext().render(CIImage(cgImage: image), toBitmap: &bytes, rowBytes: 4,
                           bounds: CGRect(x: 100, y: 90, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
    }
}
