import Foundation
import Translation

/// Translates captions with Apple's on-device `Translation` framework.
///
/// The session is handed in rather than created here: `TranslationSession` is
/// only ever vended by the `.translationTask` view modifier, which is also why
/// this runner cannot be used from MCP. The view owns the session's lifetime;
/// this type owns what to do with it.
@MainActor
struct AppleTranslationRunner: CaptionTranslationRunner {
    var kind: CaptionTranslationEngineKind { .appleTranslation }

    let session: TranslationSession
    let sourceLanguage: String
    let targetLanguage: String

    /// Requests per `translate(batch:)` call.
    ///
    /// The framework has no documented ceiling, but one call for nine hundred
    /// captions is also one cancellation point and one progress update. Chunking
    /// buys responsiveness, not throughput.
    private let chunkSize = 150

    func translate(
        _ requests: [CaptionTranslationRequest],
        onBatch: @MainActor ([CaptionTranslationResult]) -> Void,
        onProgress: @MainActor (CaptionTranslationProgress) -> Void
    ) async throws -> CaptionTranslationRun {
        guard !requests.isEmpty else { return CaptionTranslationRun() }

        // Downloads the language pack if needed. Called before any writing so
        // the system's download prompt appears while the transcript is still
        // untouched, rather than halfway through a run.
        try await session.prepareTranslation()

        var run = CaptionTranslationRun()
        run.results.reserveCapacity(requests.count)
        var done = 0

        for chunk in requests.chunked(into: chunkSize) {
            try Task.checkCancellation()

            // `clientIdentifier` is the only handle the framework gives back, so
            // the segment's UUID rides on it — responses are not guaranteed to
            // come back in request order.
            let batch = chunk.map {
                TranslationSession.Request(
                    sourceText: $0.text,
                    clientIdentifier: $0.segmentID.uuidString
                )
            }
            onProgress(
                CaptionTranslationProgress(
                    done: done,
                    total: requests.count,
                    inFlight: chunk.count
                )
            )

            var chunkResults: [CaptionTranslationResult] = []
            var answered = 0
            for try await response in session.translate(batch: batch) {
                // The framework answers one caption at a time, so progress can
                // move per caption rather than per chunk — a 28-caption
                // transcript is one chunk, and per-chunk reporting would sit at
                // zero for the whole run.
                answered += 1
                onProgress(
                    CaptionTranslationProgress(
                        done: min(done + answered, requests.count),
                        total: requests.count,
                        inFlight: max(chunk.count - answered, 0)
                    )
                )

                guard let raw = response.clientIdentifier,
                      let segmentID = UUID(uuidString: raw)
                else { continue }
                let text = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                chunkResults.append(CaptionTranslationResult(segmentID: segmentID, text: text))
            }

            run.results.append(contentsOf: chunkResults)
            run.failed += chunk.count - chunkResults.count
            onBatch(chunkResults)

            done += chunk.count
            onProgress(
                CaptionTranslationProgress(
                    done: min(done, requests.count),
                    total: requests.count
                )
            )
        }

        return run
    }
}

extension Array {
    /// Fixed-size slices, last one short. Local to the translation runners —
    /// `CaptionAIContext.batches` is the equivalent for the AI path, but it
    /// packs by character budget rather than count.
    fileprivate func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
