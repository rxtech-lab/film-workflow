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

    @State private var draft: [UUID: Range] = [:]
    @State private var order: [UUID] = []
    @State private var focusedID: UUID?
    @State private var boundary: CaptionTimestampBoundary = .start
    @State private var player: CaptionEditorAudioPlayer?
    @State private var closeGapsOnSave = false
    @State private var editingBoundary: CaptionTimestampBoundary?
    @FocusState private var keyboardFocused: Bool

    /// The colour of "this is what Space writes". Used nowhere else in the sheet
    /// so it can't be confused with the accent colour, which means "focused row".
    private static let pending = Color.yellow

    /// A caption's pending time range. Start/end here, offset/duration in storage.
    struct Range: Equatable {
        var startMs: Int
        var endMs: Int

        var isValid: Bool { endMs > startMs && startMs >= 0 }
    }

    private var segmentsByID: [UUID: CaptionSegment] {
        Dictionary(uniqueKeysWithValues: project.orderedSegments.map { ($0.uuid, $0) })
    }

    private var audioDurationMs: Int {
        project.audioDurationMs > 0 ? project.audioDurationMs : (player?.durationMs ?? 0)
    }

    /// Only the captions whose range actually changed get written.
    private var pendingIDs: [UUID] {
        order.filter { id in
            guard let segment = segmentsByID[id], let range = draft[id] else { return false }
            return range.startMs != segment.startMs || range.endMs != segment.endMs
        }
    }

    private var hasInvalidRange: Bool {
        draft.values.contains { !$0.isValid }
    }

    private var focusedIndex: Int? {
        guard let focusedID else { return nil }
        return order.firstIndex(of: focusedID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            captionList
            Divider()
            transport
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
                Text("Retime Captions")
                    .font(.headline)
                Spacer()
                if let index = focusedIndex {
                    let position: String = "\(index + 1) / \(order.count)"
                    Text(position)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !pendingIDs.isEmpty {
                    let changed: Int = pendingIDs.count
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
        .scrollPosition(id: $focusedID, anchor: .center)
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
        let startChanged = range.startMs != segment.startMs
        let endChanged = range.endMs != segment.endMs
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

    // MARK: - Transport

    private var transport: some View {
        VStack(spacing: 12) {
            if let player {
                playbackControls(player)
            }

            pendingBanner

            HStack(spacing: 10) {
                Picker("Boundary", selection: $boundary) {
                    ForEach(CaptionTimestampBoundary.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)

                Button {
                    editingBoundary = boundary
                } label: {
                    Label("Type a time…", systemImage: "keyboard")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("t", modifiers: [.command])
                .disabled(focusedID == nil)

                Spacer()

                Button {
                    guard let id = focusedID, let range = draft[id] else { return }
                    player?.clearPlaybackLimit()
                    player?.playRange(startMs: range.startMs, endMs: range.endMs)
                } label: {
                    Label("Preview", systemImage: "play.rectangle")
                }
                .buttonStyle(.bordered)
                .disabled(focusedID == nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func playbackControls(_ player: CaptionEditorAudioPlayer) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    player.clearPlaybackLimit()
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help("Play / Pause")

                Button { player.step(byMs: -1000) } label: { Image(systemName: "gobackward.1") }
                    .buttonStyle(.borderless)
                Button { player.step(byMs: 1000) } label: { Image(systemName: "goforward.1") }
                    .buttonStyle(.borderless)

                Spacer()

                let elapsed: String = CaptionExporter.vttTimestamp(player.currentMs)
                Text(elapsed)
                    .font(.body.monospacedDigit())
            }

            if audioDurationMs > 0 {
                Slider(
                    value: Binding(
                        get: { Double(player.currentMs) },
                        set: {
                            player.clearPlaybackLimit()
                            player.seek(toMs: Int($0))
                        }
                    ),
                    in: 0...Double(audioDurationMs)
                )
            }
        }
    }

    /// Restates the pending boundary next to the playhead, so the answer to "what
    /// will Space write?" is visible without looking back up at the list.
    private var pendingBanner: some View {
        let isStart = boundary == .start
        let playhead: String = CaptionExporter.vttTimestamp(player?.currentMs ?? 0)

        return HStack(spacing: 10) {
            Image(systemName: isStart ? "arrow.right.to.line" : "arrow.left.to.line")
                .foregroundStyle(Self.pending)

            VStack(alignment: .leading, spacing: 1) {
                Text("Space sets")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let index = focusedIndex {
                    let number: Int = index + 1
                    Text(isStart ? "Start of caption \(number)" : "End of caption \(number)")
                        .font(.callout.weight(.medium))
                } else {
                    Text("No caption selected")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(playhead)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(Self.pending)

            Button {
                setBoundaryToPlayhead()
            } label: {
                Text(isStart ? "Set Start" : "Set End")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.black)
                    .frame(minWidth: 76)
            }
            .buttonStyle(.borderedProminent)
            .tint(Self.pending)
            .controlSize(.large)
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(player == nil || focusedID == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Self.pending.opacity(0.12))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Self.pending.opacity(0.45))
        }
        .animation(.snappy(duration: 0.15), value: boundary)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("Close gaps shorter than 300 ms on save", isOn: $closeGapsOnSave)
                .font(.callout)

            if hasInvalidRange {
                Label(
                    "Some captions end before they start.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
            }

            Spacer()

            Button("Cancel", role: .cancel) { dismiss() }
            Button("Save \(pendingIDs.isEmpty ? "" : "(\(pendingIDs.count))")") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(pendingIDs.isEmpty || hasInvalidRange)
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
        order = segments.map(\.uuid)
        draft = Dictionary(
            uniqueKeysWithValues: segments.map {
                ($0.uuid, Range(startMs: $0.startMs, endMs: $0.endMs))
            }
        )
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
        guard let id = focusedID, var range = draft[id] else { return }
        switch which {
        case .start:
            range.startMs = max(ms, 0)
            // Keep the range valid as you go rather than blocking the save later.
            if range.endMs <= range.startMs { range.endMs = range.startMs + 1 }
        case .end:
            range.endMs = max(ms, range.startMs + 1)
        }
        draft[id] = range
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
        guard let id = focusedID, let index = order.firstIndex(of: id), index + 1 < order.count
        else { return }
        focusedID = order[index + 1]
    }

    private func focusPrevious() {
        guard let id = focusedID, let index = order.firstIndex(of: id), index > 0 else { return }
        focusedID = order[index - 1]
    }

    private func save() {
        let segments = segmentsByID
        // Snapshot the writes before touching the model: SwiftUI can rebuild this
        // view mid-save, and iterating live state while mutating it is how you get
        // half-applied edits.
        let updates: [(CaptionSegment, Range)] = pendingIDs.compactMap { id in
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
