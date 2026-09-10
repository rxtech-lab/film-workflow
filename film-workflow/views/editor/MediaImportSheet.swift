import AVFoundation
import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Asks whether dropped files should be copied into the film or referenced.
struct MediaImportSheet: View {
    let urls: [URL]
    let groupID: UUID?
    let onDone: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.projectStorage) private var storage
    @State private var copyIntoFilm = true
    @State private var isImporting = false
    @State private var errorMessage: String?

    private var supported: [URL] {
        urls.filter { Self.kind(of: $0) != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import \(supported.count) file\(supported.count == 1 ? "" : "s")")
                .font(.headline)
            List(supported, id: \.self) { url in
                Label(url.lastPathComponent, systemImage: Self.kind(of: url)?.systemImage ?? "doc")
            }
            .frame(height: min(200, CGFloat(supported.count) * 26 + 20))
            Picker("Storage", selection: $copyIntoFilm) {
                Text("Copy into the film").tag(true)
                Text("Leave in place (reference)").tag(false)
            }
            .pickerStyle(.radioGroup)
            Text(copyIntoFilm
                 ? "The film stays self-contained and portable. Large footage takes space twice."
                 : "The film stays small, but breaks if the original file moves.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button(isImporting ? "Importing…" : "Import") { Task { await runImport() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isImporting || supported.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    static func kind(of url: URL) -> ImportedAssetKind? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) { return .image }
        return nil
    }

    private func runImport() async {
        isImporting = true
        defer { isImporting = false }
        for url in supported {
            guard let kind = Self.kind(of: url) else { continue }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let asset = ImportedAsset(name: url.deletingPathExtension().lastPathComponent, kind: kind, originalPath: url.path)
            asset.groupID = groupID
            do {
                if copyIntoFilm {
                    asset.relativePath = try storage.copyFile(from: url, kind: .imported, fallbackExtension: kind == .image ? "png" : "mp4")
                } else {
                    // Security-scoped bookmarks need the sandbox; the plain kind is the fallback.
                    if let scoped = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                        asset.bookmarkData = scoped
                        asset.bookmarkIsSecurityScoped = true
                    } else {
                        asset.bookmarkData = try url.bookmarkData()
                        asset.bookmarkIsSecurityScoped = false
                    }
                }
                let mediaURL = asset.relativePath.map(storage.absoluteURL(for:)) ?? url
                switch kind {
                case .video:
                    if let probed = await VideoThumbnailer.probe(url: mediaURL) {
                        asset.width = probed.width; asset.height = probed.height; asset.durationSeconds = probed.duration
                    }
                    asset.thumbnailFilePath = await VideoThumbnailer.generate(for: mediaURL, storage: storage)
                case .audio:
                    let seconds = CMTimeGetSeconds(AVURLAsset(url: mediaURL).duration)
                    asset.durationSeconds = seconds.isFinite ? seconds : 0
                case .image:
                    if let image = NSImage(contentsOf: mediaURL) {
                        asset.width = Int(image.size.width); asset.height = Int(image.size.height)
                    }
                }
                modelContext.insert(asset)
            } catch {
                errorMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
                return
            }
        }
        try? modelContext.save()
        onDone()
    }
}
