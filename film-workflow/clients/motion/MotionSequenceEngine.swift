import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import MotionCore
import MotionPortable
import MotionRender
import SkiaKit
import SwiftData
import VideoEditorCore

/// Sequences rendered by MotionSwift: the timeline becomes a generated Remotion-style film
/// (`MotionSequenceComposer`) whose video, image and audio clips are native MotionSwift media,
/// Remotion clips nested compositions, and Core Image work a host processor. Preview and export
/// share it, so Remotion clips no longer need rendering to movie files first.
@MainActor
enum MotionSequenceEngine {
    /// A compiled sequence and the processor its `process` keys resolve through.
    struct Compiled: @unchecked Sendable {
        let bundle: String
        let composition: Composition
        let film: MotionSequenceComposition
    }

    /// Installs the process-wide MotionSwift media processor once. Generated films register
    /// their own processors by token while they are in use.
    static func installProcessor() {
        guard !installed else { return }
        installed = true
        MediaProcessing.processor = { image, request in
            MotionSequenceProcessor.process(image, key: request.key, time: request.time,
                                            pixelWidth: request.pixelWidth, pixelHeight: request.pixelHeight)
        }
    }
    private static var installed = false

    /// Whether the viewer has anything to draw for this timeline. Every timeline renders
    /// through MotionSwift; there is no AVFoundation compositor fallback.
    static func previews(_ timeline: Timeline) -> Bool {
        !timeline.isEmpty
    }

    // MARK: Sources

    /// Resolves every clip the film reads. Remotion clips become nested projects read from
    /// disk; everything else goes through the document resolver.
    static func sources(for timeline: Timeline, document: ProjectDocument, resolver: any MediaResolver) async -> MotionSequenceSources {
        var sources = MotionSequenceSources()
        let context = document.container.mainContext
        var seen = Set<String>()
        for clip in timeline.renderedClips where seen.insert(clip.source.id).inserted {
            if clip.source.kind == .remotion {
                guard let (prefix, id) = DocumentMediaResolver.parse(clip.source.id), prefix == .remotion,
                      let project = try? context.fetch(FetchDescriptor<RemotionProject>(predicate: #Predicate { $0.id == id })).first,
                      let nested = try? nestedProject(project) else {
                    sources.failures[clip.source.id] = .missing(clip.source)
                    continue
                }
                sources.nested[clip.source.id] = nested
                continue
            }
            do {
                sources.media[clip.source.id] = try await resolver.resolve(clip.source)
            } catch let error as MediaResolverError {
                sources.failures[clip.source.id] = error
            } catch {
                sources.failures[clip.source.id] = .missing(clip.source)
            }
        }
        // Probe sizes and durations off the main actor.
        var files: [(URL, SourceKind)] = []
        for clip in timeline.renderedClips {
            if case .file(let url, _, _)? = sources.media[clip.source.id], !files.contains(where: { $0.0 == url }) {
                files.append((url, clip.source.kind))
            }
        }
        let reversedFiles = Set(timeline.renderedClips.filter(\.isReversed).compactMap { sources.media[$0.source.id]?.fileURL })
        let probed = await Task.detached(priority: .userInitiated) { () -> [(URL, CGSize?, TimeInterval?, URL?)] in
            var result: [(URL, CGSize?, TimeInterval?, URL?)] = []
            for (url, kind) in files {
                let reversed = reversedFiles.contains(url) ? try? await ReversedAudioCache.shared.file(for: url) : nil
                if kind == .image {
                    result.append((url, imageSize(url), nil, reversed))
                } else {
                    let (size, duration) = await videoInfo(url)
                    result.append((url, size, duration, reversed))
                }
            }
            return result
        }.value
        for (url, size, duration, reversed) in probed {
            if let size { sources.naturalSizes[url] = size }
            if let duration { sources.durations[url] = duration }
            if let reversed { sources.reversedAudio[url] = reversed }
        }
        return sources
    }

    /// A Remotion project's `src/` sources, scaffolded if needed.
    static func nestedProject(_ project: RemotionProject) throws -> MotionNestedProject {
        let directory = project.projectDir.standardizedFileURL
        try RemotionRuntime.scaffold(at: directory, includeComposition: false)
        let source = directory.appendingPathComponent("src/Composition.tsx")
        if !FileManager.default.fileExists(atPath: source.path), !project.compositionSource.isEmpty {
            try RemotionCodeBuilder.writeComposition(project: project, source: project.compositionSource)
        }
        return try nestedProject(at: directory)
    }

    /// The `src/` sources of the project folder at `directory`.
    nonisolated static func nestedProject(at directory: URL) throws -> MotionNestedProject {
        let directory = directory.standardizedFileURL
        let files = try PortableCompiler.sources(in: directory).filter { $0.key.hasPrefix("src/") }
        return MotionNestedProject(publicDirectory: directory.appendingPathComponent("public", isDirectory: true), files: files)
    }

    nonisolated static func imageSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Oriented size, as MotionSwift decodes with the preferred transform applied.
    nonisolated static func videoInfo(_ url: URL) async -> (CGSize?, TimeInterval?) {
        let asset = AVURLAsset(url: url)
        let duration = try? await CMTimeGetSeconds(asset.load(.duration))
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else {
            return (nil, duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
        }
        let oriented = CGRect(origin: .zero, size: natural).applying(transform).size
        return (CGSize(width: abs(oriented.width), height: abs(oriented.height)), duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
    }

    // MARK: Compile

    /// Composes and compiles a film. Compilation runs the portable compiler off the main actor.
    static func compile(_ timeline: Timeline, document: ProjectDocument, resolver: any MediaResolver,
                        options: MotionSequenceOptions) async throws -> Compiled {
        installProcessor()
        let sources = await sources(for: timeline, document: document, resolver: resolver)
        let film = try MotionSequenceComposer.compose(timeline, sources: sources, options: options)
        return try await compile(film)
    }

    /// Compiles an already composed film.
    static func compile(_ film: MotionSequenceComposition) async throws -> Compiled {
        installProcessor()
        let bundle = try await MotionSwiftEngine.run(on: compileQueue) {
            try GraphLinker.link(PortableCompiler().compile(files: film.files, entry: MotionSequenceComposition.entry))
        }
        let object: [String: Any] = ["id": MotionSequenceComposition.compositionID, "width": film.width, "height": film.height,
                                     "fps": film.fps, "durationInFrames": film.durationInFrames]
        let composition = try JSONDecoder().decode(Composition.self, from: JSONSerialization.data(withJSONObject: object))
        try composition.validate()
        return Compiled(bundle: bundle, composition: composition, film: film)
    }

    private static let compileQueue = DispatchQueue(label: "com.rxlab.film-workflow.motionswift.sequence-compile", qos: .userInitiated)

    // MARK: Export

    /// Writes `timeline` to `url` with MotionSwift. Captions follow `options.captions`;
    /// cancelling the task removes the partial file.
    static func export(_ timeline: Timeline, document: ProjectDocument, resolver: any MediaResolver, to url: URL,
                       options: TimelineExporter.Options, progress: @escaping @Sendable (Double) -> Void) async throws {
        let options = options.normalized
        guard options.video != nil || options.audio != nil else { throw TimelineExportError.nothingToExport }
        let compiled = try await compile(timeline, document: document, resolver: resolver, options: MotionSequenceOptions(
            includeCaptions: options.burnsInCaptions, audio: options.audio == nil ? .none : .all,
            allowPlaceholders: false, audioOnly: options.isAudioOnly))
        let output = options.outputSize(for: timeline.size)
        // Audio-only films still evaluate frames for their voices; draw them tiny.
        let scale = output.map { min(4, max(0.05, $0.width / max(1, timeline.size.width))) } ?? 0.05
        let codec: MotionSwiftMovieWriter.Codec = options.video == .hevc ? .hevc : .h264
        compiled.film.processor.register()
        defer { compiled.film.processor.unregister() }
        let cancellation = CancellationFlag()
        do {
            try await withTaskCancellationHandler {
                try await MotionSwiftEngine.run(on: MotionSwiftEngine.renderQueue) {
                    // Nested projects resolve staticFile() through StaticFileRoot, not the
                    // process-wide public folder.
                    try write(compiled, to: url, scale: scale, codec: codec, audioOnly: options.isAudioOnly,
                              includeAudio: options.audio != nil, cancellation: cancellation, progress: progress)
                }
            } onCancel: { cancellation.cancel() }
        } catch {
            try? FileManager.default.removeItem(at: url)
            if error is CancellationError || Task.isCancelled { throw TimelineExportError.cancelled }
            throw error
        }
        progress(1)
    }

    nonisolated static func write(_ compiled: Compiled, to url: URL, scale: Double, codec: MotionSwiftMovieWriter.Codec,
                                          audioOnly: Bool, includeAudio: Bool, cancellation: CancellationFlag,
                                          progress: @escaping @Sendable (Double) -> Void) throws {
        let fm = FileManager.default
        let composition = compiled.composition
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let work = url.deletingLastPathComponent().appendingPathComponent(".motionswift-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        var size = try Renderer.pixelSize(width: composition.width, height: composition.height, scale: scale)
        if !audioOnly {
            // Encoders want even dimensions; nudge the scale so both edges land on one.
            size = (max(2, size.width / 2 * 2), max(2, size.height / 2 * 2))
        }
        let picture = work.appendingPathComponent("picture." + (url.pathExtension == "m4a" ? "mov" : url.pathExtension))
        let writer = audioOnly ? nil : try MotionSwiftMovieWriter(output: picture, width: size.width, height: size.height,
                                                                  fps: composition.fps, codec: codec, cancellation: cancellation)
        let audio = MotionSwiftAudioMix(directory: work, fps: composition.fps)
        let frames = Array(0..<composition.durationInFrames)
        let renderScale = Double(size.width) / Double(composition.width)
        let options = PipelineOptions(workers: MotionSwiftEngine.workerCount(frames: frames.count), backend: .gpu,
                                      scale: audioOnly ? scale : renderScale, sharedVideoFrames: !audioOnly)
        do {
            try FramePipeline.run(bundle: compiled.bundle, composition: composition, frames: frames, props: "{}", options: options) { frame in
                try cancellation.check()
                if let writer {
                    if let video = frame.videoFrame { try writer.append(video.pixelBuffer) } else { try writer.append(rgba: frame.pixels) }
                }
                if includeAudio { audio.append(frame.media) }
                let done = frame.index + 1
                if done == frames.count || done.isMultiple(of: 5) { progress(Double(done) / Double(frames.count) * 0.95) }
            }
            try writer?.finish()
        } catch {
            writer?.cancel()
            throw error
        }
        try cancellation.check()
        let duration = CMTime(value: CMTimeValue(frames.count) * 1000, timescale: CMTimeScale((composition.fps * 1000).rounded()))
        let mix = includeAudio ? try audio.render(cancellation: cancellation) : nil
        try cancellation.check()
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        if audioOnly {
            guard let mix else { throw TimelineExportError.nothingToExport }
            try fm.moveItem(at: mix, to: url)
            return
        }
        if let mix { try MotionSwiftAudioMix.mux(video: picture, audio: mix, duration: duration) }
        try fm.moveItem(at: picture, to: url)
    }
}
