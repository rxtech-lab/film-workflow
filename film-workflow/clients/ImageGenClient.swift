import Foundation

enum ImageGenError: LocalizedError {
    case missingConfig
    case invalidEndpoint
    case invalidResponse
    case apiError(String)
    case httpError(Int, String?)
    case noImageInResponse

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "Image generation is not configured. Set credentials in Settings."
        case .invalidEndpoint:
            return "OpenAI endpoint URL is invalid."
        case .invalidResponse:
            return "Invalid response from the image generation endpoint."
        case .apiError(let message):
            return "Image generation error: \(message)"
        case .httpError(let code, let body):
            if let body, !body.isEmpty {
                return "HTTP \(code): \(body)"
            }
            return "HTTP error: \(code)"
        case .noImageInResponse:
            return "No image data found in the response."
        }
    }
}

struct ImageGenResult {
    /// The decoded image bytes.
    let imageData: Data
    /// File extension to save under (without dot), e.g. "png", "jpg", "webp".
    let fileExtension: String
}

struct ImageGenClient {
    // MARK: - Google (Imagen via Gemini API)

    private static let googleImagenEndpoint =
        "https://generativelanguage.googleapis.com/v1beta/models/imagen-4.0-generate-001:predict"

    static func generateGoogle(
        prompt: String,
        aspectRatio: ImageAspectRatio,
        resolution: ImageResolution,
        apiKey: String
    ) async throws -> ImageGenResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedPrompt.isEmpty else {
            throw ImageGenError.missingConfig
        }

        let url = URL(string: googleImagenEndpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(trimmedKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 180

        let body: [String: Any] = [
            "instances": [["prompt": trimmedPrompt]],
            "parameters": [
                "sampleCount": 1,
                "aspectRatio": aspectRatio.rawValue,
                "imageSize": resolution.rawValue
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try Self.throwHTTPError(http.statusCode, data: data)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let predictions = json["predictions"] as? [[String: Any]],
              let first = predictions.first,
              let base64 = first["bytesBase64Encoded"] as? String,
              let imageData = Data(base64Encoded: base64) else {
            throw ImageGenError.noImageInResponse
        }

        let mime = (first["mimeType"] as? String) ?? "image/png"
        return ImageGenResult(imageData: imageData, fileExtension: Self.extensionFor(mimeType: mime))
    }

    // MARK: - OpenAI (and OpenAI-compatible gateways)

    /// OpenAI-style image generation. When `aspectRatio`/`resolution` are non-nil they are
    /// passed through as `aspect_ratio` / `resolution` (used when the gateway routes to a
    /// Google Imagen model and the form switches to Google-style controls).
    static func generateOpenAI(
        prompt: String,
        model: String,
        endpoint: String,
        apiKey: String,
        size: ImageSize? = nil,
        customSize: String? = nil,
        quality: ImageQuality? = nil,
        format: ImageFormat? = nil,
        compression: Int? = nil,
        background: ImageBackground? = nil,
        transparent: Bool = false,
        aspectRatio: ImageAspectRatio? = nil,
        resolution: ImageResolution? = nil
    ) async throws -> ImageGenResult {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedEndpoint.isEmpty, !trimmedKey.isEmpty,
              !trimmedModel.isEmpty, !trimmedPrompt.isEmpty else {
            throw ImageGenError.missingConfig
        }

        let url = try resolveImagesURL(from: trimmedEndpoint)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 300

        var body: [String: Any] = [
            "model": trimmedModel,
            "prompt": trimmedPrompt,
            "n": 1
        ]

        if let size {
            if let apiValue = size.apiValue {
                body["size"] = apiValue
            } else if let customSize, !customSize.isEmpty {
                body["size"] = customSize
            }
        } else if let customSize, !customSize.isEmpty {
            body["size"] = customSize
        }
        if let quality {
            body["quality"] = quality.rawValue
        }
        if let format {
            body["output_format"] = format.rawValue
        }
        if let compression, let format, format.supportsCompression {
            body["output_compression"] = compression
        }
        if transparent {
            body["background"] = "transparent"
        } else if let background {
            body["background"] = background.rawValue
        }
        if let aspectRatio {
            body["aspect_ratio"] = aspectRatio.rawValue
        }
        if let resolution {
            body["resolution"] = resolution.rawValue
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try Self.throwHTTPError(http.statusCode, data: data)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArr = json["data"] as? [[String: Any]],
              let first = dataArr.first else {
            throw ImageGenError.invalidResponse
        }

        // Prefer base64; fall back to URL.
        if let base64 = first["b64_json"] as? String,
           let imageData = Data(base64Encoded: base64) {
            let ext = format?.rawValue ?? "png"
            return ImageGenResult(imageData: imageData, fileExtension: ext == "jpeg" ? "jpg" : ext)
        }

        if let urlString = first["url"] as? String, let imgURL = URL(string: urlString) {
            let (imgData, _) = try await URLSession.shared.data(from: imgURL)
            let ext = format?.rawValue ?? imgURL.pathExtension.lowercased()
            let final = ext.isEmpty ? "png" : (ext == "jpeg" ? "jpg" : ext)
            return ImageGenResult(imageData: imgData, fileExtension: final)
        }

        throw ImageGenError.noImageInResponse
    }

    // MARK: - Helpers

    private static func resolveImagesURL(from endpoint: String) throws -> URL {
        var trimmed = endpoint
        while trimmed.hasSuffix("/") { trimmed.removeLast() }

        let candidate: String
        if trimmed.hasSuffix("/images/generations") {
            candidate = trimmed
        } else if trimmed.hasSuffix("/v1") || trimmed.contains("/v1/") {
            candidate = trimmed + "/images/generations"
        } else {
            candidate = trimmed + "/v1/images/generations"
        }

        guard let url = URL(string: candidate) else {
            throw ImageGenError.invalidEndpoint
        }
        return url
    }

    private static func throwHTTPError(_ status: Int, data: Data) throws -> Never {
        let bodyString = String(data: data, encoding: .utf8)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw ImageGenError.apiError(message)
        }
        throw ImageGenError.httpError(status, bodyString)
    }

    private static func extensionFor(mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/webp": return "webp"
        default: return "png"
        }
    }
}
