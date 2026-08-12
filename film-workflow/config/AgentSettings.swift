import Foundation
import Observation

/// App-wide defaults for the agent window.
///
/// Preferences, not secrets, so they live in UserDefaults — the `MCPSettings`
/// and `CaptionSettings` pattern. Provider credentials stay in `AppConfig`
/// (Keychain).
///
/// Deliberately separate from `CaptionSettings.aiBackend`, which still selects
/// the engine for the caption *batch* tasks (splitting, glossary review). Those
/// run unattended over a whole transcript and want a fast in-process model; the
/// agent window wants whatever the user is having a conversation with. Sharing
/// one setting would mean changing your chat engine silently re-tuned
/// transcription post-processing.
@MainActor
@Observable
final class AgentSettings {
    static let shared = AgentSettings()

    /// Backend used by a thread that hasn't overridden it.
    var defaultBackend: AgentBackend {
        didSet {
            guard defaultBackend != oldValue else { return }
            UserDefaults.standard.set(defaultBackend.rawValue, forKey: Keys.defaultBackend)
        }
    }

    /// Whether the agent may write captions directly or must propose them.
    var writePolicy: AgentWritePolicy {
        didSet {
            guard writePolicy != oldValue else { return }
            UserDefaults.standard.set(writePolicy.rawValue, forKey: Keys.writePolicy)
        }
    }

    /// Rounds of tool calls before a turn gives up. Guards against a model that
    /// loops on a tool that never satisfies it.
    var maxIterations: Int {
        didSet {
            guard maxIterations != oldValue else { return }
            UserDefaults.standard.set(maxIterations, forKey: Keys.maxIterations)
        }
    }

    private init() {
        let defaults = UserDefaults.standard

        let storedBackend = defaults.string(forKey: Keys.defaultBackend) ?? ""
        // Falls back to the OpenAI-compatible loop rather than Apple
        // Intelligence: the agent window is about calling tools, and the
        // on-device model cannot.
        self.defaultBackend = AgentBackend(rawValue: storedBackend) ?? .openAICompatible

        let storedPolicy = defaults.string(forKey: Keys.writePolicy) ?? ""
        self.writePolicy = AgentWritePolicy(rawValue: storedPolicy) ?? .review

        let storedIterations = defaults.integer(forKey: Keys.maxIterations)
        self.maxIterations = storedIterations == 0 ? 20 : storedIterations
    }

    private enum Keys {
        static let defaultBackend = "agent.defaultBackend"
        static let writePolicy = "agent.writePolicy"
        static let maxIterations = "agent.maxIterations"
    }
}
