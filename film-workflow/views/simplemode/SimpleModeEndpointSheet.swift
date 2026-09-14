import SwiftUI

/// Edits only the endpoint settings, committing them when the user saves.
struct SimpleModeEndpointSheet: View {
    let onSave: (AppConfig) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var endpoint: String
    @State private var apiKey: String
    @State private var model: String
    @State private var models: [OpenAIModelInfo] = []
    @State private var modelsTask: Task<Void, Never>?
    @State private var isLoadingModels = false
    @State private var modelsError: String?
    @State private var saveError: String?

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        self.onSave = onSave
        _endpoint = State(initialValue: config.openAIEndpoint)
        _apiKey = State(initialValue: config.openAIKey)
        _model = State(initialValue: config.openAIModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 48, height: 48)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your Endpoint")
                        .font(.title2.weight(.semibold))
                    Text("Connect an OpenAI-compatible provider.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            Form {
                Section {
                    TextField("Endpoint URL", text: $endpoint, prompt: Text("https://api.openai.com/v1"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("wizard.endpoint.url")
                    SecureField("API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("wizard.endpoint.key")
                    if !trimmedEndpoint.isEmpty, !hasValidEndpoint {
                        Text("Enter a valid URL starting with https:// or http://.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Your API key is stored securely in the Keychain when you save.")
                }

                Section {
                    TextField("Chat model", text: $model, prompt: Text("Model ID"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("wizard.endpoint.model")
                    if !models.isEmpty {
                        Picker("Available models", selection: $model) {
                            if model.isEmpty {
                                Text("Select a model").tag("")
                            } else if !models.contains(where: { $0.id == model }) {
                                Text(model).tag(model)
                            }
                            ForEach(models) { option in
                                Text(option.id).tag(option.id)
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        Button("Load Models", action: loadModels)
                            .disabled(!hasValidEndpoint || trimmedKey.isEmpty || isLoadingModels)
                            .accessibilityIdentifier("wizard.endpoint.models.load")
                        if isLoadingModels {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if let modelsError {
                        Text(modelsError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Model")
                } footer: {
                    Text("Load models from your provider or enter a model ID.")
                }
            }
            .formStyle(.grouped)

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Endpoint", action: save)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasValidEndpoint || trimmedKey.isEmpty || trimmedModel.isEmpty)
                    .accessibilityIdentifier("wizard.endpoint.save")
            }
            .padding(20)
        }
        .frame(width: 540, height: 550)
        .onChange(of: endpoint) { invalidateModels() }
        .onChange(of: apiKey) { invalidateModels() }
        .onDisappear { modelsTask?.cancel() }
    }

    private var trimmedEndpoint: String { endpoint.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var hasValidEndpoint: Bool {
        guard let components = URLComponents(string: trimmedEndpoint),
              let scheme = components.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              trimmedEndpoint.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              components.url != nil else { return false }
        return true
    }

    private func invalidateModels() {
        modelsTask?.cancel()
        models = []
        modelsError = nil
        isLoadingModels = false
    }

    private func loadModels() {
        guard hasValidEndpoint, !trimmedKey.isEmpty else { return }
        modelsTask?.cancel()
        let requestedEndpoint = trimmedEndpoint
        let requestedKey = trimmedKey
        isLoadingModels = true
        modelsError = nil
        modelsTask = Task { @MainActor in
            do {
                let result = try await OpenAIModelsClient.shared.chatModels(
                    endpoint: requestedEndpoint,
                    apiKey: requestedKey,
                    forceRefresh: true
                )
                guard !Task.isCancelled else { return }
                models = result
                if result.isEmpty {
                    modelsError = String(localized: "No models were returned. You can enter a model ID above.")
                }
            } catch {
                guard !Task.isCancelled else { return }
                modelsError = error.localizedDescription
            }
            isLoadingModels = false
        }
    }

    private func save() {
        guard hasValidEndpoint, !trimmedKey.isEmpty, !trimmedModel.isEmpty else { return }
        do {
            // Merge into the latest settings so other engines' choices stay current.
            let current = try AppConfig.loadFromKeychain()
            var updated = current
            updated.openAIEndpoint = trimmedEndpoint
            updated.openAIKey = trimmedKey
            updated.openAIModel = trimmedModel
            try updated.saveChanges(since: current)
            onSave(updated)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
