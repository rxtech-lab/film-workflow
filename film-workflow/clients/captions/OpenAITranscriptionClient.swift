import Foundation

/// Transcription against any OpenAI-compatible `/v1/audio/transcriptions`
/// endpoint.
///
/// Returns word and segment timings via `verbose_json`, but has **no**
/// diarization — every phrase comes back on speaker 0 and speakers must be
/// assigned in the editor.
///
/// Be aware that many OpenAI-compatible gateways (OpenRouter, LM Studio) list
/// audio models but never implement this route; a 404 there is a routing gap,
/// not a bad key, which is why `CaptionHTTP.error` calls that case out.
nonisolated struct OpenAITranscriptionClient: CaptionTranscriberClient {
    static let provider = CaptionProvider.openAI

    static let timeout: TimeInterval = 15 * 60
    static let defaultModel = "whisper-1"

    @concurrent
    static func transcribe(
        request: CaptionTranscribeRequest,
        config: AppConfig,
        options: CaptionProviderOptions,
        onProgress: (@MainActor @Sendable (CaptionProgress) -> Void)?
    ) async throws -> CaptionTranscript {
        let endpoint = config.openAIEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = config.openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty, !key.isEmpty else {
            throw CaptionTranscriberError.notConfigured(
                .openAI,
                hint: "Add an OpenAI-compatible endpoint and key in Settings › AI Provider."
            )
        }
        let useGateway = isVercelGatewayEndpoint(endpoint)
        let url = useGateway
            ? try resolveGatewayTranscriptionURL(from: endpoint)
            : try resolveTranscriptionsURL(from: endpoint)

        let model = options.model.isEmpty
            ? (config.openAITranscriptionModel.isEmpty ? defaultModel : config.openAITranscriptionModel)
            : options.model

        await report(onProgress, .preparing(detail: "Checking audio size"))

        // Mandatory, not opportunistic: the hosted endpoint hard-rejects >25 MB.
        let chunks = try await CaptionAudioChunker.chunk(
            request.audioURL,
            durationMs: request.durationMs,
            sizeBytes: request.sizeBytes
        )
        defer { CaptionAudioChunker.cleanUp(chunks) }

        var parts: [(transcript: CaptionTranscript, startMs: Int)] = []

        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            await report(onProgress, .transcribing(
                chunk: index + 1, totalChunks: chunks.count, fraction: nil
            ))

            let transcript = useGateway
                ? try await transcribeOneViaGateway(
                    chunk: chunk,
                    url: url,
                    key: key,
                    model: model,
                    termsHint: options.termsHint,
                    request: request,
                    onProgress: onProgress
                )
                : try await transcribeOne(
                    chunk: chunk,
                    url: url,
                    key: key,
                    model: model,
                    termsHint: options.termsHint,
                    request: request,
                    chunkIndex: index,
                    chunkCount: chunks.count,
                    onProgress: onProgress
                )
            parts.append((transcript, chunk.startMs))
        }

        await report(onProgress, .buildingCues)

        let merged = CaptionAudioChunker.merge(
            parts,
            totalDurationMs: request.durationMs,
            providerName: CaptionProvider.openAI.rawValue
        )
        guard !merged.phrases.isEmpty else { throw CaptionTranscriberError.noSpeechFound }
        return merged
    }

    // MARK: - One request

    private static func transcribeOne(
        chunk: CaptionAudioChunker.Chunk,
        url: URL,
        key: String,
        model: String,
        termsHint: String,
        request: CaptionTranscribeRequest,
        chunkIndex: Int,
        chunkCount: Int,
        onProgress: (@MainActor @Sendable (CaptionProgress) -> Void)?
    ) async throws -> CaptionTranscript {
        var fields: [(name: String, value: String)] = [
            (name: "model", value: model),
            (name: "response_format", value: "verbose_json"),
        ]
        if !termsHint.isEmpty {
            // The documented use of `prompt` on this endpoint: a list of proper
            // nouns the model should prefer. It biases decoding rather than
            // constraining it.
            fields.append((name: "prompt", value: termsHint))
        }
        if request.wordTimestampsEnabled, modelSupportsWordTimings(model) {
            // Repeated bracketed keys — the array form this API expects.
            fields.append((name: "timestamp_granularities[]", value: "segment"))
            fields.append((name: "timestamp_granularities[]", value: "word"))
        }
        let language = request.languageHint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !language.isEmpty {
            // The API wants a bare ISO-639-1 code, not a full BCP-47 tag.
            fields.append((name: "language", value: String(language.prefix(2)).lowercased()))
        }

        let bodyURL = FileStorage.temporaryFileURL(extension: "multipart")
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let boundary = try CaptionHTTP.writeMultipartBody(
            fields: fields,
            file: (
                name: "file",
                filename: chunk.url.lastPathComponent,
                mimeType: AudioProbe.mimeType(for: chunk.url),
                url: chunk.url
            ),
            to: bodyURL
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = timeout

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let delegate = CaptionUploadProgressDelegate { sent, total in
            Task { @MainActor in onProgress?(.uploading(bytesSent: sent, totalBytes: total)) }
        }

        // Once the body is fully sent the endpoint goes quiet until it's done,
        // so switch to an elapsed-time ticker rather than leaving the UI frozen
        // at "100% uploaded" — mirrors `AzureFastTranscriptionClient`.
        let waitTicker = Task { @MainActor in
            var elapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                elapsed += 1
                onProgress?(.waitingForProvider(elapsedSeconds: elapsed))
            }
        }
        defer { waitTicker.cancel() }

        let (data, response) = try await session.upload(
            for: urlRequest, fromFile: bodyURL, delegate: delegate
        )
        waitTicker.cancel()

        guard let http = response as? HTTPURLResponse else {
            throw CaptionTranscriberError.invalidResponse(
                provider: "OpenAI", detail: "not an HTTP response"
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CaptionHTTP.error(
                provider: "OpenAI",
                data: data,
                response: http,
                headerKeys: ["x-request-id"],
                hint: http.statusCode == 404
                    ? "This gateway may not proxy /v1/audio/transcriptions. Try the provider's own endpoint."
                    : nil
            )
        }

        return try decodeVerboseJSON(data, fallbackDurationMs: chunk.durationMs)
    }

    // MARK: - Vercel AI Gateway

    /// The gateway speaks its own transcription protocol rather than proxying
    /// `/v1/audio/transcriptions`, which 404s there.
    ///
    /// Body is base64 JSON, the model rides in a header, and — unlike
    /// `verbose_json` — the response carries **no word timings at all**, only
    /// `{text, startSecond, endSecond}` segments. `modelSupportsWordTimings`
    /// reports that so the UI can hide the toggle instead of promising timings
    /// this route cannot produce.
    private static func transcribeOneViaGateway(
        chunk: CaptionAudioChunker.Chunk,
        url: URL,
        key: String,
        model: String,
        termsHint: String,
        request: CaptionTranscribeRequest,
        onProgress: (@MainActor @Sendable (CaptionProgress) -> Void)?
    ) async throws -> CaptionTranscript {
        var providerOptions: [String: String] = [:]
        if !termsHint.isEmpty { providerOptions["prompt"] = termsHint }
        let language = request.languageHint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !language.isEmpty {
            providerOptions["language"] = String(language.prefix(2)).lowercased()
        }

        let bodyURL = FileStorage.temporaryFileURL(extension: "json")
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        try writeGatewayBody(
            chunk: chunk, providerOptions: providerOptions, to: bodyURL
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Both version headers are mandatory: without them the gateway answers
        // 400 "Unsupported gateway protocol version". The published cURL sample
        // omits them; these values come from `@ai-sdk/gateway` itself.
        urlRequest.setValue("0.0.1", forHTTPHeaderField: "ai-gateway-protocol-version")
        urlRequest.setValue("4", forHTTPHeaderField: "ai-transcription-model-specification-version")
        urlRequest.setValue(model, forHTTPHeaderField: "ai-model-id")
        urlRequest.timeoutInterval = timeout

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let delegate = CaptionUploadProgressDelegate { sent, total in
            Task { @MainActor in onProgress?(.uploading(bytesSent: sent, totalBytes: total)) }
        }

        // The gateway answers in one shot, so the same elapsed-time ticker as
        // the multipart path keeps the UI honest while it works.
        let waitTicker = Task { @MainActor in
            var elapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                elapsed += 1
                onProgress?(.waitingForProvider(elapsedSeconds: elapsed))
            }
        }
        defer { waitTicker.cancel() }

        let (data, response) = try await session.upload(
            for: urlRequest, fromFile: bodyURL, delegate: delegate
        )
        waitTicker.cancel()

        guard let http = response as? HTTPURLResponse else {
            throw CaptionTranscriberError.invalidResponse(
                provider: "AI Gateway", detail: "not an HTTP response"
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CaptionHTTP.error(
                provider: "AI Gateway",
                data: data,
                response: http,
                headerKeys: ["x-request-id"],
                hint: nil
            )
        }

        return try decodeGatewayJSON(data, fallbackDurationMs: chunk.durationMs)
    }

    /// Streams the base64 straight to disk rather than building one giant
    /// `String`: a chunk is up to 25 MB, and base64 inflates it by a third.
    private static func writeGatewayBody(
        chunk: CaptionAudioChunker.Chunk,
        providerOptions: [String: String],
        to bodyURL: URL
    ) throws {
        let audio = try Data(contentsOf: chunk.url, options: .mappedIfSafe)
        let mediaType = AudioProbe.mimeType(for: chunk.url)

        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw CaptionTranscriberError.invalidResponse(
                provider: "AI Gateway", detail: "could not stage the request body"
            )
        }
        let handle = try FileHandle(forWritingTo: bodyURL)
        defer { try? handle.close() }

        try handle.write(contentsOf: Data(#"{"audio":""#.utf8))
        try handle.write(contentsOf: audio.base64EncodedData())

        var tail = #"","mediaType":"\#(mediaType)""#
        if !providerOptions.isEmpty,
           let encoded = try? JSONSerialization.data(withJSONObject: ["openai": providerOptions]) {
            tail += #","providerOptions":"# + String(decoding: encoded, as: UTF8.self)
        }
        tail += "}"
        try handle.write(contentsOf: Data(tail.utf8))
    }

    /// `https://ai-gateway.vercel.sh/v1` → `…/v4/ai/transcription-model`, since
    /// the transcription route lives outside the OpenAI-compatible `/v1` tree.
    static func resolveGatewayTranscriptionURL(from endpoint: String) throws -> URL {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), let host = components.host else {
            throw CaptionTranscriberError.invalidEndpoint(endpoint)
        }
        components.path = "/v4/ai/transcription-model"
        components.query = nil
        components.fragment = nil
        guard host == gatewayHost, let url = components.url else {
            throw CaptionTranscriberError.invalidEndpoint(endpoint)
        }
        return url
    }

    static let gatewayHost = "ai-gateway.vercel.sh"

    static func isVercelGatewayEndpoint(_ endpoint: String) -> Bool {
        URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))?
            .host?.lowercased() == gatewayHost
    }

    /// OpenAI's `gpt-4o*-transcribe` models don't implement `verbose_json`, so
    /// they return no timings however they're asked.
    static func modelSupportsWordTimings(_ model: String) -> Bool {
        !model.lowercased().contains("gpt-4o")
    }

    /// Normalizes whatever the user pasted, mirroring
    /// `OpenAIModelsClient.resolveModelsURL`.
    static func resolveTranscriptionsURL(from endpoint: String) throws -> URL {
        var trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }

        let candidate: String
        if trimmed.hasSuffix("/audio/transcriptions") {
            candidate = trimmed
        } else if trimmed.hasSuffix("/v1") || trimmed.contains("/v1/") {
            candidate = trimmed + "/audio/transcriptions"
        } else {
            candidate = trimmed + "/v1/audio/transcriptions"
        }

        guard let url = URL(string: candidate) else {
            throw CaptionTranscriberError.invalidEndpoint(endpoint)
        }
        return url
    }

    // MARK: - Decoding

    private struct Response: Decodable {
        struct Segment: Decodable {
            let start: Double?
            let end: Double?
            let text: String?
        }
        struct Word: Decodable {
            let word: String?
            let start: Double?
            let end: Double?
        }
        let text: String?
        let language: String?
        let duration: Double?
        let segments: [Segment]?
        let words: [Word]?
    }

    /// `verbose_json` reports **seconds as floats**; everything downstream is
    /// integer milliseconds, so convert at this boundary and nowhere else.
    static func decodeVerboseJSON(_ data: Data, fallbackDurationMs: Int) throws -> CaptionTranscript {
        let document: Response
        do {
            document = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw CaptionTranscriberError.invalidResponse(
                provider: "OpenAI",
                detail: CaptionHTTP.truncate(String(decoding: data, as: UTF8.self), 400)
            )
        }

        func ms(_ seconds: Double?) -> Int? {
            guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
            return Int((seconds * 1000).rounded())
        }

        let allWords: [CaptionWordTiming] = (document.words ?? []).compactMap { word in
            guard let text = word.word, !text.isEmpty,
                  let start = ms(word.start), let end = ms(word.end), end > start
            else { return nil }
            return CaptionWordTiming(text: text, offsetMs: start, durationMs: end - start)
        }

        var phrases: [CaptionPhrase] = []

        if let segments = document.segments, !segments.isEmpty {
            for segment in segments {
                let text = (segment.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard let start = ms(segment.start), let end = ms(segment.end), end > start else {
                    continue
                }
                guard !text.isEmpty else { continue }
                // Attach the words that fall inside this segment so cue building
                // can split on real word boundaries.
                let words = allWords.filter { $0.offsetMs >= start && $0.endMs <= end }
                phrases.append(CaptionPhrase(
                    speaker: 0, // no diarization
                    offsetMs: start,
                    durationMs: end - start,
                    text: text,
                    locale: document.language ?? "",
                    words: words
                ))
            }
        } else if let text = document.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty {
            // Some gateways honour verbose_json only partially and return plain
            // text; treat the whole file as one phrase rather than failing.
            let duration = ms(document.duration) ?? fallbackDurationMs
            phrases.append(CaptionPhrase(
                speaker: 0,
                offsetMs: 0,
                durationMs: max(duration, 1),
                text: text,
                locale: document.language ?? "",
                words: allWords
            ))
        }

        guard !phrases.isEmpty else { throw CaptionTranscriberError.noSpeechFound }

        let duration = ms(document.duration)
            ?? max(fallbackDurationMs, phrases.map(\.endMs).max() ?? 0)

        return CaptionTranscript(
            durationMs: duration,
            phrases: phrases,
            providerName: CaptionProvider.openAI.rawValue,
            detectedLanguage: document.language ?? ""
        )
    }

    private struct GatewayResponse: Decodable {
        struct Segment: Decodable {
            let text: String?
            let startSecond: Double?
            let endSecond: Double?
        }
        let text: String?
        let segments: [Segment]?
        let language: String?
        let durationInSeconds: Double?
    }

    /// Seconds as floats here too, but sentence-level only — the protocol has
    /// no word array, so every phrase comes back with empty `words`.
    static func decodeGatewayJSON(_ data: Data, fallbackDurationMs: Int) throws -> CaptionTranscript {
        let document: GatewayResponse
        do {
            document = try JSONDecoder().decode(GatewayResponse.self, from: data)
        } catch {
            throw CaptionTranscriberError.invalidResponse(
                provider: "AI Gateway",
                detail: CaptionHTTP.truncate(String(decoding: data, as: UTF8.self), 400)
            )
        }

        func ms(_ seconds: Double?) -> Int? {
            guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
            return Int((seconds * 1000).rounded())
        }

        var phrases: [CaptionPhrase] = []

        for segment in document.segments ?? [] {
            let text = (segment.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  let start = ms(segment.startSecond),
                  let end = ms(segment.endSecond), end > start
            else { continue }
            phrases.append(CaptionPhrase(
                speaker: 0, // no diarization
                offsetMs: start,
                durationMs: end - start,
                text: text,
                locale: document.language ?? "",
                words: []
            ))
        }

        if phrases.isEmpty,
           let text = document.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            // Some models return the transcript without segmenting it.
            let duration = ms(document.durationInSeconds) ?? fallbackDurationMs
            phrases.append(CaptionPhrase(
                speaker: 0,
                offsetMs: 0,
                durationMs: max(duration, 1),
                text: text,
                locale: document.language ?? "",
                words: []
            ))
        }

        guard !phrases.isEmpty else { throw CaptionTranscriberError.noSpeechFound }

        let duration = ms(document.durationInSeconds)
            ?? max(fallbackDurationMs, phrases.map(\.endMs).max() ?? 0)

        return CaptionTranscript(
            durationMs: duration,
            phrases: phrases,
            providerName: CaptionProvider.openAI.rawValue,
            detectedLanguage: document.language ?? ""
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
