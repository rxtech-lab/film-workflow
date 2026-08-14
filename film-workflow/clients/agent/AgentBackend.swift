import Foundation
import FoundationModels
import Observation
import SwiftUI

/// What an engine is being asked to do, since not every backend can do all of it.
nonisolated enum CaptionAITask: Sendable {
    /// One turn of the caption assistant.
    case conversation
    /// Splitting or glossary review over a transcript that already exists.
    case transcriptReview
    /// Choosing break points cue by cue, while transcription is still running.
    case cueRefinement
    /// Translating a run of captions into another language.
    case translation
}

/// Where AI work runs — for the agent window and for the caption batch tasks.
///
/// Kept separate from `CaptionProvider` (which is about speech-to-text) because
/// the two axes are independent: you might transcribe with Azure and review with
/// the on-device model.
nonisolated enum AgentBackend: String, CaseIterable, Identifiable, Sendable {
    /// Apple Intelligence, entirely on device.
    case appleIntelligence
    /// The endpoint, key and model from Settings › AI Provider.
    case openAICompatible
    /// The RxFilm server, billed to the signed-in account's credits. Its model
    /// list comes from `GET /api/v1/models`, so it is the live gateway catalog
    /// rather than anything configured on this machine.
    case subscription
    /// The `claude` CLI, talking to this app over MCP. macOS only.
    case claudeCode
    /// The `codex` CLI, same arrangement. macOS only.
    case codex

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        case .openAICompatible: return "OpenAI-compatible model"
        case .subscription: return "RxFilm subscription"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// Untranslated name, for places that need a `String` rather than a
    /// `LocalizedStringKey` — these are product names, so they read the same in
    /// every language anyway.
    var engineLabel: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        case .openAICompatible: return "OpenAI-compatible model"
        case .subscription: return "RxFilm subscription"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// Backends whose model id says more than their name does.
    private var isModelNamed: Bool {
        self == .openAICompatible || self == .subscription
    }

    /// The label an engine for this backend will report, known before one is
    /// built — the progress sheet names the engine before the work starts.
    func modelLabel(config: AppConfig?) -> String {
        let model = self.model(config: config)
        guard !model.isEmpty else { return engineLabel }
        // For an OpenAI-compatible endpoint the backend name says nothing —
        // the model id *is* the answer. For a CLI the product name is what the
        // user recognizes, so the model qualifies it rather than replacing it.
        return isModelNamed ? model : "\(engineLabel) (\(model))"
    }

    /// The model id configured for this backend, or empty for "whatever it
    /// defaults to". Each backend reads its own field: handing `openAIModel` to
    /// `claude --model` is how a `gpt-4o` setting used to break the CLI agents.
    func model(config: AppConfig?) -> String {
        guard let config else { return "" }
        let raw: String
        switch self {
        case .openAICompatible: raw = config.usesSubscription ? config.subscriptionChatModel : config.openAIModel
        case .subscription: raw = config.subscriptionChatModel
        case .claudeCode: raw = config.claudeCodeModel
        case .codex: raw = config.codexModel
        case .appleIntelligence: return ""
        }
        return raw.trimmingCharacters(in: .whitespaces)
    }

    /// The reasoning level configured for this backend, or empty for "whatever
    /// the model defaults to".
    ///
    /// Only Codex has one. Read through its own accessor for the same reason
    /// `model(config:)` exists: a setting that belongs to one backend must not
    /// leak into another's arguments.
    func reasoningEffort(config: AppConfig?) -> String {
        guard case .codex = self, let config else { return "" }
        return config.codexReasoningEffort.trimmingCharacters(in: .whitespaces)
    }

    var requiresNetwork: Bool { self != .appleIntelligence }

    func supports(_ task: CaptionAITask) -> Bool {
        switch task {
        case .conversation, .transcriptReview:
            return true
        case .cueRefinement:
            // Not a speed judgement: during transcription the captions exist
            // only in memory, so an agent that reads them back over MCP has
            // nothing to read.
            return !isCommandLine
        case .translation:
            // Every backend, including the CLI agents: translation batches are
            // capped by line count, and a CLI's window is large enough that a
            // whole transcript is a handful of process launches rather than the
            // one-per-caption that still rules them out of `planSplit`.
            return true
        }
    }

    /// Backends that only exist where we can spawn a subprocess.
    var isCommandLine: Bool {
        switch self {
        case .claudeCode, .codex: return true
        case .appleIntelligence, .openAICompatible, .subscription: return false
        }
    }

    /// Characters of caption text one prompt may carry.
    ///
    /// The on-device model has a ~4k-token window shared between prompt and
    /// response, and CJK is roughly one token per character, so the budget has
    /// to be conservative — this is what keeps `CaptionAIContext` from handing
    /// it a whole transcript.
    var contextBudgetCharacters: Int {
        switch self {
        case .appleIntelligence: return 2_500
        case .openAICompatible, .subscription: return 40_000
        case .claudeCode, .codex: return 40_000
        }
    }

    /// Characters of caption text one *translation* batch may carry.
    ///
    /// Much smaller than `contextBudgetCharacters`, and deliberately so: every
    /// other task asks the model to answer about the lines it is shown, while
    /// translation asks it to rewrite all of them. The reply is therefore the
    /// larger half of the cost — the same text again, plus JSON scaffolding
    /// around every line — and it is the reply, not the prompt, that runs into
    /// a provider's default completion cap. Sizing this off the prompt window
    /// is what made long transcripts fail.
    var translationBatchCharacters: Int {
        switch self {
        case .appleIntelligence: return 900
        case .openAICompatible, .subscription: return 6_000
        case .claudeCode, .codex: return 12_000
        }
    }

    /// Captions in one translation batch, whatever their length.
    ///
    /// Characters bound the prompt; line count bounds the reply, which carries
    /// a fixed per-line overhead (`{"number":n,"text":"…"}`) that a character
    /// budget cannot see. Both bounds apply.
    var translationBatchLines: Int {
        switch self {
        case .appleIntelligence: return 12
        case .openAICompatible, .subscription: return 60
        case .claudeCode, .codex: return 120
        }
    }

    /// Backends offered on this platform, in preference order.
    static var supported: [AgentBackend] {
        #if os(macOS)
            return allCases
        #else
            return allCases.filter { !$0.isCommandLine }
        #endif
    }
}

nonisolated enum CaptionAIError: LocalizedError {
    case noBackendAvailable
    case backendUnavailable(AgentBackend, String)
    case emptyResponse
    case malformedResponse(String)
    /// The request, or the reply it asked for, ran past the model's window.
    ///
    /// Distinct from `malformedResponse` because the two call for opposite
    /// responses: a malformed reply might be bad luck, this one is arithmetic.
    /// Sending fewer lines is the only thing that helps, and the translation
    /// runner acts on exactly that.
    case contextOverflow(String)

    var errorDescription: String? {
        switch self {
        case .noBackendAvailable:
            return "No AI engine is set up. Turn on Apple Intelligence, or add an "
                + "OpenAI-compatible endpoint in Settings › AI Provider."
        case .backendUnavailable(_, let reason):
            return reason
        case .emptyResponse:
            return "The model returned nothing."
        case .malformedResponse(let detail):
            return "The model's reply couldn't be read: \(detail)"
        case .contextOverflow(let detail):
            return "The request was too large for the model: \(detail)"
        }
    }
}

/// Whether asking the same engine again with fewer lines could plausibly work.
///
/// The distinction that matters to a long run: a batch that overran the window
/// is worth splitting, an endpoint with the wrong API key is not — retrying it
/// nine hundred times only makes the user wait longer for the same failure.
nonisolated enum CaptionAIRetryPolicy {
    static func isWorthSplitting(_ error: any Error) -> Bool {
        if error is CancellationError { return false }

        switch error {
        case let captionError as CaptionAIError:
            switch captionError {
            case .contextOverflow, .malformedResponse, .emptyResponse:
                return true
            case .noBackendAvailable, .backendUnavailable:
                return false
            }
        case let openAIError as OpenAIError:
            switch openAIError {
            case .missingConfig, .invalidEndpoint:
                return false
            case .httpError(let status, _):
                // 401/403 is a credential problem and 404 a wrong endpoint;
                // neither improves with a shorter prompt. 413 and the 5xx range
                // are worth another, smaller attempt.
                return status == 413 || status == 429 || (500...599).contains(status)
            case .apiError(let message):
                return mentionsContextLimit(message)
            case .invalidResponse:
                return true
            }
        default:
            // A transport error (timeout, connection reset) on a big batch is
            // often the batch's fault, so a smaller one is worth trying.
            return true
        }
    }

    /// Whether a provider's error text is the "you sent too much" message.
    ///
    /// Matched on wording because there is no interoperable code for it: OpenAI
    /// says `context_length_exceeded`, Anthropic "prompt is too long", and the
    /// gateways in between paraphrase both.
    static func mentionsContextLimit(_ message: String) -> Bool {
        let text = message.lowercased()
        return [
            "context length",
            "context_length",
            "context window",
            "maximum context",
            "too many tokens",
            "prompt is too long",
            "request too large",
            "input is too long",
            "reduce the length",
        ]
        .contains { text.contains($0) }
    }
}

/// Which AI engines can actually run right now.
///
/// Apple Intelligence availability changes while the app is open — the user can
/// enable it in System Settings, and the model downloads in the background — so
/// this is `@Observable` and re-read rather than cached at launch. The
/// `WhisperModelStore` pattern.
@MainActor
@Observable
final class AgentBackendAvailability {
    static let shared = AgentBackendAvailability()

    /// Bumped to force the availability computed properties to re-evaluate.
    private var refreshToken = 0

    private init() {}

    /// Call when a settings pane appears; `SystemLanguageModel` is itself
    /// `Observable`, but the CLI lookups below are cached and need a nudge.
    func refresh() {
        cliPathCache.removeAll()
        refreshToken &+= 1
    }

    // MARK: - Apple Intelligence

    var appleIntelligenceAvailability: SystemLanguageModel.Availability {
        _ = refreshToken
        return SystemLanguageModel.default.availability
    }

    var isAppleIntelligenceAvailable: Bool {
        appleIntelligenceAvailability == .available
    }

    /// Why the on-device model can't be used, phrased as something the user can
    /// act on. `nil` when it is available.
    var appleIntelligenceUnavailableReason: LocalizedStringKey? {
        switch appleIntelligenceAvailability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings to use it here."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading its model. Try again shortly."
        case .unavailable:
            return "Apple Intelligence isn't available right now."
        }
    }

    // MARK: - Command-line engines

    private var cliPathCache: [AgentBackend: String?] = [:]

    /// Resolved path to a CLI backend's binary, or nil when it isn't installed.
    func executablePath(for backend: AgentBackend) -> String? {
        guard backend.isCommandLine else { return nil }
        if let cached = cliPathCache[backend] { return cached }
        let resolved = CaptionCLILocator.find(backend.executableName)
        cliPathCache[backend] = resolved
        return resolved
    }

    // MARK: - Resolution

    func isConfigured(_ backend: AgentBackend, config: AppConfig?) -> Bool {
        switch backend {
        case .appleIntelligence:
            return isAppleIntelligenceAvailable
        case .openAICompatible:
            guard let config else { return false }
            // In subscription mode this engine already routes to the server, so
            // it stays selectable there — threads created before the dedicated
            // subscription engine existed keep working.
            if config.usesSubscription { return isConfigured(.subscription, config: config) }
            return !config.openAIEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
                && !config.openAIKey.trimmingCharacters(in: .whitespaces).isEmpty
                && !config.openAIModel.trimmingCharacters(in: .whitespaces).isEmpty
        case .subscription:
            // A thread can pin its own model from the composer, so the account
            // is the only thing that has to be set up here.
            return AuthManager.shared.isAuthenticated
        case .claudeCode, .codex:
            return executablePath(for: backend) != nil
        }
    }

    /// Explains why a backend can't be selected, for the settings picker.
    func unavailableReason(_ backend: AgentBackend, config: AppConfig?) -> LocalizedStringKey? {
        guard !isConfigured(backend, config: config) else { return nil }
        switch backend {
        case .appleIntelligence:
            return appleIntelligenceUnavailableReason
        case .openAICompatible:
            if config?.usesSubscription == true {
                return "Sign in to your RxLab account on the Account tab."
            }
            return "Add an endpoint, key and model in Settings › AI Provider."
        case .subscription:
            return "Sign in to your RxLab account on the Account tab."
        case .claudeCode:
            return "The claude command isn't installed."
        case .codex:
            return "The codex command isn't installed."
        }
    }

    /// The backend to actually use, preferring the requested one and falling
    /// back to anything else that works.
    ///
    /// Falling back rather than failing matters for the transcription post-pass:
    /// a user who turned off Apple Intelligence shouldn't lose their captions,
    /// they should just get them from the other engine.
    func resolved(
        preferred: AgentBackend,
        config: AppConfig?,
        for task: CaptionAITask = .conversation
    ) throws -> AgentBackend {
        let candidates = AgentBackend.supported.filter { $0.supports(task) }

        if candidates.contains(preferred), isConfigured(preferred, config: config) {
            return preferred
        }
        if let fallback = candidates.first(where: { isConfigured($0, config: config) }) {
            return fallback
        }
        throw CaptionAIError.noBackendAvailable
    }
}

extension AgentBackend {
    var executableName: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .appleIntelligence, .openAICompatible, .subscription: return ""
        }
    }
}
