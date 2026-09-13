import Foundation

enum ImageGenError: LocalizedError {
    case missingConfig
    case invalidEndpoint
    case invalidResponse
    case apiError(String)
    case httpError(Int, String?)
    case noImageInResponse
    case notImageModel(String)

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
        case .notImageModel(let id):
            return "Model \"\(id)\" is not configured as an image-generation model."
        }
    }
}

struct ImageGenResult {
    /// The decoded image bytes.
    let imageData: Data
    /// File extension to save under (without dot), e.g. "png", "jpg", "webp".
    let fileExtension: String
}
