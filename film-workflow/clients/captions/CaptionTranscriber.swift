import Foundation

nonisolated enum CaptionTranscriberError: LocalizedError {
    case notConfigured(CaptionProvider, hint: String)
    case invalidEndpoint(String)
    case httpError(String)
    case invalidResponse(provider: String, detail: String)
    case noSpeechFound
    case unsupportedAudio(String)
    case modelNotInstalled(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let provider, let hint):
            return "\(provider.displayName) is not configured. \(hint)"
        case .invalidEndpoint(let endpoint):
            return "Could not build a transcription URL from \"\(endpoint)\"."
        case .httpError(let detail):
            return detail
        case .invalidResponse(let provider, let detail):
            return "Unexpected response from \(provider): \(detail)"
        case .noSpeechFound:
            return "No speech was found in this audio."
        case .unsupportedAudio(let detail):
            return "This audio can't be transcribed: \(detail)"
        case .modelNotInstalled(let variant):
            return "The Whisper model \"\(variant)\" isn't downloaded yet. Download it in Settings › Captions."
        }
    }
}

/// One transcription backend.
///
/// The repo doesn't use protocols for clients — `NarrativeGenerationService`
/// switches on the provider enum and calls statics. This keeps that shape while
/// making the switch a one-line dispatch: the requirements are `static`, so
/// every implementation stays a stateless `nonisolated struct` with
/// `@concurrent` statics (the `AzureTTSClient` pattern) and no actor hops.
nonisolated protocol CaptionTranscriberClient: Sendable {
    static var provider: CaptionProvider { get }

    static func transcribe(
        request: CaptionTranscribeRequest,
        config: AppConfig,
        options: CaptionProviderOptions,
        onProgress: (@MainActor @Sendable (CaptionProgress) -> Void)?
    ) async throws -> CaptionTranscript
}

nonisolated enum CaptionTranscriberFactory {
    static func client(for provider: CaptionProvider) -> any CaptionTranscriberClient.Type {
        switch provider {
        case .azure: return AzureFastTranscriptionClient.self
        case .openAI: return OpenAITranscriptionClient.self
        case .gemini: return GeminiTranscriptionClient.self
        case .whisperLocal: return WhisperCaptionClient.self
        }
    }

    /// Runs a provider, forwarding progress on the main actor.
    static func transcribe(
        provider: CaptionProvider,
        request: CaptionTranscribeRequest,
        config: AppConfig,
        options: CaptionProviderOptions,
        onProgress: (@MainActor @Sendable (CaptionProgress) -> Void)? = nil
    ) async throws -> CaptionTranscript {
        try await client(for: provider).transcribe(
            request: request,
            config: config,
            options: options,
            onProgress: onProgress
        )
    }
}

// MARK: - Shared HTTP helpers

nonisolated struct CaptionHTTP {

    /// Builds a `multipart/form-data` body **on disk** and returns its URL plus
    /// the boundary.
    ///
    /// Writing to disk instead of building a `Data` matters: a 300 MB upload
    /// buffered in memory is an immediate jetsam on iOS. Callers pair this with
    /// `URLSession.upload(for:fromFile:)`, which streams it.
    static func writeMultipartBody(
        fields: [(name: String, value: String)],
        file: (name: String, filename: String, mimeType: String, url: URL)?,
        to destination: URL
    ) throws -> String {
        let boundary = "----FilmWorkflowCaption\(UUID().uuidString)"
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        func write(_ string: String) throws {
            try handle.write(contentsOf: Data(string.utf8))
        }

        for field in fields {
            try write("--\(boundary)\r\n")
            try write("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n")
            try write("\(field.value)\r\n")
        }

        if let file {
            try write("--\(boundary)\r\n")
            try write(
                "Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\n"
            )
            try write("Content-Type: \(file.mimeType)\r\n\r\n")

            // Stream the audio through in chunks so peak memory stays flat
            // regardless of file size.
            let source = try FileHandle(forReadingFrom: file.url)
            defer { try? source.close() }
            while let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
            }
            try write("\r\n")
        }

        try write("--\(boundary)--\r\n")
        return boundary
    }

    /// Turns a non-2xx response into the most informative error available.
    ///
    /// Azure in particular returns 400 with an empty body for several distinct
    /// causes, so headers and an actionable hint are included — the same
    /// reasoning as `AzureTTSClient.httpError`.
    static func error(
        provider: String,
        data: Data,
        response: HTTPURLResponse,
        headerKeys: [String] = ["apim-request-id", "x-request-id", "x-ms-request-id"],
        hint: String? = nil
    ) -> CaptionTranscriberError {
        let status = response.statusCode
        var lines = ["\(provider) HTTP error: \(status)"]

        let rawBody = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = parseErrorMessage(data), !message.isEmpty {
            lines.append("Response: \(truncate(message, 800))")
        } else if !rawBody.isEmpty {
            lines.append("Response: \(truncate(rawBody, 800))")
        } else {
            lines.append("Response body was empty.")
        }

        for key in headerKeys {
            if let value = response.value(forHTTPHeaderField: key), !value.isEmpty {
                lines.append("\(key): \(value)")
            }
        }

        switch status {
        case 401, 403:
            lines.append("Check that the API key is correct and has access.")
        case 404:
            lines.append("This endpoint may not implement audio transcription.")
        case 413:
            lines.append("The audio file is too large for this provider.")
        case 429:
            lines.append("Rate limited. Wait a moment and try again.")
        default:
            break
        }
        if let hint { lines.append(hint) }

        print("[\(provider)] HTTP \(status). Raw body:\n\(rawBody.isEmpty ? "<empty>" : rawBody)")
        return .httpError(lines.joined(separator: "\n"))
    }

    static func parseErrorMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = json["error"] as? [String: Any] {
            if let message = error["message"] as? String { return message }
            if let code = error["code"] as? String { return code }
        }
        if let message = json["message"] as? String { return message }
        return nil
    }

    static func truncate(_ s: String, _ limit: Int) -> String {
        s.count <= limit ? s : String(s.prefix(limit)) + "…"
    }
}

/// Reports upload progress for a streamed request body.
///
/// `URLSession.data(for:)` exposes no upload progress, so the providers use
/// `upload(for:fromFile:delegate:)` with this. `@unchecked Sendable` is sound
/// here: the only stored property is an immutable `@Sendable` closure.
nonisolated final class CaptionUploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64, Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onProgress(totalBytesSent, totalBytesExpectedToSend)
    }
}

extension FileManager {
    fileprivate func createFile(atPath path: String, contents: Data?) {
        if fileExists(atPath: path) {
            try? removeItem(atPath: path)
        }
        createFile(atPath: path, contents: contents, attributes: nil)
    }
}
