import Foundation

/// What the subscription catalog groups models by. Mirrors the server's
/// `capability` enum, minus `translation`, which no picker asks for.
nonisolated enum AICapability: String, Sendable, CaseIterable {
    case chat, image, speech, transcription, music, video
}

/// The RxFilm subscription is the only route for every capability except
/// chat, where an OpenAI-compatible endpoint can also be picked per thread.
@MainActor
enum AIRoute {
    /// Throws unless the user is signed in — the one precondition every
    /// subscription call shares. The server does the real authorization; this
    /// only turns a guaranteed 401 into a message the user can act on.
    static func requireSubscription() throws {
        guard AuthManager.shared.isAuthenticated else { throw AIRouteError.notSignedIn }
    }
}

enum AIRouteError: LocalizedError {
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to your RxLab account to use subscription credits."
        }
    }
}
