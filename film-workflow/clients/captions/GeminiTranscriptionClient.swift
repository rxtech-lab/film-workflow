import Foundation

/// Transcription via Gemini's multimodal `generateContent` with a structured
/// output schema.
///
/// Port of `debate-bot/internal/stt/gemini.go`. Diarizes by prompt, reusing the
/// `googleAIKey` the app already needs — no new credential.
///
/// Two limits are inherent to this approach and shape the rest of the feature:
/// it returns **no word timings**, and its phrase offsets are model-estimated,
/// so they can be non-monotonic. `CaptionTranscriptValidator.validateTiming`
/// plus the configured timing-fallback provider exist for exactly this.
nonisolated struct GeminiTranscriptionClient: CaptionTranscriberClient {
    static let provider = CaptionProvider.gemini

    /// Above this, the audio must go through the Files API instead of inline
    /// base64 — the request itself has a hard size ceiling.
    static let inlineLimitBytes = 18 * 1024 * 1024

    static let timeout: TimeInterval = 20 * 60
    static let defaultModel = "gemini-2.5-flash"

    /// Ported verbatim from `geminiSTTPrompt`. The explicit instructions about
    /// not estimating timestamps from text length, and about verifying
    /// monotonicity, measurably improve the output — do not "tidy" them away.
    static let promptTemplate = """
        Transcribe this audio with speaker diarization. Rules:
        - Identify distinct speakers and number them 1, 2, 3, ... in order of first appearance. Use at most %d speakers.
        - Split the transcript into complete sentences or complete speaker turns. Never split one sentence at a comma, colon, or other clause punctuation.
        - For each phrase, listen for the first and last spoken word and give its exact start offset and duration in milliseconds. Do not estimate timestamps from text length.
        - Offsets must be non-decreasing and every phrase must end within the audio's real duration. Before responding, verify that no later phrase starts earlier than a preceding phrase.
        - Keep the verbatim text with natural punctuation.
        - Also report the total audio duration in milliseconds as durationMs.
        Output only the JSON.
        """

    private static var responseSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "durationMs": ["type": "integer"],
                "phrases": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "speaker": ["type": "integer"],
                            "offsetMs": ["type": "integer"],
                            "durationMs": ["type": "integer"],
                            "text": ["type": "string"],
                        ],
                        "required": ["speaker", "offsetMs", "durationMs", "text"],
                    ],
                ],
            ],
            "required": ["durationMs", "phrases"],
        ]
    }

    @concurrent
    static func transcribe(
        request: CaptionTranscribeRequest,
        config: AppConfig,
        options: CaptionProviderOptions,
        onProgress: (@MainActor @Sendable (CaptionProgress) -> Void)?
    ) async throws -> CaptionTranscript {
        let key = config.googleAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw CaptionTranscriberError.notConfigured(
                .gemini, hint: "Add your Google AI API key in Settings › AI Provider."
            )
        }
        let model = options.model.isEmpty
            ? (config.geminiTranscriptionModel.isEmpty ? defaultModel : config.geminiTranscriptionModel)
            : options.model

        var prompt = String(format: promptTemplate, clampCaptionMaxSpeakers(request.maxSpeakers))
        let language = request.languageHint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !language.isEmpty {
            prompt += "\nThe audio is primarily in \(language)."
        }
        if !options.termsHint.isEmpty {
            // Names and jargon this recording uses. Spelled out as a hint rather
            // than a rule: forcing them would make the model insert terms it
            // never heard.
            prompt += "\nThese names and terms appear in the audio and are spelled "
                + "exactly like this: \(options.termsHint)."
        }

        // Small files ride along inline; large ones must be uploaded first.
        let audioPart: [String: Any]
        if request.sizeBytes <= inlineLimitBytes {
            await report(onProgress, .preparing(detail: "Encoding audio"))
            let data = try Data(contentsOf: request.audioURL, options: .mappedIfSafe)
            audioPart = [
                "inline_data": [
                    "mime_type": request.mimeType,
                    "data": data.base64EncodedString(),
                ]
            ]
        } else {
            let fileURI = try await uploadResumable(
                request.audioURL,
                mime: request.mimeType,
                sizeBytes: request.sizeBytes,
                apiKey: key,
                onProgress: onProgress
            )
            audioPart = [
                "file_data": ["mime_type": request.mimeType, "file_uri": fileURI]
            ]
        }

        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt], audioPart]]],
            "generationConfig": [
                "temperature": 0,
                "responseMimeType": "application/json",
                "responseSchema": responseSchema,
            ],
        ]

        guard let url = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        ) else {
            throw CaptionTranscriberError.invalidEndpoint(model)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = timeout

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let ticker = Task { @MainActor in
            var elapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                elapsed += 1
                onProgress?(.waitingForProvider(elapsedSeconds: elapsed))
            }
        }
        defer { ticker.cancel() }

        let (data, response) = try await session.data(for: urlRequest)
        ticker.cancel()

        guard let http = response as? HTTPURLResponse else {
            throw CaptionTranscriberError.invalidResponse(
                provider: "Gemini", detail: "not an HTTP response"
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CaptionHTTP.error(
                provider: "Gemini", data: data, response: http, headerKeys: []
            )
        }

        await report(onProgress, .buildingCues)
        return try decode(data, fallbackDurationMs: request.durationMs)
    }

    // MARK: - Files API

    /// Uploads via the resumable protocol and waits for the file to become
    /// ACTIVE. Gemini won't accept a file reference until processing completes.
    @concurrent
    private static func uploadResumable(
        _ url: URL,
        mime: String,
        sizeBytes: Int,
        apiKey: String,
        onProgress: (@MainActor @Sendable (CaptionProgress) -> Void)?
    ) async throws -> String {
        await report(onProgress, .preparing(detail: "Starting upload"))

        guard let startURL = URL(
            string: "https://generativelanguage.googleapis.com/upload/v1beta/files"
        ) else {
            throw CaptionTranscriberError.invalidEndpoint("Gemini Files API")
        }

        var start = URLRequest(url: startURL)
        start.httpMethod = "POST"
        start.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue("\(sizeBytes)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue(mime, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(
            withJSONObject: ["file": ["display_name": url.lastPathComponent]]
        )

        let (startData, startResponse) = try await URLSession.shared.data(for: start)
        guard let startHTTP = startResponse as? HTTPURLResponse else {
            throw CaptionTranscriberError.invalidResponse(
                provider: "Gemini", detail: "not an HTTP response"
            )
        }
        guard (200..<300).contains(startHTTP.statusCode) else {
            throw CaptionHTTP.error(
                provider: "Gemini upload", data: startData, response: startHTTP, headerKeys: []
            )
        }
        guard let uploadURLString = startHTTP.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let uploadURL = URL(string: uploadURLString) else {
            throw CaptionTranscriberError.invalidResponse(
                provider: "Gemini", detail: "no X-Goog-Upload-URL in the response"
            )
        }

        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        upload.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        upload.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        upload.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        upload.setValue("\(sizeBytes)", forHTTPHeaderField: "Content-Length")
        upload.timeoutInterval = timeout

        let delegate = CaptionUploadProgressDelegate { sent, total in
            Task { @MainActor in onProgress?(.uploading(bytesSent: sent, totalBytes: total)) }
        }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        // Stream from the file so a large upload never lands in memory.
        let (uploadData, uploadResponse) = try await session.upload(
            for: upload, fromFile: url, delegate: delegate
        )
        guard let uploadHTTP = uploadResponse as? HTTPURLResponse,
              (200..<300).contains(uploadHTTP.statusCode) else {
            let http = uploadResponse as? HTTPURLResponse
            throw CaptionHTTP.error(
                provider: "Gemini upload",
                data: uploadData,
                response: http ?? HTTPURLResponse(),
                headerKeys: []
            )
        }

        struct FileResponse: Decodable {
            struct File: Decodable {
                let name: String?
                let uri: String?
                let state: String?
            }
            let file: File?
        }
        let decoded = try? JSONDecoder().decode(FileResponse.self, from: uploadData)
        guard let file = decoded?.file, let uri = file.uri, let name = file.name else {
            throw CaptionTranscriberError.invalidResponse(
                provider: "Gemini",
                detail: CaptionHTTP.truncate(String(decoding: uploadData, as: UTF8.self), 400)
            )
        }

        if (file.state ?? "").uppercased() != "ACTIVE" {
            try await waitUntilActive(name: name, apiKey: apiKey, onProgress: onProgress)
        }
        return uri
    }

    /// Polls the file until it leaves PROCESSING. Capped so a stuck upload
    /// surfaces as an error rather than hanging the UI forever.
    private static func waitUntilActive(
        name: String,
        apiKey: String,
        onProgress: (@MainActor @Sendable (CaptionProgress) -> Void)?
    ) async throws {
        struct StateResponse: Decodable {
            let state: String?
        }
        let deadline = Date().addingTimeInterval(5 * 60)
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(name)") else {
            throw CaptionTranscriberError.invalidEndpoint(name)
        }

        while Date() < deadline {
            try Task.checkCancellation()
            await report(onProgress, .preparing(detail: "Waiting for Gemini to process the audio"))
            try await Task.sleep(for: .seconds(2))

            var request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            let (data, _) = try await URLSession.shared.data(for: request)
            let state = (try? JSONDecoder().decode(StateResponse.self, from: data))?.state?.uppercased()

            if state == "ACTIVE" { return }
            if state == "FAILED" {
                throw CaptionTranscriberError.invalidResponse(
                    provider: "Gemini", detail: "the uploaded file failed processing"
                )
            }
        }
        throw CaptionTranscriberError.invalidResponse(
            provider: "Gemini", detail: "the uploaded file never became active"
        )
    }

    // MARK: - Decoding

    static func decode(_ data: Data, fallbackDurationMs: Int) throws -> CaptionTranscript {
        struct Envelope: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String? }
                    let parts: [Part]?
                }
                let content: Content?
            }
            let candidates: [Candidate]?
        }
        struct Payload: Decodable {
            struct Phrase: Decodable {
                let speaker: Int?
                let offsetMs: Int?
                let durationMs: Int?
                let text: String?
            }
            let durationMs: Int?
            let phrases: [Phrase]?
        }

        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let json = envelope.candidates?.first?.content?.parts?
                  .compactMap(\.text).joined(),
              !json.isEmpty
        else {
            throw CaptionTranscriberError.invalidResponse(
                provider: "Gemini",
                detail: CaptionHTTP.truncate(String(decoding: data, as: UTF8.self), 400)
            )
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)) else {
            throw CaptionTranscriberError.invalidResponse(
                provider: "Gemini", detail: CaptionHTTP.truncate(json, 400)
            )
        }

        let phrases = (payload.phrases ?? []).compactMap { phrase -> CaptionPhrase? in
            let text = (phrase.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return CaptionPhrase(
                speaker: phrase.speaker ?? 0,
                offsetMs: max(phrase.offsetMs ?? 0, 0),
                durationMs: max(phrase.durationMs ?? 0, 0),
                text: text
                // No words: Gemini does not report word timings.
            )
        }
        guard !phrases.isEmpty else { throw CaptionTranscriberError.noSpeechFound }

        let duration = payload.durationMs.flatMap { $0 > 0 ? $0 : nil }
            ?? max(fallbackDurationMs, phrases.map(\.endMs).max() ?? 0)

        return CaptionTranscript(
            durationMs: duration,
            phrases: phrases,
            providerName: CaptionProvider.gemini.rawValue
        )
    }

    private static func report(
        _ onProgress: (@MainActor @Sendable (CaptionProgress) -> Void)?,
        _ progress: CaptionProgress
    ) async {
        guard let onProgress else { return }
        await MainActor.run { onProgress(progress) }
    }
}
