import SwiftUI
import VideoEditorCore
import VideoEditorUI

/// The render sheet's caption rows: how the caption clips are delivered,
/// which languages, the sidecar file type, and the burn-in style.
struct CaptionRenderSection: View {
    @Binding var options: TimelineExporter.Options
    @Binding var captions: CaptionRenderRequest
    @Binding var style: TextStyle
    /// Original (empty string) first, then every translated language.
    let available: [String]
    let hasCaptions: Bool

    private var isEnabled: Bool { hasCaptions && !options.isAudioOnly }

    var body: some View {
        row("Captions") {
            Picker("", selection: $options.captions) {
                ForEach(TimelineExporter.CaptionDelivery.allCases, id: \.self) { delivery in
                    Text(delivery.displayName).tag(delivery)
                }
            }
            .disabled(!isEnabled)
        }
        if !hasCaptions {
            note("Place a caption project on the timeline to export captions.")
        } else if options.isAudioOnly {
            note("An audio file carries no captions.")
        } else {
            switch options.captions {
            case .burnIn:
                row("Language") {
                    Picker("", selection: $captions.burnInLanguage) {
                        ForEach(available, id: \.self) { code in
                            Text(name(code)).tag(code)
                        }
                    }
                }
                if !captions.burnInLanguage.isEmpty {
                    row("") { Toggle("Bilingual (original + translation)", isOn: $captions.burnInBilingual) }
                }
                DisclosureGroup("Caption Style") {
                    Form {
                        TextStyleEditor(style: $style)
                    }
                    .formStyle(.grouped)
                    .frame(height: 420)
                }
                .font(.callout)
                note("The style is applied to the caption clips as you change it, so the viewer shows what will be rendered.")
            case .embedded:
                languageToggles
                note("Players offer the tracks in their Subtitles menu. Font, size, weight, colours, alignment and position carry over; outlines do not.")
            case .sidecar:
                languageToggles
                row("File Type") {
                    Picker("", selection: $captions.sidecarFormat) {
                        ForEach(CaptionExportFormat.sidecarChoices) { format in
                            Text("\(format.displayName) (.\(format.fileExtension))").tag(format)
                        }
                    }
                }
                note("One file per language, named after the movie, written beside it.")
            case .none:
                EmptyView()
            }
        }
    }

    private var languageToggles: some View {
        row("Languages") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(available, id: \.self) { code in
                    Toggle(name(code), isOn: Binding(
                        get: { captions.trackLanguages.contains(code) },
                        set: { on in
                            if on {
                                if !captions.trackLanguages.contains(code) {
                                    captions.trackLanguages = available.filter { captions.trackLanguages.contains($0) || $0 == code }
                                }
                            } else if captions.trackLanguages.count > 1 {
                                captions.trackLanguages.removeAll { $0 == code }
                            }
                        }
                    ))
                    .disabled(captions.trackLanguages == [code])
                }
            }
        }
    }

    private func name(_ code: String) -> String {
        code.isEmpty ? String(localized: "Original") : CaptionTranslationAvailability.displayName(code)
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(.secondary)
            content()
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension CaptionRenderRequest {
    /// "Captions burned in (Original + 中文)", "2 subtitle tracks (English, 中文)",
    /// "2 caption files (.srt)"; nil when nothing caption-related happens.
    func summary(for delivery: TimelineExporter.CaptionDelivery) -> String? {
        func name(_ code: String) -> String { code.isEmpty ? String(localized: "Original") : CaptionTranslationAvailability.displayName(code) }
        switch delivery {
        case .burnIn:
            let languages = burnInLanguage.isEmpty ? name("") : (burnInBilingual ? "\(name("")) + \(name(burnInLanguage))" : name(burnInLanguage))
            return "Captions burned in (\(languages))"
        case .embedded:
            return "\(trackLanguages.count) subtitle track\(trackLanguages.count == 1 ? "" : "s") (\(trackLanguages.map(name).joined(separator: ", ")))"
        case .sidecar:
            return "\(trackLanguages.count) caption file\(trackLanguages.count == 1 ? "" : "s") (.\(sidecarFormat.fileExtension))"
        case .none:
            return nil
        }
    }
}
