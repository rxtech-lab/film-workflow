import AppKit
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Tracks open films and drives New / Open / Recent.
///
/// The scene layer installs `openWindowRequest` so that a URL arriving from
/// Finder, the Welcome window, or a menu command becomes an editor window; a
/// request that arrives before the scene exists is queued.
@MainActor
@Observable
final class ProjectDocumentController {
    static let shared = ProjectDocumentController()

    private(set) var openDocuments: [ProjectDocument] = []

    /// The film whose editor window is key, falling back to the most recently
    /// opened one while no editor window is key (the app is in the background,
    /// or only the Welcome or agent window is up). Consulted by the agent
    /// window, the MCP server and the CLI runners, which have no window of their own.
    var activeDocument: ProjectDocument? {
        get { keyDocument ?? openDocuments.last }
        set { keyDocument = newValue }
    }
    private var keyDocument: ProjectDocument?

    var recentDocumentURLs: [URL] {
        NSDocumentController.shared.recentDocumentURLs
            .filter { $0.pathExtension == UTType.rxFilmStudioProject.preferredFilenameExtension }
    }

    /// Opens an editor window for a package URL. Installed by the App body.
    var openWindowRequest: ((URL) -> Void)? {
        didSet { flushPending() }
    }
    private var pendingOpens: [URL] = []

    private init() {}

    // MARK: - Lookup

    func document(for url: URL) -> ProjectDocument? {
        let target = url.standardizedFileURL.path
        return openDocuments.first { $0.packageURL.standardizedFileURL.path == target }
    }

    func document(id: UUID) -> ProjectDocument? {
        openDocuments.first { $0.id == id }
    }

    func document(forContainer container: ModelContainer) -> ProjectDocument? {
        openDocuments.first { $0.container === container }
    }

    /// The film an agent thread was started in, if it is still open, else the
    /// active one. A thread that outlives its film keeps working on whatever
    /// the user has in front of them.
    func document(for thread: AgentThread) -> ProjectDocument? {
        if let id = thread.documentID, let doc = document(id: id) { return doc }
        if let path = thread.documentPath, let doc = document(for: URL(fileURLWithPath: path)) { return doc }
        return activeDocument
    }

    // MARK: - Open / create / close

    /// Returns the already-open document for `url`, or opens it.
    @discardableResult
    func openOrReuse(_ url: URL) throws -> ProjectDocument {
        if let existing = document(for: url) { return existing }
        let doc = try ProjectDocument.open(url)
        openDocuments.append(doc)
        keyDocument = doc
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        return doc
    }

    @discardableResult
    func createDocument(at url: URL) throws -> ProjectDocument {
        let doc = try ProjectDocument.create(at: url)
        openDocuments.append(doc)
        keyDocument = doc
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        return doc
    }

    func close(_ doc: ProjectDocument) async {
        await doc.close()
        openDocuments.removeAll { $0 === doc }
        if keyDocument === doc {
            keyDocument = nil
        }
    }

    func saveAll() {
        for doc in openDocuments { doc.save() }
    }

    // MARK: - Window requests

    func requestOpen(_ url: URL) {
        if let openWindowRequest {
            openWindowRequest(url)
        } else {
            pendingOpens.append(url)
        }
    }

    private func flushPending() {
        guard let openWindowRequest else { return }
        let urls = pendingOpens
        pendingOpens.removeAll()
        for url in urls { openWindowRequest(url) }
    }

    // MARK: - Panels

    /// Asks where to create a new film. Returns a URL ending in `.rxfilmstudio`.
    func presentNewPanel() async -> URL? {
        let panel = NSSavePanel()
        panel.title = "New Film"
        panel.prompt = "Create"
        panel.nameFieldLabel = "Film name:"
        panel.nameFieldStringValue = "Untitled Film"
        panel.allowedContentTypes = [.rxFilmStudioProject]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard await panel.begin() == .OK, let url = panel.url else { return nil }
        return Self.sanitized(url)
    }

    func presentOpenPanel() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Open Film"
        panel.allowedContentTypes = [.rxFilmStudioProject]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK else { return nil }
        return panel.url
    }

    /// Remotion's bundler and shell tooling dislike a few characters in a cwd;
    /// keep the package name plain and make sure the extension is present.
    static func sanitized(_ url: URL) -> URL {
        let ext = UTType.rxFilmStudioProject.preferredFilenameExtension ?? "rxfilmstudio"
        var base = url.pathExtension.lowercased() == ext ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        let bad = CharacterSet(charactersIn: "#%?*:\"<>|\\/")
        base = base.components(separatedBy: bad).joined(separator: "-")
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "Untitled Film" }
        return url.deletingLastPathComponent().appendingPathComponent(base).appendingPathExtension(ext)
    }
}
