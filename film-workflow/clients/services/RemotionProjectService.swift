#if os(macOS)
import Foundation
import SwiftData

/// Shared remotion project operations used by both `RemotionTabView` and the MCP server.
@MainActor
enum RemotionProjectService {
    /// Duplicates a `RemotionProject` (model row + on-disk project dir + chat history)
    /// and inserts the copy into `context`. Returns the new project.
    @discardableResult
    static func duplicate(
        _ source: RemotionProject,
        newName: String? = nil,
        context: ModelContext
    ) -> RemotionProject {
        let storage = ProjectStorage.forContainer(context.container)
        let copy = RemotionProject(name: newName ?? (source.name + " Copy"))
        copy.text = source.text
        copy.durationSeconds = source.durationSeconds
        copy.themeColorHex = source.themeColorHex
        copy.prompt = source.prompt
        copy.compositionWidth = source.compositionWidth
        copy.compositionHeight = source.compositionHeight
        copy.compositionFps = source.compositionFps
        copy.compositionSource = source.compositionSource

        copy.imagePaths = source.imagePaths.compactMap(storage.copyStoredFile(atRelative:))
        copy.referenceImagePath = source.referenceImagePath.flatMap(storage.copyStoredFile(atRelative:))
        copy.audioFilePaths = source.audioFilePaths.compactMap(storage.copyStoredFile(atRelative:))

        let srcDir = storage.remotionProjectDir(id: source.id)
        let dstDir = storage.remotionProjectDir(id: copy.id)
        if FileManager.default.fileExists(atPath: srcDir.path) {
            try? FileManager.default.createDirectory(
                at: dstDir.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: dstDir)
            try? FileManager.default.copyItem(at: srcDir, to: dstDir)
        }

        context.insert(copy)

        // Agent threads are not copied: a thread belongs to a conversation, not
        // to a project, and duplicating one would leave two threads believing
        // they own the same CLI session id.

        return copy
    }

    /// Cleans up files + remotion project dir, then deletes the row.
    static func delete(
        _ project: RemotionProject,
        context: ModelContext
    ) {
        let storage = ProjectStorage.forContainer(context.container)
        for path in project.imagePaths {
            storage.deleteFile(at: path)
        }
        if let p = project.referenceImagePath { storage.deleteFile(at: p) }
        for m in project.audioFilePaths { storage.deleteFile(at: m) }
        try? FileManager.default.removeItem(at: storage.remotionProjectDir(id: project.id))
        try? FileManager.default.removeItem(at: storage.remotionRenderDir(projectID: project.id))
        context.delete(project)
    }

}
#endif
