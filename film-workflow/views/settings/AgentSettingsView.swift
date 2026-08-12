import SwiftUI

/// Settings for the agent window.
struct AgentSettingsView: View {
    @State private var settings = AgentSettings.shared
    @State private var availability = AgentBackendAvailability.shared
    @State private var config: AppConfig?

    var body: some View {
        Form {
            backendSection
            policySection
            limitsSection
        }
        .formStyle(.grouped)
        .onAppear {
            config = try? AppConfig.loadFromKeychain()
            availability.refresh()
        }
    }

    // MARK: - Backend

    private var backendSection: some View {
        Section {
            Picker("Default engine", selection: $settings.defaultBackend) {
                ForEach(AgentBackend.supported) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }

            if let reason = availability.unavailableReason(settings.defaultBackend, config: config) {
                Label {
                    Text(reason)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
            }

            if settings.defaultBackend == .appleIntelligence {
                Label {
                    Text("""
                        Apple Intelligence runs on device and cannot call tools, so \
                        it can answer questions but not change your projects. \
                        Caption edits are the exception — it can still propose those.
                        """)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("Engine")
        } footer: {
            Text("""
                Each thread can override this from the picker in its composer. \
                Claude Code and Codex talk to this app over its own MCP server, \
                which starts automatically when a thread needs it.
                """)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Write policy

    private var policySection: some View {
        Section {
            Picker("Caption edits", selection: $settings.writePolicy) {
                Text("Review before applying").tag(AgentWritePolicy.review)
                Text("Apply immediately").tag(AgentWritePolicy.direct)
            }
            .pickerStyle(.inline)
        } header: {
            Text("Permissions")
        } footer: {
            Text("""
                Reviewing keeps the agent from writing caption text directly — it \
                proposes changes and you approve them. Everything else it does \
                (creating projects, editing compositions, generating images) takes \
                effect immediately either way.
                """)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Limits

    private var limitsSection: some View {
        Section {
            Stepper(
                "Tool rounds per turn: \(settings.maxIterations)",
                value: $settings.maxIterations,
                in: 5...50,
                step: 5
            )
        } header: {
            Text("Limits")
        } footer: {
            Text("""
                How many times the agent may call tools before it has to answer. \
                Raise it for long jobs; lower it to cut a looping model short sooner.
                """)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
