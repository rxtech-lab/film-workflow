import Foundation

/// Translates captions with whichever AI backend is configured.
///
/// Slower and more expensive than `AppleTranslationRunner`, and worth it for two
/// things it can do that Apple's engine can't: follow the project glossary, so a
/// product name survives the crossing intact, and run without a SwiftUI view
/// attached, which is the only way MCP can translate anything.
///
/// The batch sizes are a starting guess, not a guarantee. Every model has a
/// different completion cap and no way to ask what it is, so a batch that
/// overruns is halved and retried rather than failing the run — see
/// `translate(batch:)`.
@MainActor
struct AICaptionTranslationRunner: CaptionTranslationRunner {
    var kind: CaptionTranslationEngineKind { .aiBackend }

    /// The model that actually ran, not the backend chosen in Settings — for an
    /// OpenAI-compatible endpoint those are very different answers.
    var modelLabel: String { engine.modelLabel }

    let engine: any CaptionAIEngine
    let sourceLanguage: String
    let targetLanguage: String
    let terms: [CaptionTerm]

    /// Fraction of a batch the model must actually answer for the reply to be
    /// taken at face value.
    ///
    /// A model that runs out of room mid-array doesn't always fail loudly —
    /// sometimes it closes the JSON early and returns a valid object covering
    /// the first eleven of sixty lines. Without this check those forty-nine
    /// captions would be silently dropped and reported as a success.
    private static let minimumCoverage = 0.6

    func translate(
        _ requests: [CaptionTranslationRequest],
        onBatch: @MainActor ([CaptionTranslationResult]) -> Void,
        onProgress: @MainActor (CaptionTranslationProgress) -> Void
    ) async throws -> CaptionTranslationRun {
        guard !requests.isEmpty else { return CaptionTranslationRun() }

        // Numbers, not UUIDs — a number costs one token and cannot be
        // hallucinated into a different caption. The mapping stays here.
        let lines = requests.enumerated().map { index, request in
            CaptionAILine(
                number: index + 1,
                segmentID: request.segmentID,
                startMs: 0,
                speaker: "",
                text: request.text
            )
        }
        let byNumber = Dictionary(uniqueKeysWithValues: lines.map { ($0.number, $0.segmentID) })

        // The glossary rides in every batch, so its size comes out of the
        // per-batch budget rather than being ignored. Measured against the block
        // that is actually sent — the translation variant, with its placeholders
        // and per-language wordings, is longer than the plain one.
        let glossaryCost = CaptionTermMatching
            .translationPromptBlock(terms, target: targetLanguage)
            .count
        let budget = max(engine.backend.translationBatchCharacters - glossaryCost, 400)

        // Compiled once for the run: every reply goes through it on the way to
        // storage, so a hallucinated or sloppily-spelled placeholder is fixed or
        // unwrapped before it reaches a caption.
        let resolver = CaptionTermResolver(terms: terms)

        var run = CaptionTranslationRun()
        var done = 0

        // Charged against `compactPrompt` because that is what
        // `CaptionAIPrompts.translatePrompt` actually sends — the speaker label
        // in `prompt` is dropped for translation.
        for batch in CaptionAIContext.batches(
            lines,
            budget: budget,
            maxLines: engine.backend.translationBatchLines,
            cost: { $0.compactPrompt.count + 1 }
        ) {
            try Task.checkCancellation()

            // Announced before the request goes out, not after it returns: a
            // 28-caption transcript is a single batch, and without this the
            // sheet would show 0 of 28 for the whole run and then close.
            onProgress(
                CaptionTranslationProgress(
                    done: done,
                    total: requests.count,
                    inFlight: batch.count
                )
            )

            let translated = try await translate(batch: batch)

            var batchResults: [CaptionTranslationResult] = []
            for line in translated {
                guard let segmentID = byNumber[line.number] else { continue }
                let text = resolver
                    .sanitize(line.text, unwrapUnknown: true)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                batchResults.append(CaptionTranslationResult(segmentID: segmentID, text: text))
            }

            run.results.append(contentsOf: batchResults)
            run.failed += batch.count - batchResults.count
            // Handed over now, not at the end: a failure three batches later
            // must not cost the user the work already paid for.
            onBatch(batchResults)

            done += batch.count
            onProgress(
                CaptionTranslationProgress(
                    done: min(done, requests.count),
                    total: requests.count
                )
            )
        }

        return run
    }

    // MARK: - One batch, however many attempts it takes

    /// Translates one batch, halving it and retrying when the model can't
    /// manage the whole thing.
    ///
    /// The failure this exists for is not exotic: the reply has to restate every
    /// line, so a batch sized to fit the *prompt* window can still ask for a
    /// completion longer than the model will produce. That surfaces as an
    /// overflow error, an unparseable half-written reply, or a valid reply
    /// covering a third of the lines — all three mean the same thing, and all
    /// three are fixed by asking about fewer lines.
    ///
    /// Returns whatever it could translate. A single caption that still fails is
    /// dropped, counted by the caller, and left for the user to re-run.
    private func translate(batch: [CaptionAILine]) async throws -> [CaptionTranslatedLine] {
        guard !batch.isEmpty else { return [] }
        try Task.checkCancellation()

        let allowed = Set(batch.map(\.number))

        do {
            let reply = try await engine.translate(
                CaptionTranslateRequest(
                    lines: batch,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    terms: terms
                )
            )

            // Only accept numbers that were actually in this batch. A model that
            // renumbers or invents a line would otherwise write a translation
            // onto the wrong caption — silently, and in a language the user
            // can't proofread. Dropping is the safe failure.
            var seen = Set<Int>()
            let usable = reply.lines.filter { line in
                guard allowed.contains(line.number), seen.insert(line.number).inserted else {
                    return false
                }
                return !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

            let coverage = Double(usable.count) / Double(batch.count)
            guard coverage < Self.minimumCoverage, batch.count > 1 else { return usable }
            // Too little of the batch came back to trust the rest of it.
            return try await bisect(batch)

        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard CaptionAIRetryPolicy.isWorthSplitting(error) else { throw error }
            // One caption and still failing: this is as small as the question
            // gets, so stop asking. The caller counts it and moves on.
            guard batch.count > 1 else { return [] }
            return try await bisect(batch)
        }
    }

    private func bisect(_ batch: [CaptionAILine]) async throws -> [CaptionTranslatedLine] {
        let middle = batch.count / 2
        let first = try await translate(batch: Array(batch[..<middle]))
        let second = try await translate(batch: Array(batch[middle...]))
        return first + second
    }
}
