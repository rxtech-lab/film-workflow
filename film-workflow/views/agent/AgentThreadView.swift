import SwiftData
import SwiftUI

/// One thread's transcript and composer.
struct AgentThreadView: View {
    @Bindable var thread: AgentThread
    let targets: [AgentTargetOption]

    @Environment(\.modelContext) private var modelContext
    @Environment(AgentController.self) private var controller

    @State private var isAtBottom = true
    @State private var shouldScrollToBottom = false
    @State private var scrollRequestTask: Task<Void, Never>?
    @State private var reviewingProposal: CaptionEditProposal?
    @State private var showClearConfirm = false
    @State private var composerHeight: CGFloat = 80

    private var threadID: UUID { thread.id }
    private var run: AgentController.Run { controller.run(for: threadID) }
    private var messages: [AgentMessage] { thread.orderedMessages }
    private var isStreaming: Bool { run.isSending }

    var body: some View {
        ZStack(alignment: .bottom) {
            transcript
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentMargins(.top, 16, for: .scrollContent)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    composerArea
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            composerHeight = $0
                        }
                }

            if isStreaming {
                TypingIndicator()
                    .padding(.horizontal, 18)
                    .padding(.bottom, composerHeight + 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
            }
        }
        .confirmationDialog(
            "Clear this conversation?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) { clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your projects are not affected.")
        }
        .sheet(item: $reviewingProposal) { proposal in
            reviewSheet(proposal)
        }
        .onChange(of: messages.count) { _, _ in
            requestScrollToBottom()
        }
        .onChange(of: isStreaming) { _, streaming in
            guard !streaming else { return }
            controller.markSeen(threadID)
        }
        .onAppear {
            controller.markSeen(threadID)
            requestScrollToBottom(animated: false)
        }
        .onDisappear { scrollRequestTask?.cancel() }
    }

    private var composerArea: some View {
        VStack(spacing: 0) {
            if let error = run.errorMessage {
                errorBar(error)
            }
            AgentComposer(
                thread: thread,
                targets: targets,
                isStreaming: isStreaming,
                onSend: send,
                onStop: { controller.cancel(threadID: threadID) },
                onCommand: handle
            )
        }
        .background(.regularMaterial)
        .shadow(color: .black.opacity(0.08), radius: 8, y: -2)
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcript: some View {
        if messages.isEmpty {
            placeholder
        } else {
            MessageList(
                messages: messages,
                isStreaming: isStreaming,
                shouldScrollToBottom: shouldScrollToBottom,
                isAtBottom: $isAtBottom
            ) { message in
                AgentMessageRow(message: message) { proposal in
                    reviewingProposal = proposal
                }
                .padding(.horizontal, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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

    @ViewBuilder
    private func reviewSheet(_ proposal: CaptionEditProposal) -> some View {
        if let uuid = thread.target.projectUUID,
           let project = try? MCPCaptionHandlers.fetchCaption(
               id: uuid.uuidString,
               context: modelContext
           )
        {
            CaptionAIReviewSheet(project: project, proposal: proposal) { _ in
                controller.setPendingProposal(nil, forProjectUUID: uuid)
            }
        } else {
            ContentUnavailableView(
                "Caption Project Unavailable",
                systemImage: "captions.bubble",
                description: Text("The project these changes apply to is no longer available.")
            )
        }
    }

    // MARK: - Scrolling

    /// Coalesces scroll requests.
    ///
    /// Streaming appends rows in bursts; cancelling and reallocating a task —
    /// plus toggling the flag false→true — on every one is pure churn. The
    /// `MessageList` treats this as an edge trigger, hence the toggle.
    private func requestScrollToBottom(animated: Bool = true) {
        if scrollRequestTask != nil { return }
        shouldScrollToBottom = false
        scrollRequestTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(10))
            guard !Task.isCancelled else { return }
            scrollRequestTask = nil
            shouldScrollToBottom = true
        }
    }

    // MARK: - Actions

    private func send() {
        controller.send(
            instruction: run.input,
            thread: thread,
            context: modelContext,
            container: modelContext.container
        )
    }

    private func handle(_ command: AgentSlashCommand) {
        switch command {
        case .new:
            let fresh = AgentThread(target: thread.target)
            modelContext.insert(fresh)
        case .clear:
            showClearConfirm = true
        case .compact:
            compactNow()
        case .stop:
            controller.cancel(threadID: threadID)
        }
    }

    private func clearAll() {
        controller.cancel(threadID: threadID)
        for message in thread.messages {
            modelContext.delete(message)
        }
        thread.messages = []
        thread.summary = ""
        // The CLI backends keep their own copy of the history; a resume after
        // clearing would bring back everything the user just deleted.
        thread.clearProviderSessionIDs()
    }

    /// Marks every replayable turn compacted, so the next request sends only the
    /// summary. Cheap, immediate, and reversible by clearing the thread.
    private func compactNow() {
        let live = thread.liveTextMessages
        guard live.count > CaptionAIContext.verbatimTurns else { return }
        let cutoff = live.count - CaptionAIContext.verbatimTurns
        let folded = live.prefix(cutoff)
        let text = folded.map { "\($0.roleEnum.rawValue): \($0.content)" }.joined(separator: "\n")
        thread.summary = String((thread.summary + "\n" + text).suffix(600))
        for message in folded {
            message.isCompacted = true
        }
    }
}

private struct TypingIndicator: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0 ..< 3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 7, height: 7)
                    .scaleEffect(animate ? 1.0 : 0.5)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.15),
                        value: animate
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        .onAppear { animate = true }
    }
}
