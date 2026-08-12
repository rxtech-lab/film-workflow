import Foundation

/// How strictly a batch of AI-proposed operations is judged.
///
/// The three AI tasks trust the model with different amounts of rope, and the
/// validator is the only thing enforcing that. Splitting may not change a single
/// word; the glossary pass may change only glossary words; a conversational edit
/// is whatever the user asked for, so it is checked for applicability but not
/// for content.
nonisolated enum CaptionProposalPolicy: Sendable {
    /// Line breaks and punctuation only.
    case preserveWords
    /// Only glossary terms and their variants may change.
    case glossaryOnly
    /// The user asked for it in the chat; don't second-guess the wording.
    case free
}

/// Turns raw operations from a model into a reviewable, validated proposal.
///
/// Pure and `nonisolated` so it is unit-testable without a model, a project, or
/// a `ModelContext` — it works entirely off a `CaptionTranscriptSnapshot`.
nonisolated struct CaptionProposalBuilder {

    /// Below this many content characters a split piece reads as an orphan
    /// rather than a line. Expressed as a fraction of the cue limit so raising
    /// the limit raises the floor with it.
    static func minimumPieceRunes(maxRunes: Int) -> Int {
        max(Int(Double(maxRunes) * 0.35), 8)
    }

    /// How many pieces a caption of this length may legitimately become.
    ///
    /// This is the "break only when necessary" rule made concrete. A caption is
    /// split *because* it exceeds the limit, so the number of pieces should be
    /// about the minimum that gets every piece under it — plus one, since a
    /// break at a clause boundary won't divide the line evenly.
    static func maximumPieces(originalRunes: Int, maxRunes: Int) -> Int {
        guard maxRunes > 0 else { return Int.max }
        let needed = Int(ceil(Double(originalRunes) / Double(maxRunes)))
        return max(needed + 1, 2)
    }

    static func build(
        operations: [CaptionEditOperation],
        transcript: CaptionTranscriptSnapshot,
        terms: [CaptionTerm],
        policy: CaptionProposalPolicy,
        maxRunes: Int,
        summary: String = "",
        engine: String = "",
        reasons: [UUID: String] = [:]
    ) -> CaptionEditProposal {
        // Index once: a proposal over a 900-caption transcript would otherwise
        // be quadratic.
        var indexByID: [UUID: Int] = [:]
        for (index, segment) in transcript.segments.enumerated() {
            indexByID[segment.id] = index
        }

        var items: [CaptionEditProposalItem] = []
        for operation in operations {
            guard let position = indexByID[operation.segmentID] else {
                // Silently dropping would hide a model that is hallucinating
                // ids, so surface it as an unapplicable row instead.
                items.append(CaptionEditProposalItem(
                    operation: operation,
                    displayIndex: 0,
                    startMs: 0,
                    before: "",
                    after: "",
                    verdict: .notApplicable("This caption no longer exists."),
                    reason: reasons[operation.segmentID] ?? ""
                ))
                continue
            }
            let segment = transcript.segments[position]

            guard let item = item(
                for: operation,
                segment: segment,
                position: position,
                transcript: transcript,
                indexByID: indexByID,
                terms: terms,
                policy: policy,
                maxRunes: maxRunes,
                reason: reasons[operation.segmentID] ?? ""
            ) else { continue }

            items.append(item)
        }

        return CaptionEditProposal(summary: summary, engine: engine, items: items)
    }

    // MARK: - Per-operation

    private static func item(
        for operation: CaptionEditOperation,
        segment: CaptionSegmentSnapshot,
        position: Int,
        transcript: CaptionTranscriptSnapshot,
        indexByID: [UUID: Int],
        terms: [CaptionTerm],
        policy: CaptionProposalPolicy,
        maxRunes: Int,
        reason: String
    ) -> CaptionEditProposalItem? {
        func makeItem(after: String, verdict: CaptionEditVerdict) -> CaptionEditProposalItem {
            CaptionEditProposalItem(
                operation: operation,
                displayIndex: position + 1,
                startMs: segment.startMs,
                before: segment.text,
                after: after,
                verdict: verdict,
                reason: reason
            )
        }

        switch operation {
        case .split(_, let rawPieces):
            let pieces = rawPieces
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            // One piece means "leave it alone" — that's a valid answer from the
            // splitter, not a change to review.
            guard pieces.count >= 2 else { return nil }

            let after = pieces.joined(separator: " / ")
            return makeItem(after: after, verdict: splitVerdict(
                pieces: pieces,
                original: segment.text,
                maxRunes: maxRunes
            ))

        case .replaceText(_, let rawText):
            let newText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newText.isEmpty, newText != segment.text else { return nil }
            return makeItem(after: newText, verdict: textVerdict(
                newText: newText,
                original: segment.text,
                terms: terms,
                policy: policy
            ))

        case .merge(_, let nextID):
            guard let nextPosition = indexByID[nextID] else {
                return makeItem(after: "", verdict: .notApplicable("The next caption no longer exists."))
            }
            guard nextPosition == position + 1 else {
                return makeItem(
                    after: "",
                    verdict: .notApplicable("Only neighbouring captions can be merged.")
                )
            }
            let next = transcript.segments[nextPosition]
            return makeItem(after: CaptionText.join(segment.text, next.text), verdict: .ok)

        case .setSpeaker(_, let speakerID):
            guard let speaker = transcript.speakers.first(where: { $0.id == speakerID }) else {
                return makeItem(after: "", verdict: .notApplicable("That speaker no longer exists."))
            }
            guard speakerID != segment.speakerId else { return nil }
            return makeItem(after: speaker.label, verdict: .ok)

        case .delete:
            return makeItem(after: "", verdict: .ok)
        }
    }

    // MARK: - Verdicts

    /// A split must reconstruct the original words exactly. Punctuation and
    /// spacing are free — that is the whole point of letting the model repunctuate
    /// — but a dropped or invented word would silently corrupt the transcript.
    static func splitVerdict(
        pieces: [String],
        original: String,
        maxRunes: Int
    ) -> CaptionEditVerdict {
        let rebuilt = CaptionTermMatching.tokens(pieces.joined(separator: " "))
        let expected = CaptionTermMatching.tokens(original)
        guard rebuilt == expected else { return .wordsChanged }

        // The primary guard, and the one that catches a model shredding a line
        // into one word per caption. A per-piece length rule cannot: when *every*
        // piece is tiny none of them stands out as the short one, so the check
        // has to be on how many pieces there are relative to how long the line
        // actually was.
        if pieces.count > maximumPieces(originalRunes: original.count, maxRunes: maxRunes) {
            return .overSplit
        }

        // Then the orphan case: one stub line beside a full one. "Too short"
        // here is relative, not absolute — six Han characters is a whole clause
        // where six Latin characters is a fragment, and an absolute floor flags
        // every well-balanced CJK split.
        let weights = pieces.map { CaptionText.wordRuneCount($0) }
        guard let longest = weights.max(), longest > 0 else { return .ok }
        let floor = minimumPieceRunes(maxRunes: maxRunes)
        let dwarfed = Double(longest) * 0.4

        if weights.contains(where: { $0 < floor && Double($0) < dwarfed }) {
            return .stubPiece
        }
        return .ok
    }

    /// A glossary correction may only touch glossary words.
    ///
    /// Compares the two token sequences and requires every token that appears on
    /// exactly one side to belong to some term's canonical or variant spelling.
    /// That is looser than a positional diff — which is deliberate, since a
    /// two-token variant collapsing into one token shifts every later position.
    static func textVerdict(
        newText: String,
        original: String,
        terms: [CaptionTerm],
        policy: CaptionProposalPolicy
    ) -> CaptionEditVerdict {
        switch policy {
        case .free:
            return .ok

        case .preserveWords:
            return CaptionTermMatching.tokens(newText) == CaptionTermMatching.tokens(original)
                ? .ok
                : .wordsChanged

        case .glossaryOnly:
            let before = CaptionTermMatching.tokens(original)
            let after = CaptionTermMatching.tokens(newText)
            guard before != after else { return .ok }

            let allowed = Set(terms.flatMap(\.normalizedForms).flatMap { $0 })
            for token in symmetricDifference(before, after) where !allowed.contains(token) {
                return .editedNonTerm(token)
            }
            return .ok
        }
    }

    /// Tokens whose multiplicity differs between the two sequences.
    private static func symmetricDifference(_ lhs: [String], _ rhs: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for token in lhs { counts[token, default: 0] += 1 }
        for token in rhs { counts[token, default: 0] -= 1 }
        return counts.compactMap { $0.value == 0 ? nil : $0.key }
    }
}
