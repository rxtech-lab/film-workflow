import SwiftData
import SwiftUI

/// Per-word timing editor.
///
/// The word ruler is the centrepiece: capsule width is proportional to duration,
/// so a mistimed word is visible before you play anything. Adjusting a boundary
/// pins that word, which exempts it from later rescaling and turns it into an
/// anchor for its neighbours.
struct CaptionWordInspectorView: View {
    @Bindable var project: CaptionProject
    let segment: CaptionSegment

    @Environment(\.dismiss) private var dismiss

    @State private var selectedIndex: Int = 0
    @State private var nudgeMode: NudgeMode = .clamp
    @State private var boundary: CaptionTimestampBoundary = .start
    @State private var player: CaptionEditorAudioPlayer?
    @State private var clipPlayer = CaptionClipPlayer()
    @State private var editingBoundary: CaptionTimestampBoundary?
    @State private var draftWordText: String = ""

    enum NudgeMode: String, CaseIterable, Identifiable {
        /// Keep the word inside its neighbours.
        case clamp
        /// Move everything after it by the same amount.
        case ripple

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .clamp: return "Clamp"
            case .ripple: return "Ripple"
            }
        }
    }

    private var words: [CaptionWord] { segment.words }

    private var selectedWord: CaptionWord? {
        words.indices.contains(selectedIndex) ? words[selectedIndex] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if words.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ruler
                        Divider()
                        selectedWordEditor
                        Divider()
                        bulkActions
                    }
                    .padding(16)
                }
            }

            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 560)
        .onAppear(perform: load)
        .onDisappear {
            player?.pause()
            clipPlayer.stop()
        }
        .sheet(item: $editingBoundary) { which in
            CaptionTimestampPickerSheet(
                title: which == .start ? "Word Start" : "Word End",
                totalMs: wordBinding(for: which),
                maxMs: project.audioDurationMs,
                currentAudioMs: player?.currentMs
            ) {
                editingBoundary = nil
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Word Timings")
                    .font(.headline)
                Spacer()
                Text("\(words.count) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(segment.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ContentUnavailableView(
                "No Word Timings",
                systemImage: "waveform.slash",
                description: Text("""
                    This provider didn't return word timings. You can generate approximate ones \
                    by spreading the words evenly across the caption.
                    """)
            )
            Button("Generate Approximate Timings") {
                segment.retokenizeWords(preservingTimingsFrom: [])
                if segment.words.isEmpty { segment.distributeWordsEvenly() }
                project.updatedAt = Date()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    /// Capsule width ∝ duration, tint ∝ confidence, hatched when estimated.
    private var ruler: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Timeline")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(Array(words.enumerated()), id: \.element.id) { index, word in
                        wordCapsule(index: index, word: word)
                            .id(index)
                    }
                }
                .padding(.vertical, 4)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: Binding(
                get: { Optional(selectedIndex) },
                set: { if let value = $0 { selectedIndex = value } }
            ))
        }
    }

    @ViewBuilder
    private func wordCapsule(index: Int, word: CaptionWord) -> some View {
        let isSelected = index == selectedIndex
        // Scale width by duration so 40 ms and 900 ms don't look alike, but floor
        // it so a very short word stays tappable.
        let width = max(CGFloat(word.durationMs) / 8, 34)

        Button {
            selectedIndex = index
            draftWordText = word.text
            player?.seek(toMs: word.offsetMs)
        } label: {
            VStack(spacing: 2) {
                Text(word.text)
                    .font(.caption)
                    .lineLimit(1)
                Text("\(word.durationMs)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: width)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(capsuleTint(word).opacity(isSelected ? 0.45 : 0.18))
                if word.isEstimated {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .topTrailing) {
                if word.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.tint)
                        .padding(2)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
    }

    /// Low-confidence words are the ones worth checking first.
    private func capsuleTint(_ word: CaptionWord) -> Color {
        if word.isEstimated { return .secondary }
        if word.confidence <= 0 { return .blue }
        if word.confidence < 0.5 { return .red }
        if word.confidence < 0.8 { return .orange }
        return .green
    }

    @ViewBuilder
    private var selectedWordEditor: some View {
        if let word = selectedWord {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Selected word")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if word.isEstimated {
                        Text("Estimated")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if word.confidence > 0 {
                        Text("Confidence \(Int(word.confidence * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    TextField("Word", text: $draftWordText)
                        #if os(macOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                        .onSubmit(commitWordText)

                    Button("Rename", action: commitWordText)
                        .disabled(draftWordText == word.text || draftWordText.isEmpty)
                }

                Picker("Boundary", selection: $boundary) {
                    ForEach(CaptionTimestampBoundary.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text(boundary == .start ? "Start" : "End")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        editingBoundary = boundary
                    } label: {
                        Text(CaptionExporter.vttTimestamp(
                            boundary == .start ? word.offsetMs : word.endMs
                        ))
                        .monospacedDigit()
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 8) {
                    Button("−50") { nudge(-50) }
                    Button("−10") { nudge(-10) }
                    Button("+10") { nudge(10) }
                    Button("+50") { nudge(50) }
                }
                .buttonStyle(.bordered)
                .monospacedDigit()

                HStack(spacing: 10) {
                    Button {
                        guard let player else { return }
                        setBoundary(to: player.currentMs)
                        advanceAfterSet()
                    } label: {
                        Label("Use Current Time", systemImage: "playhead.and.waveform")
                    }
                    .buttonStyle(.bordered)
                    .disabled(player == nil)

                    Button {
                        clipPlayer.toggle(
                            url: project.audioURL,
                            startMs: word.offsetMs,
                            endMs: word.endMs,
                            clipID: "word-\(word.id)"
                        )
                    } label: {
                        Label("Play Word", systemImage: "play.circle")
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 10) {
                    Toggle("Pinned", isOn: Binding(
                        get: { selectedWord?.isPinned ?? false },
                        set: { setPinned($0) }
                    ))
                    .toggleStyle(.switch)

                    Spacer()

                    Button("Reset to Auto") {
                        segment.resetWord(at: selectedIndex)
                        project.updatedAt = Date()
                    }
                    .disabled(!(selectedWord?.isPinned ?? false))
                }

                Picker("When nudging", selection: $nudgeMode) {
                    ForEach(NudgeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(nudgeMode == .clamp
                    ? "Keeps the word between its neighbours."
                    : "Shifts all later unpinned words by the same amount.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var bulkActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("All words")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Distribute Evenly") {
                    segment.distributeWordsEvenly()
                    project.updatedAt = Date()
                }
                Button("Snap to Caption Bounds") {
                    segment.snapWordsToSegmentBounds()
                    project.updatedAt = Date()
                }
            }
            .buttonStyle(.bordered)

            let outOfRange = words.contains { $0.offsetMs < segment.startMs || $0.endMs > segment.endMs }
            if outOfRange {
                Label(
                    "Some words fall outside the caption's time range.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let player {
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)

                Button {
                    player.playRange(startMs: segment.startMs, endMs: segment.endMs)
                } label: {
                    Image(systemName: "play.rectangle")
                }
                .buttonStyle(.borderless)
                .help("Play the whole caption")

                Text(CaptionExporter.vttTimestamp(player.currentMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        #if os(macOS)
        // Keyboard-first retiming: this is a repetitive task and the mouse is slow.
        .onKeyPress(.space) {
            player?.togglePlayPause()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            selectPrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            selectNext()
            return .handled
        }
        .onKeyPress(KeyEquivalent("[")) {
            guard let player else { return .ignored }
            boundary = .start
            setBoundary(to: player.currentMs)
            return .handled
        }
        .onKeyPress(KeyEquivalent("]")) {
            guard let player else { return .ignored }
            boundary = .end
            setBoundary(to: player.currentMs)
            advanceAfterSet()
            return .handled
        }
        .onKeyPress(KeyEquivalent("p")) {
            setPinned(!(selectedWord?.isPinned ?? false))
            return .handled
        }
        #endif
    }

    // MARK: - Actions

    private func load() {
        draftWordText = words.first?.text ?? ""
        if FileManager.default.fileExists(atPath: project.audioURL.path) {
            player = CaptionEditorAudioPlayer(url: project.audioURL)
            player?.seek(toMs: segment.startMs)
        }
    }

    private func wordBinding(for which: CaptionTimestampBoundary) -> Binding<Int> {
        Binding(
            get: {
                guard let word = selectedWord else { return 0 }
                return which == .start ? word.offsetMs : word.endMs
            },
            set: { newValue in
                segment.adjustWord(
                    at: selectedIndex,
                    boundary: which,
                    toMs: newValue,
                    ripple: nudgeMode == .ripple
                )
                project.updatedAt = Date()
            }
        )
    }

    private func setBoundary(to ms: Int) {
        segment.adjustWord(
            at: selectedIndex,
            boundary: boundary,
            toMs: ms,
            ripple: nudgeMode == .ripple
        )
        project.updatedAt = Date()
    }

    private func nudge(_ delta: Int) {
        guard let word = selectedWord else { return }
        let current = boundary == .start ? word.offsetMs : word.endMs
        setBoundary(to: current + delta)
    }

    /// Setting a start moves on to that word's end; setting an end moves to the
    /// next word. That turns retiming into a single repeated keystroke.
    private func advanceAfterSet() {
        if boundary == .start {
            boundary = .end
        } else {
            boundary = .start
            selectNext()
        }
    }

    private func selectNext() {
        guard selectedIndex + 1 < words.count else { return }
        selectedIndex += 1
        draftWordText = words[selectedIndex].text
    }

    private func selectPrevious() {
        guard selectedIndex > 0 else { return }
        selectedIndex -= 1
        draftWordText = words[selectedIndex].text
    }

    private func setPinned(_ pinned: Bool) {
        guard words.indices.contains(selectedIndex) else { return }
        var updated = segment.words
        updated[selectedIndex].isPinned = pinned
        segment.words = updated
        segment.isUserEdited = true
        project.updatedAt = Date()
    }

    private func commitWordText() {
        guard words.indices.contains(selectedIndex) else { return }
        let trimmed = draftWordText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var updated = segment.words
        updated[selectedIndex].text = trimmed
        segment.words = updated
        // Keep the caption text and its words in agreement — otherwise a
        // sentence-level export would disagree with a word-level one.
        segment.text = updated.map(\.text).reduce(into: "") { CaptionText.appendWord($1, to: &$0) }
        segment.isUserEdited = true
        project.updatedAt = Date()
    }
}
