import Foundation

enum Tabs: Codable, Identifiable, CaseIterable {
    case Music
    case Narrative

    var id: String {
        switch self {
        case .Music: return "Music"
        case .Narrative: return "Narrative"
        }
    }

    var displayName: String { id }

    var systemImage: String {
        switch self {
        case .Music: return "music.note"
        case .Narrative: return "text.book.closed"
        }
    }
}
