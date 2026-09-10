import Foundation
import SwiftData

/// Per-document file layout. One instance per open `.rxfilmstudio` package.
///
/// Models store paths relative to the package (`Media/Music/<uuid>.mp3`) and
/// resolve them through `absoluteURL(for:)`. The static helpers that used to
/// live on `FileStorage` moved here unchanged in shape, so a call site only has
/// to obtain the right instance — usually `ProjectStorage.forContainer(context.container)`
/// in services and MCP handlers, or `@Environment(\.projectStorage)` in views.
nonisolated final class ProjectStorage: Sendable {
    enum MediaKind: String, CaseIterable, Sendable {
        case music = "Media/Music"
        case narration = "Media/Narration"
        case images = "Media/Images"
        case videos = "Media/Videos"
        case captions = "Media/Captions"
        case imported = "Media/Imported"
    }

    static let storeFilename = "Library.store"
    static let metadataFilename = "Document.json"

    let packageURL: URL

    init(packageURL: URL) {
        self.packageURL = packageURL.standardizedFileURL
    }

    // MARK: - Layout

    var storeURL: URL { packageURL.appendingPathComponent(Self.storeFilename) }
    var metadataURL: URL { packageURL.appendingPathComponent(Self.metadataFilename) }

    func mediaDir(_ kind: MediaKind) -> URL {
        packageURL.appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    var remotionDir: URL { packageURL.appendingPathComponent("Remotion", isDirectory: true) }
    func remotionProjectDir(id: UUID) -> URL {
        remotionDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    var rendersDir: URL { packageURL.appendingPathComponent("Renders", isDirectory: true) }
    var remotionRendersDir: URL { rendersDir.appendingPathComponent("Remotion", isDirectory: true) }
    func remotionRenderDir(projectID: UUID) -> URL {
        remotionRendersDir.appendingPathComponent(projectID.uuidString, isDirectory: true)
    }
    var sequenceRendersDir: URL { rendersDir.appendingPathComponent("Sequences", isDirectory: true) }
    func sequenceRenderDir(sequenceID: UUID) -> URL {
        sequenceRendersDir.appendingPathComponent(sequenceID.uuidString, isDirectory: true)
    }

    var thumbnailsDir: URL {
        packageURL.appendingPathComponent("Cache", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
    }

    func ensureDirectories() throws {
        let fm = FileManager.default
        var dirs = MediaKind.allCases.map(mediaDir)
        dirs += [remotionDir, remotionRendersDir, sequenceRendersDir, thumbnailsDir]
        for dir in dirs {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Path resolution

    func absoluteURL(for relativePath: String) -> URL {
        packageURL.appendingPathComponent(relativePath)
    }

    /// Package-relative path for a URL inside the package, or nil.
    func relativePath(for url: URL) -> String? {
        let root = packageURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    // MARK: - Writing media

    private func write(_ data: Data, kind: MediaKind, extension ext: String, fallback: String) throws -> String {
        let trimmed = ext.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let finalExt = trimmed.isEmpty ? fallback : trimmed
        let filename = UUID().uuidString + "." + finalExt
        let dir = mediaDir(kind)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(filename))
        return kind.rawValue + "/" + filename
    }

    func saveAudio(_ data: Data, extension ext: String, kind: MediaKind = .music) throws -> String {
        try write(data, kind: kind, extension: ext, fallback: "mp3")
    }

    func saveImage(_ data: Data, fileExtension: String = "jpg") throws -> String {
        try write(data, kind: .images, extension: fileExtension, fallback: "jpg")
    }

    func saveVideo(_ data: Data, fileExtension: String = "mp4") throws -> String {
        try write(data, kind: .videos, extension: fileExtension, fallback: "mp4")
    }

    func saveCaptionFile(_ data: Data, extension ext: String) throws -> String {
        try write(data, kind: .captions, extension: ext, fallback: "vtt")
    }

    /// Moves a freshly downloaded clip into `Media/Videos`. A move rather than a
    /// copy because the source is the temp file `URLSession.download` hands
    /// back and a generated video is large.
    func importVideo(movingFrom sourceURL: URL, fileExtension: String = "mp4") throws -> String {
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let finalExt = ext.isEmpty ? "mp4" : ext
        let filename = UUID().uuidString + "." + finalExt
        let dir = mediaDir(.videos)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(filename)
        do {
            try fm.moveItem(at: sourceURL, to: dest)
        } catch {
            // Cross-volume: a move is not atomic and Foundation refuses it.
            try fm.copyItem(at: sourceURL, to: dest)
            try? fm.removeItem(at: sourceURL)
        }
        return MediaKind.videos.rawValue + "/" + filename
    }

    /// Copies a file the user picked into the given media folder.
    func copyFile(from sourceURL: URL, kind: MediaKind, fallbackExtension: String) throws -> String {
        let ext = sourceURL.pathExtension.isEmpty ? fallbackExtension : sourceURL.pathExtension.lowercased()
        let filename = UUID().uuidString + "." + ext
        let dir = mediaDir(kind)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: dir.appendingPathComponent(filename))
        return kind.rawValue + "/" + filename
    }

    func copyImage(from sourceURL: URL) throws -> String {
        try copyFile(from: sourceURL, kind: .images, fallbackExtension: "png")
    }

    func importAudio(from sourceURL: URL) throws -> String {
        try copyFile(from: sourceURL, kind: .captions, fallbackExtension: "m4a")
    }

    /// Duplicates a file already inside the package, keeping its folder.
    func copyStoredFile(atRelative relativePath: String) -> String? {
        let src = absoluteURL(for: relativePath)
        let dir = (relativePath as NSString).deletingLastPathComponent
        let ext = src.pathExtension
        let filename = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
        let relative = dir.isEmpty ? filename : dir + "/" + filename
        let dst = absoluteURL(for: relative)
        do {
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: src, to: dst)
            return relative
        } catch {
            return nil
        }
    }

    func deleteFile(at relativePath: String) {
        try? FileManager.default.removeItem(at: absoluteURL(for: relativePath))
    }

    func removeDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Registry

    /// Storage instances keyed by the `ModelContainer` that owns their store.
    ///
    /// Services and MCP handlers receive a `ModelContext` but not the document,
    /// and models resolve their own file URLs; both find their storage here.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var byContainer: [ObjectIdentifier: ProjectStorage] = [:]
    nonisolated(unsafe) private static var byStoreURL: [URL: ProjectStorage] = [:]
    nonisolated(unsafe) private static var ephemeral: ProjectStorage?

    static func register(_ storage: ProjectStorage, for container: ModelContainer) {
        lock.lock(); defer { lock.unlock() }
        byContainer[ObjectIdentifier(container)] = storage
        byStoreURL[storage.storeURL.standardizedFileURL] = storage
    }

    static func unregister(container: ModelContainer) {
        lock.lock(); defer { lock.unlock() }
        if let storage = byContainer.removeValue(forKey: ObjectIdentifier(container)) {
            byStoreURL.removeValue(forKey: storage.storeURL.standardizedFileURL)
        }
    }

    /// The storage for a container. In-memory containers (tests, previews) get
    /// a throwaway package under the global temp directory so file helpers keep
    /// working without a document.
    static func forContainer(_ container: ModelContainer) -> ProjectStorage {
        lock.lock()
        if let s = byContainer[ObjectIdentifier(container)] {
            lock.unlock(); return s
        }
        if let url = container.configurations.first?.url.standardizedFileURL,
           url.lastPathComponent == storeFilename,
           let s = byStoreURL[url] {
            byContainer[ObjectIdentifier(container)] = s
            lock.unlock(); return s
        }
        lock.unlock()

        if let url = container.configurations.first?.url.standardizedFileURL,
           url.lastPathComponent == storeFilename {
            let s = ProjectStorage(packageURL: url.deletingLastPathComponent())
            register(s, for: container)
            return s
        }
        let s = ephemeralStorage()
        register(s, for: container)
        return s
    }

    /// Storage for a model that has been inserted into a context.
    static func `for`(model: any PersistentModel) -> ProjectStorage {
        if let container = model.modelContext?.container {
            return forContainer(container)
        }
        return ephemeralStorage()
    }

    static func ephemeralStorage() -> ProjectStorage {
        lock.lock(); defer { lock.unlock() }
        if let ephemeral { return ephemeral }
        let url = FileStorage.tempDir.appendingPathComponent("ephemeral-\(UUID().uuidString)", isDirectory: true)
        let s = ProjectStorage(packageURL: url)
        try? s.ensureDirectories()
        ephemeral = s
        return s
    }
}
