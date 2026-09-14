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
    /// A movie in a chosen folder, with any caption files written beside it.
    case file(URL, captionFiles: [URL])

    var url: URL {
        switch self {
        case .version(let render): return render.videoURL
        case .file(let url, _): return url
        }
    }

    var captionFiles: [URL] {
        switch self {
        case .version(let render): return render.captionFileURLs
        case .file(_, let files): return files
        }
    }
}

enum SequenceRenderProgress: Equatable {
    case preparingRemotion(clipIndex: Int, total: Int, RenderProgress)
    case exporting(Double)
    /// Rewriting the movie with subtitle tracks; short and indeterminate.
    case embeddingCaptions
    case writingCaptions
    case finalizing

    var label: String {
        switch self {
        case .preparingRemotion(let i, let n, let p):
            return String(localized: "Rendering Remotion clip \(i + 1) of \(n)") + (p.detail.map { " · \($0)" } ?? "")
        case .exporting: return String(localized: "Exporting sequence")
        case .embeddingCaptions: return String(localized: "Embedding captions")
        case .writingCaptions: return String(localized: "Writing caption files")
        case .finalizing: return String(localized: "Finalizing")
        }
    }

    var fraction: Double? {
        switch self {
        case .preparingRemotion(let i, let n, let p):
            let per = 1.0 / Double(max(1, n))
            return (Double(i) + (p.fraction ?? 0)) * per * 0.5
        case .exporting(let f): return 0.5 + f * 0.5
        case .embeddingCaptions, .writingCaptions: return nil
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
    ///
    /// `captions` says which languages the caption clips deliver in the way
    /// `options.captions` asks: burned in, as subtitle tracks muxed after the
    /// export, or as files beside the movie. Without caption clips on the
    /// timeline nothing caption-related happens.
    @discardableResult
    static func render(
        sequence: SequenceProject,
        document: ProjectDocument,
        options: TimelineExporter.Options,
        captions: CaptionRenderRequest = CaptionRenderRequest(),
        destination: SequenceRenderDestination,
        onProgress: @escaping @MainActor (SequenceRenderProgress) -> Void
    ) async throws -> SequenceRenderOutput {
        // Work in the context that owns `sequence`: an MCP call's context holds
        // edits the window's main context may not have merged yet.
        let context = sequence.modelContext ?? document.container.mainContext
        var options = options.normalized
        if !SequenceCaptionSources.hasCaptions(in: sequence) { options.captions = .none }
        let captions = captions.narrowed(to: SequenceCaptionSources.availableLanguages(in: sequence, context: context))
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
        // Embedding rewrites the movie, so the exporter writes a hidden
        // sibling that the muxer reads and then removes.
        let exportURL = options.captions == .embedded
            ? outputURL.deletingLastPathComponent()
                .appendingPathComponent(".\(outputURL.deletingPathExtension().lastPathComponent).video.\(outputURL.pathExtension)")
            : outputURL

        let resolver = DocumentMediaResolver(document: document, width: sequence.width, height: sequence.height, fps: sequence.fps,
                                             captionText: options.captions == .burnIn ? captions.burnInSelection : .original)
        // Caption clips carry their own languages, which the inspector and the
        // render sheet both edit. A request that names one — an agent render,
        // say — overrides them for this export only.
        let timeline = options.captions == .burnIn && captions.burnInLanguages != [""]
            ? SequenceCaptionSources.timeline(sequence.timeline, burningIn: captions.burnInLanguages)
            : sequence.timeline
        onProgress(.exporting(0))
        var isExporting = true
        defer { isExporting = false }
        var captionFiles: [URL] = []
        do {
            try await TimelineExporter.export(timeline, resolver: resolver, to: exportURL, options: options) { fraction in
                Task { @MainActor in
                    // Export callbacks may already be queued when the exporter
                    // returns. Do not let them replace finalizing or reopen a
                    // completed render's progress sheet, including after failure.
                    guard isExporting else { return }
                    onProgress(.exporting(fraction))
                }
            }
            isExporting = false
            switch options.captions {
            case .embedded:
                onProgress(.embeddingCaptions)
                try await embedCaptions(from: exportURL, to: outputURL, sequence: sequence, document: document, options: options, captions: captions)
            case .sidecar:
                onProgress(.writingCaptions)
                captionFiles = try await writeCaptionFiles(beside: outputURL, sequence: sequence, context: context, captions: captions)
            case .burnIn, .none:
                break
            }
        } catch {
            isExporting = false
            try? FileManager.default.removeItem(at: exportURL)
            try? FileManager.default.removeItem(at: outputURL)
            for file in captionFiles { try? FileManager.default.removeItem(at: file) }
            throw error
        }
        onProgress(.finalizing)
        guard case .film = destination else { return .file(outputURL, captionFiles: captionFiles) }

        let relative = storage.relativePath(for: outputURL) ?? "Renders/Sequences/\(sequence.id.uuidString)/\(outputURL.lastPathComponent)"
        let captionPaths = captionFiles.map { storage.relativePath(for: $0) ?? "Renders/Sequences/\(sequence.id.uuidString)/\($0.lastPathComponent)" }
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
            preset: options.video?.rawValue ?? "audio",
            captionFilePaths: captionPaths
        )
        context.insert(render)
        sequence.updatedAt = Date()
        try context.save()
        return .version(render)
    }

    /// Muxes one tx3g track per requested language into the exported movie.
    /// With no cues to write the movie is simply moved into place.
    private static func embedCaptions(
        from exportURL: URL, to outputURL: URL, sequence: SequenceProject, document: ProjectDocument,
        options: TimelineExporter.Options, captions: CaptionRenderRequest
    ) async throws {
        let tracks = try await SequenceCaptionSources.captionTracks(in: sequence, document: document, languages: captions.trackLanguages)
            .filter { !$0.cues.isEmpty }
        try? FileManager.default.removeItem(at: outputURL)
        guard !tracks.isEmpty else {
            try FileManager.default.moveItem(at: exportURL, to: outputURL)
            return
        }
        defer { try? FileManager.default.removeItem(at: exportURL) }
        try await SubtitleTrackMuxer.mux(
            movie: exportURL,
            tracks: tracks,
            style: SequenceCaptionSources.effectiveStyle(in: sequence),
            frameSize: options.outputSize(for: sequence.timeline.size) ?? sequence.timeline.size,
            duration: CMTime(seconds: sequence.timeline.duration, preferredTimescale: 600),
            fileType: options.container.fileType,
            to: outputURL
        )
    }

    /// One caption file per requested language beside the movie, named with
    /// the movie's stem. A language with no translation is skipped rather
    /// than failing the render.
    private static func writeCaptionFiles(
        beside movie: URL, sequence: SequenceProject, context: ModelContext, captions: CaptionRenderRequest
    ) async throws -> [URL] {
        guard let snapshot = SequenceCaptionSources.sidecarSnapshot(in: sequence, context: context) else { return [] }
        let stem = movie.deletingPathExtension().lastPathComponent
        let folder = movie.deletingLastPathComponent()
        var written: [URL] = []
        for language in captions.trackLanguages {
            let options = CaptionExportOptions(
                format: captions.sidecarFormat, granularity: .sentence, speakerStyle: .none,
                translationMode: language.isEmpty ? .originalOnly : .translationOnly, translationLanguage: language
            )
            let data: Data
            do {
                data = try await CaptionExporter.render(snapshot, options: options)
            } catch CaptionExportError.noTranslation {
                continue
            }
            let url = folder.appendingPathComponent(
                SequenceCaptionSources.sidecarFilename(movieStem: stem, languageCode: language, sourceLanguage: snapshot.sourceLanguage, format: captions.sidecarFormat)
            )
            try data.write(to: url, options: .atomic)
            written.append(url)
        }
        return written
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
        for path in render.captionFilePaths { storage.deleteFile(at: path) }
        context.delete(render)
    }

    static func deleteAll(for sequence: SequenceProject, context: ModelContext) {
        for render in renders(for: sequence, context: context) { delete(render, context: context) }
        ProjectStorage.forContainer(context.container).removeDirectory(
            ProjectStorage.forContainer(context.container).sequenceRenderDir(sequenceID: sequence.id)
        )
    }

    /// Copies the movie, and any caption files with it, renamed to the
    /// destination's stem so `Cut-v3.mp4` gets `Cut-v3.en.srt` beside it.
    static func export(_ render: SequenceRender, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: render.videoURL, to: destination)
        let sourceStem = render.videoURL.deletingPathExtension().lastPathComponent
        let destinationStem = destination.deletingPathExtension().lastPathComponent
        for file in render.captionFileURLs where fm.fileExists(atPath: file.path) {
            let suffix = file.lastPathComponent.dropFirst(sourceStem.count)
            let target = destination.deletingLastPathComponent().appendingPathComponent(destinationStem + suffix)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: file, to: target)
        }
    }
}
