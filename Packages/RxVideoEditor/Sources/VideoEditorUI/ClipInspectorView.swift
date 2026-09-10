import SwiftUI
import VideoEditorCore

/// Edits one clip: timing, fit, opacity, volume, text style.
public struct ClipInspectorView: View {
    @Binding var timeline: Timeline
    let clipID: UUID
    /// Shown for Remotion clips whose media is stale or missing.
    let renderStatus: String?
    let onRender: (() -> Void)?

    public init(timeline: Binding<Timeline>, clipID: UUID, renderStatus: String? = nil, onRender: (() -> Void)? = nil) {
        _timeline = timeline
        self.clipID = clipID
        self.renderStatus = renderStatus
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
                        try? TimelineEditor.move(&timeline, clipID: clipID, to: newStart)
                    }
                    timecodeField("Duration", value: clip.duration) { newDuration in
                        try? TimelineEditor.trimTrailing(&timeline, clipID: clipID, by: newDuration - clip.duration)
                    }
                    if clip.source.kind != .image {
                        timecodeField("In Point", value: clip.inPoint) { newIn in
                            try? TimelineEditor.update(&timeline, clipID: clipID) { $0.inPoint = max(0, newIn) }
                        }
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
                    Section("Text") {
                        let style = Binding(get: { clip.text ?? .caption }, set: { v in update { $0.text = v } })
                        TextField("Font", text: style.fontName)
                        slider("Size", style.fontSize, in: 0.02...0.12, percent: true)
                        slider("Position", style.verticalPosition, in: 0...1, percent: true)
                        slider("Background", style.backgroundOpacity, in: 0...1, percent: true)
                        Toggle("Bold", isOn: style.bold)
                        TextField("Color", text: style.colorHex)
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("No Clip Selected", systemImage: "rectangle.dashed")
        }
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
