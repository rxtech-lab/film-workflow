import Foundation
import FoundationModels

// MARK: - Guided output types

/// Guided-generation shapes for the on-device model.
///
/// One small `@Generable` type per task. Keeping them minimal is not cosmetic:
/// the schema is injected into the prompt, so every extra field costs context in
/// a 4k-token window.
/// The split answer is one marked-up string, not `[String]`.
///
/// A `[String]` field is what produced the shredding bug in the field: guided
/// decoding happily emits one array element per word, and no amount of prompting
/// reliably stops it. Copying the line through with `|` at the break gives the
/// model nowhere to put a list.
@Generable
nonisolated struct CaptionSplitOutput {
    @Guide(description: """
        The line copied through word for word, with a | inserted at each place \
        it should break. Usually exactly one |. No | at all means leave the line \
        alone. Never put a | between every word.
        """)
    var markedLine: String

    @Guide(description: "One short sentence on why you broke it there, or why you didn't.")
    var reason: String
}

@Generable
nonisolated struct CaptionTermFixOutput {
    @Guide(description: "The line number, exactly as shown in the list.")
    var number: Int

    @Guide(description: "The whole line, with only the glossary term corrected.")
    var correctedText: String
}

@Generable
nonisolated struct CaptionTermReviewOutput {
    @Guide(description: "Only lines that contain a misspelled glossary term. Empty if none do.")
    var fixes: [CaptionTermFixOutput]
}

@Generable
nonisolated struct CaptionTranslatedLineOutput {
    @Guide(description: "The line number, exactly as shown in the list.")
    var number: Int

    @Guide(description: "That line translated, and nothing else — no number, no notes.")
    var text: String
}

@Generable
nonisolated struct CaptionTranslateOutput {
    @Guide(description: "One entry per input line, in the same order, with the same numbers.")
    var lines: [CaptionTranslatedLineOutput]
}

@Generable
nonisolated struct CaptionChatEditOutput {
    @Guide(description: "The caption number this edit applies to.")
    var number: Int

    @Guide(description: "One of: replaceText, split, mergeWithNext, delete.")
    var kind: String

    @Guide(description: """
        For replaceText, the new text as a single item. For split, the pieces in \
        order. Empty for mergeWithNext and delete.
        """)
    var pieces: [String]
}

@Generable
nonisolated struct CaptionChatOutput {
    @Guide(description: "A short reply to the user, at most two sentences.")
    var reply: String

    @Guide(description: "Changes to make, or empty when the user only asked a question.")
    var edits: [CaptionChatEditOutput]
}

// MARK: - Engine

/// Runs caption AI tasks on Apple Intelligence, entirely on device.
///
/// A fresh `LanguageModelSession` per call. Sessions are stateful and the
/// context window is small, so reusing one across unrelated captions would let
/// earlier lines bleed into later answers and would run out of room within a
/// few dozen captions. The assistant's conversational continuity comes from the
/// compacted history we send, not from session state.
nonisolated struct AppleIntelligenceCaptionEngine: CaptionAIEngine {
    var backend: AgentBackend { .appleIntelligence }

    /// Deterministic: these are proofreading tasks, not creative ones, and a
    /// stable answer is what makes a re-run trustworthy.
    private var options: GenerationOptions {
        GenerationOptions(sampling: .greedy)
    }

    // MARK: - Split

    func planSplit(_ request: CaptionSplitRequest) async throws -> CaptionSplitPlan {
        let session = LanguageModelSession(
            instructions: CaptionAIPrompts.splitInstructions(
                maxRunes: request.maxRunes,
                minRunes: request.minRunes,
                maxPieces: request.maxPieces
            )
        )
        let response = try await respond(
            session: session,
            prompt: CaptionAIPrompts.splitPrompt(request),
            as: CaptionSplitOutput.self
        )
        return CaptionSplitPlan.parse(
            markedLine: response.markedLine,
            reason: response.reason
        )
    }

    // MARK: - Terms

    func reviewTerms(_ request: CaptionTermReviewRequest) async throws -> CaptionTermReviewResult {
        let session = LanguageModelSession(instructions: CaptionAIPrompts.termReviewInstructions)
        let response = try await respond(
            session: session,
            prompt: CaptionAIPrompts.termReviewPrompt(request),
            as: CaptionTermReviewOutput.self
        )
        return CaptionTermReviewResult(
            corrections: response.fixes.map {
                CaptionTermCorrection(number: $0.number, correctedText: $0.correctedText)
            }
        )
    }

    // MARK: - Translate

    func translate(_ request: CaptionTranslateRequest) async throws -> CaptionTranslateResult {
        guard !request.lines.isEmpty else { return CaptionTranslateResult(lines: []) }

        let session = LanguageModelSession(
            instructions: CaptionAIPrompts.translateInstructions(
                source: request.sourceLanguage,
                target: request.targetLanguage
            )
        )
        let response = try await respond(
            session: session,
            prompt: CaptionAIPrompts.translatePrompt(request),
            as: CaptionTranslateOutput.self
        )
        return CaptionTranslateResult(
            lines: response.lines.compactMap { line in
                let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return CaptionTranslatedLine(number: line.number, text: text)
            }
        )
    }

    // MARK: - Chat

    func converse(_ request: CaptionChatRequest) async throws -> CaptionChatReply {
        let session = LanguageModelSession(instructions: CaptionAIPrompts.chatInstructions)
        let response = try await respond(
            session: session,
            prompt: CaptionAIPrompts.chatPrompt(request),
            as: CaptionChatOutput.self
        )
        return CaptionChatReply(
            assistantText: response.reply,
            edits: response.edits.compactMap { edit in
                guard let kind = CaptionChatEdit.Kind(rawValue: edit.kind) else { return nil }
                return CaptionChatEdit(number: edit.number, kind: kind, pieces: edit.pieces)
            }
        )
    }

    // MARK: - Shared

    /// One guided call, with the context-window failure translated into
    /// something a caller can act on.
    ///
    /// `exceededContextWindowSize` is the error this design exists to avoid, so
    /// when it still fires it is reported as `contextOverflow` — a batched
    /// caller can act on that by sending fewer lines, where the old
    /// `malformedResponse` only offered the user advice they couldn't take in
    /// the middle of a whole-transcript run.
    private func respond<Output: Generable>(
        session: LanguageModelSession,
        prompt: String,
        as type: Output.Type
    ) async throws -> Output {
        do {
            return try await session.respond(
                to: prompt,
                generating: type,
                options: options
            ).content
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                throw CaptionAIError.contextOverflow(
                    "the request was too long for the on-device model"
                )
            case .guardrailViolation, .refusal:
                throw CaptionAIError.malformedResponse(
                    "Apple Intelligence declined to answer for this text"
                )
            case .assetsUnavailable:
                throw CaptionAIError.backendUnavailable(
                    .appleIntelligence,
                    "Apple Intelligence is still downloading its model. Try again shortly."
                )
            default:
                throw error
            }
        }
    }
}
