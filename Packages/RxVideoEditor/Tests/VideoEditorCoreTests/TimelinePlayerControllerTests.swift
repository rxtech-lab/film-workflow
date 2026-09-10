import AVFoundation
import Foundation
import Testing

@testable import VideoEditorCore

@Suite("Timeline playback cursor")
@MainActor
struct TimelinePlayerControllerTests {
    @Test("An empty timeline allows seeking and stepping beyond its content")
    func seekBeyondContent() async {
        let controller = TimelinePlayerController()
        controller.seek(to: 120)
        await Task.yield()
        #expect(controller.currentTime == 120)
        #expect(controller.duration == 0)

        controller.step(frames: 1)
        #expect(abs(controller.currentTime - (120 + 1.0 / 30)) < 0.000001)
        controller.seek(to: -10)
        #expect(controller.currentTime == 0)
    }

    @Test("Repeated seeks retain the latest editing position")
    func repeatedSeeks() async {
        let controller = TimelinePlayerController()
        for time in 0...100 { controller.seek(to: Double(time)) }
        await Task.yield()
        #expect(controller.currentTime == 100)
        controller.unload()
        #expect(controller.currentTime == 0)
    }

    @Test("Live volume and mute edits retain the playing item and cursor")
    func liveVolume() async throws {
        let dir = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("volume.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144_000))
        buffer.frameLength = 144_000
        let samples = try #require(buffer.floatChannelData)
        for i in 0..<144_000 { samples[0][i] = Float(sin(Double(i) * 0.1)) * 0.1 }
        do {
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buffer)
        }
        let source = ClipSource(id: "volume", kind: .audio, displayName: "Volume")
        var timeline = Timeline(tracks: [Track(kind: .audio, name: "Audio", clips: [Clip(source: source, start: 0, duration: 3, volume: 0)])])
        let resolver = FixtureResolver(files: [source.id: .file(url, naturalDuration: 3, naturalSize: nil)])
        let controller = TimelinePlayerController()
        defer { controller.unload() }
        controller.load(timeline, resolver: resolver)
        for _ in 0..<100 {
            if controller.player.currentItem != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let item = try #require(controller.player.currentItem)
        try await Task.sleep(for: .milliseconds(100))
        await controller.player.seek(to: CMTime(seconds: 0.5, preferredTimescale: 600))
        controller.play()
        for volume: Float in [0.5, 1, 0, 1.5] {
            let before = CMTimeGetSeconds(controller.player.currentTime())
            timeline.tracks[0].clips[0].volume = volume
            controller.load(timeline, resolver: resolver)
            try await Task.sleep(for: .milliseconds(100))
            #expect(controller.player.currentItem === item)
            #expect(controller.isPlaying)
            #expect(controller.player.rate == 1)
            #expect(CMTimeGetSeconds(controller.player.currentTime()) >= before - 0.02)
            let input = try #require(controller.player.currentItem?.audioMix?.inputParameters.first)
            var gain: Float = -1
            #expect(input.getVolumeRamp(for: .zero, startVolume: &gain, endVolume: nil, timeRange: nil))
            #expect(gain == volume)
        }
        timeline.tracks[0].isMuted = true
        controller.load(timeline, resolver: resolver)
        #expect(controller.player.currentItem === item)
        let input = try #require(item.audioMix?.inputParameters.first)
        var gain: Float = -1
        #expect(input.getVolumeRamp(for: .zero, startVolume: &gain, endVolume: nil, timeRange: nil))
        #expect(gain == 0)
    }

}
