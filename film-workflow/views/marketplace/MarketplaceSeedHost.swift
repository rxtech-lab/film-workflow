#if os(macOS)
import SwiftData
import SwiftUI
import VideoEditorCore

/// What a surface asks to publish.
///
/// Turning one of these into a draft can be slow — archiving a project, then
/// rendering a frame out of it — so surfaces state the intent and let
/// `MarketplaceSeedHost` do the work behind a progress overlay.
enum MarketplaceSeedRequest: Identifiable, Hashable {
    /// Anything whose content is the file already sitting in the film.
    case file(title: String, sourceKind: SourceKind, file: URL?)
    /// A Remotion composition, which publishes its source rather than a render.
    /// `renderID` nil means "whichever render the surface is showing", i.e. the newest.
    case remotion(title: String, projectID: UUID, renderID: UUID?)

    var id: String {
        switch self {
        case .file(let title, let kind, let file): return "file:\(kind.rawValue):\(title):\(file?.path ?? "")"
        case .remotion(_, let projectID, let renderID): return "remotion:\(projectID):\(renderID?.uuidString ?? "latest")"
        }
    }
}

/// Gives any surface the "Create Marketplace Item…" behaviour: preparing the
/// seed, saying so while it works, reporting what went wrong, and presenting
/// the editor. Attach once per surface and drive it with a request binding.
///
/// This exists so the six places that offer the action share one implementation
/// of the slow and failure-prone half, rather than each carrying its own sheet,
/// alert and staging logic.
struct MarketplaceSeedHost: ViewModifier {
    @Binding var request: MarketplaceSeedRequest?
    @Environment(\.modelContext) private var modelContext

    @State private var seed: MarketplaceAuthoringSeed?
    @State private var error: String?
    @State private var preparing = false

    func body(content: Content) -> some View {
        content
            .task(id: request) { await prepare() }
            .overlay { if preparing { progress } }
            .sheet(item: $seed) { MarketplaceAuthoringEditor(seed: $0) }
            .alert("Couldn’t Create a Marketplace Item", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
    }

    private var progress: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Preparing the item…").font(.callout)
            Text("Archiving the composition and rendering its first frame.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("marketplace-seed-progress")
    }

    private func prepare() async {
        guard let request else { return }
        self.request = nil
        preparing = true
        defer { preparing = false }
        do {
            switch request {
            case .file(let title, let sourceKind, let file):
                guard var value = MarketplaceAuthoringSeed(title: title, sourceKind: sourceKind, file: file) else {
                    throw MarketplaceSeedError.noSlot(hasFile: file != nil)
                }
                if sourceKind == .audio, let file {
                    let tracks = try MusicLyrics.tracks(forAudioURL: file, context: modelContext)
                    if !tracks.isEmpty { value.metadata.lyricTracks = tracks }
                }
                seed = value
            case .remotion(let title, let projectID, let renderID):
                seed = try await MarketplaceAuthoringSeed.remotion(
                    title: title, projectID: projectID, renderID: renderID, context: modelContext)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension View {
    /// See `MarketplaceSeedHost`. Set the binding to offer an item; the host
    /// clears it once it has taken the request.
    func marketplaceSeedHost(_ request: Binding<MarketplaceSeedRequest?>) -> some View {
        modifier(MarketplaceSeedHost(request: request))
    }
}

enum MarketplaceSeedError: LocalizedError {
    case noSlot(hasFile: Bool)
    case missingProject
    case notRendered

    var errorDescription: String? {
        switch self {
        case .noSlot(let hasFile):
            return hasFile
                ? String(localized: "The marketplace has no slot for this clip’s file.")
                : String(localized: "This clip has no file to upload yet. Render it first.")
        case .missingProject:
            return String(localized: "This composition could not be found in the film.")
        case .notRendered:
            return String(localized: "Render this composition before publishing it, so the listing has a preview to show.")
        }
    }
}

extension MarketplaceAuthoringSeed {
    /// Builds a Remotion draft: archive the project, render frame 0 out of that
    /// archive, and stage its newest render as the preview video.
    ///
    /// Frame 0 comes from the extracted archive rather than the film's own
    /// project directory for two reasons: rendering from a project scaffolds
    /// files into it and writes stills under `.agent-stills`, which would mean
    /// publishing mutates the film; and rendering from the archive proves it is
    /// complete and self-contained before a byte of it is uploaded.
    @MainActor
    static func remotion(title: String, projectID: UUID, renderID: UUID?, context: ModelContext) async throws -> MarketplaceAuthoringSeed {
        guard let project = try? context.fetch(FetchDescriptor<RemotionProject>(predicate: #Predicate { $0.id == projectID })).first else {
            throw MarketplaceSeedError.missingProject
        }
        let renders = RemotionRenderService.renders(for: project, context: context)
        guard let render = renderID.flatMap({ id in renders.first { $0.id == id } }) ?? renders.first else {
            throw MarketplaceSeedError.notRendered
        }

        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("MarketplaceRemotion-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let archive = staging.appendingPathComponent("\(sanitized(project.name)).zip")
        let descriptor = try RemotionProjectArchive.write(
            project: project.projectDir, descriptor: .init(project: project), to: archive)

        // Round-trip the archive, then render out of the copy.
        let unpacked = staging.appendingPathComponent("source", isDirectory: true)
        try RemotionProjectArchive.read(archive: archive, into: unpacked)
        let cover = try await RemotionStillCapture.still(
            projectDir: unpacked, frame: 0,
            width: descriptor.compositionWidth, height: descriptor.compositionHeight,
            runId: "marketplace-cover")

        // The render is the film's own file, so it is copied rather than moved.
        let preview = staging.appendingPathComponent("preview.\(render.videoURL.pathExtension)")
        try fm.copyItem(at: render.videoURL, to: preview)

        var metadata = MarketplaceItemMetadata()
        metadata.width = descriptor.compositionWidth
        metadata.height = descriptor.compositionHeight
        metadata.durationSeconds = descriptor.durationSeconds > 0 ? descriptor.durationSeconds : render.durationSeconds
        let prompt = descriptor.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { metadata.promptExcerpt = String(prompt.prefix(400)) }

        return MarketplaceAuthoringSeed(
            title: title, kind: .remotion, contentFile: archive,
            previewVideo: preview, previewImage: cover,
            metadata: metadata, stagingDirectory: staging)
    }

    /// A filename-safe version of a composition's name, for the archive.
    private static func sanitized(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
        return cleaned.isEmpty ? "composition" : String(cleaned.prefix(60))
    }
}
#endif
