import Foundation
import SwiftUI

enum VideoGenError: LocalizedError {
    case missingConfig
    case invalidEndpoint
    case invalidResponse
    case apiError(String)
    case httpError(Int, String?)
    case jobFailed(String)
    case timedOut(elapsed: TimeInterval)
    case noVideoInResponse
    /// A pending job from a build that called Google directly.
    case legacyJob

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "Video generation is not configured. Choose a model in Settings › AI Provider."
        case .invalidEndpoint:
            return "The video generation endpoint URL is invalid."
        case .invalidResponse:
            return "Invalid response from the video generation endpoint."
        case .apiError(let message):
            return "Video generation error: \(message)"
        case .httpError(let code, let body):
            if let body, !body.isEmpty {
                return "HTTP \(code): \(body)"
            }
            return "HTTP error: \(code)"
        case .jobFailed(let message):
            return "The provider could not generate this video: \(message)"
        case .timedOut(let elapsed):
            return "Gave up waiting after \(Int(elapsed / 60)) minutes. The job may still finish — reopen the project to resume it."
        case .noVideoInResponse:
            return "The job finished but returned no video."
        case .legacyJob:
            return "This job was started with your own Google key and can't be resumed. Generate the video again."
        }
    }
}

/// A handle to a generation running on the provider's side.
///
/// Persisted on the project (`VideoGenProject.pendingJobID`) so the app can
/// reconnect to a job it already paid for after a quit or a cancel.
nonisolated struct VideoGenJob: Sendable, Equatable {
    /// Google: the operation name, `models/…/operations/…`.
    let id: String
    let provider: VideoProvider
}

nonisolated struct VideoGenResult: Sendable {
    /// A file in `FileStorage.tempDir`. The caller is expected to move it.
    let fileURL: URL
    let fileExtension: String
}

/// Coarse progress for one generation.
///
/// An enum rather than the `fraction`-carrying `RenderProgress` struct, for the
/// same reason `CaptionProgress` is one: the phases are heterogeneous. Waiting
/// on Veo yields nothing but elapsed time, while an OpenAI-compatible job
/// reports a real percentage.
nonisolated enum VideoGenProgress: Sendable, Equatable {
    case submitting
    /// `percent` is nil for providers whose job status carries no progress —
    /// a Veo operation is only ever "not done" until it is.
    case processing(percent: Double?, elapsedSeconds: Int)
    case downloading(elapsedSeconds: Int)
    case saving

    var fraction: Double? {
        switch self {
        case .processing(let percent, _):
            guard let percent else { return nil }
            return min(max(percent / 100, 0), 1)
        case .submitting, .downloading, .saving:
            return nil
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .submitting: return "Submitting…"
        case .processing: return "Generating video…"
        case .downloading: return "Downloading video…"
        case .saving: return "Saving…"
        }
    }

    var detail: String {
        switch self {
        case .submitting, .saving:
            return ""
        case .downloading(let elapsed):
            return Self.elapsedText(elapsed)
        case .processing(let percent, let elapsed):
            let time = Self.elapsedText(elapsed)
            guard let percent else { return time }
            return "\(Int(percent))% · \(time)"
        }
    }

    private static func elapsedText(_ seconds: Int) -> String {
            seconds >= 60
                ? String(localized: "\(seconds / 60)m \(seconds % 60)s elapsed")
                : String(localized: "\(seconds)s elapsed")
    }
}

typealias VideoProgressHandler = @MainActor @Sendable (VideoGenProgress) -> Void

/// One image handed to the model, already loaded off disk.
nonisolated struct VideoInputImage: Sendable {
    let data: Data
    let mimeType: String

    init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }

    /// Reads a relative `images/…` path. Returns nil when the file is gone —
    /// a deleted reference should not abort a generation the user asked for.
    init?(relativePath: String, storage: ProjectStorage) {
        let url = storage.absoluteURL(for: relativePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.data = data
        self.mimeType = VideoInputImage.mimeType(forExtension: url.pathExtension)
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        default: return "image/png"
        }
    }
}
