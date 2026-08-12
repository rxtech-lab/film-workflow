import SwiftData
import SwiftUI
import Translation

/// The caption editor's main list.
///
/// Rows show index, time range, speaker and text, with a per-row clip preview.
/// Editing happens in sheets rather than inline so a mis-tap can't silently
/// change a timing.
struct CaptionSegmentListView: View {
    @Bindable var project: CaptionProject
    @Environment(\.modelContext) private var modelContext

    @State private var clipPlayer = CaptionClipPlayer()
    @State private var editingSegment: CaptionSegment?
    @State private var inspectingSegment: CaptionSegment?
    @State private var deletingSegment: CaptionSegment?
    @State private var showRetimeSheet = false
    @State private var showExportSheet = false
    @State private var selection: Set<UUID> = []
    @State private var bulkSpeaker: UUID?
    @State private var gapNotice: String?

    @State private var settings = CaptionSettings.shared
    @State private var aiTask: Task<Void, Never>?
    @State private var aiProgress: CaptionProgress?
    @State private var isRunningAI = false
    @State private var pendingProposal: CaptionEditProposal?
    @State private var aiError: String?
    @State private var aiNotice: String?

    @State private var showTranslateSheet = false
    @State private var translationTask: Task<Void, Never>?
    @State private var translationProgress: CaptionProgress?
    @State private var isTranslating = false
    @State private var translationError: String?
    @State private var translationNotice: String?
    @State private var removingTranslation: String?
    /// Set when a run needs an Apple `TranslationSession`, which only the
    /// `.translationTask` modifier can produce.
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var pendingChoice: CaptionTranslateChoice?

    private var segments: [CaptionSegment] { project.orderedSegments }

    private var issues: [CaptionValidationIssue] {
        CaptionTranscriptValidator.issues(in: project.snapshot())
    }

    private func issues(forSegmentAt index: Int) -> [CaptionValidationIssue] {
        issues.filter { $0.segmentIndex == index && $0.wordIndex == nil }
    }

    var body: some View {
        Group {
            if segments.isEmpty {
                ContentUnavailableView(
                    "No Captions Yet",
                    systemImage: "captions.bubble",
                    description: Text("Run transcription to create captions from your audio.")
                )
            } else {
                list
            }
        }
        .toolbar { toolbarContent }
        .sheet(item: $editingSegment) { segment in
            CaptionSegmentEditorSheet(project: project, segment: segment)
        }
        .sheet(item: $inspectingSegment) { segment in
            CaptionWordInspectorView(project: project, segment: segment)
        }
        .sheet(isPresented: $showRetimeSheet) {
            CaptionRetimeSheet(project: project)
        }
        .sheet(isPresented: $showExportSheet) {
            CaptionExportSheet(project: project)
        }
        .sheet(isPresented: $isRunningAI) {
            CaptionTranscriptionProgressView(progress: aiProgress) {
                aiTask?.cancel()
            }
        }
        .sheet(isPresented: $showTranslateSheet) {
            CaptionTranslateSheet(project: project, selection: selection) { choice in
                startTranslation(choice)
            }
        }
        .sheet(isPresented: $isTranslating) {
            CaptionTranscriptionProgressView(progress: translationProgress) {
                translationTask?.cancel()
            }
        }
        // Apple's engine only exists inside this modifier. `translationConfig`
        // stays nil for the AI engine, which leaves the task dormant.
        .translationTask(translationConfig) { session in
            await runAppleTranslation(session: session)
        }
        .sheet(item: $pendingProposal) { proposal in
            CaptionAIReviewSheet(project: project, proposal: proposal) { applied in
                aiNotice = applied == 0
                    ? "No changes were applied."
                    : "Applied \(applied) change\(applied == 1 ? "" : "s")."
            }
        }
        .alert(
            "AI review",
            isPresented: Binding(
                get: { aiNotice != nil },
                set: { if !$0 { aiNotice = nil } }
            )
        ) {
            Button("OK") { aiNotice = nil }
        } message: {
            Text(aiNotice ?? "")
        }
        .alert(
            "AI review failed",
            isPresented: Binding(
                get: { aiError != nil },
                set: { if !$0 { aiError = nil } }
            )
        ) {
            Button("OK") { aiError = nil }
        } message: {
            Text(aiError ?? "")
        }
        .alert(
            "Gaps closed",
            isPresented: Binding(
                get: { gapNotice != nil },
                set: { if !$0 { gapNotice = nil } }
            )
        ) {
            Button("OK") { gapNotice = nil }
        } message: {
            Text(gapNotice ?? "")
        }
        .alert(
            "Translation",
            isPresented: Binding(
                get: { translationNotice != nil },
                set: { if !$0 { translationNotice = nil } }
            )
        ) {
            Button("OK") { translationNotice = nil }
        } message: {
            Text(translationNotice ?? "")
        }
        .alert(
            "Translation failed",
            isPresented: Binding(
                get: { translationError != nil },
                set: { if !$0 { translationError = nil } }
            )
        ) {
            Button("OK") { translationError = nil }
        } message: {
            Text(translationError ?? "")
        }
        .confirmationDialog(
            "Remove this translation?",
            isPresented: Binding(
                get: { removingTranslation != nil },
                set: { if !$0 { removingTranslation = nil } }
            ),
            titleVisibility: .visible,
            presenting: removingTranslation
        ) { code in
            Button("Remove", role: .destructive) { removeTranslation(code) }
            Button("Cancel", role: .cancel) { removingTranslation = nil }
        } message: { code in
            Text("Every \(CaptionTranslationAvailability.displayName(code)) translation in this version will be deleted, including any you edited.")
        }
        .modifier(CaptionSegmentDeleteConfirmation(
            segment: $deletingSegment,
            onDelete: delete
        ))
        .task(id: project.projectUUID) {
            // Lazy schema backfill: a project last written before versioning gets
            // its version 1 record the first time it's opened. `activeSegments`
            // already returns the right rows without it, so this is bookkeeping,
            // not a correctness requirement.
            project.ensureVersioned()
        }
        .onDisappear { clipPlayer.stop() }
    }

    // MARK: - List

    private var list: some View {
        List(selection: $selection) {
            if project.alignmentQualityEnum.needsReview || !project.warning.isEmpty {
                Section { warningBanner }
            }

            Section {
                ForEach(Array(segments.enumerated()), id: \.element.uuid) { index, segment in
                    row(index: index, segment: segment)
                        .tag(segment.uuid)
                }
            } header: {
                HStack {
                    Text("\(segments.count) captions")
                    Spacer()
                    if !selection.isEmpty {
                        Text("\(selection.count) selected")
                    }
                    if !project.translatedLanguages.isEmpty {
                        translationPicker
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.plain)
        .environment(\.editMode, .constant(selection.isEmpty ? .inactive : .active))
        #endif
    }

    /// Which translation shows beneath each caption.
    ///
    /// Bound to the model rather than local `@State`: the choice is per-project,
    /// survives relaunch, and seeds the export sheet — three things a view-local
    /// toggle would get wrong.
    private var translationPicker: some View {
        Menu {
            Picker("Translation", selection: $project.displayedTranslationLanguage) {
                Text("Original only").tag("")
                ForEach(project.translatedLanguages, id: \.self) { code in
                    Text(CaptionTranslationAvailability.displayName(code)).tag(code)
                }
            }
        } label: {
            Label(
                project.displayedTranslationLanguage.isEmpty
                    ? "Original"
                    : CaptionTranslationAvailability.displayName(project.displayedTranslationLanguage),
                systemImage: "character.bubble"
            )
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private func row(index: Int, segment: CaptionSegment) -> some View {
        let rowIssues = issues(forSegmentAt: index)

        HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 26, alignment: .trailing)

            CaptionClipPlayButton(
                url: project.audioURL,
                startMs: segment.startMs,
                endMs: segment.endMs,
                clipID: segment.uuid.uuidString,
                clipPlayer: clipPlayer
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(
                        "\(CaptionExporter.shortTimestamp(segment.startMs))–"
                        + "\(CaptionExporter.shortTimestamp(segment.endMs))"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                    if let label = project.speaker(segment.speakerId)?.label, !label.isEmpty {
                        Text(label)
                            .font(.caption)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(speakerTint(segment.speakerId).opacity(0.18), in: Capsule())
                    }

                    if segment.isEstimatedTiming {
                        Image(systemName: "clock.badge.questionmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("Timing is estimated")
                    }
                    if segment.hasWordTimings {
                        Image(systemName: "waveform")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("\(segment.words.count) word timings")
                    }
                }

                Text(segment.text)
                    .font(.body)
                    .textSelection(.enabled)

                translationLine(for: segment)

                ForEach(rowIssues) { issue in
                    Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(issue.isBlocking ? .red : .orange)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editingSegment = segment }
        .contextMenu {
            Button("Edit Text & Timing…") { editingSegment = segment }
            Button("Word Timings…") { inspectingSegment = segment }
                .disabled(segment.words.isEmpty && segment.text.isEmpty)
            Divider()
            Button("Split at Midpoint") { split(segment) }
                .disabled(segment.words.count < 2)
            Button("Merge with Next") { mergeWithNext(segment) }
                .disabled(nextSegment(after: segment) == nil)
            Divider()
            Button("Delete…", role: .destructive) { deletingSegment = segment }
        }
        #if os(iOS)
        .swipeActions(edge: .trailing) {
            Button("Delete…", role: .destructive) { deletingSegment = segment }
            Button("Edit") { editingSegment = segment }
                .tint(.blue)
        }
        .swipeActions(edge: .leading) {
            Button("Words") { inspectingSegment = segment }
                .tint(.purple)
        }
        #endif
    }

    /// The selected translation, under the original.
    ///
    /// Secondary colour at `.callout` is what makes the original read as the
    /// primary text — a divider or an indent would fight the row metrics the
    /// timestamps and speaker chip already establish.
    @ViewBuilder
    private func translationLine(for segment: CaptionSegment) -> some View {
        let code = project.displayedTranslationLanguage
        if !code.isEmpty {
            if let translation = segment.translation(code), !translation.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Text(translation.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if segment.isTranslationStale(code) {
                        Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("The caption changed after this was translated")
                    }
                }
            } else {
                Text("Not translated")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var warningBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            if project.alignmentQualityEnum.needsReview {
                Label {
                    Text(
                        project.alignmentQualityEnum == .estimated
                        ? "Timings are estimated from text length. Open the retimer to correct them."
                        : "Timings are aligned per sentence, not per word. Spot-check them in the retimer."
                    )
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
            }
            if !project.warning.isEmpty {
                Text(project.warning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Open Retimer") { showRetimeSheet = true }
                .buttonStyle(.bordered)
        }
        .font(.callout)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    showExportSheet = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }

                Divider()

                Menu {
                    Button("Translate…") { showTranslateSheet = true }
                        .disabled(isTranslating)

                    if !project.translatedLanguages.isEmpty {
                        Divider()
                        ForEach(project.translatedLanguages, id: \.self) { code in
                            Button(updateLabel(for: code)) { updateTranslation(code) }
                                .disabled(isTranslating)
                        }
                        Divider()
                        Menu("Remove Translation") {
                            ForEach(project.translatedLanguages, id: \.self) { code in
                                Button(
                                    CaptionTranslationAvailability.displayName(code),
                                    role: .destructive
                                ) {
                                    removingTranslation = code
                                }
                            }
                        }
                    }
                } label: {
                    Label("Translate", systemImage: "globe")
                }

                Divider()

                Button {
                    reviewSplits()
                } label: {
                    Label("Review Splits…", systemImage: "rectangle.split.3x1")
                }
                    .disabled(segments.isEmpty || isRunningAI)
                Button {
                    checkTerms()
                } label: {
                    Label("Check Terms…", systemImage: "text.magnifyingglass")
                }
                    .disabled(segments.isEmpty || project.usableTerms.isEmpty || isRunningAI)

                Divider()

                Button {
                    showRetimeSheet = true
                } label: {
                    Label("Retimer…", systemImage: "timeline.selection")
                }
                    .disabled(segments.isEmpty)

                Button {
                    let changed = project.removeGaps(shorterThan: 300)
                    gapNotice = changed == 0
                        ? "No gaps needed closing."
                        : "Closed \(changed) gap\(changed == 1 ? "" : "s")."
                } label: {
                    Label("Close Gaps Under 300 ms", systemImage: "arrow.left.and.right")
                }
                .disabled(segments.count < 2)

                if !selection.isEmpty, !project.speakers.isEmpty {
                    Divider()
                    Menu("Assign Speaker to Selection") {
                        ForEach(project.speakers) { speaker in
                            Button(speaker.label) { assignSpeaker(speaker.id) }
                        }
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .disabled(segments.isEmpty)
        }
    }

    // MARK: - Translation

    /// e.g. "Update Chinese (412 of 900)" — the counts are what tell the user
    /// whether a run is worth starting.
    private func updateLabel(for code: String) -> String {
        let counts = CaptionTranslationService.counts(for: code, in: project)
        let name = CaptionTranslationAvailability.displayName(code)
        let outstanding = counts.total - counts.translated + counts.stale
        guard outstanding > 0 else { return "\(name) — up to date" }
        return "Update \(name) (\(outstanding) to do)"
    }

    private func updateTranslation(_ code: String) {
        startTranslation(
            CaptionTranslateChoice(
                languageCode: code,
                engine: settings.translationEngine,
                scope: .missingOrStale
            )
        )
    }

    /// Routes a run to the right engine.
    ///
    /// The AI engine can start immediately. Apple's can't: its session comes
    /// from `.translationTask`, so all this can do is stash the choice and set
    /// the configuration that wakes the modifier up.
    private func startTranslation(_ choice: CaptionTranslateChoice) {
        guard !isTranslating else { return }
        pendingChoice = choice

        switch choice.engine {
        case .aiBackend:
            runAITranslation(choice)

        case .appleTranslation:
            let target = Locale.Language(identifier: choice.languageCode)
            let source = project.sourceLanguageCode.isEmpty
                ? nil
                : Locale.Language(identifier: project.sourceLanguageCode)

            isTranslating = true
            translationProgress = .translating(
                done: 0,
                total: 0,
                language: CaptionTranslationAvailability.displayName(choice.languageCode)
            )
            // Re-requesting the same pair produces no new session, so an
            // unchanged target has to be invalidated to fire the task again.
            if translationConfig?.target == target, translationConfig?.source == source {
                translationConfig?.invalidate()
            } else {
                translationConfig = TranslationSession.Configuration(source: source, target: target)
            }
        }
    }

    private func runAppleTranslation(session: TranslationSession) async {
        guard let choice = pendingChoice, choice.engine == .appleTranslation else { return }
        pendingChoice = nil

        let runner = AppleTranslationRunner(
            session: session,
            sourceLanguage: project.sourceLanguageCode,
            targetLanguage: choice.languageCode
        )
        await perform(choice: choice, runner: runner)
    }

    private func runAITranslation(_ choice: CaptionTranslateChoice) {
        pendingChoice = nil
        let config = try? AppConfig.loadFromKeychain()
        let runner: AICaptionTranslationRunner
        do {
            runner = try CaptionTranslationService.makeAIRunner(
                project: project,
                targetLanguage: choice.languageCode,
                config: config
            )
        } catch {
            translationError = error.localizedDescription
            return
        }

        isTranslating = true
        translationProgress = .translating(
            done: 0,
            total: 0,
            language: CaptionTranslationAvailability.displayName(choice.languageCode)
        )
        translationTask = Task { await perform(choice: choice, runner: runner) }
    }

    /// Shared tail: run, report, and make sure the progress sheet comes down on
    /// every path, including cancellation.
    ///
    /// Partial results are deliberately kept — the service writes each batch as
    /// it lands, so cancelling half way through a nine-hundred-caption run
    /// leaves the first half translated rather than throwing the work away.
    private func perform(choice: CaptionTranslateChoice, runner: any CaptionTranslationRunner) async {
        defer {
            isTranslating = false
            translationProgress = nil
            translationTask = nil
        }
        do {
            let written = try await CaptionTranslationService.translate(
                project: project,
                runner: runner,
                scope: choice.scope,
                context: modelContext,
                onProgress: { translationProgress = $0 }
            )
            let name = CaptionTranslationAvailability.displayName(choice.languageCode)
            translationNotice = written == 0
                ? "Nothing needed translating into \(name)."
                : "Translated \(written) caption\(written == 1 ? "" : "s") into \(name)."
        } catch is CancellationError {
            // User pressed Cancel; whatever was written stays written.
        } catch {
            translationError = error.localizedDescription
        }
    }

    private func removeTranslation(_ code: String) {
        removingTranslation = nil
        do {
            try CaptionTranslationService.removeTranslation(code, from: project, context: modelContext)
        } catch {
            translationError = error.localizedDescription
        }
    }

    // MARK: - AI actions

    private func reviewSplits() {
        runAI { engine, transcript in
            let label = engine.modelLabel
            return try await CaptionAISplitter.proposal(
                for: transcript,
                maxRunes: settings.maxCueRunes,
                terms: project.usableTerms,
                languageHint: project.languageHint,
                engine: engine,
                onProgress: { done, total in
                    Task { @MainActor in
                        aiProgress = .reviewingWithAI(engine: label, done: done, total: total)
                    }
                }
            )
        }
    }

    private func checkTerms() {
        runAI { engine, transcript in
            let label = engine.modelLabel
            return try await CaptionTermReviewer.proposal(
                for: transcript,
                terms: project.usableTerms,
                languageHint: project.languageHint,
                engine: engine,
                onProgress: { done, total in
                    Task { @MainActor in
                        aiProgress = .reviewingWithAI(engine: label, done: done, total: total)
                    }
                }
            )
        }
    }

    /// Shared plumbing for the two batch tasks: resolve an engine, snapshot the
    /// transcript, run off the main actor with a progress sheet, then hand the
    /// result to the review sheet.
    ///
    /// The manual actions always review, whatever `aiConfirmChanges` says — that
    /// setting exists for the automatic pass after transcription, and choosing
    /// "Review Splits…" from a menu is already an explicit request to review.
    private func runAI(
        _ work: @escaping @Sendable (any CaptionAIEngine, CaptionTranscriptSnapshot) async throws
            -> CaptionEditProposal
    ) {
        guard !isRunningAI else { return }

        let config = try? AppConfig.loadFromKeychain()
        let backend: AgentBackend
        do {
            backend = try AgentBackendAvailability.shared.resolved(
                preferred: settings.aiBackend,
                config: config,
                for: .transcriptReview
            )
        } catch {
            aiError = error.localizedDescription
            return
        }

        let transcript = project.snapshot()
        isRunningAI = true
        aiProgress = .reviewingWithAI(engine: backend.modelLabel(config: config), done: 0, total: 0)

        aiTask = Task {
            defer {
                isRunningAI = false
                aiProgress = nil
                aiTask = nil
            }
            do {
                // Always an in-process engine: `resolved(for: .transcriptReview)`
                // above never returns a command-line backend, because this work
                // is per-cue over a whole transcript and a subprocess launch
                // each would take minutes.
                let engine = try CaptionAIEngineFactory.make(backend: backend, config: config)

                let proposal = try await work(engine, transcript)
                // Presenting a second sheet while the progress sheet is still up
                // silently drops it on macOS; let the first one close first.
                isRunningAI = false
                try? await Task.sleep(for: .milliseconds(150))
                pendingProposal = proposal
            } catch is CancellationError {
                // User pressed Cancel.
            } catch {
                aiError = error.localizedDescription
            }
        }
    }

    // MARK: - Actions

    private func nextSegment(after segment: CaptionSegment) -> CaptionSegment? {
        let ordered = segments
        guard let index = ordered.firstIndex(where: { $0.uuid == segment.uuid }),
              index + 1 < ordered.count
        else { return nil }
        return ordered[index + 1]
    }

    private func split(_ segment: CaptionSegment) {
        let midpoint = segment.words.count / 2
        guard let trailing = segment.makeSplit(atWordIndex: midpoint) else { return }
        trailing.project = project
        modelContext.insert(trailing)
        project.reindexSegments()
        project.updatedAt = Date()
    }

    private func mergeWithNext(_ segment: CaptionSegment) {
        guard let next = nextSegment(after: segment) else { return }
        segment.merge(with: next)
        modelContext.delete(next)
        project.reindexSegments()
        project.updatedAt = Date()
    }

    private func delete(_ segment: CaptionSegment) {
        selection.remove(segment.uuid)
        modelContext.delete(segment)
        project.reindexSegments()
        project.updatedAt = Date()
    }

    /// Bulk speaker assignment. This is what makes a Whisper or OpenAI
    /// transcript of an interview usable at all — neither provider diarizes, so
    /// every caption arrives unassigned.
    private func assignSpeaker(_ speakerId: UUID) {
        for segment in segments where selection.contains(segment.uuid) {
            segment.speakerId = speakerId
            segment.isUserEdited = true
        }
        project.updatedAt = Date()
        selection.removeAll()
    }

    private func speakerTint(_ id: UUID?) -> Color {
        guard let speaker = project.speaker(id) else { return .secondary }
        return CaptionSpeakerPalette.color(at: speaker.colorIndex)
    }
}

private struct CaptionSegmentDeleteConfirmation: ViewModifier {
    @Binding var segment: CaptionSegment?
    let onDelete: (CaptionSegment) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete this caption?",
            isPresented: Binding(
                get: { segment != nil },
                set: { if !$0 { segment = nil } }
            ),
            titleVisibility: .visible,
            presenting: segment
        ) { target in
            Button("Delete Caption", role: .destructive) {
                onDelete(target)
                segment = nil
            }
            Button("Cancel", role: .cancel) { segment = nil }
        } message: { _ in
            Text("This caption and its translations will be permanently deleted from the current version.")
        }
    }
}

/// Distinct, colour-blind-safe tints for speaker chips.
nonisolated enum CaptionSpeakerPalette {
    static let colors: [Color] = [.blue, .orange, .purple, .green, .pink, .teal, .indigo, .brown]

    static func color(at index: Int) -> Color {
        guard !colors.isEmpty else { return .blue }
        return colors[((index % colors.count) + colors.count) % colors.count]
    }
}
