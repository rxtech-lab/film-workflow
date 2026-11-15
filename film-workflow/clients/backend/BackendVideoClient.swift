import Foundation

/// Video generation through the RxFilm server.
///
/// The server submits the Veo job and hands back its own job id; the app only
/// ever polls `api/v1/jobs/{id}`, and the server finishes the job (download,
/// storage, billing) on the poll that finds it done. Split into `start` and
/// `awaitCompletion` for the same reason the direct client was: the job id is
/// persisted on the project before anything blocks, so a quit costs nothing
/// but time.
enum BackendVideoClient {
    /// Veo runs are minutes long; 4k/8s is the tail. Past this we stop waiting
    /// and tell the user the job can be resumed rather than hanging forever.
    static let defaultWaitTimeout: TimeInterval = 20 * 60

    private struct Image: Encodable {
        let mimeType: String
        let objectKey: String
    }

    private struct UploadRequest: Encodable {
        let filename: String
        let contentType: String
        let sizeBytes: Int
    }

    private struct UploadAuthorization: Decodable {
        let uploadUrl: String
        let objectKey: String
        let headers: [String: String]
    }

    nonisolated private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let handler: VideoProgressHandler?
        init(_ handler: VideoProgressHandler?) { self.handler = handler }
        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            let handler = handler
            Task { @MainActor in handler?(.uploading(sent: totalBytesSent, total: totalBytesExpectedToSend)) }
        }
    }

    private static func uploadImage(_ image: VideoInputImage?, onProgress: VideoProgressHandler?) async throws -> Image? {
        guard let image else { return nil }
        let authorization: UploadAuthorization = try await BackendClient.shared.post(
            "api/v1/uploads", body: UploadRequest(filename: "video-input", contentType: image.mimeType, sizeBytes: image.data.count)
        )
        guard let url = URL(string: authorization.uploadUrl), url.scheme == "https" else { throw VideoGenError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 300
        for (name, value) in authorization.headers { request.setValue(value, forHTTPHeaderField: name) }
        await report(onProgress, .uploading(sent: 0, total: Int64(image.data.count)))
        let delegate = UploadProgress(onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.upload(for: request, from: image.data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VideoGenError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0, "Image upload failed.")
        }
        return Image(mimeType: image.mimeType, objectKey: authorization.objectKey)
    }

    private struct Request: Encodable {
        let model: String
        let prompt: String
        let negativePrompt: String?
        let aspectRatio: String
        let resolution: String?
        let durationSeconds: Int
        let personGeneration: String
        let numberOfVideos: Int?
        let generateAudio: Bool?
        let seed: Int?
        let firstFrame: Image?
        let lastFrame: Image?
        let referenceImages: [Image]?
    }

    private struct Started: Decodable {
        let jobId: String
        let status: String
        let pollUrl: String
    }

    struct Job: Decodable {
        struct ResultMeta: Decodable {
            let mimeType: String?
            let durationSeconds: Double?
            let chargedPoints: Int?
            let model: String?
        }
        struct Failure: Decodable { let code: String?; let message: String? }
        let id: String
        let status: String
        let progressPercent: Int
        let resultUrl: String?
        let resultMeta: ResultMeta?
        let error: Failure?
    }

    /// Submits the generation and returns as soon as the server accepts it.
    static func start(
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
        idempotencyKey: String,
        onProgress: VideoProgressHandler? = nil
    ) async throws -> VideoGenJob {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty, !trimmedPrompt.isEmpty else {
            throw VideoGenError.missingConfig
        }
        let family = VeoModelFamily.from(trimmedModel)
        let trimmedNegative = negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        // The server applies the family's own omission rules again; sending
        // only what this family accepts keeps the request honest about what
        // the user chose.
        let uploadedFirst = try await uploadImage(firstFrame, onProgress: onProgress)
        let uploadedLast = try await uploadImage(lastFrame, onProgress: onProgress)
        var uploadedReferences: [Image] = []
        if family.supportsReferenceImages {
            for reference in referenceImages.prefix(family.maxReferenceImages) {
                if let image = try await uploadImage(reference, onProgress: onProgress) { uploadedReferences.append(image) }
            }
        }
        await report(onProgress, .submitting)
        let request = Request(
            model: trimmedModel,
            prompt: trimmedPrompt,
            negativePrompt: trimmedNegative.isEmpty ? nil : trimmedNegative,
            aspectRatio: aspectRatio.rawValue,
            resolution: family.resolutions.contains(resolution) ? resolution.rawValue : nil,
            durationSeconds: duration.seconds,
            personGeneration: personGeneration.rawValue,
            numberOfVideos: family.supportsNumberOfVideos ? max(1, min(numberOfVideos, family.maxVideos)) : nil,
            generateAudio: family.supportsAudio ? generateAudio : nil,
            seed: family.supportsSeed ? seed : nil,
            firstFrame: uploadedFirst,
            lastFrame: uploadedLast,
            referenceImages: uploadedReferences.isEmpty ? nil : uploadedReferences
        )

        let started: Started
        do {
            started = try await BackendClient.shared.post(
                "api/v1/ai/videos",
                body: request,
                idempotencyKey: idempotencyKey
            )
        } catch let error as BackendError {
            // The server's refusal names neither the model nor the capability;
            // this is the only layer that knows both.
            throw error.namingModel(trimmedModel, capability: .video)
        }
        guard !started.jobId.isEmpty else { throw VideoGenError.invalidResponse }
        return VideoGenJob(id: started.jobId, provider: .google)
    }

    /// Polls until the job finishes, then downloads the clip into `tempDir`.
    ///
    /// Safe to call on a job submitted by a previous app launch: nothing here
    /// depends on state held in memory, only on the job id.
    static func awaitCompletion(
        jobID: String,
        startedAt: Date = Date(),
        timeout: TimeInterval = defaultWaitTimeout,
        onProgress: VideoProgressHandler?
    ) async throws -> VideoGenResult {
        let job = try await waitForJob(
            jobID: jobID, startedAt: startedAt, timeout: timeout, onProgress: onProgress
        )
        guard let rawURL = job.resultUrl, let url = URL(string: rawURL) else {
            throw VideoGenError.noVideoInResponse
        }
        let result = try await download(
            url: url, mimeType: job.resultMeta?.mimeType,
            startedAt: startedAt, onProgress: onProgress
        )
        await CreditBalanceStore.shared.refresh()
        return result
    }

    /// A failed status request says nothing about the provider's job. Retry
    /// read-only polls within the overall wait budget; never resubmit here.
    static func waitForJob(
        jobID: String,
        startedAt: Date,
        timeout: TimeInterval = defaultWaitTimeout,
        onProgress: VideoProgressHandler? = nil,
        fetchJob: (String) async throws -> Job = { try await BackendClient.shared.get("api/v1/jobs/\($0)") },
        sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async throws -> Job {
        let deadline = Date().addingTimeInterval(timeout)
        var interval: TimeInterval = 3
        var lastPercent: Double?

        while Date() < deadline {
            try Task.checkCancellation()
            do {
                let job = try await fetchJob(jobID)
                switch job.status {
                case "succeeded":
                    return job
                case "failed", "cancelled":
                    throw VideoGenError.jobFailed(job.error?.message ?? "Video generation failed.")
                default:
                    lastPercent = job.progressPercent > 0 ? Double(job.progressPercent) : nil
                }
            } catch BackendError.badRequest(let message) {
                // A rejected poll (including a missing job) cannot recover.
                throw VideoGenError.jobFailed(message)
            } catch {
                try Task.checkCancellation()
                guard isTransientPollError(error) else { throw error }
            }

            await report(onProgress, .processing(
                percent: lastPercent, elapsedSeconds: Int(Date().timeIntervalSince(startedAt))
            ))
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            try await sleep(min(interval, remaining))
            interval = min(interval + 1, 10)
        }

        throw VideoGenError.timedOut(elapsed: Date().timeIntervalSince(startedAt))
    }

    static func isTransientPollError(_ error: Error) -> Bool {
        if let error = error as? URLError {
            switch error.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }
        if case BackendError.server(let status, _) = error {
            return status == 408 || status == 429 || (500...599).contains(status)
        }
        return false
    }

    // MARK: - Helpers

    private static func download(
        url: URL,
        mimeType: String?,
        startedAt: Date,
        onProgress: VideoProgressHandler?
    ) async throws -> VideoGenResult {
        let ticker = Task { @MainActor in
            var elapsed = Int(Date().timeIntervalSince(startedAt))
            while !Task.isCancelled {
                onProgress?(.downloading(elapsedSeconds: elapsed))
                try? await Task.sleep(for: .seconds(1))
                elapsed += 1
            }
        }
        defer { ticker.cancel() }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let (tempURL, response) = try await session.download(from: url)
        ticker.cancel()

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tempURL)
            throw VideoGenError.httpError(http.statusCode, nil)
        }

        // `download(from:)` hands back a file the system may reclaim, so move
        // it somewhere we own before returning.
        let ext = extensionFor(mimeType: mimeType)
        let destination = FileStorage.temporaryFileURL(extension: ext)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return VideoGenResult(fileURL: destination, fileExtension: ext)
    }

    private static func report(_ handler: VideoProgressHandler?, _ progress: VideoGenProgress) async {
        guard let handler else { return }
        await MainActor.run { handler(progress) }
    }

    private static func extensionFor(mimeType: String?) -> String {
        switch (mimeType ?? "").lowercased() {
        case "video/quicktime": return "mov"
        case "video/webm": return "webm"
        default: return "mp4"
        }
    }
}
