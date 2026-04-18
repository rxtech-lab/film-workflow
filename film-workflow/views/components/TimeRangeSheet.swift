#if os(iOS)
import SwiftUI

struct TimeRangeButton: View {
    @Binding var startTime: TimeInterval
    @Binding var endTime: TimeInterval
    let duration: TimeInterval

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                Text(SongStructureEntry.formatTime(startTime))
                Text("–")
                    .foregroundStyle(.secondary)
                Text(SongStructureEntry.formatTime(endTime))
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.platformControlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.platformSeparator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isPresented) {
            TimeRangeSheet(
                startTime: $startTime,
                endTime: $endTime,
                duration: duration
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }
}

struct TimeRangeSheet: View {
    @Binding var startTime: TimeInterval
    @Binding var endTime: TimeInterval
    let duration: TimeInterval

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                timeLabels

                RangeSlider(
                    startTime: $startTime,
                    endTime: $endTime,
                    duration: max(duration, 1)
                )
                .frame(height: 44)
                .padding(.horizontal, 8)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .navigationTitle("Section Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var timeLabels: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Start")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(SongStructureEntry.formatTime(startTime))
                    .font(.title2.monospacedDigit().weight(.semibold))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("End")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(SongStructureEntry.formatTime(endTime))
                    .font(.title2.monospacedDigit().weight(.semibold))
            }
        }
    }
}

private struct RangeSlider: View {
    @Binding var startTime: TimeInterval
    @Binding var endTime: TimeInterval
    let duration: TimeInterval

    private let thumbSize: CGFloat = 28
    private let trackHeight: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let usable = max(width - thumbSize, 1)
            let startX = xFor(startTime, usable: usable)
            let endX = xFor(endTime, usable: usable)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(endX - startX, 0), height: trackHeight)
                    .offset(x: startX + thumbSize / 2)

                thumb
                    .offset(x: startX)
                    .gesture(dragGesture(for: .start, usable: usable))
                    .accessibilityLabel("Start time")
                    .accessibilityValue(SongStructureEntry.formatTime(startTime))

                thumb
                    .offset(x: endX)
                    .gesture(dragGesture(for: .end, usable: usable))
                    .accessibilityLabel("End time")
                    .accessibilityValue(SongStructureEntry.formatTime(endTime))
            }
            .frame(height: thumbSize)
        }
        .sensoryFeedback(.selection, trigger: Int(startTime))
        .sensoryFeedback(.selection, trigger: Int(endTime))
    }

    private var thumb: some View {
        Circle()
            .fill(Color.white)
            .frame(width: thumbSize, height: thumbSize)
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            .overlay(
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
    }

    private enum Thumb { case start, end }

    private func xFor(_ time: TimeInterval, usable: CGFloat) -> CGFloat {
        CGFloat(time / duration) * usable
    }

    private func timeFor(_ x: CGFloat, usable: CGFloat) -> TimeInterval {
        let clamped = min(max(x, 0), usable)
        let seconds = (Double(clamped) / Double(usable)) * duration
        return (seconds.rounded()).clamped(to: 0 ... duration)
    }

    private func dragGesture(for thumb: Thumb, usable: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let newTime = timeFor(value.location.x - thumbSize / 2, usable: usable)
                switch thumb {
                case .start:
                    startTime = min(newTime, endTime)
                case .end:
                    endTime = max(newTime, startTime)
                }
            }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

#Preview("Time Range Sheet") {
    @Previewable @State var start: TimeInterval = 20
    @Previewable @State var end: TimeInterval = 50

    TimeRangeSheet(startTime: $start, endTime: $end, duration: 120)
}
#endif
