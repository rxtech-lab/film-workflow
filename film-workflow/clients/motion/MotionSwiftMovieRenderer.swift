import CoreMedia
import Foundation
import MotionCore
import MotionRender
import SkiaKit

/// Exports a Film Studio Remotion project to a movie with MotionSwift.
enum MotionSwiftMovieRenderer {
    struct Request: Sendable {
        var projectDir: URL
        var output: URL
        var width: Int
        var height: Int
        var fps: Int
        var preserveAlpha: Bool
        /// Output pixels per composition pixel (≤ 1), as used for disposable previews.
        var captureScale: Double?
    }

    struct Update: Sendable {
        enum Stage: Sendable { case compiling, rendering, encoding }
        var stage: Stage
        var fraction: Double?
        var detail: String?
    }

    static func render(_ request: Request, onProgress: @escaping @Sendable (Update) -> Void) async throws {
        onProgress(.init(stage: .compiling, detail: String(localized: "Compiling natively")))
        let prepared = try await MotionSwiftEngine.prepare(projectDir: request.projectDir)
        try Task.checkCancellation()
        let composition = try MotionSwiftEngine.composition(prepared.composition, width: request.width,
                                                             height: request.height, fps: Double(request.fps))
        let cancellation = CancellationFlag()
        try await withTaskCancellationHandler {
            try await MotionSwiftEngine.run(on: MotionSwiftEngine.renderQueue) {
                try MotionSwiftEngine.withProject(prepared) {
                    try export(request, prepared: prepared, composition: composition, cancellation: cancellation, onProgress: onProgress)
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private static func export(_ request: Request, prepared: MotionSwiftEngine.Prepared, composition: Composition,
                               cancellation: CancellationFlag, onProgress: @escaping @Sendable (Update) -> Void) throws {
        let fm = FileManager.default
        let scale = min(1, max(0.05, request.captureScale ?? 1))
        let size = try Renderer.pixelSize(width: composition.width, height: composition.height, scale: scale)
        try fm.createDirectory(at: request.output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let work = request.output.deletingLastPathComponent()
            .appendingPathComponent(".motionswift-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let picture = work.appendingPathComponent("picture." + request.output.pathExtension)
        let writer = try MotionSwiftMovieWriter(output: picture, width: size.width, height: size.height,
                                                fps: composition.fps, codec: request.preserveAlpha ? .proRes4444 : .h264,
                                                cancellation: cancellation)
        let audio = MotionSwiftAudioMix(directory: work, fps: composition.fps)
        let frames = Array(0..<composition.durationInFrames)
        // Opaque H.264 takes the shared IOSurface path (no CPU readback); alpha needs the
        // readback because ProRes 4444 is fed straight-alpha-converted BGRA.
        let options = PipelineOptions(workers: MotionSwiftEngine.workerCount(frames: frames.count), backend: .gpu,
                                      scale: scale, sharedVideoFrames: !request.preserveAlpha)
        let start = Date()
        do {
            try FramePipeline.run(bundle: prepared.bundle, composition: composition, frames: frames, props: "{}",
                                  options: options) { frame in
                try cancellation.check()
                if let video = frame.videoFrame { try writer.append(video.pixelBuffer) } else { try writer.append(rgba: frame.pixels) }
                audio.append(frame.media)
                let done = frame.index + 1
                if done == frames.count || done.isMultiple(of: 5) {
                    let elapsed = Date().timeIntervalSince(start)
                    let rate = elapsed > 0 ? Double(done) / elapsed : 0
                    onProgress(.init(stage: .rendering, fraction: Double(done) / Double(frames.count),
                                     detail: String(localized: "Frame \(done) of \(frames.count) · \(Int(rate.rounded())) fps native")))
                }
            }
            onProgress(.init(stage: .encoding, fraction: nil, detail: String(localized: "Finishing video")))
            try writer.finish()
        } catch {
            writer.cancel()
            throw error
        }
        try cancellation.check()
        let duration = CMTime(value: CMTimeValue(frames.count) * 1000, timescale: CMTimeScale((composition.fps * 1000).rounded()))
        if let mix = try audio.render(cancellation: cancellation) {
            onProgress(.init(stage: .encoding, fraction: nil, detail: String(localized: "Mixing audio")))
            try MotionSwiftAudioMix.mux(video: picture, audio: mix, duration: duration)
        }
        try cancellation.check()
        if fm.fileExists(atPath: request.output.path) { try fm.removeItem(at: request.output) }
        try fm.moveItem(at: picture, to: request.output)
    }
}
