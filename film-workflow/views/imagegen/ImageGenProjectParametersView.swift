import SwiftUI

struct ImageGenProjectParametersView: View {
    @Bindable var project: ImageGenProject

    @State private var openAIImageModels: [OpenAIModelInfo] = []
    @State private var isLoadingModels = false
    @State private var modelsError: String?

    private var googleStyleForm: Bool {
        if project.providerEnum == .google { return true }
        if project.providerEnum == .openai
            && project.openAIModel.lowercased().contains("google") { return true }
        return false
    }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: Binding(
                    get: { project.providerEnum },
                    set: { project.providerEnum = $0; project.updatedAt = Date() }
                )) {
                    ForEach(ImageProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Provider")
            }

            Section {
                TextEditor(text: $project.prompt)
                    .frame(minHeight: 80)
                    .font(.body)
            } header: {
                Text("Prompt")
            }

            if project.providerEnum == .openai {
                Section {
                    HStack {
                        Picker("Model", selection: $project.openAIModel) {
                            if project.openAIModel.isEmpty {
                                Text("Select a model").tag("")
                            } else if !openAIImageModels.contains(where: { $0.id == project.openAIModel }) {
                                Text(project.openAIModel).tag(project.openAIModel)
                            }
                            ForEach(openAIImageModels) { model in
                                Text(model.id).tag(model.id)
                            }
                        }

                        Button {
                            Task { await loadImageModels(forceRefresh: true) }
                        } label: {
                            if isLoadingModels {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(isLoadingModels)
                        .help("Refresh model list")
                    }

                    if let modelsError {
                        Text(modelsError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Model")
                }
            }

            if googleStyleForm {
                googleParametersSection
            } else {
                openAIParametersSection
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if project.providerEnum == .openai {
                Task { await loadImageModels(forceRefresh: false) }
            }
        }
        .onChange(of: project.providerEnum) { _, newValue in
            if newValue == .openai {
                Task { await loadImageModels(forceRefresh: false) }
            }
        }
    }

    @ViewBuilder
    private var googleParametersSection: some View {
        Section {
            Picker("Aspect Ratio", selection: Binding(
                get: { project.googleAspectRatioEnum },
                set: { project.googleAspectRatioEnum = $0 }
            )) {
                ForEach(ImageAspectRatio.allCases) { value in
                    Text(value.displayName).tag(value)
                }
            }

            Picker("Resolution", selection: Binding(
                get: { project.googleResolutionEnum },
                set: { project.googleResolutionEnum = $0 }
            )) {
                ForEach(ImageResolution.allCases) { value in
                    Text(value.displayName).tag(value)
                }
            }
        } header: {
            Text("Image Parameters")
        } footer: {
            Text("Google Imagen controls. Use a 5:4 / 2K ratio for landscape stills.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var openAIParametersSection: some View {
        Section {
            Picker("Size", selection: Binding(
                get: { project.openAISizeEnum },
                set: { project.openAISizeEnum = $0 }
            )) {
                ForEach(ImageSize.allCases) { value in
                    Text(value.displayName).tag(value)
                }
            }

            if project.openAISizeEnum == .custom {
                HStack {
                    Text("Width")
                    Spacer()
                    TextField("Width", value: $project.openAICustomWidth, format: .number)
                        #if os(macOS)
                        .textFieldStyle(.roundedBorder)
                        #else
                        .keyboardType(.numberPad)
                        #endif
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                    Text("px")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Height")
                    Spacer()
                    TextField("Height", value: $project.openAICustomHeight, format: .number)
                        #if os(macOS)
                        .textFieldStyle(.roundedBorder)
                        #else
                        .keyboardType(.numberPad)
                        #endif
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                    Text("px")
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Quality", selection: Binding(
                get: { project.openAIQualityEnum },
                set: { project.openAIQualityEnum = $0 }
            )) {
                ForEach(ImageQuality.allCases) { value in
                    Text(value.displayName).tag(value)
                }
            }

            Picker("Format", selection: Binding(
                get: { project.openAIFormatEnum },
                set: {
                    project.openAIFormatEnum = $0
                    if !$0.supportsTransparent { project.openAITransparent = false }
                }
            )) {
                ForEach(ImageFormat.allCases.filter { !project.openAITransparent || $0.supportsTransparent }) { value in
                    Text(value.displayName).tag(value)
                }
            }

            if project.openAIFormatEnum.supportsCompression {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Compression")
                        Spacer()
                        Text("\(project.openAICompression)%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(project.openAICompression) },
                            set: { project.openAICompression = Int($0) }
                        ),
                        in: 0...100,
                        step: 1
                    )
                }
            }

            Picker("Background", selection: Binding(
                get: { project.openAIBackgroundEnum },
                set: { project.openAIBackgroundEnum = $0 }
            )) {
                ForEach(ImageBackground.allCases) { value in
                    Text(value.displayName).tag(value)
                }
            }
            .disabled(project.openAITransparent)

            Toggle("Transparent background", isOn: $project.openAITransparent)
                .disabled(!project.openAIFormatEnum.supportsTransparent)
        } header: {
            Text("Image Parameters")
        } footer: {
            Text("Transparent background requires PNG or WebP output.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func loadImageModels(forceRefresh: Bool) async {
        guard let config = try? AppConfig.loadFromKeychain(),
              !config.openAIEndpoint.isEmpty,
              !config.openAIKey.isEmpty else {
            modelsError = "Configure the OpenAI endpoint and API key in Settings."
            return
        }
        isLoadingModels = true
        modelsError = nil
        defer { isLoadingModels = false }
        do {
            let models = try await OpenAIModelsClient.shared.imageModels(
                endpoint: config.openAIEndpoint,
                apiKey: config.openAIKey,
                forceRefresh: forceRefresh
            )
            openAIImageModels = models
        } catch {
            modelsError = error.localizedDescription
        }
    }
}
