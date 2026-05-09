#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

struct RemotionParametersView: View {
    private let maxImages = 10

    @Bindable var project: RemotionProject
    @Binding var statusMessage: String?
    @Binding var isSeeding: Bool

    @State private var showImagePicker = false
    @State private var showReferencePicker = false
    @State private var showMusicPicker = false
    @State private var generatedImages: [URL] = []

    var body: some View {
        Form {
            basicSection
            promptSection
            imagesSection
            referenceImageSection
            generatedImagesSection
            musicSection
            generateSection
        }
        .formStyle(.grouped)
        .onChange(of: project.compositionWidth) { _, _ in syncCompositionConstants() }
        .onChange(of: project.compositionHeight) { _, _ in syncCompositionConstants() }
        .onChange(of: project.compositionFps) { _, _ in syncCompositionConstants() }
        .onChange(of: project.durationSeconds) { _, _ in syncCompositionConstants() }
        .task { refreshGeneratedImages() }
        .onReceive(NotificationCenter.default.publisher(for: .remotionGeneratedImageWritten)) { note in
            if let id = note.object as? UUID, id == project.id {
                refreshGeneratedImages()
            }
        }
    }

    // MARK: - Sections

    private var basicSection: some View {
        Section("Basic") {
            TextField("Project Name", text: $project.name)

            VStack(alignment: .leading, spacing: 4) {
                Text("Text Overlay")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", text: $project.text, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("Duration")
                Spacer()
                Text(String(format: "%.1fs", project.durationSeconds))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { project.durationSeconds },
                    set: { project.durationSeconds = (($0 * 2).rounded() / 2) }
                ),
                in: 1...60
            )

            ColorPicker("Theme Color", selection: themeColorBinding, supportsOpacity: false)

            HStack {
                Text("Resolution")
                Spacer()
                Picker("", selection: resolutionBinding) {
                    ForEach(ExportResolution.allCases) { res in
                        Text(res.label).tag(res)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
            }

            HStack {
                Text("Frame Rate")
                Spacer()
                Picker("", selection: frameRateBinding) {
                    ForEach(ExportFrameRate.allCases) { fps in
                        Text(fps.label).tag(fps)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }
        }
    }

    private var promptSection: some View {
        Section {
            TextEditor(text: $project.prompt)
                .font(.body)
                .multilineTextAlignment(.leading)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 72, maxHeight: 220)
                .padding(6)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.35))
                )
        } header: {
            Text("Prompt")
        } footer: {
            Text("Tell the model what kind of video to build (style, motion, mood, structure). Used both for the initial generation and as context for follow-up chat edits.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var imagesSection: some View {
        Section("Images") {
            if !project.imagePaths.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(project.imagePaths.enumerated()), id: \.offset) { index, path in
                            ZStack(alignment: .topTrailing) {
                                if let image = Image(contentsOfFile: FileStorage.absoluteURL(for: path)) {
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 100, height: 100)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                Button {
                                    removeImage(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.white, .red)
                                }
                                .buttonStyle(.borderless)
                                .padding(4)
                            }
                        }
                    }
                }
                .frame(height: 110)
            }

            Button {
                showImagePicker = true
            } label: {
                Label("Add Images", systemImage: "photo.on.rectangle.angled")
            }
            .disabled(project.imagePaths.count >= maxImages)
            .fileImporter(
                isPresented: $showImagePicker,
                allowedContentTypes: [.image],
                allowsMultipleSelection: true
            ) { result in
                handleImageImport(result)
            }

            if project.imagePaths.count >= maxImages {
                Text("Maximum \(maxImages) images.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var referenceImageSection: some View {
        Section("Reference Image") {
            HStack {
                if let path = project.referenceImagePath,
                   let image = Image(contentsOfFile: FileStorage.absoluteURL(for: path)) {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 80, height: 80)
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Button("Choose…") { showReferencePicker = true }
                        .fileImporter(
                            isPresented: $showReferencePicker,
                            allowedContentTypes: [.image],
                            allowsMultipleSelection: false
                        ) { result in
                            handleReferenceImport(result)
                        }
                    if project.referenceImagePath != nil {
                        Button("Remove", role: .destructive) {
                            if let p = project.referenceImagePath {
                                FileStorage.deleteFile(at: p)
                            }
                            project.referenceImagePath = nil
                        }
                    }
                }
            }

            Text("Used as a visual style guide passed to the LLM during chat edits.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var generatedImagesSection: some View {
        Section {
            if generatedImages.isEmpty {
                Text("Images you generate via the chat appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(generatedImages, id: \.self) { url in
                            ZStack(alignment: .topTrailing) {
                                if let image = Image(contentsOfFile: url) {
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 100, height: 100)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.secondary.opacity(0.15))
                                        .frame(width: 100, height: 100)
                                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                                }
                                Button {
                                    deleteGeneratedImage(at: url)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.white, .red)
                                }
                                .buttonStyle(.borderless)
                                .padding(4)
                            }
                            .help(url.lastPathComponent)
                        }
                    }
                }
                .frame(height: 110)
            }
        } header: {
            HStack {
                Text("Generated Images")
                Spacer()
                Button {
                    refreshGeneratedImages()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
        } footer: {
            Text("Saved under public/generated/. Reference them in the composition via staticFile(\"generated/<name>\").")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var musicSection: some View {
        Section("Music (optional)") {
            HStack {
                if let m = project.musicFilePath {
                    Image(systemName: "waveform")
                        .foregroundStyle(Color.accentColor)
                    Text(URL(fileURLWithPath: m).lastPathComponent)
                        .lineLimit(1)
                } else {
                    Text("No music attached")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose…") { showMusicPicker = true }
                    .fileImporter(
                        isPresented: $showMusicPicker,
                        allowedContentTypes: [.audio],
                        allowsMultipleSelection: false
                    ) { result in
                        handleMusicImport(result)
                    }
                if project.musicFilePath != nil {
                    Button("Remove", role: .destructive) {
                        if let m = project.musicFilePath {
                            FileStorage.deleteFile(at: m)
                        }
                        project.musicFilePath = nil
                    }
                }
            }
        }
    }

    private var generateSection: some View {
        Section {
            Button {
                seed()
            } label: {
                HStack {
                    if isSeeding { ProgressView().controlSize(.small) }
                    Text(isSeeding ? "Generating…" : "Generate Initial Composition")
                }
            }
            .disabled(isSeeding)

            if let status = statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            Text("Builds a starting Composition.tsx from these inputs and launches Studio. Use the chat below to refine.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bindings

    private var themeColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: project.themeColorHex) ?? .black },
            set: { project.themeColorHex = $0.hexString() ?? project.themeColorHex }
        )
    }

    private var resolutionBinding: Binding<ExportResolution> {
        Binding(
            get: {
                ExportResolution.allCases.first(where: {
                    $0.size.width == project.compositionWidth &&
                    $0.size.height == project.compositionHeight
                }) ?? .p1080
            },
            set: { res in
                project.compositionWidth = res.size.width
                project.compositionHeight = res.size.height
            }
        )
    }

    private var frameRateBinding: Binding<ExportFrameRate> {
        Binding(
            get: { ExportFrameRate(rawValue: project.compositionFps) ?? .fps30 },
            set: { project.compositionFps = $0.rawValue }
        )
    }

    // MARK: - Actions

    private func seed() {
        let config: AppConfig
        do {
            config = try AppConfig.loadFromKeychain()
        } catch {
            statusMessage = "Could not load credentials: \(error.localizedDescription)"
            return
        }
        guard !config.openAIEndpoint.isEmpty,
              !config.openAIKey.isEmpty,
              !config.openAIModel.isEmpty else {
            statusMessage = "Set OpenAI endpoint, key, and model in Settings before generating."
            return
        }

        isSeeding = true
        statusMessage = "Generating composition with the model…"
        let projectId = project.id
        let bindable = project
        Task {
            do {
                let raw = try await RemotionCodeBuilder.seedWithLLM(project: bindable, config: config)
                // Force the composition's constants to match the project settings even if the
                // model hardcoded different values.
                let normalized = RemotionCodeBuilder.patchProjectConstants(in: raw, project: bindable)
                if normalized != raw {
                    try? RemotionCodeBuilder.writeComposition(project: bindable, source: normalized)
                }
                bindable.compositionSource = normalized
                bindable.updatedAt = Date()
                statusMessage = "Starting Remotion Studio…"
                try await RemotionRuntime.shared.start(projectId: projectId)
                statusMessage = "Studio running. Refine via chat below."
            } catch {
                statusMessage = error.localizedDescription
            }
            isSeeding = false
        }
    }

    private func handleImageImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            let remaining = maxImages - project.imagePaths.count
            for url in urls.prefix(remaining) {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                if let path = try? FileStorage.copyImage(from: url) {
                    project.imagePaths.append(path)
                }
            }
            syncAssetsToPublic()
        case .failure:
            break
        }
    }

    private func handleReferenceImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        if let oldPath = project.referenceImagePath {
            FileStorage.deleteFile(at: oldPath)
        }
        if let path = try? FileStorage.copyImage(from: url) {
            project.referenceImagePath = path
        }
        syncAssetsToPublic()
    }

    private func handleMusicImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
            let filename = UUID().uuidString + "." + ext
            let dest = FileStorage.imagesDir.appendingPathComponent(filename)
            try data.write(to: dest)
            if let oldPath = project.musicFilePath {
                FileStorage.deleteFile(at: oldPath)
            }
            project.musicFilePath = "images/" + filename
            syncAssetsToPublic()
        } catch {
            // ignore
        }
    }

    private func syncAssetsToPublic() {
        _ = try? RemotionCodeBuilder.prepareAssets(project: project)
    }

    private func syncCompositionConstants() {
        let current = project.compositionSource
        guard !current.isEmpty else { return }
        let patched = RemotionCodeBuilder.patchProjectConstants(in: current, project: project)
        guard patched != current else { return }
        project.compositionSource = patched
        project.updatedAt = Date()
        try? RemotionCodeBuilder.writeComposition(project: project, source: patched)
    }

    private func removeImage(at index: Int) {
        let path = project.imagePaths.remove(at: index)
        FileStorage.deleteFile(at: path)
    }

    private func generatedDir() -> URL {
        FileStorage.remotionProjectDir(id: project.id)
            .appendingPathComponent("public", isDirectory: true)
            .appendingPathComponent("generated", isDirectory: true)
    }

    private func refreshGeneratedImages() {
        let dir = generatedDir()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            generatedImages = []
            return
        }
        generatedImages = entries
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
    }

    private func deleteGeneratedImage(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        refreshGeneratedImages()
    }
}

// MARK: - Color hex helpers

extension Color {
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let value = UInt32(h, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    func hexString() -> String? {
        let nsColor = NSColor(self).usingColorSpace(.sRGB)
        guard let c = nsColor else { return nil }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
#endif
