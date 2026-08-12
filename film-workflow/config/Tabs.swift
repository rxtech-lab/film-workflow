import Foundation
import SwiftUI

enum Tabs: Codable, Identifiable, CaseIterable {
    case Music
    case Narrative
    case Caption
    case ImageGen
    case Remotion
    /// iOS only — on macOS the agent is its own window, not a tab.
    case Agent
    case Settings

    var id: String {
        switch self {
        case .Music: return "Music"
        case .Narrative: return "Narrative"
        case .Caption: return "Caption"
        case .ImageGen: return "ImageGen"
        case .Remotion: return "Remotion"
        case .Agent: return "Agent"
        case .Settings: return "Settings"
        }
    }

    var displayName: LocalizedStringKey {
        switch self {
        case .Music: return "Music"
        case .Narrative: return "Narrative"
        case .Caption: return "Caption"
        case .ImageGen: return "Image"
        case .Remotion: return "Remotion"
        case .Agent: return "Agent"
        case .Settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .Music: return "music.note"
        case .Narrative: return "text.book.closed"
        case .Caption: return "captions.bubble"
        case .ImageGen: return "photo.on.rectangle.angled"
        case .Remotion: return "film.stack"
        case .Agent: return "sparkles"
        case .Settings: return "gear"
        }
    }
}
