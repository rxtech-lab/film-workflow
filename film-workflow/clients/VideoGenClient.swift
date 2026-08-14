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

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "Video generation is not configured. Set credentials in Settings."
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
        seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s elapsed" : "\(seconds)s elapsed"
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
    init?(relativePath: String) {
        let url = FileStorage.absoluteURL(for: relativePath)
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

/// The decoded state of a Veo long-running operation.
nonisolated struct GoogleVeoOperation: Sendable {
    let done: Bool
    let videoURIs: [String]
    let mimeType: String?
    let errorMessage: String?
}

struct VideoGenClient {
    /// Veo runs are minutes long; 4k/8s is the tail. Past this we stop waiting
    /// and tell the user the job can be resumed rather than hanging forever.
    static let defaultWaitTimeout: TimeInterval = 20 * 60

    private static let baseURL = "https://generativelanguage.googleapis.com/v1beta"

    // MARK: - Google (Veo via the Gemini API)

    /// Submits the generation and returns as soon as the provider accepts it.
    ///
    /// Deliberately separate from the wait loop: the operation name has to be
    /// persisted before anything can block, or a crash between submit and
    /// completion loses a job that has already been billed.
    static func startGoogleVeo(
        prompt: String,
        negativePrompt: String,
        model: String,
        aspectRatio: VideoAspectRatio,
        resolution: VideoResolution,
        duration: VideoDuration,
        personGeneration: VideoPersonGeneration,
        numberOfVideos: Int,
        generateAudio: Bool,
        seed: Int?,
        firstFrame: VideoInputImage?,
        lastFrame: VideoInputImage?,
        referenceImages: [VideoInputImage],
        apiKey: String
    ) async throws -> VideoGenJob {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedModel.isEmpty, !trimmedPrompt.isEmpty else {
            throw VideoGenError.missingConfig
        }

        guard let url = URL(string: "\(baseURL)/models/\(trimmedModel):predictLongRunning") else {
            throw VideoGenError.invalidEndpoint
        }

        let family = VeoModelFamily.from(trimmedModel)

        var instance: [String: Any] = ["prompt": trimmedPrompt]
        if let firstFrame {
            instance["image"] = inlineData(firstFrame)
        }
        if let lastFrame {
            instance["lastFrame"] = inlineData(lastFrame)
        }
        if family.supportsReferenceImages, !referenceImages.isEmpty {
            instance["referenceImages"] = referenceImages.map { image in
                ["image": inlineData(image), "referenceType": "asset"]
            }
        }

        // Every parameter the selected family does not support is omitted
        // rather than sent with a default — Veo rejects unknown combinations.
        var parameters: [String: Any] = [
            "aspectRatio": aspectRatio.rawValue,
            // Number, not the enum's string rawValue — Veo rejects `"4"`.
            "durationSeconds": duration.seconds,
            "personGeneration": personGeneration.rawValue
        ]
        if family.supportsNumberOfVideos {
            parameters["numberOfVideos"] = max(1, min(numberOfVideos, family.maxVideos))
        }
        if family.resolutions.contains(resolution) {
            parameters["resolution"] = resolution.rawValue
        }
        if family.supportsAudio {
            parameters["generateAudio"] = generateAudio
        }
        if family.supportsSeed, let seed {
            parameters["seed"] = seed
        }
        let trimmedNegative = negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNegative.isEmpty {
            parameters["negativePrompt"] = trimmedNegative
        }

        let body: [String: Any] = [
            "instances": [instance],
            "parameters": parameters
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(trimmedKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try throwHTTPError(http.statusCode, data: data)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String, !name.isEmpty else {
            throw VideoGenError.invalidResponse
        }
        return VideoGenJob(id: name, provider: .google)
    }

    static func pollGoogleVeo(operationName: String, apiKey: String) async throws -> GoogleVeoOperation {
        guard let url = URL(string: "\(baseURL)/\(operationName)") else {
            throw VideoGenError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try throwHTTPError(http.statusCode, data: data)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VideoGenError.invalidResponse
        }

        let done = (json["done"] as? Bool) ?? false
        let errorMessage = (json["error"] as? [String: Any])?["message"] as? String

        var uris: [String] = []
        var mimeType: String?
        if let responseObject = json["response"] as? [String: Any],
           let generate = responseObject["generateVideoResponse"] as? [String: Any],
           let samples = generate["generatedSamples"] as? [[String: Any]] {
            for sample in samples {
                guard let video = sample["video"] as? [String: Any] else { continue }
                if let uri = video["uri"] as? String { uris.append(uri) }
                if mimeType == nil { mimeType = video["mimeType"] as? String }
            }
        }

        return GoogleVeoOperation(done: done, videoURIs: uris, mimeType: mimeType, errorMessage: errorMessage)
    }

    /// Downloads the finished clip into `tempDir`.
    ///
    /// The file URI redirects to a signed storage host, and URLSession drops
    /// custom headers across that hop, so the delegate re-applies the API key.
    static func downloadGoogleVideo(
        uri: String,
        apiKey: String,
        mimeType: String?,
        startedAt: Date,
        onProgress: VideoProgressHandler?
    ) async throws -> VideoGenResult {
        guard let url = URL(string: uri) else { throw VideoGenError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 600

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let ticker = Task { @MainActor in
            var elapsed = Int(Date().timeIntervalSince(startedAt))
            while !Task.isCancelled {
                onProgress?(.downloading(elapsedSeconds: elapsed))
                try? await Task.sleep(for: .seconds(1))
                elapsed += 1
            }
        }
        defer { ticker.cancel() }

        let delegate = AuthPreservingRedirectDelegate(headers: ["x-goog-api-key": apiKey])
        let (tempURL, response) = try await session.download(for: request, delegate: delegate)
        ticker.cancel()

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = try? String(contentsOf: tempURL, encoding: .utf8)
            try? FileManager.default.removeItem(at: tempURL)
            throw VideoGenError.httpError(http.statusCode, body)
        }

        // `download(for:)` hands back a file the system may reclaim, so move it
        // somewhere we own before returning.
        let ext = extensionFor(mimeType: mimeType)
        let destination = FileStorage.temporaryFileURL(extension: ext)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)

        return VideoGenResult(fileURL: destination, fileExtension: ext)
    }

    // MARK: - Wait loop

    /// Polls until the job finishes, then downloads it.
    ///
    /// Safe to call on a job submitted by a previous app launch: nothing here
    /// depends on state held in memory, only on the operation name.
    static func awaitGoogleCompletion(
        operationName: String,
        apiKey: String,
        startedAt: Date = Date(),
        timeout: TimeInterval = defaultWaitTimeout,
        onProgress: VideoProgressHandler?
    ) async throws -> VideoGenResult {
        let deadline = Date().addingTimeInterval(timeout)
        // Backs off from a snappy first check to a polite steady state: Veo
        // takes minutes, and polling every 3s for all of it is pure noise.
        var interval = 3

        while Date() < deadline {
            try Task.checkCancellation()

            let elapsed = Int(Date().timeIntervalSince(startedAt))
            await report(onProgress, .processing(percent: nil, elapsedSeconds: elapsed))

            let operation = try await pollGoogleVeo(operationName: operationName, apiKey: apiKey)

            if let message = operation.errorMessage, !message.isEmpty {
                throw VideoGenError.jobFailed(message)
            }
            if operation.done {
                guard let uri = operation.videoURIs.first else {
                    throw VideoGenError.noVideoInResponse
                }
                return try await downloadGoogleVideo(
                    uri: uri,
                    apiKey: apiKey,
                    mimeType: operation.mimeType,
                    startedAt: startedAt,
                    onProgress: onProgress
                )
            }

            try await Task.sleep(for: .seconds(interval))
            interval = min(interval + 1, 10)
        }

        throw VideoGenError.timedOut(elapsed: Date().timeIntervalSince(startedAt))
    }

    // MARK: - Helpers

    private static func inlineData(_ image: VideoInputImage) -> [String: Any] {
        ["inlineData": ["mimeType": image.mimeType, "data": image.data.base64EncodedString()]]
    }

    private static func report(_ handler: VideoProgressHandler?, _ progress: VideoGenProgress) async {
        guard let handler else { return }
        await MainActor.run { handler(progress) }
    }

    private static func throwHTTPError(_ status: Int, data: Data) throws -> Never {
        let bodyString = String(data: data, encoding: .utf8)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw VideoGenError.apiError(message)
        }
        throw VideoGenError.httpError(status, bodyString)
    }

    private static func extensionFor(mimeType: String?) -> String {
        switch (mimeType ?? "").lowercased() {
        case "video/quicktime": return "mov"
        case "video/webm": return "webm"
        default: return "mp4"
        }
    }
}

/// Re-applies auth headers when a download is redirected to another host.
///
/// URLSession strips custom headers on a cross-origin redirect, which is
/// exactly what the Gemini file URI does on its way to signed storage — without
/// this the download comes back 403.
private final class AuthPreservingRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let headers: [String: String]

    init(headers: [String: String]) {
        self.headers = headers
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var updated = request
        for (field, value) in headers {
            updated.setValue(value, forHTTPHeaderField: field)
        }
        completionHandler(updated)
    }
}
