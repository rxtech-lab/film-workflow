import SwiftUI
import UniformTypeIdentifiers

struct VideoGenProjectParametersView: View {
    @Bindable var project: VideoGenProject

    @State private var veoModels: [GoogleModelInfo] = []
    @State private var isLoadingModels = false
    @State private var modelsError: String?

    @State private var showFirstFramePicker = false
    @State private var showLastFramePicker = false
    @State private var showReferencePicker = false

    private var family: VeoModelFamily { project.veoFamily }

    /// Durations left after the model, resolution and reference-image
    /// constraints have all had their say.
    private var availableDurations: [VideoDuration] {
        family.durations(
            resolution: project.googleResolutionEnum,
            usingReferenceImages: !project.googleReferenceImagePaths.isEmpty
        )
    }

    var body: some View {
        Form {
            if VideoProvider.allCases.count > 1 {
                Section {
                    Picker("Provider", selection: Binding(
                        get: { project.providerEnum },
                        set: { project.providerEnum = $0; project.updatedAt = Date() }
                    )) {
                        ForEach(VideoProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Provider")
                }
            }

            Section {
                TextEditor(text: $project.prompt)
                    .frame(minHeight: 80)
                    .font(.body)
            } header: {
                Text("Prompt")
            }

            Section {
                TextEditor(text: $project.negativePrompt)
                    .frame(minHeight: 44)
                    .font(.body)
            } header: {
                Text("Negative Prompt")
            } footer: {
                Text("What to keep out of the shot. Optional.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            modelSection
            parametersSection
            framesSection

            if family.supportsReferenceImages {
                referenceImagesSection
            }
        }
        .formStyle(.grouped)
        // Attached to the Form rather than to each button so a section being
        // hidden by a capability check never tears down a presented picker.
        .fileImporter(
            isPresented: $showFirstFramePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { handleFirstFrame($0) }
        .fileImporter(
            isPresented: $showLastFramePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { handleLastFrame($0) }
        .fileImporter(
            isPresented: $showReferencePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { handleReferenceImages($0) }
        .onAppear {
            Task { await loadVeoModels(forceRefresh: false) }
        }
        .onChange(of: project.googleModel) { _, _ in
            VeoModelFamily.clamp(project)
            project.updatedAt = Date()
        }
        .onChange(of: project.googleResolution) { _, _ in
            VeoModelFamily.clamp(project)
            project.updatedAt = Date()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var modelSection: some View {
        Section {
            HStack {
                Picker("Model", selection: $project.googleModel) {
                    if project.googleModel.isEmpty {
                        Text("Select a model").tag("")
                    } else if !veoModels.contains(where: { $0.id == project.googleModel }) {
                        Text(project.googleModel).tag(project.googleModel)
                    }
                    ForEach(veoModels) { model in
                        Text(model.id).tag(model.id)
                    }
                }

                Button {
                    Task { await loadVeoModels(forceRefresh: true) }
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

    @ViewBuilder
    private var parametersSection: some View {
        Section {
            Picker("Aspect Ratio", selection: Binding(
                get: { project.googleAspectRatioEnum },
                set: { project.googleAspectRatioEnum = $0; project.updatedAt = Date() }
            )) {
                ForEach(VideoAspectRatio.allCases) { value in
                    Text(value.displayName).tag(value)
                }
            }

            Picker("Resolution", selection: Binding(
                get: { project.googleResolutionEnum },
                set: { project.googleResolutionEnum = $0; project.updatedAt = Date() }
            )) {
                ForEach(family.resolutions) { value in
                    Text(value.displayName).tag(value)
                }
            }

            Picker("Duration", selection: Binding(
                get: { project.googleDurationEnum },
                set: { project.googleDurationEnum = $0; project.updatedAt = Date() }
            )) {
                ForEach(availableDurations) { value in
                    Text(value.displayName).tag(value)
                }
            }
            .disabled(availableDurations.count <= 1)

            Picker("People", selection: Binding(
                get: { project.googlePersonGenerationEnum },
                set: { project.googlePersonGenerationEnum = $0; project.updatedAt = Date() }
            )) {
                ForEach(VideoPersonGeneration.allCases) { value in
                    Text(value.displayName).tag(value)
                }
            }

            if family.supportsAudio {
                Toggle("Generate audio", isOn: $project.googleGenerateAudio)
            }

            if family.maxVideos > 1 {
                Stepper(
                    "Clips: \(project.googleNumberOfVideos)",
                    value: $project.googleNumberOfVideos,
                    in: 1...family.maxVideos
                )
            }

            if family.supportsSeed {
                Toggle("Use a fixed seed", isOn: $project.useSeed)
                if project.useSeed {
                    HStack {
                        Text("Seed")
                        Spacer()
                        TextField("Seed", value: $project.seed, format: .number)
                            #if os(macOS)
                            .textFieldStyle(.roundedBorder)
                            #else
                            .keyboardType(.numberPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                    }
                }
            }
        } header: {
            Text("Video Parameters")
        } footer: {
            Text(constraintFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var constraintFooter: LocalizedStringKey {
        if !project.googleReferenceImagePaths.isEmpty {
            return "Reference images render 8-second clips only."
        }
        if project.googleResolutionEnum.requiresEightSeconds {
            return "1080p and 4K render 8-second clips only."
        }
        return "Options follow what the selected model supports."
    }

    @ViewBuilder
    private var framesSection: some View {
        Section {
            framePicker(
                title: "First frame",
                path: project.googleFirstFrameImagePath,
                showPicker: $showFirstFramePicker,
                onRemove: {
                    project.googleFirstFrameImagePath = nil
                    project.updatedAt = Date()
                }
            )

            framePicker(
                title: "Last frame",
                path: project.googleLastFrameImagePath,
                showPicker: $showLastFramePicker,
                onRemove: {
                    project.googleLastFrameImagePath = nil
                    project.updatedAt = Date()
                }
            )
        } header: {
            Text("Frames")
        } footer: {
            Text("Optional. A first frame animates that image; adding a last frame makes the model interpolate between the two.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func framePicker(
        title: LocalizedStringKey,
        path: String?,
        showPicker: Binding<Bool>,
        onRemove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            thumbnail(path: path)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Button("Choose…") { showPicker.wrappedValue = true }
                    .buttonStyle(.borderless)
            }

            Spacer()

            if path != nil {
                Button("Remove", role: .destructive, action: onRemove)
                    .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private func thumbnail(path: String?) -> some View {
        if let path, let image = Image(contentsOfFile: FileStorage.absoluteURL(for: path)) {
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 64, height: 64)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }

    @ViewBuilder
    private var referenceImagesSection: some View {
        Section {
            if project.googleReferenceImagePaths.isEmpty {
                Text("No reference images.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(project.googleReferenceImagePaths, id: \.self) { path in
                            thumbnail(path: path)
                                .contextMenu {
                                    Button("Remove", role: .destructive) {
                                        removeReferenceImage(path)
                                    }
                                }
                        }
                    }
                }
            }

            Button {
                showReferencePicker = true
            } label: {
                Label("Add Reference Images", systemImage: "photo.on.rectangle.angled")
            }
        } header: {
            Text("Reference Images")
        } footer: {
            Text("Keeps characters or objects consistent across shots. Describe the scene in the prompt — Veo has no token syntax for referring to them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Import handlers

    private func handleFirstFrame(_ result: Result<[URL], Error>) {
        importSingle(result) { path in
            if let old = project.googleFirstFrameImagePath { FileStorage.deleteFile(at: old) }
            project.googleFirstFrameImagePath = path
        }
    }

    private func handleLastFrame(_ result: Result<[URL], Error>) {
        importSingle(result) { path in
            if let old = project.googleLastFrameImagePath { FileStorage.deleteFile(at: old) }
            project.googleLastFrameImagePath = path
        }
    }

    private func importSingle(_ result: Result<[URL], Error>, apply: (String) -> Void) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let path = try? FileStorage.copyImage(from: url) else { return }
        apply(path)
        project.updatedAt = Date()
    }

    private func handleReferenceImages(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            if let path = try? FileStorage.copyImage(from: url) {
                project.googleReferenceImagePaths.append(path)
            }
        }
        // Reference images force an 8-second clip.
        VeoModelFamily.clamp(project)
        project.updatedAt = Date()
    }

    private func removeReferenceImage(_ path: String) {
        FileStorage.deleteFile(at: path)
        project.googleReferenceImagePaths.removeAll { $0 == path }
        VeoModelFamily.clamp(project)
        project.updatedAt = Date()
    }

    @MainActor
    private func loadVeoModels(forceRefresh: Bool) async {
        guard let config = try? AppConfig.loadFromKeychain(),
              !config.googleAIKey.isEmpty else {
            modelsError = "Configure the Google AI API key in Settings."
            return
        }
        isLoadingModels = true
        modelsError = nil
        defer { isLoadingModels = false }
        do {
            veoModels = try await GoogleModelsClient.shared.veoModels(
                apiKey: config.googleAIKey,
                forceRefresh: forceRefresh
            )
        } catch {
            modelsError = error.localizedDescription
        }
    }
}
