import AppKit
import AVFoundation
import SwiftUI
import XCTest
import VideoEditorCore
@testable import VideoEditorUI

private actor WaveformResolver: MediaResolver {
    let url: URL
    private(set) var calls = 0
    init(url: URL) { self.url = url }
    func resolve(_ source: ClipSource) async throws -> ResolvedMedia {
        calls += 1
        return .file(url, naturalDuration: 1, naturalSize: nil)
    }
    func thumbnail(for source: ClipSource, at time: TimeInterval) async -> CGImage? { nil }
}

final class WaveformViewTests: XCTestCase {
    @MainActor
    func testWaveformLoadsAndPreviewPlayheadFollowsTime() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("waveform-view-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        let data = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<48_000 {
            data[0][frame] = Float(sin(Double(frame) * 2 * .pi * 1_000 / 48_000)) * (frame < 24_000 ? 0.8 : 0.1)
        }
        do {
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buffer)
        }
        let resolver = WaveformResolver(url: url)
        let host = NSHostingView(rootView:
            ZStack {
                Color.green
                ClipWaveformView(source: ClipSource(id: "test", kind: .audio, displayName: "Hello world v1"),
                                 resolver: resolver, inPoint: 0, duration: 1, volume: 1)
                    .frame(height: 28)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }.frame(width: 400, height: 46)
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 46), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<40 {
            if await resolver.calls > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let calls = await resolver.calls
        XCTAssertGreaterThan(calls, 0, "The initially empty waveform must mount and start resolving its source")
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/film-timeline-waveform-test.png"))
        var brightPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.redComponent > 0.55, color.blueComponent > 0.55 {
                    brightPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(brightPixels, 500, "Decoded audio must draw a visible waveform, not just the clip background")

        let preview = NSHostingView(rootView: AudioWaveformView(url: url, currentTime: 0).frame(width: 400, height: 46))
        window.contentView = preview
        // Render successive playback/seek positions through the same view instance.
        for time in [0.0, 0.25, 0.75, 1.0, 0.1] {
            preview.rootView = AudioWaveformView(url: url, currentTime: time).frame(width: 400, height: 46)
            try await Task.sleep(for: .milliseconds(100))
            preview.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(preview.bitmapImageRepForCachingDisplay(in: preview.bounds))
            preview.cacheDisplay(in: preview.bounds, to: image)
            if time == 0.25, let png = image.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: "/tmp/film-waveform-playhead.png"))
            }
            let expectedX = min(max(1, 400 * time), 399) * Double(image.pixelsWide) / 400
            var redPixels = 0
            for y in 0..<image.pixelsHigh {
                for x in 0..<image.pixelsWide {
                    guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          color.redComponent > color.greenComponent + 0.3,
                          color.redComponent > color.blueComponent + 0.3 else { continue }
                    redPixels += 1
                    XCTAssertLessThanOrEqual(abs(Double(x) - expectedX), 10, "Playhead must move to the current playback time")
                }
            }
            XCTAssertGreaterThan(redPixels, 40, "Playhead must remain visible, including the start and end")
        }

        // Reusing cached geometry must still react to gain, trim and layout.
        for (gain, start, width, minimum, maximum) in [
            (Float(0), 0.0, 400.0, 0, 2_000),
            (Float(1), 0.0, 400.0, 8_000, Int.max),
            (Float(1), 0.5, 400.0, 500, 8_000),
            (Float(1), 0.0, 200.0, 4_000, Int.max)
        ] {
            preview.rootView = AudioWaveformView(url: url, inPoint: start, duration: 0.5, volume: gain)
                .frame(width: width, height: 46)
            try await Task.sleep(for: .milliseconds(100))
            preview.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(preview.bitmapImageRepForCachingDisplay(in: preview.bounds))
            preview.cacheDisplay(in: preview.bounds, to: image)
            var bright = 0
            for y in 0..<image.pixelsHigh {
                for x in 0..<image.pixelsWide {
                    if let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.redComponent > 0.55, color.blueComponent > 0.55 {
                        bright += 1
                    }
                }
            }
            // Normalize Retina screenshots to points for stable area checks.
            let scale = Double(image.pixelsWide) / Double(preview.bounds.width)
            let area = Double(bright) / (scale * scale)
            XCTAssertGreaterThanOrEqual(area, Double(minimum))
            XCTAssertLessThan(area, Double(maximum))
        }


    }
}
