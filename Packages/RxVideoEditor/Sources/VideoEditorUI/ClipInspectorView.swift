import SwiftUI
import VideoEditorCore

/// A language a caption clip can draw, named the way the host app names it.
/// The empty code is the transcript itself.
public struct CaptionLanguageChoice: Identifiable, Hashable, Sendable {
    public let code: String
    public let name: String

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }

    public var id: String { code }
}

/// Edits one clip: timing, fit, opacity, volume, caption languages, text style.
public struct ClipInspectorView: View {
    @Binding var timeline: Timeline
    let clipID: UUID
    /// Shown for Remotion clips whose media is stale or missing.
    let renderStatus: String?
    let onRender: (() -> Void)?
    /// What a caption clip can be drawn in, transcript first. Empty when the
    /// host has nothing to offer, which hides the language rows.
    let captionLanguages: [CaptionLanguageChoice]
    @State private var showSpeed = false
    @State private var editError: String?

    public init(timeline: Binding<Timeline>, clipID: UUID, renderStatus: String? = nil,
                captionLanguages: [CaptionLanguageChoice] = [], onRender: (() -> Void)? = nil) {
        _timeline = timeline
        self.clipID = clipID
        self.renderStatus = renderStatus
        self.captionLanguages = captionLanguages
        self.onRender = onRender
    }

    private var clip: Clip? { timeline.clip(id: clipID) }

    public var body: some View {
        if let clip {
            Form {
                Section {
                    LabeledContent("Source", value: clip.source.displayName)
                    LabeledContent("Kind", value: clip.source.kind.rawValue.capitalized)
                    if let renderStatus {
                        HStack {
                            Label(renderStatus, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Spacer()
                            if let onRender {
                                Button("Render Now", action: onRender)
                            }
                        }
                    }
                }
                Section("Timing") {
                    timecodeField("Start", value: clip.start) { newStart in
                        performEdit { try TimelineEditor.move(&timeline, clipID: clipID, to: newStart) }
                    }
                    .disabled(!clip.source.capabilities.contains(.drag))
                    timecodeField("Duration", value: clip.duration) { newDuration in
                        performEdit { try TimelineEditor.trimTrailing(&timeline, clipID: clipID, by: newDuration - clip.duration) }
                    }
                    .disabled(!clip.source.capabilities.contains(.duration))
                    if clip.source.kind != .image {
                        timecodeField("In Point", value: clip.inPoint) { newIn in
                            try? TimelineEditor.update(&timeline, clipID: clipID) { $0.inPoint = max(0, newIn) }
                        }
                    }
                    if clip.source.capabilities.contains(.speed) {
                        LabeledContent("Speed") {
                            Button("\((clip.playbackRate * 100).formatted(.number.precision(.fractionLength(0...3))))%…") { showSpeed = true }
                        }
                    }
                    if clip.source.capabilities.contains(.reverse) {
                        Toggle("Reverse", isOn: Binding(get: { clip.isReversed }, set: { _ in
                            performEdit { try TimelineEditor.reverse(&timeline, clipID: clipID) }
                        }))
                    }
                    LabeledContent("End", value: Timecode.string(seconds: clip.end, fps: timeline.fps))
                }
                if clip.source.kind.hasVideo || clip.source.kind == .image {
                    Section("Picture") {
                        Picker("Fit", selection: binding(\.transform.fit)) {
                            Text("Letterbox").tag(FitMode.fit)
                            Text("Fill").tag(FitMode.fill)
                            Text("Stretch").tag(FitMode.stretch)
                        }
                        slider("Scale", binding(\.transform.scale), in: 0.25...3)
                        slider("Offset X", binding(\.transform.offsetX), in: -0.5...0.5)
                        slider("Offset Y", binding(\.transform.offsetY), in: -0.5...0.5)
                        slider("Opacity", Binding(get: { Double(clip.opacity) }, set: { v in update { $0.opacity = Float(v) } }), in: 0...1, percent: true)
                    }
                }
                if clip.source.kind.hasAudio {
                    Section("Audio") {
                        slider("Volume", Binding(get: { Double(clip.volume) }, set: { v in update { $0.volume = Float(v) } }), in: 0...2, percent: true)
                    }
                }
                if clip.source.kind == .captions {
                    Section("Captions") {
                        if captionLanguages.count > 1 {
                            ForEach(captionLanguages) { language in
                                Toggle(language.name, isOn: languageBinding(language.code, clip: clip))
                                    // Something has to be drawn, so the last
                                    // language on cannot be turned off.
                                    .disabled(clip.captions.languages == [language.code])
                            }
                            if clip.captions.languages.count > 1 {
                                Text("Drawn on one caption, transcript first.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Toggle("Strip Punctuation", isOn: Binding(
                            get: { clip.captions.stripsPunctuation },
                            set: { on in update { $0.captions.stripsPunctuation = on } }
                        ))
                    }
                    Section("Text") {
                        TextStyleEditor(style: Binding(get: { clip.text ?? .caption }, set: { v in update { $0.text = v } }))
                    }
                }
            }
            .formStyle(.grouped)
            .popover(isPresented: $showSpeed) { ClipSpeedEditor(timeline: $timeline, clipID: clipID) }
            .alert("Couldn’t edit footage", isPresented: Binding(get: { editError != nil }, set: { if !$0 { editError = nil } })) {
                Button("OK") { editError = nil }
            } message: { Text(editError ?? "") }
        } else {
            ContentUnavailableView("No Clip Selected", systemImage: "rectangle.dashed")
        }
    }

    /// Turning a language on adds it in the order the host listed them, so a
    /// bilingual caption always reads transcript first rather than in the
    /// order the toggles happened to be clicked.
    private func languageBinding(_ code: String, clip: Clip) -> Binding<Bool> {
        Binding(
            get: { clip.captions.languages.contains(code) },
            set: { on in
                var chosen = Set(clip.captions.languages)
                if on { chosen.insert(code) } else { chosen.remove(code) }
                let ordered = captionLanguages.map(\.code).filter { chosen.contains($0) }
                update { $0.captions = CaptionOptions(languages: ordered, stripsPunctuation: $0.captions.stripsPunctuation) }
            }
        )
    }

    private func performEdit(_ edit: () throws -> Void) {
        do { try edit() } catch { editError = error.localizedDescription }
    }

    private func update(_ change: (inout Clip) -> Void) {
        try? TimelineEditor.update(&timeline, clipID: clipID, change)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Clip, T>) -> Binding<T> {
        Binding(
            get: { timeline.clip(id: clipID)![keyPath: keyPath] },
            set: { v in update { $0[keyPath: keyPath] = v } }
        )
    }

    private func slider(_ title: String, _ value: Binding<Double>, in range: ClosedRange<Double>, percent: Bool = false) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text(percent ? "\(Int((value.wrappedValue * 100).rounded())) %" : String(format: "%.2f", value.wrappedValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }

    private func timecodeField(_ title: String, value: TimeInterval, commit: @escaping (TimeInterval) -> Void) -> some View {
        TimecodeField(title: title, seconds: value, fps: timeline.fps, commit: commit)
    }
}

/// A text field showing `HH:MM:SS:FF` that commits on return or focus loss.
struct TimecodeField: View {
    let title: String
    let seconds: TimeInterval
    let fps: Int
    let commit: (TimeInterval) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .font(.system(.body, design: .monospaced))
            .focused($focused)
            .onAppear { text = Timecode.string(seconds: seconds, fps: fps) }
            .onChange(of: seconds) { _, new in if !focused { text = Timecode.string(seconds: new, fps: fps) } }
            .onSubmit { apply() }
            .onChange(of: focused) { _, isFocused in if !isFocused { apply() } }
    }

    private func apply() {
        if let parsed = Timecode.seconds(from: text, fps: fps) {
            commit(parsed)
        }
        text = Timecode.string(seconds: seconds, fps: fps)
    }
}
