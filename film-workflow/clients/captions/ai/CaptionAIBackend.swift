import Foundation
import FoundationModels
import Observation
import SwiftUI

/// Where caption AI work runs.
///
/// Kept separate from `CaptionProvider` (which is about speech-to-text) because
/// the two axes are independent: you might transcribe with Azure and review with
/// the on-device model.
/// What an engine is being asked to do, since not every backend can do all three.
nonisolated enum CaptionAITask: Sendable {
    /// One turn of the caption assistant.
    case conversation
    /// Splitting or glossary review over a transcript that already exists.
    case transcriptReview
    /// Choosing break points cue by cue, while transcription is still running.
    case cueRefinement
}

nonisolated enum CaptionAIBackend: String, CaseIterable, Identifiable, Sendable {
    /// Apple Intelligence, entirely on device.
    case appleIntelligence
    /// The endpoint, key and model from Settings › AI Provider.
    case openAICompatible
    /// The `claude` CLI, talking to this app over MCP. macOS only.
    case claudeCode
    /// The `codex` CLI, same arrangement. macOS only.
    case codex

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        case .openAICompatible: return "OpenAI-compatible model"
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
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// The label an engine for this backend will report, known before one is
    /// built — the progress sheet names the engine before the work starts.
    func modelLabel(config: AppConfig?) -> String {
        guard self == .openAICompatible else { return engineLabel }
        let model = config?.openAIModel.trimmingCharacters(in: .whitespaces) ?? ""
        return model.isEmpty ? engineLabel : model
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
        }
    }

    /// Backends that only exist where we can spawn a subprocess.
    var isCommandLine: Bool {
        switch self {
        case .claudeCode, .codex: return true
        case .appleIntelligence, .openAICompatible: return false
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
        case .openAICompatible: return 40_000
        case .claudeCode, .codex: return 40_000
        }
    }

    /// Backends offered on this platform, in preference order.
    static var supported: [CaptionAIBackend] {
        #if os(macOS)
            return allCases
        #else
            return allCases.filter { !$0.isCommandLine }
        #endif
    }
}

nonisolated enum CaptionAIError: LocalizedError {
    case noBackendAvailable
    case backendUnavailable(CaptionAIBackend, String)
    case emptyResponse
    case malformedResponse(String)

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
        }
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
final class CaptionAIAvailability {
    static let shared = CaptionAIAvailability()

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

    private var cliPathCache: [CaptionAIBackend: String?] = [:]

    /// Resolved path to a CLI backend's binary, or nil when it isn't installed.
    func executablePath(for backend: CaptionAIBackend) -> String? {
        guard backend.isCommandLine else { return nil }
        if let cached = cliPathCache[backend] { return cached }
        let resolved = CaptionCLILocator.find(backend.executableName)
        cliPathCache[backend] = resolved
        return resolved
    }

    // MARK: - Resolution

    func isConfigured(_ backend: CaptionAIBackend, config: AppConfig?) -> Bool {
        switch backend {
        case .appleIntelligence:
            return isAppleIntelligenceAvailable
        case .openAICompatible:
            guard let config else { return false }
            return !config.openAIEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
                && !config.openAIKey.trimmingCharacters(in: .whitespaces).isEmpty
                && !config.openAIModel.trimmingCharacters(in: .whitespaces).isEmpty
        case .claudeCode, .codex:
            return executablePath(for: backend) != nil
        }
    }

    /// Explains why a backend can't be selected, for the settings picker.
    func unavailableReason(_ backend: CaptionAIBackend, config: AppConfig?) -> LocalizedStringKey? {
        guard !isConfigured(backend, config: config) else { return nil }
        switch backend {
        case .appleIntelligence:
            return appleIntelligenceUnavailableReason
        case .openAICompatible:
            return "Add an endpoint, key and model in Settings › AI Provider."
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
        preferred: CaptionAIBackend,
        config: AppConfig?,
        for task: CaptionAITask = .conversation
    ) throws -> CaptionAIBackend {
        let candidates = CaptionAIBackend.supported.filter { $0.supports(task) }

        if candidates.contains(preferred), isConfigured(preferred, config: config) {
            return preferred
        }
        if let fallback = candidates.first(where: { isConfigured($0, config: config) }) {
            return fallback
        }
        throw CaptionAIError.noBackendAvailable
    }
}

extension CaptionAIBackend {
    var executableName: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .appleIntelligence, .openAICompatible: return ""
        }
    }
}
