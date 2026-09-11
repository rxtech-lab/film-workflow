import AppKit
import AVFoundation
import Testing
@testable import RxRemotion

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RX_REMOTION_INTEGRATION"] == "1"))
@MainActor
struct PreviewResolutionTests {
    @Test("Smaller preview pixels retain logical layout, alpha, every frame, and audio")
    func scaledCapture() async throws {
        let helper = MediaIntegrationTests()
        let root = try helper.project(helper.constants + """
        import {AbsoluteFill,Audio,staticFile,useCurrentFrame,useVideoConfig} from 'remotion';
        export function MyComposition(){const f=useCurrentFrame(),{width,height,fps}=useVideoConfig();
        if(width!==320||height!==180||fps!==30)throw Error('Preview changed logical configuration');
        return <AbsoluteFill><div style={{position:'absolute',left:f<15?40:200,top:40,width:80,height:80,background:'lime'}}/>
        <Audio src={staticFile('tone.wav')}/></AbsoluteFill>}
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        try MediaIntegrationTests.wav().write(to: root.appendingPathComponent("public/tone.wav"))
        let engine = RemotionEngine(); defer { engine.closeAll() }
        let project = try await engine.prepare(projectURL: root)
        let still = root.appendingPathComponent("preview.png")
        try await engine.renderStill(project: project, frame: 15, to: still, settings: .init(captureScale: 0.5))
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: still)))
        #expect(bitmap.pixelsWide == 160 && bitmap.pixelsHigh == 90)
        #expect(try #require(bitmap.colorAt(x: 120, y: 40)).greenComponent > 0.9)
        #expect(try #require(bitmap.colorAt(x: 40, y: 40)).alphaComponent < 0.01)
        let movie = root.appendingPathComponent("preview.mov")
        try await engine.renderMovie(project: project, to: movie, settings: .init(codec: .proRes4444, captureScale: 0.5))
        let asset = AVURLAsset(url: movie)
        #expect(abs(try await asset.load(.duration).seconds - 1) < 0.001)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 160, height: 90))
        #expect(try await track.load(.nominalFrameRate) == 30)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); #expect(reader.startReading())
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let bytes = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let row = 40 * CVPixelBufferGetBytesPerRow(buffer)
            let box = row + (count < 15 ? 40 : 120) * 4
            let clear = row + (count < 15 ? 120 : 40) * 4
            #expect(bytes[box + 1] > 230 && bytes[box + 3] > 230)
            #expect(bytes[clear + 3] < 3)
            #expect(abs(CMSampleBufferGetPresentationTimeStamp(sample).seconds - Double(count) / 30) < 0.001)
            count += 1
        }
        #expect(reader.status == .completed && count == 30)
    }
}

struct PreviewResolutionSettingsTests {
    @Test func legacySettingsKeepFullResolution() throws {
        let settings = try JSONDecoder().decode(RemotionRenderSettings.self, from: Data(#"{"codec":"proRes4444","width":320,"height":180}"#.utf8))
        let composition = RemotionComposition(id: "Main", width: 320, height: 180, fps: 30, durationInFrames: 30)
        #expect(settings.captureScale == nil)
        #expect(settings.capturedComposition(composition) == composition)
    }
}
