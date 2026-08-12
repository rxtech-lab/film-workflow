import Foundation
import SwiftUI

/// What actually produces a translation.
///
/// Two very different things sit behind this: Apple's `Translation` framework —
/// offline, free, purpose-built, and unavailable outside SwiftUI — and an LLM
/// through `CaptionAIEngine`, which costs tokens but knows the project glossary
/// and can run headless for MCP. Neither is strictly better, so both ship.
nonisolated enum CaptionTranslationEngineKind: String, CaseIterable, Identifiable, Sendable {
    /// Apple's on-device translation. The default.
    case appleTranslation
    /// Whichever AI backend is configured in Settings.
    case aiBackend

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .appleTranslation: return "Apple Translation"
        case .aiBackend: return "AI model"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .appleTranslation:
            return "On device and free. Downloads a language pack the first time."
        case .aiBackend:
            return "Uses your AI backend and follows the project glossary. Costs tokens."
        }
    }

    /// Can run without a SwiftUI view attached — which is what MCP needs.
    ///
    /// A `TranslationSession` is only ever vended by the `.translationTask`
    /// modifier, so the Apple engine simply cannot exist in a headless context.
    var supportsHeadless: Bool { self == .aiBackend }
}

/// One caption to translate.
nonisolated struct CaptionTranslationRequest: Sendable, Hashable {
    var segmentID: UUID
    var text: String
}

nonisolated struct CaptionTranslationResult: Sendable, Hashable {
    var segmentID: UUID
    var text: String
}

/// A configured translator: one source language, one target, many captions.
///
/// `@MainActor` because `TranslationSession` is not `Sendable` and arrives from
/// a view modifier. This is the one place in the caption stack where work does
/// not hop to a `@concurrent` context — both implementations do their real work
/// behind an `await`, so the main actor is only holding the coordination.
@MainActor
protocol CaptionTranslationRunner {
    var kind: CaptionTranslationEngineKind { get }
    /// BCP-47, or empty when the engine should detect it.
    var sourceLanguage: String { get }
    /// BCP-47. Never empty.
    var targetLanguage: String { get }

    /// Translates a batch, reporting `(done, total)` as it goes.
    ///
    /// May return fewer results than requests — a translation that came back
    /// empty or unmatchable is dropped rather than guessed at. Callers write
    /// back what they get and leave the rest untranslated, which the editor
    /// then shows as a gap the user can re-run.
    func translate(
        _ requests: [CaptionTranslationRequest],
        onProgress: @MainActor (Int, Int) -> Void
    ) async throws -> [CaptionTranslationResult]
}
