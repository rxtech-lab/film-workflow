import CryptoKit
import Foundation

/// Fingerprints everything that decides what a Remotion render looks like.
///
/// Source files are hashed by content. Assets under `public/` are large, so
/// they contribute path, size and modification time instead. Logs, bundler
/// caches and the `node_modules` symlink are skipped: they change without
/// changing the picture.
nonisolated enum RemotionSourceHasher {
    private static let contentDirectories = ["src"]
    private static let contentFiles = ["package.json", "remotion.config.ts", "tsconfig.json"]
    private static let assetDirectories = ["public"]
    private static let skippedNames: Set<String> = ["node_modules", ".remotion", ".agent-stills", "dist", "build", ".DS_Store"]

    static func hash(projectDir: URL, width: Int, height: Int, fps: Int) throws -> String {
        var hasher = SHA256()
        hasher.update(data: Data("settings:\(width)x\(height)@\(fps)\n".utf8))

        for name in contentFiles {
            let url = projectDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            hasher.update(data: Data("file:\(name)\n".utf8))
            hasher.update(data: data)
        }
        for dir in contentDirectories {
            for relative in try sortedFiles(under: projectDir.appendingPathComponent(dir, isDirectory: true), root: projectDir) {
                let data = try Data(contentsOf: projectDir.appendingPathComponent(relative))
                hasher.update(data: Data("file:\(relative)\n".utf8))
                hasher.update(data: data)
            }
        }
        for dir in assetDirectories {
            for relative in try sortedFiles(under: projectDir.appendingPathComponent(dir, isDirectory: true), root: projectDir) {
                let attrs = try FileManager.default.attributesOfItem(atPath: projectDir.appendingPathComponent(relative).path)
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                hasher.update(data: Data("asset:\(relative):\(size):\(Int(mtime))\n".utf8))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Regular files below `directory`, as paths relative to `root`, sorted.
    private static func sortedFiles(under directory: URL, root: URL) throws -> [String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else { return [] }
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [String] = []
        let rootPath = root.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            if skippedNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { continue }
            files.append(String(path.dropFirst(rootPath.count)))
        }
        return files.sorted()
    }
}
