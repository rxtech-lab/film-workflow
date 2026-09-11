import AVFoundation
import CoreImage
import Testing
import VideoEffectsCore
@testable import VideoEditorCore

@Suite("Reduced-resolution preview framing", .serialized)
@MainActor
struct PreviewFramingTests {
    @Test("Preview scaling preserves all four video corners with and without transitions")
    func scaledVideoFrames() async throws {
        let dir = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("quadrants.mp4")
        let size = CGSize(width: 640, height: 360)
        var pattern = CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: size))
        for (color, rect) in [(CIColor.red, CGRect(x: 0, y: 0, width: 320, height: 180)),
                              (CIColor.green, CGRect(x: 320, y: 0, width: 320, height: 180)),
                              (CIColor.blue, CGRect(x: 0, y: 180, width: 320, height: 180))] {
            pattern = CIImage(color: color).cropped(to: rect).composited(over: pattern)
        }
        let context = CIContext()
        let image = try #require(context.createCGImage(pattern, from: pattern.extent))
        try Fixtures.video(color: .black, seconds: 2, size: (640, 360), image: image, at: url)
        let clip = Clip(source: .init(id: "video", kind: .video, displayName: "Corners"), start: 0, duration: 2)
        let resolver = FixtureResolver(files: ["video": .file(url, naturalDuration: 2, naturalSize: size)])
        var timeline = Timeline(width: 1280, height: 720, tracks: [Track(kind: .video, name: "V1", clips: [clip])])
        for transition in [false, true] {
            if transition { try TimelineEditor.addTransition(&timeline, definitionID: "rx.cross-dissolve", attachment: .start(clip.id)) }
            var reference: [Double: [[UInt8]]] = [:]
            for scale: Float in [1, 0.5, 0.25] {
                let built = try await TimelineCompositionBuilder(resolver: resolver).build(timeline, allowPlaceholders: true)
                built.videoComposition.renderScale = scale
                // AVAssetImageGenerator and export reject renderScale != 1. Read the
                // actual AVPlayer output to exercise the same path as the viewer.
                for time in [0.5, 1.5] {
                    let frame = try await playerFrame(built, at: time)
                    #expect(frame.width == Int(1280 * scale) && frame.height == Int(720 * scale))
                    let raster = CIImage(cgImage: frame)
                    let corners = [(0.25, 0.25, [255, 0, 0]), (0.75, 0.25, [0, 255, 0]),
                                   (0.25, 0.75, [0, 0, 255]), (0.75, 0.75, [255, 255, 255])]
                    var samples: [[UInt8]] = []
                    for (index, corner) in corners.enumerated() {
                        let (x, y, expected) = corner
                        var bytes = [UInt8](repeating: 0, count: 4)
                        context.render(raster, toBitmap: &bytes, rowBytes: 4,
                                       bounds: CGRect(x: Double(frame.width) * x, y: Double(frame.height) * y, width: 1, height: 1),
                                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                        for channel in 0..<3 {
                            if time == 1.5 {
                                #expect(abs(Int(bytes[channel]) - expected[channel]) < 80,
                                        "scale \(scale), transition \(transition), corner \(x),\(y): \(bytes)")
                            }
                            if let full = reference[time] {
                                #expect(abs(Int(bytes[channel]) - Int(full[index][channel])) < 5,
                                        "Framing changed at time \(time), scale \(scale), transition \(transition), corner \(x),\(y)")
                            }
                        }
                        samples.append(bytes)
                    }
                    if scale == 1 { reference[time] = samples }
                }
            }
        }
    }

    private func playerFrame(_ built: BuiltComposition, at seconds: Double) async throws -> CGImage {
        let item = AVPlayerItem(asset: built.asset)
        item.videoComposition = built.videoComposition
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        defer { player.replaceCurrentItem(with: nil) }
        let deadline = ContinuousClock.now + .seconds(5)
        while item.status == .unknown, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(item.status == .readyToPlay, "\(String(describing: item.error))")
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        var buffer: CVPixelBuffer?
        while buffer == nil, ContinuousClock.now < deadline {
            var displayed = CMTime.invalid
            if let candidate = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayed),
               abs(displayed.seconds - seconds) < 1.0 / 30 {
                buffer = candidate
            }
            if buffer == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let raster = CIImage(cvPixelBuffer: try #require(buffer, "Player did not produce a frame"))
        return try #require(CIContext().createCGImage(raster, from: raster.extent))
    }
}
