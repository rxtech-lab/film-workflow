import Foundation

enum Tabs: Codable, Identifiable, CaseIterable {
    case Music
    case Narrative
    case Settings

    var id: String {
        switch self {
        case .Music: return "Music"
        case .Narrative: return "Narrative"
        case .Settings: return "Settings"
        }
    }

    var displayName: String { id }

    var systemImage: String {
        switch self {
        case .Music: return "music.note"
        case .Narrative: return "text.book.closed"
        case .Settings: return "gear"
        }
    }
}
