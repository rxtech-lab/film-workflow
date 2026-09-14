import AVFoundation
import AVKit
import Combine
import SwiftUI

/// Scene id for the marketplace window, shared by the scene declaration and
/// every `openWindow` call so a typo can't silently open nothing.
nonisolated enum MarketplaceWindowID {
    static let value = "marketplace"
}

/// The public catalog (everything, one kind, or one kind's media type), or the
/// current author's items. Categories stay in the content view's dropdown; the
/// sidebar carries at most one level below a kind, and only where the backend
/// reports one — footage, today, split into stills and clips.
enum MarketplaceSidebarSelection: Hashable {
    case all
    case kind(MarketplaceKind)
    case media(MarketplaceKind, MarketplaceMediaType)
    case mine
    case manage

    /// The kind filtering the grid. A media row still filters by its kind, so
    /// everything that reads this keeps working unchanged.
    var kind: MarketplaceKind? {
        switch self {
        case .all, .mine, .manage: return nil
        case .kind(let kind): return kind
        case .media(let kind, _): return kind
        }
    }

    /// The sub-level, when one is selected.
    var mediaType: MarketplaceMediaType? {
        if case .media(_, let mediaType) = self { return mediaType }
        return nil
    }

    /// The authoring destinations, which read the author API rather than the
    /// public catalog, so the catalog reload skips them.
    var isAuthoring: Bool {
        switch self {
        case .mine, .manage: return true
        case .all, .kind, .media: return false
        }
    }
}

/// Lets anything outside the window ask it to open on one of its destinations.
///
/// The marketplace is a single `Window` scene rather than a `WindowGroup`, so
/// the request cannot ride along with `openWindow` as a value; it is left here
/// and picked up when the window appears or, if it is already open, as soon as
/// it changes.
@MainActor @Observable
final class MarketplaceWindowRouter {
    static let shared = MarketplaceWindowRouter()
    private(set) var requested: MarketplaceSidebarSelection?

    func show(_ selection: MarketplaceSidebarSelection) { requested = selection }

    /// Reads the pending request once, so a second window or a later redraw
    /// does not pull the selection back.
    func take() -> MarketplaceSidebarSelection? {
        defer { requested = nil }
        return requested
    }
}

/// Identifiable wrapper so the detail sheet is keyed by item id but reads the
/// live item from the store, so purchase / install state stays current.
private struct MarketplacePresentedItem: Identifiable {
    let id: String
}

/// The system-wide marketplace window: a kind sidebar alongside the grid, with
/// the selected kind's categories offered as a dropdown above the cards.
/// Clicking a card opens its detail in a sheet; hovering a card with a video
/// preview plays it in place.
struct MarketplaceWindowView: View {
    @State private var store: MarketplaceStore
    @State private var auth = AuthManager.shared
    @State private var documents = ProjectDocumentController.shared
    @State private var selection: MarketplaceSidebarSelection = .all
    /// The category slug filtering the grid, or nil for every category in the
    /// selected kind. Cleared whenever the sidebar selection changes.
    @State private var category: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var search = ""
    @State private var presented: MarketplacePresentedItem?
    @State private var addedMessage: String?
    @State private var creatingItem = false
    @State private var authoring = MarketplaceAuthoringService.shared
    @State private var authoringRevision = 0
    @State private var router = MarketplaceWindowRouter.shared

    init(store: MarketplaceStore = .shared) {
        _store = State(initialValue: store)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            if selection.isAuthoring, authoring.canAuthor {
                MarketplaceAuthoringListView(scope: selection == .mine ? .mine : .all, query: search,
                                             refreshID: authoringRevision,
                                             onCreate: { creatingItem = true }, onItemsChanged: authoringDidChange)
                    .id("\(authoring.userId ?? "")-\(selection == .mine)")
            } else {
                grid
            }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("Marketplace")
        .searchable(text: $search, placement: .toolbar, prompt: "Search the marketplace")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { authoringRevision += 1; Task { await store.loadTaxonomy(force: true); await reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Reload the catalog")
                    .disabled(store.isLoading)
                if authoring.canAuthor {
                    Button("Create Item", systemImage: "plus") { creatingItem = true }.accessibilityIdentifier("marketplace-create-item")
                }
                AccountControl(placement: .toolbar)
            }
        }
        .sheet(item: $presented) { presented in
            MarketplaceItemSheet(itemID: presented.id, store: store, isSignedIn: auth.isAuthenticated,
                                 hasActiveFilm: documents.activeDocument != nil, onAddToFilm: addToFilm)
        }
        .sheet(isPresented: $creatingItem, onDismiss: authoringDidChange) { MarketplaceAuthoringEditor() }
        .task { await reload() }
        .task { await store.loadTaxonomy() }
        .task { _ = await authoring.refreshAccess(); applyRoutedSelection() }
        .onChange(of: router.requested) { applyRoutedSelection() }
        .onChange(of: selection) { category = nil; Task { await reload() } }
        .onChange(of: category) { Task { await reload() } }
        .onChange(of: search) { Task { await reload(debounced: true) } }
        .onChange(of: auth.isAuthenticated) { Task { _ = await authoring.refreshAccess(); await reload() } }
        .onChange(of: authoring.canAuthor) {
            if authoring.canAuthor {
                // A request that arrived before access was known is still pending.
                applyRoutedSelection()
            } else {
                if selection.isAuthoring { selection = .all }
                creatingItem = false
            }
        }
        .insufficientCreditsAlert(Binding(get: { store.insufficientCredits }, set: { store.insufficientCredits = $0 }))
        .alert("Added to Film", isPresented: Binding(get: { addedMessage != nil }, set: { if !$0 { addedMessage = nil } })) {
            Button("OK") { addedMessage = nil }
        } message: {
            Text(addedMessage ?? "")
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    /// Honours a destination another view asked for. Authoring destinations
    /// only exist for an author, so a request for one is dropped rather than
    /// landing the reader on an empty pane.
    private func applyRoutedSelection() {
        guard let requested = router.requested else { return }
        guard !requested.isAuthoring || authoring.canAuthor else { return }
        _ = router.take()
        columnVisibility = .all
        selection = requested
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: Binding<MarketplaceSidebarSelection?>(
            get: { selection },
            set: { if let value = $0 { selection = value } }
        )) {
            Section {
                Label("All Items", systemImage: "square.grid.2x2")
                    .tag(MarketplaceSidebarSelection.all)
                ForEach(store.taxonomy.kinds) { entry in
                    Label(entry.label, systemImage: MarketplaceSymbol.resolve(entry.icon, fallback: entry.kind.systemImage))
                        .badge(entry.count)
                        .tag(MarketplaceSidebarSelection.kind(entry.kind))
                    // Indented rather than a DisclosureGroup, whose label does
                    // not reliably take a tag inside a selection-driven List —
                    // clicking the kind itself has to keep showing everything.
                    ForEach(store.mediaTypes(for: entry.kind)) { child in
                        Label(child.label, systemImage: MarketplaceSymbol.resolve(child.icon, fallback: child.mediaType.systemImage))
                            .badge(child.count)
                            .padding(.leading, 18)
                            .tag(MarketplaceSidebarSelection.media(entry.kind, child.mediaType))
                    }
                }
            }
            .accessibilityIdentifier("marketplace-kinds")
            if authoring.canAuthor {
                Section("Authoring") {
                    Label("My Marketplace", systemImage: "person.crop.square")
                        .tag(MarketplaceSidebarSelection.mine)
                        .accessibilityIdentifier("marketplace-my-items")
                    Label("Manage Items", systemImage: "square.and.pencil")
                        .tag(MarketplaceSidebarSelection.manage)
                        .accessibilityIdentifier("marketplace-manage-button")
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("marketplace-sidebar")
    }

    private var categoriesForSelectedKind: [MarketplaceCategoryCount] {
        guard let kind = selection.kind else { return [] }
        return store.categories(for: kind)
    }

    // MARK: - Grid

    /// The category filter for the selected kind. Only shown when the backend
    /// actually reports categories for it, so single-category kinds stay clean.
    @ViewBuilder
    private var categoryFilter: some View {
        if let kind = selection.kind, !categoriesForSelectedKind.isEmpty {
            HStack {
                Picker(store.label(for: kind), selection: $category) {
                    Text("All Categories").tag(String?.none)
                    ForEach(categoriesForSelectedKind) { entry in
                        Text("\(entry.displayName) (\(entry.count))").tag(String?.some(entry.category))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("marketplace-category-filter")
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
        }
    }

    private var grid: some View {
        VStack(spacing: 0) {
            categoryFilter
            gridContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var gridContent: some View {
        Group {
            if store.isLoading && store.items.isEmpty {
                Color.clear
            } else if let error = store.lastError, store.items.isEmpty {
                ContentUnavailableView {
                    Label("Couldn’t load the marketplace", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await reload() } }
                }
            } else if store.items.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                ScrollView {
                    MarketplaceItemGrid {
                        ForEach(store.items) { item in
                            MarketplaceItemCard(item: item, isInstalled: store.isInstalled(item.id), symbol: store.symbol(for: item.kind)) {
                                presented = MarketplacePresentedItem(id: item.id)
                            }
                        }
                    }
                    if store.pageCount > 1 { pager.padding(.bottom, 14) }
                }
            }
        }
        .marketplaceLoadingOverlay(store.isLoading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let error = store.lastError, !store.items.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding()
            }
        }
    }

    private var pager: some View {
        HStack {
            Button("Previous") { Task { await reload(page: store.page - 1) } }.disabled(store.page <= 1)
            Text("Page \(store.page) of \(store.pageCount)").foregroundStyle(.secondary).font(.callout)
            Button("Next") { Task { await reload(page: store.page + 1) } }.disabled(store.page >= store.pageCount)
        }
    }

    @State private var reloadTask: Task<Void, Never>?

    private func reload(page: Int = 1, debounced: Bool = false) async {
        reloadTask?.cancel()
        guard !selection.isAuthoring else { return }
        let selection = selection, category = category, search = search
        let task = Task { @MainActor in
            if debounced { try? await Task.sleep(for: .milliseconds(300)); if Task.isCancelled { return } }
            await store.load(kind: selection.kind, mediaType: selection.mediaType, category: category, query: search, page: page)
            if let presented, store.item(presented.id) == nil { self.presented = nil }
        }
        reloadTask = task
        await task.value
    }

    private func authoringDidChange() {
        authoringRevision += 1
        Task { await store.loadTaxonomy(force: true); await reload() }
    }

    private func addToFilm(_ item: MarketplaceItem) {
        guard let manifest = store.manifest(for: item.id) else { store.setLastError(MarketplaceError.notInstalled.errorDescription); return }
        guard let document = documents.activeDocument else { store.setLastError(MarketplaceError.noActiveFilm.errorDescription); return }
        Task {
            do {
                _ = try await MarketplaceInstaller.addToFilm(manifest, contentURL: manifest.contentURL(in: store.directory(for: manifest)), document: document)
                addedMessage = String(localized: "“\(item.title)” was added to \(document.displayName).")
            } catch {
                store.setLastError(error.localizedDescription)
            }
        }
    }
}

/// Shared card sizing and spacing for the catalog and authoring destinations.
struct MarketplaceItemGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 14, alignment: .top)], spacing: 14) {
                content
            }
        }
        .padding(14)
    }
}

extension View {
    /// Keep the last page in place while a replacement request is in flight.
    func marketplaceLoadingOverlay(_ isLoading: Bool) -> some View {
        overlay {
            if isLoading {
                ZStack {
                    Color.primary.opacity(0.025)
                    ProgressView("Loading items…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .allowsHitTesting(false)
                .accessibilityIdentifier("marketplace-loading-overlay")
            }
        }
    }
}

/// A shared Liquid Glass card with in-place video playback on hover.
struct MarketplaceItemCard: View {
    let item: MarketplaceItem
    let isInstalled: Bool
    /// The SF Symbol for the item's kind, already resolved against this Mac.
    var symbol: String?
    var publicationStatus: String?
    var isBusy = false
    let onOpen: () -> Void
    @State private var isHovering = false
    @State private var isVideoReady = false
    @ScaledMetric(relativeTo: .callout) private var titleHeight = 32
    @ScaledMetric(relativeTo: .caption2) private var metadataHeight = 18

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                // The frame owns the layout; loaded images and AVPlayer must
                // never change its size with their intrinsic aspect ratios.
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        ZStack {
                            MarketplacePreviewImage(url: item.previewImageUrl, kind: item.kind, symbol: symbol)
                            if isHovering, item.kind != .audio, item.kind != .soundEffect, let video = item.previewVideoUrl {
                                MarketplaceHoverVideo(url: video) {
                                    withAnimation(.easeInOut(duration: 0.3)) { isVideoReady = true }
                                }
                                .opacity(isVideoReady ? 1 : 0)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                                .accessibilityLabel("Preview video")
                                .accessibilityIdentifier("marketplace-hover-preview-\(item.id)")
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topLeading) {
                        if let publicationStatus {
                            Text(publicationStatus == "published" ? LocalizedStringKey("Published") : LocalizedStringKey("Draft"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(publicationStatus == "published" ? Color.green : Color.orange)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                                .padding(6)
                                .accessibilityIdentifier("marketplace-item-status-\(item.id)")
                        }
                    }
                    .overlay {
                        if isBusy {
                            ProgressView().controlSize(.small)
                                .padding(10)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if isInstalled {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.white, .green)
                                .padding(6)
                                .accessibilityLabel("Installed")
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if !isHovering, item.previewVideoUrl != nil {
                            Image(systemName: "play.fill")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(.black.opacity(0.45), in: Circle())
                                .padding(6)
                                .accessibilityHidden(true)
                        }
                    }
                Text(item.title).font(.callout.weight(.medium))
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(height: titleHeight, alignment: .topLeading)
                HStack(spacing: 4) {
                    ForEach(Array((item.metadata.tags ?? []).prefix(2)), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
                .frame(height: metadataHeight, alignment: .leading)
                HStack(spacing: 6) {
                    Text(item.categoryLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let badge = item.resolutionBadge {
                        Text(badge)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                            .accessibilityLabel("Resolution \(badge)")
                    }
                    Spacer()
                    MarketplacePriceBadge(item: item)
                }
                .lineLimit(1)
                .frame(height: metadataHeight)
            }
            .padding(12)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(isHovering ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            // Reset on the way in so the video starts hidden and fades over the
            // cover once it is ready; on the way out the removal transition owns
            // the fade, so leaving the flag alone keeps that crossfade smooth.
            if hovering { isVideoReady = false }
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        .onDisappear { isHovering = false }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("marketplace-item-\(item.id)")
    }
}

/// A muted, looping, control-free player for hover previews. Created when it
/// appears and torn down when it goes away, so nothing plays off-screen.
struct MarketplaceHoverVideo: NSViewRepresentable {
    let url: URL
    /// Called on the main actor once the first frame is playable.
    var onReady: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspectFill
        view.showsFullScreenToggleButton = false
        context.coordinator.attach(url: url, to: view, onReady: onReady)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if context.coordinator.url != url { context.coordinator.attach(url: url, to: view, onReady: onReady) }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.detach()
        view.player = nil
    }

    @MainActor
    final class Coordinator {
        private(set) var url: URL?
        private var player: AVPlayer?
        private var loopObserver: NSObjectProtocol?
        private var statusObservation: NSKeyValueObservation?

        func attach(url: URL, to view: AVPlayerView, onReady: @escaping () -> Void) {
            detach()
            self.url = url
            let player = AVPlayer(url: url)
            player.isMuted = true
            player.actionAtItemEnd = .none
            statusObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { item, _ in
                guard item.status == .readyToPlay else { return }
                Task { @MainActor in onReady() }
            }
            loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak player] _ in
                player?.seek(to: .zero)
                player?.play()
            }
            view.player = player
            player.play()
            self.player = player
        }

        func detach() {
            if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
            loopObserver = nil
            statusObservation?.invalidate()
            statusObservation = nil
            player?.pause()
            player = nil
            url = nil
        }
    }
}

struct MarketplacePriceBadge: View {
    let item: MarketplaceItem
    var body: some View {
        Group {
            if item.owned && !item.isFree { Text("Owned") }
            else if item.isFree { Text("Free") }
            else { Text("\(item.pricePoints.formatted()) credits") }
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(item.isFree || item.owned ? Color.green.opacity(0.2) : Color.accentColor.opacity(0.2)))
    }
}

struct MarketplacePreviewImage: View {
    let url: URL?
    let kind: MarketplaceKind
    /// The kind's symbol as the backend names it; nil falls back to the built-in one.
    var symbol: String?
    var contentMode: ContentMode = .fill
    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().aspectRatio(contentMode: contentMode) }
                    else if phase.error != nil { placeholder }
                    else { ProgressView().controlSize(.small) }
                }
            } else {
                placeholder
            }
        }
        .clipped()
    }
    private var placeholder: some View {
        Image(systemName: symbol ?? kind.systemImage).font(.title).foregroundStyle(.secondary)
    }
}

/// The detail preview: shows the cover art with a play button, crossfades into
/// the preview video once playback starts, and crossfades back to the cover
/// when the video reaches the end.
struct MarketplacePreviewPlayer: View {
    let item: MarketplaceItem

    @State private var player: AVPlayer?
    @State private var isShowingVideo = false
    @State private var isPreparing = false
    @State private var playbackError: String?
    @State private var prepareTask: Task<Void, Never>?
    @State private var teardownTask: Task<Void, Never>?

    /// One duration for both directions so the two crossfades feel symmetric.
    private static let crossfade: Double = 0.35

    var body: some View {
        ZStack {
            MarketplacePreviewImage(url: item.previewImageUrl, kind: item.kind)
                .blur(radius: isShowingVideo ? 6 : 0)
                .scaleEffect(isShowingVideo ? 1.04 : 1)
            if let player, let playerItem = player.currentItem {
                VideoPlayer(player: player)
                    // Attach the player while it prepares so AVKit can load and
                    // render the video underneath the cover.
                    .opacity(isShowingVideo ? 1 : 0)
                    .scaleEffect(isShowingVideo ? 1 : 1.04)
                    .allowsHitTesting(isShowingVideo)
                    .accessibilityHidden(!isShowingVideo)
                    .accessibilityLabel("Preview video")
                    .onReceive(player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main)) { status in
                        guard self.player === player, isPreparing, status == .playing else { return }
                        prepareTask?.cancel()
                        prepareTask = nil
                        isPreparing = false
                        withAnimation(.easeInOut(duration: Self.crossfade)) { isShowingVideo = true }
                    }
                    .onReceive(playerItem.publisher(for: \.status).receive(on: DispatchQueue.main)) { status in
                        guard self.player === player, status == .failed else { return }
                        fail(playerItem.error?.localizedDescription ?? String(localized: "Couldn’t play this preview. Try again."))
                    }
            }
            if !isShowingVideo, item.previewVideoUrl != nil {
                playButton.transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .overlay(alignment: .bottom) {
            if let playbackError {
                Label(playbackError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(12)
                    .accessibilityIdentifier("marketplace-preview-error")
            }
        }
        .animation(.easeInOut(duration: Self.crossfade), value: isShowingVideo)
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            guard let finished = note.object as? AVPlayerItem, finished === player?.currentItem else { return }
            stop(animated: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { note in
            guard let failed = note.object as? AVPlayerItem, failed === player?.currentItem else { return }
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            fail(error?.localizedDescription ?? String(localized: "Couldn’t play this preview. Try again."))
        }
        .onChange(of: item.previewVideoUrl) { _, _ in stop(animated: false); playbackError = nil }
        .onDisappear { stop(animated: false) }
    }

    private var playButton: some View {
        Button(action: start) {
            ZStack {
                if isPreparing {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: playbackError == nil ? "play.fill" : "arrow.clockwise").font(.title2).foregroundStyle(.white)
                }
            }
            .frame(width: 64, height: 64)
            .contentShape(Circle())
            .glassEffect(.regular.tint(.black.opacity(0.22)).interactive(), in: .circle)
            .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
        .disabled(isPreparing)
        .accessibilityLabel(playbackError == nil ? "Play preview" : "Retry preview")
        .accessibilityIdentifier("marketplace-preview-play")
    }

    private func start() {
        guard let url = item.previewVideoUrl, prepareTask == nil else { return }
        teardownTask?.cancel()
        teardownTask = nil
        playbackError = nil
        isPreparing = true
        isShowingVideo = false
        let player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        self.player = player
        prepareTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard !Task.isCancelled, self.player === player, isPreparing else { return }
            fail(String(localized: "The preview took too long to load. Try again."))
        }
        // Request playback immediately. Waiting for status through an async
        // publisher before attaching/starting the player could wait forever.
        player.play()
    }

    private func fail(_ message: String) {
        stop(animated: false)
        playbackError = message
    }

    private func stop(animated: Bool) {
        prepareTask?.cancel()
        prepareTask = nil
        isPreparing = false
        player?.pause()
        guard animated else {
            teardownTask?.cancel()
            teardownTask = nil
            isShowingVideo = false
            player = nil
            return
        }
        withAnimation(.easeInOut(duration: Self.crossfade)) { isShowingVideo = false }
        // Keep the player alive until the fade-out finishes, otherwise the layer
        // blanks out before the cover has faded back in.
        teardownTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.crossfade + 0.05))
            guard !Task.isCancelled, !isShowingVideo else { return }
            player = nil
            teardownTask = nil
        }
    }

}

// MARK: - Previews

#if DEBUG
/// Serves a canned catalog page so previews render without a backend. Purchase
/// and download calls fail, which is enough to exercise the buttons' idle state.
private struct PreviewMarketplaceTransport: MarketplaceTransport {
    let page: MarketplaceCatalogPage

    func get<Response: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> Response {
        guard path == "api/v1/marketplace/items" else { throw BackendError.server(404, nil) }
        let data = try JSONEncoder().encode(page)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body, idempotencyKey: String?) async throws -> Response {
        throw BackendError.server(503, "Not available in previews.")
    }
}

extension MarketplaceItem {
    static let previewItems: [MarketplaceItem] = [
        MarketplaceItem(id: "intro-hello", kind: .footage, category: "intro", title: "Hello World Intro",
                        description: "A short animated intro with a waving robot and a title card.", pricePoints: 0,
                        previewImageUrl: URL(string: "https://picsum.photos/seed/intro/640/360"),
                        previewVideoUrl: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4"),
                        contentSizeBytes: 1_258_291, metadata: .init(durationSeconds: 10, width: 1280, height: 720, tags: ["intro", "robot"])),
        MarketplaceItem(id: "space-loop", kind: .footage, category: "background", title: "Starfield Loop",
                        description: "Seamless drifting stars for backgrounds and lower thirds.", pricePoints: 120,
                        previewImageUrl: URL(string: "https://picsum.photos/seed/stars/640/360"),
                        previewVideoUrl: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4"),
                        contentSizeBytes: 8_400_000, metadata: .init(durationSeconds: 30, width: 1920, height: 1080)),
        MarketplaceItem(id: "lofi-beat", kind: .audio, category: "lo-fi", title: "Rainy Window Beat",
                        description: "Mellow lo-fi loop, 82 BPM.", pricePoints: 60,
                        metadata: .init(durationSeconds: 94, tags: ["lo-fi", "chill"]), owned: true),
        MarketplaceItem(id: "whoosh-01", kind: .soundEffect, category: "transitions", title: "Soft Whoosh",
                        pricePoints: 0, metadata: .init(durationSeconds: 1.2)),
        MarketplaceItem(id: "font-grotesk", kind: .font, category: "sans", title: "Studio Grotesk",
                        description: "A clean geometric sans for captions.", pricePoints: 200,
                        previewImageUrl: URL(string: "https://picsum.photos/seed/font/640/360"),
                        metadata: .init(fontFamily: "Studio Grotesk")),
        MarketplaceItem(id: "prompt-product", kind: .remotion, category: "product", title: "Product Reveal",
                        description: "A prompt that builds a three-scene product reveal.", pricePoints: 40,
                        metadata: .init(promptExcerpt: "Create a 15 second product reveal with a dark gradient background…")),
        MarketplaceItem(id: "fx-glow", kind: .effect, category: "stylize", title: "Neon Glow",
                        pricePoints: 80, previewImageUrl: URL(string: "https://picsum.photos/seed/glow/640/360"),
                        metadata: .init(descriptor: .init(filterName: "CIBloom", parameterCount: 2))),
        MarketplaceItem(id: "tr-wipe", kind: .transition, category: "wipes", title: "Diagonal Wipe",
                        pricePoints: 0, previewVideoUrl: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4"),
                        metadata: .init(durationSeconds: 0.6, descriptor: .init(filterName: "CISwipeTransition", parameterCount: 3))),
    ]
}

extension MarketplaceStore {
    /// A store over the canned catalog and a scratch install folder.
    @MainActor
    static func preview(items: [MarketplaceItem] = MarketplaceItem.previewItems, installed: [MarketplaceItem] = []) -> MarketplaceStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("marketplace-preview-\(UUID().uuidString)", isDirectory: true)
        for item in installed {
            let directory = FileStorage.marketplaceItemDir(kind: item.kind.rawValue, itemID: item.id, root: root)
            let manifest = InstalledMarketplaceManifest(
                itemID: item.id, kind: item.kind, title: item.title, category: item.category, description: item.description,
                contentFilename: item.contentFilename ?? "content.bin", contentRelativePath: "content.bin",
                previewImagePath: nil, metadata: item.metadata, installedAt: Date()
            )
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? Data().write(to: manifest.contentURL(in: directory))
            try? MarketplaceStore.write(manifest, to: directory)
        }
        var categories: [MarketplaceCategoryCount] = []
        for item in items {
            if let index = categories.firstIndex(where: { $0.kind == item.kind && $0.category == item.category }) {
                categories[index] = MarketplaceCategoryCount(kind: item.kind, category: item.category, count: categories[index].count + 1)
            } else {
                categories.append(MarketplaceCategoryCount(kind: item.kind, category: item.category, count: 1))
            }
        }
        let page = MarketplaceCatalogPage(items: items, total: items.count, page: 1, pageCount: 1, pageSize: 24, categories: categories)
        let client = MarketplaceClient(transport: PreviewMarketplaceTransport(page: page))
        let store = MarketplaceStore(client: client, root: root)
        store.balanceRefresher = {}
        return store
    }
}

#Preview("Marketplace Window") {
    MarketplaceWindowView(store: .preview(installed: [MarketplaceItem.previewItems[0]]))
        .frame(width: 1000, height: 640)
}

#Preview("Item Card") {
    let store = MarketplaceStore.preview()
    HStack(alignment: .top, spacing: 14) {
        MarketplaceItemCard(item: MarketplaceItem.previewItems[0], isInstalled: true) {}
        MarketplaceItemCard(item: MarketplaceItem.previewItems[1], isInstalled: false) {}
        MarketplaceItemCard(item: MarketplaceItem.previewItems[4], isInstalled: false) {}
    }
    .frame(width: 720)
    .padding()
    .task { await store.load(kind: nil, category: nil, query: "") }
}

#Preview("Item Sheet") {
    let store = MarketplaceStore.preview()
    MarketplaceItemSheet(itemID: "intro-hello", store: store, isSignedIn: true, hasActiveFilm: true, onAddToFilm: { _ in })
        .task { await store.load(kind: nil, category: nil, query: "") }
}

#Preview("Item Sheet — Signed Out, Paid") {
    let store = MarketplaceStore.preview()
    MarketplaceItemSheet(itemID: "space-loop", store: store, isSignedIn: false, hasActiveFilm: false, onAddToFilm: { _ in })
        .task { await store.load(kind: nil, category: nil, query: "") }
}
#endif
