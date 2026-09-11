import AppKit
import SwiftUI
import VideoEffectsCore

/// Sliders keep a local value for the whole gesture and commit only on release.
public struct ModifierParameterEditor: View {
    let definition: any ModifierDefinition
    @Binding var parameters: ModifierParameters
    public init(definition: any ModifierDefinition, parameters: Binding<ModifierParameters>) {
        self.definition = definition; _parameters = parameters
    }
    public var body: some View {
        ForEach(definition.parameters) { descriptor in
            let current = parameters[descriptor.id] ?? descriptor.defaultValue
            switch descriptor.control {
            case .number(let range, let step):
                if case .number(let value) = current {
                    CommittingSlider(title: descriptor.title, value: value, range: range, step: step) {
                        parameters[descriptor.id] = .number($0)
                    }
                }
            case .choice(let choices):
                Picker(descriptor.title, selection: Binding(get: {
                    if case .string(let value) = current { return value }; return choices.first ?? ""
                }, set: { parameters[descriptor.id] = .string($0) })) {
                    ForEach(choices, id: \.self) { Text($0).tag($0) }
                }
            case .color:
                CommittingColorField(title: descriptor.title, value: {
                    if case .string(let value) = current { return value }; return "#000000"
                }()) { parameters[descriptor.id] = .string($0) }
            }
        }
    }
}

private struct CommittingSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let commit: (Double) -> Void
    @State private var draft: Double?
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text((draft ?? value).formatted(.number.precision(.fractionLength(0...2)))).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, draft ?? value)) }, set: { draft = $0 }), in: range, step: step) { editing in
                if !editing, let draft { commit(draft); self.draft = nil }
            }.accessibilityLabel(title)
        }.onChange(of: value) { _, _ in draft = nil }
    }
}

/// Presets and a hex field allow arbitrary colors without recording each keystroke.
private struct CommittingColorField: View {
    let title: String
    let value: String
    let commit: (String) -> Void
    @State private var draft: String?
    @FocusState private var focused: Bool
    private let presets = [("Black", "#000000"), ("White", "#FFFFFF"), ("Red", "#FF0000"), ("Blue", "#0000FF")]
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Menu("Preset") {
                ForEach(presets, id: \.1) { name, hex in
                    Button(name) { draft = nil; commit(hex) }
                }
            }.fixedSize()
            TextField("#RRGGBB", text: Binding(get: { draft ?? value }, set: { draft = $0 }))
                .frame(width: 85).focused($focused).onSubmit(submit)
                .accessibilityLabel("\(title) hex value")
                .help("A six-digit RGB color, such as #204080")
        }
        .onChange(of: focused) { _, active in if !active { submit() } }
        .onChange(of: value) { _, _ in draft = nil }
    }
    private func submit() {
        guard let draft else { return }
        let hex = draft.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if digits.count == 6, digits.allSatisfy({ $0.isHexDigit }) { commit("#" + digits) }
        self.draft = nil
    }
}
