import SwiftData
import SwiftUI

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
    @State private var showAssistantSheet = false

    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

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
        .sheet(isPresented: $showAssistantSheet) {
            NavigationStack {
                CaptionAssistantView(project: project, selection: selection)
            }
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
                }
            }
        }
        #if os(iOS)
        .listStyle(.plain)
        .environment(\.editMode, .constant(selection.isEmpty ? .inactive : .active))
        #endif
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
            Button("Delete", role: .destructive) { delete(segment) }
        }
        #if os(iOS)
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { delete(segment) }
            Button("Edit") { editingSegment = segment }
                .tint(.blue)
        }
        .swipeActions(edge: .leading) {
            Button("Words") { inspectingSegment = segment }
                .tint(.purple)
        }
        #endif
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
            Button {
                showExportSheet = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(segments.isEmpty)
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Review Splits…") { reviewSplits() }
                    .disabled(segments.isEmpty || isRunningAI)
                Button("Check Terms…") { checkTerms() }
                    .disabled(segments.isEmpty || project.usableTerms.isEmpty || isRunningAI)
                Divider()
                Button("Open Assistant") { openAssistant() }
            } label: {
                Label("AI", systemImage: "sparkles")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Retimer…") { showRetimeSheet = true }
                    .disabled(segments.isEmpty)

                Button("Close Gaps Under 300 ms") {
                    let changed = project.removeGaps(shorterThan: 300)
                    gapNotice = changed == 0
                        ? "No gaps needed closing."
                        : "Closed \(changed) gap\(changed == 1 ? "" : "s")."
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
                Label("Tools", systemImage: "slider.horizontal.3")
            }
        }
    }

    // MARK: - AI actions

    /// Opens the assistant beside the captions on macOS, and as a sheet on iOS
    /// where a second window isn't available. Same view either way.
    private func openAssistant() {
        #if os(macOS)
            openWindow(id: CaptionAssistantWindowID.value, value: project.projectUUID)
        #else
            showAssistantSheet = true
        #endif
    }

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
        let backend: CaptionAIBackend
        do {
            backend = try CaptionAIAvailability.shared.resolved(
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
        // Named before the engine exists: building a CLI engine starts the MCP
        // server, which is slow enough to be visible.
        aiProgress = .reviewingWithAI(engine: backend.modelLabel(config: config), done: 0, total: 0)

        aiTask = Task {
            defer {
                isRunningAI = false
                aiProgress = nil
                aiTask = nil
            }
            do {
                // The conversational factory, because a CLI backend has to have
                // the MCP server up before it can read a single caption.
                let (engine, release) = try await CaptionAIEngineFactory.makeConversational(
                    backend: backend,
                    config: config,
                    project: project
                )
                defer { Task { await release() } }

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

/// Distinct, colour-blind-safe tints for speaker chips.
nonisolated enum CaptionSpeakerPalette {
    static let colors: [Color] = [.blue, .orange, .purple, .green, .pink, .teal, .indigo, .brown]

    static func color(at index: Int) -> Color {
        guard !colors.isEmpty else { return .blue }
        return colors[((index % colors.count) + colors.count) % colors.count]
    }
}
