import SwiftUI
import VideoEditorCore
import VideoEditorUI

/// The render sheet's Captions tab: how the caption clips reach the movie,
/// which languages, the burn-in style, and whether caption files (with their
/// translations) are also saved beside it.
struct CaptionRenderSection: View {
    @Binding var options: TimelineExporter.Options
    @Binding var captions: CaptionRenderRequest
    @Binding var style: TextStyle
    /// Original (empty string) first, then every translated language.
    let available: [String]
    let hasCaptions: Bool

    private var isEnabled: Bool { hasCaptions && !options.isAudioOnly }

    /// Files have their own section, so the movie picker leaves them out.
    private static let movieDeliveries: [TimelineExporter.CaptionDelivery] = [.burnIn, .embedded, .none]

    var body: some View {
        if !hasCaptions {
            note("Place a caption project on the timeline to export captions.")
        }
        row("In Movie") {
            Picker("", selection: $options.captions) {
                ForEach(Self.movieDeliveries, id: \.self) { delivery in
                    Text(delivery.displayName).tag(delivery)
                }
            }
            .labelsHidden()
            .disabled(!isEnabled)
        }
        if hasCaptions {
            if options.isAudioOnly {
                note("An audio file carries no captions. Caption files can still be saved beside it.")
            } else {
                switch options.captions {
                case .burnIn:
                    row("Language") {
                        Picker("", selection: $captions.burnInLanguage) {
                            ForEach(available, id: \.self) { code in
                                Text(name(code)).tag(code)
                            }
                        }
                        .labelsHidden()
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
                    languageToggles($captions.trackLanguages)
                    note("Players offer the tracks in their Subtitles menu. Font, size, weight, colours, alignment and position carry over; outlines do not.")
                case .sidecar, .none:
                    EmptyView()
                }
            }
        }
        Divider().padding(.vertical, 4)
        Toggle(isOn: $captions.savesFiles) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Save Caption Files")
                Text("Also write SRT or VTT files beside the movie, one per language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .disabled(!hasCaptions)
        if hasCaptions && captions.savesFiles {
            languageToggles($captions.fileLanguages)
            row("File Type") {
                Picker("", selection: $captions.sidecarFormat) {
                    ForEach(CaptionExportFormat.sidecarChoices) { format in
                        Text("\(format.displayName) (.\(format.fileExtension))").tag(format)
                    }
                }
                .labelsHidden()
            }
            note("Files are named after the movie. Translations without text are skipped.")
        }
    }

    private func languageToggles(_ selection: Binding<[String]>) -> some View {
        row("Languages") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(available, id: \.self) { code in
                    Toggle(name(code), isOn: Binding(
                        get: { selection.wrappedValue.contains(code) },
                        set: { on in
                            if on {
                                if !selection.wrappedValue.contains(code) {
                                    selection.wrappedValue = available.filter { selection.wrappedValue.contains($0) || $0 == code }
                                }
                            } else if selection.wrappedValue.count > 1 {
                                selection.wrappedValue.removeAll { $0 == code }
                            }
                        }
                    ))
                    .disabled(selection.wrappedValue == [code])
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
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension CaptionRenderRequest {
    /// "Captions burned in (Original + 中文)", "2 subtitle tracks (English, 中文)",
    /// "2 caption files (.srt)", joined when files accompany the movie; nil
    /// when nothing caption-related happens.
    func summary(for delivery: TimelineExporter.CaptionDelivery) -> String? {
        func name(_ code: String) -> String { code.isEmpty ? String(localized: "Original") : CaptionTranslationAvailability.displayName(code) }
        var parts: [String] = []
        switch delivery {
        case .burnIn:
            let languages = burnInLanguage.isEmpty ? name("") : (burnInBilingual ? "\(name("")) + \(name(burnInLanguage))" : name(burnInLanguage))
            parts.append("Captions burned in (\(languages))")
        case .embedded:
            parts.append("\(trackLanguages.count) subtitle track\(trackLanguages.count == 1 ? "" : "s") (\(trackLanguages.map(name).joined(separator: ", ")))")
        case .sidecar, .none:
            break
        }
        if writesFiles(for: delivery) {
            let languages = fileLanguages(for: delivery)
            parts.append("\(languages.count) caption file\(languages.count == 1 ? "" : "s") (\(languages.map(name).joined(separator: ", ")), .\(sidecarFormat.fileExtension))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
