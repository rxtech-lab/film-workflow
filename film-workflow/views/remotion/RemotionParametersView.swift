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

    var body: some View {
        Form {
            basicSection
            promptSection
            imagesSection
            referenceImageSection
            musicSection
            generateSection
        }
        .formStyle(.grouped)
        .fileImporter(
            isPresented: $showImagePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            handleImageImport(result)
        }
        .fileImporter(
            isPresented: $showReferencePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleReferenceImport(result)
        }
        .fileImporter(
            isPresented: $showMusicPicker,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            handleMusicImport(result)
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
            Slider(value: $project.durationSeconds, in: 1...60, step: 0.5)

            ColorPicker("Theme Color", selection: themeColorBinding, supportsOpacity: false)
        }
    }

    private var promptSection: some View {
        Section {
            TextField("", text: $project.prompt, axis: .vertical)
                .lineLimit(3...10)
                .textFieldStyle(.roundedBorder)
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
                let source = try await RemotionCodeBuilder.seedWithLLM(project: bindable, config: config)
                bindable.compositionSource = source
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
        } catch {
            // ignore
        }
    }

    private func removeImage(at index: Int) {
        let path = project.imagePaths.remove(at: index)
        FileStorage.deleteFile(at: path)
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
