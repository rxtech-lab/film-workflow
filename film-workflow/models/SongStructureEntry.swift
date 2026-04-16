import Foundation

struct SongStructureEntry: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var type: SongSectionType
    var startTime: TimeInterval
    var endTime: TimeInterval
    var intensity: Double
    var description: String

    var formattedStartTime: String {
        Self.formatTime(startTime)
    }

    var formattedEndTime: String {
        Self.formatTime(endTime)
    }

    var formattedTimeRange: String {
        "[\(formattedStartTime) - \(formattedEndTime)]"
    }

    var intensityLabel: String {
        switch intensity {
        case 0..<0.25: return "low"
        case 0.25..<0.5: return "medium"
        case 0.5..<0.75: return "high"
        default: return "very high"
        }
    }

    static func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func parseTime(_ string: String) -> TimeInterval? {
        let parts = string.split(separator: ":")
        guard parts.count == 2,
              let minutes = Int(parts[0]),
              let seconds = Int(parts[1]) else { return nil }
        return TimeInterval(minutes * 60 + seconds)
    }
}
