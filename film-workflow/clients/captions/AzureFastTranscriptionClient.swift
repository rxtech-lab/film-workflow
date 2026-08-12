import Foundation

/// Azure Speech **fast transcription** — synchronous, diarized, word-timed.
///
/// Port of `debate-bot/internal/stt/azure.go`. One POST returns the whole
/// transcript, so there is no polling and no job lifecycle to manage.
///
/// Note the host differs from TTS: fast transcription lives on
/// `{region}.api.cognitive.microsoft.com`, **not**
/// `{region}.tts.speech.microsoft.com`, so `AzureTTSClient.ttsURL` must not be
/// reused here. Only `AzureTTSClient.region(from:)` is shared.
nonisolated struct AzureFastTranscriptionClient: CaptionTranscriberClient {
    static let provider = CaptionProvider.azure

    static let apiVersion = "2025-10-15"

    /// Azure transcribes faster than real time, but a multi-hour file still
    /// takes minutes.
    static let timeout: TimeInterval = 30 * 60

    /// Documented per-request limits for the fast transcription endpoint.
    static let maxBytes = 300 * 1024 * 1024
    static let maxDurationMs = 2 * 60 * 60 * 1000

    @concurrent
    static func transcribe(
        request: CaptionTranscribeRequest,
        config: AppConfig,
        options: CaptionProviderOptions,
        onProgress: (@MainActor @Sendable (CaptionProgress) -> Void)?
    ) async throws -> CaptionTranscript {
        let key = config.azureSpeechKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !config.azureSpeechEndpoint.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw CaptionTranscriberError.notConfigured(
                .azure,
                hint: "Add your Azure Speech key and region in Settings › AI Provider."
            )
        }
        guard let url = transcriptionURL(from: config.azureSpeechEndpoint) else {
            throw CaptionTranscriberError.invalidEndpoint(config.azureSpeechEndpoint)
        }
        if request.sizeBytes > maxBytes {
            throw CaptionTranscriberError.unsupportedAudio(
                "Azure fast transcription accepts up to 300 MB; this file is "
                + ByteCountFormatter.string(fromByteCount: Int64(request.sizeBytes), countStyle: .file)
                + "."
            )
        }
        if request.durationMs > maxDurationMs {
            throw CaptionTranscriberError.unsupportedAudio(
                "Azure fast transcription accepts up to 2 hours per request."
            )
        }

        await report(onProgress, .preparing(detail: "Packaging audio for Azure"))

        // The definition field is a JSON *string* in a multipart form, not a
        // JSON body — see writeAzureMultipart in the Go reference.
        var definition: [String: Any] = [
            "profanityFilterMode": "None"
        ]
        if request.diarizationEnabled {
            definition["diarization"] = [
                "enabled": true,
                "maxSpeakers": clampCaptionMaxSpeakers(request.maxSpeakers),
            ]
        }
        let language = request.languageHint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !language.isEmpty {
            definition["locales"] = [language]
        }
        let definitionData = try JSONSerialization.data(withJSONObject: definition)
        let definitionJSON = String(decoding: definitionData, as: UTF8.self)

        let bodyURL = FileStorage.temporaryFileURL(extension: "multipart")
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let boundary = try CaptionHTTP.writeMultipartBody(
            fields: [(name: "definition", value: definitionJSON)],
            file: (
                name: "audio",
                filename: request.audioURL.lastPathComponent,
                mimeType: request.mimeType,
                url: request.audioURL
            ),
            to: bodyURL
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        urlRequest.timeoutInterval = timeout

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let delegate = CaptionUploadProgressDelegate { sent, total in
            Task { @MainActor in onProgress?(.uploading(bytesSent: sent, totalBytes: total)) }
        }

        // Once the body is fully sent, Azure goes quiet until it's done, so
        // switch to an elapsed-time ticker rather than leaving the UI frozen at
        // "100% uploaded".
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
                provider: "Azure", detail: "not an HTTP response"
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CaptionHTTP.error(
                provider: "Azure",
                data: data,
                response: http,
                hint: http.statusCode == 400
                    ? "The audio format may be unsupported, or api-version \(apiVersion) may not be enabled on this resource."
                    : nil
            )
        }

        await report(onProgress, .buildingCues)
        return try decode(data, fallbackDurationMs: request.durationMs)
    }

    /// Resolves the transcription URL.
    ///
    /// A pasted full endpoint is honoured verbatim (that's the
    /// `*.cognitiveservices.azure.com` case, where the first host label is the
    /// resource name and not a region, so synthesizing a region host would be
    /// wrong). A bare region string gets the standard host.
    static func transcriptionURL(from endpoint: String) -> URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let path = "/speechtotext/transcriptions:transcribe?api-version=\(apiVersion)"

        if let components = URLComponents(string: trimmed), let host = components.host {
            // Azure's TTS host doesn't serve transcription — rewrite it.
            let resolvedHost = host.contains(".tts.speech.microsoft.com")
                ? host.replacingOccurrences(
                    of: ".tts.speech.microsoft.com", with: ".api.cognitive.microsoft.com"
                )
                : host
            return URL(string: "https://\(resolvedHost)\(path)")
        }

        guard let region = AzureTTSClient.region(from: trimmed) else { return nil }
        return URL(string: "https://\(region).api.cognitive.microsoft.com\(path)")
    }

    // MARK: - Decoding

    private struct Response: Decodable {
        struct Phrase: Decodable {
            struct Word: Decodable {
                let text: String?
                let offsetMilliseconds: Int?
                let durationMilliseconds: Int?
            }
            let speaker: Int?
            let offsetMilliseconds: Int?
            let durationMilliseconds: Int?
            let text: String?
            let locale: String?
            let confidence: Double?
            let words: [Word]?
        }
        let durationMilliseconds: Int?
        let phrases: [Phrase]?
    }

    static func decode(_ data: Data, fallbackDurationMs: Int) throws -> CaptionTranscript {
        let document: Response
        do {
            document = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw CaptionTranscriberError.invalidResponse(
                provider: "Azure",
                detail: CaptionHTTP.truncate(String(decoding: data, as: UTF8.self), 400)
            )
        }

        let phrases = (document.phrases ?? []).compactMap { phrase -> CaptionPhrase? in
            let text = (phrase.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let words = (phrase.words ?? []).compactMap { word -> CaptionWordTiming? in
                guard let wordText = word.text, !wordText.isEmpty,
                      let offset = word.offsetMilliseconds,
                      let duration = word.durationMilliseconds
                else { return nil }
                return CaptionWordTiming(text: wordText, offsetMs: offset, durationMs: duration)
            }
            guard !text.isEmpty || !words.isEmpty else { return nil }

            return CaptionPhrase(
                // Azure reports 0 for non-diarized audio; the caption speaker
                // roster treats 0 as unknown, which is the right meaning.
                speaker: phrase.speaker ?? 0,
                offsetMs: phrase.offsetMilliseconds ?? 0,
                durationMs: phrase.durationMilliseconds ?? 0,
                text: text,
                locale: phrase.locale ?? "",
                words: words
            )
        }

        guard !phrases.isEmpty else { throw CaptionTranscriberError.noSpeechFound }

        let duration = document.durationMilliseconds.flatMap { $0 > 0 ? $0 : nil }
            ?? max(fallbackDurationMs, phrases.map(\.endMs).max() ?? 0)

        return CaptionTranscript(
            durationMs: duration,
            phrases: phrases.sorted { $0.offsetMs < $1.offsetMs },
            providerName: CaptionProvider.azure.rawValue,
            detectedLanguage: phrases.first { !$0.locale.isEmpty }?.locale ?? ""
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
