import CryptoKit
import Foundation
import Observation
import VideoEditorCore

extension Notification.Name {
    /// Posted with `userInfo["directory"]` when a Remotion project's files change.
    static let remotionPreviewChanged = Notification.Name("RemotionPreviewChanged")
}

/// Live previews of Remotion projects play natively through MotionSwift. The
/// preview descriptor's URL is the project directory; the view compiles it with
/// MotionSwift and follows the editor's clock.
@MainActor
enum RemotionLivePreview {
    static func descriptor(project: RemotionProject, width: Int, height: Int) throws -> LivePreviewDescriptor {
        let directory = project.projectDir.standardizedFileURL
        try RemotionRuntime.shared.prepareProjectDirectory(directory)
        let source = directory.appendingPathComponent("src/Composition.tsx")
        if !FileManager.default.fileExists(atPath: source.path), !project.compositionSource.isEmpty {
            try RemotionCodeBuilder.writeComposition(project: project, source: project.compositionSource)
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw MotionSwiftEngine.Failure(String(localized: "Create a composition to start the preview."))
        }
        let fps = max(1, project.compositionFps)
        return LivePreviewDescriptor(url: directory, fps: fps,
                                     frames: max(1, Int((project.durationSeconds * Double(fps)).rounded())),
                                     width: width, height: height)
    }
}

/// Watches a project's sources while a preview shows it, so edits made outside the
/// app's editors (agents, the Source sheet, an external editor) reload every viewer,
/// filmstrip and thumbnail of that project.
@MainActor
final class RemotionProjectWatcher {
    private static var watchers: [URL: (count: Int, task: Task<Void, Never>)] = [:]

    /// Starts watching `directory`; balance with `stop(_:)`.
    static func start(_ directory: URL) {
        let key = directory.standardizedFileURL
        if let entry = watchers[key] { watchers[key] = (entry.count + 1, entry.task); return }
        let task = Task.detached(priority: .utility) {
            var last = try? RemotionSourceHasher.hash(projectDir: key, width: 0, height: 0, fps: 0)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                let current = try? RemotionSourceHasher.hash(projectDir: key, width: 0, height: 0, fps: 0)
                if current != last {
                    last = current
                    await MainActor.run {
                        NotificationCenter.default.post(name: .remotionPreviewChanged, object: nil, userInfo: ["directory": key])
                    }
                }
            }
        }
        watchers[key] = (1, task)
    }

    static func stop(_ directory: URL) {
        let key = directory.standardizedFileURL
        guard let entry = watchers[key] else { return }
        if entry.count > 1 { watchers[key] = (entry.count - 1, entry.task); return }
        entry.task.cancel()
        watchers.removeValue(forKey: key)
    }

    /// Stops watching projects inside a closing film package (or everything).
    static func stopAll(in package: URL? = nil) {
        for key in Array(watchers.keys) where package == nil || key.path.hasPrefix(package!.standardizedFileURL.path + "/") {
            watchers.removeValue(forKey: key)?.task.cancel()
        }
    }
}

/// Disposable alpha-preserving media. It never inserts a RemotionRender version.
@MainActor
enum RemotionPreviewRenderCache {
    private static let jobs = RemotionPreviewRenderJobs()
    static func captureScale(width: Int, height: Int) -> Double {
        min(1, 960 / Double(max(1, width, height)))
    }

    static func render(project: RemotionProject, width: Int, height: Int,
                       progress: @escaping @MainActor (RenderProgress) -> Void) async throws -> URL {
        let projectDir = project.projectDir
        let fps = max(1, project.compositionFps)
        let scale = captureScale(width: width, height: height)
        let sourceHash = try RemotionSourceHasher.hash(projectDir: projectDir, width: width, height: height, fps: fps)
        let key = SHA256.hash(data: Data("native-alpha-preview-v3-960:\(MotionSwiftEngine.fingerprint):\(projectDir.path):\(sourceHash)".utf8)).map { String(format: "%02x", $0) }.joined()
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.rxlab.film-workflow/RemotionPreview/\(key)", isDirectory: true)
        let output = root.appendingPathComponent("source.mov")
        if FileManager.default.fileExists(atPath: output.path) { return output }
        let title = project.name
        return try await jobs.value(for: key, progress: progress) { update in
            try await RenderQueue.shared.run(.remotion, title: title) { @MainActor reporter in
                let fm = FileManager.default
                if fm.fileExists(atPath: output.path) { return output }
                let work = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: work) }
                try Task.checkCancellation()
                let temporary = work.appendingPathComponent("rendering.mov")
                try await RemotionRenderer.render(projectDir: projectDir, to: temporary, width: width, height: height,
                                                  fps: fps, preserveAlpha: true, captureScale: scale) { progress in
                    update(progress)
                    reporter.update(progress.fraction, detail: progress.detail ?? progress.stage.rawValue.capitalized)
                }
                try Task.checkCancellation()
                if !fm.fileExists(atPath: output.path) { try fm.moveItem(at: temporary, to: output) }
                return output
            }
        }
    }
}
