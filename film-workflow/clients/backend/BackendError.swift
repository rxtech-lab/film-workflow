import Foundation

/// `CustomStringConvertible` as well as `LocalizedError` because these errors
/// do not only reach a `catch` that knows to ask for `localizedDescription`.
/// One path runs through `RxAgentSDK`, which flattens whatever a transport
/// throws with `String(describing:)` — and for a bare enum that is the case
/// name and its associated values, printed into the agent's error bar.
enum BackendError: LocalizedError, CustomStringConvertible {
    case notSignedIn
    case insufficientCredits(available: Int, required: Int, creditsURL: URL?)
    case unauthorized
    case badRequest(String)
    /// The server refused the model the request named (`model_not_allowed`).
    ///
    /// Its own case rather than a `badRequest` because it is the one rejection
    /// the user can fix themselves, and every surface that hits it wants the
    /// same two things: the id that was refused, and a way into the picker that
    /// chose it. Both fields start empty — the server's reply names neither —
    /// and are filled in by whichever client sent the request, through
    /// `namingModel(_:capability:)`.
    case modelUnavailable(model: String, capability: AICapability?)
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
        case .modelUnavailable(let model, let capability):
            Self.modelUnavailableDescription(model: model, capability: capability)
        case .server(let status, let message): message ?? "The RxFilm service returned HTTP \(status)."
        case .priceUnavailable(let model): "Pricing is not configured for \(model)."
        case .jobFailed(let message): message
        case .decoding(let error): "The RxFilm service response could not be read: \(error.localizedDescription)"
        }
    }

    var description: String { errorDescription ?? "The RxFilm service request failed." }

    /// Fills in what the server's reply leaves out.
    ///
    /// `BackendClient` reads the `model_not_allowed` code but never sees the
    /// request, so the id and the capability are attached by the client that
    /// sent it. Already-named values win — a client that knows better than its
    /// caller (the image client retries on a refreshed id) has already said so.
    /// Every other error passes through untouched, so a call site can wrap its
    /// whole `catch` in this without switching first.
    func namingModel(_ model: String, capability: AICapability) -> BackendError {
        guard case .modelUnavailable(let named, let namedCapability) = self else { return self }
        return .modelUnavailable(
            model: named.isEmpty ? model.trimmingCharacters(in: .whitespaces) : named,
            capability: namedCapability ?? capability
        )
    }

    /// The refused model and capability, for a caller that wants to react to
    /// this rejection rather than just print it.
    var unavailableModel: (model: String, capability: AICapability?)? {
        guard case .modelUnavailable(let model, let capability) = self else { return nil }
        return (model, capability)
    }

    private static func modelUnavailableDescription(
        model: String,
        capability: AICapability?
    ) -> String {
        // Quoted only when there is something to quote: the id is missing
        // whenever the rejection was not routed through a client that knew it.
        let named = model.isEmpty
            ? String(localized: "The selected model")
            : String(localized: "“\(model)”")
        guard let capability else {
            return String(localized: "\(named) is not available on this account. Pick another one in Settings ▸ AI Provider.")
        }
        return String(localized: "\(named) is not available for \(capability.activityLabel) on this account. Pick another one under \(capability.settingsRowLabel) in Settings ▸ AI Provider.")
    }
}
