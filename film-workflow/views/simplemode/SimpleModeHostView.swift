import AppKit
import FilmTemplateKit
import FilmTemplateUI
import JSONRenderUI
import JSONSchemaForm
import SwiftUI

/// The wizard itself: one page per phase of the session.
///
/// Everything that touches a film, the marketplace or the agent lives in the
/// coordinator; this only maps state onto pages and answers back.
struct SimpleModeHostView: View {
    let session: SimpleModeSession
    let onOpenEditor: (URL) -> Void
    let onBackToTemplates: () -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var formData: FormData = .object(properties: [:])
    @State private var coordinator = SimpleModeCoordinator.shared

    var body: some View {
        ZStack {
            content
                .id(pageIdentity)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 16)),
                    removal: .opacity.combined(with: .offset(y: -8))
                ))
        }
        .frame(minWidth: 720, minHeight: 560)
        .clipped()
        .animation(
            reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.32),
            value: pageIdentity
        )
    }

    /// Animate page changes, without replacing a page when its choices or
    /// progress text updates. The player also survives build completion.
    private var pageIdentity: String {
        switch session.step {
        case .chooseEngine: "engine"
        case .intake: "brief"
        case .chooseLocation: "location"
        case .creating: "creating"
        case .researching: "research"
        case .chooseTemplate: "templates"
        case .planning: "planning"
        case .chooseOptions: "options"
        case .optionsUnavailable: "options-fallback"
        case .building, .preview: showsBuildWaiting ? "building" : "preview"
        case .failed: "error"
        }
    }

    private var showsBuildWaiting: Bool {
        session.step == .building && session.document?.pendingTimelineFocus == nil
    }

    @ViewBuilder private var content: some View {
        switch session.step {
        case .chooseEngine:
            SimpleModeEnginePage(
                session: session,
                onContinue: { session.chooseEngine($0) },
                onBack: onBackToTemplates,
                onCancel: cancel
            )

        case .intake:
            IntakeFormView(
                template: session.template,
                formData: $formData,
                onSubmit: { session.reviewLocation(for: $0) },
                onBack: { session.returnToEngine() },
                onCancel: cancel
            )

        case .chooseLocation:
            SimpleModeLocationPage(session: session, onContinue: {
                guard let intake = session.intake else { return }
                Task { await coordinator.submitIntake(intake, for: session) }
            }, onCancel: cancel)

        case .creating:
            waiting(
                step: .location,
                title: "Setting up your film",
                detail: "Creating the film and copying in your footage."
            )

        case .researching:
            waiting(
                step: .research,
                title: "Reading your website",
                detail: "We're learning about the company and looking for templates that fit."
            )

        case .chooseTemplate(let candidates):
            TemplateChoiceView(
                title: session.template.title,
                summary: session.lastSummary,
                candidates: candidates,
                onChoose: choose,
                onCancel: cancel
            )

        case .planning:
            waiting(
                step: .chooseOptions,
                title: "Working out your options",
                detail: "Matching your footage to the template and picking music that suits."
            )

        case .chooseOptions(let spec, let title):
            OptionsPageView(
                title: title,
                spec: spec,
                state: session.optionsState,
                imageProvider: imageProvider,
                onConfirm: { coordinator.confirmOptions(for: session) },
                onCancel: cancel
            )

        case .optionsUnavailable(let reason):
            OptionsFallbackView(
                detail: "We couldn't show the choices page (\(reason)). We'll build your film with the setup we recommended.",
                onContinue: { coordinator.continueWithoutOptions(for: session) },
                onCancel: cancel
            )

        case .building, .preview:
            buildingPage

        case .failed(let message):
            WizardShell(
                title: session.template.title,
                subtitle: nil,
                current: session.step.wizardStep,
                onCancel: cancel
            ) {
                WizardErrorView(
                    message: message,
                    onRetry: { session.restartIntake() },
                    onCancel: cancel
                )
            }
        }
    }

    /// While the build runs, show the timeline filling up rather than a
    /// spinner: the whole point of Simple mode is watching it happen.
    @ViewBuilder private var buildingPage: some View {
        if showsBuildWaiting {
            waiting(
                step: .build,
                title: "Building your film",
                detail: "Placing your shots, adding music and titles."
            )
        } else {
            previewPage
        }
    }

    @ViewBuilder private var previewPage: some View {
        if let document = session.document {
            SimpleModePreviewHost(
                session: session,
                document: document,
                onOpenEditor: openEditor,
                onCancel: cancel
            )
        } else {
            waiting(step: .preview, title: "Almost there", detail: "Finishing your film.")
        }
    }

    /// A waiting phase, or the error that stopped it.
    ///
    /// A failed turn would otherwise leave the user on a spinner with no way
    /// forward: the agent has stopped, and nothing else moves the wizard on.
    private func waiting(step: WizardStep, title: String, detail: String) -> some View {
        WizardShell(
            title: session.template.title,
            subtitle: session.template.summary,
            current: step,
            onCancel: cancel
        ) {
            if let error = session.error, !session.isAgentRunning {
                WizardErrorView(
                    message: error,
                    onRetry: { coordinator.retryCurrentPhase(for: session) },
                    onCancel: cancel
                )
            } else {
                WizardWaitingView(title: title, detail: detail, status: session.statusText)
            }
        }
    }

    // MARK: - Actions

    private func choose(_ choice: TemplateChoice) {
        guard let item = session.candidate(id: choice.id) else { return }
        coordinator.choose(template: item, for: session)
    }

    private func openEditor() {
        guard let url = coordinator.finish(session) else { return }
        onOpenEditor(url)
        onClose()
    }

    private func cancel() {
        // Ask before throwing work away, and say which of the two things will
        // happen: a film with a cut in it is kept, an empty one is not.
        if session.document != nil, session.step.hasWork {
            let discards = coordinator.cancellingDiscardsFilm(session)
            let alert = NSAlert()
            alert.messageText = discards
                ? String(localized: "Discard this film?")
                : String(localized: "Stop building this film?")
            alert.informativeText = discards
                ? String(localized: "The film will be moved to the Trash.")
                : String(localized: "The film stays in your chosen location. You can open it from Recent Films.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: discards
                ? String(localized: "Discard")
                : String(localized: "Stop"))
            alert.addButton(withTitle: String(localized: "Keep Working"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Task {
            await coordinator.cancel(session)
            onClose()
        }
    }

    /// Turns a sourceId on an option card into a thumbnail from the film.
    private var imageProvider: JSONRenderImageProvider? {
        guard let document = session.document else { return nil }
        return { source in
            guard let url = SimpleModeThumbnails.url(for: source, in: document),
                  let image = NSImage(contentsOf: url)
            else { return nil }
            return Image(nsImage: image)
        }
    }
}

private extension SimpleModeSession.Step {
    /// Whether anything exists that discarding would throw away.
    var hasWork: Bool {
        switch self {
        case .chooseEngine, .intake, .chooseLocation, .creating, .researching: false
        default: true
        }
    }
}
