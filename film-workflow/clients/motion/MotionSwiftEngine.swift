import CoreGraphics
import Foundation
import ImageIO
import MotionCompiler
import MotionCore
import MotionPortable
import MotionRender
import MotionRuntime
import OSLog
import SkiaKit
import UniformTypeIdentifiers

/// Native Remotion rendering through MotionSwift (Skia on Metal). Film Studio projects
/// use the scaffold from `RemotionRuntime`: `src/index.ts` registers a `Main` composition and media
/// lives in `public/`. Everything here is blocking work and runs off the main actor.
enum MotionSwiftEngine {
    static let entry = "src/index.ts"
    static let compositionID = "Main"
    static let logger = Logger(subsystem: "com.rxlab.film-workflow", category: "MotionSwift")
    /// Identifies the renderer in cache keys: a new vendor graph (React/Remotion shim)
    /// or pipeline revision invalidates cached frames, previews and render versions.
    static var fingerprint: String { "motionswift-2-" + String(Vendor.sha256.prefix(12)) }

    /// A compiled project, ready to render frames.
    struct Prepared: @unchecked Sendable {
        let bundle: String
        /// The composition as registered by the project.
        let composition: Composition
        let publicDirectory: URL
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// Compilation keeps a retained module graph per project, so a second render or
    /// still of an unchanged project skips tsgo/esbuild. Serialized: the cache and the
    /// process-wide public directory are shared.
    private static let compileQueue = DispatchQueue(label: "com.rxlab.film-workflow.motionswift.compile")
    nonisolated(unsafe) private static let compiler = Compiler(cacheEnabled: true)
    /// Frame pipelines run one at a time. MotionSwift's render workers are plain threads
    /// that resolve `staticFile()` through the process-wide public directory (task-local
    /// scoping does not reach them), so two projects must not render concurrently.
    static let renderQueue = DispatchQueue(label: "com.rxlab.film-workflow.motionswift.render", qos: .userInitiated)

    /// Runs a frame pipeline for `prepared` with its public folder in effect.
    static func withProject<T>(_ prepared: Prepared, _ work: () throws -> T) rethrows -> T {
        dispatchPrecondition(condition: .onQueue(renderQueue))
        MediaSource.publicDirectory = prepared.publicDirectory
        return try MediaSource.withPublicDirectory(prepared.publicDirectory, operation: work)
    }

    static func prepare(projectDir: URL) async throws -> Prepared {
        try await run(on: compileQueue) {
            let project = projectDir.standardizedFileURL
            // Projects created before their entry files existed get the scaffold here.
            try RemotionRuntime.scaffold(at: project, includeComposition: false)
            let publicDirectory = project.appendingPathComponent("public", isDirectory: true)
            let bundle = try compiler.compile(project: project, entry: entry)
            let runtime = try Runtime(bundle: bundle)
            let compositions = try MediaSource.withPublicDirectory(publicDirectory) { try runtime.compositions() }
            guard let composition = compositions.first(where: { $0.id == compositionID }) ?? compositions.first else {
                throw Failure("The project does not register a composition.")
            }
            try composition.validate()
            return Prepared(bundle: bundle, composition: composition, publicDirectory: publicDirectory)
        }
    }

    /// The registered composition with the requested output size and frame rate, the way
    /// Remotion's renderer overrides them: layout happens at the new size, and the duration in
    /// seconds is kept when the frame rate changes.
    static func composition(_ base: Composition, width: Int?, height: Int?, fps: Double?) throws -> Composition {
        let rate = fps ?? base.fps
        let frames = rate == base.fps ? base.durationInFrames
            : max(1, Int((Double(base.durationInFrames) / base.fps * rate).rounded()))
        let object: [String: Any] = [
            "id": base.id, "width": width ?? base.width, "height": height ?? base.height,
            "fps": rate, "durationInFrames": frames,
        ]
        let composition = try JSONDecoder().decode(Composition.self, from: JSONSerialization.data(withJSONObject: object))
        try composition.validate()
        return composition
    }

    /// MotionSwift currently uses the registered dimensions for useVideoConfig(), even
    /// when FramePipeline receives an overridden composition. Override registrations
    /// before the runtime loads the entry, including on its per-frame module resets.
    /// This affects only this render's bundle; project source files stay untouched.
    static func renderBundle(_ bundle: String, composition: Composition) -> String {
        let registrationOverride = """
        (() => {
          const start = globalThis.__ms_start;
          globalThis.__ms_start = () => {
            const shim = __ms_require(__ms_ids.shim);
            for (const name of ['Composition', 'Still']) {
              const register = shim[name];
              shim[name] = props => register({...props, width: \(composition.width), height: \(composition.height)});
            }
            return start();
          };
        })();
        """
        // Keep the compiled bundle's line offsets intact for MotionSwift's stack mapper.
        return registrationOverride.split(separator: "\n").joined() + bundle
    }

    /// Worker threads for a render. Each GPU worker owns a JavaScript VM and a Metal
    /// context, so the app's "frames at a time" preference doubles as a ceiling.
    static func workerCount(frames: Int) -> Int {
        let automatic = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))
        let preferred = RemotionRenderPreferences.concurrency.map { $0 * 2 } ?? automatic
        return max(1, min(preferred, frames))
    }

    /// Renders one frame to a PNG at `width`×`height` composition pixels, scaled by
    /// `scale` (≤ 1 for thumbnails). `fps` re-times the frame number like a movie render.
    static func renderStill(projectDir: URL, frame: Int, width: Int, height: Int, fps: Double? = nil,
                            scale: Double = 1, to output: URL) async throws {
        let prepared = try await prepare(projectDir: projectDir)
        let composition = try composition(prepared.composition, width: width, height: height, fps: fps)
        let number = min(max(0, frame), composition.durationInFrames - 1)
        let scale = min(1, max(0.02, scale))
        let size = try Renderer.pixelSize(width: composition.width, height: composition.height, scale: scale)
        let cancellation = CancellationFlag()
        try await withTaskCancellationHandler {
            try await run(on: renderQueue) {
                var pixels: Data?
                try withProject(prepared) {
                    try FramePipeline.run(bundle: renderBundle(prepared.bundle, composition: composition), composition: composition, frames: [number], props: "{}",
                                          options: PipelineOptions(workers: 1, backend: .cpu, scale: scale)) { rendered in
                        try cancellation.check()
                        pixels = rendered.pixels
                    }
                }
                guard let pixels else { throw Failure("The still frame was not rendered.") }
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try writePNG(rgba: pixels, width: size.width, height: size.height, to: output)
            }
        } onCancel: { cancellation.cancel() }
    }

    /// Writes unpremultiplied, tightly packed RGBA8888 pixels as a PNG.
    static func writePNG(rgba: Data, width: Int, height: Int, to url: URL) throws {
        guard rgba.count == width * height * 4,
              let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure("Cannot encode the still frame.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure("Cannot write \(url.lastPathComponent).") }
    }

    /// Runs blocking work on a dispatch queue so it never ties up a cooperative thread.
    static func run<T: Sendable>(on queue: DispatchQueue, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Bridges Swift task cancellation into the synchronous MotionSwift frame consumer.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    func check() throws { if isCancelled { throw CancellationError() } }
}

/// MotionSwift's compiler and runtime messages (tsgo/esbuild diagnostics, JavaScript
/// stacks) are its `description`; surface them in alerts and agent tool results.
extension MotionError: @retroactive LocalizedError {
    public var errorDescription: String? { description }
}
