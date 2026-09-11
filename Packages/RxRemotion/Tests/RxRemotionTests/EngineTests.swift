import AppKit
import AVFoundation
import Testing
@testable import RxRemotion

@Suite(.serialized) @MainActor
struct EngineTests {
    @Test func ranges() throws {
        #expect(try ResourceServer.byteRange("bytes=2-5", length: 10) == 2..<6)
        #expect(try ResourceServer.byteRange("bytes=-3", length: 10) == 7..<10)
        #expect(try ResourceServer.byteRange("bytes=8-", length: 10) == 8..<10)
        #expect(throws: (any Error).self) { try ResourceServer.byteRange("bytes=12-", length: 10) }
        #expect(throws: (any Error).self) { try ResourceServer.byteRange("bytes=0-1,4-5", length: 10) }
    }
    @Test func containment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("ok.js"))
        #expect(try ResourceServer.containedFile("ok.js", root: root).lastPathComponent == "ok.js")
        #expect(throws: (any Error).self) { try ResourceServer.containedFile("../outside", root: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(throws: (any Error).self) { try ResourceServer.containedFile("outside", root: root) }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RX_REMOTION_INTEGRATION"] == "1"))
    func compileDiscoverAndCapture() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RxRemotionTest-" + UUID().uuidString)
        try RemotionEngine.scaffold(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = """
        import {AbsoluteFill, useCurrentFrame} from 'remotion';
        export const COMPOSITION_WIDTH=320, COMPOSITION_HEIGHT=180, COMPOSITION_FPS=30, COMPOSITION_DURATION_IN_FRAMES=3;
        export function MyComposition(){const frame=useCurrentFrame();return <AbsoluteFill><div style={{position:'absolute',left:frame*20,top:0,width:80,height:80,background:'red'}}/></AbsoluteFill>}
        """
        try source.write(to: root.appendingPathComponent("src/Composition.tsx"), atomically: true, encoding: .utf8)
        let engine = RemotionEngine(); defer { engine.closeAll() }
        let project = try await engine.prepare(projectURL: root)
        let compositions = try await engine.compositions(in: project)
        #expect(compositions.first?.width == 320)
        let output = root.appendingPathComponent("frame.png")
        try await engine.renderStill(project: project, frame: 1, to: output)
        let image = try #require(NSBitmapImageRep(data: Data(contentsOf: output)))
        try Data(contentsOf: output).write(to: URL(fileURLWithPath: "/tmp/rxremotion-capture.png"))
        #expect(image.pixelsWide == 320); #expect(image.pixelsHigh == 180)
        let red = try #require(image.colorAt(x: 30, y: 30))
        let clear = try #require(image.colorAt(x: 250, y: 140))
        #expect(red.redComponent > 0.9); #expect(red.greenComponent < 0.1)
        #expect(clear.alphaComponent < 0.01)
        for codec in [RemotionRenderSettings.Codec.h264, .proRes4444] {
            let movie = root.appendingPathComponent(codec == .h264 ? "test.mp4" : "test.mov")
            try await engine.renderMovie(project: project, to: movie, settings: .init(codec: codec))
            let asset = AVURLAsset(url: movie)
            let duration = try await asset.load(.duration).seconds
            #expect(abs(duration - 0.1) < 0.001)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            #expect(try await track.load(.naturalSize) == CGSize(width: 320, height: 180))
            let reader = try AVAssetReader(asset: asset)
            let frames = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(frames); #expect(reader.startReading())
            var count = 0
            while let sample = frames.copyNextSampleBuffer() {
                count += CMSampleBufferGetNumSamples(sample)
                if codec == .proRes4444, let pixel = CMSampleBufferGetImageBuffer(sample) {
                    CVPixelBufferLockBaseAddress(pixel, .readOnly)
                    let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
                    let offset = 140 * CVPixelBufferGetBytesPerRow(pixel) + 250 * 4
                    #expect(bytes[offset + 3] < 3)
                    CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
                }
            }
            #expect(count == 3)
        }
    }
}
