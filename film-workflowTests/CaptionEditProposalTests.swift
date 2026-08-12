import Foundation
import Testing

@testable import film_workflow

/// The validator is the only thing standing between a hallucinating model and a
/// corrupted transcript, so these lock in exactly what it will and won't accept.
@Suite("Caption edit proposals")
struct CaptionEditProposalTests {

    // MARK: - Helpers

    private func words(_ items: [(String, Int, Int)]) -> [CaptionWord] {
        items.map { CaptionWord(text: $0.0, offsetMs: $0.1, durationMs: $0.2) }
    }

    private func segment(
        id: UUID = UUID(),
        startMs: Int = 0,
        endMs: Int = 4_000,
        text: String,
        words: [CaptionWord] = []
    ) -> CaptionSegmentSnapshot {
        CaptionSegmentSnapshot(
            id: id,
            startMs: startMs,
            endMs: endMs,
            text: text,
            words: words
        )
    }

    private func transcript(_ segments: [CaptionSegmentSnapshot]) -> CaptionTranscriptSnapshot {
        CaptionTranscriptSnapshot(
            projectName: "Test",
            audioDurationMs: 60_000,
            speakers: [],
            segments: segments
        )
    }

    // MARK: - Split validation

    @Test("Repunctuating a split is accepted")
    func splitMayAddPunctuation() {
        let verdict = CaptionProposalBuilder.splitVerdict(
            pieces: ["We shipped the release on Friday.", "Everyone went home happy."],
            original: "we shipped the release on friday everyone went home happy",
            maxRunes: 40
        )
        #expect(verdict == .ok)
    }

    @Test("Changing a word is rejected")
    func splitMayNotChangeWords() {
        let verdict = CaptionProposalBuilder.splitVerdict(
            pieces: ["We shipped the release on Thursday.", "Everyone went home happy."],
            original: "we shipped the release on friday everyone went home happy",
            maxRunes: 40
        )
        #expect(verdict == .wordsChanged)
    }

    @Test("Dropping a word is rejected")
    func splitMayNotDropWords() {
        let verdict = CaptionProposalBuilder.splitVerdict(
            pieces: ["We shipped the release.", "Everyone went home."],
            original: "we shipped the release on friday everyone went home happy",
            maxRunes: 40
        )
        #expect(verdict == .wordsChanged)
    }

    @Test("A stub second line is flagged, not silently accepted")
    func splitFlagsStubPiece() {
        let verdict = CaptionProposalBuilder.splitVerdict(
            pieces: ["We shipped the release on Friday and everyone went home", "happy"],
            original: "we shipped the release on friday and everyone went home happy",
            maxRunes: 60
        )
        #expect(verdict == .stubPiece)
    }

    @Test("CJK splits validate on normalized glyphs")
    func splitHandlesCJK() {
        let verdict = CaptionProposalBuilder.splitVerdict(
            pieces: ["今天天气很好，", "我们出去走走吧。"],
            original: "今天天气很好我们出去走走吧",
            maxRunes: 24
        )
        // Six glyphs is under the absolute floor but is a balanced half of this
        // caption, so it must not be flagged as a stub.
        #expect(verdict == .ok)
    }

    @Test("A short piece beside a long one is still a stub in CJK")
    func cjkStubIsStillFlagged() {
        let verdict = CaptionProposalBuilder.splitVerdict(
            pieces: ["今天天气很好我们出去外面走一走看看风景吧", "好"],
            original: "今天天气很好我们出去外面走一走看看风景吧好",
            maxRunes: 24
        )
        #expect(verdict == .stubPiece)
    }

    @Test("Shredding a line into one piece per word is rejected")
    func splitRejectsUniformShredding() {
        // The regression this guards: every piece is short, so no single piece
        // stands out as the stub — only the *count* gives it away.
        let sentence = "social network that does not belong one company because"
        let verdict = CaptionProposalBuilder.splitVerdict(
            pieces: sentence.split(separator: " ").map(String.init),
            original: sentence,
            maxRunes: 80
        )
        #expect(verdict == .overSplit)
    }

    @Test("Shredding is caught even when every word is long")
    func splitRejectsShreddingOfLongWords() {
        let sentence = "advertising algorithms determine everything meaningful"
        let verdict = CaptionProposalBuilder.splitVerdict(
            pieces: sentence.split(separator: " ").map(String.init),
            original: sentence,
            maxRunes: 80
        )
        #expect(verdict == .overSplit)
    }

    @Test("A line long enough to need three pieces may have three")
    func splitAllowsPiecesTheLengthRequires() {
        // 40 words, 199 characters. At a 60-character limit that genuinely needs
        // four pieces, so three must be accepted.
        let words = Array(repeating: "word", count: 40)
        let long = words.joined(separator: " ")
        let pieces = stride(from: 0, to: 40, by: 14).map { start in
            words[start..<min(start + 14, 40)].joined(separator: " ")
        }

        #expect(pieces.count == 3)
        #expect(
            CaptionProposalBuilder.splitVerdict(
                pieces: pieces, original: long, maxRunes: 60
            ) == .ok
        )
    }

    @Test("The piece budget follows from the line's length")
    func maximumPiecesFollowsLength() {
        // A line just over the limit needs two pieces; allow one of slack.
        #expect(CaptionProposalBuilder.maximumPieces(originalRunes: 100, maxRunes: 80) == 3)
        // Four times the limit legitimately needs four.
        #expect(CaptionProposalBuilder.maximumPieces(originalRunes: 320, maxRunes: 80) == 5)
        // Never below two, or a split could never be proposed at all.
        #expect(CaptionProposalBuilder.maximumPieces(originalRunes: 10, maxRunes: 80) == 2)
    }

    @Test("The minimum piece length scales with the cue limit")
    func minimumPieceScales() {
        #expect(CaptionProposalBuilder.minimumPieceRunes(maxRunes: 80) == 28)
        // Never drops below the floor, even at the smallest allowed limit.
        #expect(CaptionProposalBuilder.minimumPieceRunes(maxRunes: 20) == 8)
    }

    // MARK: - Text validation

    @Test("A glossary correction is accepted")
    func glossaryCorrectionAccepted() {
        let terms = [CaptionTerm(text: "RxLab", variants: ["RX lab"])]
        let verdict = CaptionProposalBuilder.textVerdict(
            newText: "Welcome to RxLab today.",
            original: "Welcome to RX lab today.",
            terms: terms,
            policy: .glossaryOnly
        )
        #expect(verdict == .ok)
    }

    @Test("A glossary pass may not rewrite prose")
    func glossaryPassRejectsProseEdits() {
        let terms = [CaptionTerm(text: "RxLab", variants: ["RX lab"])]
        let verdict = CaptionProposalBuilder.textVerdict(
            newText: "Welcome to RxLab this morning.",
            original: "Welcome to RX lab today.",
            terms: terms,
            policy: .glossaryOnly
        )
        // "today" disappeared and "morning" appeared; neither is a glossary word.
        guard case .editedNonTerm = verdict else {
            Issue.record("expected editedNonTerm, got \(verdict)")
            return
        }
    }

    @Test("Conversational edits are not content-checked")
    func freePolicyAllowsAnything() {
        let verdict = CaptionProposalBuilder.textVerdict(
            newText: "Something else entirely.",
            original: "Welcome to RX lab today.",
            terms: [],
            policy: .free
        )
        #expect(verdict == .ok)
    }

    // MARK: - Proposal assembly

    @Test("A one-piece split is dropped rather than shown as a change")
    func singlePieceSplitProducesNoItem() {
        let id = UUID()
        let proposal = CaptionProposalBuilder.build(
            operations: [.split(segment: id, pieces: ["Leave this alone."])],
            transcript: transcript([segment(id: id, text: "Leave this alone.")]),
            terms: [],
            policy: .preserveWords,
            maxRunes: 80
        )
        #expect(proposal.isEmpty)
    }

    @Test("An unknown caption id surfaces instead of disappearing")
    func unknownSegmentIsReported() {
        let proposal = CaptionProposalBuilder.build(
            operations: [.replaceText(segment: UUID(), newText: "hi")],
            transcript: transcript([segment(text: "Hello there.")]),
            terms: [],
            policy: .free,
            maxRunes: 80
        )
        #expect(proposal.items.count == 1)
        #expect(!proposal.items[0].verdict.isOK)
        #expect(proposal.okCount == 0)
    }

    @Test("Only adjacent captions can be merged")
    func mergeRequiresAdjacency() {
        let first = UUID()
        let third = UUID()
        let proposal = CaptionProposalBuilder.build(
            operations: [.merge(segment: first, withNext: third)],
            transcript: transcript([
                segment(id: first, startMs: 0, endMs: 1_000, text: "One."),
                segment(startMs: 1_000, endMs: 2_000, text: "Two."),
                segment(id: third, startMs: 2_000, endMs: 3_000, text: "Three."),
            ]),
            terms: [],
            policy: .free,
            maxRunes: 80
        )
        #expect(proposal.items.count == 1)
        #expect(!proposal.items[0].verdict.isOK)
    }

    @Test("Display index and timestamp come from the transcript, not the model")
    func itemsCarryEditorCoordinates() {
        let target = UUID()
        let proposal = CaptionProposalBuilder.build(
            operations: [.replaceText(segment: target, newText: "Second, revised.")],
            transcript: transcript([
                segment(startMs: 0, endMs: 1_000, text: "First."),
                segment(id: target, startMs: 1_000, endMs: 2_000, text: "Second."),
            ]),
            terms: [],
            policy: .free,
            maxRunes: 80
        )
        #expect(proposal.items.count == 1)
        #expect(proposal.items[0].displayIndex == 2)
        #expect(proposal.items[0].startMs == 1_000)
        #expect(proposal.items[0].before == "Second.")
    }

    // MARK: - Word boundary mapping

    @Test("Split boundaries land on real word indices")
    func wordBoundariesMapToWordIndices() {
        let timings = words([
            ("we", 0, 200), ("shipped", 200, 300), ("the", 500, 100),
            ("release", 600, 400), ("everyone", 1_000, 400), ("went", 1_400, 200),
        ])
        let boundaries = CaptionEditApplier.wordBoundaries(
            for: ["We shipped the release.", "Everyone went."],
            in: timings
        )
        #expect(boundaries == [4])
    }

    @Test("Boundary mapping tolerates added punctuation on CJK")
    func wordBoundariesHandleCJKPunctuation() {
        let timings = words([
            ("今", 0, 100), ("天", 100, 100), ("很", 200, 100),
            ("好", 300, 100), ("我", 400, 100), ("们", 500, 100),
        ])
        let boundaries = CaptionEditApplier.wordBoundaries(
            for: ["今天很好，", "我们"],
            in: timings
        )
        #expect(boundaries == [4])
    }

    @Test("Pieces that don't line up with the words map to nothing")
    func wordBoundariesRejectMismatch() {
        let timings = words([("hello", 0, 200), ("world", 200, 200)])
        #expect(CaptionEditApplier.wordBoundaries(for: ["hel", "lo world"], in: timings) == nil)
    }

    @Test("A boundary at the very end is refused")
    func wordBoundariesRejectTerminalSplit() {
        let timings = words([("hello", 0, 200), ("world", 200, 200)])
        // Everything in the first piece would leave an empty second segment.
        #expect(CaptionEditApplier.wordBoundaries(for: ["hello world", ""], in: timings) == nil)
    }

    // MARK: - Round-trip

    @Test("A proposal survives JSON encoding")
    func proposalRoundTrips() throws {
        let id = UUID()
        let original = CaptionEditProposal(
            summary: "Two fixes",
            engine: "Apple Intelligence",
            items: [
                CaptionEditProposalItem(
                    operation: .split(segment: id, pieces: ["A.", "B."]),
                    displayIndex: 1,
                    startMs: 0,
                    before: "A B",
                    after: "A. / B."
                )
            ]
        )
        let json = try #require(original.encodedJSON())
        let decoded = try #require(CaptionEditProposal.decode(fromJSON: json))
        #expect(decoded == original)
        #expect(decoded.engine == "Apple Intelligence")
    }

    @Test("A proposal saved before the engine was recorded still opens")
    func proposalDecodesWithoutEngine() throws {
        // Exactly what an assistant message persisted by an earlier build holds.
        let legacy = #"{"id":"\#(UUID().uuidString)","summary":"One fix","items":[]}"#
        let decoded = try #require(CaptionEditProposal.decode(fromJSON: legacy))
        #expect(decoded.summary == "One fix")
        #expect(decoded.engine.isEmpty)
    }
}
