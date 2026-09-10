import AVFoundation
import Foundation

/// `cancelExport` is documented as safe from any thread; the box only exists
/// to say so to the compiler.
private final class SessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

public enum TimelineExportError: Error, Sendable {
    case cannotCreateSession
    case failed(String)
    case cancelled
}

/// Writes a timeline to an mp4 through `AVAssetExportSession`.
@MainActor
public enum TimelineExporter {
    public enum Preset: String, CaseIterable, Sendable, Codable {
        case h264
        case hevc

        public var displayName: String {
            switch self {
            case .h264: return "H.264"
            case .hevc: return "HEVC"
            }
        }

        var exportPreset: String {
            switch self {
            case .h264: return AVAssetExportPresetHighestQuality
            case .hevc: return AVAssetExportPresetHEVCHighestQuality
            }
        }
    }

    /// Renders `timeline` to `url`, replacing any existing file. Cancelling the
    /// task cancels the export and removes the partial file.
    public static func export(
        _ timeline: Timeline,
        resolver: any MediaResolver,
        to url: URL,
        preset: Preset,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let built = try await TimelineCompositionBuilder(resolver: resolver).build(timeline, allowPlaceholders: false)
        guard let session = AVAssetExportSession(asset: built.asset, presetName: preset.exportPreset) else {
            throw TimelineExportError.cannotCreateSession
        }
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        session.shouldOptimizeForNetworkUse = true
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let progressTask = Task {
            for await state in session.states(updateInterval: 0.25) {
                if case .exporting(let p) = state {
                    progress(p.fractionCompleted)
                }
            }
        }
        defer { progressTask.cancel() }

        let box = SessionBox(session)
        do {
            try await withTaskCancellationHandler {
                try await box.session.export(to: url, as: .mp4)
            } onCancel: {
                box.session.cancelExport()
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            if Task.isCancelled { throw TimelineExportError.cancelled }
            throw TimelineExportError.failed(error.localizedDescription)
        }
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: url)
            throw TimelineExportError.cancelled
        }
        progress(1)
    }
}
