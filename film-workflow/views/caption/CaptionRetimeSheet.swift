import SwiftData
import SwiftUI

/// Karaoke-style bulk retimer.
///
/// Ported from debate-bot's `TranscriptSegmentRetimeSheet`. The workflow is: play
/// the audio, and tap one button as each caption starts and ends. Setting a start
/// auto-advances to that caption's end; setting an end auto-advances to the next
/// caption. That reduces retiming a whole transcript to a single repeated
/// keystroke instead of hundreds of individual time entries.
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            captionList
            Divider()
            controls
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 620)
        // A long session accumulates an unsaved draft; don't let a stray Escape
        // or drag throw it away. Cancel is the deliberate way out.
        .interactiveDismissDisabled()
        .onAppear(perform: load)
        .onDisappear { player?.pause() }
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
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Retime Captions")
                    .font(.headline)
                Spacer()
                if !pendingIDs.isEmpty {
                    Text("\(pendingIDs.count) changed")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
            Text("Play the audio, then set each caption's start and end as you hear it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

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

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                // Precomputed into explicitly-typed locals: interpolating these calls
                // inside a Text initializer sends the type-checker exponential here.
                // Start and end are separate Texts so only the edited side lights up.
                let startLabel: String = CaptionExporter.vttTimestamp(range.startMs)
                let endLabel: String = CaptionExporter.vttTimestamp(range.endMs)
                HStack(spacing: 4) {
                    Text(startLabel)
                        .foregroundStyle(timestampColor(changed: startChanged, valid: range.isValid))
                    Text(verbatim: "→")
                        .foregroundStyle(Color.secondary)
                    Text(endLabel)
                        .foregroundStyle(timestampColor(changed: endChanged, valid: range.isValid))
                }
                .font(.caption.monospacedDigit())

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

    private var controls: some View {
        VStack(spacing: 10) {
            if let player {
                HStack(spacing: 12) {
                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)

                    Button { player.step(byMs: -1000) } label: { Image(systemName: "gobackward.1") }
                        .buttonStyle(.borderless)
                    Button { player.step(byMs: 1000) } label: { Image(systemName: "goforward.1") }
                        .buttonStyle(.borderless)

                    Spacer()

                    Text(CaptionExporter.vttTimestamp(player.currentMs))
                        .font(.body.monospacedDigit())
                }

                if audioDurationMs > 0 {
                    Slider(
                        value: Binding(
                            get: { Double(player.currentMs) },
                            set: { player.seek(toMs: Int($0)) }
                        ),
                        in: 0...Double(audioDurationMs)
                    )
                }
            }

            Picker("Boundary", selection: $boundary) {
                ForEach(CaptionTimestampBoundary.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.segmented)

            // The one button that does the work.
            Button {
                setBoundaryToPlayhead()
            } label: {
                Label(
                    boundary == .start ? "Set Start to Current Time" : "Set End to Current Time",
                    systemImage: "playhead.and.waveform"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(player == nil || focusedID == nil)

            HStack {
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

    private var footer: some View {
        VStack(spacing: 8) {
            Toggle("Close gaps shorter than 300 ms on save", isOn: $closeGapsOnSave)
                .font(.callout)

            HStack {
                if hasInvalidRange {
                    Label("Some captions end before they start.", systemImage: "exclamationmark.triangle.fill")
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        #if os(macOS)
        .onKeyPress(.space) {
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
        guard let player else { return }
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
        project.updatedAt = Date()
        dismiss()
    }
}
