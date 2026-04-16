import Foundation

enum LyriaError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case apiError(String)
    case noAudioInResponse
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No Google AI API key configured. Please set it in Settings."
        case .invalidResponse:
            return "Invalid response from the API."
        case .apiError(let message):
            return "API error: \(message)"
        case .noAudioInResponse:
            return "No audio data found in the API response."
        case .httpError(let code):
            return "HTTP error: \(code)"
        }
    }
}

struct LyriaResponse {
    let lyricsText: String?
    let audioData: Data
    let mimeType: String
}

struct LyriaClient {
    private static let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/lyria-3-pro-preview:generateContent"

    static func generate(
        prompt: String,
        imageDataPairs: [(mimeType: String, base64: String)] = [],
        apiKey: String
    ) async throws -> LyriaResponse {
        guard !apiKey.isEmpty else {
            throw LyriaError.noAPIKey
        }

        let url = URL(string: endpoint)!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300 // Music generation can take a while

        // Build parts array
        var parts: [[String: Any]] = []
        parts.append(["text": prompt])

        for img in imageDataPairs {
            parts.append([
                "inline_data": [
                    "mime_type": img.mimeType,
                    "data": img.base64
                ]
            ])
        }

        let body: [String: Any] = [
            "contents": [["parts": parts]],
            "generationConfig": [
                "responseModalities": ["AUDIO", "TEXT"]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            // Try to extract error message
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw LyriaError.apiError(message)
            }
            throw LyriaError.httpError(httpResponse.statusCode)
        }

        return try parseResponse(data)
    }

    private static func parseResponse(_ data: Data) throws -> LyriaResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            print("[LyriaClient] Invalid response. Raw body:\n\(raw)")
            throw LyriaError.invalidResponse
        }

        var lyricsText: String?
        var audioData: Data?
        var mimeType = "audio/mp3"

        for part in parts {
            if let text = part["text"] as? String {
                lyricsText = text
            } else if let inlineData = part["inlineData"] as? [String: Any],
                      let base64String = inlineData["data"] as? String,
                      let mime = inlineData["mimeType"] as? String {
                audioData = Data(base64Encoded: base64String)
                mimeType = mime
            }
        }

        guard let audio = audioData else {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            print("[LyriaClient] No audio in response. Raw body:\n\(raw)")
            throw LyriaError.noAudioInResponse
        }

        return LyriaResponse(lyricsText: lyricsText, audioData: audio, mimeType: mimeType)
    }
}
