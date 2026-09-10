import Foundation

/// Versioned JSON encoding for a `Timeline`, tolerant of unknown fields so a
/// newer app can add properties without breaking older readers.
public enum TimelineCodec {
    private struct Envelope: Codable {
        var formatVersion: Int
        var timeline: Timeline
    }

    public static func encode(_ timeline: Timeline) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Envelope(formatVersion: Timeline.formatVersion, timeline: timeline))
    }

    public static func decode(_ data: Data) throws -> Timeline {
        let decoder = JSONDecoder()
        return try decoder.decode(Envelope.self, from: data).timeline
    }
}
