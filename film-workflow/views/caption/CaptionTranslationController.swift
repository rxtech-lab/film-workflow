import SwiftData
import SwiftUI
import Translation

/// Runs a caption translation on behalf of whichever screen asked for one.
///
/// This is a type rather than a handful of `@State` properties because of
/// Apple's engine: its session only exists inside `.translationTask`, so
/// starting a run means stashing the choice and waking that modifier up. Every
/// screen offering translation would otherwise repeat the dance. Hold one of
/// these and attach `.captionTranslation(_:project:)` once.
@MainActor
@Observable
final class CaptionTranslationController {
    /// Settable so the progress sheet's own dismissal can lower it; the run
    /// itself keeps going and finishes writing whatever it had left.
    var isRunning = false
    var progress: CaptionProgress?
    var errorMessage: String?
    var notice: String?

    /// Set when a run needs an Apple `TranslationSession`. Stays nil for the AI
    /// engine, which leaves the `.translationTask` dormant.
    var config: TranslationSession.Configuration?

    private var pendingChoice: CaptionTranslateChoice?
    private var task: Task<Void, Never>?

    /// Routes a run to the right engine.
    ///
    /// The AI engine can start immediately. Apple's can't: all this can do is
    /// stash the choice and set the configuration the modifier watches.
    func start(_ choice: CaptionTranslateChoice, project: CaptionProject, context: ModelContext) {
        guard !isRunning else { return }
        pendingChoice = choice

        switch choice.engine {
        case .aiBackend:
            runAI(choice, project: project, context: context)

        case .appleTranslation:
            let target = Locale.Language(identifier: choice.languageCode)
            let source = project.sourceLanguageCode.isEmpty
                ? nil
                : Locale.Language(identifier: project.sourceLanguageCode)

            isRunning = true
            progress = .translating(
                done: 0,
                total: 0,
                language: CaptionTranslationAvailability.displayName(choice.languageCode)
            )
            // Re-requesting the same pair produces no new session, so an
            // unchanged target has to be invalidated to fire the task again.
            if config?.target == target, config?.source == source {
                config?.invalidate()
            } else {
                config = TranslationSession.Configuration(source: source, target: target)
            }
        }
    }

    /// Starts a top-up of one language using the app-wide engine settings —
    /// what the "Update …" rows offer, where the sheet's choices would be noise.
    func update(
        _ languageCode: String,
        project: CaptionProject,
        context: ModelContext,
        settings: CaptionSettings
    ) {
        start(
            CaptionTranslateChoice(
                languageCode: languageCode,
                engine: settings.translationEngine,
                preferredBackend: settings.translationEngine == .aiBackend ? settings.aiBackend : nil,
                scope: .missingOrStale
            ),
            project: project,
            context: context
        )
    }

    func cancel() {
        task?.cancel()
    }

    func removeTranslation(_ code: String, project: CaptionProject, context: ModelContext) {
        do {
            try CaptionTranslationService.removeTranslation(code, from: project, context: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// e.g. "Update Chinese (412 to do)" — the counts are what tell the user
    /// whether a run is worth starting.
    static func updateLabel(for code: String, in project: CaptionProject) -> String {
        let counts = CaptionTranslationService.counts(for: code, in: project)
        let name = CaptionTranslationAvailability.displayName(code)
        let outstanding = counts.total - counts.translated + counts.stale
        guard outstanding > 0 else { return "\(name) — up to date" }
        return "Update \(name) (\(outstanding) to do)"
    }

    // MARK: - Engines

    /// Called by the `.translationTask` once Apple hands over a session.
    func runApple(session: TranslationSession, project: CaptionProject, context: ModelContext) async {
        guard let choice = pendingChoice, choice.engine == .appleTranslation else { return }
        pendingChoice = nil

        let runner = AppleTranslationRunner(
            session: session,
            sourceLanguage: project.sourceLanguageCode,
            targetLanguage: choice.languageCode
        )
        await perform(choice: choice, runner: runner, project: project, context: context)
    }

    private func runAI(_ choice: CaptionTranslateChoice, project: CaptionProject, context: ModelContext) {
        pendingChoice = nil
        let config = try? AppConfig.loadFromKeychain()
        let runner: AICaptionTranslationRunner
        do {
            runner = try CaptionTranslationService.makeAIRunner(
                project: project,
                targetLanguage: choice.languageCode,
                config: config,
                preferredBackend: choice.preferredBackend
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        isRunning = true
        progress = .translating(
            done: 0,
            total: 0,
            language: CaptionTranslationAvailability.displayName(choice.languageCode)
        )
        task = Task { await perform(choice: choice, runner: runner, project: project, context: context) }
    }

    /// Shared tail: run, report, and make sure the progress sheet comes down on
    /// every path, including cancellation.
    ///
    /// Partial results are deliberately kept — the service writes each batch as
    /// it lands, so cancelling half way through a nine-hundred-caption run
    /// leaves the first half translated rather than throwing the work away.
    private func perform(
        choice: CaptionTranslateChoice,
        runner: any CaptionTranslationRunner,
        project: CaptionProject,
        context: ModelContext
    ) async {
        defer {
            isRunning = false
            progress = nil
            task = nil
        }
        do {
            let outcome = try await CaptionTranslationService.translate(
                project: project,
                runner: runner,
                scope: choice.scope,
                context: context,
                onProgress: { [weak self] in self?.progress = $0 }
            )
            let name = CaptionTranslationAvailability.displayName(choice.languageCode)
            let written = outcome.written
            if written == 0, outcome.failed == 0 {
                notice = String(localized: "Nothing needed translating into \(name).")
            } else {
                var text = String(localized: "Translated \(written) caption\(written == 1 ? "" : "s") into \(name).")
                if outcome.failed > 0 {
                    // Named rather than swallowed: the captions are still there,
                    // untranslated, and re-running retries just them.
                    text += " " + String(localized: "\(outcome.failed) couldn't be translated — run it again to retry them.")
                }
                notice = text
            }
        } catch is CancellationError {
            // User pressed Cancel; whatever was written stays written.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension View {
    /// The progress sheet, the Apple session and the end-of-run notices that
    /// every caller of `CaptionTranslationController` needs.
    func captionTranslation(_ controller: CaptionTranslationController, project: CaptionProject) -> some View {
        modifier(CaptionTranslationPresentation(controller: controller, project: project))
    }
}

private struct CaptionTranslationPresentation: ViewModifier {
    @Bindable var controller: CaptionTranslationController
    let project: CaptionProject
    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $controller.isRunning) {
                CaptionTranscriptionProgressView(progress: controller.progress) {
                    controller.cancel()
                }
            }
            // Apple's engine only exists inside this modifier.
            .translationTask(controller.config) { session in
                await controller.runApple(session: session, project: project, context: modelContext)
            }
            .alert(
                "Translation",
                isPresented: Binding(
                    get: { controller.notice != nil },
                    set: { if !$0 { controller.notice = nil } }
                )
            ) {
                Button("OK") { controller.notice = nil }
            } message: {
                Text(controller.notice ?? "")
            }
            .alert(
                "Translation failed",
                isPresented: Binding(
                    get: { controller.errorMessage != nil },
                    set: { if !$0 { controller.errorMessage = nil } }
                )
            ) {
                Button("OK") { controller.errorMessage = nil }
            } message: {
                Text(controller.errorMessage ?? "")
            }
    }
}
