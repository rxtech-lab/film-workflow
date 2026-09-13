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
        let player = ControlledTimelinePlayer()
        let controller = TimelinePlayerController(player: player)
        defer { controller.unload() }
        controller.load(timeline, resolver: resolver)
        // Build the real composition and mix, but keep playback independent of
        // audio-device availability and wall-clock delays on CI runners.
        try await wait { !controller.isLoading }
        try #require(controller.lastError == nil)
        let item = try #require(controller.player.currentItem)
        controller.seek(to: 0.5)
        try await wait { player.currentTime().seconds == 0.5 }
        controller.play()
        try #require(controller.isPlaying && player.rate == 1)
        let replacements = player.replacementCount
        let pauses = player.pauseCount
        let seeks = player.seekCount
        for (volume, muted): (Float, Bool) in [(0.5, false), (1, false), (0, false), (1.5, false), (1.5, true), (1.5, false)] {
            player.advance(by: 0.1)
            try await wait { controller.currentTime == player.currentTime().seconds }
            let before = player.currentTime()
            let cursor = controller.currentTime
            timeline.tracks[0].clips[0].volume = volume
            timeline.tracks[0].isMuted = muted
            controller.load(timeline, resolver: resolver)
            await Task.yield()
            #expect(controller.player.currentItem === item)
            #expect(controller.isPlaying)
            #expect(controller.player.rate == 1)
            #expect(!controller.isLoading)
            #expect(player.currentTime() == before)
            #expect(controller.currentTime == cursor)
            #expect(player.replacementCount == replacements)
            #expect(player.pauseCount == pauses)
            #expect(player.seekCount == seeks)
            let input = try #require(controller.player.currentItem?.audioMix?.inputParameters.first)
            var gain: Float = -1
            #expect(input.getVolumeRamp(for: .zero, startVolume: &gain, endVolume: nil, timeRange: nil))
            #expect(gain == (muted ? 0 : volume))
        }
    }

    private func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Transport did not reach the expected state")
    }
}

/// Retains real player items without attaching them to AVFoundation's playback
/// pipeline. Only the main-actor controller and its test drive this transport.
@MainActor
private final class ControlledTimelinePlayer: AVPlayer, @unchecked Sendable {
    private var item: AVPlayerItem?
    private var time = CMTime.zero
    private var playbackRate: Float = 0
    private var timeObserver: (@Sendable (CMTime) -> Void)?
    private(set) var replacementCount = 0
    private(set) var pauseCount = 0
    private(set) var seekCount = 0

    override var currentItem: AVPlayerItem? { MainActor.assumeIsolated { item } }
    override var rate: Float {
        get { MainActor.assumeIsolated { playbackRate } }
        set { MainActor.assumeIsolated { playbackRate = newValue } }
    }

    override func currentTime() -> CMTime { MainActor.assumeIsolated { time } }
    override func play() { rate = 1 }
    override func pause() {
        MainActor.assumeIsolated {
            pauseCount += 1
            rate = 0
        }
    }

    override func replaceCurrentItem(with item: AVPlayerItem?) {
        MainActor.assumeIsolated {
            replacementCount += 1
            self.item = item
            time = .zero
        }
    }

    override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
                       completionHandler: @escaping @Sendable (Bool) -> Void) {
        MainActor.assumeIsolated {
            seekCount += 1
            self.time = time
        }
        completionHandler(true)
    }

    override func addPeriodicTimeObserver(forInterval interval: CMTime, queue: DispatchQueue?,
                                         using block: @escaping @Sendable (CMTime) -> Void) -> Any {
        MainActor.assumeIsolated { timeObserver = block }
        return NSObject()
    }

    override func removeTimeObserver(_ observer: Any) {
        MainActor.assumeIsolated { timeObserver = nil }
    }

    func advance(by seconds: Double) {
        time = time + CMTime(seconds: seconds * Double(rate), preferredTimescale: 600)
        timeObserver?(time)
    }
}
