import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Persistent, content-keyed storage for derived media (thumbnails, waveforms,
/// prerendered compositions), so relaunching the app does not render them again.
/// Keys fingerprint the source file's path, size and modification date; a changed
/// source simply misses and the stale entry is eventually pruned.
public nonisolated enum RenderDiskCache {
    public enum Bucket: String, Sendable {
        case thumbnails = "Thumbnails"
        case waveforms = "Waveforms"
        case remotionFrames = "RemotionFrames"
    }

    public static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "RxVideoEditor", isDirectory: true)
            .appendingPathComponent("RenderCache", isDirectory: true)
    }

    public static func directory(_ bucket: Bucket) -> URL {
        root.appendingPathComponent(bucket.rawValue, isDirectory: true)
    }

    public static func url(_ bucket: Bucket, key: String, extension ext: String) -> URL {
        directory(bucket).appendingPathComponent(key).appendingPathExtension(ext)
    }

    public static func key(_ parts: String...) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Identifies one version of a file on disk, or `nil` if it cannot be read.
    public static func fingerprint(of url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        return "\(url.standardizedFileURL.path)|\(values.fileSize ?? -1)|\(values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)"
    }

    // MARK: - Data

    public static func data(_ bucket: Bucket, key: String, extension ext: String) -> Data? {
        try? Data(contentsOf: url(bucket, key: key, extension: ext))
    }

    public static func store(_ data: Data, _ bucket: Bucket, key: String, extension ext: String) {
        let destination = url(bucket, key: key, extension: ext)
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: destination, options: .atomic)
    }

    // MARK: - Images

    public static func image(_ bucket: Bucket, key: String) -> CGImage? {
        let file = url(bucket, key: key, extension: "jpg")
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    public static func store(_ image: CGImage, _ bucket: Bucket, key: String) {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }
        store(data as Data, bucket, key: key, extension: "jpg")
    }

    // MARK: - Maintenance

    /// Deletes the oldest entries until the cache fits within `limit` bytes.
    public static func prune(limit: Int64 = 1_024 * 1_024 * 1_024) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? 0)
            files.append((file, size, values.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > limit else { return }
        for file in files.sorted(by: { $0.date < $1.date }) where total > limit {
            if (try? fm.removeItem(at: file.url)) != nil { total -= file.size }
        }
    }
}
