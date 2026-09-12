import AVFoundation
import AVKit
import SwiftUI

/// Scene id for the marketplace window, shared by the scene declaration and
/// every `openWindow` call so a typo can't silently open nothing.
nonisolated enum MarketplaceWindowID {
    static let value = "marketplace"
}

/// What the filter bar can select: everything, one kind, or one category within a kind.
enum MarketplaceSidebarSelection: Hashable {
    case all
    case kind(MarketplaceKind)
    case category(MarketplaceKind, String)

    var kind: MarketplaceKind? {
        switch self {
        case .all: return nil
        case .kind(let kind), .category(let kind, _): return kind
        }
    }

    var category: String? {
        if case .category(_, let name) = self { return name }
        return nil
    }
}

/// Identifiable wrapper so the detail sheet is keyed by item id but reads the
/// live item from the store, so purchase / install state stays current.
private struct MarketplacePresentedItem: Identifiable {
    let id: String
}

/// The system-wide marketplace window: one grid with a filter bar on top.
/// Clicking a card opens its detail in a sheet; hovering a card with a video
/// preview plays it in place.
struct MarketplaceWindowView: View {
    @State private var store: MarketplaceStore
    @State private var auth = AuthManager.shared
    @State private var documents = ProjectDocumentController.shared
    @State private var selection: MarketplaceSidebarSelection = .all
    @State private var search = ""
    @State private var presented: MarketplacePresentedItem?
    @State private var addedMessage: String?

    init(store: MarketplaceStore = .shared) {
        _store = State(initialValue: store)
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            grid
        }
        .navigationTitle("Marketplace")
        .searchable(text: $search, placement: .toolbar, prompt: "Search the marketplace")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Reload the catalog")
                    .disabled(store.isLoading)
                AccountControl(placement: .toolbar)
            }
        }
        .sheet(item: $presented) { presented in
            MarketplaceItemSheet(itemID: presented.id, store: store, isSignedIn: auth.isAuthenticated,
                                 hasActiveFilm: documents.activeDocument != nil, onAddToFilm: addToFilm)
        }
        .task { await reload() }
        .onChange(of: selection) { Task { await reload() } }
        .onChange(of: search) { Task { await reload(debounced: true) } }
        .onChange(of: auth.isAuthenticated) { Task { await reload() } }
        .insufficientCreditsAlert(Binding(get: { store.insufficientCredits }, set: { store.insufficientCredits = $0 }))
        .alert("Added to Film", isPresented: Binding(get: { addedMessage != nil }, set: { if !$0 { addedMessage = nil } })) {
            Button("OK") { addedMessage = nil }
        } message: {
            Text(addedMessage ?? "")
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    MarketplaceFilterChip(title: String(localized: "All Items"), systemImage: "square.grid.2x2", isSelected: selection == .all) {
                        selection = .all
                    }
                    ForEach(MarketplaceKind.allCases) { kind in
                        MarketplaceFilterChip(title: kind.displayName, systemImage: kind.systemImage, isSelected: selection.kind == kind) {
                            selection = .kind(kind)
                        }
                    }
                }
                .padding(.horizontal, 14)
            }
            .accessibilityIdentifier("marketplace-kinds")
            if let kind = selection.kind, !categoriesForSelectedKind.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        MarketplaceFilterChip(title: String(localized: "All \(kind.displayName)"), isSelected: selection.category == nil, compact: true) {
                            selection = .kind(kind)
                        }
                        ForEach(categoriesForSelectedKind, id: \.category) { entry in
                            MarketplaceFilterChip(title: entry.category, count: entry.count, isSelected: selection.category == entry.category, compact: true) {
                                selection = .category(kind, entry.category)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .accessibilityIdentifier("marketplace-categories")
            }
        }
        .padding(.vertical, 10)
        .animation(.easeInOut(duration: 0.15), value: categoriesForSelectedKind)
    }

    private var categoriesForSelectedKind: [MarketplaceCategoryCount] {
        guard let kind = selection.kind else { return [] }
        return store.categories.filter { $0.kind == kind }
    }

    // MARK: - Grid

    private var grid: some View {
        Group {
            if store.isLoading && store.items.isEmpty {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 14, alignment: .top)], spacing: 14) {
                        ForEach(store.items) { item in
                            MarketplaceItemCard(item: item, isInstalled: store.isInstalled(item.id)) {
                                presented = MarketplacePresentedItem(id: item.id)
                            }
                        }
                    }
                    .padding(14)
                    if store.pageCount > 1 { pager.padding(.bottom, 14) }
                }
            }
        }
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
        let selection = selection, search = search
        let task = Task { @MainActor in
            if debounced { try? await Task.sleep(for: .milliseconds(300)); if Task.isCancelled { return } }
            await store.load(kind: selection.kind, category: selection.category, query: search, page: page)
            if let presented, store.item(presented.id) == nil { self.presented = nil }
        }
        reloadTask = task
        await task.value
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

/// One pill in the filter bar. Kinds get an icon; categories are compact with a count.
struct MarketplaceFilterChip: View {
    let title: String
    var systemImage: String?
    var count: Int?
    let isSelected: Bool
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).lineLimit(1)
                if let count {
                    Text(count, format: .number).foregroundStyle(isSelected ? .primary : .secondary).font(.caption2)
                }
            }
            .font(compact ? .caption : .callout)
            .padding(.horizontal, compact ? 9 : 11)
            .padding(.vertical, compact ? 4 : 6)
            .background(Capsule().fill(isSelected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
            .overlay(Capsule().stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A catalog card. Hovering plays the item's preview video in place when it has one.
struct MarketplaceItemCard: View {
    let item: MarketplaceItem
    let isInstalled: Bool
    let onOpen: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        MarketplacePreviewImage(url: item.previewImageUrl, kind: item.kind)
                        if isHovering, let video = item.previewVideoUrl {
                            MarketplaceHoverVideo(url: video)
                                .transition(.opacity)
                                .accessibilityLabel("Preview video")
                        }
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    if isInstalled {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white, .green)
                            .padding(6)
                            .accessibilityLabel("Installed")
                    }
                    if !isHovering, item.previewVideoUrl != nil {
                        Image(systemName: "play.fill")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(.black.opacity(0.45), in: Circle())
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            .accessibilityHidden(true)
                    }
                }
                Text(item.title).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                HStack {
                    Text(item.category).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    MarketplacePriceBadge(item: item)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(isHovering ? Color.primary.opacity(0.07) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isHovering ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("marketplace-item-\(item.id)")
    }
}

/// A muted, looping, control-free player for hover previews. Created when it
/// appears and torn down when it goes away, so nothing plays off-screen.
struct MarketplaceHoverVideo: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspectFill
        view.showsFullScreenToggleButton = false
        context.coordinator.attach(url: url, to: view)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if context.coordinator.url != url { context.coordinator.attach(url: url, to: view) }
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

        func attach(url: URL, to view: AVPlayerView) {
            detach()
            self.url = url
            let player = AVPlayer(url: url)
            player.isMuted = true
            player.actionAtItemEnd = .none
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
    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
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
        Image(systemName: kind.systemImage).font(.title).foregroundStyle(.secondary)
    }
}

/// The detail sheet: reads the live item from the store so the action row
/// tracks purchase and install state while it is open.
struct MarketplaceItemSheet: View {
    let itemID: String
    let store: MarketplaceStore
    let isSignedIn: Bool
    let hasActiveFilm: Bool
    let onAddToFilm: (MarketplaceItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if let item = store.item(itemID) {
                MarketplaceItemDetail(item: item, store: store, isSignedIn: isSignedIn, hasActiveFilm: hasActiveFilm, onAddToFilm: { onAddToFilm(item) })
            } else {
                ContentUnavailableView("Item unavailable", systemImage: "storefront", description: Text("This item is no longer in the catalog."))
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("marketplace-detail-done")
            }
            .padding(12)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 560, idealHeight: 640)
        .accessibilityIdentifier("marketplace-detail")
    }
}

/// Preview, description and the action row for one item.
struct MarketplaceItemDetail: View {
    let item: MarketplaceItem
    let store: MarketplaceStore
    let isSignedIn: Bool
    let hasActiveFilm: Bool
    let onAddToFilm: () -> Void
    @State private var player: AVPlayer?
    @State private var navigation = AppNavigation.shared

    private var isInstalled: Bool { store.isInstalled(item.id) }
    private var isBusy: Bool { store.busyItemIDs.contains(item.id) }
    private var progress: Double? { store.downloadProgress[item.id] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                preview
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.title).font(.title2.weight(.semibold))
                        Spacer()
                        MarketplacePriceBadge(item: item)
                    }
                    Label(item.kind.displayName, systemImage: item.kind.systemImage).font(.callout).foregroundStyle(.secondary)
                    Text(item.category).font(.callout).foregroundStyle(.secondary)
                }
                actionRow
                if !item.description.isEmpty {
                    Text(item.description).font(.body).textSelection(.enabled)
                }
                facts
                if item.kind == .remotionPrompt, let excerpt = item.metadata.promptExcerpt, !excerpt.isEmpty {
                    GroupBox("Prompt") { Text(excerpt).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
                if isInstalled, !item.kind.installedHint.isEmpty {
                    Text(item.kind.installedHint).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .onAppear { if let url = item.previewVideoUrl { player = AVPlayer(url: url) } }
        .onDisappear { player?.pause(); player = nil }
    }

    @ViewBuilder
    private var preview: some View {
        if let player {
            VideoPlayer(player: player).accessibilityLabel("Preview video")
        } else {
            MarketplacePreviewImage(url: item.previewImageUrl, kind: item.kind)
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 10) {
            if !isSignedIn && (!item.isFree || !isInstalled) {
                Button("Sign In to \(item.isFree ? "Install" : "Buy")") { navigation.requestSignIn() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("marketplace-sign-in")
            } else if !item.isEntitled {
                Button { Task { await store.purchase(item) } } label: {
                    if isBusy { ProgressView().controlSize(.small) } else { Text("Buy for \(item.pricePoints.formatted()) credits") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
                .accessibilityIdentifier("marketplace-buy")
            } else if let progress {
                ProgressView(value: progress) { Text("Downloading — \(Int(progress * 100))%") }
                    .frame(maxWidth: 260)
            } else if !isInstalled {
                Button("Install") { Task { await store.install(item) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
                    .accessibilityIdentifier("marketplace-install")
            } else {
                Menu {
                    Button("Reveal in Finder") { store.revealInFinder(item.id) }
                    Button("Uninstall", role: .destructive) { store.uninstall(item.id) }
                } label: {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                }
                .fixedSize()
                .accessibilityIdentifier("marketplace-installed")
                if item.kind.addsToFilm {
                    Button("Add to Film", action: onAddToFilm)
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasActiveFilm)
                        .help(hasActiveFilm ? "Add this item to the film in front" : "Open a film to add this item")
                        .accessibilityIdentifier("marketplace-add-to-film")
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var facts: some View {
        let rows = factRows
        if !rows.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(rows, id: \.0) { row in
                    GridRow {
                        Text(row.0).foregroundStyle(.secondary)
                        Text(row.1)
                    }
                }
            }
            .font(.callout)
        }
    }

    private var factRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let seconds = item.metadata.durationSeconds, seconds > 0 {
            rows.append((String(localized: "Duration"), Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))))
        }
        if let width = item.metadata.width, let height = item.metadata.height, width > 0, height > 0 {
            rows.append((String(localized: "Size"), "\(width)×\(height)"))
        }
        if let family = item.metadata.fontFamily, !family.isEmpty { rows.append((String(localized: "Family"), family)) }
        if let descriptor = item.metadata.descriptor { rows.append((String(localized: "Filter"), descriptor.filterName)) }
        if let bytes = item.contentSizeBytes, bytes > 0 {
            rows.append((String(localized: "Download"), ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))
        }
        if let tags = item.metadata.tags, !tags.isEmpty { rows.append((String(localized: "Tags"), tags.joined(separator: ", "))) }
        return rows
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
        MarketplaceItem(id: "prompt-product", kind: .remotionPrompt, category: "product", title: "Product Reveal",
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
