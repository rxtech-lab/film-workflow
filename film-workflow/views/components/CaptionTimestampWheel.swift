import SwiftUI

/// Which end of a caption a timestamp edit applies to.
nonisolated enum CaptionTimestampBoundary: String, CaseIterable, Identifiable, Sendable {
    case start
    case end

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .start: return "Start"
        case .end: return "End"
        }
    }
}

/// An HH : MM : SS . mmm wheel picker.
///
/// Millisecond precision is the point — caption timing is judged at that
/// resolution, and a seconds-only picker makes precise retiming impossible. The
/// hours column only appears past an hour so short files aren't cluttered by a
/// column that can only ever read zero.
struct CaptionTimestampWheel: View {
    @Binding var totalMs: Int
    /// Upper bound, normally the audio duration. 0 means unbounded.
    var maxMs: Int = 0

    private var showsHours: Bool { maxMs >= 3_600_000 }

    private var maxHours: Int {
        maxMs > 0 ? min(maxMs / 3_600_000, 23) : 23
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsHours {
                column(
                    range: 0...maxHours,
                    selection: hoursBinding,
                    label: "h",
                    width: 58
                )
                separator(":")
            }
            column(range: 0...59, selection: minutesBinding, label: "m", width: 58)
            separator(":")
            column(range: 0...59, selection: secondsBinding, label: "s", width: 58)
            separator(".")
            column(range: 0...999, selection: millisBinding, label: "ms", width: 72, digits: 3)
        }
        .frame(height: 132)
    }

    @ViewBuilder
    private func column(
        range: ClosedRange<Int>,
        selection: Binding<Int>,
        label: String,
        width: CGFloat,
        digits: Int = 2
    ) -> some View {
        VStack(spacing: 2) {
            Picker(label, selection: selection) {
                ForEach(Array(range), id: \.self) { value in
                    Text(String(format: "%0\(digits)d", value)).tag(value)
                }
            }
            .labelsHidden()
            #if os(iOS)
            .pickerStyle(.wheel)
            #endif
            .frame(width: width)

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func separator(_ text: String) -> some View {
        Text(text)
            .font(.title3.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
            .padding(.bottom, 14)
    }

    // MARK: - Component bindings

    /// Each column reads its slice out of `totalMs` and writes the whole value
    /// back, so the binding stays a single source of truth and can't drift.
    private var hoursBinding: Binding<Int> {
        Binding(
            get: { clamped(totalMs) / 3_600_000 },
            set: { setComponent(hours: $0) }
        )
    }

    private var minutesBinding: Binding<Int> {
        Binding(
            get: { (clamped(totalMs) % 3_600_000) / 60_000 },
            set: { setComponent(minutes: $0) }
        )
    }

    private var secondsBinding: Binding<Int> {
        Binding(
            get: { (clamped(totalMs) % 60_000) / 1000 },
            set: { setComponent(seconds: $0) }
        )
    }

    private var millisBinding: Binding<Int> {
        Binding(
            get: { clamped(totalMs) % 1000 },
            set: { setComponent(millis: $0) }
        )
    }

    private func setComponent(
        hours: Int? = nil,
        minutes: Int? = nil,
        seconds: Int? = nil,
        millis: Int? = nil
    ) {
        let current = clamped(totalMs)
        let h = hours ?? current / 3_600_000
        let m = minutes ?? (current % 3_600_000) / 60_000
        let s = seconds ?? (current % 60_000) / 1000
        let ms = millis ?? current % 1000
        totalMs = clamped(h * 3_600_000 + m * 60_000 + s * 1000 + ms)
    }

    private func clamped(_ value: Int) -> Int {
        let lower = max(value, 0)
        return maxMs > 0 ? min(lower, maxMs) : lower
    }
}

/// A sheet wrapper around the wheel, with a "use the playhead" shortcut.
struct CaptionTimestampPickerSheet: View {
    let title: LocalizedStringKey
    @Binding var totalMs: Int
    var maxMs: Int = 0
    /// Current playhead position, offered as a one-tap value.
    var currentAudioMs: Int?
    let onDone: () -> Void

    @State private var draft: Int = 0

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.headline)

            Text(CaptionExporter.vttTimestamp(draft))
                .font(.system(.title2, design: .monospaced))

            CaptionTimestampWheel(totalMs: $draft, maxMs: maxMs)

            if let currentAudioMs {
                Button {
                    draft = currentAudioMs
                } label: {
                    Label(
                        "Use current audio time (\(CaptionExporter.shortTimestamp(currentAudioMs)))",
                        systemImage: "playhead.and.waveform"
                    )
                }
                .buttonStyle(.bordered)
            }

            HStack {
                Button("Cancel", role: .cancel) { onDone() }
                Spacer()
                Button("Set") {
                    totalMs = draft
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 340)
        .onAppear { draft = totalMs }
    }
}
