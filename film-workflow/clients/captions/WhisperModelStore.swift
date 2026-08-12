import Foundation
import Observation
import WhisperKit

/// Catalog of downloadable Whisper models plus what's installed on disk.
///
/// Structurally the same as `AzureVoiceStore`: an `@Observable @MainActor`
/// singleton with a JSON disk cache, a 24-hour TTL, a stale-on-error fallback,
/// and `lastError` for the UI.
@Observable
@MainActor
final class WhisperModelStore {
    static let shared = WhisperModelStore()

    struct ModelEntry: Identifiable, Hashable, Sendable {
        let variant: String
        /// Approximate download size. WhisperKit doesn't publish per-variant
        /// sizes, so these come from the known family sizes and are labelled
        /// "about" in the UI.
        let approximateBytes: Int64
        let isRecommended: Bool
        var isInstalled: Bool
        var installedBytes: Int64

        var id: String { variant }

        /// "openai_whisper-large-v3_turbo" → "Large v3 turbo".
        var displayName: String {
            var name = variant
            for prefix in ["openai_whisper-", "distil-whisper_distil-", "openai_"] {
                if name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
            }
            name = name.replacingOccurrences(of: "_", with: " ")
            return name.prefix(1).uppercased() + name.dropFirst()
        }

        var family: String {
            let lower = variant.lowercased()
            for candidate in ["large-v3", "large-v2", "large", "medium", "small", "base", "tiny"] {
                if lower.contains(candidate) { return candidate }
            }
            return "other"
        }

        /// Whisper's multilingual models omit the `.en` suffix.
        var isMultilingual: Bool { !variant.lowercased().contains(".en") }
    }

    private(set) var models: [ModelEntry] = []
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var recommendedVariant: String = ""

    /// variant → 0…1 while a download is in flight.
    private(set) var downloadProgress: [String: Double] = [:]

    /// Variants with a download actually in flight.
    ///
    /// WhisperKit's progress callback hops to the main actor through detached
    /// tasks, which are unordered — a trailing 100% update can land *after* the
    /// completion handler has cleared `downloadProgress`, resurrecting the entry
    /// forever and pinning the row at "Downloading — 100%". Progress updates are
    /// gated on membership here, and membership is dropped before the progress
    /// entry is cleared, so a late update has nothing to resurrect.
    private var inFlight: Set<String> = []

    private var fetchedAt: Date?
    private static let cacheTTL: TimeInterval = 24 * 60 * 60

    private init() {
        loadCache()
        refreshInstalledState()
    }

    // MARK: - Catalog

    func fetchIfNeeded() async {
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.cacheTTL, !models.isEmpty {
            refreshInstalledState()
            return
        }
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            let base = FileStorage.whisperModelsDir
            let available = try await WhisperKit.fetchAvailableModels(downloadBase: base)
            let recommended = await WhisperKit.recommendedRemoteModels(downloadBase: base)

            recommendedVariant = recommended.default
            let recommendedSet = Set(recommended.supported)
            let installed = Self.installedVariants()

            let offered = available
                .filter { Self.fitsInMemory($0) }
                .sorted { lhs, rhs in
                    let lhsWeight = Self.sortWeight(lhs)
                    let rhsWeight = Self.sortWeight(rhs)
                    return lhsWeight == rhsWeight
                        ? lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
                        : lhsWeight < rhsWeight
                }

            models = offered.map { variant in
                ModelEntry(
                    variant: variant,
                    approximateBytes: Self.approximateBytes(for: variant),
                    isRecommended: variant == recommended.default || recommendedSet.contains(variant),
                    isInstalled: installed.contains(variant),
                    installedBytes: installed.contains(variant)
                        ? Self.installedBytes(variant: variant)
                        : 0
                )
            }
            fetchedAt = Date()
            saveCache()
        } catch {
            // Keep whatever the cache had; a failed catalog fetch must not hide
            // models the user already downloaded.
            lastError = error.localizedDescription
            refreshInstalledState()
            if models.isEmpty {
                models = Self.fallbackCatalog(installed: Self.installedVariants())
            }
        }
    }

    // MARK: - Download / delete

    func download(_ variant: String) async {
        guard !inFlight.contains(variant) else { return }
        lastError = nil
        inFlight.insert(variant)
        downloadProgress[variant] = 0

        defer {
            // Order matters: leave the in-flight set first so any queued progress
            // update is ignored, then clear the visible progress.
            inFlight.remove(variant)
            downloadProgress[variant] = nil
        }

        do {
            _ = try await WhisperKit.download(
                variant: variant,
                downloadBase: FileStorage.whisperModelsDir,
                progressCallback: { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        let store = WhisperModelStore.shared
                        guard store.inFlight.contains(variant) else { return }
                        // Monotonic: out-of-order updates must not walk backwards.
                        let current = store.downloadProgress[variant] ?? 0
                        store.downloadProgress[variant] = max(current, fraction)
                    }
                }
            )
            refreshInstalledState()

            // First model downloaded becomes the selected one, so transcription
            // works without a second trip through Settings.
            if CaptionSettings.shared.whisperVariant.isEmpty {
                CaptionSettings.shared.whisperVariant = variant
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func delete(_ variant: String) {
        guard let folder = Self.folderURL(for: variant) else { return }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            lastError = error.localizedDescription
        }
        if CaptionSettings.shared.whisperVariant == variant {
            CaptionSettings.shared.whisperVariant = ""
        }
        Task { await WhisperKitEngine.shared.unload() }
        refreshInstalledState()
    }

    func refreshInstalledState() {
        let installed = Self.installedVariants()
        models = models.map { entry in
            var copy = entry
            copy.isInstalled = installed.contains(entry.variant)
            copy.installedBytes = copy.isInstalled
                ? Self.installedBytes(variant: entry.variant)
                : 0
            return copy
        }
    }

    var totalInstalledBytes: Int64 {
        models.reduce(0) { $0 + $1.installedBytes }
    }

    var installedModels: [ModelEntry] { models.filter(\.isInstalled) }

    // MARK: - Disk inspection

    /// Root WhisperKit downloads into: `<base>/models/<repo>/<variant>/`.
    /// `nonisolated` so the installed-state scan can run off the main actor.
    nonisolated private static var repoRoot: URL {
        FileStorage.whisperModelsDir
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
    }

    /// `nonisolated` so `WhisperKitEngine` can resolve the model folder from its
    /// own actor without hopping to the main actor mid-load.
    nonisolated static func folderURL(for variant: String) -> URL? {
        let direct = repoRoot.appendingPathComponent(variant, isDirectory: true)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }

        // Tolerate naming drift between the catalog entry and the folder on disk
        // (the download helper may add an "openai_" prefix to disambiguate).
        let contents = try? FileManager.default.contentsOfDirectory(
            at: repoRoot, includingPropertiesForKeys: nil
        )
        return contents?.first { $0.lastPathComponent.hasSuffix(variant) }
    }

    /// A variant counts as installed only when its folder holds compiled Core ML
    /// models — a partial download leaves the folder present but unusable.
    nonisolated static func installedVariants() -> Set<String> {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: repoRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var out: Set<String> = []
        for entry in entries {
            let compiled = (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil))?
                .contains { $0.pathExtension == "mlmodelc" } ?? false
            if compiled { out.insert(entry.lastPathComponent) }
        }
        return out
    }

    nonisolated static func isInstalled(variant: String) -> Bool {
        let installed = installedVariants()
        if installed.contains(variant) { return true }
        // Match the prefixed-folder case above.
        return installed.contains { $0.hasSuffix(variant) }
    }

    private static func installedBytes(variant: String) -> Int64 {
        guard let folder = folderURL(for: variant),
              let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.fileSizeKey]
              )
        else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }

    // MARK: - Heuristics

    /// Approximate download size for the "about N MB" label.
    ///
    /// Many variants state their real size in the id
    /// (`distil-whisper_distil-large-v3_594MB`), so prefer that — the family
    /// fallback would call that 1.6 GB and be wrong by nearly 3×.
    nonisolated static func approximateBytes(for variant: String) -> Int64 {
        let mb: Int64 = 1024 * 1024

        if let match = variant.range(
            of: "_([0-9]+)MB", options: [.regularExpression, .caseInsensitive]
        ) {
            let digits = variant[match].filter(\.isNumber)
            if let value = Int64(digits), value > 0 { return value * mb }
        }

        let lower = variant.lowercased()
        if lower.contains("large") { return 1600 * mb }
        if lower.contains("medium") { return 800 * mb }
        if lower.contains("small") { return 480 * mb }
        if lower.contains("base") { return 145 * mb }
        if lower.contains("tiny") { return 75 * mb }
        return 300 * mb
    }

    /// Hides models this device can't hold. A `large` variant on a 4 GB iPhone
    /// is a guaranteed jetsam, so it should never be offered.
    private static func fitsInMemory(_ variant: String) -> Bool {
        let physical = ProcessInfo.processInfo.physicalMemory
        let gb = Double(physical) / 1_073_741_824
        let lower = variant.lowercased()

        if lower.contains("large") { return gb >= 8 }
        if lower.contains("medium") { return gb >= 6 }
        return true
    }

    /// Smallest first — the ordering someone choosing a first download wants.
    private static func sortWeight(_ variant: String) -> Int {
        let lower = variant.lowercased()
        if lower.contains("tiny") { return 0 }
        if lower.contains("base") { return 1 }
        if lower.contains("small") { return 2 }
        if lower.contains("medium") { return 3 }
        if lower.contains("large") { return 4 }
        return 5
    }

    /// Offline fallback so Settings still lists something useful when the
    /// catalog can't be fetched.
    private static func fallbackCatalog(installed: Set<String>) -> [ModelEntry] {
        ["openai_whisper-tiny", "openai_whisper-base", "openai_whisper-small"]
            .filter { fitsInMemory($0) }
            .map { variant in
                ModelEntry(
                    variant: variant,
                    approximateBytes: approximateBytes(for: variant),
                    isRecommended: variant == "openai_whisper-base",
                    isInstalled: installed.contains(variant),
                    installedBytes: installed.contains(variant) ? installedBytes(variant: variant) : 0
                )
            }
    }

    // MARK: - Cache

    private struct Cache: Codable {
        let fetchedAt: Date
        let variants: [String]
        let recommended: String
    }

    private static var cacheURL: URL {
        FileStorage.appSupportURL.appendingPathComponent("whisper-models.json")
    }

    private func saveCache() {
        let cache = Cache(
            fetchedAt: fetchedAt ?? Date(),
            variants: models.map(\.variant),
            recommended: recommendedVariant
        )
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: Self.cacheURL)
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data)
        else { return }

        let installed = Self.installedVariants()
        fetchedAt = cache.fetchedAt
        recommendedVariant = cache.recommended
        models = cache.variants.map { variant in
            ModelEntry(
                variant: variant,
                approximateBytes: Self.approximateBytes(for: variant),
                isRecommended: variant == cache.recommended,
                isInstalled: installed.contains(variant),
                installedBytes: installed.contains(variant)
                    ? Self.installedBytes(variant: variant)
                    : 0
            )
        }
    }
}
