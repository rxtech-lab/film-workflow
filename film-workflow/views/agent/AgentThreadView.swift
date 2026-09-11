import RxAgentSDK
import SwiftData
import SwiftUI

/// One thread's transcript and composer.
///
/// The transcript, the composer, the scroll pinning and the streaming indicator
/// are all `AgentChatView` now. What remains here is the app-specific shell
/// around it: the error bar, the caption-proposal row and its review sheet, the
/// `/` and `@` completions, and the engine picker under the field.
struct AgentThreadView: View {
    @Bindable var thread: AgentThread
    let targets: [AgentTargetOption]

    @Environment(\.modelContext) private var modelContext
    @Environment(AgentController.self) private var controller

    /// The proposal row being reviewed. The row, not its decoded proposal, so
    /// applying can write the outcome back onto it.
    @State private var reviewingRow: AgentMessage?
    @State private var showClearConfirm = false

    private var threadID: UUID { thread.id }
    private var run: AgentController.Run { controller.run(for: threadID) }

    var body: some View {
        Group {
            if let agent = controller.agent(for: thread) {
                chat(agent)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let error = run.errorMessage {
                errorBar(error)
            }
        }
        .confirmationDialog(
            "Clear this conversation?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                controller.clearTranscript(thread, context: modelContext)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your projects are not affected.")
        }
        .sheet(item: $reviewingRow) { row in
            reviewSheet(row)
        }
        .task { await controller.prepare(thread: thread, context: modelContext) }
        .onAppear { controller.markSeen(threadID) }
        .onChange(of: controller.isRunning(threadID)) { _, streaming in
            guard !streaming else { return }
            controller.markSeen(threadID)
        }
    }

    // MARK: - Chat

    private func chat(_ agent: Agent) -> some View {
        AgentChatView(
            agent: agent,
            draft: Binding(
                get: { controller.run(for: threadID).input },
                set: { controller.setInput($0, for: threadID) }
            ),
            completions: completionSources,
            onDropFiles: handleDrop,
            row: { item in
                AgentMessageRow(item: item, thread: thread) { row in
                    reviewingRow = row
                }
            },
            accessories: {
                AgentEngineMenu(thread: thread)
            }
        )
        .agentTheme(.filmStudio)
        // The engine picker lives under the field, in `accessories`. The SDK's
        // own header would put a second one at the top of the window — and its
        // chrome is the only opaque band in an otherwise transparent surface.
        .agentToolbar(.hidden)
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask for changes in plain language.")
                .font(.callout)
            Text("""
            “merge captions 12 and 13”, “make the title yellow and slow the fade”, \
            “list my projects”, “export the captions as SRT”.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("Type @ to pick a project, / for commands.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }

    private func errorBar(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                controller.setError(nil, for: threadID)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Completions

    /// `/` commands and `@` project mentions, as SDK completion sources.
    private var completionSources: [AgentCompletionSource] {
        [
            AgentCompletionSource(trigger: "/") { query in
                AgentSlashCommand.allCases
                    .filter { query.isEmpty || $0.rawValue.hasPrefix(query.lowercased()) }
                    .map { command in
                        AgentCompletionItem(
                            id: command.rawValue,
                            label: command.command,
                            detail: command.summary,
                            systemImage: command.systemImage,
                            // No insertion: a command runs instead of leaving
                            // text behind for the user to delete.
                            action: { run(command) }
                        )
                    }
            },
            AgentCompletionSource(trigger: "@") { query in
                targets
                    .filter {
                        query.isEmpty
                            || $0.name.localizedCaseInsensitiveContains(query)
                    }
                    .prefix(12)
                    .map { option in
                        AgentCompletionItem(
                            id: "\(option.kind.rawValue):\(option.projectUUID.uuidString)",
                            label: option.name,
                            detail: option.kind.rawValue,
                            systemImage: option.kind.systemImage,
                            insertion: "@\(option.kind.rawValue):\(option.name)"
                        )
                    }
            },
        ]
    }

    private func run(_ command: AgentSlashCommand) {
        switch command {
        case .new:
            let fresh = AgentThread(target: thread.target)
            modelContext.insert(fresh)
        case .clear:
            showClearConfirm = true
        case .compact:
            controller.compactNow(thread)
        case .stop:
            controller.cancel(threadID: threadID)
        }
    }

    /// Dropped files become paths in the draft — the tools take paths, so
    /// "transcribe /Users/…/a.mp4" is what the agent can actually act on.
    private func handleDrop(_ urls: [URL]) -> Bool {
        let paths = urls.map(\.path).joined(separator: " ")
        var draft = controller.run(for: threadID).input
        if !draft.isEmpty, !draft.hasSuffix(" ") { draft += " " }
        controller.setInput(draft + paths, for: threadID)
        return true
    }

    // MARK: - Review sheet

    @ViewBuilder
    private func reviewSheet(_ row: AgentMessage) -> some View {
        // The row's own project, falling back to the thread's target for rows
        // written before that was recorded. A thread can retarget mid-life, and
        // the changes still belong to the project they were proposed against.
        if let proposal = row.proposal,
           let uuid = row.proposalProjectUUID ?? thread.target.projectUUID,
           let documentContext = ProjectDocumentController.shared
               .document(for: thread)?.container.mainContext,
           let project = try? MCPCaptionHandlers.fetchCaption(
               id: uuid.uuidString,
               context: documentContext
           )
        {
            CaptionAIReviewSheet(project: project, proposal: proposal) { applied in
                controller.recordProposalOutcome(
                    applied: applied,
                    for: row,
                    context: modelContext
                )
            }
        } else {
            // Sized and dismissable: a bare `ContentUnavailableView` in a sheet
            // collapses to an almost empty panel with no way out of it.
            VStack(spacing: 16) {
                ContentUnavailableView(
                    "Caption Project Unavailable",
                    systemImage: "captions.bubble",
                    description: Text("The project these changes apply to is no longer available.")
                )
                Button("Close") { reviewingRow = nil }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            .frame(minWidth: 360, minHeight: 260)
        }
    }
}

// MARK: - Slash commands

enum AgentSlashCommand: String, CaseIterable, Identifiable {
    case new
    case clear
    case compact
    case stop

    var id: String { rawValue }
    var command: String { "/\(rawValue)" }

    var summary: String {
        switch self {
        case .new: "Start a new thread"
        case .clear: "Delete every message in this thread"
        case .compact: "Fold older turns into the summary now"
        case .stop: "Stop the running turn"
        }
    }

    var systemImage: String {
        switch self {
        case .new: "square.and.pencil"
        case .clear: "trash"
        case .compact: "arrow.down.right.and.arrow.up.left"
        case .stop: "stop.fill"
        }
    }
}


// MARK: - Theme

extension AgentTheme {
    /// The agent window's look.
    ///
    /// Both grounds are clear so the conversation sits directly on the window's
    /// own material rather than on a slab of its own — the composer already
    /// floats over the transcript, and a second opaque layer behind it flattens
    /// that back out.
    static let filmStudio: AgentTheme = {
        var theme = AgentTheme.compact
        theme.background = .clear
        theme.listBackground = .clear
        return theme
    }()
}
