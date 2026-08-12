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
        /// Segment ids the runner refuses to answer for, standing in for a model
        /// that skips a line.
        var skipping: Set<UUID> = []

        func translate(
            _ requests: [CaptionTranslationRequest],
            onProgress: @MainActor (Int, Int) -> Void
        ) async throws -> [CaptionTranslationResult] {
            onProgress(requests.count, requests.count)
            return requests
                .filter { !skipping.contains($0.segmentID) }
                .map {
                    CaptionTranslationResult(
                        segmentID: $0.segmentID,
                        text: "[\(targetLanguage)] \($0.text)"
                    )
                }
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

        let written = try await CaptionTranslationService.translate(
            project: project, runner: StubRunner(), context: context
        )

        #expect(written == 2)
        #expect(rows[0].translatedText("zh-Hans") == "已翻译")
        #expect(rows[1].translatedText("zh-Hans") == "[zh-Hans] Two.")
        #expect(rows[2].translatedText("zh-Hans") == "[zh-Hans] Three.")
    }

    @Test("Scope .all overwrites, including hand-edited translations")
    func serviceAllScope() async throws {
        let (project, context) = try makeProject(texts: ["One."])
        project.orderedSegments[0].setTranslation("我的翻译", language: "zh-Hans", isUserEdited: true)

        let written = try await CaptionTranslationService.translate(
            project: project, runner: StubRunner(), scope: .all, context: context
        )

        #expect(written == 1)
        #expect(project.orderedSegments[0].translatedText("zh-Hans") == "[zh-Hans] One.")
    }

    @Test("A skipped caption is left untranslated rather than guessed at")
    func serviceKeepsGapsHonest() async throws {
        let (project, context) = try makeProject(texts: ["One.", "Two."])
        let skipped = project.orderedSegments[1].uuid

        let written = try await CaptionTranslationService.translate(
            project: project,
            runner: StubRunner(skipping: [skipped]),
            context: context
        )

        #expect(written == 1)
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
}
