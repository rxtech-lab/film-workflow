import FilmTemplateKit
import SwiftUI

/// The frame every wizard page sits in: a progress header, the page, and a
/// footer the page fills with its own buttons.
public struct WizardShell<Content: View, Footer: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    let steps: [WizardStep]
    let current: WizardStep
    let onCancel: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    @Environment(\.wizardAgentActivity) private var agentActivity
    @State private var showingAgentActivity = false

    public init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        steps: [WizardStep] = WizardStep.allCases,
        current: WizardStep,
        onCancel: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.steps = steps
        self.current = current
        self.onCancel = onCancel
        self.content = content
        self.footer = footer
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 12) {
                if let onCancel {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .accessibilityIdentifier("wizard.cancel")
                }
                Spacer(minLength: 8)
                footer()
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(
                    colors: [.blue.opacity(0.09), .clear, .cyan.opacity(0.05)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
            .ignoresSafeArea()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 22) {
            WizardProgressBar(steps: steps, current: current)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 26, weight: .semibold))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    if let agentActivity {
                        activityButton(agentActivity)
                    }
                    Text("STEP \(currentIndex + 1) OF \(steps.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 20)
    }

    /// What the agent has been saying, on every page rather than only the
    /// preview: a wizard that sits on a spinner should still be able to show
    /// its work.
    private func activityButton(_ activity: @escaping () -> AnyView) -> some View {
        Button {
            FilmTemplateTip.activity.didPerform()
            showingAgentActivity.toggle()
        } label: {
            Label("Agent Activity", systemImage: "bubble.left.and.bubble.right")
                .labelStyle(.iconOnly)
                .font(.system(size: 13))
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .help("Agent Activity")
        .accessibilityLabel("Agent Activity")
        .accessibilityIdentifier("wizard.activity")
        .templateTip(.activity, when: !showingAgentActivity)
        .popover(isPresented: $showingAgentActivity, arrowEdge: .bottom) {
            activity()
                .frame(width: 520, height: 480)
        }
    }

    private var currentIndex: Int { steps.firstIndex(of: current) ?? 0 }
}

struct WizardProgressBar: View {
    let steps: [WizardStep]
    let current: WizardStep
    private var currentIndex: Int { steps.firstIndex(of: current) ?? 0 }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                HStack(spacing: 6) {
                    Group {
                        if index < currentIndex {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                        } else {
                            Text("\(index + 1)").font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .frame(width: 20, height: 20)
                    .foregroundStyle(index <= currentIndex ? Color.accentColor : Color.secondary)
                    .background(index <= currentIndex ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: Circle())
                    Text(LocalizedStringKey(step.shortTitle))
                        .font(.system(size: 11, weight: index == currentIndex ? .semibold : .regular))
                        .foregroundStyle(index == currentIndex ? .primary : .secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background {
                    if index == currentIndex {
                        Capsule().fill(.background.opacity(0.8))
                            .shadow(color: .black.opacity(0.05), radius: 3, y: 2)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(5)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(currentIndex + 1) of \(steps.count): \(current.title)")
        .accessibilityIdentifier("wizard.progress")
    }
}

/// Shown while the agent works between pages.
public struct WizardWaitingView: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let status: String?

    public init(title: LocalizedStringKey, detail: LocalizedStringKey, status: String?) {
        self.title = title
        self.detail = detail
        self.status = status
    }

    public var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 5) {
                Text(title).font(.system(size: 22, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let status, !status.isEmpty {
                Text(status)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
                    .accessibilityIdentifier("wizard.status")
            }
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: status)
    }
}

/// Shown when a step fails and the user has to decide what to do next.
public struct WizardErrorView: View {
    let message: String
    let onRetry: (() -> Void)?
    let onCancel: () -> Void

    public init(message: String, onRetry: (() -> Void)?, onCancel: @escaping () -> Void) {
        self.message = message
        self.onRetry = onRetry
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.orange)
            Text("Something went wrong")
                .font(.system(size: 22, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                if let onRetry {
                    Button("Try Again", action: onRetry).buttonStyle(.glassProminent)
                }
                Button("Cancel", role: .cancel, action: onCancel)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("wizard.error")
    }
}
