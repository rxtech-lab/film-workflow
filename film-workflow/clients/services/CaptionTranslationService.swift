import Foundation
import SwiftData

/// The single entry point for translating captions, shared by the UI and MCP.
///
/// Mirrors `CaptionTranscriptionService`: a `@MainActor enum` that snapshots
/// what it needs, hands the work to a runner, then writes results back on the
/// main actor. Translations always attach to the **active** version, which is
/// what makes "translate, re-transcribe, translate again" behave sensibly.
@MainActor
enum CaptionTranslationService {

    /// Which captions a run should cover.
    enum Scope: Sendable {
        /// Everything, including translations the user hand-edited.
        case all
        /// Untranslated captions, plus ones whose original changed afterwards.
        case missingOrStale
        /// Just these segment uuids, subject to the same missing-or-stale rule.
        case selection(Set<UUID>)
    }

    /// Translates the active version into the runner's target language.
    /// Returns how many captions were written.
    ///
    /// `.missingOrStale` is the default because a re-run after fixing three
    /// lines should cost three requests, not nine hundred. It also never
    /// overwrites a translation the user typed — only `.all` does that.
    @discardableResult
    static func translate(
        project: CaptionProject,
        runner: any CaptionTranslationRunner,
        scope: Scope = .missingOrStale,
        context: ModelContext,
        onProgress: (@MainActor @Sendable (CaptionProgress) -> Void)? = nil
    ) async throws -> Int {
        project.ensureVersioned()

        let language = runner.targetLanguage
        guard !language.isEmpty else { return 0 }

        let candidates = segments(of: project, in: scope, language: language)
        guard !candidates.isEmpty else { return 0 }

        let languageName = CaptionTranslationAvailability.displayName(language)
        onProgress?(.translating(done: 0, total: candidates.count, language: languageName))

        let requests = candidates.map {
            CaptionTranslationRequest(segmentID: $0.uuid, text: $0.text)
        }

        let results = try await runner.translate(requests) { done, total in
            onProgress?(.translating(done: done, total: total, language: languageName))
        }

        // Index by uuid rather than walking `activeSegments` per result: a
        // nine-hundred-caption transcript would otherwise be quadratic.
        let byID = Dictionary(
            candidates.map { ($0.uuid, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var written = 0
        for result in results {
            guard let segment = byID[result.segmentID] else { continue }
            segment.setTranslation(
                result.text,
                language: language,
                engine: runner.kind.rawValue
            )
            written += 1
        }

        project.recordTranslationRun(language: language, engine: runner.kind.rawValue)
        if project.displayedTranslationLanguage.isEmpty, written > 0 {
            // First translation on this project: show it, otherwise the run
            // finishes with nothing visibly different.
            project.displayedTranslationLanguage = language
        }
        project.updatedAt = Date()
        try context.save()
        return written
    }

    /// Drops a language from every caption in the active version.
    static func removeTranslation(
        _ languageCode: String,
        from project: CaptionProject,
        context: ModelContext
    ) throws {
        guard !languageCode.isEmpty else { return }
        for segment in project.activeSegments {
            segment.removeTranslation(languageCode)
        }
        if let index = project.versions.firstIndex(where: { $0.id == project.activeVersionID }) {
            project.versions[index].translations.removeAll { $0.languageCode == languageCode }
        }
        if project.displayedTranslationLanguage == languageCode {
            project.displayedTranslationLanguage = ""
        }
        project.refreshTranslationSummary()
        project.updatedAt = Date()
        try context.save()
    }

    /// How complete one language is, for menu labels and the version list.
    static func counts(
        for languageCode: String,
        in project: CaptionProject
    ) -> (translated: Int, stale: Int, total: Int) {
        let rows = project.activeSegments
        var translated = 0
        var stale = 0
        for row in rows {
            guard let entry = row.translation(languageCode), !entry.isEmpty else { continue }
            translated += 1
            if row.isTranslationStale(languageCode) { stale += 1 }
        }
        return (translated, stale, rows.count)
    }

    /// Builds the AI runner for a project, resolving the backend the same way
    /// every other AI action does. The only runner MCP can use.
    static func makeAIRunner(
        project: CaptionProject,
        targetLanguage: String,
        config: AppConfig?,
        preferredBackend: AgentBackend? = nil
    ) throws -> AICaptionTranslationRunner {
        let preferred = preferredBackend ?? CaptionSettings.shared.aiBackend
        let backend = try AgentBackendAvailability.shared.resolved(
            preferred: preferred,
            config: config,
            for: .translation
        )
        return AICaptionTranslationRunner(
            engine: try CaptionAIEngineFactory.make(backend: backend, config: config),
            sourceLanguage: project.sourceLanguageCode,
            targetLanguage: targetLanguage,
            terms: CaptionSettings.shared.translationRespectsGlossary ? project.usableTerms : []
        )
    }

    // MARK: - Scope

    private static func segments(
        of project: CaptionProject,
        in scope: Scope,
        language: String
    ) -> [CaptionSegment] {
        let ordered = project.orderedSegments
        switch scope {
        case .all:
            return ordered.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        case .missingOrStale:
            return ordered.filter { $0.needsTranslation(language) && !$0.text.isEmpty }
        case .selection(let ids):
            return ordered.filter {
                ids.contains($0.uuid) && $0.needsTranslation(language) && !$0.text.isEmpty
            }
        }
    }
}
