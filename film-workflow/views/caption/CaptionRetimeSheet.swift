import SwiftData
import SwiftUI

/// Karaoke-style bulk retimer.
///
/// Ported from debate-bot's `TranscriptSegmentRetimeSheet`. The workflow is: play
/// the audio and hit Space as each caption starts and ends. Setting a start
/// auto-advances to that caption's end; setting an end auto-advances to the next
/// caption. That reduces retiming a whole transcript to a single repeated
/// keystroke instead of hundreds of individual time entries.
///
/// The one thing the UI has to answer at a glance is "what does Space write right
/// now?", so the pending boundary — and only that boundary — is highlighted in
/// yellow, in the list and again next to the playhead.
///
/// Edits accumulate in a draft and are written in one pass on save, so a long
/// session doesn't produce hundreds of SwiftData writes — and can be abandoned.
struct CaptionRetimeSheet: View {
    @Bindable var project: CaptionProject

    @Environment(\.dismiss) private var dismiss

    @State private var draft = CaptionRetimeDraft()
    @State private var segmentsByID: [UUID: CaptionSegment] = [:]
    @State private var focusedID: UUID?
    @State private var scrollID: UUID?
    @State private var boundary: CaptionTimestampBoundary = .start
    @State private var player: CaptionEditorAudioPlayer?
    @State private var closeGapsOnSave = false
    @State private var editingBoundary: CaptionTimestampBoundary?
    @FocusState private var keyboardFocused: Bool

    /// The colour of "this is what Space writes". Used nowhere else in the sheet
    /// so it can't be confused with the accent colour, which means "focused row".
    private static let pending = Color.yellow

    typealias Range = CaptionRetimeDraft.Range

    private var order: [UUID] { draft.order }

    private var audioDurationMs: Int {
        project.audioDurationMs > 0 ? project.audioDurationMs : (player?.durationMs ?? 0)
    }

    private var focusedIndex: Int? {
        guard let focusedID else { return nil }
        return draft.index(of: focusedID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            captionList
            Divider()
            CaptionRetimeTransport(
                player: player, audioDurationMs: audioDurationMs,
                focusedIndex: focusedIndex, focusedRange: focusedID.flatMap { draft[$0] },
                boundary: $boundary, editingBoundary: $editingBoundary,
                setBoundaryToPlayhead: setBoundaryToPlayhead
            )
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 660)
        // A long session accumulates an unsaved draft; don't let a stray Escape
        // or drag throw it away. Cancel is the deliberate way out.
        .interactiveDismissDisabled()
        .onAppear(perform: load)
        .onDisappear { player?.pause() }
        .defaultFocus($keyboardFocused, true)
        .sheet(item: $editingBoundary) { which in
            CaptionTimestampPickerSheet(
                title: which == .start ? "Start Time" : "End Time",
                totalMs: boundaryBinding(which),
                maxMs: audioDurationMs,
                currentAudioMs: player?.currentMs
            ) {
                editingBoundary = nil
            }
        }
        #if os(macOS)
        // Attached to the root so the shortcuts work wherever focus sits inside
        // the sheet — key presses bubble up the focus chain.
        .onKeyPress(.space) {
            setBoundaryToPlayhead()
            return .handled
        }
        .onKeyPress(KeyEquivalent("p")) {
            player?.togglePlayPause()
            return .handled
        }
        .onKeyPress(KeyEquivalent("[")) {
            boundary = .start
            setBoundaryToPlayhead()
            return .handled
        }
        .onKeyPress(KeyEquivalent("]")) {
            boundary = .end
            setBoundaryToPlayhead()
            return .handled
        }
        .onKeyPress(.downArrow) {
            focusNext()
            return .handled
        }
        .onKeyPress(.upArrow) {
            focusPrevious()
            return .handled
        }
        #endif
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(project.lyricsSourceID == nil ? "Retime Captions" : "Retime Lyrics")
                    .font(.headline)
                Spacer()
                if let index = focusedIndex {
                    let position: String = "\(index + 1) / \(order.count)"
                    Text(position)
                        .accessibilityIdentifier("caption-retime-position")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if draft.changedCount > 0 {
                    let changed: Int = draft.changedCount
                    Text("\(changed) changed")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }

            HStack(spacing: 14) {
                keyHint("Space", "Set the highlighted time")
                keyHint("P", "Play / Pause")
                keyHint("↑ ↓", "Change caption")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func keyHint(_ key: String, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.caption2.monospaced())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.08))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.primary.opacity(0.12))
                }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Caption list

    private var captionList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(Array(order.enumerated()), id: \.element) { index, id in
                    if let segment = segmentsByID[id], let range = draft[id] {
                        captionRow(index: index, id: id, segment: segment, range: range)
                            .id(id)
                    }
                }
            }
            .padding(12)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        // Scrolling reports the visible row back through this binding. Keep
        // that separate from the caption whose boundary Space will edit.
        .scrollPosition(id: $scrollID, anchor: .center)
        .onChange(of: focusedID) { _, id in scrollID = id }
        .accessibilityIdentifier("caption-retime-list")
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocused)
    }

    @ViewBuilder
    private func captionRow(
        index: Int,
        id: UUID,
        segment: CaptionSegment,
        range: Range
    ) -> some View {
        let isFocused = id == focusedID
        let original = draft.originalRange(for: id)
        let startChanged = range.startMs != original?.startMs
        let endChanged = range.endMs != original?.endMs
        let isChanged = startChanged || endChanged

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)

                // Precomputed into explicitly-typed locals: interpolating these calls
                // inside a Text initializer sends the type-checker exponential here.
                // Start and end are separate chips so only the edited side lights up.
                let startLabel: String = CaptionExporter.vttTimestamp(range.startMs)
                let endLabel: String = CaptionExporter.vttTimestamp(range.endMs)
                HStack(spacing: 3) {
                    timestampChip(
                        startLabel,
                        pending: isFocused && boundary == .start,
                        changed: startChanged,
                        valid: range.isValid
                    )
                    Text(verbatim: "→")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                    timestampChip(
                        endLabel,
                        pending: isFocused && boundary == .end,
                        changed: endChanged,
                        valid: range.isValid
                    )
                }

                if isChanged {
                    Image(systemName: "pencil.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
                Spacer()
                if let label = project.speaker(segment.speakerId)?.label, !label.isEmpty {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(segment.text)
                .accessibilityIdentifier("caption-retime-text.\(id)")
                .font(isFocused ? .body : .callout)
                .foregroundStyle(isFocused ? .primary : .secondary)
                .lineLimit(3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isFocused ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isFocused ? Color.accentColor : .clear, lineWidth: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            focusedID = id
            boundary = .start
            player?.seek(toMs: range.startMs)
        }
    }

    /// The pending boundary is the only thing in the sheet painted yellow.
    private func timestampChip(
        _ label: String,
        pending: Bool,
        changed: Bool,
        valid: Bool
    ) -> some View {
        Text(label)
            .font(.caption.monospacedDigit())
            .fontWeight(pending ? .semibold : .regular)
            .foregroundStyle(pending ? Color.black : timestampColor(changed: changed, valid: valid))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(pending ? Self.pending : Color.clear)
            }
            .animation(.snappy(duration: 0.15), value: pending)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("Close gaps shorter than 300 ms on save", isOn: $closeGapsOnSave)
                .font(.callout)

            if draft.hasInvalidRange {
                Label(
                    "Some captions end before they start.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
            }

            Spacer()

            Button("Cancel", role: .cancel) { dismiss() }
                .accessibilityIdentifier("caption-retime-cancel")
            Button("Save \(draft.changedCount == 0 ? "" : "(\(draft.changedCount))")") { save() }
                .accessibilityIdentifier("caption-retime-save")
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(draft.changedCount == 0 || draft.hasInvalidRange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    /// Invalid ranges stay red — a changed-but-broken time is still broken.
    private func timestampColor(changed: Bool, valid: Bool) -> Color {
        if !valid { return .red }
        return changed ? Color.accentColor : Color.secondary
    }

    private func load() {
        let segments = project.orderedSegments
        segmentsByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.uuid, $0) })
        draft = CaptionRetimeDraft(segments: segments)
        focusedID = order.first
        if FileManager.default.fileExists(atPath: project.audioURL.path) {
            player = CaptionEditorAudioPlayer(url: project.audioURL)
        }
    }

    private func boundaryBinding(_ which: CaptionTimestampBoundary) -> Binding<Int> {
        Binding(
            get: {
                guard let id = focusedID, let range = draft[id] else { return 0 }
                return which == .start ? range.startMs : range.endMs
            },
            set: { apply($0, to: which) }
        )
    }

    private func setBoundaryToPlayhead() {
        guard let player, focusedID != nil else { return }
        apply(player.currentMs, to: boundary)
        advance()
    }

    private func apply(_ ms: Int, to which: CaptionTimestampBoundary) {
        guard let id = focusedID else { return }
        draft.apply(ms, to: which, for: id)
    }

    /// Start → that caption's end → the next caption's start.
    private func advance() {
        if boundary == .start {
            boundary = .end
        } else {
            boundary = .start
            focusNext()
        }
    }

    private func focusNext() {
        guard let index = focusedIndex, index + 1 < order.count
        else { return }
        focusedID = order[index + 1]
    }

    private func focusPrevious() {
        guard let index = focusedIndex, index > 0 else { return }
        focusedID = order[index - 1]
    }

    private func save() {
        // Resolve once at commit in case a caption was removed or the active
        // version changed elsewhere while this sheet was open.
        let segments = Dictionary(uniqueKeysWithValues: project.orderedSegments.map { ($0.uuid, $0) })
        // Snapshot the writes before touching the model: SwiftUI can rebuild this
        // view mid-save, and iterating live state while mutating it is how you get
        // half-applied edits.
        let updates: [(CaptionSegment, Range)] = draft.pendingIDs.compactMap { id in
            guard let segment = segments[id], let range = draft[id], range.isValid else { return nil }
            return (segment, range)
        }

        for (segment, range) in updates {
            segment.retime(toStartMs: range.startMs, endMs: range.endMs)
        }
        if closeGapsOnSave {
            project.removeGaps(shorterThan: 300)
        }
        project.reindexSegments()
        // Hand-timing was the fix the banner asked for; drop it once no caption
        // is estimated any more.
        project.refreshEstimatedTimingState()
        project.updatedAt = Date()
        dismiss()
    }
}
