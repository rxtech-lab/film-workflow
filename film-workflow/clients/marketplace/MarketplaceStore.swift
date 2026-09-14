import AppKit
import Foundation
import Observation
import VideoEffectsCore

/// The marketplace catalog plus what is installed on disk.
///
/// Same shape as `WhisperModelStore`: an `@Observable @MainActor` singleton
/// with `isLoading` / `lastError`, per-item download progress gated by an
/// in-flight set, and an installed state derived by scanning disk. The
/// client and root directory are injectable so tests run against a fake
/// transport and a temporary folder.
@Observable
@MainActor
final class MarketplaceStore {
    static let shared = MarketplaceStore()

    private let client: MarketplaceClient
    let root: URL

    private(set) var items: [MarketplaceItem] = []
    /// The sidebar the backend describes. Starts as the built-in shape and is
    /// replaced by `loadTaxonomy()`; a failed load leaves the built-in one up.
    private(set) var taxonomy: MarketplaceTaxonomy = .builtIn
    /// True once the backend's version is in hand, so tabs that show up later
    /// do not each refetch it.
    private var hasLoadedTaxonomy = false
    private(set) var total = 0
    private(set) var page = 1
    private(set) var pageCount = 1
    private(set) var isLoading = false
    private(set) var lastError: String?

    /// Item ID → manifest, for everything under `root`.
    private(set) var installed: [String: InstalledMarketplaceManifest] = [:]
    /// Item ID → 0…1 while a download is in flight.
    private(set) var downloadProgress: [String: Double] = [:]
    /// Items with a purchase or install call running.
    private(set) var busyItemIDs: Set<String> = []
    /// Purchases made in this session, so `owned` is right before the next reload.
    private var purchasedIDs: Set<String> = []
    /// Same race guard as `WhisperModelStore`: a late progress callback must not
    /// resurrect an entry the completion already cleared.
    private var inFlight: Set<String> = []

    var insufficientCredits: InsufficientCreditsNotice?

    /// Runs after a purchase so the toolbar balance drops. Replaced in tests,
    /// where there is no account to refresh.
    var balanceRefresher: @MainActor () async -> Void = { await CreditBalanceStore.shared.refresh() }

    init(client: MarketplaceClient = MarketplaceClient(), root: URL = FileStorage.marketplaceDir) {
        self.client = client
        self.root = root
        refreshInstalledState()
    }

    // MARK: - Catalog

    /// Identifies the newest load so a superseded one — the request cancelled
    /// when the filter or the search text changed — neither reports its
    /// cancellation as a failure nor overwrites the fresher result.
    private var loadToken = 0

    func load(kind: MarketplaceKind?, mediaType: MarketplaceMediaType? = nil, category: String?, query: String, page: Int = 1) async {
        loadToken += 1
        let token = loadToken
        isLoading = true
        lastError = nil
        defer { if token == loadToken { isLoading = false } }
        do {
            let result = try await client.items(kind: kind, mediaType: mediaType, category: category, query: query, page: page)
            guard token == loadToken else { return }
            items = result.items.map { item in
                var item = item
                if purchasedIDs.contains(item.id) { item.owned = true }
                return item
            }
            total = result.total
            self.page = result.page
            pageCount = result.pageCount
        } catch {
            guard token == loadToken, !MarketplaceError.isCancellation(error) else { return }
            lastError = error.localizedDescription
        }
    }

    /// Loads the sidebar. Kept apart from `load` because it does not depend on
    /// the filters and rarely changes, so it is fetched once per launch unless
    /// `force` says otherwise; a failure keeps the shape already on screen
    /// rather than emptying the sidebar.
    func loadTaxonomy(force: Bool = false) async {
        guard force || !hasLoadedTaxonomy else { return }
        guard let loaded = try? await client.taxonomy(), !loaded.kinds.isEmpty else { return }
        taxonomy = loaded
        hasLoadedTaxonomy = true
    }

    /// The categories the sidebar lists under one kind.
    func categories(for kind: MarketplaceKind) -> [MarketplaceCategoryCount] { taxonomy.categories(for: kind) }

    /// The sub-level the backend reports under a kind, if any.
    func mediaTypes(for kind: MarketplaceKind) -> [MarketplaceMediaTypePresentation] { taxonomy.mediaTypes(for: kind) }

    /// The label the backend gives a kind, falling back to the built-in one.
    func label(for kind: MarketplaceKind) -> String { taxonomy.presentation(for: kind).label }

    /// The SF Symbol the backend gives a kind, resolved against what this Mac can draw.
    func symbol(for kind: MarketplaceKind) -> String {
        MarketplaceSymbol.resolve(taxonomy.presentation(for: kind).icon, fallback: kind.systemImage)
    }

    func item(_ id: String) -> MarketplaceItem? { items.first { $0.id == id } }

    func setLastError(_ message: String?) { lastError = message }

    // MARK: - Purchase

    /// Charges the item's price. Returns false when the balance could not cover
    /// it, in which case `insufficientCredits` carries the alert.
    @discardableResult
    func purchase(_ item: MarketplaceItem) async -> Bool {
        guard !busyItemIDs.contains(item.id) else { return false }
        busyItemIDs.insert(item.id)
        defer { busyItemIDs.remove(item.id) }
        lastError = nil
        do {
            _ = try await client.purchase(item.id)
            markOwned(item.id)
            await balanceRefresher()
            return true
        } catch {
            if let notice = InsufficientCreditsNotice(error) {
                insufficientCredits = notice
            } else if !MarketplaceError.isCancellation(error) {
                lastError = error.localizedDescription
            }
            return false
        }
    }

    private func markOwned(_ id: String) {
        purchasedIDs.insert(id)
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].owned = true }
    }

    // MARK: - Install

    func isInstalled(_ id: String) -> Bool { installed[id] != nil }

    func manifest(for id: String) -> InstalledMarketplaceManifest? { installed[id] }

    /// Resolve only when Play is pressed: signed content URLs expire. Public
    /// previews remain available before purchase; full audio uses entitlement.
    func audioPreviewSource(for item: MarketplaceItem) async throws -> (url: URL, start: Double) {
        if let url = item.previewVideoUrl { return (url, item.metadata.preview?.startSeconds ?? 0) }
        if let manifest = manifest(for: item.id) {
            let url = manifest.contentURL(in: directory(for: manifest))
            if FileManager.default.fileExists(atPath: url.path) { return (url, 0) }
        }
        guard item.isEntitled else { throw MarketplaceError.notEntitled }
        return (try await client.downloadURL(item.id).url, 0)
    }

    /// Installed items a film can take in (footage, music, sound effects,
    /// Remotion prompts), newest install first. Fonts, effects and transitions
    /// are global and have their own pickers, so they stay out of the library.
    var libraryItems: [InstalledMarketplaceManifest] {
        installed.values.filter { $0.kind.addsToFilm }
            .sorted { ($0.installedAt, $0.title) > ($1.installedAt, $1.title) }
    }

    func directory(for manifest: InstalledMarketplaceManifest) -> URL {
        FileStorage.marketplaceItemDir(kind: manifest.kind.rawValue, itemID: manifest.itemID, root: root)
    }

    /// Downloads the content file into the item's folder and records a manifest.
    /// The download URL is fetched here, right before use: it expires.
    @discardableResult
    func install(_ item: MarketplaceItem) async -> Bool {
        guard item.isEntitled else { lastError = MarketplaceError.notEntitled.errorDescription; return false }
        guard !inFlight.contains(item.id) else { return false }
        inFlight.insert(item.id)
        busyItemIDs.insert(item.id)
        downloadProgress[item.id] = 0
        lastError = nil
        defer {
            inFlight.remove(item.id)
            busyItemIDs.remove(item.id)
            downloadProgress[item.id] = nil
        }
        let directory = FileStorage.marketplaceItemDir(kind: item.kind.rawValue, itemID: item.id, root: root)
        do {
            let download = try await client.downloadURL(item.id)
            let ext = (download.filename as NSString).pathExtension.lowercased()
            let contentName = ext.isEmpty ? "content" : "content.\(ext)"
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let id = item.id
            try await MarketplaceDownloader.download(from: download.url, to: directory.appendingPathComponent(contentName)) { fraction in
                Task { @MainActor [weak self] in
                    guard let self, self.inFlight.contains(id) else { return }
                    self.downloadProgress[id] = fraction
                }
            }
            let previewPath = await cachePreview(item.previewImageUrl, in: directory)
            var manifest = InstalledMarketplaceManifest(
                itemID: item.id, kind: item.kind, title: item.title, category: item.category, description: item.description,
                contentFilename: download.filename, contentRelativePath: contentName, previewImagePath: previewPath,
                metadata: download.metadata, installedAt: Date()
            )
            try postInstall(&manifest, contentURL: directory.appendingPathComponent(contentName))
            try Self.write(manifest, to: directory)
            installed[item.id] = manifest
            return true
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if !MarketplaceError.isCancellation(error) { lastError = error.localizedDescription }
            return false
        }
    }

    /// Kind-specific work once the file is on disk. Throws to abort the install.
    private func postInstall(_ manifest: inout InstalledMarketplaceManifest, contentURL: URL) throws {
        switch manifest.kind {
        case .font:
            guard MarketplaceFonts.register(contentURL) else { throw MarketplaceError.fontRegistrationFailed(manifest.contentFilename) }
            if manifest.metadata.fontFamily == nil { manifest.metadata.fontFamily = MarketplaceFonts.familyName(of: contentURL) }
        case .effect, .transition:
            let descriptor = try InstalledModifierLoader.descriptor(at: contentURL, expecting: manifest.kind)
            manifest.metadata.descriptor = .init(filterName: descriptor.filter, parameterCount: descriptor.parameters.count)
            // Written before reload so the loader can see this item's preview.
            try Self.write(manifest, to: directory(for: manifest))
            InstalledModifierLoader.reload(root: root)
        case .projectTemplate:
            _ = try ProjectTemplateDefinition.decode(Data(contentsOf: contentURL))
        case .remotion:
            // Proved safe here, before the item can be added to any film.
            _ = try RemotionProjectArchive.validate(archive: contentURL)
        case .footage, .audio, .soundEffect:
            break
        }
    }

    private func cachePreview(_ url: URL?, in directory: URL) async -> String? {
        guard let url else { return nil }
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension.lowercased()
        let name = "preview.\(ext)"
        do {
            try await MarketplaceDownloader.download(from: url, to: directory.appendingPathComponent(name))
            return name
        } catch {
            return nil
        }
    }

    func uninstall(_ id: String) {
        guard let manifest = installed[id] else { return }
        let directory = self.directory(for: manifest)
        if manifest.kind == .font { MarketplaceFonts.unregister(manifest.contentURL(in: directory)) }
        try? FileManager.default.removeItem(at: directory)
        installed[id] = nil
        if manifest.kind == .effect || manifest.kind == .transition { InstalledModifierLoader.reload(root: root) }
    }

    func revealInFinder(_ id: String) {
        guard let manifest = installed[id] else { return }
        NSWorkspace.shared.activateFileViewerSelecting([manifest.contentURL(in: directory(for: manifest))])
    }

    /// Re-reads every manifest under `root`.
    func refreshInstalledState() {
        installed = Self.scanInstalled(root: root)
    }

    nonisolated static func scanInstalled(root: URL) -> [String: InstalledMarketplaceManifest] {
        var found: [String: InstalledMarketplaceManifest] = [:]
        let fm = FileManager.default
        for kind in MarketplaceKind.allCases {
            let kindDir = root.appendingPathComponent(kind.rawValue, isDirectory: true)
            guard let entries = try? fm.contentsOfDirectory(at: kindDir, includingPropertiesForKeys: nil) else { continue }
            for entry in entries {
                guard let manifest = read(from: entry), manifest.kind == kind,
                      fm.fileExists(atPath: manifest.contentURL(in: entry).path) else { continue }
                found[manifest.itemID] = manifest
            }
        }
        return found
    }

    nonisolated static func read(from directory: URL) -> InstalledMarketplaceManifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(InstalledMarketplaceManifest.filename)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(InstalledMarketplaceManifest.self, from: data)
    }

    nonisolated static func write(_ manifest: InstalledMarketplaceManifest, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(manifest).write(to: directory.appendingPathComponent(InstalledMarketplaceManifest.filename), options: .atomic)
    }
}
