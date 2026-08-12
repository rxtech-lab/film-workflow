import Foundation

/// Finds captions where a glossary term was misheard, and proposes the fix.
///
/// Batched to the engine's context budget and validated with the `glossaryOnly`
/// policy, so a model that decides to improve the prose along the way has its
/// improvements flagged rather than applied.
nonisolated enum CaptionTermReviewer {

    static func proposal(
        for transcript: CaptionTranscriptSnapshot,
        terms: [CaptionTerm],
        languageHint: String,
        engine: any CaptionAIEngine,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> CaptionEditProposal {
        if let batch = engine as? any CaptionBatchAIEngine {
            return try await batch.proposeTermFixes(
                transcript: transcript,
                terms: terms.filter { !$0.isEmpty },
                languageHint: languageHint
            )
        }

        let usable = terms.filter { !$0.isEmpty }
        guard !usable.isEmpty else {
            return CaptionEditProposal(
                summary: "Add some terms in the caption setup panel first.",
                engine: engine.modelLabel
            )
        }

        let lines = CaptionAIContext.lines(from: transcript.segments)
        guard !lines.isEmpty else {
            return CaptionEditProposal(
                summary: "There are no captions to check.",
                engine: engine.modelLabel
            )
        }

        // The glossary rides along in every batch, so its size comes out of the
        // per-batch budget rather than being ignored.
        let glossaryCost = CaptionTermMatching.promptBlock(usable).count
        let budget = max(engine.backend.contextBudgetCharacters - glossaryCost, 400)
        let batches = CaptionAIContext.batches(lines, budget: budget)

        var lineByNumber: [Int: CaptionAILine] = [:]
        for line in lines { lineByNumber[line.number] = line }

        var operations: [CaptionEditOperation] = []
        var failures = 0

        for (index, batch) in batches.enumerated() {
            try Task.checkCancellation()

            do {
                let result = try await engine.reviewTerms(CaptionTermReviewRequest(
                    lines: batch,
                    terms: usable,
                    languageHint: languageHint
                ))

                for correction in result.corrections {
                    // The model can only name a line we showed it in this batch;
                    // anything else is a hallucinated number.
                    guard let line = lineByNumber[correction.number],
                          batch.contains(where: { $0.number == correction.number }) else {
                        continue
                    }
                    let corrected = correction.correctedText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !corrected.isEmpty, corrected != line.text else { continue }
                    operations.append(.replaceText(segment: line.segmentID, newText: corrected))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
            }

            onProgress?(index + 1, batches.count)
        }

        var proposal = CaptionProposalBuilder.build(
            operations: operations,
            transcript: transcript,
            terms: usable,
            policy: .glossaryOnly,
            maxRunes: 0,
            summary: summary(lines: lines.count, terms: usable.count, failures: failures),
            engine: engine.modelLabel
        )
        if proposal.items.isEmpty {
            proposal.summary = "Checked \(lines.count) caption\(lines.count == 1 ? "" : "s") "
                + "against \(usable.count) term\(usable.count == 1 ? "" : "s") — all correct."
        }
        return proposal
    }

    private static func summary(lines: Int, terms: Int, failures: Int) -> String {
        var text = "Checked \(lines) caption\(lines == 1 ? "" : "s") against "
            + "\(terms) term\(terms == 1 ? "" : "s")."
        if failures > 0 {
            text += " \(failures) batch\(failures == 1 ? "" : "es") couldn't be reviewed."
        }
        return text
    }
}
