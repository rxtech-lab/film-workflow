import Foundation
import Observation
import RxAgentSDK
import SwiftData
import os

/// Posted after a tool call that changed the library, so a view showing the
/// item can refresh.
extension Notification.Name {
    static let agentDidMutateProject = Notification.Name("agentDidMutateProject")
}

/// Owns every in-flight agent turn.
///
/// Keyed by **thread**, not by library item, which is the whole reason threads exist:
/// a Remotion turn and a caption turn can be streaming at the same time, and
/// closing the agent window must not cancel either.
///
/// After the RxAgentSDK migration this is a much smaller object. It used to hold
/// the event-to-transcript reducer, the backend dispatch switch, the history
/// replay and the compaction loop; all four now live in `RxAgentSDK.Agent`, one
/// instance per thread. What is left is the three things the SDK cannot know
/// about: **SwiftData persistence**, **caption proposals**, and **which of this
/// app's five engines a thread is pinned to**.
@MainActor
@Observable
final class AgentController {
    static let shared = AgentController()

    @ObservationIgnored private let logger = Logger(subsystem: "rxlab.film-workflow", category: "Agent")

    struct Run {
        var input: String = ""
        var errorMessage: String?
        /// Set when a turn finishes on a thread the user isn't looking at, so
        /// the thread menu can show a "done" dot.
        var hasUnseenCompletion: Bool = false
    }

    private var runs: [UUID: Run] = [:]

    /// One SDK agent per open thread. Created lazily and kept, because a thread
    /// the user switches away from must keep streaming.
    ///
    /// Deliberately *not* `@ObservationIgnored`: the thread view asks for its
    /// agent in `body`, so it has to be told when one appears.
    private var agents: [UUID: Agent] = [:]

    /// MCP holds taken per thread, released when the thread's agent is torn
    /// down. The server is refcounted, so overlapping threads share one.
    @ObservationIgnored private var mcpHolds: Set<UUID> = []

    /// Caption proposals waiting for review, keyed by the captions item they
    /// apply to.
    ///
    /// Keyed by item rather than thread because a proposal can arrive from a
    /// CLI engine, whose tool call comes in over HTTP with no idea which thread
    /// it belongs to. The item id is the only thing both paths know.
    private var proposalsByProject: [UUID: CaptionEditProposal] = [:]

    /// The last config `agent(for:context:container:)` loaded.
    ///
    /// The keychain read is not free and the engine menu needs the same answer
    /// in `body`, so the value is kept rather than re-read. Observed, so a menu
    /// that drew before the first load refreshes once it lands.
    private(set) var lastConfig: AppConfig?

    private init() {}

    // MARK: - Run access

    func run(for threadID: UUID) -> Run {
        runs[threadID] ?? Run()
    }

    func isRunning(_ threadID: UUID) -> Bool {
        agents[threadID]?.phase.isBusy ?? false
    }

    var runningCount: Int {
        agents.reduce(into: 0) { $0 += ($1.value.phase.isBusy ? 1 : 0) }
    }

    func setInput(_ text: String, for threadID: UUID) {
        mutate(threadID) { $0.input = text }
    }

    func setError(_ message: String?, for threadID: UUID) {
        mutate(threadID) { $0.errorMessage = message }
    }

    func markSeen(_ threadID: UUID) {
        guard runs[threadID]?.hasUnseenCompletion == true else { return }
        mutate(threadID) { $0.hasUnseenCompletion = false }
    }

    private func mutate(_ threadID: UUID, _ body: (inout Run) -> Void) {
        var run = runs[threadID] ?? Run()
        body(&run)
        runs[threadID] = run
    }

    // MARK: - Agents

    /// The live agent for `thread`, if one has been built.
    ///
    /// Non-throwing and non-async so a view body can ask. `prepare(thread:)`
    /// is what actually builds one.
    func agent(for thread: AgentThread) -> Agent? {
        agents[thread.id]
    }

    /// Builds the thread's agent if it doesn't have one yet, and applies the
    /// thread's current engine, model and policy to it either way.
    ///
    /// Called from `.task` when a thread appears, so the transcript, the MCP
    /// server and the engine are ready before the user types rather than after
    /// they hit send — and again whenever the thread's engine or model pick
    /// changes, because the SDK composer sends without coming back through
    /// this controller.
    func prepare(thread: AgentThread, context: ModelContext) async {
        _ = await MarketplaceAuthoringService.shared.refreshAccess()
        let container = ProjectDocumentController.shared.document(for: thread)?.container
            ?? ProjectDocumentController.shared.activeDocument?.container

        do {
            _ = try await agent(for: thread, context: context, container: container)
        } catch {
            setError(error.localizedDescription, for: thread.id)
        }
    }

    func cancel(threadID: UUID) {
        agents[threadID]?.stop()
    }

    /// Tears a thread's agent down, releasing its MCP hold and any child process.
    func clear(threadID: UUID) {
        guard let agent = agents.removeValue(forKey: threadID) else {
            runs[threadID] = nil
            return
        }
        runs[threadID] = nil
        releaseMCP(threadID: threadID)
        Task { await agent.shutdown() }
    }

    // MARK: - Backend resolution

    func backend(for thread: AgentThread) -> AgentBackend {
        thread.backendOverride ?? AgentSettings.shared.defaultBackend
    }

    /// The model a thread's next turn will run on for `backend`: its own pin,
    /// else the one Settings names for that engine.
    ///
    /// Reads `lastConfig` rather than the keychain because the engine menu asks
    /// in `body` — `prepare(thread:context:)` refreshes it whenever a thread
    /// appears or its pick changes, which is exactly when the answer can move.
    func effectiveModel(for thread: AgentThread, backend: AgentBackend) -> String {
        let pinned = thread.modelOverride(for: backend)?.trimmingCharacters(in: .whitespaces)
        if let pinned, !pinned.isEmpty { return pinned }
        return backend.model(config: lastConfig)
    }

    /// Thinking levels the engine menu should offer for a thread, given the
    /// model it will actually use. Empty for an engine with no such dial.
    func thinkingLevels(for thread: AgentThread, backend: AgentBackend) -> [String] {
        AgentModelCatalog.shared.efforts(
            for: backend,
            model: effectiveModel(for: thread, backend: backend)
        )
    }

    /// The level the *next turn* would send with nothing pinned on the thread —
    /// what the menu's "Engine default" row actually means right now.
    func settingsThinkingLevel(for thread: AgentThread, backend: AgentBackend) -> String? {
        AgentModelCatalog.shared.effort(
            for: effectiveModel(for: thread, backend: backend),
            backend: backend,
            override: nil,
            configured: backend.reasoningEffort(config: lastConfig)
        )
    }

    // MARK: - Proposals

    /// Called by `MCPCaptionHandlers.caption_propose_edits`, from either an
    /// in-process client or a CLI agent over HTTP.
    func setPendingProposal(_ proposal: CaptionEditProposal?, forProjectUUID projectUUID: UUID) {
        if let proposal {
            proposalsByProject[projectUUID] = proposal
        } else {
            proposalsByProject.removeValue(forKey: projectUUID)
        }
    }

    func pendingProposal(forProjectUUID projectUUID: UUID?) -> CaptionEditProposal? {
        guard let projectUUID else { return nil }
        return proposalsByProject[projectUUID]
    }

    /// Records what the user did with a proposal, on the row and in the thread.
    ///
    /// Both halves matter. The row keeps the card honest — it said "Review 1
    /// change…" whether or not the change had been applied. The transcript line
    /// is what the *model* sees on the next turn: without it the agent has no
    /// way to know its proposal was approved, and goes on describing settled
    /// work as pending.
    func recordProposalOutcome(
        applied: Int,
        for message: AgentMessage,
        context: ModelContext
    ) {
        message.proposalAppliedCount = applied
        if let projectUUID = message.proposalProjectUUID ?? message.thread?.target.projectUUID {
            setPendingProposal(nil, forProjectUUID: projectUUID)
        }

        guard let thread = message.thread else { return }
        let total = message.proposal?.items.count ?? applied
        let note = applied == 0
            ? "The user reviewed your proposed changes and applied none of them."
            : "The user applied \(applied) of \(total) proposed change\(total == 1 ? "" : "s")."

        let row = AgentTranscriptStore.append(
            role: .system,
            content: note,
            to: thread,
            context: context
        )
        // The SDK thread carries what the model replays, so the note has to
        // reach it too — not just the persisted transcript.
        agents[thread.id]?.thread.appendUserMessage(note)
        _ = row
    }

    // MARK: - Sending

    func send(
        instruction: String,
        thread: AgentThread,
        context: ModelContext,
        container: ModelContainer?
    ) {
        let threadID = thread.id
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        mutate(threadID) {
            $0.input = ""
            $0.errorMessage = nil
            $0.hasUnseenCompletion = false
        }

        Task { @MainActor in
            do {
                _ = await MarketplaceAuthoringService.shared.refreshAccess()
                let agent = try await agent(
                    for: thread,
                    context: context,
                    container: container
                )

                // Persist the user's turn before starting, so it survives a
                // crash. The SDK appends its own copy to the live transcript;
                // reusing the id is what stops `persistTurnEnd` writing a
                // duplicate row at the end of the turn.
                let queuedBehind = agent.phase.isBusy
                agent.send(trimmed)
                if !queuedBehind,
                   let sent = agent.thread.messages.last(where: { $0.role == .user }) {
                    AgentTranscriptStore.append(
                        role: .user,
                        content: trimmed,
                        id: sent.id,
                        to: thread,
                        context: context
                    )
                }
            } catch {
                setError(error.localizedDescription, for: threadID)
            }
        }
    }

    // MARK: - Agent construction

    /// The SDK agent for `thread`, built on first use and reconfigured each turn.
    ///
    /// Reconfigured rather than rebuilt because the transcript lives on the
    /// agent: settings that can change between turns (the engine, the model, the
    /// write policy, the target) are written onto the existing instance, so
    /// switching engines mid-thread keeps the conversation.
    private func agent(
        for thread: AgentThread,
        context: ModelContext,
        container: ModelContainer?
    ) async throws -> Agent {
        let config = try? AppConfig.loadFromKeychain()
        lastConfig = config
        let preferred = backend(for: thread)
        let resolved = try AgentBackendAvailability.shared.resolved(
            preferred: preferred,
            config: config,
            for: .conversation
        )

        let agent: Agent
        if let existing = agents[thread.id] {
            agent = existing
        } else {
            agent = try await makeAgent(
                thread: thread,
                config: config,
                container: container
            )
            agents[thread.id] = agent
        }

        configure(
            agent: agent,
            thread: thread,
            backend: resolved,
            config: config,
            container: container
        )
        return agent
    }

    private func makeAgent(
        thread: AgentThread,
        config: AppConfig?,
        container: ModelContainer?
    ) async throws -> Agent {
        let clients = AgentClientFactory.makeClients(config: config)
        guard !clients.isEmpty else { throw CaptionAIError.noBackendAvailable }

        // Catalog and authoring tools also work without an open film.
        var mcpServers: [MCPServerSpec] = []
        #if os(macOS)
            let document = container.flatMap { ProjectDocumentController.shared.document(forContainer: $0) }
            mcpServers.append(try await AgentMCPBridge.acquire(documentID: document?.id))
            mcpHolds.insert(thread.id)
        #endif

        let agent = Agent(
            clients: clients,
            mcpServers: mcpServers,
            workingDirectory: workingDirectory(for: thread),
            // There is no approval UI here, and deliberately so: the agent's
            // whole surface is this app's own MCP tools, and the write policy
            // is the user's standing answer about which of them may run. The
            // resolver says yes to exactly that set and no to everything else.
            //
            // Not `DenyAllPermissions`: Claude Code's approval hook fires for
            // every MCP call ahead of `--allowedTools`, so a blanket deny
            // refused the pre-approved tools too.
            //
            // `.default` rather than `.bypassPermissions` is load-bearing:
            // bypass turns off the very pipeline that carries `--allowedTools`,
            // which would hand a coding agent an unscoped shell.
            permissions: AgentPolicyPermissions(),
            permissionMode: .default
        )

        agent.resume(AgentTranscriptStore.load(thread))
        agent.autoCompact = Agent.AutoCompact(
            afterMessages: CaptionAIContext.verbatimTurns * 3,
            keepingLast: CaptionAIContext.verbatimTurns
        )
        agent.summarizer = Self.makeSummarizer(config: config)
        agent.onEvent = { [weak self] event in
            self?.record(event, thread: thread)
        }
        return agent
    }

    /// Applies everything that can change between turns.
    private func configure(
        agent: Agent,
        thread: AgentThread,
        backend: AgentBackend,
        config: AppConfig?,
        container: ModelContainer?
    ) {
        let clientID = AgentClientFactory.clientID(for: backend)
        if agent.activeClientID != clientID {
            agent.select(clientID)
        }

        // The thread's own pick wins over Settings, then the engine's default.
        // Always the engine's own model field: `openAIModel` and
        // `claudeCodeModel` name models in different namespaces, and passing a
        // `gpt-4o` meant for the endpoint to `claude --model` cannot work.
        let pinned = thread.modelOverride(for: backend)?.trimmingCharacters(in: .whitespaces)
        let model = (pinned?.isEmpty == false ? pinned! : backend.model(config: config))
        agent.model = model.isEmpty ? nil : model

        // The thread's own pick wins over Settings here too, and both are
        // dropped when the thread's model doesn't accept the level: the levels
        // differ between Codex models, and a thread can be re-pointed at a model
        // after a level was chosen.
        let effort = AgentModelCatalog.shared.effort(
            for: model,
            backend: backend,
            override: thread.effortOverride(for: backend),
            configured: backend.reasoningEffort(config: config)
        ) ?? ""
        agent.effort = effort.isEmpty ? nil : effort

        // Which engine the next turn actually runs on. `backend` here is the
        // *resolved* one, so this is also where a silent fallback from the
        // thread's pick becomes visible.
        let preferred = self.backend(for: thread)
        var summary = "Thread \(thread.id.uuidString) chats with \(backend.engineLabel)"
            + " (model: \(model.isEmpty ? "engine default" : model),"
            + " effort: \(effort.isEmpty ? "engine default" : effort))"
        if preferred != backend {
            summary += " — thread asked for \(preferred.engineLabel), which is unavailable"
        }
        logger.info("\(summary, privacy: .public)")

        let policy = AgentSettings.shared.writePolicy
        agent.allowedTools = AgentToolPolicy.toolNames(policy: policy)
        agent.disallowedTools = AgentToolPolicy.disallowedToolNames(policy: policy)
        agent.maxToolIterations = AgentSettings.shared.maxIterations
        agent.workingDirectory = workingDirectory(for: thread)

        agent.context = AgentPrompts.context(
            target: thread.target,
            toolNames: AgentToolPolicy.toolNames(policy: policy),
            policy: policy,
            context: container.map { ModelContext($0) },
            // A CLI agent namespaces every MCP tool it discovers; an in-process
            // client speaks MCP itself and sees the bare name. The prompt has to
            // list the names that engine will actually see.
            toolNamePrefix: backend.isCommandLine ? "mcp__\(AgentMCPBridge.serverKey)__" : ""
        )
    }

    /// The film package, so relative paths the agent mentions resolve to the
    /// film and Claude Code's project memory lands beside it.
    private func workingDirectory(for thread: AgentThread) -> URL {
        if let document = ProjectDocumentController.shared.document(for: thread) {
            return document.packageURL
        }
        return ProjectDocumentController.shared.activeDocument?.packageURL
            ?? FileStorage.appSupportURL
    }

    /// Compacts with an in-process engine even on a CLI thread: spawning a
    /// subprocess to compress history would cost more than the history does.
    private static func makeSummarizer(
        config: AppConfig?
    ) -> @Sendable (String, String) async -> String? {
        { existing, transcript in
            let prepared = await MainActor.run { () -> (any CaptionAIEngine, String)? in
                guard let backend = try? AgentBackendAvailability.shared.resolved(
                    preferred: .openAICompatible,
                    config: config,
                    for: .transcriptReview
                ),
                    let engine = try? CaptionAIEngineFactory.make(backend: backend, config: config)
                else { return nil }
                return (
                    engine,
                    AgentPrompts.summarizationInstruction(
                        existing: existing,
                        transcript: transcript
                    )
                )
            }
            guard let (engine, instruction) = prepared else { return nil }

            guard let reply = try? await engine.converse(CaptionChatRequest(
                instruction: instruction,
                summary: "",
                recentTurns: [],
                lines: [],
                totalLines: 0,
                speakers: [],
                terms: [],
                languageHint: ""
            )) else { return nil }

            let text = reply.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    private func releaseMCP(threadID: UUID) {
        #if os(macOS)
            guard mcpHolds.remove(threadID) != nil else { return }
            Task { await AgentMCPBridge.release() }
        #endif
    }

    // MARK: - Persistence

    /// Folds the live event stream into SwiftData rows.
    ///
    /// The SDK maintains the transcript the UI renders; this exists so the same
    /// transcript is still there after a relaunch. Row ids are taken from the
    /// SDK's message and tool-call ids so the two stay addressable by the same
    /// key — see `AgentTranscriptStore`.
    private func record(
        _ event: AgentEvent,
        thread: AgentThread
    ) {
        let context = thread.modelContext
        guard let context else { return }
        let threadID = thread.id

        switch event {
        case .turnStarted:
            mutate(threadID) {
                $0.errorMessage = nil
                $0.hasUnseenCompletion = false
            }
            persistTranscript(thread: thread, context: context)

        case .toolCallStarted(let id, let name):
            guard toolRow(callID: id, in: thread) == nil else { return }
            let row = AgentMessage(
                role: .assistant,
                content: "",
                kind: .tool,
                toolName: MCPToolName.bare(name),
                toolStatus: .pending,
                toolCallId: id
            )
            AgentTranscriptStore.attach(row, to: thread, context: context)
            persistTranscript(thread: thread, context: context)

        case .toolCallInput(let id, let input):
            toolRow(callID: id, in: thread)?.toolArgs = JSONValue.object(input).jsonString

        case .toolCallResult(let id, let content, let isError):
            if let row = toolRow(callID: id, in: thread) {
                row.toolResult = MCPMarketplaceHandlers.isMarketplaceTool(row.toolName ?? "") ? content : Self.summarize(content)
                row.toolStatusEnum = isError ? .failed : .ok
                surfaceProposalIfNeeded(
                    toolName: row.toolName,
                    isError: isError,
                    thread: thread,
                    context: context
                )
                if !isError, let name = row.toolName {
                    NotificationCenter.default.post(
                        name: .agentDidMutateProject,
                        object: nil,
                        userInfo: ["tool": name]
                    )
                }
            }
            persistTranscript(thread: thread, context: context)

        case .blockEnded, .messageEnded:
            persistTranscript(thread: thread, context: context)

        case .failed(let error):
            setError(error.description, for: threadID)
            // A failed CLI turn may never emit turnEnded. Keep its user input
            // and any session id so retrying or switching agents retains context.
            persistTurnEnd(thread: thread, context: context)

        case .turnEnded:
            persistTurnEnd(thread: thread, context: context)
            mutate(threadID) { $0.hasUnseenCompletion = true }

        default:
            break
        }
    }

    /// Snapshot at block/tool boundaries, avoiding a rewrite for every token
    /// while keeping completed prose interleaved with the calls around it.
    private func persistTranscript(thread: AgentThread, context: ModelContext) {
        guard let agent = agents[thread.id] else { return }
        AgentTranscriptStore.saveTranscript(from: agent.thread, to: thread, context: context)
    }

    private func persistTurnEnd(thread: AgentThread, context: ModelContext) {
        guard let agent = agents[thread.id] else { return }

        AgentTranscriptStore.saveTranscript(from: agent.thread, to: thread, context: context)
        AgentTranscriptStore.saveSessionIDs(from: agent.thread, to: thread)
        AgentTranscriptStore.saveCompaction(from: agent.thread, to: thread)
        thread.updatedAt = Date()
    }

    private func toolRow(callID: String, in thread: AgentThread) -> AgentMessage? {
        thread.messages.first { $0.kindEnum == .tool && $0.toolCallId == callID }
    }

    /// A successful propose call has parked a proposal keyed by project; surface
    /// it as a reviewable row in this thread.
    private func surfaceProposalIfNeeded(
        toolName: String?,
        isError: Bool,
        thread: AgentThread,
        context: ModelContext
    ) {
        guard !isError, toolName == "caption_propose_edits",
              let projectUUID = thread.target.projectUUID,
              let proposal = proposalsByProject[projectUUID]
        else { return }

        // The tool can be called more than once in a turn; don't stack identical
        // review rows for the same proposal.
        let alreadyShown = thread.messages.contains {
            $0.kindEnum == .proposal && $0.proposal?.id == proposal.id
        }
        guard !alreadyShown else { return }

        let row = AgentMessage(
            role: .assistant,
            content: proposal.summary,
            kind: .proposal,
            proposalJSON: proposal.encodedJSON(),
            proposalProjectUUID: projectUUID
        )
        AgentTranscriptStore.attach(row, to: thread, context: context)
    }

    /// One short line for the tool card in the transcript.
    private static func summarize(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > 200 ? String(collapsed.prefix(200)) + "…" : collapsed
    }

    // MARK: - Thread commands

    /// Deletes every message in a thread, here and in the SDK.
    func clearTranscript(_ thread: AgentThread, context: ModelContext) {
        cancel(threadID: thread.id)
        for message in thread.messages {
            context.delete(message)
        }
        thread.messages = []
        thread.transcriptJSON = nil
        thread.summary = ""
        // The CLI engines keep their own copy of the history; a resume after
        // clearing would bring back everything the user just deleted.
        thread.clearProviderSessionIDs()
        agents[thread.id]?.thread.clear()
    }

    /// Folds older turns into the summary now, without a model call.
    func compactNow(_ thread: AgentThread) {
        guard let agent = agents[thread.id] else { return }
        guard agent.thread.compactWithoutSummarizing(
            keepingLast: CaptionAIContext.verbatimTurns
        ) else { return }
        AgentTranscriptStore.saveCompaction(from: agent.thread, to: thread)
    }
}
