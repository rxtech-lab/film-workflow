import Foundation
import Testing

@testable import VideoEditorCore

@Suite("Timeline codec")
struct TimelineCodecTests {
    @Test("Round-trips every field")
    func roundTrip() throws {
        var t = Timeline(width: 1280, height: 720, fps: 24, backgroundHex: "#112233")
        let v = t.tracks.first { $0.kind == .video }!.id
        let clip = Clip(
            source: ClipSource(id: "video:1", kind: .video, displayName: "One"),
            start: 1.5, duration: 3, inPoint: 0.25, volume: 0.5, opacity: 0.75,
            transform: ClipTransform(fit: .fill, scale: 1.2, offsetX: 0.1, offsetY: -0.1),
            text: nil
        )
        try TimelineEditor.insert(&t, clip: clip, on: v)
        let o = t.tracks.first { $0.kind == .caption }!.id
        try TimelineEditor.insert(&t, clip: Clip(source: ClipSource(id: "caption:1", kind: .captions, displayName: "Cap"), start: 0, duration: 4, text: TextStyle(fontSize: 0.07)), on: o)

        let data = try TimelineCodec.encode(t)
        let back = try TimelineCodec.decode(data)
        #expect(back == t)
    }

    @Test("Missing and unknown fields are tolerated")
    func tolerant() throws {
        let json = """
        {"formatVersion": 1, "timeline": {"width": 100, "height": 50, "tracks": [
            {"id": "\(UUID().uuidString)", "kind": "video", "name": "V1", "clips": [
                {"source": {"id": "x", "kind": "image", "displayName": "X"}, "start": 2, "duration": 5, "future": true}
            ], "isMuted": false}
        ], "someNewThing": 1}}
        """
        let t = try TimelineCodec.decode(Data(json.utf8))
        #expect(t.width == 100 && t.height == 50 && t.fps == 30)
        let clip = try #require(t.allClips.first)
        #expect(clip.opacity == 1 && clip.volume == 1 && clip.transform == .identity && clip.inPoint == 0)
        #expect(clip.start == 2 && clip.duration == 5)
    }
}
