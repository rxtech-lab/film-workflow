import FilmTemplateKit
import SwiftUI

/// The first cut: play it, ask for a change, or take it into the editor.
///
/// The player, clip strip, and agent activity are injected by the app, which
/// owns the film document and its live agent.
public struct PreviewPageView<Player: View, Strip: View, AgentActivity: View>: View {
    let title: String
    let status: String?
    let isBusy: Bool
    let summary: String?
    let hasAgentActivity: Bool
    let onRefine: (String) -> Void
    let onOpenEditor: () -> Void
    let onCancel: () -> Void
    @ViewBuilder let player: () -> Player
    @ViewBuilder let clipStrip: () -> Strip
    @ViewBuilder let agentActivity: () -> AgentActivity

    @State private var refinement = ""
    @State private var showingNotes = false
    @State private var showingAgentActivity = false

    public init(
        title: String,
        status: String?,
        isBusy: Bool,
        summary: String?,
        hasAgentActivity: Bool = false,
        onRefine: @escaping (String) -> Void,
        onOpenEditor: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        @ViewBuilder player: @escaping () -> Player,
        @ViewBuilder clipStrip: @escaping () -> Strip = { EmptyView() },
        @ViewBuilder agentActivity: @escaping () -> AgentActivity = { EmptyView() }
    ) {
        self.title = title
        self.status = status
        self.isBusy = isBusy
        self.summary = summary
        self.hasAgentActivity = hasAgentActivity
        self.onRefine = onRefine
        self.onOpenEditor = onOpenEditor
        self.onCancel = onCancel
        self.player = player
        self.clipStrip = clipStrip
        self.agentActivity = agentActivity
    }

    public var body: some View {
        WizardShell(
            title: title,
            subtitle: isBusy ? "Watch your story come together." : "Your first cut. Ready when you are.",
            current: isBusy ? .build : .preview,
            onCancel: onCancel
        ) {
            VStack(spacing: 14) {
                HStack {
                    Label(isBusy ? "Building your film" : "Film preview", systemImage: "play.rectangle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let summary, !summary.isEmpty {
                        Button { showingNotes = true } label: {
                            Label("Build Notes", systemImage: "text.alignleft")
                        }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("wizard.preview.notes")
                        .popover(isPresented: $showingNotes, arrowEdge: .top) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text("Build notes").font(.title3.bold())
                                    Text(.init(summary))
                                        .font(.callout)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(24)
                            }
                            .frame(width: 420, height: 340)
                        }
                    }
                }
                player()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .clipShape(.rect(cornerRadius: 18))
                    .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12)) }
                    .shadow(color: .black.opacity(0.12), radius: 16, y: 8)

                clipStrip()

                statusRow
                refineRow
            }
            .padding(.horizontal, 28)
        } footer: {
            Button("Edit in Editor", action: onOpenEditor)
                .buttonStyle(.glassProminent)
                .disabled(isBusy)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("wizard.preview.edit")
        }
    }

    @ViewBuilder private var statusRow: some View {
        if isBusy || (status?.isEmpty == false) || hasAgentActivity {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(status ?? (isBusy ? "Working…" : "Ready"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("wizard.preview.status")
                if hasAgentActivity {
                    Button { showingAgentActivity.toggle() } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Show agent activity")
                    .accessibilityLabel("Show agent activity")
                    .accessibilityIdentifier("wizard.preview.activity")
                    .popover(isPresented: $showingAgentActivity, arrowEdge: .bottom) {
                        agentActivity()
                            .frame(width: 520, height: 480)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        }
    }

    private var refineRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Ask for a change…", text: $refinement, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...3)
                .onSubmit(send)
                .accessibilityIdentifier("wizard.preview.refine")
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 24, height: 26)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(refinement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
            .help("Apply this change")
            .accessibilityLabel("Apply change")
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private func send() {
        let text = refinement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        refinement = ""
        onRefine(text)
    }
}
