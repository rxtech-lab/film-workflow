import SwiftUI
import VideoEditorCore

public struct RecordingPresentationEditor: View {
    @Binding var value: RecordingClipPresentation
    /// Generating zooms writes clips onto a lane, which only a clip's own
    /// inspector can do; the project defaults form passes nothing.
    private let onGenerateZooms: (() -> Void)?
    public init(value: Binding<RecordingClipPresentation>, onGenerateZooms: (() -> Void)? = nil) {
        _value = value; self.onGenerateZooms = onGenerateZooms
    }
    public var body: some View {
        if let onGenerateZooms {
            Button("Generate Zooms from Clicks", action: onGenerateZooms)
                .disabled(!value.autoZoom || value.pointer.allSatisfy { !$0.clicked })
                .help(value.autoZoom ? "Adds one zoom clip per click to the recording's zoom lane."
                                     : "The clicks in this recording have already been turned into zoom clips.")
        } else {
            Toggle("Auto Zoom to Clicks", isOn: $value.autoZoom)
        }
        LabeledContent("Zoom") { Slider(value: $value.zoomScale, in: 1...5); Text("\(value.zoomScale, specifier: "%.1f")×") }
        Picker("Cursor", selection: $value.cursor) { ForEach(RecordingClipPresentation.Cursor.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
        LabeledContent("Cursor Size") { Slider(value: $value.cursorSize, in: 0.01...0.08) }
        LabeledContent("Mouse Smoothing") { Slider(value: $value.smoothing, in: 0...0.5) }
        Toggle("Show Clicks", isOn: $value.showClicks)
        Picker("Camera Shape", selection: $value.shape) { ForEach(RecordingClipPresentation.Shape.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
        LabeledContent("Camera Size") { Slider(value: $value.cameraSize, in: 0.1...0.8) }
        LabeledContent("Camera X") { Slider(value: $value.cameraX, in: 0...1) }
        LabeledContent("Camera Y") { Slider(value: $value.cameraY, in: 0...1) }
        Toggle("Camera Follows Screen Zoom", isOn: $value.cameraFollowsZoom)
        // Zooms live on the zoom lane now. These remain for films written
        // before it, whose intervals are still on the presentation.
        ForEach($value.zooms) { $zoom in
            VStack {
                HStack { TextField("Start", value: $zoom.start, format: .number); TextField("End", value: $zoom.end, format: .number); TextField("Zoom", value: $zoom.scale, format: .number) }
                HStack { TextField("Focus X", value: $zoom.x, format: .number); TextField("Focus Y", value: $zoom.y, format: .number) }
                Toggle("Follow Pointer", isOn: $zoom.followsPointer)
                Button("Remove Zoom") { value.zooms.removeAll { $0.id == zoom.id } }
            }
        }
        ForEach(Array((value.cameraKeyframes ?? []).enumerated()), id: \.element.id) { index, frame in
            HStack {
                TextField("At", value: cameraBinding(index, \.time), format: .number)
                TextField("Size", value: cameraBinding(index, \.size), format: .number)
                TextField("X", value: cameraBinding(index, \.x), format: .number)
                TextField("Y", value: cameraBinding(index, \.y), format: .number)
            }
            Picker("Shape", selection: Binding(get: { value.cameraKeyframes?[index].shape ?? frame.shape }, set: { value.cameraKeyframes?[index].shape = $0 })) { ForEach(RecordingClipPresentation.Shape.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Button("Remove Camera Change") { value.cameraKeyframes?.removeAll { $0.id == frame.id } }
        }
        Button("Add Camera Change") { var frames = value.cameraKeyframes ?? []; frames.append(.init(time: (frames.last?.time ?? 0) + 1, size: value.cameraSize, x: value.cameraX, y: value.cameraY, shape: value.shape)); value.cameraKeyframes = frames }
        Button("Add Zoom Interval") { value.zooms.append(.init(start: 0, end: 2)) }
        ForEach($value.visibility) { $interval in
            HStack { TextField("Start", value: $interval.start, format: .number); TextField("End", value: $interval.end, format: .number); Toggle("Visible", isOn: $interval.visible) }
            Button("Remove Visibility Interval") { value.visibility.removeAll { $0.id == interval.id } }
        }
        Button("Add Visibility Interval") { value.visibility.append(.init(start: 0, end: 1, visible: false)) }
    }
    private func cameraBinding(_ index: Int, _ key: WritableKeyPath<RecordingCameraKeyframe, Double>) -> Binding<Double> { Binding(get: { value.cameraKeyframes?[index][keyPath: key] ?? 0 }, set: { value.cameraKeyframes?[index][keyPath: key] = $0 }) }
}
