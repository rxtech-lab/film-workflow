import Foundation

enum AzureTTSError: LocalizedError {
    case noAPIKey
    case noEndpoint
    case noSpeakers
    case invalidResponse
    case apiError(String)
    case httpError(Int)

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
        }
    }
}

struct AzureTTSResponse {
    let audioData: Data
    let mimeType: String
    let fileExtension: String
}

struct AzureTTSClient {
    static func generate(
        project: NarrativeProject,
        apiKey: String,
        endpoint: String,
        format: AzureAudioFormat
    ) async throws -> AzureTTSResponse {
        guard !apiKey.isEmpty else { throw AzureTTSError.noAPIKey }
        guard let url = ttsURL(from: endpoint) else { throw AzureTTSError.noEndpoint }
        guard !project.speakers.isEmpty else { throw AzureTTSError.noSpeakers }

        let ssml = AzureSSMLBuilder.build(from: project)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        request.setValue(format.header, forHTTPHeaderField: "X-Microsoft-OutputFormat")
        request.setValue("film-workflow", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 300
        request.httpBody = ssml.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            if let message = parseErrorMessage(data) {
                throw AzureTTSError.apiError(message)
            }
            throw AzureTTSError.httpError(httpResponse.statusCode)
        }

        return AzureTTSResponse(
            audioData: data,
            mimeType: format.mimeType,
            fileExtension: format.fileExtension
        )
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
            if let message = parseErrorMessage(data) { throw AzureTTSError.apiError(message) }
            throw AzureTTSError.httpError(httpResponse.statusCode)
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
            if let message = parseErrorMessage(data) {
                throw AzureTTSError.apiError(message)
            }
            throw AzureTTSError.httpError(httpResponse.statusCode)
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
