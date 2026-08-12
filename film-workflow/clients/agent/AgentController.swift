import Foundation
import Observation
import SwiftData

/// Owns every in-flight agent turn.
///
/// Keyed by **thread**, not by project, which is the whole reason threads exist:
/// a Remotion turn and a caption turn can be streaming at the same time, and
/// closing the agent window must not cancel either. Replaces the two
/// single-session controllers this descends from (`RemotionChatController` and
/// `CaptionAssistantController`), which could each run one conversation per
/// project and nothing across projects.
@MainActor
@Observable
final class AgentController {
    static let shared = AgentController()

    struct Run {
        var input: String = ""
        var isSending: Bool = false
        var errorMessage: String?
        var task: Task<Void, Never>?
        /// Turns typed while this one was streaming, sent in order afterwards.
        var queued: [String] = []
        /// Set when a turn finishes on a thread the user isn't looking at, so
        /// the thread menu can show a "done" dot.
        var hasUnseenCompletion: Bool = false
    }

    private var runs: [UUID: Run] = [:]

    /// Caption proposals waiting for review, keyed by the project they apply to.
    ///
    /// Keyed by project rather than thread because a proposal can arrive from a
    /// CLI backend, whose tool call comes in over HTTP with no idea which thread
    /// it belongs to. The project id is the only thing both paths know.
    private var proposalsByProject: [UUID: CaptionEditProposal] = [:]

    private init() {}

    // MARK: - Run access

    func run(for threadID: UUID) -> Run {
        runs[threadID] ?? Run()
    }

    func isRunning(_ threadID: UUID) -> Bool {
        runs[threadID]?.isSending ?? false
    }

    var runningThreadIDs: Set<UUID> {
        Set(runs.filter { $0.value.isSending }.keys)
    }

    var runningCount: Int {
        runs.reduce(into: 0) { $0 += ($1.value.isSending ? 1 : 0) }
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

    func cancel(threadID: UUID) {
        runs[threadID]?.task?.cancel()
        mutate(threadID) { $0.queued = [] }
    }

    func clear(threadID: UUID) {
        runs[threadID]?.task?.cancel()
        runs[threadID] = nil
    }

    private func mutate(_ threadID: UUID, _ body: (inout Run) -> Void) {
        var run = runs[threadID] ?? Run()
        body(&run)
        runs[threadID] = run
    }

    // MARK: - Queue

    /// Queues a turn typed while the thread was streaming.
    func enqueue(_ text: String, for threadID: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate(threadID) { $0.queued.append(trimmed) }
    }

    func removeQueued(at index: Int, for threadID: UUID) {
        mutate(threadID) {
            guard $0.queued.indices.contains(index) else { return }
            $0.queued.remove(at: index)
        }
    }

    func mergeQueued(for threadID: UUID) {
        mutate(threadID) {
            guard $0.queued.count > 1 else { return }
            $0.queued = [$0.queued.joined(separator: "\n\n")]
        }
    }

    // MARK: - Proposals

    /// Called by `MCPCaptionHandlers.caption_propose_edits`, from either the
    /// in-process runtime or a CLI agent over HTTP.
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
        let row = AgentMessage(role: .system, content: note)
        row.thread = thread
        context.insert(row)
        thread.messages.append(row)
        thread.updatedAt = Date()
    }

    // MARK: - Backend resolution

    func backend(for thread: AgentThread) -> AgentBackend {
        thread.backendOverride ?? AgentSettings.shared.defaultBackend
    }

    // MARK: - Sending

    func send(
        instruction: String,
        thread: AgentThread,
        context: ModelContext,
        container: ModelContainer
    ) {
        let threadID = thread.id
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Typing while a turn runs queues rather than interrupting it.
        guard !isRunning(threadID) else {
            enqueue(trimmed, for: threadID)
            setInput("", for: threadID)
            return
        }

        let config = try? AppConfig.loadFromKeychain()
        let preferred = backend(for: thread)

        let resolved: AgentBackend
        do {
            resolved = try AgentBackendAvailability.shared.resolved(
                preferred: preferred,
                config: config,
                for: .conversation
            )
        } catch {
            setError(error.localizedDescription, for: threadID)
            return
        }

        // Persist the user's turn before starting, so it survives a crash and is
        // on screen while the model thinks.
        let userMessage = AgentMessage(role: .user, content: trimmed)
        userMessage.thread = thread
        context.insert(userMessage)
        thread.messages.append(userMessage)
        thread.updatedAt = Date()

        mutate(threadID) {
            $0.input = ""
            $0.isSending = true
            $0.errorMessage = nil
            $0.hasUnseenCompletion = false
        }

        let policy = AgentSettings.shared.writePolicy
        let maxIterations = AgentSettings.shared.maxIterations

        let task = Task { @MainActor [weak self] in
            defer {
                if let self {
                    self.mutate(threadID) {
                        $0.isSending = false
                        $0.task = nil
                        $0.hasUnseenCompletion = true
                    }
                    self.drainQueue(thread: thread, context: context, container: container)
                }
            }

            do {
                try await self?.perform(
                    instruction: trimmed,
                    thread: thread,
                    backend: resolved,
                    policy: policy,
                    maxIterations: maxIterations,
                    config: config,
                    context: context,
                    container: container
                )
            } catch is CancellationError {
                // User pressed stop; nothing to report.
            } catch {
                self?.setError(error.localizedDescription, for: threadID)
            }
        }

        mutate(threadID) { $0.task = task }
    }

    /// Starts the next queued turn once the current one finishes.
    private func drainQueue(
        thread: AgentThread,
        context: ModelContext,
        container: ModelContainer
    ) {
        let threadID = thread.id
        guard runs[threadID]?.errorMessage == nil else { return }
        guard let next = runs[threadID]?.queued.first, !next.isEmpty else { return }
        mutate(threadID) { $0.queued.removeFirst() }
        send(instruction: next, thread: thread, context: context, container: container)
    }

    // MARK: - Turn execution

    private func perform(
        instruction: String,
        thread: AgentThread,
        backend: AgentBackend,
        policy: AgentWritePolicy,
        maxIterations: Int,
        config: AppConfig?,
        context: ModelContext,
        container: ModelContainer
    ) async throws {
        let (older, recent) = Self.partition(thread.liveTextMessages.dropLast())
        let request = AgentRunRequest(
            instruction: instruction,
            summary: thread.summary,
            recentTurns: recent,
            target: thread.target,
            policy: policy,
            maxIterations: maxIterations
        )

        switch backend {
        case .openAICompatible:
            guard let config else { throw AgentRuntimeError.missingLLMConfig }
            try await consume(
                AgentRuntime.run(request: request, config: config, container: container),
                thread: thread,
                context: context
            )

        case .claudeCode, .codex:
            #if os(macOS)
                try await runCLI(
                    request: request,
                    backend: backend,
                    thread: thread,
                    config: config,
                    context: context
                )
            #else
                throw CaptionAIError.backendUnavailable(backend, "Command-line agents need macOS.")
            #endif

        case .appleIntelligence:
            try await runOnDevice(
                request: request,
                thread: thread,
                config: config,
                context: context
            )
        }

        await compactIfNeeded(thread: thread, older: older, backend: backend, config: config)
    }

    #if os(macOS)
    private func runCLI(
        request: AgentRunRequest,
        backend: AgentBackend,
        thread: AgentThread,
        config: AppConfig?,
        context: ModelContext
    ) async throws {
        guard let executable = AgentBackendAvailability.shared.executablePath(for: backend) else {
            throw CaptionAIError.backendUnavailable(
                backend,
                "The \(backend.executableName) command isn't installed."
            )
        }

        let endpoint = try await AgentMCPBridge.acquire()
        defer { Task { await AgentMCPBridge.release() } }

        let resume = thread.providerSessionID(for: backend)
        // Resuming means the CLI already holds the history, so replaying ours
        // would duplicate it. Send just the new instruction in that case.
        let prompt = resume == nil
            ? AgentPrompts.turn(
                instruction: request.instruction,
                summary: request.summary,
                recentTurns: request.recentTurns
              )
            : request.instruction

        // The thread's own pick wins over Settings, then the CLI's own default.
        // Always the CLI's model field, never `openAIModel` — those name models
        // in different namespaces, and passing a `gpt-4o` meant for the endpoint
        // to `claude --model` cannot work.
        let model = thread.modelOverride(for: backend) ?? backend.model(config: config)

        let cliContext = AgentCLIRunner.Context(
            backend: backend,
            executable: executable,
            endpoint: endpoint,
            model: model,
            // Dropped when the thread's model doesn't accept it: effort is
            // configured once in Settings but the model can be overridden per
            // thread, and the levels differ between Codex models.
            reasoningEffort: AgentModelCatalog.shared.effort(
                for: model,
                configured: backend.reasoningEffort(config: config)
            ) ?? "",
            resumeSessionID: resume,
            systemPrompt: AgentPrompts.system(
                target: request.target,
                toolNames: AgentToolPolicy.toolNames(policy: request.policy),
                policy: request.policy,
                context: context,
                toolNamePrefix: "mcp__\(AgentMCPBridge.serverKey)__"
            ),
            prompt: prompt,
            policy: request.policy
        )

        try await consume(
            AgentCLIRunner.run(context: cliContext),
            thread: thread,
            context: context
        )
    }
    #endif

    /// Apple Intelligence has no tool calling and a ~2.5k-character budget, so
    /// it answers as text.
    ///
    /// For a caption target it still goes through the structured-edit path the
    /// caption assistant used, so choosing the on-device model doesn't silently
    /// lose the ability to propose caption changes — it just can't reach any
    /// other tool.
    private func runOnDevice(
        request: AgentRunRequest,
        thread: AgentThread,
        config: AppConfig?,
        context: ModelContext
    ) async throws {
        let engine = try CaptionAIEngineFactory.make(backend: .appleIntelligence, config: config)

        var lines: [CaptionAILine] = []
        var project: CaptionProject?
        if request.target.kind == .caption,
           let uuid = request.target.projectUUID,
           let found = try? MCPCaptionHandlers.fetchCaption(id: uuid.uuidString, context: context) {
            project = found
            lines = CaptionAIContext.lines(from: found.snapshot().segments)
        }

        let budget = max(
            AgentBackend.appleIntelligence.contextBudgetCharacters
                - request.instruction.count - request.summary.count - 400,
            300
        )

        let chatRequest = CaptionChatRequest(
            instruction: request.instruction,
            summary: request.summary,
            recentTurns: request.recentTurns.map {
                CaptionChatTurn(role: $0.role, content: $0.content)
            },
            lines: lines.isEmpty ? [] : CaptionAIContext.retrieve(
                query: request.instruction,
                lines: lines,
                selection: [],
                budget: budget
            ),
            totalLines: lines.count,
            speakers: project?.speakers ?? [],
            terms: project?.usableTerms ?? [],
            languageHint: project?.languageHint ?? ""
        )

        let reply = try await engine.converse(chatRequest)
        try Task.checkCancellation()

        let text = reply.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            appendAssistantText(text, thread: thread, context: context)
        }

        guard let project, !reply.edits.isEmpty else { return }
        let proposal = CaptionProposalMapping.proposal(
            from: reply.edits,
            lines: lines,
            transcript: project.snapshot(),
            terms: project.usableTerms,
            maxRunes: CaptionSettings.shared.maxCueRunes,
            engine: AgentBackend.appleIntelligence.engineLabel
        )
        guard let proposal, !proposal.isEmpty else { return }
        setPendingProposal(proposal, forProjectUUID: project.projectUUID)
        appendProposalRow(proposal, projectUUID: project.projectUUID, thread: thread, context: context)
    }

    // MARK: - Event consumption

    /// Turns an event stream into persisted transcript rows.
    ///
    /// Shared by every streaming backend so the transcript looks identical
    /// whichever engine produced it.
    private func consume(
        _ stream: AsyncThrowingStream<AgentEvent, Error>,
        thread: AgentThread,
        context: ModelContext
    ) async throws {
        var pendingTools: [String: AgentMessage] = [:]
        let backend = backend(for: thread)

        defer {
            // Anything still pending never got a result — a cancelled turn or a
            // stream that ended mid-call. Leaving it spinning forever would be
            // worse than marking it failed.
            for message in pendingTools.values {
                message.toolStatusEnum = .failed
                if message.toolResult == nil { message.toolResult = "no result" }
            }
        }

        for try await event in stream {
            try Task.checkCancellation()

            switch event {
            case .status:
                break

            case .sessionID(let id):
                thread.setProviderSessionID(id, for: backend)

            case .toolCall(let id, let name, let args):
                let message = AgentMessage(
                    role: .assistant,
                    content: "",
                    kind: .tool,
                    toolName: name,
                    toolArgs: args,
                    toolStatus: .pending,
                    toolCallId: id
                )
                message.thread = thread
                context.insert(message)
                thread.messages.append(message)
                pendingTools[id] = message

            case .toolResult(let id, let name, let summary, let ok):
                if let message = pendingTools.removeValue(forKey: id) {
                    message.toolResult = summary
                    message.toolStatusEnum = ok ? .ok : .failed
                }
                // A successful propose call has parked a proposal keyed by
                // project; surface it as a reviewable row in this thread.
                if ok, name == "caption_propose_edits",
                   let projectUUID = thread.target.projectUUID,
                   let proposal = proposalsByProject[projectUUID] {
                    appendProposalRow(
                        proposal,
                        projectUUID: projectUUID,
                        thread: thread,
                        context: context
                    )
                }

            case .assistantText(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                appendAssistantText(trimmed, thread: thread, context: context)

            case .completed:
                thread.updatedAt = Date()
            }
        }
    }

    private func appendAssistantText(
        _ text: String,
        thread: AgentThread,
        context: ModelContext
    ) {
        let message = AgentMessage(role: .assistant, content: text)
        message.thread = thread
        context.insert(message)
        thread.messages.append(message)
        thread.updatedAt = Date()
    }

    private func appendProposalRow(
        _ proposal: CaptionEditProposal,
        projectUUID: UUID,
        thread: AgentThread,
        context: ModelContext
    ) {
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
        row.thread = thread
        context.insert(row)
        thread.messages.append(row)
    }

    // MARK: - Compaction

    /// Folds older turns into the thread's summary once the conversation grows
    /// past what the backend can replay.
    ///
    /// Rows are marked rather than deleted, so the visible transcript is
    /// unchanged — only what we *send* shrinks.
    private func compactIfNeeded(
        thread: AgentThread,
        older: [AgentChatTurn],
        backend: AgentBackend,
        config: AppConfig?
    ) async {
        guard !older.isEmpty else { return }
        // A CLI thread that resumes natively keeps its own history; compacting
        // ours would only desync the two.
        if backend.isCommandLine, thread.providerSessionID(for: backend) != nil { return }

        let live = thread.liveTextMessages
        guard live.count > CaptionAIContext.verbatimTurns else { return }

        let transcriptText = older.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
        let existing = thread.summary

        let instruction = """
            Summarize the conversation below in at most three sentences. Keep \
            decisions, identifiers and anything still outstanding. Drop \
            pleasantries. Reply with the summary only.

            \(transcriptText)
            """

        var merged = existing
        // Summarize with an in-process engine even on a CLI thread: spawning a
        // subprocess to compress history would cost more than the history does.
        let summarizer = (try? AgentBackendAvailability.shared.resolved(
            preferred: backend.isCommandLine ? .openAICompatible : backend,
            config: config,
            for: .transcriptReview
        )) ?? .appleIntelligence

        if let engine = try? CaptionAIEngineFactory.make(backend: summarizer, config: config),
           let reply = try? await engine.converse(CaptionChatRequest(
               instruction: instruction,
               summary: existing,
               recentTurns: [],
               lines: [],
               totalLines: 0,
               speakers: [],
               terms: [],
               languageHint: ""
           )),
           !reply.assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            merged = reply.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            // Summarizing failed — truncate rather than keep replaying the whole
            // conversation, which would eventually exceed the window.
            merged = String((existing + "\n" + transcriptText).suffix(600))
        }

        thread.summary = merged
        let cutoff = live.count - CaptionAIContext.verbatimTurns
        for message in live.prefix(cutoff) {
            message.isCompacted = true
        }
    }

    /// Splits replayable turns into the part that gets summarized and the tail
    /// that is sent verbatim.
    private static func partition(
        _ messages: some Collection<AgentMessage>
    ) -> (older: [AgentChatTurn], recent: [AgentChatTurn]) {
        let turns = messages.map {
            AgentChatTurn(role: $0.roleEnum.rawValue, content: $0.content)
        }
        guard turns.count > CaptionAIContext.verbatimTurns else { return ([], turns) }
        let cutoff = turns.count - CaptionAIContext.verbatimTurns
        return (Array(turns.prefix(cutoff)), Array(turns.suffix(CaptionAIContext.verbatimTurns)))
    }
}
