import Foundation

nonisolated enum BackendTranscriptionClient {
    private static let directUploadThreshold = 4 * 1024 * 1024

    private struct UploadAuthorizationRequest: Encodable {
        let filename: String
        let contentType: String
        let sizeBytes: Int
    }

    private struct UploadAuthorization: Decodable {
        let uploadUrl: String
        let objectKey: String
        let headers: [String: String]
    }

    private struct StoredTranscriptionRequest: Encodable {
        let provider: String
        let model: String
        let objectKey: String
        let mimeType: String
        let filename: String
        let language: String?
        let prompt: String?
        let diarization: Bool?
        let maxSpeakers: Int?
    }

    static func transcribe(
        provider: CaptionProvider,
        request: CaptionTranscribeRequest,
        config: AppConfig,
        options: CaptionProviderOptions,
        onProgress: (@MainActor @Sendable (CaptionProgress) -> Void)?
    ) async throws -> CaptionTranscript {
        switch provider {
        case .openAI, .gemini:
            return try await transcribeOpenAI(
                request: request,
                config: config,
                options: options,
                onProgress: onProgress
            )
        case .azure:
            return try await transcribeAzure(
                request: request,
                onProgress: onProgress
            )
        case .whisperLocal:
            return try await WhisperCaptionClient.transcribe(
                request: request,
                config: config,
                options: options,
                onProgress: onProgress
            )
        }
    }

    private static func transcribeOpenAI(
        request: CaptionTranscribeRequest,
        config: AppConfig,
        options: CaptionProviderOptions,
        onProgress: (@MainActor @Sendable (CaptionProgress) -> Void)?
    ) async throws -> CaptionTranscript {
        await report(onProgress, .preparing(detail: "Checking audio size"))
        let chunks = try await CaptionAudioChunker.chunk(
            request.audioURL,
            durationMs: request.durationMs,
            sizeBytes: request.sizeBytes
        )
        defer { CaptionAudioChunker.cleanUp(chunks) }

        let configured = config.subscriptionTranscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configured.isEmpty ? "whisper-1" : configured
        var parts: [(transcript: CaptionTranscript, startMs: Int)] = []

        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            await report(onProgress, .transcribing(chunk: index + 1, totalChunks: chunks.count, fraction: nil))
            var fields: [(name: String, value: String)] = [
                ("provider", "openai"),
                ("model", model),
            ]
            if !options.termsHint.isEmpty { fields.append(("prompt", options.termsHint)) }
            let language = request.languageHint.trimmingCharacters(in: .whitespacesAndNewlines)
            if !language.isEmpty { fields.append(("language", String(language.prefix(2)).lowercased())) }

            let data = try await upload(
                fields: fields,
                fileName: "audio",
                audioURL: chunk.url,
                mimeType: AudioProbe.mimeType(for: chunk.url)
            )
            let transcript = try OpenAITranscriptionClient.decodeVerboseJSON(
                data,
                fallbackDurationMs: chunk.durationMs
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
        await CreditBalanceStore.shared.refresh()
        return merged
    }

    private static func transcribeAzure(
        request: CaptionTranscribeRequest,
        onProgress: (@MainActor @Sendable (CaptionProgress) -> Void)?
    ) async throws -> CaptionTranscript {
        guard request.sizeBytes <= AzureFastTranscriptionClient.maxBytes else {
            throw CaptionTranscriberError.unsupportedAudio("Azure fast transcription accepts up to 300 MB.")
        }
        await report(onProgress, .preparing(detail: "Packaging audio"))
        let fields: [(name: String, value: String)] = [
            ("provider", "azure"),
            ("model", "azure-fast-transcription"),
            ("language", request.languageHint),
            ("diarization", request.diarizationEnabled ? "true" : "false"),
            ("max_speakers", String(request.maxSpeakers)),
        ]
        await report(onProgress, .uploading(bytesSent: 0, totalBytes: Int64(request.sizeBytes)))
        let data = try await upload(
            fields: fields,
            fileName: "audio",
            audioURL: request.audioURL,
            mimeType: request.mimeType
        )
        await report(onProgress, .buildingCues)
        let transcript = try AzureFastTranscriptionClient.decode(data, fallbackDurationMs: request.durationMs)
        await CreditBalanceStore.shared.refresh()
        return transcript
    }

    private static func upload(
        fields: [(name: String, value: String)],
        fileName: String,
        audioURL: URL,
        mimeType: String
    ) async throws -> Data {
        let sizeBytes = try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if sizeBytes > directUploadThreshold {
            return try await uploadThroughS3(
                fields: fields,
                audioURL: audioURL,
                mimeType: mimeType,
                sizeBytes: sizeBytes
            )
        }

        let bodyURL = FileStorage.temporaryFileURL(extension: "multipart")
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        let boundary = try CaptionHTTP.writeMultipartBody(
            fields: fields,
            file: (
                name: fileName,
                filename: audioURL.lastPathComponent,
                mimeType: mimeType,
                url: audioURL
            ),
            to: bodyURL
        )
        return try await BackendClient.shared.upload(
            "api/v1/ai/transcriptions",
            fromFile: bodyURL,
            contentType: "multipart/form-data; boundary=\(boundary)",
            idempotencyKey: "transcription:\(UUID().uuidString)"
        )
    }

    private static func uploadThroughS3(
        fields: [(name: String, value: String)],
        audioURL: URL,
        mimeType: String,
        sizeBytes: Int
    ) async throws -> Data {
        let authorization: UploadAuthorization = try await BackendClient.shared.post(
            "api/v1/uploads",
            body: UploadAuthorizationRequest(
                filename: audioURL.lastPathComponent,
                contentType: mimeType,
                sizeBytes: sizeBytes
            )
        )
        guard let uploadURL = URL(string: authorization.uploadUrl) else {
            throw BackendError.badRequest("The storage service returned an invalid upload URL.")
        }

        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "PUT"
        uploadRequest.timeoutInterval = 30 * 60
        for (name, value) in authorization.headers {
            uploadRequest.setValue(value, forHTTPHeaderField: name)
        }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30 * 60
        configuration.timeoutIntervalForResource = 30 * 60
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (_, uploadResponse) = try await session.upload(for: uploadRequest, fromFile: audioURL)
        guard let uploadHTTP = uploadResponse as? HTTPURLResponse,
              (200..<300).contains(uploadHTTP.statusCode) else {
            throw BackendError.server((uploadResponse as? HTTPURLResponse)?.statusCode ?? 0, "The audio upload failed.")
        }

        let values = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value) })
        let body = StoredTranscriptionRequest(
            provider: values["provider"] ?? "openai",
            model: values["model"] ?? "whisper-1",
            objectKey: authorization.objectKey,
            mimeType: mimeType,
            filename: audioURL.lastPathComponent,
            language: values["language"],
            prompt: values["prompt"],
            diarization: values["diarization"].map { $0 == "true" },
            maxSpeakers: values["max_speakers"].flatMap(Int.init)
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try await BackendClient.shared.data(
            "api/v1/ai/transcriptions",
            method: "POST",
            body: encoder.encode(body),
            contentType: "application/json",
            idempotencyKey: "transcription:\(UUID().uuidString)"
        )
    }

    private static func report(
        _ handler: (@MainActor @Sendable (CaptionProgress) -> Void)?,
        _ progress: CaptionProgress
    ) async {
        guard let handler else { return }
        await MainActor.run { handler(progress) }
    }
}
