import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MarketplaceLyricsEditor: View {
    @Binding var tracks: [MarketplaceLyricTrack]
    @State private var language = "en"
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Optional lyrics captions").font(.headline)
            Text("Import SRT or VTT captions timed to the full song. Add another language to offer a translation during playback.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(tracks) { track in
                HStack {
                    CaptionLanguagePicker(title: "Language", language: track.language) { code in
                        var updated = tracks
                        try MarketplaceLyricTrack.setLanguage(code, for: track.id, in: &updated)
                        tracks = updated
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("marketplace-lyrics-track-language-\(track.id)")
                    Text("\(track.cues.count) captions").foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") { tracks.removeAll { $0.id == track.id } }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Language code, e.g. en or zh-Hans", text: $language)
                    .accessibilityIdentifier("marketplace-lyrics-language")
                Button("Import Captions…", systemImage: "captions.bubble") { importCaptions() }
                    .accessibilityIdentifier("marketplace-lyrics-import")
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private func importCaptions() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt"), UTType(filenameExtension: "vtt")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 512_000 else { throw MarketplaceAuthoringError.invalid("Caption files must be under 500 KB.") }
            let track = try MarketplaceLyricTrack.parse(String(contentsOf: url, encoding: .utf8), language: language)
            var updated = tracks
            if let index = updated.firstIndex(where: { $0.id == track.id }) { updated[index] = track }
            else { updated.append(track) }
            guard updated.count <= 12, try JSONEncoder().encode(updated).count <= 512_000 else {
                throw MarketplaceAuthoringError.invalid("Use up to 12 languages and 500 KB of lyrics and translations.")
            }
            tracks = updated; error = nil
        } catch { self.error = error.localizedDescription }
    }
}
