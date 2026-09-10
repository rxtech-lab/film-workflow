import Foundation
import SwiftData

struct DocumentMetadata: Codable, Sendable {
    static let currentFormatVersion = 1

    var id: UUID
    var formatVersion: Int
    var createdAt: Date
    var appVersion: String
}

enum ProjectDocumentError: LocalizedError {
    case notAPackage(URL)
    case missingStore(URL)
    case unsupportedFormat(Int)
    case alreadyExists(URL)

    var errorDescription: String? {
        switch self {
        case .notAPackage(let url):
            return "\"\(url.lastPathComponent)\" is not a RxFilmStudio film."
        case .missingStore(let url):
            return "\"\(url.lastPathComponent)\" is missing its library database."
        case .unsupportedFormat(let v):
            return "This film was saved by a newer version of RxFilmStudio (format \(v))."
        case .alreadyExists(let url):
            return "\"\(url.lastPathComponent)\" already exists."
        }
    }
}

/// One open `.rxfilmstudio` package.
///
/// Owns the SwiftData container for that film. SwiftData autosaves into the
/// package in place, so there is no explicit dirty state; `save()` only flushes
/// pending changes at moments where a copy of the package might be taken.
@MainActor
@Observable
final class ProjectDocument: Identifiable {
    let id: UUID
    let packageURL: URL
    let container: ModelContainer
    let storage: ProjectStorage
    let metadata: DocumentMetadata
    @ObservationIgnored private(set) var panelLayout: DocumentPanelLayout
    @ObservationIgnored private var panelLayoutSaveTask: Task<Void, Never>?
    @ObservationIgnored private var panelLayoutNeedsSave = false

    var displayName: String {
        packageURL.deletingPathExtension().lastPathComponent
    }

    /// Every model persisted inside a film. Agent threads live in the app-level
    /// store instead (`AppModelContainer`), because they span films.
    static let schema = Schema([
        MusicProject.self,
        GeneratedMusic.self,
        NarrativeProject.self,
        GeneratedNarrative.self,
        RemotionProject.self,
        ImageGenProject.self,
        GeneratedImage.self,
        VideoGenProject.self,
        GeneratedVideo.self,
        CaptionProject.self,
        CaptionSegment.self,
        ProjectGroup.self,
        RemotionRender.self,
        SequenceProject.self,
        SequenceRender.self,
        ImportedAsset.self,
    ])

    private init(packageURL: URL, metadata: DocumentMetadata) throws {
        let storage = ProjectStorage(packageURL: packageURL)
        try storage.ensureDirectories()
        let configuration = ModelConfiguration(schema: Self.schema, url: storage.storeURL)
        let container = try ModelContainer(for: Self.schema, configurations: [configuration])
        ProjectStorage.register(storage, for: container)

        self.id = metadata.id
        self.packageURL = storage.packageURL
        self.container = container
        self.storage = storage
        self.metadata = metadata
        self.panelLayout = (try? JSONDecoder().decode(
            DocumentPanelLayout.self,
            from: Data(contentsOf: storage.packageURL.appendingPathComponent("Workspace.json"))
        )) ?? DocumentPanelLayout()
    }

    /// Creates a new, empty film at `url` (which must end in `.rxfilmstudio`).
    static func create(at url: URL) throws -> ProjectDocument {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { throw ProjectDocumentError.alreadyExists(url) }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let metadata = DocumentMetadata(
            id: UUID(),
            formatVersion: DocumentMetadata.currentFormatVersion,
            createdAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: url.appendingPathComponent(ProjectStorage.metadataFilename))
        return try ProjectDocument(packageURL: url, metadata: metadata)
    }

    /// Opens an existing film, validating its metadata and store.
    static func open(_ url: URL) throws -> ProjectDocument {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw ProjectDocumentError.notAPackage(url)
        }
        let metadataURL = url.appendingPathComponent(ProjectStorage.metadataFilename)
        guard let data = try? Data(contentsOf: metadataURL) else {
            throw ProjectDocumentError.notAPackage(url)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(DocumentMetadata.self, from: data)
        guard metadata.formatVersion <= DocumentMetadata.currentFormatVersion else {
            throw ProjectDocumentError.unsupportedFormat(metadata.formatVersion)
        }
        return try ProjectDocument(packageURL: url, metadata: metadata)
    }

    func save() {
        savePanelLayout()
        let context = container.mainContext
        if context.hasChanges {
            try? context.save()
        }
    }

    func setPanelSizes(_ sizes: [Double], for panel: DocumentPanelLayout.Panel) {
        guard sizes.count >= 2, sizes.allSatisfy({ $0.isFinite && $0 > 0 }),
              panelLayout.splits[panel.rawValue] != sizes else { return }
        panelLayout.splits[panel.rawValue] = sizes
        panelLayoutNeedsSave = true
        panelLayoutSaveTask?.cancel()
        panelLayoutSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.savePanelLayout()
        }
    }

    private func savePanelLayout() {
        panelLayoutSaveTask?.cancel()
        panelLayoutSaveTask = nil
        guard panelLayoutNeedsSave else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(panelLayout).write(
                to: packageURL.appendingPathComponent("Workspace.json"), options: .atomic
            )
            panelLayoutNeedsSave = false
        } catch {
            // Retain the dirty flag so the next resize or document save retries.
            NSLog("Could not save panel layout: %@", error.localizedDescription)
        }
    }

    /// Flushes changes and releases per-document registrations. Stops the
    /// Remotion Studio preview if it is serving a project inside this package.
    func close() async {
        save()
        #if os(macOS)
        RemotionPreviewSessions.shared.stopAll(in: packageURL)
        if let dir = RemotionRuntime.shared.currentProjectDir,
           dir.standardizedFileURL.path.hasPrefix(packageURL.path) {
            await RemotionRuntime.shared.stop()
        }
        #endif
        ProjectStorage.unregister(container: container)
    }
}
