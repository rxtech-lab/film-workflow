import Foundation

/// Editing operations that keep word timings consistent with their segment.
///
/// The invariant everything here maintains: the segment's `[startMs, endMs]` is
/// authoritative, and words are always monotone and contained within it. A word
/// the user has hand-adjusted (`isPinned`) is an immovable anchor — bulk
/// operations rescale around it rather than through it.
extension CaptionSegment {

    /// Moves the segment and carries its words along by affine rescale.
    ///
    /// Pinned words keep their absolute times (clamped into the new range) and
    /// act as anchors; unpinned runs between anchors are redistributed inside
    /// their sub-interval. Returns how many word timings changed, for the
    /// editor's confirmation text.
    ///
    /// `isHandSet` is what clears `isEstimatedTiming`: a boundary the user chose
    /// against the waveform is a real time, and leaving the caption flagged as
    /// estimated afterwards meant the editor's "timings are estimated" banner
    /// could never be satisfied. Bulk nudges like `removeGaps` pass false —
    /// closing a 200 ms gap doesn't make a guessed span measured.
    @discardableResult
    func retime(toStartMs newStart: Int, endMs newEnd: Int, isHandSet: Bool = true) -> Int {
        guard newEnd > newStart else { return 0 }

        let oldStart = startMs
        let oldDuration = max(endMs - startMs, 0)
        startMs = newStart
        endMs = newEnd
        isUserEdited = true
        if isHandSet { isEstimatedTiming = false }

        guard !words.isEmpty else { return 0 }

        // Degenerate original span: nothing to scale from, so distribute evenly.
        guard oldDuration > 0 else {
            distributeWordsEvenly()
            return words.count
        }

        let scale = Double(newEnd - newStart) / Double(oldDuration)
        var changed = 0
        var rescaled = words

        for index in rescaled.indices {
            if rescaled[index].isPinned {
                // Keep the hand-set time, only forcing it inside the new range.
                let clampedStart = min(max(rescaled[index].offsetMs, newStart), newEnd)
                let clampedEnd = min(max(rescaled[index].endMs, clampedStart + 1), newEnd)
                if rescaled[index].offsetMs != clampedStart
                    || rescaled[index].durationMs != clampedEnd - clampedStart {
                    rescaled[index].offsetMs = clampedStart
                    rescaled[index].durationMs = clampedEnd - clampedStart
                    changed += 1
                }
                continue
            }

            let offsetFromStart = Double(rescaled[index].offsetMs - oldStart) * scale
            let scaledDuration = Double(rescaled[index].durationMs) * scale
            let newOffset = newStart + Int(offsetFromStart.rounded())
            let newDuration = max(Int(scaledDuration.rounded()), 1)

            if rescaled[index].offsetMs != newOffset || rescaled[index].durationMs != newDuration {
                changed += 1
            }
            rescaled[index].offsetMs = newOffset
            rescaled[index].durationMs = newDuration
        }

        words = rescaled
        normalizeWords()
        return changed
    }

    /// Re-tokenizes after a text edit, preserving the timings of words that
    /// survived.
    ///
    /// Reuses the alignment machinery rather than inventing a second diff: the
    /// old and new word lists are exactly a reference/hypothesis pair. Words
    /// that match keep their measured times; new words interpolate between the
    /// surviving anchors around them.
    func retokenizeWords(preservingTimingsFrom oldWords: [CaptionWord]) {
        // Tokenize the way the aligner does rather than splitting on whitespace:
        // Chinese and Japanese have no inter-word spaces, so a whitespace split
        // collapsed a whole CJK caption into one "word" and threw away every
        // per-glyph timing. For Latin text the two agree exactly.
        let pieces = CaptionTokenizer.tokenize(text).map(\.display)

        guard !pieces.isEmpty else {
            words = []
            return
        }
        guard !oldWords.isEmpty else {
            words = evenlyDistributed(pieces)
            return
        }

        // Match new tokens against old ones by normalized form, in order, so a
        // repeated word can't steal an earlier occurrence's timing.
        var remaining = Array(oldWords.enumerated())
        var matched: [Int: CaptionWord] = [:]

        for (newIndex, piece) in pieces.enumerated() {
            let key = CaptionTokenizer.normalize(piece)
            guard !key.isEmpty else { continue }
            if let position = remaining.firstIndex(where: {
                CaptionTokenizer.normalize($0.element.text) == key
            }) {
                var carried = remaining[position].element
                carried.text = piece
                matched[newIndex] = carried
                // Consume everything up to and including the match to keep the
                // mapping monotone.
                remaining.removeSubrange(0...position)
            }
        }

        guard !matched.isEmpty else {
            words = evenlyDistributed(pieces)
            return
        }

        // Fill the gaps between matched anchors proportionally.
        var rebuilt: [CaptionWord] = []
        var index = 0
        while index < pieces.count {
            if let anchor = matched[index] {
                rebuilt.append(anchor)
                index += 1
                continue
            }
            // Collect the unmatched run and interpolate across it.
            var run: [Int] = []
            while index < pieces.count, matched[index] == nil {
                run.append(index)
                index += 1
            }
            let runStart = rebuilt.last?.endMs ?? startMs
            let runEnd = matched[index]?.offsetMs ?? endMs
            let spans = CaptionText.distribute(
                weights: run.map { max(CaptionText.wordRuneCount(pieces[$0]), 1) },
                fromMs: runStart,
                toMs: max(runEnd, runStart)
            )
            for (position, span) in zip(run, spans) {
                rebuilt.append(CaptionWord(
                    text: pieces[position],
                    offsetMs: span.startMs,
                    durationMs: max(span.endMs - span.startMs, 1),
                    isEstimated: true
                ))
            }
        }

        words = rebuilt
        normalizeWords()
        isUserEdited = true
    }

    /// Nudges one word boundary.
    ///
    /// `ripple` shifts every later unpinned word by the same delta, which is
    /// what you want when the whole tail is late; the default clamps within the
    /// neighbours, which is what you want for a single misplaced boundary.
    /// Either way the word becomes pinned, so later rescales respect it.
    func adjustWord(
        at index: Int,
        boundary: CaptionTimestampBoundary,
        toMs value: Int,
        ripple: Bool
    ) {
        guard words.indices.contains(index) else { return }

        var updated = words
        let original = updated[index]

        switch boundary {
        case .start:
            let lower = index > 0 ? updated[index - 1].endMs : startMs
            let upper = original.endMs - 1
            let clamped = min(max(value, lower), max(upper, lower))
            let delta = clamped - original.offsetMs
            updated[index].offsetMs = clamped
            updated[index].durationMs = max(original.endMs - clamped, 1)
            if ripple { shift(&updated, from: index + 1, by: delta) }

        case .end:
            let lower = original.offsetMs + 1
            let upper = index + 1 < updated.count ? updated[index + 1].offsetMs : endMs
            let clamped = min(max(value, lower), max(upper, lower))
            let delta = clamped - original.endMs
            updated[index].durationMs = max(clamped - original.offsetMs, 1)
            if ripple { shift(&updated, from: index + 1, by: delta) }
        }

        updated[index].isPinned = true
        updated[index].isEstimated = false
        words = updated
        normalizeWords()
        isUserEdited = true
    }

    /// Clears a hand adjustment and re-derives the word's timing from its
    /// neighbours.
    func resetWord(at index: Int) {
        guard words.indices.contains(index) else { return }
        var updated = words
        updated[index].isPinned = false

        let lower = index > 0 ? updated[index - 1].endMs : startMs
        let upper = index + 1 < updated.count ? updated[index + 1].offsetMs : endMs
        if upper > lower {
            updated[index].offsetMs = lower
            updated[index].durationMs = max(upper - lower, 1)
            updated[index].isEstimated = true
        }
        words = updated
        normalizeWords()
    }

    /// Spreads words evenly across the segment by content weight, dropping all
    /// pins.
    func distributeWordsEvenly() {
        guard !words.isEmpty else { return }
        let spans = CaptionText.distribute(
            weights: words.map(\.runeWeight),
            fromMs: startMs,
            toMs: endMs
        )
        var updated = words
        for (index, span) in spans.enumerated() where updated.indices.contains(index) {
            updated[index].offsetMs = span.startMs
            updated[index].durationMs = max(span.endMs - span.startMs, 1)
            updated[index].isPinned = false
            updated[index].isEstimated = true
        }
        words = updated
        isUserEdited = true
    }

    /// Pulls the first and last words onto the segment bounds.
    func snapWordsToSegmentBounds() {
        guard !words.isEmpty else { return }
        var updated = words
        updated[0].offsetMs = startMs
        let lastIndex = updated.count - 1
        updated[lastIndex].durationMs = max(endMs - updated[lastIndex].offsetMs, 1)
        words = updated
        normalizeWords()
        isUserEdited = true
    }

    /// Forces words monotone and inside the segment. Runs after every mutation
    /// so no other method has to think about it.
    func normalizeWords() {
        guard !words.isEmpty else { return }
        var updated = words.sorted { $0.offsetMs < $1.offsetMs }
        var cursor = startMs

        for index in updated.indices {
            updated[index].offsetMs = min(max(updated[index].offsetMs, cursor), max(endMs - 1, cursor))
            let maxDuration = max(endMs - updated[index].offsetMs, 1)
            updated[index].durationMs = min(max(updated[index].durationMs, 1), maxDuration)
            cursor = updated[index].endMs
        }
        words = updated
    }

    // MARK: - Split / merge

    /// Splits at a word boundary, returning the trailing half.
    ///
    /// The caller inserts the returned segment into the context — this type
    /// can't reach the `ModelContext`.
    ///
    /// Translations stay with the head and are *not* copied to the tail: half a
    /// source sentence paired with a whole translation would be wrong either
    /// way, and the head's text just changed, so `isTranslationStale` flags it
    /// automatically. Visibly stale beats silently discarded.
    func makeSplit(atWordIndex index: Int) -> CaptionSegment? {
        guard words.indices.contains(index), index > 0 else { return nil }
        let boundary = words[index].offsetMs
        guard boundary > startMs, boundary < endMs else { return nil }

        let head = Array(words[..<index])
        let tail = Array(words[index...])

        let trailing = CaptionSegment(
            orderIndex: orderIndex + 1,
            startMs: boundary,
            endMs: endMs,
            text: tail.map(\.text).reduce(into: "") { CaptionText.appendWord($1, to: &$0) },
            speakerId: speakerId,
            providerSpeakerNumber: providerSpeakerNumber,
            locale: locale,
            confidence: confidence,
            isEstimatedTiming: isEstimatedTiming,
            words: tail
        )
        trailing.isUserEdited = true
        trailing.versionID = versionID

        endMs = boundary
        words = head
        text = head.map(\.text).reduce(into: "") { CaptionText.appendWord($1, to: &$0) }
        isUserEdited = true

        return trailing
    }

    /// Absorbs the following segment. The caller deletes `other` afterwards.
    func merge(with other: CaptionSegment) {
        text = CaptionText.join(text, other.text)
        endMs = max(endMs, other.endMs)
        words = words + other.words
        isEstimatedTiming = isEstimatedTiming || other.isEstimatedTiming
        mergeTranslations(with: other)
        isUserEdited = true
        normalizeWords()
    }

    /// Joins same-language translations with the same joiner used for `text`, so
    /// a merged caption reads as one sentence in every language it has.
    ///
    /// A language present on only one side carries through unjoined; the
    /// fingerprint then flags it stale, which is the honest signal — the merged
    /// original no longer matches what was translated.
    private func mergeTranslations(with other: CaptionSegment) {
        guard !translations.isEmpty || !other.translations.isEmpty else { return }

        var merged = translations
        for incoming in other.translations {
            guard let index = merged.firstIndex(where: { $0.languageCode == incoming.languageCode })
            else {
                merged.append(incoming)
                continue
            }
            merged[index].text = CaptionText.join(merged[index].text, incoming.text)
            merged[index].updatedAt = Date()
            merged[index].isUserEdited = merged[index].isUserEdited || incoming.isUserEdited
        }
        translations = merged
    }

    // MARK: - Helpers

    private func evenlyDistributed(_ pieces: [String]) -> [CaptionWord] {
        let spans = CaptionText.distribute(
            weights: pieces.map { max(CaptionText.wordRuneCount($0), 1) },
            fromMs: startMs,
            toMs: endMs
        )
        return zip(pieces, spans).map { piece, span in
            CaptionWord(
                text: piece,
                offsetMs: span.startMs,
                durationMs: max(span.endMs - span.startMs, 1),
                isEstimated: true
            )
        }
    }

    private func shift(_ list: inout [CaptionWord], from index: Int, by delta: Int) {
        guard delta != 0, index < list.count else { return }
        for position in index..<list.count where !list[position].isPinned {
            list[position].offsetMs += delta
        }
    }
}

// MARK: - Project-level operations

extension CaptionProject {
    /// Closes gaps shorter than `thresholdMs` by pulling each caption's start
    /// back to the previous caption's end.
    ///
    /// End times never move — that's what makes this safe to run over a whole
    /// transcript. Ported from debate-bot's `removeGaps(shorterThan:)`.
    @discardableResult
    func removeGaps(shorterThan thresholdMs: Int) -> Int {
        let ordered = orderedSegments
        guard ordered.count > 1 else { return 0 }

        var changed = 0
        for index in 1..<ordered.count {
            let previous = ordered[index - 1]
            let current = ordered[index]
            let gap = current.startMs - previous.endMs
            guard gap > 0, gap < thresholdMs else { continue }
            current.retime(toStartMs: previous.endMs, endMs: current.endMs, isHandSet: false)
            changed += 1
        }
        if changed > 0 { updatedAt = Date() }
        return changed
    }

    /// Renumbers `orderIndex` to match timeline order, so later inserts and
    /// splits keep a stable, meaningful ordering.
    ///
    /// Also refreshes the active version's translation counts: every caller is
    /// here because the segment set changed — a split, a merge, a delete — and
    /// those counts are denormalized onto the version.
    func reindexSegments() {
        for (index, segment) in orderedSegments.enumerated() {
            segment.orderIndex = index
        }
        refreshTranslationSummary()
    }
}
