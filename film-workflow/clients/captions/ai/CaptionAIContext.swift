import Foundation

/// One caption as the model sees it.
///
/// Numbered rather than identified by UUID: a number is one token, a UUID is
/// about twenty, and on a 4k-token window that difference decides how many
/// captions fit. The mapping back to real segments stays on our side, which also
/// means the model cannot invent an identifier.
nonisolated struct CaptionAILine: Sendable, Hashable {
    /// 1-based position in the transcript, matching the editor's row numbers.
    var number: Int
    var segmentID: UUID
    var startMs: Int
    var speaker: String
    var text: String

    /// The rendered form that goes into a prompt.
    var prompt: String {
        var out = "\(number). "
        if !speaker.isEmpty { out += "[\(speaker)] " }
        out += text
        return out
    }

    /// Same, minus the speaker — the first thing dropped when space is tight.
    var compactPrompt: String {
        "\(number). \(text)"
    }
}

/// Chooses what the model gets to see.
///
/// The whole feature depends on this. Apple's on-device model has roughly a
/// 4k-token window shared between prompt and response, so "send the transcript"
/// is not an option for anything longer than a couple of minutes. Instead the
/// app decides which captions are relevant and packs only those.
nonisolated enum CaptionAIContext {

    // MARK: - Lines

    static func lines(from segments: [CaptionSegmentSnapshot]) -> [CaptionAILine] {
        segments.enumerated().map { index, segment in
            CaptionAILine(
                number: index + 1,
                segmentID: segment.id,
                startMs: segment.startMs,
                speaker: segment.speakerLabel,
                text: segment.text
            )
        }
    }

    // MARK: - Batching

    /// Packs lines into windows that fit `budget` characters.
    ///
    /// Greedy and order-preserving: a caption is never split across windows, and
    /// a single caption longer than the whole budget still gets its own window
    /// rather than being dropped — losing it silently would be worse than one
    /// oversized request that the engine can reject.
    static func batches(_ lines: [CaptionAILine], budget: Int) -> [[CaptionAILine]] {
        guard !lines.isEmpty else { return [] }
        let limit = max(budget, 200)

        var batches: [[CaptionAILine]] = []
        var current: [CaptionAILine] = []
        var used = 0

        for line in lines {
            let cost = line.prompt.count + 1
            if !current.isEmpty, used + cost > limit {
                batches.append(current)
                current = []
                used = 0
            }
            current.append(line)
            used += cost
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    // MARK: - Retrieval

    /// Picks the captions a chat request is about.
    ///
    /// Three sources, unioned: explicit `#12` / `caption 12` references in the
    /// message, the rows the user has selected in the editor, and a keyword match
    /// over the transcript. Each hit brings its immediate neighbours along, since
    /// "merge this with the next one" is meaningless without the next one.
    ///
    /// When nothing matches — "tidy up the punctuation" — it falls back to the
    /// head of the transcript rather than nothing, so the model always has
    /// something concrete to work with.
    static func retrieve(
        query: String,
        lines: [CaptionAILine],
        selection: Set<UUID> = [],
        budget: Int
    ) -> [CaptionAILine] {
        guard !lines.isEmpty else { return [] }

        var wanted = Set<Int>()

        for number in explicitReferences(in: query) where number >= 1 && number <= lines.count {
            wanted.insert(number)
        }
        for line in lines where selection.contains(line.segmentID) {
            wanted.insert(line.number)
        }

        let queryTokens = Set(CaptionTermMatching.tokens(query)).filter { $0.count > 1 }
        if !queryTokens.isEmpty {
            let scored = lines
                .map { line -> (Int, Int) in
                    let tokens = Set(CaptionTermMatching.tokens(line.text))
                    return (line.number, tokens.intersection(queryTokens).count)
                }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
            for (number, _) in scored.prefix(20) { wanted.insert(number) }
        }

        // Neighbours, so relative instructions have something to refer to.
        for number in wanted {
            if number > 1 { wanted.insert(number - 1) }
            if number < lines.count { wanted.insert(number + 1) }
        }

        if wanted.isEmpty {
            return trimmed(Array(lines.prefix(40)), budget: budget)
        }
        let selected = lines.filter { wanted.contains($0.number) }
        return trimmed(selected, budget: budget)
    }

    /// `#12`, `caption 12`, `line 12` and bare numbers in a short message.
    static func explicitReferences(in query: String) -> [Int] {
        var out: [Int] = []
        var digits = ""

        for character in query {
            if character.isNumber {
                digits.append(character)
                continue
            }
            if !digits.isEmpty {
                if let value = Int(digits) { out.append(value) }
                digits = ""
            }
        }
        if !digits.isEmpty, let value = Int(digits) { out.append(value) }
        return out
    }

    /// Drops lines from the end until the batch fits.
    ///
    /// The end rather than the middle: a contiguous prefix keeps the numbering
    /// legible, and the model is told how many lines it is missing.
    static func trimmed(_ lines: [CaptionAILine], budget: Int) -> [CaptionAILine] {
        var used = 0
        var out: [CaptionAILine] = []
        for line in lines {
            let cost = line.prompt.count + 1
            if used + cost > budget, !out.isEmpty { break }
            out.append(line)
            used += cost
        }
        return out
    }

    // MARK: - Conversation compaction

    /// How many turns are kept verbatim before older ones are summarized.
    static let verbatimTurns = 4

    /// Splits a conversation into "needs summarizing" and "keep verbatim".
    static func partition(
        turns: [CaptionChatTurn],
        keeping verbatim: Int = verbatimTurns
    ) -> (older: [CaptionChatTurn], recent: [CaptionChatTurn]) {
        guard turns.count > verbatim else { return ([], turns) }
        let cut = turns.count - verbatim
        return (Array(turns[..<cut]), Array(turns[cut...]))
    }

    /// Whether the assembled prompt would overrun the backend's budget.
    static func exceedsBudget(_ text: String, backend: CaptionAIBackend) -> Bool {
        text.count > backend.contextBudgetCharacters
    }
}
