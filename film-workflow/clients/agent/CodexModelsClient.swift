#if os(macOS)
import Foundation

nonisolated enum CodexModelsError: LocalizedError {
    case notInstalled
    case unreadableOutput

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "The codex command isn't installed."
        case .unreadableOutput:
            return "Couldn't read the model list from codex."
        }
    }
}

/// Reads the Codex CLI's own model catalogue.
///
/// `codex debug models` rather than the `app-server` JSON-RPC `model/list` that
/// rxcode reaches for first: this app has no app-server plumbing at all, and the
/// debug command is one subprocess returning the same data. The catch is size —
/// the reply is a single ~320 KB line, nearly all of it each model's
/// `base_instructions`, which is why parsing keeps only the handful of fields
/// below and never stores the raw JSON.
///
/// Caching mirrors `OpenAIModelsClient`: a 24-hour TTL, in memory and in
/// `UserDefaults`, with `forceRefresh` for the Settings refresh button.
actor CodexModelsClient {
    static let shared = CodexModelsClient()

    private static let cacheTTL: TimeInterval = 24 * 60 * 60
    private static let userDefaultsKey = "codex.modelsCache"

    private var memoryCache: CacheEntry?
    /// Coalesces concurrent callers — Settings and the composer can both ask on
    /// the same launch, and spawning the CLI twice for one answer is waste.
    private var inFlight: Task<[AgentModelOption], Error>?

    private struct CacheEntry: Codable {
        let fetchedAt: Date
        let models: [AgentModelOption]
    }

    private init() {}

    func models(forceRefresh: Bool = false) async throws -> [AgentModelOption] {
        if !forceRefresh, let entry = currentCache(), !Self.isExpired(entry) {
            return entry.models
        }

        if let inFlight { return try await inFlight.value }

        let task = Task<[AgentModelOption], Error> { try await Self.fetch() }
        inFlight = task
        defer { inFlight = nil }

        do {
            let models = try await task.value
            let entry = CacheEntry(fetchedAt: Date(), models: models)
            memoryCache = entry
            Self.persist(entry)
            return models
        } catch {
            // A stale list beats no list: the CLI may be mid-upgrade, or the
            // machine offline. Only surface the error when we have nothing.
            if let entry = currentCache(), !entry.models.isEmpty { return entry.models }
            throw error
        }
    }

    /// The cached list without spawning anything, for synchronous UI prefill.
    /// Deliberately ignores the TTL — a day-old model list is still a far better
    /// first draw than the hardcoded fallback.
    nonisolated static func cachedModels() -> [AgentModelOption]? {
        loadFromUserDefaults()?.models
    }

    // MARK: - Private

    private func currentCache() -> CacheEntry? {
        if let memoryCache { return memoryCache }
        if let entry = Self.loadFromUserDefaults() {
            memoryCache = entry
            return entry
        }
        return nil
    }

    private static func fetch() async throws -> [AgentModelOption] {
        guard let executable = CaptionCLILocator.find("codex") else {
            throw CodexModelsError.notInstalled
        }

        let collector = OutputCollector()
        _ = try await CaptionCLIProcess.run(
            tool: "Codex",
            executable: executable,
            arguments: ["debug", "models"],
            environment: RemotionRuntime.enrichedEnvironment(),
            workingDirectory: FileStorage.appSupportURL,
            onLine: { line in collector.append(line) }
        )

        guard let data = collector.text.data(using: .utf8) else {
            throw CodexModelsError.unreadableOutput
        }
        return try parse(data)
    }

    /// Pulls model options out of `codex debug models` output.
    ///
    /// Tolerant of shape on purpose: the command's envelope has moved between
    /// releases (`models`, `data`, `items`, or a bare array), and an entry may be
    /// a plain string rather than an object. Anything unrecognizable is skipped
    /// rather than failing the whole list — a new field must never cost the user
    /// their picker.
    static func parse(_ data: Data) throws -> [AgentModelOption] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw CodexModelsError.unreadableOutput
        }

        let entries: [Any]
        if let object = root as? [String: Any] {
            entries = (object["models"] as? [Any])
                ?? (object["data"] as? [Any])
                ?? (object["items"] as? [Any])
                ?? []
        } else if let array = root as? [Any] {
            entries = array
        } else {
            throw CodexModelsError.unreadableOutput
        }

        // Sorted by the CLI's own `priority` where it gives one, which is how it
        // orders its own picker; entries without it keep their original order.
        let parsed = entries.enumerated().compactMap { index, entry -> (Int, Int, AgentModelOption)? in
            guard let option = parseEntry(entry) else { return nil }
            let priority = ((entry as? [String: Any])?["priority"] as? NSNumber)?.intValue ?? Int.max
            return (priority, index, option)
        }

        return parsed
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            .map(\.2)
    }

    private static func parseEntry(_ entry: Any) -> AgentModelOption? {
        if let id = entry as? String, !id.isEmpty {
            return AgentModelOption(id: id, displayName: displayName(for: id))
        }

        guard let object = entry as? [String: Any],
              let id = firstString(in: object, keys: ["slug", "id", "model", "name"]),
              !id.isEmpty
        else { return nil }

        // `visibility` is the current spelling and reads "list" or "hide";
        // `hidden` was the older boolean. Anything not explicitly listable is
        // dropped, so internal entries (auto-review, watermarked variants) stay
        // out of the picker.
        if object["hidden"] as? Bool == true { return nil }
        if let visibility = object["visibility"] as? String, visibility != "list" { return nil }

        let levels = object["supported_reasoning_levels"] as? [Any] ?? []
        let efforts = levels.compactMap { level -> String? in
            if let effort = level as? String { return effort }
            return (level as? [String: Any])?["effort"] as? String
        }

        return AgentModelOption(
            id: id,
            displayName: firstString(in: object, keys: ["display_name", "displayName", "name"])
                ?? displayName(for: id),
            detail: firstString(in: object, keys: ["description", "detail"]) ?? "",
            efforts: efforts,
            defaultEffort: firstString(in: object, keys: ["default_reasoning_level", "defaultReasoningLevel"])
        )
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// `gpt-5.4-mini` → `GPT 5.4 Mini`, for the releases that report no
    /// `display_name`.
    static func displayName(for id: String) -> String {
        id.split(separator: "-")
            .map { part in
                part.uppercased().hasPrefix("GPT") ? part.uppercased() : part.capitalized
            }
            .joined(separator: " ")
    }

    // MARK: - Cache

    private static func isExpired(_ entry: CacheEntry) -> Bool {
        Date().timeIntervalSince(entry.fetchedAt) > cacheTTL
    }

    private static func loadFromUserDefaults() -> CacheEntry? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(CacheEntry.self, from: data)
    }

    private static func persist(_ entry: CacheEntry) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}

/// Joins the lines `CaptionCLIProcess` hands back. `@unchecked Sendable` with a
/// lock for the same reason its own collectors are: delivery is off-actor, from
/// a Dispatch read handler.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.withLock { lines.append(line) }
    }

    var text: String {
        lock.withLock { lines.joined() }
    }
}
#endif
