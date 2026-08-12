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
    var backend: CaptionAIBackend { get }

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
}

extension CaptionAIEngine {
    var modelLabel: String { backend.engineLabel }
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

/// Builds the engine for a backend.
///
/// The CLI backends need a running MCP server and a resolved binary path, both
/// of which are main-actor state — which is why this is `async` and lives here
/// rather than in each engine's initializer.
@MainActor
enum CaptionAIEngineFactory {

    /// In-process engines. Synchronous, so the batch tasks can build one without
    /// an `await` in the middle of a UI action.
    static func make(
        backend: CaptionAIBackend,
        config: AppConfig?
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
            throw CaptionAIError.backendUnavailable(
                backend,
                "This engine has to be started with makeConversational."
            )
        }
    }

    /// Any backend, including the command-line ones.
    ///
    /// Returns the endpoint alongside the engine so the caller can release the
    /// MCP server when the turn finishes.
    static func makeConversational(
        backend: CaptionAIBackend,
        config: AppConfig?,
        project: CaptionProject
    ) async throws -> (engine: any CaptionAIEngine, release: @Sendable () async -> Void) {
        #if os(macOS)
            if backend.isCommandLine {
                guard let executable = CaptionAIAvailability.shared.executablePath(for: backend)
                else {
                    throw CaptionAIError.backendUnavailable(
                        backend,
                        "The \(backend.executableName) command isn't installed."
                    )
                }

                let endpoint = try await CaptionMCPBridge.ensureRunning()
                let context = CaptionCLIContext(
                    executable: executable,
                    endpoint: endpoint,
                    captionID: project.projectUUID,
                    projectName: project.name,
                    model: "",
                    // The agent has no repository to work in; point it at our own
                    // storage so a stray relative path can't touch a user project.
                    workingDirectory: FileStorage.captionsDir
                )

                let engine: any CaptionAIEngine = backend == .claudeCode
                    ? ClaudeCodeCaptionEngine(context: context)
                    : CodexCaptionEngine(context: context)

                return (engine, { await CaptionMCPBridge.release(endpoint) })
            }
        #endif

        return (try make(backend: backend, config: config), {})
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
