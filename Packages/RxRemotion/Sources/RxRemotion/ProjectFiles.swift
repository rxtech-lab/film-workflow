import CryptoKit
import Foundation

/// Filesystem scans, hashing, copying and deletion must never monopolize AppKit.
enum ProjectFiles {
    @concurrent static func list(in directory: URL) async throws -> [String] { try files(in: directory) }
    @concurrent static func hash(in directory: URL, entryPoint: String) async throws -> String {
        try fingerprint(in: directory, entryPoint: entryPoint)
    }
    @concurrent static func remove(_ directory: URL) async { try? FileManager.default.removeItem(at: directory) }
    @concurrent static func snapshot(of directory: URL, entryPoint: String) async throws -> URL {
        let fm = FileManager.default
        let destination = fm.temporaryDirectory.appendingPathComponent("rxremotion-export-" + UUID().uuidString)
        let before = try fingerprint(in: directory, entryPoint: entryPoint)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            for path in try files(in: directory) {
                try Task.checkCancellation()
                let source = try ResourceServer.containedFile(path, root: directory)
                let target = destination.appendingPathComponent(path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: target)
            }
            guard try fingerprint(in: directory, entryPoint: entryPoint) == before else {
                throw RemotionError.rendering("Source changed while preparing export. Retry the render.")
            }
            return destination.resolvingSymlinksInPath().standardizedFileURL
        } catch { try? fm.removeItem(at: destination); throw error }
    }
    private static func files(in directory: URL) throws -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [String] = []
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            if ["node_modules", "dist", "build", "Renders"].contains(file.lastPathComponent) { enumerator.skipDescendants(); continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isRegularFile == true { result.append(String(file.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(directory.path.count + 1))) }
        }
        return result.sorted()
    }
    private static func fingerprint(in directory: URL, entryPoint: String) throws -> String {
        var hash = SHA256()
        hash.update(data: Data((RemotionEngine.runtimeFingerprint + entryPoint).utf8))
        for path in try files(in: directory) where !path.hasSuffix(".log") {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(path).path)
            if ["ts", "tsx", "js", "jsx", "mjs", "css", "json"].contains(URL(fileURLWithPath: path).pathExtension) {
                hash.update(data: try Data(contentsOf: directory.appendingPathComponent(path)))
            }
            hash.update(data: Data("\(path):\(attributes[.size] ?? 0):\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)".utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
