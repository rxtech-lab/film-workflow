import Foundation

enum LyriaError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case apiError(String)
    case noAudioInResponse
    case httpError(Int)
    case generationBlocked(reason: String, message: String?)

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
        case .generationBlocked(let reason, let message):
            return message ?? "Music generation was blocked (\(reason))."
        }
    }
}

struct LyriaResponse {
    let lyricsText: String?
    let audioData: Data
    let mimeType: String
}
