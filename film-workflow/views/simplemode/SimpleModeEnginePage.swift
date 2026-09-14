import AppKit
import FilmTemplateKit
import FilmTemplateUI
import SwiftUI

/// The wizard's first page: which AI engine builds this film.
///
/// Asked before the brief because every phase after it is a turn on that
/// engine. Left to the app default, a user who has never signed in — or whose
/// credits ran out — types a brief, waits through "Setting up your film", and
/// only then learns the run cannot start. Here the same problem is a button.
struct SimpleModeEnginePage: View {
    let session: SimpleModeSession
    let onContinue: (AgentBackend) -> Void
    let onBack: () -> Void
    let onCancel: () -> Void

    @State private var availability = AgentBackendAvailability.shared
    @State private var auth = AuthManager.shared
    @State private var balance = CreditBalanceStore.shared
    @State private var config: AppConfig?
    @State private var selection: AgentBackend = AgentSettings.shared.defaultBackend
    @State private var showEndpointSetup = false

    /// Apple Intelligence is left out rather than shown as unavailable: it runs
    /// on device and cannot call tools at all, so no amount of setting up would
    /// let it build a film.
    private var engines: [AgentBackend] {
        AgentBackend.supported.filter { $0 != .appleIntelligence }
    }

    var body: some View {
        WizardShell(
            title: LocalizedStringKey(session.template.title),
            subtitle: "Choose the engine that builds your film.",
            current: .engine,
            onCancel: onCancel
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(engines) { engine in
                        EngineCard(
                            engine: engine,
                            isSelected: selection == engine,
                            detail: detail(for: engine),
                            problem: problem(for: engine),
                            select: { selection = engine },
                            configureEndpoint: configureEndpoint
                        )
                    }
                    Text("""
                        You can switch engines later from the Agent window. \
                        Claude Code and Codex run the command-line tools installed on this Mac.
                        """)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                .padding(24)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("wizard.engine")
            .filmTip(.simpleEngine, when: !showEndpointSetup)
        } footer: {
            Button("Back", action: onBack)
                .help("Back to template selection")
                .accessibilityIdentifier("wizard.engine.back")
            Button("Continue") {
                FilmFeatureTip.simpleEngine.didPerform()
                onContinue(selection)
            }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(problem(for: selection) != nil)
                .accessibilityIdentifier("wizard.engine.continue")
        }
        .sheet(isPresented: $showEndpointSetup) {
            SimpleModeEndpointSheet(config: config ?? AppConfig()) { savedConfig in
                config = savedConfig
                selection = .openAICompatible
                availability.refresh()
            }
        }
        .task {
            selection = session.backend ?? selection
            config = try? AppConfig.loadFromKeychain()
            availability.refresh()
            // Land on something that works: the app default is only a
            // preference, and the point of this page is not to start a run
            // that cannot finish.
            if problem(for: selection) != nil,
               let usable = engines.first(where: { problem(for: $0) == nil }) {
                selection = usable
            }
            if auth.isAuthenticated { await balance.refresh() }
        }
        .task(id: auth.isAuthenticated) {
            guard auth.isAuthenticated else { return }
            await balance.refresh()
        }
        // Buying credits happens in the browser, so the page watches the
        // balance instead of making the user come back and click something.
        .task(id: isOutOfCredits) {
            guard isOutOfCredits else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await balance.refresh()
            }
        }
        // Reflect changes made in Settings while the wizard is open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            config = try? AppConfig.loadFromKeychain()
            availability.refresh()
        }
    }

    private func configureEndpoint() {
        config = try? AppConfig.loadFromKeychain()
        selection = .openAICompatible
        showEndpointSetup = true
    }

    /// Signed in, billed, and nothing left to spend — the one state a top-up
    /// fixes, and the only one worth polling for.
    private var isOutOfCredits: Bool {
        auth.isAuthenticated
            && balance.billingEnabled
            && balance.lastUpdated != nil
            && balance.availablePoints <= 0
    }

    // MARK: - Per-engine state

    private func detail(for engine: AgentBackend) -> String {
        switch engine {
        case .subscription:
            guard auth.isAuthenticated else {
                return String(localized: "Runs on the RxFilm servers, billed to your credits.")
            }
            return String(localized: "\(balance.availablePoints.formatted()) credits available.")
        case .openAICompatible:
            guard let config, config.hasOpenAICompatibleChat else {
                return String(localized: "Use your own endpoint, API key, and chat model.")
            }
            return String(localized: "Your own endpoint, running \(config.openAIModel).")
        case .claudeCode:
            return String(localized: "The claude command on this Mac, billed to your Claude subscription.")
        case .codex:
            return String(localized: "The codex command on this Mac, billed to your OpenAI account.")
        case .appleIntelligence:
            return ""
        }
    }

    /// What stops this engine from being used, and the control that fixes it.
    /// Nil when the engine is ready to run.
    private func problem(for engine: AgentBackend) -> EngineProblem? {
        if engine == .subscription {
            if auth.isRestoring {
                return EngineProblem(message: "Restoring your account…", fix: nil)
            }
            if !auth.isAuthenticated {
                return EngineProblem(message: "Sign in to your RxLab account to use it.", fix: .signIn)
            }
            if isOutOfCredits {
                return EngineProblem(
                    message: "You have no credits left. Add some and this page updates on its own.",
                    fix: .addCredits
                )
            }
            return nil
        }

        if engine == .openAICompatible, config?.hasOpenAICompatibleChat != true {
            return EngineProblem(
                message: "Add an endpoint, API key, and model to use this engine.",
                fix: .setUpEndpoint
            )
        }
        guard availability.isConfigured(engine, config: config) else {
            return EngineProblem(
                message: availability.unavailableReason(engine, config: config)
                    ?? "This engine isn't set up.",
                fix: nil
            )
        }
        return nil
    }
}

/// Why an engine cannot be picked, and the one thing that would fix it.
struct EngineProblem {
    enum Fix {
        case signIn
        case addCredits
        case setUpEndpoint

        var title: LocalizedStringKey {
            switch self {
            case .signIn: "Sign In"
            case .addCredits: "Add Credits"
            case .setUpEndpoint: "Set Up Endpoint…"
            }
        }
    }

    let message: LocalizedStringKey
    let fix: Fix?
}

private struct EngineCard: View {
    let engine: AgentBackend
    let isSelected: Bool
    let detail: String
    let problem: EngineProblem?
    let select: () -> Void
    let configureEndpoint: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: select) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(engine.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(problem == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let problem {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(problem.message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if let fix = problem.fix {
                        Button(fix.title) { apply(fix) }
                            .controlSize(.small)
                            .accessibilityIdentifier("wizard.engine.fix.\(engine.rawValue)")
                    }
                }
                .padding(.leading, 24)
            } else if engine == .openAICompatible, isSelected {
                HStack {
                    Spacer()
                    Button("Edit Endpoint…", action: configureEndpoint)
                        .controlSize(.small)
                        .accessibilityIdentifier("wizard.engine.endpoint.edit")
                }
            }
        }
        .padding(12)
        .background(
            isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(isHovered ? 0.06 : 0.03),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.07))
        }
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("wizard.engine.\(engine.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func apply(_ fix: EngineProblem.Fix) {
        switch fix {
        case .signIn:
            AppNavigation.shared.requestSignIn()
        case .addCredits:
            SubscriptionCheckout.presentTopUp()
        case .setUpEndpoint:
            configureEndpoint()
        }
    }
}
