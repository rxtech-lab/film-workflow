import Foundation

/// One sentence-level caption cue derived from a transcript.
///
/// Text keeps its natural punctuation; the exporter strips it at render time if
/// asked, so the editor still reads like prose.
nonisolated struct CaptionCue: Sendable, Hashable {
    var speaker: Int = 0
    var speakerId: UUID?
    var startMs: Int
    var endMs: Int
    var text: String
    var words: [CaptionWord] = []
    var isEstimatedTiming: Bool = false
    var locale: String = ""
    var confidence: Double = 0

    /// The selected translation of `text`, populated only on the export path.
    /// Empty everywhere the cue is being built from audio — a cue coming out of
    /// a recognizer has nothing to translate yet.
    var translation: String = ""

    var durationMs: Int { max(endMs - startMs, 0) }

    init(
        speaker: Int = 0,
        speakerId: UUID? = nil,
        startMs: Int,
        endMs: Int,
        text: String,
        words: [CaptionWord] = [],
        isEstimatedTiming: Bool = false,
        locale: String = "",
        confidence: Double = 0,
        translation: String = ""
    ) {
        self.translation = translation
        self.speaker = speaker
        self.speakerId = speakerId
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.words = words
        self.isEstimatedTiming = isEstimatedTiming
        self.locale = locale
        self.confidence = confidence
    }
}

/// Flattens a provider transcript into sentence-level cues.
///
/// Faithful port of `debate-bot/internal/stt/cues.go`. Phrases with word
/// timings split exactly at the word whose text ends in boundary punctuation;
/// phrases without them split textually and distribute the phrase duration
/// proportionally to content-rune weight. Cues never cross a phrase's speaker
/// boundary, and times stay monotonic.
nonisolated struct CaptionCueBuilder {

    /// Forces a split inside a run of text containing no boundary punctuation,
    /// so one cue can't grow unbounded. Generous compared with a 44-rune
    /// burn-in wrap because the exporter can re-wrap at render time.
    static let defaultMaxRunes = 80

    /// Maximum silence across which two clause-cut phrases are rejoined.
    static let defaultMergeGapMs = 1500

    /// Builds cues off the main actor. `@concurrent` matters here: a 1-hour
    /// transcript is ~20k words, and under this target's MainActor-by-default
    /// isolation a plain `nonisolated` static would run on the caller's actor
    /// and stutter the UI.
    @concurrent
    static func sentenceCues(
        from transcript: CaptionTranscript,
        maxRunes: Int = defaultMaxRunes,
        mergeGapMs: Int = defaultMergeGapMs,
        mergeContinuations: Bool = true
    ) async -> [CaptionCue] {
        var out: [CaptionCue] = []
        for phrase in transcript.phrases {
            if phrase.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               phrase.words.isEmpty {
                continue
            }
            if phrase.words.isEmpty {
                out.append(contentsOf: cuesFromText(phrase, maxRunes: maxRunes))
            } else {
                out.append(contentsOf: cuesFromWords(phrase, maxRunes: maxRunes))
            }
        }
        // Narrative alignment skips the merge pass: the author's own sentence
        // structure is already authoritative, and merging would join sentences
        // they deliberately separated.
        let merged = mergeContinuations
            ? mergeSentenceContinuations(out, gapMs: mergeGapMs)
            : out
        return clampCueOverlaps(merged)
    }

    // MARK: - Per-phrase cue construction

    /// Walks a phrase's word timeline, closing a cue whenever a word ends in
    /// sentence punctuation or the running text reaches `maxRunes`.
    static func cuesFromWords(_ phrase: CaptionPhrase, maxRunes: Int) -> [CaptionCue] {
        var out: [CaptionCue] = []
        var text = ""
        var words: [CaptionWord] = []
        var runes = 0
        var startMs = -1
        var endMs = 0

        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, startMs >= 0, endMs > startMs {
                out.append(CaptionCue(
                    speaker: phrase.speaker,
                    startMs: startMs,
                    endMs: endMs,
                    text: trimmed,
                    words: words,
                    locale: phrase.locale
                ))
            }
            text = ""
            words = []
            runes = 0
            startMs = -1
        }

        for word in phrase.words {
            let wt = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if wt.isEmpty { continue }

            if startMs < 0 { startMs = word.offsetMs }
            CaptionText.appendWord(wt, to: &text)
            words.append(CaptionWord(
                text: wt,
                offsetMs: word.offsetMs,
                durationMs: word.durationMs,
                confidence: word.confidence
            ))
            runes += wt.count
            endMs = max(endMs, word.endMs)

            if let last = wt.last, CaptionText.isCueBoundary(last) || runes >= maxRunes {
                flush()
            }
        }
        flush()
        return out
    }

    /// Splits a phrase's text at boundary punctuation (keeping the punctuation
    /// on the piece it ends) and distributes the phrase duration across pieces
    /// proportionally to content-rune weight.
    static func cuesFromText(_ phrase: CaptionPhrase, maxRunes: Int) -> [CaptionCue] {
        let pieces = CaptionText.splitAtBoundaries(phrase.text, maxRunes: maxRunes)
        guard !pieces.isEmpty else { return [] }

        let weights = pieces.map { CaptionText.wordRuneCount($0) }
        let spans = CaptionText.distribute(
            weights: weights,
            fromMs: phrase.offsetMs,
            toMs: phrase.endMs
        )

        var out: [CaptionCue] = []
        for (piece, span) in zip(pieces, spans) where span.endMs > span.startMs {
            out.append(CaptionCue(
                speaker: phrase.speaker,
                startMs: span.startMs,
                endMs: span.endMs,
                text: piece,
                // No measured word timings existed, so the span is derived.
                isEstimatedTiming: true,
                locale: phrase.locale
            ))
        }
        return out
    }

    // MARK: - Post-passes

    /// Joins provider phrases that were cut at clause punctuation. Word-timed
    /// providers pick phrase boundaries independently of sentence boundaries;
    /// leaving the clauses split recreates exactly the subtitle drift this is
    /// meant to prevent.
    static func mergeSentenceContinuations(_ cues: [CaptionCue], gapMs: Int) -> [CaptionCue] {
        var out: [CaptionCue] = []
        out.reserveCapacity(cues.count)

        for cue in cues {
            if let previous = out.last,
               previous.speaker == cue.speaker,
               cue.startMs >= previous.endMs,
               cue.startMs - previous.endMs <= gapMs,
               continuesSentence(previous.text) {
                var merged = previous
                CaptionText.appendWord(cue.text, to: &merged.text)
                merged.endMs = cue.endMs
                merged.words.append(contentsOf: cue.words)
                merged.isEstimatedTiming = merged.isEstimatedTiming || cue.isEstimatedTiming
                out[out.count - 1] = merged
                continue
            }
            out.append(cue)
        }
        return out
    }

    static func continuesSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return CaptionText.isClauseContinuation(last)
    }

    /// Trims each cue that runs past the next cue's start.
    ///
    /// Timing validation only requires monotonic phrase offsets, so a provider
    /// may report a duration that overruns the following phrase; an overlapping
    /// cue makes every containment-based caption lookup ambiguous. Must run
    /// *after* `mergeSentenceContinuations`, whose gap check needs the raw ends.
    /// A cue whose clamped range collapses merges its text forward into the
    /// successor rather than dropping words.
    static func clampCueOverlaps(_ cues: [CaptionCue]) -> [CaptionCue] {
        guard cues.count >= 2 else { return cues }

        var work = cues
        var out: [CaptionCue] = []
        out.reserveCapacity(work.count)

        for index in work.indices {
            var cue = work[index]
            if index + 1 < work.count {
                if cue.endMs > work[index + 1].startMs {
                    cue.endMs = work[index + 1].startMs
                }
                if cue.endMs <= cue.startMs {
                    // Collapsed: fold this cue's text into the next one so no
                    // words are lost, and let the next cue own the wider span.
                    var next = work[index + 1]
                    next.text = CaptionText.join(cue.text, next.text)
                    next.words = cue.words + next.words
                    if cue.startMs < next.startMs { next.startMs = cue.startMs }
                    work[index + 1] = next
                    continue
                }
            }
            out.append(cue)
        }
        return out
    }
}
