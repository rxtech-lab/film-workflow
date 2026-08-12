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

    /// Plain-text name, for strings that have to be concatenated with a model
    /// name. `displayName` is a `LocalizedStringKey` and can't be.
    var shortName: String {
        switch self {
        case .appleTranslation: return "Apple Translation"
        case .aiBackend: return "AI model"
        }
    }

    /// What produced a stored translation, e.g. "AI model · gpt-4o-mini".
    ///
    /// Takes raw values rather than a case because both are read back off a
    /// persisted record, which may name an engine this build no longer has —
    /// showing the stored string beats showing nothing. Empty when neither was
    /// recorded, which is what a translation written before this existed looks
    /// like.
    static func producerDescription(engine: String, model: String) -> String {
        let engineName = CaptionTranslationEngineKind(rawValue: engine)?.shortName ?? engine
        return [engineName, model].filter { !$0.isEmpty }.joined(separator: " · ")
    }
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

/// How far along a run is.
///
/// Carries `inFlight` as well as `done` because a batch is atomic: the engine
/// says nothing until it has answered for every caption in the request, so a
/// transcript short enough to fit in one batch would otherwise report zero for
/// the entire run and then finish.
nonisolated struct CaptionTranslationProgress: Sendable {
    var done: Int
    var total: Int
    /// Captions currently out with the engine, awaiting an answer.
    var inFlight: Int = 0
}

/// What a whole run produced.
///
/// `failed` is reported rather than thrown because a transcript is not
/// all-or-nothing: eight hundred good translations and thirty captions the
/// model choked on is a useful outcome, and the thirty stay marked untranslated
/// so a re-run picks up exactly those.
nonisolated struct CaptionTranslationRun: Sendable {
    var results: [CaptionTranslationResult] = []
    /// Captions that couldn't be translated even one at a time.
    var failed: Int = 0
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

    /// Which model is answering, recorded onto every translation this run
    /// writes. Empty when the engine has no model to name.
    var modelLabel: String { get }

    /// Translates a batch, reporting progress as it goes.
    ///
    /// May return fewer results than requests — a translation that came back
    /// empty or unmatchable is dropped rather than guessed at. Callers write
    /// back what they get and leave the rest untranslated, which the editor
    /// then shows as a gap the user can re-run.
    ///
    /// `onBatch` hands over each batch the moment it lands, before the run is
    /// finished. That is what makes cancelling a nine-hundred-caption run keep
    /// the first half: the caller saves as it goes, so nothing depends on this
    /// method returning normally.
    func translate(
        _ requests: [CaptionTranslationRequest],
        onBatch: @MainActor ([CaptionTranslationResult]) -> Void,
        onProgress: @MainActor (CaptionTranslationProgress) -> Void
    ) async throws -> CaptionTranslationRun
}

extension CaptionTranslationRunner {
    /// Apple's engine is the reason this has a default: it is one system
    /// translator with no model name to report.
    var modelLabel: String { "" }
}
