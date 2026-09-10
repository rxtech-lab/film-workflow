import SwiftUI
import VideoEditorCore

/// Frame size, rate and background of a sequence.
public struct SequenceSettingsView: View {
    @Binding var timeline: Timeline

    public init(timeline: Binding<Timeline>) {
        _timeline = timeline
    }

    public struct SizePreset: Identifiable, Hashable, Sendable {
        public let name: String
        public let width: Int
        public let height: Int
        public var id: String { "\(width)x\(height)" }

        public static let all: [SizePreset] = [
            SizePreset(name: "1080p (1920 × 1080)", width: 1920, height: 1080),
            SizePreset(name: "4K (3840 × 2160)", width: 3840, height: 2160),
            SizePreset(name: "720p (1280 × 720)", width: 1280, height: 720),
            SizePreset(name: "Vertical 1080 × 1920", width: 1080, height: 1920),
            SizePreset(name: "Square 1080 × 1080", width: 1080, height: 1080),
        ]
    }

    public var body: some View {
        Section("Sequence") {
            Picker("Resolution", selection: Binding(
                get: { "\(timeline.width)x\(timeline.height)" },
                set: { id in
                    if let preset = SizePreset.all.first(where: { $0.id == id }) {
                        var updated = timeline
                        updated.width = preset.width
                        updated.height = preset.height
                        timeline = updated
                    }
                }
            )) {
                ForEach(SizePreset.all) { preset in
                    Text(preset.name).tag(preset.id)
                }
                if !SizePreset.all.contains(where: { $0.width == timeline.width && $0.height == timeline.height }) {
                    Text("\(timeline.width) × \(timeline.height)").tag("\(timeline.width)x\(timeline.height)")
                }
            }
            Picker("Frame Rate", selection: $timeline.fps) {
                ForEach([24, 25, 30, 50, 60], id: \.self) { Text("\($0) fps").tag($0) }
            }
            TextField("Background", text: $timeline.backgroundHex)
            LabeledContent("Duration", value: Timecode.string(seconds: timeline.duration, fps: timeline.fps))
        }
    }
}
