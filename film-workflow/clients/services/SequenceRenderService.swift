import AVFoundation
import Foundation
import SwiftData
import VideoEditorCore

/// Where a sequence render goes: kept in the film as a version, or written
/// to a folder the user picked.
enum SequenceRenderDestination: Equatable {
    case film
    case folder(URL)
}

enum SequenceRenderOutput {
    case version(SequenceRender)
    case file(URL)

    var url: URL {
        switch self {
        case .version(let render): return render.videoURL
        case .file(let url): return url
        }
    }
}

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
            RemotionRenderService.cachedRender(project: $0, width: sequence.width, height: sequence.height, fps: $0.compositionFps, context: context, preserveAlpha: true) == nil
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
                fps: project.compositionFps,
                context: context,
                preserveAlpha: true
            ) { p in
                onProgress(.preparingRemotion(clipIndex: index, total: stale.count, p))
            }
        }
    }

    /// Renders into the film as a new version with the default H.264 + AAC options.
    @discardableResult
    static func render(
        sequence: SequenceProject,
        document: ProjectDocument,
        preset: TimelineExporter.Preset,
        onProgress: @escaping @MainActor (SequenceRenderProgress) -> Void
    ) async throws -> SequenceRender {
        guard case .version(let render) = try await render(
            sequence: sequence, document: document, options: TimelineExporter.Options(video: preset), destination: .film, onProgress: onProgress
        ) else { preconditionFailure("film destination always yields a version") }
        return render
    }

    /// Renders `sequence` with `options`. `.film` records the file as the next
    /// version; `.folder` writes `<name>.<ext>` there and records nothing.
    @discardableResult
    static func render(
        sequence: SequenceProject,
        document: ProjectDocument,
        options: TimelineExporter.Options,
        destination: SequenceRenderDestination,
        onProgress: @escaping @MainActor (SequenceRenderProgress) -> Void
    ) async throws -> SequenceRenderOutput {
        // Work in the context that owns `sequence`: an MCP call's context holds
        // edits the window's main context may not have merged yet.
        let context = sequence.modelContext ?? document.container.mainContext
        let options = options.normalized
        try await renderRemotionClips(in: sequence, context: context, onProgress: onProgress)

        let storage = document.storage
        let version = (renders(for: sequence, context: context).map(\.versionNumber).max() ?? 0) + 1
        let outputURL: URL
        switch destination {
        case .film:
            outputURL = storage.sequenceRenderDir(sequenceID: sequence.id)
                .appendingPathComponent(String(format: "v%03d.%@", version, options.fileExtension))
        case .folder(let folder):
            outputURL = Self.unusedFileURL(in: folder, name: sequence.name, ext: options.fileExtension)
        }

        let resolver = DocumentMediaResolver(document: document, width: sequence.width, height: sequence.height, fps: sequence.fps)
        onProgress(.exporting(0))
        try await TimelineExporter.export(sequence.timeline, resolver: resolver, to: outputURL, options: options) { fraction in
            Task { @MainActor in onProgress(.exporting(fraction)) }
        }
        onProgress(.finalizing)
        guard case .film = destination else { return .file(outputURL) }

        let relative = storage.relativePath(for: outputURL) ?? "Renders/Sequences/\(sequence.id.uuidString)/\(outputURL.lastPathComponent)"
        let thumbnail = options.isAudioOnly ? nil : await VideoThumbnailer.generate(for: outputURL, storage: storage)
        let probed = options.isAudioOnly ? nil : await VideoThumbnailer.probe(url: outputURL)
        let size = options.outputSize(for: sequence.timeline.size)
        let duration: Double
        if let probed { duration = probed.duration } else {
            duration = (try? await CMTimeGetSeconds(AVURLAsset(url: outputURL).load(.duration))) ?? sequence.timeline.duration
        }
        let render = SequenceRender(
            sequenceID: sequence.id,
            versionNumber: version,
            filePath: relative,
            thumbnailFilePath: thumbnail,
            width: probed?.width ?? size.map { Int($0.width) } ?? 0,
            height: probed?.height ?? size.map { Int($0.height) } ?? 0,
            fps: options.isAudioOnly ? 0 : sequence.fps,
            durationSeconds: duration,
            preset: options.video?.rawValue ?? "audio"
        )
        context.insert(render)
        sequence.updatedAt = Date()
        try context.save()
        return .version(render)
    }

    /// `<name>.<ext>` in `folder`, or `<name> 2.<ext>`, `<name> 3.<ext>`… when taken.
    static func unusedFileURL(in folder: URL, name: String, ext: String) -> URL {
        let base = name.replacingOccurrences(of: "[/:]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = base.isEmpty ? "Sequence" : base
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent("\(stem).\(ext)")
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) \(counter).\(ext)")
            counter += 1
        }
        return candidate
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
