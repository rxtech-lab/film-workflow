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
    var viewerSelection: LibraryItemID?
    /// The version of each item the viewer previews and the library drags.
    /// Items without an entry use their newest output.
    var currentVersions: [LibraryItemID: UUID] = [:]
    var currentSequenceID: UUID?
    /// The clips selected on the timeline; they move and delete together.
    var selectedClipIDs: Set<UUID> = [] {
        didSet { if !selectedClipIDs.isEmpty { inspectorTab = .clip; showSequenceViewer() } }
    }
    /// The single selected clip, for the inspector and single-clip edits.
    /// Nil while several clips are selected.
    var selectedClipID: UUID? {
        get { selectedClipIDs.count == 1 ? selectedClipIDs.first : nil }
        set { selectedClipIDs = newValue.map { [$0] } ?? [] }
    }
    var inspectorTab: InspectorTab = .footage
    /// Sequence playback has one position; footage players own their own time.
    var playhead: TimeInterval {
        get { player.currentTime }
        set {
            showSequenceViewer()
            player.pause()
            player.seek(to: newValue)
        }
    }
    let player = TimelinePlayerController()
    @ObservationIgnored lazy var preview = TimelinePreviewController(transport: player)

    func showSequenceViewer() {
        if let id = currentSequenceID { viewerSelection = LibraryItemID(kind: .sequence, id: id) }
    }

    var showImportSheet = false
    var pendingImportURLs: [URL] = []
    var showRenderSheet = false
    var renderProgress: SequenceRenderProgress?
    var renderTask: Task<Void, Never>?
    var renderError: String?
    var showRenderError = false

    func select(_ item: LibraryItemID?, updateViewer: Bool = true) {
        selection = item
        if updateViewer { viewerSelection = item }
        if let item, item.kind == .sequence {
            currentSequenceID = item.id
            inspectorTab = .sequence
        } else {
            if item != nil { player.pause() }
            inspectorTab = .footage
        }
        selectedClipIDs = []
    }

    func currentVersion(for item: LibraryItemID) -> UUID? { currentVersions[item] }

    func setCurrentVersion(_ versionID: UUID, for item: LibraryItemID) {
        guard currentVersions[item] != versionID else { return }
        currentVersions[item] = versionID
    }
}
