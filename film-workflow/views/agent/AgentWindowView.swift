import SwiftData
import SwiftUI

/// Scene id for the agent window, shared by the scene declaration and every
/// `openWindow` call so a typo can't silently open nothing.
nonisolated enum AgentWindowID {
    static let value = "agent"
}

/// The system-wide agent window.
///
/// One window for the whole app rather than one per project. It follows the
/// context you came from — opening it while a caption project is selected
/// starts a thread aimed at that project — but every thread keeps its own
/// target, so retargeting the window never disturbs work already in flight.
struct AgentWindowView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AgentController.self) private var controller

    @Query(sort: \AgentThread.updatedAt, order: .reverse)
    private var threads: [AgentThread]

    @Query private var captionProjects: [CaptionProject]
    @Query private var musicProjects: [MusicProject]
    @Query private var narrativeProjects: [NarrativeProject]
    @Query private var imageProjects: [ImageGenProject]
    #if os(macOS)
        @Query private var remotionProjects: [RemotionProject]
    #endif

    @State private var selectedThreadID: UUID?
    @State private var pendingThreadDeletion: AgentThread?
    @State private var navigation = AppNavigation.shared

    private var selectedThread: AgentThread? {
        guard let selectedThreadID else { return threads.first }
        return threads.first { $0.id == selectedThreadID } ?? threads.first
    }

    /// Newest first, pinned above everything.
    private var orderedThreads: [AgentThread] {
        threads.sorted {
            $0.isPinned == $1.isPinned ? $0.updatedAt > $1.updatedAt : $0.isPinned
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let thread = selectedThread {
                AgentThreadView(thread: thread, targets: targetOptions)
                    .id(thread.id)
            } else {
                ContentUnavailableView {
                    Label("No Threads", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Start a thread to work with the agent.")
                } actions: {
                    Button("New Thread") { newThread() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar {
            ToolbarItemGroup {
                threadsMenu
                targetMenu
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    selectedThread?.isPinned.toggle()
                } label: {
                    Image(systemName: selectedThread?.isPinned == true ? "pin.fill" : "pin")
                }
                .disabled(selectedThread == nil)
                .help(selectedThread?.isPinned == true ? "Unpin this thread" : "Pin this thread")
                Button(action: newThread) {
                    Image(systemName: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("New thread")
            }
        }
        .task {
            if threads.isEmpty { newThread() }
        }
        .onChange(of: selectedThreadID) { _, newValue in
            guard let newValue else { return }
            controller.markSeen(newValue)
        }
        .confirmationDialog(
            "Delete this agent thread?",
            isPresented: Binding(
                get: { pendingThreadDeletion != nil },
                set: { if !$0 { pendingThreadDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingThreadDeletion
        ) { thread in
            Button("Delete Thread", role: .destructive) {
                delete(thread)
                pendingThreadDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingThreadDeletion = nil }
        } message: { _ in
            Text("Every message and the saved summary in this thread will be permanently deleted. Projects are not affected.")
        }
    }

    // MARK: - Toolbar menus

    private var threadsMenu: some View {
        Menu {
            ForEach(orderedThreads) { thread in
                Button {
                    selectedThreadID = thread.id
                } label: {
                    Label {
                        Text(threadMenuLabel(thread))
                    } icon: {
                        Image(systemName: threadIcon(thread))
                    }
                }
            }
            if let thread = selectedThread {
                Divider()
                Button("Delete This Thread", role: .destructive) {
                    pendingThreadDeletion = thread
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet")
                Text("Threads")
                if controller.runningCount > 0 {
                    Text("\(controller.runningCount)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(.white)
                }
            }
            .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func threadMenuLabel(_ thread: AgentThread) -> String {
        let name = AgentTargetResolver.name(for: thread.target, context: modelContext)
        guard let name else { return thread.displayTitle }
        return "\(thread.displayTitle)  ·  \(name)"
    }

    /// Running, finished-but-unseen, or idle — the same three states rxcode's
    /// sidebar shows, so a background thread finishing is visible without
    /// switching to it.
    private func threadIcon(_ thread: AgentThread) -> String {
        if controller.isRunning(thread.id) { return "circle.dotted" }
        if controller.run(for: thread.id).hasUnseenCompletion { return "circle.fill" }
        return thread.id == selectedThread?.id ? "checkmark" : "circle"
    }

    private var targetMenu: some View {
        Menu {
            Button {
                selectedThread?.target = .none
            } label: {
                Text("No project")
            }
            ForEach(AgentTargetKind.selectable.filter { $0 != .none }, id: \.self) { kind in
                let options = targetOptions.filter { $0.kind == kind }
                if !options.isEmpty {
                    Section(kind.displayName) {
                        ForEach(options) { option in
                            Button {
                                selectedThread?.target = AgentTarget(
                                    kind: option.kind,
                                    projectUUID: option.projectUUID
                                )
                            } label: {
                                Text(option.name)
                            }
                        }
                    }
                }
            }
        } label: {
            let target = selectedThread?.target ?? .none
            Label {
                if let name = AgentTargetResolver.name(for: target, context: modelContext) {
                    Text(name)
                } else {
                    Text("No project")
                }
            } icon: {
                Image(systemName: target.kind.systemImage)
            }
            .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Targets

    /// Every project the agent can be pointed at.
    ///
    /// Ids come from the same helpers MCP uses (`CaptionProject.projectUUID`,
    /// `RemotionProject.id`, `MCPProjectHandlers.stableID` for the rest), so the
    /// id shown here is the id the tools accept.
    private var targetOptions: [AgentTargetOption] {
        var options: [AgentTargetOption] = []

        options += captionProjects.map {
            AgentTargetOption(kind: .caption, projectUUID: $0.projectUUID, name: $0.name)
        }
        options += musicProjects.map {
            AgentTargetOption(
                kind: .music,
                projectUUID: MCPProjectHandlers.stableID(of: $0),
                name: $0.name
            )
        }
        options += narrativeProjects.map {
            AgentTargetOption(
                kind: .narrative,
                projectUUID: MCPProjectHandlers.stableID(of: $0),
                name: $0.name
            )
        }
        options += imageProjects.map {
            AgentTargetOption(
                kind: .imageGen,
                projectUUID: MCPProjectHandlers.stableID(of: $0),
                name: $0.name
            )
        }
        #if os(macOS)
            options += remotionProjects.map {
                AgentTargetOption(kind: .remotion, projectUUID: $0.id, name: $0.name)
            }
        #endif

        return options.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Actions

    private func newThread() {
        // A new thread inherits whatever the app is currently showing; existing
        // threads keep their own target.
        let thread = AgentThread(target: navigation.currentTarget)
        modelContext.insert(thread)
        selectedThreadID = thread.id
    }

    private func delete(_ thread: AgentThread) {
        controller.clear(threadID: thread.id)
        modelContext.delete(thread)
        selectedThreadID = orderedThreads.first { $0.id != thread.id }?.id
    }
}
