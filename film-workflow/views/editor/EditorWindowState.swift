import Foundation
import Observation
import SwiftUI
import VideoEditorCore

/// The footage kinds the library shows. Six generators, imported files, and
/// the sequences that assemble them.
enum FootageKind: String, CaseIterable, Codable, Identifiable {
    case sequence
    case music
    case narration
    case caption
    case image
    case video
    case remotion
    case imported

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .sequence: return "Sequence"
        case .music: return "Music"
        case .narration: return "Narration"
        case .caption: return "Captions"
        case .image: return "Images"
        case .video: return "Video"
        case .remotion: return "Remotion"
        case .imported: return "Imported"
        }
    }

    var systemImage: String {
        switch self {
        case .sequence: return "film.stack"
        case .music: return "music.note"
        case .narration: return "text.book.closed"
        case .caption: return "captions.bubble"
        case .image: return "photo.on.rectangle.angled"
        case .video: return "video.badge.waveform"
        case .remotion: return "atom"
        case .imported: return "paperclip"
        }
    }

    var agentKind: AgentTargetKind? {
        switch self {
        case .music: return .music
        case .narration: return .narrative
        case .caption: return .caption
        case .image: return .imageGen
        case .video: return .videoGen
        case .remotion: return .remotion
        case .sequence, .imported: return nil
        }
    }

    /// Kinds offered by the New menu.
    static var creatable: [FootageKind] { [.sequence, .music, .narration, .caption, .image, .video, .remotion] }
}

struct LibraryItemID: Hashable, Codable {
    let kind: FootageKind
    let id: UUID
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case footage
    case sequence
    case clip
    var id: String { rawValue }
}

/// Per-window editor state: what is selected in the library, which sequence
/// the timeline shows, and the preview player.
@MainActor
@Observable
final class EditorWindowState {
    var selection: LibraryItemID?
    var currentSequenceID: UUID?
    var selectedClipID: UUID? {
        didSet { if selectedClipID != nil { inspectorTab = .clip } }
    }
    var inspectorTab: InspectorTab = .footage
    var playhead: TimeInterval = 0 {
        didSet { if !player.isPlaying { player.seek(to: playhead) } }
    }
    let player = TimelinePlayerController()

    var showImportSheet = false
    var pendingImportURLs: [URL] = []
    var showRenderSheet = false
    var renderProgress: SequenceRenderProgress?
    var renderTask: Task<Void, Never>?
    var renderError: String?
    var showRenderError = false

    func select(_ item: LibraryItemID?) {
        selection = item
        if let item, item.kind == .sequence {
            currentSequenceID = item.id
            inspectorTab = .sequence
        } else {
            inspectorTab = .footage
        }
        selectedClipID = nil
    }
}
