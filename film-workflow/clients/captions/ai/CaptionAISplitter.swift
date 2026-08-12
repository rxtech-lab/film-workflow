import Foundation

/// Chooses where over-long captions should break, using a language model
/// instead of a character counter.
///
/// Two entry points that share the same validation:
/// - `refine(cues:)` runs inside the transcription pipeline, before segments
///   exist, and rewrites the cue list in place.
/// - `proposal(for:)` runs on an existing project and produces a reviewable
///   `CaptionEditProposal`.
nonisolated enum CaptionAISplitter {

    /// Ceiling applied while building cues in AI mode.
    ///
    /// The character split must not run first — the model can only choose a good
    /// break point if it is given the whole sentence. But leaving cues entirely
    /// unbounded would hand a minutes-long unpunctuated run to a model with a
    /// 4k-token window, so a generous multiple of the user's limit still applies.
    static func rawCueCeiling(maxRunes: Int) -> Int {
        max(maxRunes, 20) * 6
    }

    // MARK: - Pipeline entry point

    /// Re-splits every cue longer than `maxRunes`.
    ///
    /// Never fails the run: a cue whose plan is rejected, or whose engine call
    /// throws, falls back to exactly the character split that would have
    /// happened anyway. The worst case is today's behavior.
    static func refine(
        cues: [CaptionCue],
        maxRunes: Int,
        terms: [CaptionTerm],
        languageHint: String,
        engine: any CaptionAIEngine,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [CaptionCue] {
        let overlong = cues.indices.filter { cues[$0].text.count > maxRunes }
        guard !overlong.isEmpty else { return cues }

        var out: [CaptionCue] = []
        out.reserveCapacity(cues.count)
        var done = 0

        for (index, cue) in cues.enumerated() {
            guard overlong.contains(index) else {
                out.append(cue)
                continue
            }

            if Task.isCancelled {
                out.append(contentsOf: cues[index...])
                break
            }

            out.append(contentsOf: await refined(
                cue: cue,
                maxRunes: maxRunes,
                terms: terms,
                languageHint: languageHint,
                engine: engine
            ))

            done += 1
            onProgress?(done, overlong.count)
        }
        return out
    }

    private static func refined(
        cue: CaptionCue,
        maxRunes: Int,
        terms: [CaptionTerm],
        languageHint: String,
        engine: any CaptionAIEngine
    ) async -> [CaptionCue] {
        // Anything past the engine's budget can't be reasoned about in one call.
        guard cue.text.count <= engine.backend.contextBudgetCharacters else {
            return characterSplit(cue, maxRunes: maxRunes)
        }

        guard let plan = try? await validatedPlan(
            text: cue.text,
            maxRunes: maxRunes,
            terms: terms,
            languageHint: languageHint,
            engine: engine
        ) else {
            return characterSplit(cue, maxRunes: maxRunes)
        }

        // The model deciding not to split is a valid answer, and the whole point
        // of "break only when necessary" — honour it.
        guard plan.pieces.count >= 2 else { return [cue] }

        return split(cue, into: plan.pieces) ?? characterSplit(cue, maxRunes: maxRunes)
    }

    // MARK: - Asking the model

    /// Thrown when the model's answer still didn't validate on the retry.
    struct RejectedPlan: Error {
        var verdict: CaptionEditVerdict
    }

    /// Asks where one line should break, retrying once with the rejection reason
    /// when the first answer doesn't validate.
    ///
    /// The retry is what makes a strict validator affordable. Without it every
    /// rejection silently costs the AI split for that caption; with it, a small
    /// model that shredded the line usually gets it right the second time, when
    /// told in so many words that it did.
    ///
    /// Returns a single piece when the model declined to split. Throws
    /// `RejectedPlan` when both attempts failed, which both callers already
    /// treat as "this caption couldn't be reviewed".
    static func validatedPlan(
        text: String,
        maxRunes: Int,
        terms: [CaptionTerm],
        languageHint: String,
        engine: any CaptionAIEngine
    ) async throws -> CaptionSplitPlan {
        let maxPieces = CaptionProposalBuilder.maximumPieces(
            originalRunes: text.count,
            maxRunes: maxRunes
        )
        var request = CaptionSplitRequest(
            text: text,
            maxRunes: maxRunes,
            minRunes: CaptionProposalBuilder.minimumPieceRunes(maxRunes: maxRunes),
            maxPieces: maxPieces,
            terms: terms,
            languageHint: languageHint
        )

        var lastVerdict = CaptionEditVerdict.ok
        for _ in 0..<2 {
            try Task.checkCancellation()

            let plan = try await engine.planSplit(request)
            let pieces = plan.pieces
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard pieces.count >= 2 else {
                return CaptionSplitPlan(pieces: [text], reason: plan.reason)
            }

            let verdict = CaptionProposalBuilder.splitVerdict(
                pieces: pieces,
                original: text,
                maxRunes: maxRunes
            )
            if verdict == .ok {
                return CaptionSplitPlan(pieces: pieces, reason: plan.reason)
            }

            lastVerdict = verdict
            request.retryNote = retryNote(for: verdict, maxPieces: maxPieces)
        }
        throw RejectedPlan(verdict: lastVerdict)
    }

    /// What to tell the model about its rejected answer. Model-facing English,
    /// deliberately concrete — "too many markers" gets a better second attempt
    /// than a restatement of the rules it just ignored.
    private static func retryNote(for verdict: CaptionEditVerdict, maxPieces: Int) -> String {
        switch verdict {
        case .overSplit:
            let markers = maxPieces - 1
            return "you inserted far too many markers. This line takes at most "
                + "\(markers), and one is almost certainly right. Do not put a | "
                + "between every word."
        case .stubPiece:
            return "one part was far too short to stand on its own as a subtitle "
                + "line. Move the marker, or leave the line unbroken."
        case .wordsChanged:
            return "you changed the wording. Copy the line through word for word "
                + "and only insert markers."
        default:
            return "it could not be applied. Keep it simple: one marker, at a "
                + "clause boundary."
        }
    }

    // MARK: - Cue surgery

    /// Splits a cue into the given pieces, carrying word timings across.
    ///
    /// Returns nil when the pieces don't line up with the cue's words, which the
    /// caller treats as "fall back to the character split".
    static func split(_ cue: CaptionCue, into pieces: [String]) -> [CaptionCue]? {
        guard pieces.count >= 2 else { return nil }

        if cue.words.count >= 2 {
            guard let boundaries = CaptionEditApplier.wordBoundaries(
                for: pieces,
                in: cue.words
            ) else { return nil }

            var out: [CaptionCue] = []
            var start = 0
            for (index, piece) in pieces.enumerated() {
                let end = index < boundaries.count ? boundaries[index] : cue.words.count
                guard end > start else { return nil }
                let slice = Array(cue.words[start..<end])
                guard let first = slice.first, let last = slice.last else { return nil }

                var part = cue
                part.text = piece
                part.words = slice
                part.startMs = first.offsetMs
                // The last piece keeps the cue's own end so the span is never
                // shortened by a word whose duration undershoots.
                part.endMs = index == pieces.count - 1
                    ? max(cue.endMs, last.endMs)
                    : max(last.endMs, first.offsetMs + 1)
                out.append(part)
                start = end
            }
            return out
        }

        // No word timings: distribute the span by readable-content weight, the
        // same rule `CaptionCueBuilder.cuesFromText` uses.
        let spans = CaptionText.distribute(
            weights: pieces.map { max(CaptionText.wordRuneCount($0), 1) },
            fromMs: cue.startMs,
            toMs: cue.endMs
        )
        guard spans.count == pieces.count else { return nil }

        return zip(pieces, spans).map { piece, span in
            var part = cue
            part.text = piece
            part.words = []
            part.startMs = span.startMs
            part.endMs = max(span.endMs, span.startMs + 1)
            part.isEstimatedTiming = true
            return part
        }
    }

    /// The pre-AI behaviour, used whenever the model can't be trusted for a cue.
    ///
    /// Mirrors `CaptionCueBuilder.cuesFromWords`' length rule so falling back
    /// produces the same captions the character-limit mode would have.
    static func characterSplit(_ cue: CaptionCue, maxRunes: Int) -> [CaptionCue] {
        guard maxRunes > 0, cue.text.count > maxRunes else { return [cue] }

        if cue.words.count >= 2 {
            var pieces: [String] = []
            var current = ""
            var runes = 0

            for word in cue.words {
                CaptionText.appendWord(word.text, to: &current)
                runes += word.text.count
                if runes >= maxRunes {
                    pieces.append(current)
                    current = ""
                    runes = 0
                }
            }
            if !current.isEmpty { pieces.append(current) }
            guard pieces.count >= 2, let split = split(cue, into: pieces) else { return [cue] }
            return split
        }

        let pieces = CaptionText.splitAtBoundaries(cue.text, maxRunes: maxRunes)
        guard pieces.count >= 2, let split = split(cue, into: pieces) else { return [cue] }
        return split
    }

    // MARK: - Manual entry point

    /// Reviews an existing transcript and proposes splits for its long captions.
    static func proposal(
        for transcript: CaptionTranscriptSnapshot,
        maxRunes: Int,
        terms: [CaptionTerm],
        languageHint: String,
        engine: any CaptionAIEngine,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> CaptionEditProposal {
        // An agent engine reads the transcript itself and answers in one turn;
        // calling it once per caption would mean one process launch per caption.
        if let batch = engine as? any CaptionBatchAIEngine {
            return try await batch.proposeSplits(
                transcript: transcript,
                maxRunes: maxRunes,
                terms: terms,
                languageHint: languageHint
            )
        }

        let candidates = transcript.segments.filter { $0.text.count > maxRunes }
        guard !candidates.isEmpty else {
            return CaptionEditProposal(
                summary: "Every caption is already short enough.",
                engine: engine.modelLabel
            )
        }

        var operations: [CaptionEditOperation] = []
        var reasons: [UUID: String] = [:]
        var failures = 0

        for (index, segment) in candidates.enumerated() {
            try Task.checkCancellation()

            do {
                let plan = try await validatedPlan(
                    text: segment.text,
                    maxRunes: maxRunes,
                    terms: terms,
                    languageHint: languageHint,
                    engine: engine
                )
                if plan.pieces.count >= 2 {
                    operations.append(.split(segment: segment.id, pieces: plan.pieces))
                    if !plan.reason.isEmpty { reasons[segment.id] = plan.reason }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One caption failing shouldn't lose the other 40 results.
                failures += 1
            }

            onProgress?(index + 1, candidates.count)
        }

        var proposal = CaptionProposalBuilder.build(
            operations: operations,
            transcript: transcript,
            terms: terms,
            policy: .preserveWords,
            maxRunes: maxRunes,
            summary: summary(checked: candidates.count, failures: failures),
            engine: engine.modelLabel,
            reasons: reasons
        )
        if proposal.items.isEmpty {
            proposal.summary = "Checked \(candidates.count) long caption"
                + (candidates.count == 1 ? "" : "s")
                + " — none needed a better break point."
        }
        return proposal
    }

    private static func summary(checked: Int, failures: Int) -> String {
        var text = "Checked \(checked) long caption\(checked == 1 ? "" : "s")."
        if failures > 0 {
            text += " \(failures) couldn't be reviewed."
        }
        return text
    }
}
