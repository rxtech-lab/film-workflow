import Foundation

/// Browser modules contain scoped URLs. Store a relocatable form on disk so separate
/// projects and immutable export copies can share a content-identical compilation.
enum CompilationCache {
    private static var root: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("app.rxlab.RxRemotion/compiled", isDirectory: true) }
    private static let placeholder = "__RX_REMOTION_RESOURCE_BASE__/"
    @concurrent static func read(key: String, base: URL) async -> [String: Data]? {
        let url = root.appendingPathComponent(key + ".json")
        guard let data = try? Data(contentsOf: url), let cached = try? JSONDecoder().decode([String: String].self, from: data),
              cached["entry.js"] != nil else { return nil }
        return cached.mapValues { Data($0.replacingOccurrences(of: placeholder, with: base.absoluteString).utf8) }
    }
    @concurrent static func write(_ outputs: [String: Data], key: String, base: URL) async {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let cached = outputs.mapValues { String(decoding: $0, as: UTF8.self).replacingOccurrences(of: base.absoluteString, with: placeholder) }
            try JSONEncoder().encode(cached).write(to: root.appendingPathComponent(key + ".json"), options: .atomic)
            let files = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            let entries = files.compactMap { url -> (URL, Int, Date)? in
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }.sorted { $0.2 < $1.2 }
            var size = entries.reduce(0) { $0 + $1.1 }
            for (url, bytes, _) in entries where size > 256 * 1024 * 1024 {
                try? fm.removeItem(at: url); size -= bytes
            }
        } catch { /* Cache failures must not prevent rendering. */ }
    }
}
