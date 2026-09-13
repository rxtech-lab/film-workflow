import Foundation

enum GeminiTTSError: LocalizedError {
    case noAPIKey
    case noSpeakers
    case invalidResponse
    case apiError(String)
    case noAudioInResponse
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No Google AI API key configured. Please set it in Settings."
        case .noSpeakers:
            return "Add at least one speaker before generating."
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

struct GeminiTTSResponse {
    let audioData: Data
    let mimeType: String
}
