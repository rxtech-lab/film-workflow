import SwiftData
import SwiftUI

/// The inspector's Translation tab: what each language's coverage looks like,
/// a way to top one up or start a new one, and which translation the editor
/// draws under each caption.
///
/// The caption editor's toolbar offers the same run, but only while that window
/// is open. This puts it beside the rest of the footage's settings, where the
/// work is actually happening — cutting a sequence and noticing the Spanish is
/// four captions behind.
struct CaptionTranslationTab: View {
    @Bindable var project: CaptionProject
    @Environment(\.modelContext) private var modelContext

    @State private var settings = CaptionSettings.shared
    @State private var translator = CaptionTranslationController()
    @State private var showTranslateSheet = false
    @State private var removingTranslation: String?

    private var languages: [String] { project.translatedLanguages }

    var body: some View {
        Form {
            if project.activeSegmentCount == 0 {
                Section {
                    Text("Transcribe these captions first — there is nothing to translate yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                languagesSection
                displaySection
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showTranslateSheet) {
            // No selection to narrow by: the editor's caption list owns that,
            // and the inspector always works on the whole transcript.
            CaptionTranslateSheet(project: project, selection: []) { choice in
                translator.start(choice, project: project, context: modelContext)
            }
        }
        .captionTranslation(translator, project: project)
        .confirmationDialog(
            "Remove this translation?",
            isPresented: Binding(
                get: { removingTranslation != nil },
                set: { if !$0 { removingTranslation = nil } }
            ),
            titleVisibility: .visible,
            presenting: removingTranslation
        ) { code in
            Button("Remove", role: .destructive) { remove(code) }
            Button("Cancel", role: .cancel) { removingTranslation = nil }
        } message: { code in
            Text("Every \(CaptionTranslationAvailability.displayName(code)) translation in this version will be deleted, including any you edited.")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var languagesSection: some View {
        Section {
            if languages.isEmpty {
                Text("Not translated yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(languages, id: \.self) { code in
                    languageRow(code)
                }
            }
            Button("Translate…") {
                FilmFeatureTip.captionTranslate.didPerform()
                showTranslateSheet = true
            }
                .disabled(translator.isRunning)
                .filmTip(.captionTranslate, when: !translator.isRunning && !showTranslateSheet)
        } header: {
            Text("Languages")
        } footer: {
            Text(sourceFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// One language: how far along it is, what last wrote it, and the two
    /// things you can do to it.
    private func languageRow(_ code: String) -> some View {
        let counts = CaptionTranslationService.counts(for: code, in: project)
        let outstanding = counts.total - counts.translated + counts.stale
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(CaptionTranslationAvailability.displayName(code))
                    .font(.callout.weight(.medium))
                Spacer()
                Text("\(counts.translated) of \(counts.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if counts.stale > 0 {
                // Stale is the one that needs saying: the caption reads fine,
                // it just no longer matches the text it was made from.
                Label("\(counts.stale) out of date", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let producer = project.activeVersion?.translation(code)?.producerDescription, !producer.isEmpty {
                Text("Last translated with \(producer).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button(outstanding > 0 ? "Update (\(outstanding) to do)" : "Up to date") {
                    translator.update(code, project: project, context: modelContext, settings: settings)
                }
                .disabled(translator.isRunning || outstanding == 0)
                Button("Remove", role: .destructive) { removingTranslation = code }
                    .disabled(translator.isRunning)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.vertical, 2)
    }

    /// Bound to the model, like the editor's own picker: the choice is
    /// per-project, survives relaunch, and seeds the export sheet.
    @ViewBuilder
    private var displaySection: some View {
        if !languages.isEmpty {
            Section {
                Picker("Show", selection: $project.displayedTranslationLanguage) {
                    Text("Original only").tag("")
                    ForEach(languages, id: \.self) { code in
                        Text(CaptionTranslationAvailability.displayName(code)).tag(code)
                    }
                }
            } header: {
                Text("Displayed Translation")
            } footer: {
                Text("Which translation the caption editor shows beneath each line, and the one the export sheet starts on. Clips on the timeline pick their own language in the Clip tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sourceFooter: LocalizedStringKey {
        guard !project.sourceLanguageCode.isEmpty else {
            return "Translations belong to the current transcript version. Re-transcribing starts a fresh set."
        }
        let name = CaptionTranslationAvailability.displayName(project.sourceLanguageCode)
        return "These captions are in \(name). Translations belong to the current transcript version — re-transcribing starts a fresh set."
    }

    private func remove(_ code: String) {
        removingTranslation = nil
        translator.removeTranslation(code, project: project, context: modelContext)
    }
}
