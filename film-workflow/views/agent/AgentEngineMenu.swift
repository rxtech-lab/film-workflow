#if os(macOS)
import RxAgentManagement
#endif
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
    @State private var refreshError: String?
    #if os(macOS)
    @State private var clientStore = AgentManagementStore.shared
    @State private var managingClients = false
    @State private var acpModels: [ManagedACPClient: [ACPSupportedModel]] = [:]
    @State private var loadingACPModels: Set<ManagedACPClient> = []
    @State private var acpModelErrors: [ManagedACPClient: String] = [:]
    #endif

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
                if backend == .acp {
                    acpClientMenu
                } else if backend.isCommandLine || backend == .subscription {
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
                        if backend == .codex {
                            Divider()
                            Button("Refresh Models", systemImage: "arrow.clockwise") {
                                Task {
                                    await modelCatalog.loadCodexModels(forceRefresh: true)
                                    refreshError = modelCatalog.codexModelsError
                                }
                            }.disabled(modelCatalog.isLoadingCodexModels)
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
        .filmTip(.chatEngine, when: !controller.isRunning(thread.id))
        .task {
            #if os(macOS)
            await clientStore.load()
            #endif
            await modelCatalog.loadCodexModels(forceRefresh: false)
        }
        #if os(macOS)
        .sheet(isPresented: $managingClients) { AgentManagementView() }
        .task(id: clientStore.clients) {
            for client in clientStore.clients where client.enabled {
                guard !Task.isCancelled else { return }
                if acpModels[client] == nil { await loadACPModels(client) }
            }
        }
        #endif
        .overlay {
            if isLoadingModels { ProgressView().controlSize(.small).padding(6).background(.regularMaterial, in: Capsule()) }
        }
        .alert("Could Not Refresh Models", isPresented: Binding(get: { refreshError != nil }, set: { if !$0 { refreshError = nil } })) {
            Button("OK") { refreshError = nil }
        } message: { Text(refreshError ?? "") }
        .onChange(of: thread.backendRaw) { FilmFeatureTip.chatEngine.didPerform() }
        .onChange(of: thread.modelOverridesJSON) { FilmFeatureTip.chatEngine.didPerform() }
    }

    @ViewBuilder
    private var acpClientMenu: some View {
        #if os(macOS)
        Menu("ACP Clients") {
            ForEach(clientStore.clients.filter(\.enabled)) { client in
                Menu(client.name) {
                    Button {
                        do {
                            try thread.selectACPClient(client)
                            thread.setModelOverride(nil, for: .acp)
                            AgentSettings.shared.rememberPick(from: thread)
                        } catch { refreshError = error.localizedDescription }
                    } label: {
                        if controller.backend(for: thread) == .acp && thread.configuredACPClient?.id == client.id && thread.modelOverride(for: .acp) == nil {
                            Label("Default model", systemImage: "checkmark")
                        } else { Text("Default model") }
                    }.disabled(controller.isRunning(thread.id))
                    Divider()
                    if let models = acpModels[client], !models.isEmpty {
                        ForEach(acpModelGroups(models), id: \.self) { group in
                            Section(group) {
                                ForEach(models.filter { ($0.group ?? "Models") == group }) { model in
                                    acpModelButton(client: client, model: model)
                                }
                            }
                        }
                    } else if loadingACPModels.contains(client) {
                        Text("Loading models…")
                    } else if acpModelErrors[client] != nil {
                        Text("Could not load models")
                    } else {
                        Text("No models reported")
                    }
                    Divider()
                    Button("Refresh Models", systemImage: "arrow.clockwise") {
                        Task {
                            await loadACPModels(client)
                            refreshError = acpModelErrors[client]
                        }
                    }.disabled(loadingACPModels.contains(client))
                }
            }
            if clientStore.clients.allSatisfy({ !$0.enabled }) { Text("No enabled ACP clients") }
            Divider()
            Button("Manage ACP Clients…") { managingClients = true }
        }
        #endif
    }

    private var isLoadingModels: Bool {
        #if os(macOS)
        modelCatalog.isLoadingCodexModels || !loadingACPModels.isEmpty
        #else
        modelCatalog.isLoadingCodexModels
        #endif
    }

    #if os(macOS)
    private func acpModelButton(client: ManagedACPClient, model: ACPSupportedModel) -> some View {
        let selected = controller.backend(for: thread) == .acp
            && thread.configuredACPClient?.id == client.id
            && thread.modelOverride(for: .acp) == model.id
        return Button {
            do {
                try thread.selectACPClient(client)
                thread.setModelOverride(model.id, for: .acp)
                AgentSettings.shared.rememberPick(from: thread)
            } catch { refreshError = error.localizedDescription }
        } label: {
            if selected { Label(model.name, systemImage: "checkmark") }
            else { Text(model.name) }
        }
        .help(model.detail ?? model.id)
        .disabled(controller.isRunning(thread.id))
    }

    private func acpModelGroups(_ models: [ACPSupportedModel]) -> [String] {
        var seen = Set<String>()
        return models.map { $0.group ?? "Models" }.filter { seen.insert($0).inserted }
    }

    private func loadACPModels(_ client: ManagedACPClient) async {
        guard loadingACPModels.insert(client).inserted else { return }
        defer { loadingACPModels.remove(client) }
        acpModelErrors[client] = nil
        do {
            let models = try await ACPAccountSession().supportedModels(client: client)
            try Task.checkCancellation()
            acpModels[client] = models
        } catch {
            if !Task.isCancelled { acpModelErrors[client] = error.localizedDescription }
        }
    }
    #endif

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
        #if os(macOS)
        if backend == .acp, let client = thread.configuredACPClient {
            guard let model = thread.modelOverride(for: .acp) else { return client.name }
            let name = acpModels[client]?.first { $0.id == model }?.name ?? model
            return "\(client.name) · \(name)"
        }
        #endif
        guard let model = thread.modelOverride(for: backend), !model.isEmpty else {
            return backend.engineLabel
        }
        return "\(backend.engineLabel) · \(modelCatalog.displayName(for: model, backend: backend))"
    }
}
