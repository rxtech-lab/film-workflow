import Foundation

/// A reference token with a time range assigned to it.
nonisolated struct CaptionTimedToken: Sendable {
    var token: CaptionToken
    var startMs: Int
    var endMs: Int
    /// True when the range was interpolated rather than measured.
    var isEstimated: Bool
    var confidence: Double = 0
}

nonisolated struct CaptionAlignmentResult: Sendable {
    var timedTokens: [CaptionTimedToken]
    /// Matched anchorable reference tokens ÷ all anchorable reference tokens.
    var matchRatio: Double
    /// Reference units containing at least one anchor.
    var anchoredUnitRatio: Double
    var quality: CaptionAlignmentQuality
}

/// Maps ASR timings onto the author's own words.
///
/// This is what makes narrative captions honest: the speech service is used
/// *only* as a clock. Its transcription hypothesis is aligned against the
/// reference script, timings are transferred to the reference tokens, and the
/// hypothesis text is then discarded — so a mis-heard word never reaches the
/// caption, but the caption still lands on the right moment.
///
/// The alignment is a banded Needleman–Wunsch over normalized tokens. Banding is
/// what makes it tractable: both sides are the *same utterance*, so the optimal
/// path never strays far from the diagonal. Unbanded, a 15k × 15k alignment is
/// 225M cells; banded at ~5% it is roughly 11M.
nonisolated struct CaptionAligner {

    /// Scoring. Chosen so a near-miss still anchors (ASR routinely returns
    /// "wanna" for "want to"), while an outright mismatch is cheaper to skip
    /// than to force.
    static let exactScore = 2
    static let nearScore = 1
    static let mismatchScore = -1
    static let gapScore = -1

    static let minBandWidth = 64
    static let bandFraction = 0.05

    /// Below this match ratio, per-token anchors aren't trustworthy.
    static let sentenceAnchoredFloor = 0.35

    @concurrent
    static func align(
        reference: [CaptionToken],
        hypothesis: [CaptionToken],
        hypothesisTimings: [CaptionWordTiming],
        audioDurationMs: Int,
        minConfidence: Double,
        onProgress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async -> CaptionAlignmentResult {
        guard !reference.isEmpty else {
            return CaptionAlignmentResult(
                timedTokens: [], matchRatio: 0, anchoredUnitRatio: 0, quality: .none
            )
        }
        // No hypothesis at all (or a provider with no word timings) → straight to
        // proportional estimation.
        guard !hypothesis.isEmpty, !hypothesisTimings.isEmpty else {
            return estimateByWeight(reference: reference, audioDurationMs: audioDurationMs)
        }

        let pairs = await traceback(
            reference: reference, hypothesis: hypothesis, onProgress: onProgress
        )

        // referenceIndex → hypothesisIndex for matched pairs only.
        var anchors: [Int: Int] = [:]
        for pair in pairs {
            let refToken = reference[pair.referenceIndex]
            let hypToken = hypothesis[pair.hypothesisIndex]
            guard refToken.isAnchorable, hypToken.isAnchorable else { continue }
            guard score(refToken, hypToken) > 0 else { continue }
            anchors[pair.referenceIndex] = pair.hypothesisIndex
        }

        let anchorableCount = reference.count { $0.isAnchorable }
        let matchRatio = anchorableCount > 0
            ? Double(anchors.count) / Double(anchorableCount)
            : 0

        let unitIndices = Set(reference.map(\.unitIndex).filter { $0 >= 0 })
        let anchoredUnits = Set(anchors.keys.map { reference[$0].unitIndex }.filter { $0 >= 0 })
        let anchoredUnitRatio = unitIndices.isEmpty
            ? 0
            : Double(anchoredUnits.count) / Double(unitIndices.count)

        guard matchRatio >= sentenceAnchoredFloor else {
            var estimated = estimateByWeight(
                reference: reference, audioDurationMs: audioDurationMs
            )
            estimated.matchRatio = matchRatio
            estimated.anchoredUnitRatio = anchoredUnitRatio
            return estimated
        }

        let timed = assignTimes(
            reference: reference,
            anchors: anchors,
            hypothesis: hypothesis,
            hypothesisTimings: hypothesisTimings,
            audioDurationMs: audioDurationMs
        )

        // Enough anchors to trust individually, or only enough to trust the
        // sentence spans they fall inside?
        let quality: CaptionAlignmentQuality =
            matchRatio >= minConfidence ? .wordAligned : .sentenceAnchored

        let finalTokens = quality == .sentenceAnchored
            ? redistributeWithinSentences(timed, audioDurationMs: audioDurationMs)
            : timed

        return CaptionAlignmentResult(
            timedTokens: finalTokens,
            matchRatio: matchRatio,
            anchoredUnitRatio: anchoredUnitRatio,
            quality: quality
        )
    }

    // MARK: - Dynamic programming

    struct Pair: Sendable {
        let referenceIndex: Int
        let hypothesisIndex: Int
    }

    /// Banded Needleman–Wunsch with a full direction matrix for traceback.
    ///
    /// Only cells inside the band are stored (one row of `2W+1` per reference
    /// token), which keeps memory linear in the band rather than quadratic in
    /// the inputs.
    @concurrent
    static func traceback(
        reference: [CaptionToken],
        hypothesis: [CaptionToken],
        onProgress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async -> [Pair] {
        let m = reference.count
        let n = hypothesis.count
        guard m > 0, n > 0 else { return [] }

        let band = bandWidth(referenceCount: m, hypothesisCount: n)
        let rowWidth = 2 * band + 1
        let slope = Double(n) / Double(m)

        // Column at the centre of row i's band.
        func centre(_ i: Int) -> Int { Int((Double(i) * slope).rounded()) }

        // Direction codes: 0 = diagonal, 1 = gap in hypothesis (consume
        // reference), 2 = gap in reference (consume hypothesis), 3 = unreachable.
        var directions = [UInt8](repeating: 3, count: (m + 1) * rowWidth)
        let negativeInfinity = Int32.min / 4

        var previous = [Int32](repeating: negativeInfinity, count: rowWidth)
        var current = [Int32](repeating: negativeInfinity, count: rowWidth)

        /// Maps an absolute column to its slot in row i's band, or nil if outside.
        func slot(row i: Int, column j: Int) -> Int? {
            let offset = j - centre(i) + band
            return (offset >= 0 && offset < rowWidth) ? offset : nil
        }

        // Row 0: only gaps in the reference.
        for offset in 0..<rowWidth {
            let j = centre(0) - band + offset
            guard j >= 0, j <= n else { continue }
            previous[offset] = Int32(j * gapScore)
            directions[offset] = j == 0 ? 3 : 2
        }

        for i in 1...m {
            for index in current.indices { current[index] = negativeInfinity }
            let rowBase = i * rowWidth

            for offset in 0..<rowWidth {
                let j = centre(i) - band + offset
                guard j >= 0, j <= n else { continue }

                var best = negativeInfinity
                var bestDirection: UInt8 = 3

                // Diagonal: consume one token from each side.
                if j >= 1, let previousSlot = slot(row: i - 1, column: j - 1),
                   previous[previousSlot] > negativeInfinity {
                    let candidate = previous[previousSlot]
                        + Int32(score(reference[i - 1], hypothesis[j - 1]))
                    if candidate > best {
                        best = candidate
                        bestDirection = 0
                    }
                }
                // Gap in the hypothesis: a reference token nobody said (or that
                // the recognizer dropped).
                if let previousSlot = slot(row: i - 1, column: j),
                   previous[previousSlot] > negativeInfinity {
                    let candidate = previous[previousSlot] + Int32(gapScore)
                    if candidate > best {
                        best = candidate
                        bestDirection = 1
                    }
                }
                // Gap in the reference: the recognizer heard something extra.
                if offset > 0, current[offset - 1] > negativeInfinity {
                    let candidate = current[offset - 1] + Int32(gapScore)
                    if candidate > best {
                        best = candidate
                        bestDirection = 2
                    }
                }

                current[offset] = best
                directions[rowBase + offset] = bestDirection
            }

            swap(&previous, &current)

            // Cancellation and progress every 512 rows: often enough to feel
            // responsive, rare enough not to dominate the inner loop.
            if i % 512 == 0 {
                if Task.isCancelled { return [] }
                if let onProgress {
                    let fraction = Double(i) / Double(m)
                    await MainActor.run { onProgress(fraction) }
                }
            }
        }

        // Walk back from (m, n) to (0, 0).
        var pairs: [Pair] = []
        var i = m
        var j = n
        while i > 0 || j > 0 {
            guard let offset = slot(row: i, column: j) else { break }
            let direction = directions[i * rowWidth + offset]
            switch direction {
            case 0:
                guard i > 0, j > 0 else { i = 0; j = 0; continue }
                pairs.append(Pair(referenceIndex: i - 1, hypothesisIndex: j - 1))
                i -= 1
                j -= 1
            case 1:
                guard i > 0 else { i = 0; continue }
                i -= 1
            case 2:
                guard j > 0 else { j = 0; continue }
                j -= 1
            default:
                // Fell outside the band — stop rather than loop forever.
                i = 0
                j = 0
            }
        }
        return pairs.reversed()
    }

    static func bandWidth(referenceCount: Int, hypothesisCount: Int) -> Int {
        let larger = max(referenceCount, hypothesisCount)
        return max(minBandWidth, Int(bandFraction * Double(larger)))
    }

    /// Token similarity.
    static func score(_ lhs: CaptionToken, _ rhs: CaptionToken) -> Int {
        guard lhs.isAnchorable, rhs.isAnchorable else {
            // Two punctuation-only tokens align happily; punctuation against a
            // real word does not.
            return lhs.isAnchorable == rhs.isAnchorable ? 0 : mismatchScore
        }
        if lhs.normalized == rhs.normalized { return exactScore }
        if isNearMatch(lhs.normalized, rhs.normalized) { return nearScore }
        return mismatchScore
    }

    /// Tolerates the differences ASR actually produces: a one-character slip in
    /// a longer word, or a truncation like "recognise" vs "recognises".
    static func isNearMatch(_ lhs: String, _ rhs: String) -> Bool {
        if lhs.isEmpty || rhs.isEmpty { return false }
        if lhs.count >= 4, rhs.count >= 4, levenshteinAtMostOne(lhs, rhs) { return true }

        let shorter = lhs.count <= rhs.count ? lhs : rhs
        let longer = lhs.count <= rhs.count ? rhs : lhs
        if shorter.count >= 3, longer.hasPrefix(shorter) { return true }
        return false
    }

    /// True when edit distance ≤ 1. Short-circuits instead of computing the full
    /// matrix, because it's called once per DP cell.
    static func levenshteinAtMostOne(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs)
        let b = Array(rhs)
        if abs(a.count - b.count) > 1 { return false }

        if a.count == b.count {
            var differences = 0
            for index in a.indices where a[index] != b[index] {
                differences += 1
                if differences > 1 { return false }
            }
            return differences == 1
        }

        // Off by one in length: the longer must contain the shorter with exactly
        // one insertion.
        let shorter = a.count < b.count ? a : b
        let longer = a.count < b.count ? b : a
        var shortIndex = 0
        var longIndex = 0
        var skipped = false
        while shortIndex < shorter.count, longIndex < longer.count {
            if shorter[shortIndex] == longer[longIndex] {
                shortIndex += 1
                longIndex += 1
            } else {
                if skipped { return false }
                skipped = true
                longIndex += 1
            }
        }
        return true
    }

    // MARK: - Time assignment

    /// Three passes: anchors take measured times, unmatched runs interpolate
    /// between them, then a sweep forces monotonicity.
    static func assignTimes(
        reference: [CaptionToken],
        anchors: [Int: Int],
        hypothesis: [CaptionToken],
        hypothesisTimings: [CaptionWordTiming],
        audioDurationMs: Int
    ) -> [CaptionTimedToken] {
        var timed: [CaptionTimedToken?] = Array(repeating: nil, count: reference.count)

        // Pass 1 — anchors.
        //
        // Several reference tokens can land on one hypothesis token (a provider
        // "word" holding two CJK glyphs, say), so group first and split that
        // token's span across them by weight.
        var byHypothesis: [Int: [Int]] = [:]
        for (referenceIndex, hypothesisIndex) in anchors {
            byHypothesis[hypothesisIndex, default: []].append(referenceIndex)
        }

        for (hypothesisIndex, referenceIndices) in byHypothesis {
            let timingIndex = hypothesis[hypothesisIndex].timingIndex
            guard hypothesisTimings.indices.contains(timingIndex) else { continue }
            let timing = hypothesisTimings[timingIndex]

            let sorted = referenceIndices.sorted()
            if sorted.count == 1 {
                timed[sorted[0]] = CaptionTimedToken(
                    token: reference[sorted[0]],
                    startMs: timing.offsetMs,
                    endMs: timing.endMs,
                    isEstimated: false,
                    confidence: timing.confidence
                )
            } else {
                let spans = CaptionText.distribute(
                    weights: sorted.map { reference[$0].runeWeight },
                    fromMs: timing.offsetMs,
                    toMs: timing.endMs
                )
                for (referenceIndex, span) in zip(sorted, spans) {
                    timed[referenceIndex] = CaptionTimedToken(
                        token: reference[referenceIndex],
                        startMs: span.startMs,
                        endMs: span.endMs,
                        // Sub-split of a real measurement: approximate, but
                        // bounded by measured edges.
                        isEstimated: true,
                        confidence: timing.confidence
                    )
                }
            }
        }

        // Pass 2 — gap runs between anchors.
        var index = 0
        while index < reference.count {
            if timed[index] != nil {
                index += 1
                continue
            }
            var run: [Int] = []
            while index < reference.count, timed[index] == nil {
                run.append(index)
                index += 1
            }

            let runStart = run.first.flatMap { first -> Int? in
                guard first > 0 else { return nil }
                return timed[first - 1]?.endMs
            } ?? 0
            let runEnd = index < reference.count ? (timed[index]?.startMs ?? audioDurationMs)
                                                : audioDurationMs

            let spans = CaptionText.distribute(
                weights: run.map { reference[$0].runeWeight },
                fromMs: runStart,
                toMs: max(runEnd, runStart)
            )
            for (referenceIndex, span) in zip(run, spans) {
                timed[referenceIndex] = CaptionTimedToken(
                    token: reference[referenceIndex],
                    startMs: span.startMs,
                    endMs: span.endMs,
                    isEstimated: true
                )
            }
        }

        // Pass 3 — monotonicity. Guarantees the result passes timing validation
        // no matter what the provider returned.
        var result = timed.compactMap { $0 }
        var cursor = 0
        for position in result.indices {
            result[position].startMs = max(result[position].startMs, cursor)
            result[position].endMs = max(result[position].endMs, result[position].startMs + 1)
            if audioDurationMs > 0 {
                result[position].endMs = min(result[position].endMs, audioDurationMs)
                result[position].startMs = min(
                    result[position].startMs, max(result[position].endMs - 1, 0)
                )
            }
            cursor = result[position].endMs
        }
        return result
    }

    /// Sentence-anchored fallback: keep each sentence's outer bounds (which the
    /// anchors do establish) but redistribute the words inside it evenly, since
    /// individual anchors aren't reliable at this match rate.
    static func redistributeWithinSentences(
        _ tokens: [CaptionTimedToken],
        audioDurationMs: Int
    ) -> [CaptionTimedToken] {
        guard !tokens.isEmpty else { return tokens }
        var result = tokens
        var sentenceStart = 0

        func flush(_ endIndex: Int) {
            guard endIndex >= sentenceStart else { return }
            let range = sentenceStart...endIndex
            let from = result[sentenceStart].startMs
            let to = max(result[endIndex].endMs, from + 1)
            let spans = CaptionText.distribute(
                weights: range.map { result[$0].token.runeWeight },
                fromMs: from,
                toMs: to
            )
            for (position, span) in zip(range, spans) {
                result[position].startMs = span.startMs
                result[position].endMs = max(span.endMs, span.startMs + 1)
                result[position].isEstimated = true
            }
        }

        for index in result.indices {
            // Break at sentence ends and at speaker changes: a caption must never
            // span two speakers.
            let isBoundary = result[index].token.isSentenceEnd
                || (index + 1 < result.count
                    && result[index + 1].token.speakerId != result[index].token.speakerId)
            if isBoundary {
                flush(index)
                sentenceStart = index + 1
            }
        }
        flush(result.count - 1)
        return result
    }

    /// Last resort: no usable anchors, so spread the reference across the audio
    /// by content weight, honouring authored pauses as fixed gaps.
    static func estimateByWeight(
        reference: [CaptionToken],
        audioDurationMs: Int
    ) -> CaptionAlignmentResult {
        guard !reference.isEmpty else {
            return CaptionAlignmentResult(
                timedTokens: [], matchRatio: 0, anchoredUnitRatio: 0, quality: .estimated
            )
        }
        let duration = max(audioDurationMs, reference.count)
        let spans = CaptionText.distribute(
            weights: reference.map(\.runeWeight),
            fromMs: 0,
            toMs: duration
        )
        let timed = zip(reference, spans).map { token, span in
            CaptionTimedToken(
                token: token,
                startMs: span.startMs,
                endMs: max(span.endMs, span.startMs + 1),
                isEstimated: true
            )
        }
        return CaptionAlignmentResult(
            timedTokens: timed, matchRatio: 0, anchoredUnitRatio: 0, quality: .estimated
        )
    }

    // MARK: - Cue construction

    /// Turns timed reference tokens into cues.
    ///
    /// Cuts at sentence ends and at every speaker change, and never at a comma —
    /// the author's own sentence structure is authoritative here, which is also
    /// why the continuation-merge pass is skipped for narrative sources.
    static func cues(
        from result: CaptionAlignmentResult,
        maxRunes: Int,
        audioDurationMs: Int
    ) -> [CaptionCue] {
        guard !result.timedTokens.isEmpty else { return [] }

        var cues: [CaptionCue] = []
        var text = ""
        var words: [CaptionWord] = []
        var startMs = -1
        var endMs = 0
        var runes = 0
        var speakerId: UUID?
        var anyEstimated = false

        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, startMs >= 0, endMs > startMs {
                cues.append(CaptionCue(
                    speaker: 0,
                    speakerId: speakerId,
                    startMs: startMs,
                    endMs: endMs,
                    text: trimmed,
                    words: words,
                    isEstimatedTiming: anyEstimated
                ))
            }
            text = ""
            words = []
            startMs = -1
            endMs = 0
            runes = 0
            anyEstimated = false
        }

        for (index, timed) in result.timedTokens.enumerated() {
            // A speaker change always closes the current cue.
            if startMs >= 0, timed.token.speakerId != speakerId {
                flush()
            }
            if startMs < 0 {
                startMs = timed.startMs
                speakerId = timed.token.speakerId
            }

            CaptionText.appendWord(timed.token.display, to: &text)
            words.append(CaptionWord(
                text: timed.token.display,
                offsetMs: timed.startMs,
                durationMs: max(timed.endMs - timed.startMs, 1),
                confidence: timed.confidence,
                isEstimated: timed.isEstimated
            ))
            runes += timed.token.display.count
            endMs = max(endMs, timed.endMs)
            anyEstimated = anyEstimated || timed.isEstimated

            let isLast = index == result.timedTokens.count - 1
            if timed.token.isSentenceEnd || runes >= maxRunes || isLast {
                flush()
            }
        }
        flush()

        return CaptionCueBuilder.clampCueOverlaps(cues)
    }
}
