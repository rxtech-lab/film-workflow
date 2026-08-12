import Foundation
import SwiftData
import Testing

@testable import film_workflow

/// Transcript versioning.
///
/// The first test is the important one: a project written before versioning
/// existed has `activeVersionID == nil` and `versionID == nil` on every row, and
/// must keep rendering its captions with no migration having run. Getting that
/// wrong would blank the editor for every existing user.
@MainActor
@Suite("Caption versioning")
struct CaptionVersioningTests {

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
        context.insert(project)

        // Deliberately no `versionID` — this is the legacy shape.
        for (index, text) in texts.enumerated() {
            let segment = CaptionSegment(
                orderIndex: index,
                startMs: index * 1_000,
                endMs: (index + 1) * 1_000,
                text: text,
                locale: "en"
            )
            segment.project = project
            context.insert(segment)
        }
        return (project, context)
    }

    private func cues(_ texts: [String], locale: String = "en") -> [CaptionCue] {
        texts.enumerated().map { index, text in
            CaptionCue(
                startMs: index * 1_000,
                endMs: (index + 1) * 1_000,
                text: text,
                locale: locale
            )
        }
    }

    // MARK: - Legacy projects

    @Test("A pre-versioning project still shows its captions before any migration")
    func legacyProjectRenders() throws {
        let (project, _) = try makeProject(texts: ["One.", "Two.", "Three."])

        #expect(project.versions.isEmpty)
        #expect(project.activeVersionID == nil)
        #expect(project.activeSegmentCount == 3)
        #expect(project.orderedSegments.map(\.text) == ["One.", "Two.", "Three."])
    }

    @Test("ensureVersioned creates version 1, stamps every row, and is idempotent")
    func ensureVersionedBackfills() throws {
        let (project, _) = try makeProject(texts: ["One.", "Two."])
        project.languageHint = "en-US"

        let version = try #require(project.ensureVersioned())
        #expect(version.number == 1)
        #expect(version.languageCode == "en-US")
        #expect(version.segmentCount == 2)
        #expect(project.activeVersionID == version.id)
        #expect(project.segments.allSatisfy { $0.versionID == version.id })

        // Second call must not add a version or renumber anything.
        let again = project.ensureVersioned()
        #expect(again?.id == version.id)
        #expect(project.versions.count == 1)
    }

    @Test("ensureVersioned falls back to the detected locale when there is no hint")
    func ensureVersionedDetectsLanguage() throws {
        let (project, _) = try makeProject(texts: ["One."])
        project.languageHint = ""

        let version = try #require(project.ensureVersioned())
        #expect(version.languageCode == "en")
    }

    // MARK: - Writing versions

    @Test("Re-transcribing appends a version and keeps the old captions")
    func writeSegmentsAppendsVersion() throws {
        let (project, context) = try makeProject(texts: ["One.", "Two."])

        let v2 = CaptionTranscriptionService.writeSegments(
            of: project,
            with: cues(["Uno.", "Dos.", "Tres."]),
            context: context,
            provider: .azure
        )

        #expect(project.versions.count == 2)
        #expect(project.orderedVersions.map(\.number) == [2, 1])
        #expect(project.activeVersionID == v2.id)
        #expect(project.orderedSegments.map(\.text) == ["Uno.", "Dos.", "Tres."])
        // Nothing is pruned: both takes are still stored.
        #expect(project.segments.count == 5)
        #expect(project.activeSegmentCount == 3)
    }

    @Test("Switching back to an earlier version restores its captions")
    func activatingAnEarlierVersion() throws {
        let (project, context) = try makeProject(texts: ["One.", "Two."])
        let v1 = try #require(project.ensureVersioned())

        CaptionTranscriptionService.writeSegments(
            of: project, with: cues(["Uno."]), context: context, provider: .azure
        )
        #expect(project.orderedSegments.map(\.text) == ["Uno."])

        CaptionTranscriptionService.activateVersion(v1.id, in: project)
        #expect(project.orderedSegments.map(\.text) == ["One.", "Two."])
    }

    @Test("The version language prefers the hint, then the provider's locale")
    func versionLanguageResolution() throws {
        let (hinted, hintedContext) = try makeProject(texts: ["One."])
        hinted.languageHint = "zh-CN"
        let hintedVersion = CaptionTranscriptionService.writeSegments(
            of: hinted, with: cues(["一。"], locale: "ja"), context: hintedContext, provider: .gemini
        )
        #expect(hintedVersion.languageCode == "zh-CN")

        let (auto, autoContext) = try makeProject(texts: ["One."])
        auto.languageHint = ""
        let autoVersion = CaptionTranscriptionService.writeSegments(
            of: auto, with: cues(["Uno."], locale: "es"), context: autoContext, provider: .gemini
        )
        #expect(autoVersion.languageCode == "es")
    }

    // MARK: - Translation inheritance

    @Test("Unchanged captions keep their translation across a re-transcription")
    func translationsInheritForUnchangedText() throws {
        let (project, context) = try makeProject(texts: ["Welcome back.", "Let's begin."])
        project.ensureVersioned()
        for segment in project.activeSegments {
            segment.setTranslation(
                segment.text == "Welcome back." ? "欢迎回来。" : "我们开始吧。",
                language: "zh-Hans"
            )
        }
        project.refreshTranslationSummary()

        // Second take: line 1 identical, line 2 reworded.
        CaptionTranscriptionService.writeSegments(
            of: project,
            with: cues(["Welcome back.", "Let us begin now."]),
            context: context,
            provider: .azure
        )

        let rows = project.orderedSegments
        #expect(rows[0].translatedText("zh-Hans") == "欢迎回来。")
        #expect(rows[1].translation("zh-Hans") == nil)

        // And the version summary reflects the one that carried over.
        let summary = try #require(project.activeVersion?.translation("zh-Hans"))
        #expect(summary.translatedCount == 1)
        #expect(summary.totalCount == 2)
    }

    @Test("Inheritance ignores punctuation but not wording")
    func inheritanceIsPunctuationBlind() throws {
        let (project, context) = try makeProject(texts: ["hello world"])
        project.ensureVersioned()
        project.activeSegments[0].setTranslation("你好世界", language: "zh-Hans")

        CaptionTranscriptionService.writeSegments(
            of: project, with: cues(["Hello, world!"]), context: context, provider: .azure
        )
        #expect(project.orderedSegments[0].translatedText("zh-Hans") == "你好世界")
    }

    @Test("A repeated line hands each translation to a distinct new caption")
    func inheritanceConsumesMatchesInOrder() throws {
        let (project, context) = try makeProject(texts: ["Yes.", "Yes."])
        project.ensureVersioned()
        let originals = project.orderedSegments
        originals[0].setTranslation("是的。", language: "zh-Hans")
        originals[1].setTranslation("对。", language: "zh-Hans")

        CaptionTranscriptionService.writeSegments(
            of: project, with: cues(["Yes.", "Yes."]), context: context, provider: .azure
        )

        let rows = project.orderedSegments
        #expect(rows[0].translatedText("zh-Hans") == "是的。")
        #expect(rows[1].translatedText("zh-Hans") == "对。")
    }

    // MARK: - Deleting

    @Test("Deleting a version removes its captions and refuses on the last one")
    func deleteVersion() throws {
        let (project, context) = try makeProject(texts: ["One.", "Two."])
        let v1 = try #require(project.ensureVersioned())
        let v2 = CaptionTranscriptionService.writeSegments(
            of: project, with: cues(["Uno."]), context: context, provider: .azure
        )

        #expect(CaptionTranscriptionService.deleteVersion(v1.id, from: project, context: context))
        #expect(project.versions.count == 1)
        #expect(project.activeVersionID == v2.id)
        #expect(project.segments.count == 1)

        // The last remaining version can't go — a project with captions but no
        // version would read as legacy and show every take at once.
        #expect(!CaptionTranscriptionService.deleteVersion(v2.id, from: project, context: context))
        #expect(project.versions.count == 1)
    }

    @Test("Deleting the active version falls back to the newest remaining one")
    func deleteActiveVersion() throws {
        let (project, context) = try makeProject(texts: ["One."])
        let v1 = try #require(project.ensureVersioned())
        let v2 = CaptionTranscriptionService.writeSegments(
            of: project, with: cues(["Uno."]), context: context, provider: .azure
        )

        #expect(CaptionTranscriptionService.deleteVersion(v2.id, from: project, context: context))
        #expect(project.activeVersionID == v1.id)
        #expect(project.orderedSegments.map(\.text) == ["One."])
    }

    @Test("Version numbers are never reused after a deletion")
    func versionNumbersAreStable() throws {
        let (project, context) = try makeProject(texts: ["One."])
        project.ensureVersioned()
        let v2 = CaptionTranscriptionService.writeSegments(
            of: project, with: cues(["Uno."]), context: context, provider: .azure
        )

        CaptionTranscriptionService.deleteVersion(v2.id, from: project, context: context)
        #expect(project.nextVersionNumber == 2)

        let v3 = CaptionTranscriptionService.writeSegments(
            of: project, with: cues(["Ein."]), context: context, provider: .azure
        )
        #expect(v3.number == 2)
    }

    // MARK: - Snapshots

    @Test("A snapshot carries only the active version, plus its language and number")
    func snapshotIsVersionScoped() throws {
        let (project, context) = try makeProject(texts: ["One.", "Two."])
        project.languageHint = "en"
        project.ensureVersioned()
        CaptionTranscriptionService.writeSegments(
            of: project, with: cues(["Uno."]), context: context, provider: .azure
        )

        let snapshot = project.snapshot()
        #expect(snapshot.segments.map(\.text) == ["Uno."])
        #expect(snapshot.sourceLanguage == "en")
        #expect(snapshot.versionNumber == 2)
    }

    // MARK: - Warnings

    @Test("The warning describes the active version, not the last run")
    func warningFollowsTheActiveVersion() throws {
        let (project, context) = try makeProject(texts: ["One."])
        project.warning = "OpenAI-compatible returned no word timings."
        let v1 = try #require(project.ensureVersioned())
        #expect(v1.warning == "OpenAI-compatible returned no word timings.")

        // A clean re-run on a provider that does give timings.
        let v2 = CaptionTranscriptionService.writeSegments(
            of: project, with: cues(["Uno."]), context: context, provider: .azure
        )
        project.warning = ""
        #expect(project.activeWarning.isEmpty)

        // Switching back must bring the old take's caveat back with it.
        CaptionTranscriptionService.activateVersion(v1.id, in: project)
        #expect(project.activeWarning == "OpenAI-compatible returned no word timings.")

        CaptionTranscriptionService.activateVersion(v2.id, in: project)
        #expect(project.activeWarning.isEmpty)
    }

    @Test("Alignment quality is read off the active version")
    func alignmentQualityFollowsTheActiveVersion() throws {
        let (project, context) = try makeProject(texts: ["One."])
        project.alignmentQualityEnum = .estimated
        let v1 = try #require(project.ensureVersioned())

        let v2 = CaptionTranscriptionService.writeSegments(
            of: project,
            with: cues(["Uno."]),
            context: context,
            provider: .azure,
            alignmentQuality: .wordAligned
        )
        #expect(project.activeAlignmentQuality == .wordAligned)

        CaptionTranscriptionService.activateVersion(v1.id, in: project)
        #expect(project.activeAlignmentQuality == .estimated)

        CaptionTranscriptionService.activateVersion(v2.id, in: project)
        #expect(project.activeAlignmentQuality == .wordAligned)
    }

    @Test("Hand-timing every estimated caption retires the estimated warning")
    func retimingClearsTheEstimatedWarning() throws {
        let (project, context) = try makeProject(texts: ["One.", "Two."])
        var estimated = cues(["One.", "Two."])
        for index in estimated.indices { estimated[index].isEstimatedTiming = true }
        CaptionTranscriptionService.writeSegments(
            of: project,
            with: estimated,
            context: context,
            provider: .openAI,
            alignmentQuality: .estimated,
            warning: "OpenAI-compatible returned no word timings."
        )

        let rows = project.orderedSegments
        rows[0].retime(toStartMs: 100, endMs: 900)
        // One caption still estimated, so the banner has to stay.
        project.refreshEstimatedTimingState()
        #expect(project.activeAlignmentQuality == .estimated)
        #expect(!project.activeWarning.isEmpty)

        rows[1].retime(toStartMs: 900, endMs: 1_800)
        project.refreshEstimatedTimingState()
        #expect(project.activeAlignmentQuality == .none)
        #expect(project.activeWarning.isEmpty)
    }

    @Test("Closing gaps is not a hand-set timing")
    func closingGapsLeavesCaptionsEstimated() throws {
        let (project, context) = try makeProject(texts: ["One.", "Two."])
        var estimated = cues(["One.", "Two."])
        for index in estimated.indices { estimated[index].isEstimatedTiming = true }
        // A 200 ms gap the bulk pass will close.
        estimated[1].startMs = 1_200
        CaptionTranscriptionService.writeSegments(
            of: project,
            with: estimated,
            context: context,
            provider: .openAI,
            alignmentQuality: .estimated,
            warning: "Estimated."
        )

        #expect(project.removeGaps(shorterThan: 300) == 1)
        project.refreshEstimatedTimingState()
        #expect(project.orderedSegments.allSatisfy { $0.isEstimatedTiming })
        #expect(project.activeAlignmentQuality == .estimated)
    }
}
