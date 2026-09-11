import Foundation
import SwiftUI
import VideoEditorCore

/// Percentage and target duration are two ways to preserve and retime one range.
struct ClipSpeedEditor: View {
    @Binding var timeline: Timeline
    let clipID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var percentage = ""
    @State private var duration = ""
    @State private var mode = Mode.percentage
    @State private var error: String?
    @FocusState private var focused: Bool

    private enum Mode: String, CaseIterable { case percentage = "Speed", duration = "Target duration" }
    private var clip: Clip? { timeline.clip(id: clipID) }
    private var enteredValue: Double? {
        let text = mode == .percentage ? percentage.replacingOccurrences(of: "%", with: "") : duration
        return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private var proposedRate: Double? {
        guard let clip, let value = enteredValue, value.isFinite, value > 0 else { return nil }
        return mode == .percentage ? value / 100 : clip.sourceRangeDuration / value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change Speed").font(.headline)
            if let clip {
                Text(clip.source.displayName).foregroundStyle(.secondary).lineLimit(1)
                Picker("Set by", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack {
                    TextField(mode == .percentage ? "Speed" : "Target duration", text: mode == .percentage ? $percentage : $duration)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .accessibilityIdentifier("timeline.speed.value")
                        .onSubmit { apply() }
                    Text(mode == .percentage ? "%" : "seconds").foregroundStyle(.secondary)
                }
                if let rate = proposedRate, rate.isFinite, rate > 0 {
                    Text(mode == .percentage
                         ? "Duration: \((clip.sourceRangeDuration / rate).formatted(.number.precision(.fractionLength(0...6)))) seconds"
                         : "Speed: \((rate * 100).formatted(.number.precision(.fractionLength(0...6))))%")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("Reset to 100%") { mode = .percentage; percentage = "100" }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Apply") { apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(proposedRate == nil || !clip.source.capabilities.contains(.speed))
                        .accessibilityIdentifier("timeline.speed.apply")
                }
            }
        }
        .padding(18)
        .frame(width: 360)
        .onAppear {
            if let clip {
                percentage = String(format: "%.10g", clip.playbackRate * 100)
                duration = String(format: "%.10g", clip.duration)
            }
            focused = true
        }
    }

    private func apply() {
        guard let value = enteredValue else { return }
        do {
            if mode == .percentage {
                try TimelineEditor.changeSpeed(&timeline, clipID: clipID, rate: value / 100)
            } else {
                try TimelineEditor.retime(&timeline, clipID: clipID, duration: value)
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
