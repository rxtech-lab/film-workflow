import SwiftUI

/// One project the agent can be pointed at, and the `@name` token that names it.
struct AgentTargetOption: Identifiable, Hashable {
    let kind: AgentTargetKind
    let projectUUID: UUID
    let name: String

    var id: String { "\(kind.rawValue):\(projectUUID.uuidString)" }
    var token: String { "@\(kind.rawValue):\(name)" }
}

/// Picks the engine (and, for engines whose model id says more than their name
/// does, the model) for one thread.
///
/// Sits under the composer as an `AgentChatView` accessory. It is per-thread
/// rather than global on purpose: a thread started on Codex keeps answering on
/// Codex after the app default changes, and can pin a model Settings never
/// named.
struct AgentEngineMenu: View {
    @Bindable var thread: AgentThread

    @Environment(AgentController.self) private var controller
    @State private var modelCatalog = AgentModelCatalog.shared

    var body: some View {
        Menu {
            Button {
                thread.backendOverride = nil
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
    /// the user didn't set.
    private var menuLabel: String {
        let backend = controller.backend(for: thread)
        guard let model = thread.modelOverride(for: backend), !model.isEmpty else {
            return backend.engineLabel
        }
        return "\(backend.engineLabel) · \(modelCatalog.displayName(for: model, backend: backend))"
    }
}
