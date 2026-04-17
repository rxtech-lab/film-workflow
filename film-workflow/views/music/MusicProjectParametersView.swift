import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

struct MusicProjectParametersView: View {
    @Bindable var project: MusicProject
    @State private var selectedInstruments: Set<MusicInstrument> = []
    @State private var showImagePicker = false
    #if os(iOS)
    @State private var showImageSourceDialog = false
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    #endif

    var body: some View {
        Form {
            basicInfoSection
            generalPromptSection
            musicalParametersSection
            instrumentsSection
            referenceImagesSection
        }
        .formStyle(.grouped)
        .navigationTitle(project.name)
        .onAppear {
            selectedInstruments = project.instrumentEnums
        }
        .onChange(of: selectedInstruments) { _, newValue in
            project.instrumentEnums = newValue
        }
        .fileImporter(
            isPresented: $showImagePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            handleImageImport(result)
        }
        #if os(iOS)
        .confirmationDialog("Select Image Source", isPresented: $showImageSourceDialog, titleVisibility: .visible) {
            Button("Photo Library") {
                showPhotoPicker = true
            }
            Button("Files") {
                showImagePicker = true
            }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: max(1, 10 - project.referenceImagePaths.count),
            matching: .images
        )
        .onChange(of: selectedPhotoItems) { _, newItems in
            handlePhotoImport(newItems)
        }
        #endif
    }

    // MARK: - Sections

    private var basicInfoSection: some View {
        Section("Basic Info") {
            TextField("Project Name", text: $project.name)

            Picker("Input Mode", selection: $project.inputModeEnum) {
                ForEach(InputMode.allCases) { mode in
                    Text(mode.localizedName).tag(mode)
                }
            }
        }
    }

    private var generalPromptSection: some View {
        Section {
            TextField("", text: $project.generalPrompt, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.leading)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            Text("Overall Vibe")
        } footer: {
            Text("Sets the overall feeling or atmosphere of the music. Included at the top of the generated prompt.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var musicalParametersSection: some View {
        Section("Musical Parameters") {
            Picker("Genre", selection: $project.genreEnum) {
                ForEach(MusicGenre.allCases) { genre in
                    Text(genre.localizedName).tag(genre)
                }
            }

            Picker("Mood", selection: $project.moodEnum) {
                ForEach(Mood.allCases) { mood in
                    Text(mood.localizedName).tag(mood)
                }
            }

            Picker("BPM", selection: $project.bpmPreset) {
                ForEach(BPMPreset.allCases) { bpm in
                    Text(bpm.displayName).tag(bpm)
                }
            }

            Picker("Key / Scale", selection: $project.keyScaleEnum) {
                ForEach(KeyScale.allCases) { key in
                    Text(key.localizedName).tag(key)
                }
            }

            Picker("Duration", selection: $project.musicLengthEnum) {
                ForEach(MusicLength.allCases) { length in
                    Text(verbatim: length.rawValue).tag(length)
                }
            }

            Picker("Type", selection: $project.generationTypeEnum) {
                ForEach(GenerationType.allCases) { type in
                    Text(type.localizedName).tag(type)
                }
            }

            if project.generationTypeEnum == .withLyrics {
                Picker("Lyrics Language", selection: $project.lyricsLanguageEnum) {
                    ForEach(LyricsLanguage.allCases) { lang in
                        Text(lang.localizedName).tag(lang)
                    }
                }
            }
        }
    }

    private var instrumentsSection: some View {
        Section("Instruments") {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 150), alignment: .leading)
            ], alignment: .leading, spacing: 8) {
                ForEach(MusicInstrument.allCases) { instrument in
                    Toggle(instrument.localizedName, isOn: Binding(
                        get: { selectedInstruments.contains(instrument) },
                        set: { isOn in
                            if isOn {
                                selectedInstruments.insert(instrument)
                            } else {
                                selectedInstruments.remove(instrument)
                            }
                        }
                    ))
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #else
                    .toggleStyle(.switch)
                    .padding(.vertical, 6)
                    #endif
                }
            }
        }
    }

    private var referenceImagesSection: some View {
        Section("Reference Images") {
            if !project.referenceImagePaths.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(project.referenceImagePaths.enumerated()), id: \.offset) { index, path in
                            let url = FileStorage.absoluteURL(for: path)
                            ZStack(alignment: .topTrailing) {
                                if let image = Image(contentsOfFile: url) {
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
                                .offset(x: 4, y: -4)
                            }
                        }
                    }
                }
                .frame(height: 110)
            }

            Button {
                #if os(iOS)
                showImageSourceDialog = true
                #else
                showImagePicker = true
                #endif
            } label: {
                Label("Add Images", systemImage: "photo.on.rectangle.angled")
            }
            .disabled(project.referenceImagePaths.count >= 10)

            if project.referenceImagePaths.count >= 10 {
                Text("Maximum 10 images reached.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func handleImageImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            let remaining = 10 - project.referenceImagePaths.count
            for url in urls.prefix(remaining) {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                if let relativePath = try? FileStorage.copyImage(from: url) {
                    project.referenceImagePaths.append(relativePath)
                }
            }
        case .failure:
            break
        }
    }

    #if os(iOS)
    private func handlePhotoImport(_ items: [PhotosPickerItem]) {
        let remaining = 10 - project.referenceImagePaths.count
        guard remaining > 0 else {
            selectedPhotoItems = []
            return
        }
        let itemsToImport = Array(items.prefix(remaining))
        Task {
            for item in itemsToImport {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let ext = preferredImageExtension(from: item) ?? "jpg"
                if let relativePath = try? FileStorage.saveImage(data, fileExtension: ext) {
                    await MainActor.run {
                        project.referenceImagePaths.append(relativePath)
                    }
                }
            }
            await MainActor.run {
                selectedPhotoItems = []
            }
        }
    }

    private func preferredImageExtension(from item: PhotosPickerItem) -> String? {
        item.supportedContentTypes
            .first(where: { $0.conforms(to: .image) })?
            .preferredFilenameExtension
    }
    #endif

    private func removeImage(at index: Int) {
        let path = project.referenceImagePaths.remove(at: index)
        FileStorage.deleteFile(at: path)
    }
}
