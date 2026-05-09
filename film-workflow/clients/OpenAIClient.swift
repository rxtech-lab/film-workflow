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

// MARK: - Rich messages (tool use + multimodal)

/// A content block that can appear inside a multimodal message body.
enum OpenAIContentPart {
    case text(String)
    /// `dataURL` should be a full data URL, e.g. "data:image/png;base64,…", or any http(s) URL.
    case imageURL(String)

    fileprivate var json: [String: Any] {
        switch self {
        case .text(let s):
            return ["type": "text", "text": s]
        case .imageURL(let url):
            return ["type": "image_url", "image_url": ["url": url]]
        }
    }
}

/// A single tool call requested by the assistant.
struct OpenAIToolCall {
    let id: String
    let name: String
    let argumentsJSON: String

    fileprivate var json: [String: Any] {
        [
            "id": id,
            "type": "function",
            "function": [
                "name": name,
                "arguments": argumentsJSON
            ]
        ]
    }
}

/// A message in the rich chat protocol. Either `content` or `parts` carries the body
/// (mutually exclusive). Assistant messages may also carry `toolCalls`. Tool-role
/// messages must carry `toolCallId`.
struct OpenAIRichMessage {
    let role: String
    let content: String?
    let parts: [OpenAIContentPart]?
    let toolCalls: [OpenAIToolCall]?
    let toolCallId: String?
    let name: String?
    /// When true, attach `cache_control: { type: "ephemeral" }` so the gateway
    /// pins a prompt-cache breakpoint at this message. Used for the static
    /// prefix (system prompt, frozen project state) on Anthropic via Vercel AI Gateway.
    let cacheControl: Bool

    init(
        role: String,
        content: String? = nil,
        parts: [OpenAIContentPart]? = nil,
        toolCalls: [OpenAIToolCall]? = nil,
        toolCallId: String? = nil,
        name: String? = nil,
        cacheControl: Bool = false
    ) {
        self.role = role
        self.content = content
        self.parts = parts
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.name = name
        self.cacheControl = cacheControl
    }

    fileprivate var json: [String: Any] {
        var dict: [String: Any] = ["role": role]
        if let parts {
            dict["content"] = parts.map { $0.json }
        } else if let content {
            dict["content"] = content
        } else if toolCalls != nil {
            // Assistant message that is purely tool calls — content must still be present
            // for some endpoints; use empty string.
            dict["content"] = ""
        }
        if let toolCalls, !toolCalls.isEmpty {
            dict["tool_calls"] = toolCalls.map { $0.json }
        }
        if let toolCallId {
            dict["tool_call_id"] = toolCallId
        }
        if let name {
            dict["name"] = name
        }
        if cacheControl {
            dict["cache_control"] = ["type": "ephemeral"]
        }
        return dict
    }
}

/// Tool definition (OpenAI function-calling shape).
struct OpenAIToolDefinition {
    let name: String
    let description: String
    /// JSON Schema dictionary for `parameters`.
    let parametersSchema: [String: Any]

    fileprivate var json: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parametersSchema
            ]
        ]
    }
}

/// A parsed assistant response from `chatWithTools`.
struct OpenAIAssistantResponse {
    let content: String?
    let toolCalls: [OpenAIToolCall]
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

    /// Tool-using chat completion. Returns the assistant message including any tool calls.
    /// `extraBody` is shallow-merged into the request body — used to pass gateway-only
    /// fields like `providerOptions.gateway.caching = "auto"`.
    static func chatWithTools(
        messages: [OpenAIRichMessage],
        tools: [OpenAIToolDefinition],
        endpoint: String,
        apiKey: String,
        model: String,
        extraBody: [String: Any] = [:]
    ) async throws -> OpenAIAssistantResponse {
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
        request.timeoutInterval = 300

        var body: [String: Any] = [
            "model": trimmedModel,
            "messages": messages.map { $0.json },
            "stream": false
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { $0.json }
            body["tool_choice"] = "auto"
        }
        for (key, value) in extraBody {
            body[key] = value
        }
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
              let message = first["message"] as? [String: Any] else {
            throw OpenAIError.invalidResponse
        }

        let content = message["content"] as? String
        var toolCalls: [OpenAIToolCall] = []
        if let calls = message["tool_calls"] as? [[String: Any]] {
            for call in calls {
                guard let id = call["id"] as? String,
                      let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                let args = (function["arguments"] as? String) ?? "{}"
                toolCalls.append(OpenAIToolCall(id: id, name: name, argumentsJSON: args))
            }
        }

        return OpenAIAssistantResponse(content: content, toolCalls: toolCalls)
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
