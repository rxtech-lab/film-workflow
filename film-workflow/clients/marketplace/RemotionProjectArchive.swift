#if os(macOS)
import Foundation

/// The zip a Remotion composition is published as, and read back from.
///
/// The archive carries the project's source rather than a render: `src/`,
/// `public/`, the root config files, and a descriptor holding the prompt and
/// composition settings that live in SwiftData rather than on disk.
///
/// Extraction runs on the *installing* machine and produces TypeScript that
/// machine will compile and run, so `read` validates the tree before a single
/// byte reaches the film package. Treat that validation as load-bearing.
nonisolated enum RemotionProjectArchive {
    /// Deliberately not `manifest.json`: that name belongs to
    /// `InstalledMarketplaceManifest`, which sits beside this archive in the
    /// installed-item directory.
    static let descriptorName = "rxremotion.json"

    /// The root entries an archive may contain. Anything else is refused.
    static let allowedRoots: Set<String> = ["src", "public", "package.json", "tsconfig.json", "remotion.config.ts", descriptorName]

    /// Bounds on what extraction will unpack, so a malicious archive cannot
    /// fill the disk. Generous enough for a composition with real assets.
    static let maximumUnpackedBytes: Int64 = 400 * 1024 * 1024
    static let maximumFileCount = 5_000

    /// What SwiftData knows about a composition that its files do not.
    struct Descriptor: Codable, Hashable, Sendable {
        var version = 1
        var name: String
        var prompt: String
        var compositionWidth: Int
        var compositionHeight: Int
        var compositionFps: Int
        var durationSeconds: Double
    }

    enum ArchiveError: LocalizedError, Equatable {
        case empty
        case tooLarge(bytes: Int64)
        case unsafeEntry(String)
        case missing(String)
        case malformedDescriptor
        case dittoFailed(String)

        var errorDescription: String? {
            switch self {
            case .empty:
                return String(localized: "This composition has no source files to publish yet.")
            case .tooLarge(let bytes):
                let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                return String(localized: "This composition's files come to \(size), which is more than the marketplace accepts. Remove large assets from its public folder and try again.")
            case .unsafeEntry(let path):
                return String(localized: "This archive contains an unsafe entry (\(path)) and was not installed.")
            case .missing(let path):
                return String(localized: "This archive is missing \(path).")
            case .malformedDescriptor:
                return String(localized: "This archive's composition details could not be read.")
            case .dittoFailed(let message):
                return String(localized: "The archive could not be created: \(message)")
            }
        }
    }

    // MARK: - Writing

    /// Zips the project into `destination`.
    ///
    /// The file list comes from `RemotionProjectFiles.list`, the same walk the
    /// agent's `list_files` tool and the source viewer use, so the archive and
    /// the editor can never disagree about what the project is. That walk
    /// already skips `node_modules`, `.agent-stills`, `.git`, `dist` and builds.
    @discardableResult
    static func write(project projectDir: URL, descriptor: Descriptor, to destination: URL, limitBytes: Int64 = maximumUnpackedBytes) throws -> Descriptor {
        let fm = FileManager.default
        let paths = RemotionProjectFiles.list(projectDir: projectDir)
        guard !paths.isEmpty else { throw ArchiveError.empty }

        let staging = fm.temporaryDirectory.appendingPathComponent("RemotionArchive-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        var total: Int64 = 0
        for relative in paths {
            let source = projectDir.appendingPathComponent(relative)
            let target = staging.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: target)
            total += Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        guard total <= limitBytes else { throw ArchiveError.tooLarge(bytes: total) }

        let json = JSONEncoder()
        json.outputFormatting = [.prettyPrinted, .sortedKeys]
        try json.encode(descriptor).write(to: staging.appendingPathComponent(descriptorName), options: .atomic)

        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // `--norsrc --noextattr` keeps the archive free of the `__MACOSX`
        // entries a plain ditto leaves behind, which would fail the root check.
        try run(["-c", "-k", "--norsrc", "--noextattr", staging.path, destination.path])
        return descriptor
    }

    // MARK: - Reading

    /// Unpacks into `destination` after checking the tree, and returns the
    /// descriptor. `destination` must not already exist.
    @discardableResult
    static func read(archive: URL, into destination: URL) throws -> Descriptor {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("RemotionUnpack-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        try run(["-x", "-k", archive.path, scratch.path])

        let descriptor = try inspect(scratch)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        // Only now, with the tree proved safe, does anything reach the film.
        try fm.moveItem(at: scratch, to: destination)
        return descriptor
    }

    /// Checks an archive without keeping what it unpacks. Used at install time,
    /// before the item is ever added to a film.
    @discardableResult
    static func validate(archive: URL) throws -> Descriptor {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("RemotionCheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        try run(["-x", "-k", archive.path, scratch.path])
        return try inspect(scratch)
    }

    /// Everything that makes an unpacked tree safe to keep.
    private static func inspect(_ root: URL) throws -> Descriptor {
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.path

        for entry in (try? fm.contentsOfDirectory(atPath: rootPath)) ?? [] {
            guard allowedRoots.contains(entry) else { throw ArchiveError.unsafeEntry(entry) }
        }

        var files = 0
        var bytes: Int64 = 0
        guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
            throw ArchiveError.missing(descriptorName)
        }
        for case let url as URL in walk {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            // A symlink is how an archive escapes its own directory; refuse the
            // whole thing rather than trying to decide which ones are benign.
            if values?.isSymbolicLink == true { throw ArchiveError.unsafeEntry(url.lastPathComponent) }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard resolved == rootPath || resolved.hasPrefix(rootPath + "/") else { throw ArchiveError.unsafeEntry(url.lastPathComponent) }
            guard values?.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(values?.fileSize ?? 0)
            if files > maximumFileCount { throw ArchiveError.tooLarge(bytes: bytes) }
            if bytes > maximumUnpackedBytes { throw ArchiveError.tooLarge(bytes: bytes) }
        }

        let descriptorURL = root.appendingPathComponent(descriptorName)
        guard fm.fileExists(atPath: descriptorURL.path) else { throw ArchiveError.missing(descriptorName) }
        guard fm.fileExists(atPath: root.appendingPathComponent("src/Composition.tsx").path) else { throw ArchiveError.missing("src/Composition.tsx") }
        guard let data = try? Data(contentsOf: descriptorURL),
              let descriptor = try? JSONDecoder().decode(Descriptor.self, from: data)
        else { throw ArchiveError.malformedDescriptor }
        return descriptor
    }

    // MARK: - ditto

    /// `/usr/bin/ditto`, which ships with macOS and handles both directions.
    /// The app is not sandboxed, so this is available to it.
    private static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ArchiveError.dittoFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

extension RemotionProjectArchive.Descriptor {
    /// The descriptor for a composition as the film holds it.
    @MainActor init(project: RemotionProject) {
        self.init(name: project.name, prompt: project.prompt,
                  compositionWidth: project.compositionWidth, compositionHeight: project.compositionHeight,
                  compositionFps: project.compositionFps, durationSeconds: project.durationSeconds)
    }
}
#endif
