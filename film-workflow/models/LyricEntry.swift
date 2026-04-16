import Foundation

struct LyricEntry: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var timestamp: TimeInterval
    var content: String

    var formattedTimestamp: String {
        SongStructureEntry.formatTime(timestamp)
    }
}
