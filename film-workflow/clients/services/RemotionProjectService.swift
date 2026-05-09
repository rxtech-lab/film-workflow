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
        let copy = RemotionProject(name: newName ?? (source.name + " Copy"))
        copy.text = source.text
        copy.durationSeconds = source.durationSeconds
        copy.themeColorHex = source.themeColorHex
        copy.prompt = source.prompt
        copy.compositionWidth = source.compositionWidth
        copy.compositionHeight = source.compositionHeight
        copy.compositionFps = source.compositionFps
        copy.compositionSource = source.compositionSource

        copy.imagePaths = source.imagePaths.compactMap(copyStoredFile(atRelative:))
        copy.referenceImagePath = source.referenceImagePath.flatMap(copyStoredFile(atRelative:))
        copy.musicFilePath = source.musicFilePath.flatMap(copyStoredFile(atRelative:))

        let srcDir = FileStorage.remotionProjectDir(id: source.id)
        let dstDir = FileStorage.remotionProjectDir(id: copy.id)
        if FileManager.default.fileExists(atPath: srcDir.path) {
            try? FileManager.default.createDirectory(
                at: dstDir.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: dstDir)
            try? FileManager.default.copyItem(at: srcDir, to: dstDir)
        }

        context.insert(copy)

        for msg in source.messages.sorted(by: { $0.createdAt < $1.createdAt }) {
            let copiedMsg = RemotionMessage(
                role: msg.role,
                content: msg.content,
                project: copy,
                kind: RemotionMessageKind(rawValue: msg.kind) ?? .text,
                toolName: msg.toolName,
                toolArgs: msg.toolArgs,
                toolResult: msg.toolResult,
                toolStatus: msg.toolStatus.flatMap { RemotionToolStatus(rawValue: $0) },
                toolCallId: msg.toolCallId
            )
            context.insert(copiedMsg)
            copy.messages.append(copiedMsg)
        }

        return copy
    }

    /// Cleans up files + remotion project dir + chat messages, then deletes the row.
    static func delete(
        _ project: RemotionProject,
        context: ModelContext
    ) {
        for path in project.imagePaths {
            FileStorage.deleteFile(at: path)
        }
        if let p = project.referenceImagePath { FileStorage.deleteFile(at: p) }
        if let m = project.musicFilePath { FileStorage.deleteFile(at: m) }
        let dir = FileStorage.remotionProjectDir(id: project.id)
        try? FileManager.default.removeItem(at: dir)
        context.delete(project)
    }

    /// Copy a file stored under `<appSupport>/<folder>/<name>` to a new name in the same folder.
    /// Returns the new relative path or nil if the source is missing / unreadable.
    static func copyStoredFile(atRelative relativePath: String) -> String? {
        let src = FileStorage.absoluteURL(for: relativePath)
        guard FileManager.default.fileExists(atPath: src.path) else { return nil }
        let parts = relativePath.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let folder = String(parts[0])
        let ext = src.pathExtension
        let newName = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
        let dst = FileStorage.appSupportURL
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(newName)
        do {
            try FileManager.default.createDirectory(
                at: dst.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: src, to: dst)
            return folder + "/" + newName
        } catch {
            return nil
        }
    }
}
#endif
