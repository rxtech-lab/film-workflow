import Foundation

enum BackendMusicClient {
    private struct Image: Encodable {
        let mimeType: String
        let base64: String
    }

    private struct Request: Encodable {
        let prompt: String
        let responseMimeType: String?
        let images: [Image]
    }

    private struct Started: Decodable {
        let jobId: String
        let status: String
        let pollUrl: String
    }

    private struct Job: Decodable {
        struct ResultMeta: Decodable {
            let mimeType: String?
            let lyricsText: String?
            let durationSeconds: Double?
            let chargedPoints: Int?
        }
        struct Failure: Decodable { let code: String?; let message: String? }
        let id: String
        let status: String
        let progressPercent: Int
        let resultUrl: String?
        let resultMeta: ResultMeta?
        let error: Failure?
    }

    static func generate(
        prompt: String,
        imageDataPairs: [(mimeType: String, base64: String)],
        responseMimeType: String?
    ) async throws -> LyriaResponse {
        let started: Started = try await BackendClient.shared.post(
            "api/v1/ai/music",
            body: Request(
                prompt: prompt,
                responseMimeType: responseMimeType,
                images: imageDataPairs.map { Image(mimeType: $0.mimeType, base64: $0.base64) }
            ),
            idempotencyKey: "music:\(UUID().uuidString)"
        )

        let deadline = Date().addingTimeInterval(20 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            let job: Job = try await BackendClient.shared.get(
                started.pollUrl.isEmpty ? "api/v1/jobs/\(started.jobId)" : started.pollUrl
            )
            switch job.status {
            case "succeeded":
                guard let rawURL = job.resultUrl, let url = URL(string: rawURL) else {
                    throw BackendError.decoding(LyriaError.noAudioInResponse)
                }
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw BackendError.server((response as? HTTPURLResponse)?.statusCode ?? 0, nil)
                }
                await CreditBalanceStore.shared.refresh()
                return LyriaResponse(
                    lyricsText: job.resultMeta?.lyricsText,
                    audioData: data,
                    mimeType: job.resultMeta?.mimeType ?? responseMimeType ?? "audio/wav"
                )
            case "failed", "cancelled":
                throw BackendError.jobFailed(failureText(job.error))
            default:
                try await Task.sleep(for: .seconds(2))
            }
        }
        throw BackendError.server(408, "Music generation timed out. The job may still finish in your account.")
    }

    /// What a failed job says, with its code.
    ///
    /// The server stores one sentence for every music failure — "Music
    /// generation could not be completed." — and keeps the reason in `code`
    /// (`PROVIDER_400:…`, `GOOGLE_AI_NOT_CONFIGURED`,
    /// `INVALID_PROVIDER_RESPONSE`). Reporting only the sentence leaves the
    /// caller nothing to act on and no way to tell a misconfigured account
    /// from a prompt the provider refused, so the code travels with it.
    private static func failureText(_ failure: Job.Failure?) -> String {
        let message = failure?.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = failure?.code?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (message?.isEmpty == false ? message : nil, code?.isEmpty == false ? code : nil) {
        case let (message?, code?): return "\(message) (\(code))"
        case let (message?, nil): return message
        case let (nil, code?): return "Music generation failed: \(code)"
        case (nil, nil): return "Music generation failed."
        }
    }
}
