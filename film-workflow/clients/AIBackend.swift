import Foundation

nonisolated enum AICapability: String, Sendable, CaseIterable {
    case chat, image, speech, transcription, music
}

@MainActor
enum AIRoute: Sendable {
    case byok
    case subscription

    static func resolve(_ config: AppConfig, for capability: AICapability) throws -> AIRoute {
        if config.usesSubscription {
            guard AuthManager.shared.isAuthenticated else { throw AIRouteError.notSignedIn }
            return .subscription
        }

        let configured: Bool
        switch capability {
        case .chat: configured = !config.openAIEndpoint.isEmpty && !config.openAIKey.isEmpty && !config.openAIModel.isEmpty
        case .image: configured = !config.googleAIKey.isEmpty || (!config.openAIEndpoint.isEmpty && !config.openAIKey.isEmpty)
        case .speech: configured = !config.googleAIKey.isEmpty || (!config.azureSpeechKey.isEmpty && !config.azureSpeechEndpoint.isEmpty)
        case .transcription: configured = !config.googleAIKey.isEmpty || !config.openAIKey.isEmpty || !config.azureSpeechKey.isEmpty
        case .music: configured = !config.googleAIKey.isEmpty
        }
        guard configured else { throw AIRouteError.missingBYOKConfig(capability) }
        return .byok
    }
}

enum AIRouteError: LocalizedError {
    case notSignedIn
    case missingBYOKConfig(AICapability)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to your RxLab account to use subscription credits."
        case .missingBYOKConfig(let capability): "Configure your own provider credentials for \(capability.rawValue) in Settings."
        }
    }
}
