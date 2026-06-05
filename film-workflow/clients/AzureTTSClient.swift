import Foundation

enum AzureTTSError: LocalizedError {
    case noAPIKey
    case noEndpoint
    case noSpeakers
    case invalidResponse
    case apiError(String)
    case httpError(Int)
    case detailedHTTPError(String)
    /// A retryable failure (HTTP 429 / 5xx). Carries the server's `Retry-After` hint when present.
    case transientHTTPError(status: Int, retryAfter: TimeInterval?, message: String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No Azure Speech API key configured. Please set it in Settings."
        case .noEndpoint:
            return "No Azure Speech endpoint configured. Please set the region URL in Settings."
        case .noSpeakers:
            return "Add at least one speaker before generating."
        case .invalidResponse:
            return "Invalid response from the Azure Speech API."
        case .apiError(let message):
            return "Azure API error: \(message)"
        case .httpError(let code):
            return "Azure HTTP error: \(code)"
        case .detailedHTTPError(let message):
            return message
        case .transientHTTPError(_, _, let message):
            return message
        }
    }
}

struct AzureTTSResponse {
    let audioData: Data
    let mimeType: String
    let fileExtension: String
    /// The full `<speak>` document that was synthesized, for storing as the transcript.
    /// Built here (off the main actor) so callers don't have to recompute it on the UI thread.
    let ssml: String
}

nonisolated struct AzureTTSClient {
    /// Synthesizes narration audio for the given speakers/paragraphs.
    ///
    /// `@concurrent` forces this onto the global concurrent executor — **not** the caller's actor.
    /// This matters under Swift 6.2 approachable concurrency (SE-0461), where a plain `nonisolated
    /// async` function would otherwise inherit the caller's isolation and run on the main actor when
    /// called from `@MainActor` code, freezing the UI. With `@concurrent`, the heavy SSML building,
    /// audio stitching, and network requests all run off-main even though the caller is the main
    /// actor. Callers must pass `Sendable` snapshots of the speakers and paragraphs (not the
    /// main-actor-bound SwiftData model).
    @concurrent
    static func generate(
        speakers: [NarrativeSpeaker],
        paragraphs: [NarrativeParagraph],
        apiKey: String,
        endpoint: String,
        format: AzureAudioFormat,
        onProgress: (@MainActor (NarrativeGenerationProgress) -> Void)? = nil
    ) async throws -> AzureTTSResponse {
        guard !apiKey.isEmpty else { throw AzureTTSError.noAPIKey }
        guard let url = ttsURL(from: endpoint) else { throw AzureTTSError.noEndpoint }
        guard !speakers.isEmpty else { throw AzureTTSError.noSpeakers }

        // Azure's real-time endpoint caps each request at ~10 minutes of synthesized audio and
        // rejects anything longer with an (often empty-body) HTTP 400. Split long projects into
        // batches, synthesize each separately, and stitch the audio chunks back into one file.
        let batches = AzureSSMLBuilder.buildBatches(speakers: speakers, paragraphs: paragraphs)
        guard !batches.isEmpty else {
            throw AzureTTSError.apiError("There is no transcript content to synthesize.")
        }

        // Synthesize the batches concurrently (up to `maxConcurrent` in flight) to cut wall-clock
        // time, while keeping a sliding window so we never open more sockets than Azure is happy
        // with. Results are slotted back by index so the final audio stays in transcript order even
        // though requests finish out of order.
        let maxConcurrent = min(2, batches.count)
        let total = batches.count
        var slots = [Data?](repeating: nil, count: total)
        var completed = 0
        var inFlight = 0

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                let ssml = batches[index]
                group.addTask {
                    (index, try await synthesize(ssml: ssml, url: url, apiKey: apiKey, format: format))
                }
                inFlight += 1
            }

            // Prime the window, then enqueue the next batch each time one finishes.
            while next < maxConcurrent {
                enqueue(next)
                next += 1
            }
            await onProgress?(.synthesizing(completed: completed, total: total, inFlight: inFlight))

            while let (index, data) = try await group.next() {
                slots[index] = data
                completed += 1
                inFlight -= 1
                if next < total {
                    enqueue(next)
                    next += 1
                }
                await onProgress?(.synthesizing(completed: completed, total: total, inFlight: inFlight))
            }
        }
        let chunks = slots.compactMap { $0 }

        if batches.count > 1 {
            await onProgress?(.stitching)
        }
        let merged = try AzureAudioStitcher.stitch(chunks, format: format)
        return AzureTTSResponse(
            audioData: merged,
            mimeType: format.mimeType,
            fileExtension: format.fileExtension,
            ssml: AzureSSMLBuilder.build(speakers: speakers, paragraphs: paragraphs)
        )
    }

    /// Synthesizes one batch, retrying transient failures (request timeouts, dropped
    /// connections, HTTP 429/5xx) with exponential backoff. Without this, a single slow
    /// or throttled batch among many concurrent ones would abort the whole job — exactly
    /// the `-1001 timed out` failure seen on long, multi-chunk projects.
    /// `@concurrent` keeps the request (and response handling) off the main actor.
    @concurrent
    private static func synthesize(
        ssml: String,
        url: URL,
        apiKey: String,
        format: AzureAudioFormat
    ) async throws -> Data {
        let maxAttempts = 4
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await performSynthesis(ssml: ssml, url: url, apiKey: apiKey, format: format)
            } catch {
                guard attempt < maxAttempts, let delay = retryDelay(for: error, attempt: attempt) else {
                    print("[AzureTTSClient] batch failed after \(attempt) attempt(s), giving up: "
                        + "\(error.localizedDescription)")
                    throw error
                }
                print("[AzureTTSClient] batch attempt \(attempt)/\(maxAttempts) failed "
                    + "(\(error.localizedDescription)); retrying in \(String(format: "%.1f", delay))s")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Performs a single real-time synthesis request for one `<speak>` document.
    @concurrent
    private static func performSynthesis(
        ssml: String,
        url: URL,
        apiKey: String,
        format: AzureAudioFormat
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        request.setValue(format.header, forHTTPHeaderField: "X-Microsoft-OutputFormat")
        request.setValue("film-workflow", forHTTPHeaderField: "User-Agent")
        // Batches are small (~5 min of audio), so a healthy request finishes well within this.
        // A shorter timeout means a stalled connection surfaces and retries quickly instead of
        // hanging for minutes.
        request.timeoutInterval = 120
        request.httpBody = ssml.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let status = httpResponse.statusCode
            // 429 (throttled) and 5xx are transient — surface them as retryable.
            if status == 429 || status >= 500 {
                let detail = httpError(data: data, response: httpResponse, sentSSML: ssml).errorDescription
                    ?? "Azure HTTP error: \(status)"
                throw AzureTTSError.transientHTTPError(
                    status: status,
                    retryAfter: retryAfterSeconds(from: httpResponse),
                    message: detail
                )
            }
            throw httpError(data: data, response: httpResponse, sentSSML: ssml)
        }
        return data
    }

    /// Returns the backoff delay (seconds) for a retryable error, or `nil` if the error
    /// is permanent and should propagate immediately.
    private static func retryDelay(for error: Error, attempt: Int) -> TimeInterval? {
        // Exponential backoff: 1s, 2s, 4s … capped at 30s.
        let backoff = min(pow(2.0, Double(attempt - 1)), 30)

        if let azure = error as? AzureTTSError, case let .transientHTTPError(_, retryAfter, _) = azure {
            return retryAfter ?? backoff
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .resourceUnavailable:
                return backoff
            default:
                return nil
            }
        }
        return nil
    }

    /// Parses the `Retry-After` header (delta-seconds form, which Azure uses).
    private static func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces) else { return nil }
        return TimeInterval(raw)
    }

    static func generateSample(
        voiceName: String,
        apiKey: String,
        endpoint: String,
        text: String = "Hello! This is how I sound."
    ) async throws -> Data {
        guard !apiKey.isEmpty else { throw AzureTTSError.noAPIKey }
        guard let url = ttsURL(from: endpoint) else { throw AzureTTSError.noEndpoint }

        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let ssml = """
        <speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>\
        <voice name='\(voiceName)'>\(escaped)</voice></speak>
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        request.setValue(AzureAudioFormat.mp3.header, forHTTPHeaderField: "X-Microsoft-OutputFormat")
        request.setValue("film-workflow", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        request.httpBody = ssml.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw httpError(data: data, response: httpResponse, sentSSML: ssml)
        }
        return data
    }

    static func fetchVoices(apiKey: String, endpoint: String) async throws -> [AzureVoice] {
        guard !apiKey.isEmpty else { throw AzureTTSError.noAPIKey }
        guard let voicesURL = voicesURL(from: endpoint) else { throw AzureTTSError.noEndpoint }

        var request = URLRequest(url: voicesURL)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("film-workflow", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw httpError(data: data, response: httpResponse, sentSSML: nil)
        }

        do {
            return try JSONDecoder().decode([AzureVoice].self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            print("[AzureTTSClient] Invalid voices response. Raw body:\n\(raw)")
            throw AzureTTSError.invalidResponse
        }
    }

    // Extract the Azure region from whatever the user pasted:
    //   "eastus"                                          → "eastus"
    //   "https://eastus.api.cognitive.microsoft.com/"     → "eastus"
    //   "https://eastus.tts.speech.microsoft.com/..."     → "eastus"
    static func region(from endpoint: String) -> String? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let host = URLComponents(string: trimmed)?.host,
           let first = host.split(separator: ".").first {
            return String(first)
        }
        // Looks like a bare region string (no scheme).
        if !trimmed.contains("/"), !trimmed.contains(".") {
            return trimmed
        }
        return nil
    }

    static func ttsURL(from endpoint: String) -> URL? {
        guard let region = region(from: endpoint) else { return nil }
        return URL(string: "https://\(region).tts.speech.microsoft.com/cognitiveservices/v1")
    }

    static func voicesURL(from endpoint: String) -> URL? {
        guard let region = region(from: endpoint) else { return nil }
        return URL(string: "https://\(region).tts.speech.microsoft.com/cognitiveservices/voices/list")
    }

    /// Builds the most informative error we can from an Azure non-200 response.
    /// Azure Cognitive Services TTS frequently returns a 400 with an *empty* body
    /// (e.g. malformed SSML or an invalid/unsupported voice name), in which case
    /// the only diagnostics live in the response headers and reason phrase — so we
    /// surface those too instead of throwing a bare status code.
    private static func httpError(
        data: Data,
        response: HTTPURLResponse,
        sentSSML: String?
    ) -> AzureTTSError {
        let status = response.statusCode
        var lines: [String] = ["Azure HTTP error: \(status)"]

        // Always surface the raw response body — this is the actual reason Azure rejected
        // the request. Prefer a cleanly parsed message when one exists, otherwise show the
        // raw text verbatim.
        let rawBody = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = parseErrorMessage(data), !message.isEmpty {
            lines.append("Response: \(message)")
        } else if !rawBody.isEmpty {
            lines.append("Response: \(rawBody)")
        } else {
            lines.append("Response body was empty.")
        }

        // Azure surfaces diagnostics in these headers; include any that are present.
        let headerKeys = ["X-Microsoft-OutputFormat", "apim-request-id", "X-RequestId", "WWW-Authenticate"]
        for key in headerKeys {
            if let value = response.value(forHTTPHeaderField: key), !value.isEmpty {
                lines.append("\(key): \(value)")
            }
        }

        // Common, actionable hint for the empty-body 400 case.
        if status == 400 {
            lines.append("This usually means the SSML is malformed or a voice name is invalid/unsupported for the region.")
        } else if status == 401 || status == 403 {
            lines.append("Check that the Azure Speech key and region are correct.")
        }

        // Log the full context (raw body + SSML) so it's recoverable from the console.
        print("[AzureTTSClient] HTTP \(status). Raw body:\n\(rawBody.isEmpty ? "<empty>" : rawBody)")
        if let sentSSML { print("[AzureTTSClient] Sent SSML:\n\(sentSSML)") }

        return .detailedHTTPError(lines.joined(separator: "\n"))
    }

    private static func parseErrorMessage(_ data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            if let message = json["message"] as? String {
                return message
            }
        }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        return nil
    }
}
