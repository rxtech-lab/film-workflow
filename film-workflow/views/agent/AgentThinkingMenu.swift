import RxAgentSDK
import SwiftUI

/// Picks how hard the thread's engine should think.
///
/// Sits beside `AgentEngineMenu` under the composer rather than inside it: the
/// level is a different axis from the engine and its model, it changes far more
/// often than either, and a value two submenus deep reads as a setting rather
/// than a control.
///
/// Draws nothing for an engine with no such dial — Apple Intelligence, the
/// OpenAI-compatible loop and the subscription gateway all have none, so on
/// those threads the row is just the engine menu again.
///
/// The control itself is the SDK's `AgentReasoningPicker`. What this view adds
/// is where the levels and the selection come from: the levels belong to the
/// engine's *current model* (Codex publishes them per model), and the selection
/// is pinned per backend on the thread, so switching engines shows that engine's
/// own level rather than carrying one across.
struct AgentThinkingMenu: View {
    @Bindable var thread: AgentThread

    @Environment(AgentController.self) private var controller

    var body: some View {
        AgentReasoningPicker(
            levels: .describing(levels),
            selection: selection,
            defaultLabel: "Thinking",
            defaultRowTitle: defaultRowTitle,
            style: .chip(icon: "brain")
        )
    }

    private var backend: AgentBackend {
        controller.backend(for: thread)
    }

    private var levels: [String] {
        controller.thinkingLevels(for: thread, backend: backend)
    }

    private var selection: Binding<String?> {
        let backend = backend
        return Binding(
            get: { thread.effortOverride(for: backend) },
            set: { level in
                thread.setEffortOverride(level, for: backend)
                AgentSettings.shared.rememberPick(from: thread)
            }
        )
    }

    /// Names what clearing the pick falls back to, so the row isn't a mystery
    /// when Settings has a Codex level set.
    private var defaultRowTitle: String {
        guard let settings = controller.settingsThinkingLevel(for: thread, backend: backend) else {
            return "Engine default"
        }
        return "Settings (\(settings.capitalized))"
    }
}
