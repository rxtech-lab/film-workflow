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

    /// The engine the user last picked in a thread's engine menu, as
    /// `AgentBackend.rawValue`; empty means they picked "Default".
    ///
    /// A new thread starts from this rather than from `defaultBackend`: someone
    /// who switched to Codex in their last three threads wants the fourth on
    /// Codex too, without going to Settings to make it the app default.
    /// Existing threads are untouched — each keeps the pick it was given.
    var lastPickedBackendRaw: String {
        didSet {
            guard lastPickedBackendRaw != oldValue else { return }
            UserDefaults.standard.set(lastPickedBackendRaw, forKey: Keys.lastPickedBackend)
        }
    }

    /// The per-engine model map (`AgentThread.modelOverridesJSON`) as it stood
    /// when the user last picked a model. The whole map rather than one model
    /// so a new thread that later switches engines lands on the model last
    /// used with *that* engine, not the engine's default.
    var lastPickedModelOverridesJSON: String? {
        didSet {
            guard lastPickedModelOverridesJSON != oldValue else { return }
            UserDefaults.standard.set(lastPickedModelOverridesJSON, forKey: Keys.lastPickedModelOverrides)
        }
    }

    /// The per-engine thinking-level map (`AgentThread.effortOverridesJSON`) as
    /// it stood when the user last picked a level. The whole map, for the same
    /// reason the model map is kept whole: the levels are per engine, so a new
    /// thread that switches engines lands on the level last used with *that* one.
    var lastPickedEffortOverridesJSON: String? {
        didSet {
            guard lastPickedEffortOverridesJSON != oldValue else { return }
            UserDefaults.standard.set(lastPickedEffortOverridesJSON, forKey: Keys.lastPickedEffortOverrides)
        }
    }

    /// Records a pick made in `thread`'s engine menu so the next new thread
    /// starts from it.
    func rememberPick(from thread: AgentThread) {
        lastPickedBackendRaw = thread.backendRaw
        lastPickedModelOverridesJSON = thread.modelOverridesJSON
        lastPickedEffortOverridesJSON = thread.effortOverridesJSON
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

        let storedPick = defaults.string(forKey: Keys.lastPickedBackend) ?? ""
        // Drop a pick for an engine this build no longer knows, so a stale
        // value can't pin new threads to nothing.
        self.lastPickedBackendRaw = AgentBackend(rawValue: storedPick) == nil ? "" : storedPick
        self.lastPickedModelOverridesJSON = defaults.string(forKey: Keys.lastPickedModelOverrides)
        self.lastPickedEffortOverridesJSON = defaults.string(forKey: Keys.lastPickedEffortOverrides)
    }

    private enum Keys {
        static let defaultBackend = "agent.defaultBackend"
        static let writePolicy = "agent.writePolicy"
        static let maxIterations = "agent.maxIterations"
        static let lastPickedBackend = "agent.lastPickedBackend"
        static let lastPickedModelOverrides = "agent.lastPickedModelOverrides"
        static let lastPickedEffortOverrides = "agent.lastPickedEffortOverrides"
    }
}
