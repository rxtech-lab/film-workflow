import AppKit
import CoreImage
import CryptoKit
import Foundation
import RxRemotion
import VideoEditorCore

extension GeneratedMusic: LibPreviewableProtocol {}
extension GeneratedNarrative: LibPreviewableProtocol {}
extension GeneratedImage: LibPreviewableProtocol {}
extension GeneratedVideo: LibPreviewableProtocol {}
extension ImportedAsset: LibPreviewableProtocol {}

extension CaptionProject: LibPreviewableProtocol {
    func makeLibPreviewSource() -> LibPreviewSource {
        CaptionLibraryPreviewCache.shared.preview(for: self).source
    }

    var libraryPreviewCaptionCount: Int {
        CaptionLibraryPreviewCache.shared.preview(for: self).captionCount
    }

    func buildLibraryCaptionPreview() -> CaptionLibraryPreviewCache.Preview {
        let cues = DocumentMediaResolver.cues(for: self, text: .original)
        let style = captionStyle
        let duration = max(storedDuration ?? 0, cues.map(\.end).max() ?? 0)
        let revision = "\(activeVersionID?.uuidString ?? "legacy"):\(cues.hashValue):\(style.hashValue):\(duration)"
        let source = LibPreviewSource(id: clipSource.id, revision: revision, duration: duration,
                                isTemporal: true, canScrub: duration > 0) { time, size in
            let text = cues.filter { $0.start <= time && time < $0.end }.map(\.text).joined(separator: "\n")
            let context = CGContext(data: nil, width: max(1, Int(size.width)), height: max(1, Int(size.height)),
                                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.setFillColor(NSColor.black.cgColor)
            context?.fill(CGRect(origin: .zero, size: size))
            if !text.isEmpty, let raster = TextRenderer.shared.image(for: text, style: style, frameSize: size),
               let image = LibraryCaptionRaster.context.createCGImage(raster, from: CGRect(origin: .zero, size: size)) {
                context?.draw(image, in: CGRect(origin: .zero, size: size))
            }
            return context?.makeImage()
        }
        return .init(source: source, captionCount: activeSegmentCount)
    }
}

@MainActor
private enum LibraryCaptionRaster { static let context = CIContext() }

extension RemotionProject: LibPreviewableProtocol {
    func makeLibPreviewSource() -> LibPreviewSource {
        let directory = projectDir
        let source = compositionSource
        let width = compositionWidth, height = compositionHeight, fps = max(1, compositionFps)
        let duration = durationSeconds
        let modified = try? directory.appendingPathComponent("src/Composition.tsx").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let revision = "\(updatedAt.timeIntervalSinceReferenceDate):\(source.hashValue):\(modified?.timeIntervalSinceReferenceDate ?? 0):\(width):\(height):\(fps)"
        let exists = !source.isEmpty || FileManager.default.fileExists(atPath: directory.appendingPathComponent("src/Composition.tsx").path)
        return LibPreviewSource(id: clipSource.id, revision: revision, duration: duration,
                                isTemporal: true, canScrub: exists && duration > 0) { time, size in
            guard exists else { return nil }
            return await LibraryRemotionThumbnails.image(directory: directory, source: source, time: time,
                                                         width: width, height: height, fps: fps, size: size)
        }
    }
}

/// Only one background WebKit capture at a time, regardless of how many
/// library/timeline tiles become visible. The viewer retains its own live session.
@MainActor
private enum LibraryRemotionThumbnails {
    static var tail: Task<Void, Never>?

    static func image(directory: URL, source: String, time: Double, width: Int, height: Int, fps: Int, size: CGSize) async -> CGImage? {
        let previous = tail
        let work = Task { @MainActor () -> CGImage? in
            await previous?.value
            guard !Task.isCancelled else { return nil }
            let engine = RemotionEngine(configuration: RemotionMapSettings.configuration)
            defer { engine.closeAll() }
            do {
                try RemotionRuntime.shared.prepareProjectDirectory(directory)
                let sourceURL = directory.appendingPathComponent("src/Composition.tsx")
                if !FileManager.default.fileExists(atPath: sourceURL.path), !source.isEmpty {
                    try source.write(to: sourceURL, atomically: true, encoding: .utf8)
                }
                let hash = try RemotionSourceHasher.hash(projectDir: directory, width: width, height: height, fps: fps)
                let frame = max(0, Int((time * Double(fps)).rounded(.down)))
                let scale = min(1, max(size.width / Double(max(1, width)), size.height / Double(max(1, height))))
                let key = SHA256.hash(data: Data("\(directory.path):\(hash):\(frame):\(scale):\(RemotionMapSettings.fingerprint)".utf8))
                    .map { String(format: "%02x", $0) }.joined()
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("RxFilmStudio-LibraryFrames", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let output = root.appendingPathComponent(key + ".png")
                if !FileManager.default.fileExists(atPath: output.path) {
                    let project = try await engine.prepare(projectURL: directory)
                    try Task.checkCancellation()
                    try await engine.renderStill(project: project, frame: frame, to: output,
                                                 settings: .init(width: width, height: height, fps: Double(fps), captureScale: scale))
                }
                return NSImage(contentsOf: output)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            } catch { return nil }
        }
        tail = Task { _ = await work.value }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }
}
