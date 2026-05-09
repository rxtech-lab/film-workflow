import Foundation
import SwiftUI

enum Tabs: Codable, Identifiable, CaseIterable {
    case Music
    case Narrative
    case Remotion
    case Settings

    var id: String {
        switch self {
        case .Music: return "Music"
        case .Narrative: return "Narrative"
        case .Remotion: return "Remotion"
        case .Settings: return "Settings"
        }
    }

    var displayName: LocalizedStringKey {
        switch self {
        case .Music: return "Music"
        case .Narrative: return "Narrative"
        case .Remotion: return "Remotion"
        case .Settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .Music: return "music.note"
        case .Narrative: return "text.book.closed"
        case .Remotion: return "film.stack"
        case .Settings: return "gear"
        }
    }
}
