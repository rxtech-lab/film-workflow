import Foundation

/// Translates captions with whichever AI backend is configured.
///
/// Slower and more expensive than `AppleTranslationRunner`, and worth it for two
/// things it can do that Apple's engine can't: follow the project glossary, so a
/// product name survives the crossing intact, and run without a SwiftUI view
/// attached, which is the only way MCP can translate anything.
@MainActor
struct AICaptionTranslationRunner: CaptionTranslationRunner {
    var kind: CaptionTranslationEngineKind { .aiBackend }

    let engine: any CaptionAIEngine
    let sourceLanguage: String
    let targetLanguage: String
    let terms: [CaptionTerm]

    func translate(
        _ requests: [CaptionTranslationRequest],
        onProgress: @MainActor (Int, Int) -> Void
    ) async throws -> [CaptionTranslationResult] {
        guard !requests.isEmpty else { return [] }

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

        // Leave room for the instructions and the reply. A translation is
        // roughly as long as its original, so the reply costs about as much as
        // the prompt — hence half the budget rather than all of it.
        let budget = max(engine.backend.contextBudgetCharacters / 2, 400)

        var results: [CaptionTranslationResult] = []
        var done = 0

        for batch in CaptionAIContext.batches(lines, budget: budget) {
            try Task.checkCancellation()

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
            let allowed = Set(batch.map(\.number))
            for line in reply.lines where allowed.contains(line.number) {
                guard let segmentID = byNumber[line.number] else { continue }
                let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                results.append(CaptionTranslationResult(segmentID: segmentID, text: text))
            }

            done += batch.count
            onProgress(min(done, requests.count), requests.count)
        }

        return results
    }
}
