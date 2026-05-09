import Foundation
import SwiftUI

enum Tabs: Codable, Identifiable, CaseIterable {
    case Music
    case Narrative
    case ImageGen
    case Remotion
    case Settings

    var id: String {
        switch self {
        case .Music: return "Music"
        case .Narrative: return "Narrative"
        case .ImageGen: return "ImageGen"
        case .Remotion: return "Remotion"
        case .Settings: return "Settings"
        }
    }

    var displayName: LocalizedStringKey {
        switch self {
        case .Music: return "Music"
        case .Narrative: return "Narrative"
        case .ImageGen: return "Image"
        case .Remotion: return "Remotion"
        case .Settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .Music: return "music.note"
        case .Narrative: return "text.book.closed"
        case .ImageGen: return "photo.on.rectangle.angled"
        case .Remotion: return "film.stack"
        case .Settings: return "gear"
        }
    }
}
