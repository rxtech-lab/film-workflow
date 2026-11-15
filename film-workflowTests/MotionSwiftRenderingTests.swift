import AVFoundation
import AppKit
import Foundation
import MotionCore
import MotionEditor
import MotionRuntime
import MotionSwiftUI
import Testing
@testable import film_workflow

@Suite("MotionSwift rendering", .serialized) @MainActor
struct MotionSwiftRenderingTests {
    private static let composition = """
    import {AbsoluteFill, Audio, interpolate, staticFile, useCurrentFrame} from 'remotion';
    export const COMPOSITION_WIDTH = 320;
    export const COMPOSITION_HEIGHT = 180;
    export const COMPOSITION_FPS = 30;
    export const COMPOSITION_DURATION_IN_FRAMES = 30;
    export const MyComposition = () => {
      const frame = useCurrentFrame();
      return <AbsoluteFill>
        <Audio src={staticFile('tone.wav')} volume={0.5} />
        <div style={{position: 'absolute', left: interpolate(frame, [0, 29], [0, 160]), top: 40,
                     width: 100, height: 100, backgroundColor: '#ff0000'}} />
      </AbsoluteFill>;
    };
    """

    /// A scaffolded project with a transparent background, a moving red square and a
    /// one-second 440 Hz tone in `public/`.
    private func makeProject(source: String = composition) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MotionSwift-" + UUID().uuidString)
        try RemotionRuntime.scaffold(at: root)
        try source.write(to: root.appendingPathComponent("src/Composition.tsx"), atomically: true, encoding: .utf8)
        try writeTone(to: root.appendingPathComponent("public/tone.wav"))
        return root
    }

    private func writeTone(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for channel in 0..<2 {
            for index in 0..<48_000 { buffer.floatChannelData![channel][index] = sinf(Float(index) * 2 * .pi * 440 / 48_000) * 0.8 }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    @Test("Native H.264 export carries the composition's mixed audio")
    func opaqueMovieWithAudio() async throws {
        let root = try makeProject(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("out/movie.mp4")
        let request = MotionSwiftMovieRenderer.Request(projectDir: root, output: output, width: 320, height: 180, fps: 30,
                                                       preserveAlpha: false, captureScale: nil)
        try await MotionSwiftMovieRenderer.render(request) { _ in }

        let asset = AVURLAsset(url: output)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await video.load(.naturalSize)
        #expect(size == CGSize(width: 320, height: 180))
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 1) < 0.05)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        #expect(audio.count == 1)

        // The square has moved right by the last frame.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let last = try await generator.image(at: CMTime(value: 29, timescale: 30)).image
        let pixel = try #require(NSBitmapImageRep(cgImage: last).colorAt(x: 250, y: 90))
        #expect(pixel.redComponent > 0.8 && pixel.greenComponent < 0.2)
    }

    @Test("Native ProRes 4444 export keeps transparency and honours capture scale")
    func alphaMovie() async throws {
        let root = try makeProject(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("out/alpha.mov")
        let request = MotionSwiftMovieRenderer.Request(projectDir: root, output: output, width: 320, height: 180, fps: 30,
                                                       preserveAlpha: true, captureScale: 0.5)
        try await MotionSwiftMovieRenderer.render(request) { _ in }

        let asset = AVURLAsset(url: output)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.naturalSize) == CGSize(width: 160, height: 90))
        let formats = try await video.load(.formatDescriptions)
        #expect(formats.first.map(CMFormatDescriptionGetMediaSubType) == kCMVideoCodecType_AppleProRes4444)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let first = NSBitmapImageRep(cgImage: try await generator.image(at: .zero).image)
        #expect((first.colorAt(x: 150, y: 80)?.alphaComponent ?? 1) < 0.05)   // background stays clear
        #expect((first.colorAt(x: 25, y: 45)?.alphaComponent ?? 0) > 0.95)    // the square is opaque
    }

    @Test("Native still is written at the requested size")
    func still() async throws {
        let root = try makeProject(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try await RemotionStillCapture.still(projectDir: root, frame: 0, width: 320, height: 180, runId: "test")
        let image = try #require(NSImage(contentsOf: url))
        let rep = try #require(image.representations.first as? NSBitmapImageRep)
        #expect(rep.pixelsWide == 320 && rep.pixelsHigh == 180)
        let red = try #require(rep.colorAt(x: 50, y: 90))
        #expect(red.redComponent > 0.9 && red.alphaComponent > 0.9)
    }

    @Test("Export size reaches every composition registration and rendered component")
    func exportDimensionsOverrideRegistrations() async throws {
        let root = try makeProject(source: """
        import {AbsoluteFill, Sequence, useVideoConfig} from 'remotion';
        export const COMPOSITION_WIDTH = 160;
        export const COMPOSITION_HEIGHT = 90;
        export const COMPOSITION_FPS = 30;
        export const COMPOSITION_DURATION_IN_FRAMES = 2;
        export const MyComposition = () => {
          const {width, height} = useVideoConfig();
          return <AbsoluteFill style={{backgroundColor: '#000000'}}>
            <Sequence from={0}>
              <div style={{position: 'absolute', left: width - 40, top: height - 40,
                           width: 40, height: 40, backgroundColor: '#ff0000'}} />
            </Sequence>
          </AbsoluteFill>;
        };
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        import {Composition, Still} from 'remotion';
        import {MyComposition} from './Composition';
        export const RemotionRoot = () => <>
          <Composition id="Main" component={MyComposition} width={160} height={90} fps={30} durationInFrames={2} />
          <Composition id="Other" component={MyComposition} width={80} height={80} fps={30} durationInFrames={2} />
          <Still id="Poster" component={MyComposition} width={100} height={100} />
        </>;
        """.write(to: root.appendingPathComponent("src/Root.tsx"), atomically: true, encoding: .utf8)
        let prepared = try await MotionSwiftEngine.prepare(projectDir: root)
        let composition = try MotionSwiftEngine.composition(prepared.composition, width: 640, height: 360, fps: nil)
        let runtime = try Runtime(bundle: MotionSwiftEngine.renderBundle(prepared.bundle, composition: composition))
        let catalog = try runtime.compositions()
        #expect(catalog.count == 3)
        #expect(catalog.allSatisfy { $0.width == 640 && $0.height == 360 })

        // Pixel checks catch an output-sized canvas whose component still sees 160×90.
        // Capture scaling must reduce pixels without changing the layout dimensions.
        let still = root.appendingPathComponent("still.png")
        try await MotionSwiftEngine.renderStill(projectDir: root, frame: 0, width: 640, height: 360, scale: 0.5, to: still)
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: still)))
        #expect(bitmap.pixelsWide == 320 && bitmap.pixelsHigh == 180)
        #expect((bitmap.colorAt(x: 310, y: 170)?.redComponent ?? 0) > 0.9)
        #expect((bitmap.colorAt(x: 70, y: 35)?.redComponent ?? 1) < 0.1)

        let movie = root.appendingPathComponent("out/resized.mp4")
        try await MotionSwiftMovieRenderer.render(.init(projectDir: root, output: movie, width: 640, height: 360,
                                                        fps: 30, preserveAlpha: false, captureScale: nil)) { _ in }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let frame = NSBitmapImageRep(cgImage: try await generator.image(at: CMTime(value: 1, timescale: 30)).image)
        #expect(frame.pixelsWide == 640 && frame.pixelsHigh == 360)
        #expect((frame.colorAt(x: 620, y: 340)?.redComponent ?? 0) > 0.8)
        #expect((frame.colorAt(x: 140, y: 70)?.redComponent ?? 1) < 0.2)
        #expect(try String(contentsOf: root.appendingPathComponent("src/Composition.tsx"), encoding: .utf8)
            .contains("COMPOSITION_WIDTH = 160"))
    }

    @Test("The element editor opens a Film Studio project and selects its elements")
    func editorOpensProject() async throws {
        let root = try makeProject(); defer { try? FileManager.default.removeItem(at: root) }
        let model = EditorModel(project: root, entry: MotionSwiftEngine.entry)
        await model.open(compositionID: MotionSwiftEngine.compositionID)
        #expect(model.status == .idle)
        #expect(model.player.composition?.id == "Main")
        #expect(model.files.keys.contains("src/Composition.tsx"))
        _ = try await model.player.render(frame: 0)
    }

    @Test("Compositions outside MotionSwift's subset fail with a compile error")
    func unsupportedPackageFails() async throws {
        let root = try makeProject(source: """
        import {AbsoluteFill} from 'remotion';
        import {doesNotExist} from 'remotion-package-that-is-not-installed';
        export const COMPOSITION_WIDTH = 320;
        export const COMPOSITION_HEIGHT = 180;
        export const COMPOSITION_FPS = 30;
        export const COMPOSITION_DURATION_IN_FRAMES = 10;
        export const MyComposition = () => <AbsoluteFill>{String(doesNotExist)}</AbsoluteFill>;
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("out/failed.mp4")
        await #expect(throws: (any Error).self) {
            try await RemotionRenderer.render(projectDir: root, to: output, width: 320, height: 180, fps: 30) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
