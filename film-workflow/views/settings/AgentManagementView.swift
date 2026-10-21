#if os(macOS)
import SwiftUI
import RxAgentSDK
import RxAgentManagement

struct AgentManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = AgentManagementStore.shared
    @State private var editor: ManagedACPClient?
    @State private var browsing = false
    @State private var removing: ManagedACPClient?
    @State private var busy = false
    @State private var message: String?
    @State private var refreshID = UUID()
    @State private var acpAccount: ManagedACPClient?
    @State private var acpSignOut = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agent Runtimes").font(.headline)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") {
                    refreshID = UUID()
                    Task { await store.load() }
                }.labelStyle(.iconOnly).buttonStyle(.plain).help("Refresh runtime status")
            }.padding(20)
            Divider()
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach([CLIAccountProvider.claude, .codex]) { provider in
                        CLIRuntimeRow(provider: provider, refreshID: refreshID)
                    }
                    ForEach(store.clients) { client in
                        AgentRuntimeRow(name: client.name, installed: FileManager.default.isExecutableFile(atPath: client.command),
                            version: client.version ?? "Custom ACP client",
                            detail: store.selectedID == client.id ? "Default ACP client" : (client.enabled ? "ACP" : "Disabled"),
                            path: client.command) {
                            Button("Sign In…") { acpAccount = client; acpSignOut = false }
                            Button("Sign Out…") { acpAccount = client; acpSignOut = true }
                            Divider()
                            Button("Use for ACP engine") {
                                store.selectedID = client.id
                                message = "ACP engine default updated. New conversations will use \(client.name)."
                            }.disabled(!client.enabled)
                            Button("Edit…") { editor = client }
                            Button("Remove…", role: .destructive) { removing = client }
                        }
                    }
                }.padding(20)
            }
            Divider()
            HStack {
                Menu("Add Client", systemImage: "plus") {
                    Button("Download from ACP Registry…") { browsing = true }
                    Button("Add Custom Client…") { editor = ManagedACPClient(name: "", command: "") }
                }.fixedSize()
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(16)
        }
        .frame(width: 720, height: 530)
        .task { await store.load(); message = store.loadError }
        .sheet(item: $acpAccount) { ACPAccountSheet(client: $0, signOut: acpSignOut) }
        .sheet(item: $editor) { ACPClientEditor(client: $0) }
        .sheet(isPresented: $browsing) { ACPRegistrySheet() }
        .confirmationDialog("Remove \(removing?.name ?? "client")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let client = removing {
                Button("Remove Client", role: .destructive) {
                    removing = nil; busy = true
                    Task {
                        do { try await store.remove(client); message = "Client removed." }
                        catch { message = error.localizedDescription }
                        busy = false
                    }
                }
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { Text("Downloaded files are removed. The provider account stays signed in.") }
        .disabled(busy)
        .overlay { if busy { ProgressView("Removing client…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .alert("Agent Management", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }
}

private struct ACPClientEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var client: ManagedACPClient
    @State private var arguments = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $client.name)
                TextField("Executable path or command", text: $client.command)
                TextField("Arguments (one per line)", text: $arguments, axis: .vertical).lineLimit(3...6)
                Toggle("Enabled", isOn: $client.enabled)
            }.formStyle(.grouped).navigationTitle("ACP Client")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }
                        .disabled(client.name.trimmingCharacters(in: .whitespaces).isEmpty || client.command.trimmingCharacters(in: .whitespaces).isEmpty || busy) }
                }
        }.frame(width: 500, height: 360)
            .onAppear { arguments = client.arguments.joined(separator: "\n") }
            .disabled(busy)
            .overlay { if busy { ProgressView("Saving client…").padding().background(.regularMaterial) } }
            .alert("Could Not Save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
    private func save() {
        busy = true
        Task {
            client.name = client.name.trimmingCharacters(in: .whitespacesAndNewlines)
            client.command = client.command.trimmingCharacters(in: .whitespacesAndNewlines)
            client.arguments = arguments.split(separator: "\n").map(String.init)
            let resolved = client.command.hasPrefix("/") ? client.command : await ShellEnvironment.shared.findBinary(named: client.command)
            guard let resolved, FileManager.default.isExecutableFile(atPath: resolved) else {
                error = "Executable not found. Install the tool or choose its absolute path."; busy = false; return
            }
            client.command = resolved
            do { try await AgentManagementStore.shared.save(client); dismiss() }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

private struct ACPRegistrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [AgentRegistryEntry] = []
    @State private var query = ""
    @State private var selected: AgentRegistryEntry?
    @State private var busy = false
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List(entries.filter { $0.canInstall && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }) { entry in
                Button { selected = entry } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name).font(.headline)
                        Text(entry.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text(entry.version).font(.caption2)
                    }.padding(.vertical, 4)
                }.buttonStyle(.plain)
            }.searchable(text: $query).navigationTitle("ACP Registry")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(busy) }
                    ToolbarItem { Button("Reload", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(busy || loading) }
                }
        }.frame(width: 560, height: 540)
            .task { await load() }
            .disabled(busy)
            .interactiveDismissDisabled(busy)
            .overlay { if loading || busy { ProgressView(busy ? "Downloading and installing…" : "Loading registry…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            .confirmationDialog("Install \(selected?.name ?? "client")?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
                if let entry = selected { Button("Download & Install") { selected = nil; install(entry) } }
                Button("Cancel", role: .cancel) { selected = nil }
            } message: { Text("This downloads and runs third-party software from the ACP registry.") }
            .alert("ACP Registry", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
    private func load() async {
        loading = true
        do { entries = try await AgentManagementStore.shared.service.registry() }
        catch { self.error = error.localizedDescription }
        loading = false
    }
    private func install(_ entry: AgentRegistryEntry) {
        busy = true
        Task {
            let store = AgentManagementStore.shared
            do {
                let path = await ShellEnvironment.shared.resolvedPath()
                var client = try await store.service.install(entry, path: path)
                let previous = store.clients.first { $0.registryID == entry.id }
                if let previous { client.id = previous.id; client.enabled = previous.enabled }
                do { try await store.save(client) }
                catch { try? await store.service.removeFiles(for: client); throw error }
                dismiss()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}


#endif

#if os(macOS)
/// All runtimes use the same row hierarchy and an explicit Manage dropdown.
private struct AgentRuntimeRow<Actions: View>: View {
    let name: String
    let installed: Bool
    let version: String
    let detail: String
    let path: String
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: installed ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title3).foregroundStyle(installed ? .green : .secondary)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(name).font(.headline)
                    Text(installed ? "Installed" : "Unavailable").foregroundStyle(installed ? .green : .secondary)
                    if !version.isEmpty { Text(version).foregroundStyle(.secondary).lineLimit(1) }
                }
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                Text(path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled).help(path)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu("Manage", content: actions).menuStyle(.borderedButton).fixedSize()
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1) }
    }
}

private struct CLIRuntimeRow: View {
    let provider: CLIAccountProvider
    let refreshID: UUID
    @State private var binary: String?
    @State private var version = ""
    @State private var status = "Checking…"
    @State private var busy = false
    @State private var message: String?
    @State private var signOut = false
    @State private var installing = false
    var body: some View {
        AgentRuntimeRow(name: provider == .codex ? "Codex" : "Claude Code", installed: binary != nil,
            version: version, detail: status, path: binary ?? "Not installed on this Mac") {
            Button("Sign In…") { signIn() }.disabled(binary == nil)
            Button("Sign Out…", role: .destructive) { signOut = true }.disabled(binary == nil)
            Divider()
            Button(binary == nil ? "Download & Install…" : "Update Runtime…") { installing = true }
            Button("Refresh Status") { Task { await refresh(); await refreshModels() } }
        }
        .task(id: refreshID) { await refresh() }
        .sheet(isPresented: $installing, onDismiss: { Task { await refresh(); await refreshModels() } }) { CLIRuntimeInstallSheet(provider: provider) }
        .disabled(busy)
        .overlay { if busy { ProgressView("Updating account…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) } }
        .confirmationDialog("Sign out of \(provider.name)?", isPresented: $signOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                guard let binary else { return }
                busy = true
                Task {
                    do {
                        _ = try await AgentCommand.run(binary, arguments: provider.logoutArguments, path: await ShellEnvironment.shared.resolvedPath())
                        await refresh(); message = "Signed out."
                    } catch { message = error.localizedDescription }
                    busy = false
                }
            }
        } message: { Text("Other apps using this CLI account will also be signed out.") }
        .alert("Agent Runtime", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") { message = nil } } message: { Text(message ?? "") }
    }
    private func refresh() async {
        let managed = AgentManagementStore.shared.service.runtimePath(provider)
        binary = FileManager.default.isExecutableFile(atPath: managed) ? managed : await ShellEnvironment.shared.findBinary(named: provider.rawValue)
        guard let binary else { status = "Install this runtime to connect your account."; version = ""; return }
        let path = await ShellEnvironment.shared.resolvedPath()
        do {
            version = try await AgentCommand.run(binary, arguments: ["--version"], path: path).output.trimmingCharacters(in: .whitespacesAndNewlines)
            status = try await provider.status(binary: binary, path: path)
        } catch { status = "Status unavailable" }
        AgentBackendAvailability.shared.refresh()
    }
    private func refreshModels() async {
        guard provider == .codex else { return }
        await AgentModelCatalog.shared.loadCodexModels(forceRefresh: true)
        if let error = AgentModelCatalog.shared.codexModelsError { message = error }
    }
    private func signIn() {
        guard let binary else { return }
        Task {
            do {
                try provider.openSignIn(binary: binary, path: await ShellEnvironment.shared.resolvedPath())
                message = "Complete sign-in in Terminal and your browser, then choose Manage → Refresh Status."
            } catch { message = error.localizedDescription }
        }
    }
}

private struct CLIRuntimeInstallSheet: View {
    let provider: CLIAccountProvider
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        NavigationStack {
            Form {
                Text("Download the latest \(provider.name) runtime from its official npm package.")
                Text("Requires Node.js and npm. The runtime is installed in Film Studio’s Application Support folder.").foregroundStyle(.secondary)
                Button("Download & Install") {
                    busy = true
                    Task {
                        do {
                            _ = try await AgentManagementStore.shared.service.installRuntime(provider, path: await ShellEnvironment.shared.resolvedPath())
                            AgentBackendAvailability.shared.refresh()
                            dismiss()
                        } catch { message = error.localizedDescription }
                        busy = false
                    }
                }.disabled(busy)
            }.formStyle(.grouped).navigationTitle("Install Runtime")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }
        }.frame(width: 500, height: 280)
            .interactiveDismissDisabled(busy)
            .overlay { if busy { ProgressView("Downloading runtime…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .alert("Runtime Installation", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") { message = nil } } message: { Text(message ?? "") }
    }
}

private struct ACPAccountSheet: View {
    let client: ManagedACPClient
    let signOut: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var session = ACPAccountSession()
    @State private var methods: [ACPAccountMethod] = []
    @State private var supportsLogout = false
    @State private var busy = false
    @State private var status = ""
    @State private var error: String?
    @State private var actionTask: Task<Void, Never>?
    @State private var confirmSignOut = false
    var body: some View {
        NavigationStack {
            Form {
                if signOut {
                    if supportsLogout {
                        Button("Sign Out", role: .destructive) { confirmSignOut = true }
                    } else if !busy {
                        Text("This client does not advertise ACP sign-out. Use its provider’s account settings or CLI to sign out.").foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(methods) { method in
                        Button(method.name) { authenticate(method) }.disabled(method.type != "agent" && method.type != "terminal")
                        if let description = method.description { Text(description).font(.caption).foregroundStyle(.secondary) }
                    }
                    if methods.isEmpty && !busy { Text("This client does not advertise a sign-in method. Manage its credentials through the provider’s CLI.").foregroundStyle(.secondary) }
                    if methods.contains(where: { $0.type == "env_var" }) {
                        Text("Environment-key methods require configuration in the provider’s own CLI.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped).disabled(busy).navigationTitle(client.name)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }.frame(width: 520, height: 360)
            .task {
                busy = true
                do {
                    let info = try await session.initialize(client: client)
                    methods = info.methods; supportsLogout = info.logout
                } catch { self.error = error.localizedDescription }
                busy = false
            }
            .onDisappear { actionTask?.cancel(); Task { await session.close() } }
            .overlay { if busy { ProgressView("Connecting to client…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .confirmationDialog("Sign out of this client?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    busy = true
                    actionTask = Task {
                        do { try await session.signOut(); status = "Signed out." }
                        catch { self.error = error.localizedDescription }
                        busy = false
                    }
                }
            }
            .alert("ACP Account", isPresented: Binding(get: { error != nil || !status.isEmpty }, set: { if !$0 { error = nil; status = "" } })) {
                Button("OK") { error = nil; status = "" }
            } message: { Text(error ?? status) }
    }
    private func authenticate(_ method: ACPAccountMethod) {
        busy = true
        actionTask = Task {
            do {
                if method.type == "terminal" {
                    try AgentTerminalAction.open(command: method.terminalCommand ?? client.command,
                        arguments: method.terminalCommand == nil ? client.arguments + method.arguments : method.arguments,
                        environment: method.environment, path: await ShellEnvironment.shared.resolvedPath())
                    status = "Complete sign-in in Terminal and your browser."
                } else {
                    try await session.authenticate(method: method.id)
                    status = "The client accepted the sign-in request. Complete any provider steps, then refresh models to check access."
                }
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
#endif
