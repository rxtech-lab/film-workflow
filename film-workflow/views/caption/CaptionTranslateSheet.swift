import SwiftUI

/// Choose a target language, an engine, and how much to re-do.
///
/// A sheet rather than a menu because three choices interact: Apple's engine
/// can only offer the languages it has packs for, the AI engine can offer any
/// language but costs tokens, and the scope decides whether a re-run is three
/// requests or nine hundred.
struct CaptionTranslateSheet: View {
    @Bindable var project: CaptionProject
    /// Captions the user had selected in the editor, so "Selected captions" can
    /// be offered when there are any.
    let selection: Set<UUID>
    let onStart: (CaptionTranslateChoice) -> Void

    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
        @Environment(\.openSettings) private var openSettings
    #endif
    @State private var settings = CaptionSettings.shared
    @State private var availability = CaptionTranslationAvailability.shared
    @State private var backendAvailability = AgentBackendAvailability.shared

    @State private var language: String = ""
    @State private var customLanguage: String = ""
    @State private var engine: CaptionTranslationEngineKind = .appleTranslation
    @State private var aiBackend: AgentBackend = .appleIntelligence
    @State private var aiConfig: AppConfig?
    @State private var scope: CaptionTranslationService.Scope = .missingOrStale
    @State private var isRedoingAll = false

    private var resolvedLanguage: String {
        let custom = customLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        return language == Self.customTag ? custom : language
    }

    /// Apple's engine can only translate into languages it has a pack for, so
    /// the picker is its supported list. The AI engine has no such limit, but
    /// offering a different list per engine would be more confusing than a
    /// "Other…" row that works for both.
    private var offeredLanguages: [String] {
        var codes = availability.supportedTargets
        // A language already translated must stay selectable even if the system
        // has since dropped its pack, or "Update" would vanish from the menu.
        for existing in project.translatedLanguages where !codes.contains(existing) {
            codes.append(existing)
        }
        return codes.filter { $0 != project.sourceLanguageCode }
    }

    /// Every backend that can translate — which, since translation batches, is
    /// all of them on macOS. Keep this picker aligned with the capability check
    /// used when the runner is built.
    private var translationBackends: [AgentBackend] {
        AgentBackend.supported.filter { $0.supports(.translation) }
    }

    private var canStart: Bool {
        guard !resolvedLanguage.isEmpty else { return false }
        guard engine == .aiBackend else { return true }
        return backendAvailability.isConfigured(aiBackend, config: aiConfig)
    }

    /// Engine and model of the last pass over the chosen language, e.g.
    /// "AI model · gpt-4o-mini". Empty when it has never been translated, or was
    /// translated before the model was recorded.
    private var previousProducer: String {
        guard !language.isEmpty, language != Self.customTag else { return "" }
        return project.activeVersion?.translation(language)?.producerDescription ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Language", selection: $language) {
                        Text("Choose…").tag("")
                        ForEach(offeredLanguages, id: \.self) { code in
                            Text(CaptionTranslationAvailability.displayName(code)).tag(code)
                        }
                        Divider()
                        Text("Other…").tag(Self.customTag)
                    }
                    if language == Self.customTag {
                        TextField("Language code", text: $customLanguage)
                            .textFieldStyle(.roundedBorder)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                    }
                } header: {
                    Text("Translate into")
                } footer: {
                    VStack(alignment: .leading, spacing: 2) {
                        if language == Self.customTag {
                            Text("A BCP-47 code, such as zh-Hans, es or ja.")
                        } else if !project.sourceLanguageCode.isEmpty {
                            Text("These captions are in \(CaptionTranslationAvailability.displayName(project.sourceLanguageCode)).")
                        }
                        // What ran last time, so re-running on a different model
                        // is a deliberate choice rather than a guess.
                        if !previousProducer.isEmpty {
                            Text("Last translated with \(previousProducer).")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Engine", selection: $engine) {
                        ForEach(CaptionTranslationEngineKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()

                    if engine == .aiBackend {
                        Picker("Provider", selection: $aiBackend) {
                            ForEach(translationBackends) { backend in
                                Text(backend.displayName).tag(backend)
                            }
                        }

                        if let reason = backendAvailability.unavailableReason(
                            aiBackend,
                            config: aiConfig
                        ) {
                            Label {
                                Text(reason)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                            }
                            .font(.caption)
                            .foregroundStyle(.orange)

                            if aiBackend == .openAICompatible {
                                Button("Open AI Provider settings") {
                                    openAIProviderSettings()
                                }
                                .font(.caption)
                            }
                        }
                    }
                } header: {
                    Text("Engine")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(engine.detail)
                        // Worth saying out loud: Apple's engine cannot be given
                        // a glossary, so its lines carry no {{term}} placeholder
                        // and won't follow a later change to a term's wording.
                        if engine == .appleTranslation, !project.usableTerms.isEmpty {
                            Text("""
                                Apple's engine can't be given the glossary, so these captions won't \
                                pick up later changes to a term's translation. Use an AI model if \
                                you want them to.
                                """)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section {
                    if !selection.isEmpty {
                        Toggle("Selected captions only (\(selection.count))", isOn: selectionBinding)
                    }
                    Toggle("Re-translate captions that already have one", isOn: $isRedoingAll)
                } header: {
                    Text("Scope")
                } footer: {
                    Text(scopeFooter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Translate Captions")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Translate") { start() }
                        .disabled(!canStart)
                }
            }
            .task {
                await availability.refreshIfNeeded()
                aiConfig = try? AppConfig.loadFromKeychain()
                backendAvailability.refresh()
                seed()
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }

    // MARK: - Scope

    /// The two toggles compose into one `Scope`: selection narrows *which*
    /// captions, "re-translate" widens *whether* an existing one is replaced.
    private var selectionBinding: Binding<Bool> {
        Binding(
            get: {
                if case .selection = scope { return true }
                return false
            },
            set: { scope = $0 ? .selection(selection) : .missingOrStale }
        )
    }

    private var scopeFooter: LocalizedStringKey {
        if isRedoingAll {
            return "Every caption in scope is translated again, including ones you edited by hand."
        }
        return "Only captions with no translation, or whose text changed since they were translated."
    }

    private var resolvedScope: CaptionTranslationService.Scope {
        if case .selection(let ids) = scope, !isRedoingAll { return .selection(ids) }
        if isRedoingAll { return .all }
        return .missingOrStale
    }

    // MARK: - Actions

    private func openAIProviderSettings() {
        AppNavigation.shared.settingsSection = .aiProvider
        #if os(macOS)
            openSettings()
        #else
            dismiss()
            AppNavigation.shared.tab = .Settings
        #endif
    }

    private func seed() {
        engine = settings.translationEngine
        aiBackend = settings.aiBackend
        guard language.isEmpty else { return }
        // Prefer a language this project already has, then a configured default,
        // so the common case — topping up an existing translation — is one tap.
        if let existing = project.translatedLanguages.first {
            language = existing
        } else if let preferred = settings.defaultTranslationLanguages.first(
            where: { offeredLanguages.contains($0) }
        ) {
            language = preferred
        }
    }

    private func start() {
        let code = resolvedLanguage
        guard canStart else { return }
        settings.translationEngine = engine
        if engine == .aiBackend {
            settings.aiBackend = aiBackend
        }
        onStart(
            CaptionTranslateChoice(
                languageCode: code,
                engine: engine,
                preferredBackend: engine == .aiBackend ? aiBackend : nil,
                scope: resolvedScope
            )
        )
        dismiss()
    }

    /// Sentinel tag for the "Other…" row. Not a valid BCP-47 code, so it can
    /// never collide with a real one.
    private static let customTag = "*custom*"
}

/// What the sheet decided, handed back to the editor to run.
struct CaptionTranslateChoice {
    var languageCode: String
    var engine: CaptionTranslationEngineKind
    /// The provider explicitly chosen for this run. `nil` lets non-sheet
    /// callers use the app-wide Caption AI default and its fallback behavior.
    var preferredBackend: AgentBackend? = nil
    var scope: CaptionTranslationService.Scope
}
