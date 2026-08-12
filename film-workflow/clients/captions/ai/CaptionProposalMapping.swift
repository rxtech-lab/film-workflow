import Foundation

/// Turns a model's line-numbered caption edits into a reviewable proposal.
///
/// This is the boundary where a language model's output stops being text and
/// starts being an operation on real segments, so it is also where a
/// hallucinated line number is dropped rather than becoming an edit — the model
/// never sees a segment UUID, only the numbers we handed it.
///
/// Pure and `nonisolated` so it can be tested without a store or a main actor.
nonisolated enum CaptionProposalMapping {

    static func proposal(
        from edits: [CaptionChatEdit],
        lines: [CaptionAILine],
        transcript: CaptionTranscriptSnapshot,
        terms: [CaptionTerm],
        maxRunes: Int,
        engine: String = ""
    ) -> CaptionEditProposal? {
        guard !edits.isEmpty else { return nil }

        var lineByNumber: [Int: CaptionAILine] = [:]
        for line in lines { lineByNumber[line.number] = line }

        var operations: [CaptionEditOperation] = []
        var reasons: [UUID: String] = [:]

        for edit in edits {
            guard let line = lineByNumber[edit.number] else { continue }
            let pieces = edit.pieces
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            switch edit.kind {
            case .replaceText:
                guard let text = pieces.first else { continue }
                operations.append(.replaceText(segment: line.segmentID, newText: text))
            case .split:
                guard pieces.count >= 2 else { continue }
                operations.append(.split(segment: line.segmentID, pieces: pieces))
            case .mergeWithNext:
                guard let next = lineByNumber[edit.number + 1] else { continue }
                operations.append(.merge(segment: line.segmentID, withNext: next.segmentID))
            case .delete:
                operations.append(.delete(segment: line.segmentID))
            }

            if !edit.reason.isEmpty { reasons[line.segmentID] = edit.reason }
        }

        guard !operations.isEmpty else { return nil }

        return CaptionProposalBuilder.build(
            operations: operations,
            transcript: transcript,
            terms: terms,
            // The user asked for these in their own words, so the wording is
            // theirs to choose — validation only checks applicability.
            policy: .free,
            maxRunes: maxRunes,
            summary: "\(operations.count) change\(operations.count == 1 ? "" : "s") to review",
            engine: engine,
            reasons: reasons
        )
    }
}
