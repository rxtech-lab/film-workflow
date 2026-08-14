import Foundation

enum BackendError: LocalizedError {
    case notSignedIn
    case insufficientCredits(available: Int, required: Int, creditsURL: URL?)
    case unauthorized
    case badRequest(String)
    case server(Int, String?)
    case priceUnavailable(String)
    case jobFailed(String)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to your RxLab account to use subscription credits."
        case .insufficientCredits(let available, let required, _):
            "You need \(required) credits; \(available) are available."
        case .unauthorized: "Your RxLab session has expired. Sign in again."
        case .badRequest(let message): message
        case .server(let status, let message): message ?? "The RxFilm service returned HTTP \(status)."
        case .priceUnavailable(let model): "Pricing is not configured for \(model)."
        case .jobFailed(let message): message
        case .decoding(let error): "The RxFilm service response could not be read: \(error.localizedDescription)"
        }
    }
}
