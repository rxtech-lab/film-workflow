import AppKit
import Combine
import CoreText
import SwiftUI
import VideoEditorCore

/// Every caption style control, as rows for a `Form` section. The clip
/// inspector, the caption project's Style tab and the render sheet all use
/// this one view, so what the editor can style is exactly what the export
/// can render.
public struct TextStyleEditor: View {
    @Binding var style: TextStyle

    public init(style: Binding<TextStyle>) {
        _style = style
    }

    /// Re-read whenever a font is registered or removed in this process, so a
    /// font installed from the marketplace shows up without a relaunch.
    @State private var families: [String] = TextStyleEditor.currentFamilies()

    private static func currentFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private static let fontsChanged = Notification.Name(kCTFontManagerRegisteredFontsChangedNotification as String)

    public var body: some View {
        Picker("Font", selection: $style.fontName) {
            if !families.contains(style.fontName) {
                Text(style.fontName).tag(style.fontName)
                Divider()
            }
            ForEach(families, id: \.self) { family in
                Text(family).tag(family)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.fontsChanged).receive(on: RunLoop.main)) { _ in
            families = Self.currentFamilies()
        }
        slider("Size", $style.fontSize, in: 0.02...0.12)
        HStack {
            Toggle("Bold", isOn: $style.bold)
            Toggle("Italic", isOn: $style.italic)
        }
        Picker("Alignment", selection: $style.alignment) {
            Image(systemName: "text.alignleft").tag(CaptionAlignment.leading)
            Image(systemName: "text.aligncenter").tag(CaptionAlignment.center)
            Image(systemName: "text.alignright").tag(CaptionAlignment.trailing)
        }
        .pickerStyle(.segmented)
        ColorPicker("Text Color", selection: color($style.colorHex, fallback: .white), supportsOpacity: false)
        ColorPicker("Background", selection: color($style.backgroundHex, fallback: .black), supportsOpacity: false)
        slider("Background Opacity", $style.backgroundOpacity, in: 0...1)
        slider("Position", $style.verticalPosition, in: 0...1)
        slider("Outline", $style.strokeWidth, in: 0...0.15)
        if style.strokeWidth > 0 {
            ColorPicker("Outline Color", selection: color($style.strokeHex, fallback: .black), supportsOpacity: false)
        }
    }

    private func slider(_ title: LocalizedStringKey, _ value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text("\(Int((value.wrappedValue * 100).rounded())) %")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }

    /// Hex text in the model, a `Color` for the picker.
    private func color(_ hex: Binding<String>, fallback: NSColor) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hex: hex.wrappedValue) ?? fallback) },
            set: { hex.wrappedValue = NSColor($0).hexString }
        )
    }
}
