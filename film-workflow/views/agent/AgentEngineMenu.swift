import SwiftUI

/// One library item the agent can be pointed at, and the `@kind:name` token
/// that names it in the composer. The kind is spelled the way the library
/// spells it (`narration`, `image`), not the way the target enum does.
struct AgentTargetOption: Identifiable, Hashable {
    let kind: AgentTargetKind
    let projectUUID: UUID
    let name: String

    var id: String { "\(kindName):\(projectUUID.uuidString)" }
    var kindName: String { kind.footageKind?.rawValue ?? kind.rawValue }
    var token: String { "@\(kindName):\(name)" }
}

/// Picks the engine (and, for engines whose model id says more than their name
/// does, the model) for one thread.
///
/// Sits under the composer as an `AgentChatView` accessory. It is per-thread
/// rather than global on purpose: a thread started on Codex keeps answering on
/// Codex after the app default changes, and can pin a model Settings never
/// named.
///
/// The thinking level is the neighbouring control (`AgentThinkingMenu`), not a
/// submenu here: it is a third axis, it changes much more often than the engine
/// or the model, and it depends on which model this menu lands on.
struct AgentEngineMenu: View {
    @Bindable var thread: AgentThread

    @Environment(AgentController.self) private var controller
    @State private var modelCatalog = AgentModelCatalog.shared

    var body: some View {
        Menu {
            Button {
                thread.backendOverride = nil
                AgentSettings.shared.rememberPick(from: thread)
            } label: {
                if thread.backendOverride == nil {
                    Label("Default", systemImage: "checkmark")
                } else {
                    Text("Default")
                }
            }
            Divider()
            ForEach(AgentBackend.supported) { backend in
                if backend.isCommandLine || backend == .subscription {
                    Menu(backend.engineLabel) {
                        modelButton(backend: backend, model: nil)
                        Divider()
                        ForEach(modelCatalog.options(for: backend)) { option in
                            modelButton(
                                backend: backend,
                                model: option.id,
                                name: option.displayName
                            )
                        }
                    }
                } else {
                    Button {
                        thread.backendOverride = backend
                        AgentSettings.shared.rememberPick(from: thread)
                    } label: {
                        if thread.backendOverride == backend {
                            Label(backend.displayName, systemImage: "checkmark")
                        } else {
                            Text(backend.displayName)
                        }
                    }
                }
            }
        } label: {
            Label {
                Text(menuLabel)
            } icon: {
                Image(systemName: "sparkles")
            }
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// One row in an engine's model submenu. `model: nil` is the row that clears
    /// the thread's override and falls back to Settings.
    @ViewBuilder
    private func modelButton(
        backend: AgentBackend,
        model: String?,
        name: String? = nil
    ) -> some View {
        let isSelected = controller.backend(for: thread) == backend
            && thread.modelOverride(for: backend) == model
        Button {
            thread.backendOverride = backend
            thread.setModelOverride(model, for: backend)
            AgentSettings.shared.rememberPick(from: thread)
        } label: {
            if isSelected {
                Label(name ?? "Default model", systemImage: "checkmark")
            } else {
                Text(name ?? "Default model")
            }
        }
    }

    /// "Codex · GPT-5.6-Sol" when the thread pins a model, the engine name alone
    /// otherwise — the Settings-level model belongs in Settings, not on a button
    /// the user didn't set. The thinking level has its own control beside this
    /// one (`AgentThinkingMenu`) and stays out of this label.
    private var menuLabel: String {
        let backend = controller.backend(for: thread)
        guard let model = thread.modelOverride(for: backend), !model.isEmpty else {
            return backend.engineLabel
        }
        return "\(backend.engineLabel) · \(modelCatalog.displayName(for: model, backend: backend))"
    }
}
