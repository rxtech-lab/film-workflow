import RxAgentSDK
import SwiftUI
import TipKit

/// Observes the wizard's existing agent without starting or interrupting a turn.
struct SimpleModeAgentActivityView: View {
    let thread: AgentThread

    @Environment(\.dismiss) private var dismiss
    @State private var controller = AgentController.shared
    @State private var isAtBottom = true

    private var agent: Agent? { controller.agent(for: thread) }
    private var isStreaming: Bool { controller.isRunning(thread.id) }

    private var items: [AgentTranscriptItem] {
        let messages = agent?.thread.messages ?? AgentTranscriptStore.load(thread).messages
        var items = AgentTranscriptItem.items(for: messages, transientGroupMinSize: 2)
        if isStreaming || agent?.thread.usage != nil {
            items.append(.accessory(.streamingIndicator))
        }
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Agent Activity", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Text(isStreaming ? "Live" : "Latest messages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close agent activity")
                .accessibilityLabel("Close agent activity")
            }
            .padding(16)

            Divider()

            TipView(FilmFeatureTip.liveActivity)
                .padding(.horizontal, 16)

            if items.isEmpty {
                ContentUnavailableView(
                    "Waiting for the agent",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Messages will appear here as your film is built.")
                )
            } else {
                AgentTranscriptList(
                    items: items,
                    isStreaming: isStreaming,
                    shouldScrollToBottom: true,
                    isAtBottom: $isAtBottom,
                    accessibilityIdentifier: "wizard.agent.transcript",
                    accessoryContent: { accessory in
                        if accessory.kind == .streamingIndicator {
                            AgentStreamingIndicator(isStreaming: isStreaming, usage: agent?.thread.usage)
                        }
                    },
                    rowContent: { item in
                        AgentMessageRow(item: item, thread: thread)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let error = controller.run(for: thread.id).errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .agentTheme(.filmStudio)
        // A wizard run has no composer to retry from, so a stale model stops it
        // dead. The line above explains; this is the way out of it.
        .unavailableModelAlert(
            Binding(
                get: { controller.run(for: thread.id).unavailableModel },
                set: { controller.setUnavailableModel($0, for: thread.id) }
            )
        )
        .onAppear { controller.markSeen(thread.id) }
        .onChange(of: isStreaming) { _, streaming in
            if !streaming { controller.markSeen(thread.id) }
        }
    }
}
