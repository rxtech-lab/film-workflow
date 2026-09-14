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

    /// The agent target for a selection of this kind. Imported files have no
    /// parameters to talk about, so selecting one targets the whole film.
    var agentKind: AgentTargetKind? {
        self == .imported ? nil : AgentTargetKind(footageKind: self)
    }

    /// Kinds offered by the New menu.
    static var creatable: [FootageKind] { [.sequence, .music, .narration, .caption, .image, .video, .remotion] }
}

struct LibraryItemID: Hashable, Codable {
    let kind: FootageKind
    let id: UUID
}

/// Footage the pointer is skimming in the browser. The viewer shows this
/// take at `fraction` of its length until the pointer leaves the cell.
struct FootageSkim: Equatable {
    let item: LibraryItemID
    let cellID: UUID
    var fraction: Double
}

/// An installed marketplace item as the viewer previews it. Marketplace
/// content is shared by every film and owned by none, so it has no library
/// item to hang a preview off and travels as the cell itself.
struct MarketplacePreview: Equatable {
    let rowID: String
    let name: String
    let cell: FootageCell
    /// Where the pointer is over the card, as a share of the length. Nil once
    /// the item is the one the viewer is holding rather than skimming.
    var skimFraction: Double?
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
    /// Selecting shows the sequence viewer but leaves the inspector tab alone.
    var selectedClipIDs: Set<UUID> = [] {
        didSet { modifierSelection = nil; if !selectedClipIDs.isEmpty { showSequenceViewer() } }
    }
    /// The single selected clip, for the inspector and single-clip edits.
    /// Nil while several clips are selected.
    var selectedClipID: UUID? {
        get { selectedClipIDs.count == 1 ? selectedClipIDs.first : nil }
        set { selectedClipIDs = newValue.map { [$0] } ?? [] }
    }
    /// The inspector tab the user last picked, by `InspectorTabDescriptor.id`.
    /// Remembered across selections and launches; a selection that does not
    /// offer it shows its first tab without forgetting this.
    var modifierSelection: ModifierInspectorSelection?
    var selectedTransitionID: UUID? {
        if case .transition(let id) = modifierSelection { return id }; return nil
    }
    func inspectEffects(_ clipID: UUID) {
        selectedClipIDs = [clipID]
        modifierSelection = .effects(clipID)
        showSequenceViewer()
    }
    func inspectTransition(_ id: UUID) {
        selectedClipIDs = []
        modifierSelection = .transition(id)
        showSequenceViewer()
    }
    var modifierPreviewGeneration = UUID()
    var modifierPreviewTask: Task<Void, Never>?
    var modifierPreviewProgress: String?
    var modifierPreviewError: String?

    var inspectorTabID: String {
        didSet { defaults.set(inspectorTabID, forKey: Self.inspectorTabKey) }
    }
    /// Items with a generation or transcription in flight, so their Settings
    /// tab can lock its controls while the footer runs the work.
    var busyItems: Set<LibraryItemID> = []
    private let defaults: UserDefaults
    private static let inspectorTabKey = "inspector.tab"
    private static let skimKey = "timeline.skim"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.inspectorTabID = defaults.string(forKey: Self.inspectorTabKey) ?? InspectorTabResolver.settingsTabID
        self.skimsTimeline = defaults.bool(forKey: Self.skimKey)
    }
    /// Sequence playback has one position; footage players own their own time.
    /// While the pointer skims the timeline the player shows the skimmed
    /// frame, but the playhead itself stays put until a click moves it.
    var playhead: TimeInterval {
        get { restingPlayhead ?? player.currentTime }
        set {
            restingPlayhead = nil
            showSequenceViewer()
            player.pause()
            player.seek(to: newValue)
        }
    }
    /// Whether moving the pointer across the timeline previews the frame
    /// under it. Remembered across launches.
    var skimsTimeline: Bool {
        didSet {
            defaults.set(skimsTimeline, forKey: Self.skimKey)
            if !skimsTimeline { endSkim() }
        }
    }
    /// The footage cell under the pointer while the browser is skimmed, so
    /// the viewer can show it without changing what is selected.
    private(set) var footageSkim: FootageSkim?
    /// Shared with filmstrip indicators; only those small views observe its clock.
    let footagePlayer = FootagePlayer()

    func seekFootage(_ item: LibraryItemID, cellID: UUID, fraction: Double) {
        endFootageSkim()
        select(item)
        setCurrentVersion(cellID, for: item)
        footagePlayer.commitPosition(fraction: fraction, cellID: cellID)
    }

    /// Shows `cellID` of `item` at `fraction` (0...1) of its length in the
    /// viewer. Always on, unlike timeline skimming, because a pass over a
    /// browser cell is deliberate; like it, it stays out of the way while
    /// the sequence plays. Sequences retain their own viewer; captions and
    /// Remotion compositions use the shared footage preview.
    func skimFootage(_ item: LibraryItemID, cellID: UUID, fraction: Double) {
        guard !player.isPlaying, !footagePlayer.isPlaying, fraction.isFinite else { return }
        switch item.kind {
        case .image, .video, .music, .narration, .imported, .caption, .remotion: break
        case .sequence: return
        }
        footageSkim = FootageSkim(item: item, cellID: cellID, fraction: min(max(0, fraction), 1))
    }

    /// Returns the viewer to the selection once the pointer leaves the footage.
    func endFootageSkim() {
        footageSkim = nil
    }

    /// The marketplace card the viewer is holding, set by a click on the
    /// Marketplace tab and dropped as soon as anything in this film is picked.
    private(set) var marketplaceSelection: MarketplacePreview?
    /// The marketplace card under the pointer, which outranks the held one
    /// the way a browser skim outranks the library selection.
    private(set) var marketplaceSkim: MarketplacePreview?

    /// What the Marketplace tab puts on screen, if anything.
    var marketplacePreview: MarketplacePreview? { marketplaceSkim ?? marketplaceSelection }

    /// Holds an installed item in the viewer at `fraction` of its length, the
    /// way clicking a filmstrip holds one of this film's takes.
    func selectMarketplace(_ preview: MarketplacePreview, fraction: Double) {
        marketplaceSkim = nil
        marketplaceSelection = preview
        player.pause()
        footagePlayer.commitPosition(fraction: fraction, cellID: preview.cell.id)
    }

    /// Previews the card under the pointer without changing what is held.
    func skimMarketplace(_ preview: MarketplacePreview, fraction: Double) {
        guard !player.isPlaying, !footagePlayer.isPlaying, fraction.isFinite else { return }
        var preview = preview
        preview.skimFraction = min(max(0, fraction), 1)
        marketplaceSkim = preview
    }

    /// Returns the viewer to the held card once the pointer leaves this one.
    func endMarketplaceSkim() {
        marketplaceSkim = nil
    }

    /// Gives the viewer back to this film: the Marketplace tab went away, or
    /// the click landed between its cards.
    func clearMarketplacePreview() {
        marketplaceSkim = nil
        marketplaceSelection = nil
    }
    /// Where the playhead was when skimming started, so it can come back
    /// once the pointer leaves the timeline.
    private var restingPlayhead: TimeInterval?

    /// Previews `time` without moving the playhead. Ignored while the
    /// sequence plays, so skimming never interrupts playback.
    func skim(to time: TimeInterval) {
        guard skimsTimeline, !player.isPlaying else { return }
        if restingPlayhead == nil { restingPlayhead = player.currentTime }
        player.seek(to: time)
    }

    /// Puts the player back on the playhead after a skim.
    func endSkim() {
        guard let resting = restingPlayhead else { return }
        restingPlayhead = nil
        player.seek(to: resting)
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

    /// Changes the selection without touching the inspector tab.
    func select(_ item: LibraryItemID?, updateViewer: Bool = true) {
        // A click is a decision, so it outranks whatever the pointer is
        // skimming. A skim that never reported its end — the pointer left with
        // the app, or while the window was not key — would otherwise keep that
        // take in the viewer however often the user picked something else.
        endFootageSkim()
        // Picking something of this film's own takes the viewer back from
        // whatever the Marketplace tab was showing.
        marketplaceSelection = nil
        marketplaceSkim = nil
        selection = item
        if updateViewer { viewerSelection = item }
        if let item, item.kind == .sequence {
            currentSequenceID = item.id
        } else if item != nil {
            player.pause()
        }
        selectedClipIDs = []
    }

    func currentVersion(for item: LibraryItemID) -> UUID? { currentVersions[item] }

    func setCurrentVersion(_ versionID: UUID, for item: LibraryItemID) {
        guard currentVersions[item] != versionID else { return }
        // Picking a version is the same kind of decision as picking an item:
        // the viewer follows it rather than a take left over from a skim.
        endFootageSkim()
        currentVersions[item] = versionID
    }
}
