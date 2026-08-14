import SwiftUI
import TipKit

struct MCPSettingsView: View {
    @State private var settings = MCPSettings.shared
    @State private var server = MCPServer.shared
    @State private var portText: String = ""
    @State private var revealToken: Bool = false
    @State private var copiedKey: String?

    var body: some View {
        Form {
            Section {
                Toggle("Enable MCP server", isOn: Binding(
                    get: { settings.enabled },
                    set: { settings.enabled = $0 }
                ))
                .popoverTip(FilmWorkflowTips.MCPServerTip(), arrowEdge: .top)
            } header: {
                Text("MCP Server")
            } footer: {
                Text("Exposes project tools (narrative, music, image, remotion) over an HTTP MCP endpoint. Auto-starts when this app launches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Bind", selection: Binding(
                    get: { settings.bindAll },
                    set: { settings.bindAll = $0 }
                )) {
                    Text("Localhost only (127.0.0.1)").tag(false)
                    Text("All interfaces (0.0.0.0)").tag(true)
                }
                .pickerStyle(.inline)

                HStack {
                    Text("Base port")
                    Spacer()
                    TextField("7711", text: $portText)
                        #if os(macOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                        .frame(width: 100)
                        .onSubmit {
                            commitPort()
                        }
                    Stepper("", value: Binding(
                        get: { settings.basePort },
                        set: { settings.basePort = max(1024, $0) }
                    ), in: 1024...65535)
                    .labelsHidden()
                }
            } header: {
                Text("Network")
            } footer: {
                Text("If the configured port is in use, the next free port (up to base+9) will be used instead. The actual port is shown below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                HStack {
                    Circle()
                        .fill(server.isRunning ? .green : .secondary)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                if let url = server.displayURL {
                    HStack {
                        Text(url)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        copyIconButton(key: "url", value: url)
                    }
                }
                if let err = server.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                HStack {
                    if let token = settings.token {
                        Text(revealToken ? token : maskedToken(token))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(revealToken ? "Hide" : "Show") {
                            revealToken.toggle()
                        }
                        .buttonStyle(.borderless)
                        copyIconButton(key: "token", value: token)
                    } else {
                        Text("(not generated)")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                Button("Regenerate token") {
                    _ = try? settings.regenerateToken()
                    revealToken = false
                }
                .disabled(!settings.enabled)
            } header: {
                Text("Bearer token")
            } footer: {
                Text(requiresToken
                     ? "Required on every request. Subscription mode can spend credits, including through localhost tools."
                     : "Required when bound to all interfaces. Localhost BYOK requests skip the check.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let url = server.displayURL, settings.enabled {
                Section("Connect from Claude Code") {
                    let cmd = connectCommand(url: url, requiresToken: requiresToken, token: settings.token)
                    HStack(alignment: .top) {
                        Text(cmd)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        copyIconButton(key: "command", value: cmd)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if portText.isEmpty { portText = String(settings.basePort) }
        }
        .onChange(of: settings.basePort) { _, newValue in
            portText = String(newValue)
        }
    }

    private var statusText: String {
        if server.isRunning, let port = settings.actualPort {
            return port == settings.basePort
                ? "Running on port \(port)"
                : "Running on port \(port) (base \(settings.basePort) was busy)"
        }
        return settings.statusMessage
    }

    private var requiresToken: Bool {
        settings.bindAll || ((try? AppConfig.loadFromKeychain())?.usesSubscription == true)
    }

    private func commitPort() {
        if let n = Int(portText), n >= 1024, n <= 65535 {
            settings.basePort = n
        } else {
            portText = String(settings.basePort)
        }
    }

    private func maskedToken(_ token: String) -> String {
        guard token.count > 6 else { return String(repeating: "•", count: 12) }
        let suffix = token.suffix(4)
        return String(repeating: "•", count: 12) + suffix
    }

    @ViewBuilder
    private func copyIconButton(key: String, value: String) -> some View {
        let copied = copiedKey == key
        Button {
            copyToClipboard(value, key: key)
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? .green : .accentColor)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .help(copied ? "Copied" : "Copy")
    }

    private func copyToClipboard(_ s: String, key: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        #endif
        copiedKey = key
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedKey == key { copiedKey = nil }
        }
    }

    private func connectCommand(url: String, requiresToken: Bool, token: String?) -> String {
        if requiresToken, let token, !token.isEmpty {
            return "claude mcp add --transport http film \(url) -H \"Authorization: Bearer \(token)\""
        }
        return "claude mcp add --transport http film \(url)"
    }
}

#if !os(macOS)
import UIKit
#endif
