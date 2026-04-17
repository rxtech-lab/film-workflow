import SwiftUI

struct NarrativeProjectParametersView: View {
    @Bindable var project: NarrativeProject
    @State private var azureStore = AzureVoiceStore.shared

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                basicInfoSection
                if project.providerEnum != .azure {
                    sceneSection
                }
                speakersSection
            }
            .formStyle(.grouped)
            .navigationTitle(project.name)
            .task {
                if project.providerEnum == .azure {
                    await azureStore.fetchIfNeeded()
                }
            }
            .onChange(of: project.providerEnum) { oldValue, newValue in
                guard oldValue != newValue else { return }
                swapVoices(from: oldValue, to: newValue)
                if newValue == .azure {
                    Task { await azureStore.fetchIfNeeded() }
                }
            }
            .onChange(of: project.speakers.count) { oldValue, newValue in
                guard newValue > oldValue, let last = project.speakers.last else { return }
                DispatchQueue.main.async {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var basicInfoSection: some View {
        Section("Basic Info") {
            TextField("Project Name", text: $project.name)

            Picker("Provider", selection: $project.providerEnum) {
                ForEach(NarrativeProvider.allCases) { provider in
                    Text(verbatim: provider.displayName).tag(provider)
                }
            }

            if project.providerEnum == .azure {
                Picker("Output Format", selection: $project.azureOutputFormatEnum) {
                    ForEach(AzureAudioFormat.allCases) { format in
                        Text(verbatim: format.displayName).tag(format)
                    }
                }
            }

            if !project.providerEnum.isSupported {
                Text("\(project.providerEnum.displayName) TTS is not supported yet.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var sceneSection: some View {
        Section("Scene") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Scene Description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $project.sceneDescription)
                    .font(.body)
                    .frame(minHeight: 60)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.platformControlBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $project.notes)
                    .font(.body)
                    .frame(minHeight: 60)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.platformControlBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Context")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $project.context)
                    .font(.body)
                    .frame(minHeight: 60)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.platformControlBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var speakersSection: some View {
        Section {
            ForEach($project.speakers) { $speaker in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Speaker name", text: $speaker.displayName)
                            .textFieldStyle(.roundedBorder)

                        Button(role: .destructive) {
                            removeSpeaker(id: speaker.id)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .disabled(project.speakers.count <= 1)
                    }

                    voicePicker(for: $speaker)
                }
                .padding(.vertical, 4)
                .id(speaker.id)
            }

            if canAddSpeaker {
                Button {
                    addSpeaker()
                } label: {
                    Label("Add Speaker", systemImage: "plus")
                }
            }
        } header: {
            Text("Speakers")
        } footer: {
            speakerFooter
        }
    }

    @ViewBuilder
    private func voicePicker(for speaker: Binding<NarrativeSpeaker>) -> some View {
        switch project.providerEnum {
        case .gemini:
            HStack {
                Picker("Voice", selection: speaker.voiceEnum) {
                    ForEach(GeminiVoice.allCases) { voice in
                        Text(voice.localizedDisplayName).tag(voice)
                    }
                }

                GeminiVoicePreviewButton(voice: speaker.wrappedValue.voiceEnum)
            }
        case .azure:
            azureVoicePicker(for: speaker)
        }
    }

    @ViewBuilder
    private func azureVoicePicker(for speaker: Binding<NarrativeSpeaker>) -> some View {
        if azureStore.isLoading && azureStore.voices.isEmpty {
            HStack {
                Text("Voice")
                Spacer()
                ProgressView().controlSize(.small)
                Text("Loading voices…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if azureStore.voices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let err = azureStore.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("No voices loaded. Configure Azure in Settings and retry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Retry") {
                    Task { await azureStore.refresh() }
                }
                .buttonStyle(.bordered)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Voice", selection: Binding(
                        get: { speaker.wrappedValue.voice },
                        set: { newValue in
                            DispatchQueue.main.async {
                                speaker.wrappedValue.voice = newValue
                            }
                        }
                    )) {
                        if azureStore.voice(forShortName: speaker.wrappedValue.voice) == nil {
                            Text(speaker.wrappedValue.voice.isEmpty ? "Select a voice…" : speaker.wrappedValue.voice)
                                .tag(speaker.wrappedValue.voice)
                        }
                        ForEach(azureStore.voicesByLocale) { group in
                            Section(group.localeName) {
                                ForEach(group.items) { item in
                                    Text(item.displayText).tag(item.shortName)
                                }
                            }
                        }
                    }

                    AzureVoicePreviewButton(voice: azureStore.voice(forShortName: speaker.wrappedValue.voice))
                }

                azureVoiceParameters(for: speaker)
            }
        }
    }

    @ViewBuilder
    private func azureVoiceParameters(for speaker: Binding<NarrativeSpeaker>) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                prosodyField(
                    label: "Pitch",
                    value: speaker.azurePitch,
                    placeholder: "e.g. medium, +10%, -2st",
                    suggestions: AzureProsodyPreset.pitchSuggestions
                )
                prosodyField(
                    label: "Rate",
                    value: speaker.azureRate,
                    placeholder: "e.g. medium, 0.9, +10%",
                    suggestions: AzureProsodyPreset.rateSuggestions
                )
                prosodyField(
                    label: "Volume",
                    value: speaker.azureVolume,
                    placeholder: "e.g. medium, +6dB, loud",
                    suggestions: AzureProsodyPreset.volumeSuggestions
                )

                HStack {
                    Text("Role").frame(width: 70, alignment: .leading)
                    Picker("", selection: speaker.azureRoleEnum) {
                        ForEach(AzureRole.allCases) { role in
                            Text(role.localizedName).tag(role)
                        }
                    }
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Style degree")
                        Spacer()
                        Text(String(format: "%.2f", speaker.wrappedValue.azureStyleDegree))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: speaker.azureStyleDegree, in: 0.01...2.0)
                }

                HStack {
                    Spacer()
                    Button("Reset parameters") {
                        speaker.wrappedValue.azurePitch = ""
                        speaker.wrappedValue.azureRate = ""
                        speaker.wrappedValue.azureVolume = ""
                        speaker.wrappedValue.azureRole = ""
                        speaker.wrappedValue.azureStyleDegree = 1.0
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Text("Voice parameters")
                    .font(.subheadline)
                if azureParametersSummary(for: speaker.wrappedValue).isEmpty == false {
                    Text(azureParametersSummary(for: speaker.wrappedValue))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func prosodyField(
        label: String,
        value: Binding<String>,
        placeholder: String,
        suggestions: [String]
    ) -> some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 70, alignment: .leading)
            TextField(placeholder, text: value)
                .textFieldStyle(.roundedBorder)
            Menu {
                ForEach(suggestions, id: \.self) { preset in
                    Button(preset.isEmpty ? "(Default)" : preset) {
                        value.wrappedValue = preset
                    }
                }
            } label: {
                Image(systemName: "chevron.down.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func azureParametersSummary(for speaker: NarrativeSpeaker) -> String {
        var parts: [String] = []
        if !speaker.azurePitch.isEmpty { parts.append("pitch \(speaker.azurePitch)") }
        if !speaker.azureRate.isEmpty { parts.append("rate \(speaker.azureRate)") }
        if !speaker.azureVolume.isEmpty { parts.append("vol \(speaker.azureVolume)") }
        if !speaker.azureRole.isEmpty { parts.append("role \(speaker.azureRole)") }
        if abs(speaker.azureStyleDegree - 1.0) > 0.0001 {
            parts.append(String(format: "deg %.2f", speaker.azureStyleDegree))
        }
        return parts.joined(separator: " · ")
    }

    private var speakerFooter: some View {
        Group {
            switch project.providerEnum {
            case .gemini:
                Text("Gemini supports up to 2 speakers per narration.")
            case .azure:
                Text("Azure supports multiple speakers per narration.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var canAddSpeaker: Bool {
        if let cap = project.providerEnum.maxSpeakers {
            return project.speakers.count < cap
        }
        return true
    }

    private func addSpeaker() {
        guard canAddSpeaker else { return }
        let nextIndex = project.speakers.count + 1
        let voice: String
        switch project.providerEnum {
        case .gemini:
            let defaultVoice: GeminiVoice = project.speakers.contains(where: { $0.voiceEnum == .achernar }) ? .algenib : .achernar
            voice = defaultVoice.rawValue
        case .azure:
            let used = Set(project.speakers.map { $0.voice })
            if let firstUnused = azureStore.voices.first(where: { !used.contains($0.shortName) }) {
                voice = firstUnused.shortName
            } else if let any = azureStore.voices.first {
                voice = any.shortName
            } else {
                voice = ""
            }
        }

        let speaker = NarrativeSpeaker(
            displayName: "Speaker \(nextIndex)",
            voice: voice
        )
        project.speakers.append(speaker)
        project.updatedAt = Date()
    }

    private func removeSpeaker(id: UUID) {
        guard project.speakers.count > 1 else { return }
        project.speakers.removeAll { $0.id == id }
        project.paragraphs.removeAll { $0.speakerId == id }
        project.updatedAt = Date()
    }

    private func swapVoices(from oldProvider: NarrativeProvider, to newProvider: NarrativeProvider) {
        for index in project.speakers.indices {
            let current = project.speakers[index].voice

            switch oldProvider {
            case .gemini: project.speakers[index].geminiVoice = current
            case .azure: project.speakers[index].azureVoice = current
            }

            let stored: String
            switch newProvider {
            case .gemini: stored = project.speakers[index].geminiVoice
            case .azure: stored = project.speakers[index].azureVoice
            }

            if !stored.isEmpty {
                project.speakers[index].voice = stored
            } else {
                project.speakers[index].voice = defaultVoice(for: newProvider, at: index)
            }
        }

        for index in project.paragraphs.indices {
            project.paragraphs[index].emotion = ""
        }

        project.updatedAt = Date()
    }

    private func defaultVoice(for provider: NarrativeProvider, at index: Int) -> String {
        switch provider {
        case .gemini:
            let used = Set(
                project.speakers
                    .prefix(index)
                    .compactMap { GeminiVoice(rawValue: $0.voice) }
            )
            return (GeminiVoice.allCases.first { !used.contains($0) } ?? .achernar).rawValue
        case .azure:
            let used = Set(project.speakers.prefix(index).map { $0.voice })
            if let firstUnused = azureStore.voices.first(where: { !used.contains($0.shortName) }) {
                return firstUnused.shortName
            }
            return azureStore.voices.first?.shortName ?? ""
        }
    }
}
