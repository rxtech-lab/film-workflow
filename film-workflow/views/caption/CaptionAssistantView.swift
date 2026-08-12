import SwiftData
import SwiftUI

/// The caption assistant's conversation pane.
///
/// Ported from `RemotionChatView`, minus the macOS gate and the Markdown
/// renderer — caption replies are a couple of plain sentences, and a proposal
/// card carries anything structural.
struct CaptionAssistantView: View {
    @Bindable var project: CaptionProject
    /// Captions selected in the editor, so "shorten this one" has a referent.
    var selection: Set<UUID> = []

    @Environment(\.modelContext) private var modelContext
    @Environment(CaptionAssistantController.self) private var controller

    @State private var showClearConfirm = false
    @State private var availability = CaptionAIAvailability.shared

    private var projectID: UUID { project.projectUUID }
    private var session: CaptionAssistantController.Session { controller.session(for: projectID) }
    private var messages: [CaptionAssistantMessage] { project.orderedAssistantMessages }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            if let error = session.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
            Divider()
            composer
        }
        .confirmationDialog(
            "Clear this conversation?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) { clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The captions themselves are not affected.")
        }
        .sheet(item: Binding(
            get: { session.pendingProposal },
            set: { controller.setPendingProposal($0, for: projectID) }
        )) { proposal in
            CaptionAIReviewSheet(project: project, proposal: proposal)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Caption Assistant")
                .font(.headline)

            Spacer()

            backendMenu

            Button {
                showClearConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(messages.isEmpty)
            .help("Clear this conversation")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Per-conversation engine choice. Useful when the on-device model is
    /// struggling with a long transcript and you want to hand one question to a
    /// bigger model without changing the app-wide default.
    private var backendMenu: some View {
        Menu {
            ForEach(CaptionAIBackend.supported) { backend in
                Button {
                    controller.setBackendOverride(
                        backend == CaptionSettings.shared.aiBackend ? nil : backend,
                        for: projectID
                    )
                } label: {
                    if backend == controller.backend(for: project) {
                        Label(backend.displayName, systemImage: "checkmark")
                    } else {
                        Text(backend.displayName)
                    }
                }
            }
        } label: {
            Label {
                Text(controller.backend(for: project).displayName)
            } icon: {
                Image(systemName: "sparkles")
            }
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if messages.isEmpty {
                    placeholder
                }
                ForEach(messages) { message in
                    row(message)
                        .id(message.id)
                }
                if session.isSending {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .scrollTargetLayout()
        }
        .defaultScrollAnchor(.bottom)
        .scrollPosition(id: Binding(
            get: { session.scrollAnchor },
            set: { controller.setScrollAnchor($0, for: projectID) }
        ))
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask for changes in plain language.")
                .font(.callout)
            Text("""
                “merge captions 12 and 13”, “fix every RxLab spelling”, “split #4 so the second \
                line isn't so long”.
                """)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private func row(_ message: CaptionAssistantMessage) -> some View {
        switch message.kindEnum {
        case .proposal:
            proposalCard(message)
        case .tool:
            toolCard(message)
        case .text:
            if message.roleEnum == .user {
                HStack {
                    Spacer(minLength: 40)
                    Text(message.content)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                        .textSelection(.enabled)
                }
            } else {
                Text(message.content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func proposalCard(_ message: CaptionAssistantMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(message.content.isEmpty ? "Proposed changes" : message.content)
            } icon: {
                Image(systemName: "checklist")
            }
            .font(.callout)

            if let proposal = message.proposal {
                Button("Review \(proposal.items.count) changes…") {
                    controller.setPendingProposal(proposal, for: projectID)
                }
                .buttonStyle(.bordered)
            } else {
                Text("This proposal can no longer be read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.10))
        )
    }

    private func toolCard(_ message: CaptionAssistantMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            switch message.toolStatusEnum {
            case .pending:
                ProgressView().controlSize(.small)
            case .failed:
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
            case .ok, nil:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(message.toolName ?? "tool")
                    .font(.caption.monospaced())
                if let result = message.toolResult, !result.isEmpty {
                    Text(result.prefix(200))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                "Ask for a change…",
                text: Binding(
                    get: { session.input },
                    set: { controller.setInput($0, for: projectID) }
                ),
                axis: .vertical
            )
            .lineLimit(1...4)
            .textFieldStyle(.plain)
            .onSubmit(send)

            if session.isSending {
                Button {
                    controller.cancel(projectID: projectID)
                } label: {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(session.input.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func send() {
        controller.send(
            instruction: session.input,
            project: project,
            selection: selection,
            context: modelContext
        )
    }

    private func clearAll() {
        for message in project.assistantMessages {
            modelContext.delete(message)
        }
        project.assistantMessages = []
        project.assistantSummary = ""
        controller.clear(projectID: projectID)
    }
}

/// Scene id for the assistant window, shared by the scene declaration and every
/// `openWindow` call so a typo can't silently open nothing.
nonisolated enum CaptionAssistantWindowID {
    static let value = "caption-assistant"
}

/// Hosts the assistant in its own window, resolving the project from the id the
/// window scene carries.
///
/// The scene payload has to be `Codable`+`Hashable`, and this codebase
/// deliberately never uses `PersistentIdentifier` for cross-boundary references
/// (see `CaptionProject.projectUUID`) — so the window carries a plain UUID and
/// looks the project up here.
struct CaptionAssistantWindow: View {
    let projectUUID: UUID?

    @Environment(\.modelContext) private var modelContext
    @Query private var projects: [CaptionProject]

    init(projectUUID: UUID?) {
        self.projectUUID = projectUUID
        if let projectUUID {
            _projects = Query(filter: #Predicate<CaptionProject> { $0.projectUUID == projectUUID })
        } else {
            // An empty predicate would fetch everything; fetch nothing instead.
            _projects = Query(filter: #Predicate<CaptionProject> { _ in false })
        }
    }

    var body: some View {
        if let project = projects.first {
            CaptionAssistantView(project: project)
                .navigationTitle(project.name)
        } else {
            ContentUnavailableView(
                "No Caption Project",
                systemImage: "captions.bubble",
                description: Text("Open the assistant from a caption project.")
            )
        }
    }
}
