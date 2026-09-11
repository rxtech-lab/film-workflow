import CoreMedia
import Foundation
import Testing
@testable import VideoEditorCore

@Suite("Caption cues on the timeline")
struct CaptionCueTimelineTests {
    private let source = ClipSource(id: "caption:c", kind: .captions, displayName: "C")

    @Test("Cues shift by the clip's start and in point and clip to its range")
    func shiftAndClip() {
        let clip = Clip(source: source, start: 5, duration: 3, inPoint: 1)
        let cues = [
            TextCue(start: 0, end: 0.5, text: "before"),
            TextCue(start: 0.5, end: 1.5, text: "straddles start"),
            TextCue(start: 2, end: 3, text: "inside"),
            TextCue(start: 3.5, end: 5, text: "straddles end"),
            TextCue(start: 6, end: 7, text: "after"),
        ]
        let shifted = clip.timelineCues(cues)
        #expect(shifted.map(\.text) == ["straddles start", "inside", "straddles end"])
        #expect(shifted[0].start == 5 && shifted[0].end == 5.5)
        #expect(shifted[1].start == 6 && shifted[1].end == 7)
        #expect(shifted[2].start == 7.5 && shifted[2].end == 8)
        #expect(clip.timelineInterval(sourceStart: 4, sourceEnd: 4) == nil)
    }

    @Test("Overlapping cues flatten into non-overlapping cues with joined text")
    func flatten() {
        let cues = [TextCue(start: 0, end: 2, text: "A"), TextCue(start: 1, end: 3, text: "B"), TextCue(start: 4, end: 5, text: "C")]
        let flat = cues.flattened()
        #expect(flat == [
            TextCue(start: 0, end: 1, text: "A"),
            TextCue(start: 1, end: 2, text: "A\nB"),
            TextCue(start: 2, end: 3, text: "B"),
            TextCue(start: 4, end: 5, text: "C"),
        ])
        #expect([TextCue(start: 1, end: 1, text: "zero")].flattened().isEmpty)
        #expect([TextCue(start: 3, end: 4, text: "late"), TextCue(start: 0, end: 1, text: "early")].flattened().map(\.text) == ["early", "late"])
    }

    @Test("The sample plan fills gaps and runs to the end of the movie")
    func samplePlan() {
        let cues = [TextCue(start: 1, end: 2, text: "one"), TextCue(start: 2, end: 2.5, text: "two"), TextCue(start: 9, end: 12, text: "past the end")]
        let plan = SubtitleSampleFactory.samplePlan(cues: cues, duration: CMTime(seconds: 10, preferredTimescale: 600))
        let ms = { (t: CMTime) in Int(CMTimeGetSeconds(t) * 1000) }
        #expect(plan.map(\.text) == [nil, "one", "two", nil, "past the end"])
        #expect(plan.map { ms($0.start) } == [0, 1000, 2000, 2500, 9000])
        #expect(plan.map { ms($0.duration) } == [1000, 1000, 500, 6500, 1000])
        #expect(plan.allSatisfy { $0.start.timescale == SubtitleSampleFactory.timescale })
        #expect(SubtitleSampleFactory.samplePlan(cues: [], duration: CMTime(seconds: 2, preferredTimescale: 600)).map(\.text) == [nil])
        #expect(SubtitleSampleFactory.samplePlan(cues: cues, duration: .zero).isEmpty)
    }

    @Test("Sample payloads carry a big-endian length before the UTF-8 text")
    func payload() {
        #expect(SubtitleSampleFactory.payloadBytes(nil) == [0, 0])
        #expect(SubtitleSampleFactory.payloadBytes("Hi") == [0, 2, 0x48, 0x69])
        #expect(SubtitleSampleFactory.payloadBytes("中") == [0, 3, 0xE4, 0xB8, 0xAD])
    }

    @Test("BCP-47 tags become ISO 639-2 codes for the track header")
    func languageCodes() {
        #expect(SubtitleSampleFactory.iso639_2("en") == "eng")
        #expect(SubtitleSampleFactory.iso639_2("en-US") == "eng")
        #expect(SubtitleSampleFactory.iso639_2("zh-Hans") == "zho")
        #expect(SubtitleSampleFactory.iso639_2("") == nil)
    }
}
