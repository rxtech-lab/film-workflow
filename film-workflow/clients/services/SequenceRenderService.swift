import Foundation
import SwiftData
import VideoEditorCore

enum SequenceRenderProgress: Equatable {
    case preparingRemotion(clipIndex: Int, total: Int, RenderProgress)
    case exporting(Double)
    case finalizing

    var label: String {
        switch self {
        case .preparingRemotion(let i, let n, let p):
            return "Rendering Remotion clip \(i + 1) of \(n)" + (p.detail.map { " · \($0)" } ?? "")
        case .exporting: return "Exporting sequence"
        case .finalizing: return "Finalizing"
        }
    }

    var fraction: Double? {
        switch self {
        case .preparingRemotion(let i, let n, let p):
            let per = 1.0 / Double(max(1, n))
            return (Double(i) + (p.fraction ?? 0)) * per * 0.5
        case .exporting(let f): return 0.5 + f * 0.5
        case .finalizing: return 1
        }
    }
}

/// Renders a sequence: stale Remotion clips first, then the AVFoundation
/// export, recorded as a new `SequenceRender` version.
@MainActor
enum SequenceRenderService {
    static func renders(for sequence: SequenceProject, context: ModelContext) -> [SequenceRender] {
        let id = sequence.id
        let descriptor = FetchDescriptor<SequenceRender>(
            predicate: #Predicate { $0.sequenceID == id },
            sortBy: [SortDescriptor(\.versionNumber, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Remotion projects on the timeline that have no render for the sequence's size.
    static func unrenderedRemotionProjects(in sequence: SequenceProject, context: ModelContext) -> [RemotionProject] {
        remotionProjects(in: sequence, context: context).filter {
            RemotionRenderService.cachedRender(project: $0, width: sequence.width, height: sequence.height, fps: sequence.fps, context: context) == nil
        }
    }

    static func remotionProjects(in sequence: SequenceProject, context: ModelContext) -> [RemotionProject] {
        var ids: [UUID] = []
        for clip in sequence.timeline.allClips where clip.source.kind == .remotion {
            if let (prefix, uuid) = DocumentMediaResolver.parse(clip.source.id), prefix == .remotion, !ids.contains(uuid) {
                ids.append(uuid)
            }
        }
        return ids.compactMap { id in
            try? context.fetch(FetchDescriptor<RemotionProject>(predicate: #Predicate { $0.id == id })).first
        }
    }

    /// Renders every Remotion clip that is missing or stale for the sequence size.
    static func renderRemotionClips(
        in sequence: SequenceProject,
        context: ModelContext,
        onProgress: @escaping @MainActor (SequenceRenderProgress) -> Void
    ) async throws {
        let stale = unrenderedRemotionProjects(in: sequence, context: context)
        for (index, project) in stale.enumerated() {
            try Task.checkCancellation()
            _ = try await RemotionRenderService.ensureRender(
                project: project,
                width: sequence.width,
                height: sequence.height,
                fps: sequence.fps,
                context: context
            ) { p in
                onProgress(.preparingRemotion(clipIndex: index, total: stale.count, p))
            }
        }
    }

    @discardableResult
    static func render(
        sequence: SequenceProject,
        document: ProjectDocument,
        preset: TimelineExporter.Preset,
        onProgress: @escaping @MainActor (SequenceRenderProgress) -> Void
    ) async throws -> SequenceRender {
        // Work in the context that owns `sequence`: an MCP call's context holds
        // edits the window's main context may not have merged yet.
        let context = sequence.modelContext ?? document.container.mainContext
        try await renderRemotionClips(in: sequence, context: context, onProgress: onProgress)

        let storage = document.storage
        let existing = renders(for: sequence, context: context)
        let version = (existing.map(\.versionNumber).max() ?? 0) + 1
        let dir = storage.sequenceRenderDir(sequenceID: sequence.id)
        let outputURL = dir.appendingPathComponent(String(format: "v%03d.mp4", version))

        let resolver = DocumentMediaResolver(document: document, width: sequence.width, height: sequence.height, fps: sequence.fps)
        onProgress(.exporting(0))
        try await TimelineExporter.export(sequence.timeline, resolver: resolver, to: outputURL, preset: preset) { fraction in
            Task { @MainActor in onProgress(.exporting(fraction)) }
        }
        onProgress(.finalizing)

        let relative = storage.relativePath(for: outputURL) ?? "Renders/Sequences/\(sequence.id.uuidString)/\(outputURL.lastPathComponent)"
        let thumbnail = await VideoThumbnailer.generate(for: outputURL, storage: storage)
        let probed = await VideoThumbnailer.probe(url: outputURL)
        let render = SequenceRender(
            sequenceID: sequence.id,
            versionNumber: version,
            filePath: relative,
            thumbnailFilePath: thumbnail,
            width: probed?.width ?? sequence.width,
            height: probed?.height ?? sequence.height,
            fps: sequence.fps,
            durationSeconds: probed?.duration ?? sequence.timeline.duration,
            preset: preset.rawValue
        )
        context.insert(render)
        sequence.updatedAt = Date()
        try context.save()
        return render
    }

    static func delete(_ render: SequenceRender, context: ModelContext) {
        let storage = ProjectStorage.forContainer(context.container)
        storage.deleteFile(at: render.filePath)
        if let thumbnail = render.thumbnailFilePath { storage.deleteFile(at: thumbnail) }
        context.delete(render)
    }

    static func deleteAll(for sequence: SequenceProject, context: ModelContext) {
        for render in renders(for: sequence, context: context) { delete(render, context: context) }
        ProjectStorage.forContainer(context.container).removeDirectory(
            ProjectStorage.forContainer(context.container).sequenceRenderDir(sequenceID: sequence.id)
        )
    }

    static func export(_ render: SequenceRender, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: render.videoURL, to: destination)
    }
}
