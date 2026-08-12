import Foundation
import SwiftData

/// Writes an approved proposal into the project.
///
/// The only place AI output reaches SwiftData. Everything here goes through the
/// existing editing primitives in `CaptionSegmentEditing` so the invariants they
/// maintain — words monotone, contained in their segment, pins respected — hold
/// for AI edits exactly as they do for hand edits.
@MainActor
enum CaptionEditApplier {

    /// Applies the given items and returns how many took effect.
    ///
    /// Items whose target has already been deleted or merged away by an earlier
    /// item are skipped rather than treated as failures — a proposal is a batch,
    /// and batches overlap.
    @discardableResult
    static func apply(
        _ items: [CaptionEditProposalItem],
        to project: CaptionProject,
        context: ModelContext
    ) -> Int {
        guard !items.isEmpty else { return 0 }

        var applied = 0
        for item in items {
            if perform(item.operation, on: project, context: context) { applied += 1 }
        }

        if applied > 0 {
            project.reindexSegments()
            project.updatedAt = Date()
        }
        return applied
    }

    // MARK: - Dispatch

    private static func perform(
        _ operation: CaptionEditOperation,
        on project: CaptionProject,
        context: ModelContext
    ) -> Bool {
        guard let segment = project.segments.first(where: { $0.uuid == operation.segmentID }) else {
            return false
        }

        switch operation {
        case .split(_, let pieces):
            return applySplit(pieces: pieces, to: segment, project: project, context: context)

        case .replaceText(_, let newText):
            let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != segment.text else { return false }
            setText(trimmed, on: segment)
            return true

        case .merge(_, let nextID):
            guard let next = project.segments.first(where: { $0.uuid == nextID }) else { return false }
            segment.merge(with: next)
            context.delete(next)
            return true

        case .setSpeaker(_, let speakerID):
            guard project.speakers.contains(where: { $0.id == speakerID }) else { return false }
            segment.speakerId = speakerID
            segment.isUserEdited = true
            return true

        case .delete:
            context.delete(segment)
            return true
        }
    }

    // MARK: - Split

    private static func applySplit(
        pieces rawPieces: [String],
        to segment: CaptionSegment,
        project: CaptionProject,
        context: ModelContext
    ) -> Bool {
        let pieces = rawPieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard pieces.count >= 2 else { return false }

        let produced: [CaptionSegment]
        if segment.words.count >= 2 {
            guard let split = splitAtWordBoundaries(
                pieces: pieces,
                segment: segment,
                project: project,
                context: context
            ) else {
                return false
            }
            produced = split
        } else {
            // No measured word timings to cut between, so derive the boundaries
            // the same way `CaptionCueBuilder.cuesFromText` does: proportional to
            // content-rune weight across the segment's own span.
            produced = splitByWeight(
                pieces: pieces,
                segment: segment,
                project: project,
                context: context
            )
        }

        guard produced.count == pieces.count else { return false }
        for (piece, part) in zip(pieces, produced) {
            setText(piece, on: part)
        }
        return true
    }

    /// Cuts at real word boundaries, preserving every measured timing.
    ///
    /// Boundaries are located by accumulating normalized word text until it
    /// matches the normalized text of the pieces so far. Matching on the
    /// normalized form is what lets the model add punctuation: "你好，世界" and
    /// "你好世界" produce the same key.
    private static func splitAtWordBoundaries(
        pieces: [String],
        segment: CaptionSegment,
        project: CaptionProject,
        context: ModelContext
    ) -> [CaptionSegment]? {
        let words = segment.orderedWords
        guard let boundaries = wordBoundaries(for: pieces, in: words) else { return nil }

        var parts: [CaptionSegment] = [segment]
        var head = segment
        var consumed = 0

        for boundary in boundaries {
            let localIndex = boundary - consumed
            guard let trailing = head.makeSplit(atWordIndex: localIndex) else { return nil }
            trailing.project = project
            context.insert(trailing)
            parts.append(trailing)
            head = trailing
            consumed = boundary
        }
        return parts
    }

    /// Word index at which each piece after the first begins, or nil when the
    /// pieces don't line up with the words at all.
    ///
    /// `nonisolated` because it is pure — it touches no model — which keeps it
    /// testable without hopping to the main actor.
    nonisolated static func wordBoundaries(for pieces: [String], in words: [CaptionWord]) -> [Int]? {
        guard pieces.count >= 2, !words.isEmpty else { return nil }

        // Cumulative normalized text of the pieces, minus the last one — the tail
        // needs no boundary.
        var targets: [String] = []
        var running = ""
        for piece in pieces.dropLast() {
            running += CaptionTermMatching.tokens(piece).joined()
            targets.append(running)
        }

        var boundaries: [Int] = []
        var accumulated = ""
        var targetIndex = 0

        for (index, word) in words.enumerated() {
            accumulated += CaptionTokenizer.normalize(word.text)
            while targetIndex < targets.count, accumulated == targets[targetIndex] {
                // A boundary at 0 or at the very end would produce an empty
                // segment; `makeSplit` rejects those, so bail out cleanly.
                let boundary = index + 1
                guard boundary > 0, boundary < words.count else { return nil }
                boundaries.append(boundary)
                targetIndex += 1
            }
            if targetIndex < targets.count, accumulated.count > targets[targetIndex].count {
                return nil
            }
        }

        return boundaries.count == targets.count ? boundaries : nil
    }

    /// Fallback for segments with no usable word timings: new rows whose spans
    /// are proportional to how much readable text each piece carries.
    private static func splitByWeight(
        pieces: [String],
        segment: CaptionSegment,
        project: CaptionProject,
        context: ModelContext
    ) -> [CaptionSegment] {
        let spans = CaptionText.distribute(
            weights: pieces.map { max(CaptionText.wordRuneCount($0), 1) },
            fromMs: segment.startMs,
            toMs: segment.endMs
        )
        guard spans.count == pieces.count else { return [] }

        // The head keeps its identity so anything referring to it stays valid.
        let originalEnd = segment.endMs
        segment.endMs = max(spans[0].endMs, segment.startMs + 1)
        segment.words = []
        segment.isEstimatedTiming = true
        segment.isUserEdited = true

        var parts: [CaptionSegment] = [segment]
        for index in 1..<pieces.count {
            let span = spans[index]
            let isLast = index == pieces.count - 1
            let part = CaptionSegment(
                orderIndex: segment.orderIndex + index,
                startMs: span.startMs,
                endMs: max(isLast ? originalEnd : span.endMs, span.startMs + 1),
                text: pieces[index],
                speakerId: segment.speakerId,
                providerSpeakerNumber: segment.providerSpeakerNumber,
                locale: segment.locale,
                confidence: segment.confidence,
                isEstimatedTiming: true,
                words: []
            )
            part.isUserEdited = true
            part.project = project
            context.insert(part)
            parts.append(part)
        }
        return parts
    }

    // MARK: - Text

    /// Sets a segment's text, re-deriving word timings only when the words
    /// themselves changed.
    ///
    /// When the model only repunctuated, the existing word array is still
    /// correct and measured — re-tokenizing would replace real timings with
    /// interpolated ones for no gain.
    private static func setText(_ newText: String, on segment: CaptionSegment) {
        let oldWords = segment.orderedWords
        let wordsChanged = CaptionTermMatching.tokens(newText)
            != CaptionTermMatching.tokens(oldWords.map(\.text).joined(separator: " "))

        segment.text = newText
        segment.isUserEdited = true

        if wordsChanged, !oldWords.isEmpty {
            segment.retokenizeWords(preservingTimingsFrom: oldWords)
        }
    }
}
