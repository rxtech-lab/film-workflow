import SwiftUI
import VideoEffectsCore
import VideoEffectsUI

/// Common filters have native controls; the complete descriptor remains editable for advanced authors.
struct MarketplaceModifierEditor: View {
    let kind: MarketplaceKind
    @Binding var text: String
    @State private var preset = ""
    private var descriptor: CIFilterModifierDescriptor? { try? CIFilterModifierDescriptor.decode(Data(text.utf8)) }
    private var choices: [(String, String)] {
        kind == .transition ? [("CIDissolveTransition", "Dissolve"), ("CISwipeTransition", "Swipe"), ("CIBarsSwipeTransition", "Bars Swipe")]
        : [("CIVignette", "Vignette"), ("CISepiaTone", "Sepia"), ("CIGaussianBlur", "Soft Blur"), ("CIColorControls", "Color Controls")]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Start with", selection: $preset) { Text("Choose an effect or transition").tag(""); ForEach(choices, id: \.0) { Text($0.1).tag($0.0) } }
                .onChange(of: preset) { if !preset.isEmpty { save(starter(preset)) } }
            if let descriptor {
                TextField("Effect name", text: Binding(get: { descriptor.name }, set: { var next = descriptor; next.name = $0; save(next) }))
                let definition: any ModifierDefinition = kind == .effect ? CIFilterEffect(descriptor) as any ModifierDefinition : CIFilterTransition(descriptor) as any ModifierDefinition
                ModifierParameterEditor(definition: definition, parameters: Binding(get: { definition.defaults }, set: { values in
                    var next = descriptor
                    for index in next.parameters.indices { if let value = values[next.parameters[index].id] { next.parameters[index].defaultValue = value } }
                    save(next)
                }))
                Text(descriptor.summary).font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Advanced definition") { TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(minHeight: 180).border(.quaternary) }
        }
    }
    private func save(_ value: CIFilterModifierDescriptor) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) { text = String(decoding: data, as: UTF8.self) }
    }
    private func starter(_ filter: String) -> CIFilterModifierDescriptor {
        let name = choices.first { $0.0 == filter }?.1 ?? filter
        var value = CIFilterModifierDescriptor(id: descriptor?.id ?? "mp.\(UUID().uuidString.lowercased())", kind: kind == .transition ? .transition : .effect, name: name, filter: filter)
        func number(_ id: String, _ title: String, _ key: String, _ min: Double, _ max: Double, _ initial: Double) -> CIFilterModifierDescriptor.Parameter {
            .init(id: id, title: title, filterKey: key, control: .number(min: min, max: max, step: (max - min) / 100), defaultValue: .number(initial))
        }
        if kind == .transition { value.progressKey = "inputTime"; value.progressCurve = .easeInOut }
        switch filter {
        case "CIVignette": value.parameters = [number("intensity", "Intensity", "inputIntensity", 0, 1, 0.5), number("radius", "Radius", "inputRadius", 0, 2, 1)]
        case "CISepiaTone": value.parameters = [number("intensity", "Intensity", "inputIntensity", 0, 1, 0.7)]
        case "CIGaussianBlur": value.clampEdges = true; value.parameters = [number("radius", "Blur radius", "inputRadius", 0, 40, 8)]
        case "CIColorControls": value.parameters = [number("saturation", "Saturation", "inputSaturation", 0, 2, 1), number("brightness", "Brightness", "inputBrightness", -1, 1, 0), number("contrast", "Contrast", "inputContrast", 0.25, 2, 1)]
        case "CISwipeTransition", "CIBarsSwipeTransition": value.parameters = [number("angle", "Angle", "inputAngle", 0, 6.283, 0), number("width", "Width", "inputWidth", 1, 200, 30)]
        default: break
        }
        return value
    }
}
