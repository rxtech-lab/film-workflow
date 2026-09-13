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
