import Foundation
import Observation

/// One model a CLI agent backend can be pointed at.
///
/// `displayName` is a plain `String` rather than a `LocalizedStringKey` for the
/// same reason `AgentBackend.engineLabel` is: these are product names, and half
/// of them arrive from the `codex` binary at runtime, so there is nothing to
/// translate against.
nonisolated struct AgentModelOption: Codable, Identifiable, Hashable, Sendable {
    /// Passed to `--model`. Never empty — "use the CLI's own default" is an
    /// empty *selection*, not an option in the list.
    let id: String
    let displayName: String
    /// One line for the picker's help text. May be empty.
    let detail: String
    /// Reasoning levels this model accepts, in the order the CLI reported them.
    /// Always empty for Claude Code, which takes no effort setting here.
    let efforts: [String]
    let defaultEffort: String?

    init(
        id: String,
        displayName: String,
        detail: String = "",
        efforts: [String] = [],
        defaultEffort: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.efforts = efforts
        self.defaultEffort = defaultEffort
    }
}

/// The models each CLI backend can be pointed at.
///
/// The two backends are unlike each other, and the split is not an oversight:
///
/// - `codex` publishes its catalogue (`codex debug models`), and it changes
///   often enough that a hardcoded list would be wrong within weeks. Discovered.
/// - `claude` publishes nothing — there is no list command, and an unknown
///   `--model` only comes back as "it may not exist". Its aliases are a short,
///   stable set, so they are hardcoded here.
///
/// `@Observable` and not a plain `enum` because the Codex half changes while the
/// app is open — the user installs the CLI, or refreshes from Settings. Same
/// shape as `AgentBackendAvailability`.
@MainActor
@Observable
final class AgentModelCatalog {
    static let shared = AgentModelCatalog()

    // MARK: - Claude Code

    /// `claude --model` aliases, newest first.
    ///
    /// The `default` alias is deliberately absent: an empty selection already
    /// means "leave it to the CLI", and two rows saying almost the same thing
    /// only invite the wrong one to be picked.
    nonisolated static let claudeModels: [AgentModelOption] = [
        AgentModelOption(id: "opus", displayName: "Opus", detail: "Most capable, slowest."),
        AgentModelOption(id: "opus[1m]", displayName: "Opus 1M", detail: "Opus with a 1M-token window."),
        AgentModelOption(id: "opusplan", displayName: "Opus Plan", detail: "Opus while planning, Sonnet to execute."),
        AgentModelOption(id: "sonnet", displayName: "Sonnet", detail: "Balanced for everyday work."),
        AgentModelOption(id: "sonnet[1m]", displayName: "Sonnet 1M", detail: "Sonnet with a 1M-token window."),
        AgentModelOption(id: "haiku", displayName: "Haiku", detail: "Fastest and cheapest."),
        AgentModelOption(id: "fable", displayName: "Fable", detail: "Tuned for writing and long-form prose."),
        AgentModelOption(id: "fable[1m]", displayName: "Fable 1M", detail: "Fable with a 1M-token window."),
        AgentModelOption(id: "best", displayName: "Best", detail: "Whatever the CLI currently rates highest."),
    ]

    // MARK: - Codex

    /// Used when `codex debug models` can't be run — the CLI isn't installed,
    /// the call failed, and nothing was cached from a previous launch.
    ///
    /// Stale by construction. It exists so the picker is never empty, not as a
    /// source of truth; the moment discovery succeeds these are replaced.
    nonisolated static let codexFallbackModels: [AgentModelOption] = {
        let efforts = ["low", "medium", "high", "xhigh"]
        return [
            AgentModelOption(id: "gpt-5.6-sol", displayName: "GPT-5.6-Sol", efforts: efforts, defaultEffort: "low"),
            AgentModelOption(id: "gpt-5.5", displayName: "GPT-5.5", efforts: efforts, defaultEffort: "medium"),
            AgentModelOption(id: "gpt-5.4", displayName: "GPT-5.4", efforts: efforts, defaultEffort: "medium"),
            AgentModelOption(id: "gpt-5.4-mini", displayName: "GPT-5.4-Mini", efforts: efforts, defaultEffort: "medium"),
        ]
    }()

    /// Reasoning levels offered for a Codex model we know nothing about — a
    /// custom id the user typed in. Every model the CLI has shipped so far
    /// accepts at least these four.
    nonisolated static let genericCodexEfforts = ["low", "medium", "high", "xhigh"]

    private(set) var codexModels: [AgentModelOption]
    private(set) var isLoadingCodexModels = false
    private(set) var codexModelsError: String?

    private init() {
        #if os(macOS)
            // Seeded from the on-disk cache so the composer's menu is populated
            // on first draw without spawning anything.
            let cached = CodexModelsClient.cachedModels()
            codexModels = cached?.isEmpty == false ? cached! : Self.codexFallbackModels
        #else
            codexModels = []
        #endif
    }

    /// Re-reads `codex debug models`. Cheap when a fresh cache exists unless
    /// `forceRefresh` is set.
    func loadCodexModels(forceRefresh: Bool) async {
        #if os(macOS)
            guard !isLoadingCodexModels else { return }
            isLoadingCodexModels = true
            codexModelsError = nil
            defer { isLoadingCodexModels = false }

            do {
                let models = try await CodexModelsClient.shared.models(forceRefresh: forceRefresh)
                if !models.isEmpty { codexModels = models }
            } catch {
                // The fallback list stays in place; the message is for the
                // Settings caption, not a reason to empty the picker.
                codexModelsError = error.localizedDescription
            }
        #endif
    }

    // MARK: - Subscription

    /// Chat models the RxFilm server offers, which is the live gateway catalog
    /// rather than anything this machine knows. Empty until a signed-in load
    /// succeeds — the menu then falls back to the model chosen in Settings.
    private(set) var subscriptionChatModels: [AgentModelOption] = []
    private(set) var isLoadingSubscriptionModels = false

    func loadSubscriptionChatModels(forceRefresh: Bool) async {
        guard !isLoadingSubscriptionModels, AuthManager.shared.isAuthenticated else { return }
        isLoadingSubscriptionModels = true
        defer { isLoadingSubscriptionModels = false }
        // Silent on failure: this fills a menu the user may never open, and
        // `BackendModelCatalog` already serves its cache when the server is
        // unreachable.
        guard let models = try? await BackendModelCatalog.shared.models(
            capability: .chat,
            forceRefresh: forceRefresh
        ) else { return }
        subscriptionChatModels = models.map {
            AgentModelOption(id: $0.id, displayName: $0.displayName)
        }
    }

    // MARK: - Lookup

    func options(for backend: AgentBackend) -> [AgentModelOption] {
        switch backend {
        case .claudeCode: return Self.claudeModels
        case .codex: return codexModels
        case .subscription: return subscriptionChatModels
        case .appleIntelligence, .openAICompatible: return []
        }
    }

    func option(for id: String, backend: AgentBackend) -> AgentModelOption? {
        options(for: backend).first { $0.id == id }
    }

    /// The name to show for a model id, falling back to the id itself so a
    /// custom entry still reads sensibly.
    func displayName(for id: String, backend: AgentBackend) -> String {
        option(for: id, backend: backend)?.displayName ?? id
    }

    /// Reasoning levels to offer for a Codex model, generic ones for an id we
    /// don't recognize.
    func efforts(forCodexModel id: String) -> [String] {
        Self.efforts(forCodexModel: id, in: codexModels)
    }

    /// The effort to actually send for `modelID`, or nil to send none.
    ///
    /// The reason this exists rather than passing the configured value straight
    /// through: model and effort are chosen in two different places — effort in
    /// Settings, model possibly overridden per thread — and the levels are *not*
    /// uniform across models (GPT-5.6-Sol takes `ultra`, GPT-5.5 does not).
    /// Without this, overriding a thread's model could start failing every turn
    /// on a setting the user last touched weeks ago.
    func effort(for modelID: String, configured: String) -> String? {
        Self.effort(for: modelID, configured: configured, in: codexModels)
    }

    // MARK: - Pure forms
    //
    // Split out from the two methods above so the rules can be exercised against
    // a known list rather than whatever this machine last discovered.

    nonisolated static func efforts(
        forCodexModel id: String,
        in options: [AgentModelOption]
    ) -> [String] {
        guard !id.isEmpty,
              let option = options.first(where: { $0.id == id }),
              !option.efforts.isEmpty
        else { return genericCodexEfforts }
        return option.efforts
    }

    /// An id we don't know is passed through unchanged: the user typed it, so
    /// they know more about it than the catalogue does.
    nonisolated static func effort(
        for modelID: String,
        configured: String,
        in options: [AgentModelOption]
    ) -> String? {
        let effort = configured.trimmingCharacters(in: .whitespaces)
        guard !effort.isEmpty else { return nil }
        guard let option = options.first(where: { $0.id == modelID }), !option.efforts.isEmpty else {
            return effort
        }
        return option.efforts.contains(effort) ? effort : nil
    }
}
