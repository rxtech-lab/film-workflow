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
        let base64: String

        init(_ image: VideoInputImage) {
            mimeType = image.mimeType
            base64 = image.data.base64EncodedString()
        }
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

    private struct Job: Decodable {
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
        idempotencyKey: String
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
            firstFrame: firstFrame.map(Image.init),
            lastFrame: lastFrame.map(Image.init),
            referenceImages: family.supportsReferenceImages && !referenceImages.isEmpty
                ? referenceImages.map(Image.init)
                : nil
        )

        let started: Started = try await BackendClient.shared.post(
            "api/v1/ai/videos",
            body: request,
            idempotencyKey: idempotencyKey
        )
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
        let deadline = Date().addingTimeInterval(timeout)
        // Backs off from a snappy first check to a polite steady state: Veo
        // takes minutes, and polling every 3s for all of it is pure noise.
        var interval = 3

        while Date() < deadline {
            try Task.checkCancellation()

            let job: Job
            do {
                job = try await BackendClient.shared.get("api/v1/jobs/\(jobID)")
            } catch BackendError.badRequest(let message) {
                // `BackendClient` folds every 4xx into this case; on a poll
                // that means the server no longer knows the job (404), so
                // there is nothing left to resume. Treat it like a provider
                // failure so the project stops offering to.
                throw VideoGenError.jobFailed(message)
            }

            switch job.status {
            case "succeeded":
                guard let rawURL = job.resultUrl, let url = URL(string: rawURL) else {
                    throw VideoGenError.noVideoInResponse
                }
                let result = try await download(
                    url: url,
                    mimeType: job.resultMeta?.mimeType,
                    startedAt: startedAt,
                    onProgress: onProgress
                )
                await CreditBalanceStore.shared.refresh()
                return result
            case "failed", "cancelled":
                throw VideoGenError.jobFailed(job.error?.message ?? "Video generation failed.")
            default:
                let elapsed = Int(Date().timeIntervalSince(startedAt))
                // The server's percentage is an elapsed-time estimate until
                // the provider reports done; still better than nothing.
                let percent = job.progressPercent > 0 ? Double(job.progressPercent) : nil
                await report(onProgress, .processing(percent: percent, elapsedSeconds: elapsed))
            }

            try await Task.sleep(for: .seconds(interval))
            interval = min(interval + 1, 10)
        }

        throw VideoGenError.timedOut(elapsed: Date().timeIntervalSince(startedAt))
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
