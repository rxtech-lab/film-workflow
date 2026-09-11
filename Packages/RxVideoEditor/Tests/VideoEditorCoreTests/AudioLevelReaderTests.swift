import AVFoundation
import Foundation
import Testing
@testable import VideoEditorCore

@Suite("Viewer stereo audio levels")
struct AudioLevelReaderTests {
    @Test("Expanded waveform interpolates smoothly without losing overview peaks")
    func waveformInterpolation() {
        let waveform = AudioWaveform(duration: 3, peaks: [0, 1, 0])
        let rising = stride(from: 0.5, through: 1.5, by: 0.1).map {
            waveform.displayPeak(from: $0 - 0.01, to: $0 + 0.01)
        }
        #expect(zip(rising, rising.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(rising.dropFirst().dropLast().allSatisfy { $0 > 0 && $0 < 1 })
        #expect(abs(waveform.displayPeak(from: 0.99, to: 1.01) - 0.5) < 0.001)
        #expect(waveform.displayPeak(from: 0, to: 3) == 1)
        #expect(waveform.displayPeak(from: 3, to: 4) == 0)
        #expect(waveform.displayPeak(from: .nan, to: 1) == 0)
        #expect(AudioWaveform(duration: 1, peaks: [0.4]).displayPeak(from: 0.1, to: 0.2) == 0.4)
    }

    private func audio(at url: URL, left: Float = 0.5, right: Float = 0.125, channels: AVAudioChannelCount = 2) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        let data = try #require(buffer.floatChannelData)
        for frame in 0..<48_000 {
            let wave = Float(sin(2 * Double.pi * 1_000 * Double(frame) / 48_000))
            // Second half is silent, for seek/stale-level coverage.
            data[0][frame] = frame < 24_000 ? left * wave : 0
            if channels > 1 { data[1][frame] = frame < 24_000 ? right * wave : 0 }
        }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }

    @Test("Footage preserves independent channels and clears after seeking into silence")
    func footage() async throws {
        let dir = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stereo.wav")
        try audio(at: url)
        let reader = AudioLevelReader()
        await reader.setSource(AudioLevelSource(asset: AVURLAsset(url: url), mix: nil))
        for time in [0.0, 0.05, 0.1, 0.3] {
            let level = await reader.level(at: time)
            #expect(abs(level.left - 0.5) < 0.001)
            #expect(abs(level.right - 0.125) < 0.001)
        }
        #expect(await reader.level(at: 0.7) == .silence)
        #expect(await reader.level(at: 0.1).left > 0.49)
        #expect(await reader.level(at: 1.2) == .silence)
        await reader.setSource(nil)
        #expect(await reader.level(at: 0.1) == .silence)
    }

    @Test("Project meters measure the summed mix after clip gain, including phase cancellation")
    func composition() async throws {
        let dir = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("original.wav")
        let inverseURL = dir.appendingPathComponent("inverse.wav")
        try audio(at: url)
        try audio(at: inverseURL, left: -0.5, right: -0.125)
        let composition = AVMutableComposition()
        var parameters: [AVMutableAudioMixInputParameters] = []
        for (index, file) in [url, inverseURL].enumerated() {
            let asset = AVURLAsset(url: file)
            let source = try #require(try await asset.loadTracks(withMediaType: .audio).first)
            let track = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 48_000)), of: source, at: .zero)
            let gain = AVMutableAudioMixInputParameters(track: track)
            gain.setVolume(index == 0 ? 1 : 0.5, at: .zero)
            parameters.append(gain)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        let reader = AudioLevelReader()
        await reader.setSource(AudioLevelSource(asset: composition, mix: mix))
        let level = await reader.level(at: 0.1)
        #expect(abs(level.left - 0.25) < 0.001)
        #expect(abs(level.right - 0.0625) < 0.001)
        parameters[1].setVolume(1, at: .zero)
        mix.inputParameters = parameters
        await reader.setSource(AudioLevelSource(asset: composition, mix: mix))
        let cancelled = await reader.level(at: 0.1)
        #expect(cancelled.left < 0.001)
        #expect(cancelled.right < 0.001)
    }

    @Test("Mono footage appears in both meters and replacing a source drops old samples")
    func monoAndReplacement() async throws {
        let dir = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mono.wav")
        try audio(at: url, channels: 1)
        let reader = AudioLevelReader()
        await reader.setSource(AudioLevelSource(asset: AVURLAsset(url: url), mix: nil))
        let level = await reader.level(at: 0.1)
        #expect(level.left > 0)
        #expect(abs(level.left - level.right) < 0.001)
        await reader.setSource(AudioLevelSource(asset: AVMutableComposition(), mix: nil))
        #expect(await reader.level(at: 0.1) == .silence)
    }

    @Test("Waveform uses source time for trims, retains either stereo channel, and shows silence")
    func waveform() async throws {
        let dir = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("waveform.wav")
        try audio(at: url, left: 0, right: 0.5)
        let cache = AudioWaveformCache()
        let summary = try #require(await cache.waveform(for: url))
        #expect(abs(summary.duration - 1) < 0.001)
        #expect(summary.peaks.count == 100)
        #expect(summary.peak(from: 0.1, to: 0.2) > 0.4)
        #expect(summary.peak(from: 0.7, to: 0.8) < 0.001)
        #expect(summary.peak(from: 1.1, to: 1.2) == 0)
        #expect(summary.peak(from: -1, to: -0.5) == 0)
        #expect(summary.peak(from: 0.2, to: 0.2) == 0)
        let cached = try #require(await cache.waveform(for: url))
        #expect(cached.peaks == summary.peaks)
        #expect(await cache.waveform(for: dir.appendingPathComponent("missing.wav")) == nil)
    }

}
