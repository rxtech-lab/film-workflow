import Foundation
import Observation

@Observable
@MainActor
final class AzureVoiceStore {
    static let shared = AzureVoiceStore()

    struct MenuItem: Identifiable, Hashable {
        let shortName: String
        let displayText: String
        var id: String { shortName }
    }

    struct LocaleGroup: Identifiable {
        let locale: String
        let localeName: String
        let items: [MenuItem]
        var id: String { locale }
    }

    private(set) var voices: [AzureVoice] = [] {
        didSet { triggerRebuildIndexes() }
    }
    private(set) var voicesByLocale: [LocaleGroup] = []
    private var voicesByShortName: [String: AzureVoice] = [:]
    private(set) var isLoading = false
    private(set) var lastError: String?

    private static let cacheTTL: TimeInterval = 60 * 60 * 24
    private static var cacheFileURL: URL {
        FileStorage.appSupportURL.appendingPathComponent("azure-voices.json")
    }

    private struct DiskCache: Codable {
        let voices: [AzureVoice]
        let fetchedAt: Date
    }

    private init() {}

    func fetchIfNeeded() async {
        if !voices.isEmpty || isLoading { return }
        if let cached = loadDiskCache(), !isExpired(cached) {
            voices = sorted(cached.voices)
            return
        }
        await load()
    }

    func refresh() async {
        await load()
    }

    private func load() async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let config: AppConfig
        do {
            config = try AppConfig.loadFromKeychain()
        } catch {
            lastError = "Unable to read credentials: \(error.localizedDescription)"
            return
        }

        guard !config.azureSpeechKey.isEmpty, !config.azureSpeechEndpoint.isEmpty else {
            lastError = "Add your Azure Speech key and endpoint in Settings."
            return
        }

        do {
            let fetched = try await AzureTTSClient.fetchVoices(
                apiKey: config.azureSpeechKey,
                endpoint: config.azureSpeechEndpoint
            )
            voices = sorted(fetched)
            saveDiskCache(voices)
        } catch {
            lastError = error.localizedDescription
            // Fall back to any cached copy, even if stale, so the UI stays usable.
            if voices.isEmpty, let cached = loadDiskCache() {
                voices = sorted(cached.voices)
            }
        }
    }

    func voice(forShortName name: String) -> AzureVoice? {
        voicesByShortName[name]
    }

    private func triggerRebuildIndexes() {
        let snapshot = voices
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.buildIndexes(from: snapshot)
            await MainActor.run {
                guard let self else { return }
                self.voicesByLocale = result.groups
                self.voicesByShortName = result.byShortName
            }
        }
    }

    nonisolated private static func buildIndexes(
        from voices: [AzureVoice]
    ) -> (groups: [LocaleGroup], byShortName: [String: AzureVoice]) {
        let grouped = Dictionary(grouping: voices, by: { $0.locale })
        let groups = grouped
            .map { (locale, list) in
                LocaleGroup(
                    locale: locale,
                    localeName: list.first?.localeDisplayName ?? locale,
                    items: list.map {
                        MenuItem(
                            shortName: $0.shortName,
                            displayText: "\($0.localName) — \($0.gender)"
                        )
                    }
                )
            }
            .sorted { $0.localeName < $1.localeName }
        let byShortName = Dictionary(uniqueKeysWithValues: voices.map { ($0.shortName, $0) })
        return (groups, byShortName)
    }

    // MARK: - Disk cache

    private func sorted(_ list: [AzureVoice]) -> [AzureVoice] {
        list.sorted { lhs, rhs in
            if lhs.locale != rhs.locale { return lhs.locale < rhs.locale }
            return lhs.localName < rhs.localName
        }
    }

    private func isExpired(_ cache: DiskCache) -> Bool {
        Date().timeIntervalSince(cache.fetchedAt) >= Self.cacheTTL
    }

    private func loadDiskCache() -> DiskCache? {
        guard let data = try? Data(contentsOf: Self.cacheFileURL) else { return nil }
        return try? JSONDecoder().decode(DiskCache.self, from: data)
    }

    private func saveDiskCache(_ voices: [AzureVoice]) {
        let cache = DiskCache(voices: voices, fetchedAt: Date())
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: Self.cacheFileURL, options: .atomic)
    }
}
