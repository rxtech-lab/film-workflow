import SwiftUI

struct ImageGenProjectParametersView: View {
    @Bindable var project: ImageGenProject

    @State private var subscriptionModels: [PickableModel] = []
    @State private var isLoadingSubscriptionModels = false
    @State private var subscriptionModelsError: String?

    /// Catalog models carry the provider the backend will actually call, so the
    /// form follows that rather than guessing from the id: a Google model runs
    /// on AI Studio and takes aspect ratio and resolution, while a gateway
    /// model takes the size/quality/format controls.
    private var googleStyleForm: Bool {
        if let model = subscriptionModels.first(where: { $0.id == project.subscriptionModel }) {
            return model.provider == "google"
        }
        return project.subscriptionModel.lowercased().contains("imagen")
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $project.prompt)
                    .frame(minHeight: 80)
                    .font(.body)
            } header: {
                Text("Prompt")
            }

            Section {
                HStack {
                    Picker("Model", selection: $project.subscriptionModel) {
                        Text("Use app default").tag("")
                        if !project.subscriptionModel.isEmpty,
                           !subscriptionModels.contains(where: { $0.id == project.subscriptionModel }) {
                            Text(project.subscriptionModel).tag(project.subscriptionModel)
                        }
                        ForEach(subscriptionModels) { model in
                            Text(model.pickerLabel).tag(model.id)
                        }
                    }
                    Button {
                        Task { await loadSubscriptionModels(forceRefresh: true) }
                    } label: {
                        if isLoadingSubscriptionModels { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(isLoadingSubscriptionModels)
                    .help("Refresh model list")
                }
                if let subscriptionModelsError {
                    Text(subscriptionModelsError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Model")
            }

            if googleStyleForm {
                googleParametersSection
            } else {
                openAIParametersSection
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if project.subscriptionModel.isEmpty {
                project.subscriptionModel = (try? AppConfig.loadFromKeychain())?.subscriptionImageModel ?? ""
            }
            Task { await loadSubscriptionModels(forceRefresh: false) }
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
    private func loadSubscriptionModels(forceRefresh: Bool) async {
        isLoadingSubscriptionModels = true
        subscriptionModelsError = nil
        defer { isLoadingSubscriptionModels = false }
        do {
            subscriptionModels = try await BackendModelCatalog.shared.models(
                capability: .image,
                forceRefresh: forceRefresh
            )
        } catch {
            subscriptionModelsError = error.localizedDescription
        }
    }
}
