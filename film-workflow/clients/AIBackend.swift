import Foundation

/// What the subscription catalog groups models by. Mirrors the server's
/// `capability` enum, minus `translation`, which no picker asks for.
nonisolated enum AICapability: String, Sendable, CaseIterable {
    case chat, image, speech, transcription, music, video

    /// What this capability is called in a sentence, for an error that has to
    /// say which kind of generation refused the model.
    var activityLabel: String {
        switch self {
        case .chat: String(localized: "chat")
        case .image: String(localized: "image generation")
        case .speech: String(localized: "narration")
        case .transcription: String(localized: "transcription")
        case .music: String(localized: "music")
        case .video: String(localized: "video generation")
        }
    }

    /// The Settings row that chooses this capability's model, named exactly as
    /// the picker labels it — an error that sends the user to Settings is only
    /// useful if it names the control they have to change.
    var settingsRowLabel: String {
        switch self {
        case .chat: String(localized: "Chat model")
        case .image: String(localized: "Image model")
        case .speech: String(localized: "Narration model")
        case .transcription: String(localized: "Transcription model")
        case .music: String(localized: "Music model")
        case .video: String(localized: "Video model")
        }
    }
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
