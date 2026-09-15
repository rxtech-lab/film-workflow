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
        // Whisper reads the file off disk; every other provider uploads it, and
        // the film's own audio is usually uncompressed, so it is re-encoded to
        // speech-sized AAC first.
        guard provider != .whisperLocal else {
            return try await WhisperCaptionClient.transcribe(
                request: request,
                config: config,
                options: options,
                onProgress: onProgress
            )
        }
        let limit = perRequestByteLimit(provider)
        if CaptionAudioCompressor.willCompress(request, requiredBytes: limit) {
            await report(onProgress, .preparing(detail: "Compressing audio"))
        }
        let prepared = try await CaptionAudioCompressor.compressForUpload(request, requiredBytes: limit)
        defer {
            if let temporary = prepared.temporaryURL {
                try? FileManager.default.removeItem(at: temporary)
            }
        }

        switch provider {
        case .openAI:
            return try await transcribeOpenAI(
                request: prepared.request,
                config: config,
                options: options,
                onProgress: onProgress
            )
        case .gemini:
            return try await transcribeGemini(
                request: prepared.request,
                config: config,
                options: options,
                onProgress: onProgress
            )
        case .azure:
            return try await transcribeAzure(
                request: prepared.request,
                onProgress: onProgress
            )
        case .whisperLocal:
            // Handled above, before compression.
            throw CaptionTranscriberError.unsupportedAudio("Whisper does not run on the server.")
        }
    }

    /// The most one request may carry, for providers that cap it. Nil where the
    /// audio is split into chunks instead and its size alone can't fail.
    private static func perRequestByteLimit(_ provider: CaptionProvider) -> Int? {
        provider == .azure ? AzureFastTranscriptionClient.maxBytes : nil
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

        let model = await resolvedModel(
            for: "openai",
            configured: options.model.isEmpty ? config.subscriptionTranscriptionModel : options.model,
            fallback: OpenAITranscriptionClient.defaultModel
        )
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

    /// Gemini diarizes by prompt on the server; the reply is Gemini's own
    /// envelope, decoded by the same code the direct client used.
    ///
    /// Chunked like OpenAI because one server call is capped at five minutes
    /// of wall time. Speaker numbers restart per chunk — the same limitation
    /// the OpenAI path has, and the caption AI review is what reconciles it.
    private static func transcribeGemini(
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

        let model = await resolvedModel(
            for: "google",
            configured: options.model.isEmpty ? config.subscriptionTranscriptionModel : options.model,
            fallback: GeminiTranscriptionClient.defaultModel
        )
        var parts: [(transcript: CaptionTranscript, startMs: Int)] = []

        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            await report(onProgress, .transcribing(chunk: index + 1, totalChunks: chunks.count, fraction: nil))
            var fields: [(name: String, value: String)] = [
                ("provider", "gemini"),
                ("model", model),
                ("max_speakers", String(clampCaptionMaxSpeakers(request.maxSpeakers))),
            ]
            if !options.termsHint.isEmpty { fields.append(("prompt", options.termsHint)) }
            let language = request.languageHint.trimmingCharacters(in: .whitespacesAndNewlines)
            if !language.isEmpty { fields.append(("language", language)) }

            let data = try await upload(
                fields: fields,
                fileName: "audio",
                audioURL: chunk.url,
                mimeType: AudioProbe.mimeType(for: chunk.url)
            )
            let transcript = try GeminiTranscriptionClient.decode(
                data,
                fallbackDurationMs: chunk.durationMs
            )
            parts.append((transcript, chunk.startMs))
        }

        await report(onProgress, .buildingCues)
        let merged = CaptionAudioChunker.merge(
            parts,
            totalDurationMs: request.durationMs,
            providerName: CaptionProvider.gemini.rawValue
        )
        guard !merged.phrases.isEmpty else { throw CaptionTranscriberError.noSpeechFound }
        await CreditBalanceStore.shared.refresh()
        return merged
    }

    /// The model id to send for a provider, given one `subscriptionTranscriptionModel`
    /// shared by every provider.
    ///
    /// The configured id is used when the catalog says it belongs to this
    /// provider; a Whisper id must not be sent to Gemini just because it is
    /// what the user last picked. Otherwise the first catalog model for the
    /// provider, and failing that a known-good default.
    static func resolvedModel(for provider: String, configured: String, fallback: String) async -> String {
        let catalog = (try? await BackendModelCatalog.shared.models(capability: .transcription)) ?? []
        return resolvedModel(for: provider, configured: configured, fallback: fallback, catalog: catalog)
    }

    nonisolated static func resolvedModel(
        for provider: String,
        configured: String,
        fallback: String,
        catalog: [PickableModel]
    ) -> String {
        let wanted = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if !wanted.isEmpty, catalog.contains(where: { $0.id == wanted && $0.provider == provider }) {
            return wanted
        }
        if let first = catalog.first(where: { $0.provider == provider }) {
            return first.id
        }
        // No catalog at all (offline, or never fetched): honor a configured
        // id that at least looks like this provider's, else the default.
        if !wanted.isEmpty, catalog.isEmpty {
            let lower = wanted.lowercased()
            let looksRight = provider == "google" ? lower.contains("gemini") : !lower.contains("gemini")
            if looksRight { return wanted }
        }
        return fallback
    }

    private static func transcribeAzure(
        request: CaptionTranscribeRequest,
        onProgress: (@MainActor @Sendable (CaptionProgress) -> Void)?
    ) async throws -> CaptionTranscript {
        guard request.sizeBytes <= AzureFastTranscriptionClient.maxBytes else {
            let size = ByteCountFormatter.string(fromByteCount: Int64(request.sizeBytes), countStyle: .file)
            throw CaptionTranscriberError.unsupportedAudio(
                "Azure fast transcription accepts up to 300 MB, and this audio is \(size) even compressed. "
                + "Transcribe it with OpenAI or Gemini, which split long audio into parts."
            )
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
        do {
            return try await send(fields: fields, fileName: fileName, audioURL: audioURL, mimeType: mimeType)
        } catch let error as BackendError {
            // The model travels as a form field rather than an argument, so it
            // is read back out of `fields` — the server's refusal names it no
            // more here than it does for images or video.
            throw error.namingModel(
                fields.first { $0.name == "model" }?.value ?? "",
                capability: .transcription
            )
        }
    }

    private static func send(
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
