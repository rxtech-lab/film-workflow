#if os(macOS)
import Foundation
import SwiftData

/// Renders Remotion projects into the film package and records each result as
/// a `RemotionRender` version. Also the cache the sequence renderer consults.
@MainActor
enum RemotionRenderService {
    /// Renders sorted newest first.
    static func renders(for project: RemotionProject, context: ModelContext) -> [RemotionRender] {
        let projectID = project.id
        let descriptor = FetchDescriptor<RemotionRender>(
            predicate: #Predicate { $0.projectID == projectID },
            sortBy: [SortDescriptor(\.versionNumber, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The hash a render must carry to be current for `project` at the given size.
    static func currentHash(project: RemotionProject, width: Int, height: Int, fps: Int, preserveAlpha: Bool = false) throws -> String {
        let sourceURL = project.projectDir.appendingPathComponent("src/Composition.tsx")
        if !FileManager.default.fileExists(atPath: sourceURL.path), !project.compositionSource.isEmpty {
            try RemotionCodeBuilder.writeComposition(project: project, source: project.compositionSource)
        }
        let hash = try RemotionSourceHasher.hash(projectDir: project.projectDir, width: width, height: height, fps: fps)
        return "native-v1-" + RemotionMapSettings.fingerprint + (preserveAlpha ? "-alpha-" : "-opaque-") + hash
    }

    /// An existing render that matches the project's current source, if any.
    static func cachedRender(project: RemotionProject, width: Int, height: Int, fps: Int, context: ModelContext, preserveAlpha: Bool = false) -> RemotionRender? {
        guard let hash = try? currentHash(project: project, width: width, height: height, fps: fps, preserveAlpha: preserveAlpha) else { return nil }
        return renders(for: project, context: context).first {
            $0.sourceHash == hash && FileManager.default.fileExists(atPath: $0.videoURL.path)
        }
    }

    /// Returns a matching cached render, or renders a new version.
    static func ensureRender(
        project: RemotionProject,
        width: Int,
        height: Int,
        fps: Int,
        context: ModelContext,
        force: Bool = false,
        preserveAlpha: Bool = false,
        onProgress: @escaping @MainActor (RenderProgress) -> Void
    ) async throws -> RemotionRender {
        let storage = ProjectStorage.forContainer(context.container)
        let hash = try currentHash(project: project, width: width, height: height, fps: fps, preserveAlpha: preserveAlpha)
        let existing = renders(for: project, context: context)
        if !force, let hit = existing.first(where: {
            $0.sourceHash == hash && FileManager.default.fileExists(atPath: $0.videoURL.path)
        }) {
            return hit
        }

        let version = (existing.map(\.versionNumber).max() ?? 0) + 1
        let dir = storage.remotionRenderDir(projectID: project.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = String(format: "v%03d-%@.%@", version, String(hash.suffix(8)), preserveAlpha ? "mov" : "mp4")
        let outputURL = dir.appendingPathComponent(filename)

        try await RemotionRenderer.render(
            projectDir: project.projectDir,
            to: outputURL,
            width: width,
            height: height,
            fps: fps,
            preserveAlpha: preserveAlpha,
            onProgress: onProgress
        )

        let relative = storage.relativePath(for: outputURL) ?? "Renders/Remotion/\(project.id.uuidString)/\(filename)"
        let thumbnail = await VideoThumbnailer.generate(for: outputURL, storage: storage)
        let probed = await VideoThumbnailer.probe(url: outputURL)

        let render = RemotionRender(
            projectID: project.id,
            versionNumber: version,
            sourceHash: hash,
            width: probed?.width ?? width,
            height: probed?.height ?? height,
            fps: fps,
            filePath: relative,
            thumbnailFilePath: thumbnail,
            durationSeconds: probed?.duration ?? project.durationSeconds
        )
        context.insert(render)
        project.updatedAt = Date()
        try context.save()
        return render
    }

    static func delete(_ render: RemotionRender, context: ModelContext) {
        let storage = ProjectStorage.forContainer(context.container)
        storage.deleteFile(at: render.filePath)
        if let thumbnail = render.thumbnailFilePath { storage.deleteFile(at: thumbnail) }
        context.delete(render)
    }

    /// Removes every render of a project. Called before the project row goes.
    static func deleteAll(for project: RemotionProject, context: ModelContext) {
        for render in renders(for: project, context: context) {
            delete(render, context: context)
        }
    }

    /// Copies a render to a user-chosen location.
    static func export(_ render: RemotionRender, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: render.videoURL, to: destination)
    }
}
#endif
