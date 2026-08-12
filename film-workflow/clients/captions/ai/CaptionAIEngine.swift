import Foundation

// MARK: - Requests

/// One over-long caption to break up.
///
/// Splitting is deliberately per-caption: the prompt stays tiny, a bad answer
/// costs one caption instead of a batch, and the on-device model never sees more
/// than a couple of hundred characters.
nonisolated struct CaptionSplitRequest: Sendable {
    var text: String
    /// The length above which a caption is considered too long. Also the target
    /// each piece should aim at.
    var maxRunes: Int
    /// Shortest acceptable piece, so the model doesn't leave an orphan line.
    var minRunes: Int
    /// Most pieces the line's length justifies. Stated in the prompt because
    /// "break only when necessary" is much easier to follow as a number.
    var maxPieces: Int
    var terms: [CaptionTerm]
    /// BCP-47 hint, so the model replies in the caption's language.
    var languageHint: String
    /// Set on a second attempt, saying what was wrong with the first answer.
    /// Asking the identical question twice would get the identical answer.
    var retryNote: String = ""
}

nonisolated struct CaptionSplitPlan: Sendable {
    /// The caption in order. One piece means "leave it alone".
    var pieces: [String]
    var reason: String = ""

    /// Reads the reply format both engines use: the line copied through with a
    /// `|` at each break point.
    ///
    /// Asking for a marked-up line rather than an array of pieces is what keeps
    /// small models honest — an array invites them to emit one element per word,
    /// and the on-device model does exactly that. Newlines count as markers too,
    /// since a model told to "insert |" will often just lay the parts out on
    /// separate lines instead.
    static func parse(markedLine: String, reason: String = "") -> CaptionSplitPlan {
        let pieces = markedLine
            .split(whereSeparator: { $0 == "|" || $0 == "｜" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return CaptionSplitPlan(pieces: pieces, reason: reason)
    }
}

/// A window of captions to check against the glossary.
nonisolated struct CaptionTermReviewRequest: Sendable {
    var lines: [CaptionAILine]
    var terms: [CaptionTerm]
    var languageHint: String
}

nonisolated struct CaptionTermCorrection: Sendable {
    /// Matches `CaptionAILine.number`.
    var number: Int
    var correctedText: String
    var reason: String = ""
}

nonisolated struct CaptionTermReviewResult: Sendable {
    var corrections: [CaptionTermCorrection]
}

/// A window of captions to translate.
///
/// Batched rather than per-caption, unlike splitting: translation quality
/// depends on surrounding context — a pronoun or an elided subject in one line
/// is only resolvable from the line before it — so the model sees a run of
/// captions and answers for all of them.
nonisolated struct CaptionTranslateRequest: Sendable {
    var lines: [CaptionAILine]
    /// BCP-47 of the captions as they stand. Empty means "work it out".
    var sourceLanguage: String
    /// BCP-47 to translate into. Never empty.
    var targetLanguage: String
    /// Glossary, so a product name survives the crossing.
    var terms: [CaptionTerm]
}

nonisolated struct CaptionTranslatedLine: Sendable {
    /// Matches `CaptionAILine.number`.
    var number: Int
    var text: String
}

nonisolated struct CaptionTranslateResult: Sendable {
    var lines: [CaptionTranslatedLine]
}

/// One turn of the caption assistant.
nonisolated struct CaptionChatRequest: Sendable {
    var instruction: String
    /// Compacted summary of everything before `recentTurns`.
    var summary: String
    /// The tail of the conversation, oldest first.
    var recentTurns: [CaptionChatTurn]
    /// The captions the app decided are relevant to this request.
    var lines: [CaptionAILine]
    /// How many captions exist in total, so the model knows `lines` is a slice.
    var totalLines: Int
    var speakers: [CaptionSpeaker]
    var terms: [CaptionTerm]
    var languageHint: String
}

nonisolated struct CaptionChatTurn: Sendable {
    var role: String
    var content: String
}

nonisolated struct CaptionChatReply: Sendable {
    var assistantText: String
    /// Changes the model wants to make, keyed by caption number rather than
    /// UUID — the engine never sees identifiers it could hallucinate.
    var edits: [CaptionChatEdit] = []
}

nonisolated struct CaptionChatEdit: Sendable {
    enum Kind: String, Sendable {
        case replaceText
        case split
        case mergeWithNext
        case delete
    }

    var number: Int
    var kind: Kind
    /// For `.replaceText`, the new text. For `.split`, the pieces.
    var pieces: [String] = []
    var reason: String = ""
}

// MARK: - Engine

/// One AI engine, three tasks.
///
/// Task-shaped rather than a generic `complete(prompt:schema:)` because the two
/// implementations get structure in fundamentally different ways — Apple's model
/// through `@Generable` types resolved at compile time, an OpenAI endpoint
/// through a JSON Schema in the request body. Hiding that behind a generic
/// signature would mean building `GenerationSchema`s at runtime for no benefit.
protocol CaptionAIEngine: Sendable {
    var backend: AgentBackend { get }

    /// What produced a suggestion, for the review sheet.
    ///
    /// Not the same as the backend's name: which engine actually ran can differ
    /// from the one in Settings — `resolved(preferred:)` falls back — and for an
    /// OpenAI-compatible endpoint the backend name says nothing useful, since
    /// the whole question is *which* model answered.
    var modelLabel: String { get }

    func planSplit(_ request: CaptionSplitRequest) async throws -> CaptionSplitPlan
    func reviewTerms(_ request: CaptionTermReviewRequest) async throws -> CaptionTermReviewResult
    func converse(_ request: CaptionChatRequest) async throws -> CaptionChatReply
    func translate(_ request: CaptionTranslateRequest) async throws -> CaptionTranslateResult
}

extension CaptionAIEngine {
    var modelLabel: String { backend.engineLabel }

    /// Safety net for an engine that hasn't implemented translation. Every
    /// engine that ships does — including the CLI ones, via `CLICaptionEngine`,
    /// which batches a hundred captions per process launch.
    func translate(_ request: CaptionTranslateRequest) async throws -> CaptionTranslateResult {
        throw CaptionAIError.backendUnavailable(
            backend,
            "This engine can't translate captions. Choose a different AI backend in Settings."
        )
    }
}

/// An engine that would rather be asked once about the whole transcript than
/// once per caption.
///
/// This is the CLI agents. Calling `planSplit` sixty times would mean sixty
/// process launches; instead they read the transcript themselves through MCP and
/// hand back one proposal, which is the arrangement the MCP bridge was built for.
/// `CaptionAISplitter` and `CaptionTermReviewer` check for this and take the
/// whole-transcript path when an engine offers it.
protocol CaptionBatchAIEngine: CaptionAIEngine {
    func proposeSplits(
        transcript: CaptionTranscriptSnapshot,
        maxRunes: Int,
        terms: [CaptionTerm],
        languageHint: String
    ) async throws -> CaptionEditProposal

    func proposeTermFixes(
        transcript: CaptionTranscriptSnapshot,
        terms: [CaptionTerm],
        languageHint: String
    ) async throws -> CaptionEditProposal
}

/// Builds the engine for a caption task.
///
/// Conversation moved to the agent window, where the command-line backends are
/// driven by `AgentCLIRunner` as a streaming tool-calling agent rather than a
/// one-shot request/response. What is left here answers the batch tasks —
/// splitting, glossary review, translation. The first two run per cue, which is
/// why the CLI engine still refuses them; translation batches, so it doesn't.
@MainActor
enum CaptionAIEngineFactory {

    /// Synchronous, so the batch tasks can build one without an `await` in the
    /// middle of a UI action.
    ///
    /// `task` only matters for the command-line backends, which can answer a
    /// batched translation but not a per-cue split. Defaulting it to
    /// `.transcriptReview` keeps every existing caller on the stricter path:
    /// handing a CLI engine to `CaptionAISplitter` would not fail loudly, it
    /// would quietly character-split the whole transcript, because `refined`
    /// swallows a per-cue error by design.
    static func make(
        backend: AgentBackend,
        config: AppConfig?,
        for task: CaptionAITask = .transcriptReview
    ) throws -> any CaptionAIEngine {
        switch backend {
        case .appleIntelligence:
            return AppleIntelligenceCaptionEngine()

        case .openAICompatible:
            guard let config else { throw CaptionAIError.noBackendAvailable }
            return OpenAICaptionEngine(
                endpoint: config.openAIEndpoint,
                apiKey: config.openAIKey,
                model: config.openAIModel
            )

        case .claudeCode, .codex:
            #if os(macOS)
                guard task == .translation else {
                    // Splitting and glossary review ask once per caption, and a
                    // process launch each would take minutes. Unchanged.
                    throw CaptionAIError.backendUnavailable(
                        backend,
                        "\(backend.engineLabel) only answers in the agent window. Choose "
                            + "Apple Intelligence or an OpenAI-compatible model for this."
                    )
                }
                guard let executable = AgentBackendAvailability.shared
                    .executablePath(for: backend)
                else {
                    throw CaptionAIError.backendUnavailable(
                        backend,
                        "The \(backend.executableName) command isn't installed."
                    )
                }
                return CLICaptionEngine(
                    backend: backend,
                    executable: executable,
                    model: backend.model(config: config)
                )
            #else
                throw CaptionAIError.backendUnavailable(
                    backend,
                    "\(backend.engineLabel) needs a command line, which this platform "
                        + "doesn't have. Choose Apple Intelligence or an "
                        + "OpenAI-compatible model."
                )
            #endif
        }
    }
}

// MARK: - Prompt fragments shared by both engines

nonisolated enum CaptionAIPrompts {

    static func splitInstructions(maxRunes: Int, minRunes: Int, maxPieces: Int) -> String {
        let markers = maxPieces - 1
        return """
            You break one overlong subtitle line into shorter lines that are \
            comfortable to read.

            Reply with the SAME line copied through, with a | inserted at each \
            place it should break. You are marking up one sentence, not \
            rewriting it as a list.

            Rules, in order of importance:
            1. Never change, add or remove a spoken word. Copy every word \
            through in order. You may add or correct sentence punctuation, and \
            nothing else.
            2. Insert AT MOST \(markers) marker\(markers == 1 ? "" : "s"). One is \
            almost always the right answer. Never put a | between every word.
            3. Only break a line longer than \(maxRunes) characters. If it is \
            short enough, reply with the line and no | at all.
            4. Break at a clause or breath boundary, so each part reads as a \
            complete thought — after a comma, or before a linking word such as \
            "because", "and" or "but". Never break inside a name, a number, or \
            a fixed expression.
            5. No part may be shorter than about \(minRunes) characters. If the \
            only available break would leave a stub, reply with no | at all.
            6. Aim for parts of similar length, each close to \(maxRunes) \
            characters.

            Example
            Line: we shipped the release on friday and everyone on the team went home happy
            Reply: We shipped the release on Friday, | and everyone on the team went home happy.

            Reply in the same language as the line.
            """
    }

    static func splitPrompt(_ request: CaptionSplitRequest) -> String {
        var parts: [String] = []
        let glossary = CaptionTermMatching.promptBlock(request.terms)
        if !glossary.isEmpty {
            parts.append(glossary)
            parts.append("Never break inside a glossary term.")
        }
        if !request.retryNote.isEmpty {
            parts.append("Your previous reply was rejected: \(request.retryNote)")
        }
        parts.append("Line (\(request.text.count) characters):")
        parts.append(request.text)
        return parts.joined(separator: "\n\n")
    }

    static let termReviewInstructions = """
        You proofread subtitles against a glossary of names and jargon.

        Report only lines where a glossary term is misspelled or was misheard. \
        For each, give the line number and the whole line with the term corrected.

        Do not rephrase. Do not fix grammar, punctuation or capitalisation \
        elsewhere in the line. Do not change any word that is not a glossary \
        term. If nothing is wrong, report nothing.
        """

    static func termReviewPrompt(_ request: CaptionTermReviewRequest) -> String {
        [
            CaptionTermMatching.promptBlock(request.terms),
            "Lines:",
            request.lines.map(\.prompt).joined(separator: "\n"),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    static func translateInstructions(source: String, target: String) -> String {
        let targetName = Locale.current.localizedString(forIdentifier: target) ?? target
        let sourceName = source.isEmpty
            ? "the source language"
            : (Locale.current.localizedString(forIdentifier: source) ?? source)

        return """
            You translate subtitles from \(sourceName) into \(targetName).

            Each input line starts with its number. Reply with one translation \
            per line, keeping the same numbers. Translate every line you are \
            given — never skip one, never merge two, never add one.

            Rules:
            1. Keep each translation about as long as its original. Subtitles are \
            read in the time the line is on screen, so a translation twice the \
            length is a worse translation.
            2. Translate meaning, not words. Idiom becomes idiom.
            3. Keep the register of the original — casual stays casual.
            4. When a line contains a glossary term, do not translate it — write \
            it as the placeholder the glossary shows, e.g. {{RxLab}}, double \
            braces included, spelled exactly as the glossary lists it. Never \
            translate or respell the text inside the braces, never put spaces \
            inside them, and never invent a placeholder for a word the glossary \
            does not list. Everything else in the line is translated normally. \
            Leave numbers and other proper nouns in the form the original uses, \
            unless \(targetName) has a standard rendering of them.
            5. Keep sentence-ending punctuation appropriate to \(targetName). Do \
            not add narration, bracketed notes, or speaker names.
            6. If a line is already in \(targetName), copy it through unchanged.
            7. Braces are only ever for glossary terms. A line with no glossary \
            term comes back with no braces at all.
            """
    }

    static func translatePrompt(_ request: CaptionTranslateRequest) -> String {
        [
            CaptionTermMatching.translationPromptBlock(
                request.terms,
                target: request.targetLanguage
            ),
            "Lines:",
            // Speaker labels are dropped: they are not the caption's words, and
            // a model shown "[Alice]" will sometimes translate the name.
            request.lines.map(\.compactPrompt).joined(separator: "\n"),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    static let chatInstructions = """
        You are a subtitle editing assistant inside a caption editor. The user \
        asks for changes in plain language; you answer briefly and, when a change \
        is called for, describe it as an edit.

        You are shown a slice of the transcript, not all of it. Each line starts \
        with its number. Refer to captions by that number.

        Edits you can make: replace a line's text, split a line into pieces, merge \
        a line with the one after it, or delete a line. Every edit is reviewed by \
        the user before it takes effect, so propose confidently, but never claim \
        a change has already been made.

        Keep replies to a couple of sentences.
        """

    static func chatPrompt(_ request: CaptionChatRequest) -> String {
        var parts: [String] = []

        if !request.summary.isEmpty {
            parts.append("Earlier in this conversation:\n\(request.summary)")
        }
        for turn in request.recentTurns {
            parts.append("\(turn.role.capitalized): \(turn.content)")
        }

        let glossary = CaptionTermMatching.promptBlock(request.terms)
        if !glossary.isEmpty { parts.append(glossary) }

        if !request.speakers.isEmpty {
            parts.append("Speakers: " + request.speakers.map(\.label).joined(separator: ", "))
        }

        if request.lines.isEmpty {
            parts.append("No captions matched; the transcript has \(request.totalLines) lines.")
        } else {
            parts.append(
                "Captions (\(request.lines.count) of \(request.totalLines)):\n"
                + request.lines.map(\.prompt).joined(separator: "\n")
            )
        }

        parts.append("Request: \(request.instruction)")
        return parts.joined(separator: "\n\n")
    }
}
