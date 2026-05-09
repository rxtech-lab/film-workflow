import Foundation

enum OpenAIError: LocalizedError {
    case missingConfig
    case invalidEndpoint
    case invalidResponse
    case apiError(String)
    case httpError(Int, String?)

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "OpenAI endpoint, key, or model is not configured. Set it in Settings."
        case .invalidEndpoint:
            return "OpenAI endpoint URL is invalid."
        case .invalidResponse:
            return "Invalid response from the OpenAI-compatible endpoint."
        case .apiError(let message):
            return "OpenAI error: \(message)"
        case .httpError(let code, let body):
            if let body, !body.isEmpty {
                return "HTTP \(code): \(body)"
            }
            return "HTTP error: \(code)"
        }
    }
}

struct OpenAIChatMessage {
    let role: String
    let content: String
}

struct OpenAIClient {
    static func chat(
        messages: [OpenAIChatMessage],
        endpoint: String,
        apiKey: String,
        model: String
    ) async throws -> String {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedEndpoint.isEmpty, !trimmedKey.isEmpty, !trimmedModel.isEmpty else {
            throw OpenAIError.missingConfig
        }

        let url = try resolveChatCompletionsURL(from: trimmedEndpoint)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 180

        let body: [String: Any] = [
            "model": trimmedModel,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let bodyString = String(data: data, encoding: .utf8)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw OpenAIError.apiError(message)
            }
            throw OpenAIError.httpError(http.statusCode, bodyString)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OpenAIError.invalidResponse
        }

        return content
    }

    private static func resolveChatCompletionsURL(from endpoint: String) throws -> URL {
        var trimmed = endpoint
        while trimmed.hasSuffix("/") { trimmed.removeLast() }

        let candidate: String
        if trimmed.hasSuffix("/chat/completions") {
            candidate = trimmed
        } else if trimmed.hasSuffix("/v1") || trimmed.contains("/v1/") {
            candidate = trimmed + "/chat/completions"
        } else {
            candidate = trimmed + "/v1/chat/completions"
        }

        guard let url = URL(string: candidate) else {
            throw OpenAIError.invalidEndpoint
        }
        return url
    }
}
