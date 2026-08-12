import Foundation
import SwiftData
import Testing

@testable import film_workflow

/// Translation storage, staleness, and the service that writes it.
///
/// `AppleTranslationRunner` has no tests: a `TranslationSession` cannot be
/// constructed outside SwiftUI. That is exactly why the runner sits behind a
/// protocol — the service is exercised here against a stub instead.
@MainActor
@Suite("Caption translation")
struct CaptionTranslationTests {

    /// Echoes `[xx] text`, so a test can tell which original produced which
    /// translation without asserting on a real model's wording.
    private struct StubRunner: CaptionTranslationRunner {
        var kind: CaptionTranslationEngineKind { .aiBackend }
        var sourceLanguage: String = "en"
        var targetLanguage: String = "zh-Hans"
        var modelLabel: String = ""
        /// Segment ids the runner refuses to answer for, standing in for a model
        /// that skips a line.
        var skipping: Set<UUID> = []

        func translate(
            _ requests: [CaptionTranslationRequest],
            onBatch: @MainActor ([CaptionTranslationResult]) -> Void,
            onProgress: @MainActor (CaptionTranslationProgress) -> Void
        ) async throws -> CaptionTranslationRun {
            onProgress(
                CaptionTranslationProgress(done: requests.count, total: requests.count)
            )
            let results = requests
                .filter { !skipping.contains($0.segmentID) }
                .map {
                    CaptionTranslationResult(
                        segmentID: $0.segmentID,
                        text: "[\(targetLanguage)] \($0.text)"
                    )
                }
            onBatch(results)
            return CaptionTranslationRun(
                results: results,
                failed: requests.count - results.count
            )
        }
    }

    /// Hands back the first `succeedingBefore` captions, then throws — a stand-in
    /// for an engine that gives out partway through a long transcript.
    private struct FailingRunner: CaptionTranslationRunner {
        var kind: CaptionTranslationEngineKind { .aiBackend }
        var sourceLanguage: String = "en"
        var targetLanguage: String = "zh-Hans"
        var succeedingBefore: Int

        struct Boom: Error {}

        func translate(
            _ requests: [CaptionTranslationRequest],
            onBatch: @MainActor ([CaptionTranslationResult]) -> Void,
            onProgress: @MainActor (CaptionTranslationProgress) -> Void
        ) async throws -> CaptionTranslationRun {
            onBatch(
                requests.prefix(succeedingBefore).map {
                    CaptionTranslationResult(
                        segmentID: $0.segmentID,
                        text: "[\(targetLanguage)] \($0.text)"
                    )
                }
            )
            throw Boom()
        }
    }

    private func makeProject(texts: [String]) throws -> (CaptionProject, ModelContext) {
        let schema = Schema([
            CaptionProject.self,
            CaptionSegment.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)

        let project = CaptionProject(name: "Test captions")
        project.languageHint = "en"
        context.insert(project)

        for (index, text) in texts.enumerated() {
            let segment = CaptionSegment(
                orderIndex: index,
                startMs: index * 1_000,
                endMs: (index + 1) * 1_000,
                text: text
            )
            segment.project = project
            context.insert(segment)
        }
        project.ensureVersioned()
        return (project, context)
    }

    // MARK: - Storage

    @Test("A caption holds several languages independently")
    func multipleLanguages() throws {
        let (project, _) = try makeProject(texts: ["Hello."])
        let segment = project.orderedSegments[0]

        segment.setTranslation("你好。", language: "zh-Hans")
        segment.setTranslation("Hola.", language: "es")
        segment.setTranslation("こんにちは。", language: "ja")

        #expect(segment.translatedLanguages.count == 3)
        #expect(segment.translatedText("es") == "Hola.")
        #expect(segment.translationMap["ja"] == "こんにちは。")

        segment.removeTranslation("es")
        #expect(segment.translation("es") == nil)
        #expect(segment.translatedLanguages.count == 2)
    }

    @Test("Setting the same language twice replaces rather than duplicates")
    func setTranslationUpserts() throws {
        let (project, _) = try makeProject(texts: ["Hello."])
        let segment = project.orderedSegments[0]

        segment.setTranslation("你好。", language: "zh-Hans")
        segment.setTranslation("您好。", language: "zh-Hans", isUserEdited: true)

        #expect(segment.translations.count == 1)
        #expect(segment.translatedText("zh-Hans") == "您好。")
        #expect(segment.translation("zh-Hans")?.isUserEdited == true)
    }

    @Test("Blank text removes the translation instead of storing an empty one")
    func blankTranslationRemoves() throws {
        let (project, _) = try makeProject(texts: ["Hello."])
        let segment = project.orderedSegments[0]

        segment.setTranslation("你好。", language: "zh-Hans")
        segment.setTranslation("   ", language: "zh-Hans")
        #expect(segment.translations.isEmpty)
    }

    // MARK: - Staleness

    @Test("Re-punctuating leaves a translation current; rewording marks it stale")
    func stalenessIgnoresPunctuation() throws {
        let (project, _) = try makeProject(texts: ["hello world"])
        let segment = project.orderedSegments[0]
        segment.setTranslation("你好世界", language: "zh-Hans")

        segment.text = "Hello, world!"
        #expect(!segment.isTranslationStale("zh-Hans"))
        #expect(!segment.needsTranslation("zh-Hans"))

        segment.text = "Goodbye, world!"
        #expect(segment.isTranslationStale("zh-Hans"))
        #expect(segment.needsTranslation("zh-Hans"))
    }

    @Test("Re-saving the translation against the new text clears staleness")
    func editingClearsStaleness() throws {
        let (project, _) = try makeProject(texts: ["Hello."])
        let segment = project.orderedSegments[0]
        segment.setTranslation("你好。", language: "zh-Hans")

        segment.text = "Goodbye."
        #expect(segment.isTranslationStale("zh-Hans"))

        segment.setTranslation("再见。", language: "zh-Hans", isUserEdited: true)
        #expect(!segment.isTranslationStale("zh-Hans"))
    }

    @Test("A translation with no recorded fingerprint is treated as current")
    func missingFingerprintIsNotStale() throws {
        let (project, _) = try makeProject(texts: ["Hello."])
        let segment = project.orderedSegments[0]
        segment.translations = [CaptionTranslation(languageCode: "zh-Hans", text: "你好。")]

        #expect(!segment.isTranslationStale("zh-Hans"))
    }

    @Test("The fingerprint is stable across calls, unlike a seeded hashValue")
    func fingerprintIsStable() {
        let first = CaptionTranslation.fingerprint(of: "Hello, world!")
        let second = CaptionTranslation.fingerprint(of: "hello world")
        #expect(first == second)
        #expect(first != CaptionTranslation.fingerprint(of: "Goodbye world"))
    }

    // MARK: - Split and merge

    @Test("Merging joins same-language translations and carries one-sided ones through")
    func mergeJoinsTranslations() throws {
        let (project, _) = try makeProject(texts: ["Hello there.", "How are you?"])
        let rows = project.orderedSegments
        rows[0].setTranslation("你好。", language: "zh-Hans")
        rows[1].setTranslation("你好吗？", language: "zh-Hans")
        rows[1].setTranslation("¿Cómo estás?", language: "es")

        rows[0].merge(with: rows[1])

        // `CaptionText.join` is script-aware, so CJK runs join without a space —
        // the same rule that joins the originals.
        #expect(rows[0].translatedText("zh-Hans") == "你好。你好吗？")
        // Present on only one side: carried through, and flagged stale because
        // the merged original no longer matches what was translated.
        #expect(rows[0].translatedText("es") == "¿Cómo estás?")
        #expect(rows[0].isTranslationStale("es"))
    }

    @Test("Splitting leaves the tail untranslated and flags the head stale")
    func splitDropsTranslationFromTail() throws {
        let (project, _) = try makeProject(texts: ["one two three four"])
        let segment = project.orderedSegments[0]
        segment.words = ["one", "two", "three", "four"].enumerated().map { index, word in
            CaptionWord(text: word, offsetMs: index * 250, durationMs: 250)
        }
        segment.setTranslation("一二三四", language: "zh-Hans")

        let trailing = try #require(segment.makeSplit(atWordIndex: 2))

        #expect(trailing.translations.isEmpty)
        #expect(trailing.versionID == segment.versionID)
        #expect(segment.translatedText("zh-Hans") == "一二三四")
        #expect(segment.isTranslationStale("zh-Hans"))
    }

    // MARK: - Service

    @Test("A run translates only what is missing or stale")
    func serviceDefaultScope() async throws {
        let (project, context) = try makeProject(texts: ["One.", "Two.", "Three."])
        let rows = project.orderedSegments
        rows[0].setTranslation("已翻译", language: "zh-Hans")

        let outcome = try await CaptionTranslationService.translate(
            project: project, runner: StubRunner(), context: context
        )

        #expect(outcome.written == 2)
        #expect(outcome.failed == 0)
        #expect(rows[0].translatedText("zh-Hans") == "已翻译")
        #expect(rows[1].translatedText("zh-Hans") == "[zh-Hans] Two.")
        #expect(rows[2].translatedText("zh-Hans") == "[zh-Hans] Three.")
    }

    @Test("Scope .all overwrites, including hand-edited translations")
    func serviceAllScope() async throws {
        let (project, context) = try makeProject(texts: ["One."])
        project.orderedSegments[0].setTranslation("我的翻译", language: "zh-Hans", isUserEdited: true)

        let outcome = try await CaptionTranslationService.translate(
            project: project, runner: StubRunner(), scope: .all, context: context
        )

        #expect(outcome.written == 1)
        #expect(project.orderedSegments[0].translatedText("zh-Hans") == "[zh-Hans] One.")
    }

    @Test("A skipped caption is left untranslated rather than guessed at")
    func serviceKeepsGapsHonest() async throws {
        let (project, context) = try makeProject(texts: ["One.", "Two."])
        let skipped = project.orderedSegments[1].uuid

        let outcome = try await CaptionTranslationService.translate(
            project: project,
            runner: StubRunner(skipping: [skipped]),
            context: context
        )

        #expect(outcome.written == 1)
        #expect(outcome.failed == 1)
        #expect(project.orderedSegments[1].translation("zh-Hans") == nil)

        let summary = try #require(project.activeVersion?.translation("zh-Hans"))
        #expect(summary.translatedCount == 1)
        #expect(summary.totalCount == 2)
    }

    @Test("A run only touches the active version")
    func serviceIsVersionScoped() async throws {
        let (project, context) = try makeProject(texts: ["One."])
        let v1Segment = project.orderedSegments[0]

        CaptionTranscriptionService.writeSegments(
            of: project,
            with: [CaptionCue(startMs: 0, endMs: 1_000, text: "Uno.")],
            context: context,
            provider: .azure
        )
        try await CaptionTranslationService.translate(
            project: project, runner: StubRunner(), context: context
        )

        #expect(project.orderedSegments[0].translatedText("zh-Hans") == "[zh-Hans] Uno.")
        #expect(v1Segment.translations.isEmpty)
    }

    @Test("The first translation becomes the displayed language")
    func firstRunSetsDisplayedLanguage() async throws {
        let (project, context) = try makeProject(texts: ["One."])
        #expect(project.displayedTranslationLanguage.isEmpty)

        try await CaptionTranslationService.translate(
            project: project, runner: StubRunner(), context: context
        )
        #expect(project.displayedTranslationLanguage == "zh-Hans")
    }

    @Test("Removing a language clears it everywhere, including the summary")
    func serviceRemovesLanguage() async throws {
        let (project, context) = try makeProject(texts: ["One.", "Two."])
        try await CaptionTranslationService.translate(
            project: project, runner: StubRunner(), context: context
        )
        try await CaptionTranslationService.translate(
            project: project,
            runner: StubRunner(targetLanguage: "es"),
            context: context
        )

        try CaptionTranslationService.removeTranslation("zh-Hans", from: project, context: context)

        #expect(project.activeSegments.allSatisfy { $0.translation("zh-Hans") == nil })
        #expect(project.translatedLanguages == ["es"])
        #expect(project.displayedTranslationLanguage.isEmpty)
        // The other language is untouched.
        #expect(project.orderedSegments[0].translatedText("es") == "[es] One.")
    }

    @Test("counts reports translated, stale and total")
    func serviceCounts() async throws {
        let (project, context) = try makeProject(texts: ["One.", "Two.", "Three."])
        try await CaptionTranslationService.translate(
            project: project, runner: StubRunner(), context: context
        )
        project.orderedSegments[2].text = "Reworded."

        let counts = CaptionTranslationService.counts(for: "zh-Hans", in: project)
        #expect(counts.translated == 3)
        #expect(counts.stale == 1)
        #expect(counts.total == 3)
    }

    @Test("A run that gives out partway keeps the captions it already translated")
    func servicePersistsPartialRun() async throws {
        let (project, context) = try makeProject(texts: ["One.", "Two.", "Three."])

        await #expect(throws: FailingRunner.Boom.self) {
            try await CaptionTranslationService.translate(
                project: project,
                runner: FailingRunner(succeedingBefore: 2),
                context: context
            )
        }

        // The work already paid for survives the throw — this is what makes
        // Cancel and a mid-run failure cost the user nothing they had.
        #expect(project.orderedSegments[0].translatedText("zh-Hans") == "[zh-Hans] One.")
        #expect(project.orderedSegments[1].translatedText("zh-Hans") == "[zh-Hans] Two.")
        #expect(project.orderedSegments[2].translation("zh-Hans") == nil)
    }

    // MARK: - Batching and retry

    /// Stands in for a model with an unknown completion cap.
    ///
    /// Anything above `manageable` lines fails the way a real one does — the
    /// mode is chosen per test, because the three failures the runner has to
    /// survive look nothing alike from the outside.
    private final class StubEngine: CaptionAIEngine, @unchecked Sendable {
        enum Failure {
            /// Says so plainly.
            case overflow
            /// Returns a valid object covering only the first few lines.
            case truncatedSilently
            /// A problem no smaller batch can fix.
            case fatal
        }

        var backend: AgentBackend { .openAICompatible }
        let manageable: Int
        let failure: Failure
        /// Batch sizes seen, in order, so a test can prove bisection happened.
        private(set) var requestedSizes: [Int] = []
        /// Line numbers this engine refuses at any batch size.
        let poisoned: Set<Int>

        init(manageable: Int, failure: Failure = .overflow, poisoned: Set<Int> = []) {
            self.manageable = manageable
            self.failure = failure
            self.poisoned = poisoned
        }

        func planSplit(_ request: CaptionSplitRequest) async throws -> CaptionSplitPlan {
            throw CaptionAIError.emptyResponse
        }

        func reviewTerms(
            _ request: CaptionTermReviewRequest
        ) async throws -> CaptionTermReviewResult {
            throw CaptionAIError.emptyResponse
        }

        func converse(_ request: CaptionChatRequest) async throws -> CaptionChatReply {
            throw CaptionAIError.emptyResponse
        }

        func translate(_ request: CaptionTranslateRequest) async throws -> CaptionTranslateResult {
            requestedSizes.append(request.lines.count)

            if request.lines.contains(where: { poisoned.contains($0.number) }) {
                throw CaptionAIError.malformedResponse("this line always fails")
            }

            guard request.lines.count > manageable else {
                return CaptionTranslateResult(
                    lines: request.lines.map {
                        CaptionTranslatedLine(number: $0.number, text: "[t] \($0.text)")
                    }
                )
            }

            switch failure {
            case .overflow:
                throw CaptionAIError.contextOverflow("too many lines")
            case .truncatedSilently:
                // Valid JSON, one line of many — the failure that used to be
                // reported as a success with the rest silently dropped.
                return CaptionTranslateResult(
                    lines: request.lines.prefix(1).map {
                        CaptionTranslatedLine(number: $0.number, text: "[t] \($0.text)")
                    }
                )
            case .fatal:
                throw CaptionAIError.backendUnavailable(.openAICompatible, "no API key")
            }
        }
    }

    private func requests(_ count: Int) -> [CaptionTranslationRequest] {
        (1...count).map {
            CaptionTranslationRequest(segmentID: UUID(), text: "Caption number \($0).")
        }
    }

    private func run(
        _ engine: StubEngine,
        _ requests: [CaptionTranslationRequest]
    ) async throws -> CaptionTranslationRun {
        try await AICaptionTranslationRunner(
            engine: engine,
            sourceLanguage: "en",
            targetLanguage: "zh-Hans",
            terms: []
        )
        .translate(requests, onBatch: { _ in }, onProgress: { _ in })
    }

    @Test("A batch too big for the model is halved until it fits")
    func oversizedBatchIsBisected() async throws {
        // Well under the 60-line batch cap, so the first attempt is one batch
        // and every later one is the runner splitting it.
        let engine = StubEngine(manageable: 5)
        let outcome = try await run(engine, requests(40))

        #expect(outcome.results.count == 40)
        #expect(outcome.failed == 0)
        #expect(engine.requestedSizes.first == 40)
        #expect(engine.requestedSizes.contains { $0 <= 5 })
    }

    @Test("A reply covering a fraction of the batch is retried, not believed")
    func silentTruncationIsCaught() async throws {
        let engine = StubEngine(manageable: 4, failure: .truncatedSilently)
        let outcome = try await run(engine, requests(32))

        // Before the coverage check this returned 1 translation and reported
        // success for all 32.
        #expect(outcome.results.count == 32)
        #expect(outcome.failed == 0)
    }

    @Test("One caption the model can't handle costs that caption, not the run")
    func oneBadCaptionIsSkipped() async throws {
        let engine = StubEngine(manageable: 60, poisoned: [7])
        let outcome = try await run(engine, requests(30))

        #expect(outcome.results.count == 29)
        #expect(outcome.failed == 1)
    }

    @Test("A missing API key fails immediately instead of retrying nine hundred times")
    func fatalErrorIsNotRetried() async throws {
        let engine = StubEngine(manageable: 0, failure: .fatal)

        await #expect(throws: CaptionAIError.self) {
            _ = try await run(engine, requests(40))
        }
        // One attempt, not a bisection cascade.
        #expect(engine.requestedSizes == [40])
    }

    @Test("Batches are handed over as they land, not all at the end")
    func batchesArriveIncrementally() async throws {
        let engine = StubEngine(manageable: 60)
        var batches: [Int] = []

        _ = try await AICaptionTranslationRunner(
            engine: engine,
            sourceLanguage: "en",
            targetLanguage: "zh-Hans",
            terms: []
        )
        .translate(
            requests(150),
            onBatch: { batches.append($0.count) },
            onProgress: { _ in }
        )

        // 150 captions against a 60-line cap: three batches, three hand-offs.
        #expect(batches.count == 3)
        #expect(batches.reduce(0, +) == 150)
    }

    @Test("A single-batch run reports work in flight instead of sitting at zero")
    func singleBatchReportsInFlight() async throws {
        // 28 captions is one batch for this backend, so `done` cannot move
        // until the whole run is over. Reporting only that is what made a
        // working translation look frozen at 0 of 28.
        let engine = StubEngine(manageable: 60)
        var reports: [CaptionTranslationProgress] = []

        _ = try await AICaptionTranslationRunner(
            engine: engine,
            sourceLanguage: "en",
            targetLanguage: "zh-Hans",
            terms: []
        )
        .translate(requests(28), onBatch: { _ in }, onProgress: { reports.append($0) })

        #expect(engine.requestedSizes == [28])
        // One before the request goes out, one after it lands.
        #expect(reports.count == 2)
        #expect(reports.first?.inFlight == 28)
        #expect(reports.last?.done == 28)
        #expect(reports.last?.inFlight == 0)
    }

    @Test("Work in flight with nothing finished drives an indeterminate bar")
    func inFlightProgressIsIndeterminate() {
        let waiting = CaptionProgress.translating(
            done: 0, total: 28, language: "Chinese", inFlight: 28
        )
        // nil fraction, because 0% and "stuck" are indistinguishable on screen.
        #expect(waiting.fraction == nil)
        #expect(waiting.detail.contains("translating 28"))

        let partway = CaptionProgress.translating(
            done: 12, total: 28, language: "Chinese", inFlight: 16
        )
        #expect(partway.fraction != nil)
        #expect(partway.detail.contains("12 of 28"))
    }

    // MARK: - Lightweight migration

    /// Both embedded types must survive decoding a JSON object that predates
    /// every optional key — this is what proves the "purely additive schema"
    /// story that lets the app ship without a `SchemaMigrationPlan`.
    @Test("Embedded translation types decode from an object with no keys")
    func tolerantDecoding() throws {
        let empty = Data("{}".utf8)
        let decoder = JSONDecoder()

        let translation = try decoder.decode(CaptionTranslation.self, from: empty)
        #expect(translation.languageCode.isEmpty)
        #expect(translation.text.isEmpty)
        #expect(!translation.isUserEdited)

        let version = try decoder.decode(CaptionTranscriptVersion.self, from: empty)
        #expect(version.number == 1)
        #expect(version.segmentCount == 0)
        #expect(version.translations.isEmpty)
        #expect(version.alignmentQualityEnum == .none)

        let summary = try decoder.decode(CaptionVersionTranslation.self, from: empty)
        #expect(summary.translatedCount == 0)
        #expect(!summary.isComplete)
    }

    @Test("A version round-trips through JSON with its translations intact")
    func versionRoundTrip() throws {
        let original = CaptionTranscriptVersion(
            number: 3,
            languageCode: "en-US",
            provider: CaptionProvider.azure.rawValue,
            segmentCount: 42,
            note: "Aligned to script",
            translations: [
                CaptionVersionTranslation(
                    languageCode: "zh-Hans", translatedCount: 40, totalCount: 42
                )
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CaptionTranscriptVersion.self, from: data)

        #expect(decoded.number == 3)
        #expect(decoded.languageCode == "en-US")
        #expect(decoded.note == "Aligned to script")
        #expect(decoded.translations.first?.translatedCount == 40)
        #expect(!(decoded.translations.first?.isComplete ?? true))
    }

    // MARK: - Which model answered

    @Test("A run records its model on every caption and on the version summary")
    func runRecordsTheModel() async throws {
        let (project, context) = try makeProject(texts: ["One.", "Two."])

        try await CaptionTranslationService.translate(
            project: project,
            runner: StubRunner(modelLabel: "gpt-4o-mini"),
            context: context
        )

        #expect(project.activeSegments.allSatisfy {
            $0.translation("zh-Hans")?.model == "gpt-4o-mini"
        })
        let summary = try #require(project.activeVersion?.translation("zh-Hans"))
        #expect(summary.engine == CaptionTranslationEngineKind.aiBackend.rawValue)
        #expect(summary.model == "gpt-4o-mini")
        #expect(summary.producerDescription == "AI model · gpt-4o-mini")
    }

    @Test("Re-running on a different model overwrites what was recorded")
    func rerunReplacesTheModel() async throws {
        let (project, context) = try makeProject(texts: ["One."])

        try await CaptionTranslationService.translate(
            project: project,
            runner: StubRunner(modelLabel: "gpt-4o-mini"),
            context: context
        )
        try await CaptionTranslationService.translate(
            project: project,
            runner: StubRunner(modelLabel: "claude-opus-5"),
            scope: .all,
            context: context
        )

        #expect(project.orderedSegments[0].translation("zh-Hans")?.model == "claude-opus-5")
        #expect(project.activeVersion?.translation("zh-Hans")?.model == "claude-opus-5")
    }

    @Test("Editing a translation by hand keeps the model that produced it")
    func handEditKeepsTheModel() throws {
        let (project, _) = try makeProject(texts: ["One."])
        let segment = project.orderedSegments[0]
        segment.setTranslation(
            "一。",
            language: "zh-Hans",
            engine: CaptionTranslationEngineKind.aiBackend.rawValue,
            model: "gpt-4o-mini"
        )

        // What the editor sheet does: re-set the text, carrying the record over.
        segment.setTranslation(
            "第一。",
            language: "zh-Hans",
            engine: segment.translation("zh-Hans")?.engine ?? "",
            model: segment.translation("zh-Hans")?.model ?? "",
            isUserEdited: true
        )

        let translation = try #require(segment.translation("zh-Hans"))
        #expect(translation.text == "第一。")
        #expect(translation.model == "gpt-4o-mini")
        #expect(translation.isUserEdited)
    }

    @Test("Apple's engine has no model to name")
    func appleTranslationHasNoModel() throws {
        #expect(
            CaptionTranslationEngineKind.producerDescription(
                engine: CaptionTranslationEngineKind.appleTranslation.rawValue,
                model: ""
            ) == "Apple Translation"
        )
        // Nothing recorded at all — a translation written before this existed.
        #expect(CaptionTranslationEngineKind.producerDescription(engine: "", model: "").isEmpty)
    }

    @Test("The model survives a JSON round trip on both records")
    func modelRoundTrips() throws {
        let translation = CaptionTranslation(
            languageCode: "zh-Hans",
            text: "一。",
            engine: CaptionTranslationEngineKind.aiBackend.rawValue,
            model: "gpt-4o-mini"
        )
        let decodedTranslation = try JSONDecoder().decode(
            CaptionTranslation.self,
            from: try JSONEncoder().encode(translation)
        )
        #expect(decodedTranslation.model == "gpt-4o-mini")

        let summary = CaptionVersionTranslation(
            languageCode: "zh-Hans",
            engine: CaptionTranslationEngineKind.aiBackend.rawValue,
            model: "gpt-4o-mini"
        )
        let decodedSummary = try JSONDecoder().decode(
            CaptionVersionTranslation.self,
            from: try JSONEncoder().encode(summary)
        )
        #expect(decodedSummary.model == "gpt-4o-mini")

        // A record written before the field existed decodes to empty, not a
        // failure.
        let legacy = try JSONDecoder().decode(
            CaptionVersionTranslation.self,
            from: Data(#"{"languageCode":"es","engine":"aiBackend"}"#.utf8)
        )
        #expect(legacy.model.isEmpty)
        #expect(legacy.producerDescription == "AI model")
    }

    // MARK: - Glossary placeholders

    /// The point of the whole `{{term}}` design: the caption stores a
    /// placeholder, a snapshot resolves it, and changing the term's wording
    /// changes what every caption reads — without touching a segment, without
    /// re-translating, and without making anything stale.
    @Test("Changing a term's wording updates its captions with no re-translation")
    func termWordingFlowsThroughToCaptions() throws {
        let (project, _) = try makeProject(texts: ["We built it at RxLab."])
        project.terms = [
            CaptionTerm(text: "RxLab", translations: ["zh-Hans": "睿析实验室"])
        ]
        let segment = project.orderedSegments[0]
        segment.setTranslation("我们在{{RxLab}}构建了它。", language: "zh-Hans")

        let before = segment.translation("zh-Hans")
        #expect(project.snapshot().segments[0].translation("zh-Hans") == "我们在睿析实验室构建了它。")

        project.terms[0].setTranslation("睿析", language: "zh-Hans")

        #expect(project.snapshot().segments[0].translation("zh-Hans") == "我们在睿析构建了它。")
        // Storage untouched, so nothing went stale and nothing needs re-running.
        #expect(segment.translatedText("zh-Hans") == "我们在{{RxLab}}构建了它。")
        #expect(segment.translation("zh-Hans")?.sourceFingerprint == before?.sourceFingerprint)
        #expect(!segment.isTranslationStale("zh-Hans"))
        #expect(!segment.needsTranslation("zh-Hans"))
    }

    /// Resolution happens when the snapshot is taken, which is the only ordering
    /// that survives the exporter's own text mangling — `stripPunctuation` would
    /// eat the braces and leave half a key behind.
    @Test("No export format ever emits a placeholder")
    func exportsResolveTerms() async throws {
        let (project, _) = try makeProject(texts: ["We built it at RxLab."])
        project.terms = [CaptionTerm(text: "RxLab", translations: ["zh-Hans": "睿析实验室"])]
        project.orderedSegments[0].setTranslation("我们在{{RxLab}}构建了它。", language: "zh-Hans")
        let snapshot = project.snapshot()

        for format in [CaptionExportFormat.vtt, .srt, .text, .json] {
            for stripPunctuation in [false, true] {
                let data = try await CaptionExporter.render(
                    snapshot,
                    options: .init(
                        format: format,
                        stripPunctuation: stripPunctuation,
                        translationMode: .bilingual,
                        translationLanguage: "zh-Hans"
                    )
                )
                let text = String(decoding: data, as: UTF8.self)
                #expect(!text.contains("{{"), "\(format) strip=\(stripPunctuation)")
                #expect(text.contains("睿析实验室"), "\(format) strip=\(stripPunctuation)")
            }
        }
    }

    @Test("A language with no wording for the term falls back to its spelling")
    func termWithoutWordingFallsBack() throws {
        let (project, _) = try makeProject(texts: ["We built it at RxLab."])
        project.terms = [CaptionTerm(text: "RxLab", translations: ["zh-Hans": "睿析实验室"])]
        project.orderedSegments[0].setTranslation("Lo hicimos en {{RxLab}}.", language: "es")

        let snapshot = project.snapshot()
        #expect(snapshot.segments[0].translation("es") == "Lo hicimos en RxLab.")
    }

    /// Apple's engine can't be given a glossary, so its output has no braces.
    /// It must survive the resolver byte-for-byte.
    @Test("Placeholder-free translations pass through untouched")
    func plainTranslationsUnchanged() throws {
        let (project, _) = try makeProject(texts: ["We built it at RxLab."])
        project.terms = [CaptionTerm(text: "RxLab", translations: ["zh-Hans": "睿析实验室"])]
        project.orderedSegments[0].setTranslation("我们在睿智实验室构建了它。", language: "zh-Hans")

        #expect(project.snapshot().segments[0].translation("zh-Hans") == "我们在睿智实验室构建了它。")
    }
}
