import Foundation
import Observation
import SwiftData

/// Owns the caption assistant's in-flight turns.
///
/// A controller rather than view state, for the same reason
/// `RemotionChatController` is one: the assistant lives in its own window, and a
/// turn must survive that window closing. Unlike the Remotion controller this is
/// not macOS-only — captions are cross-platform.
@MainActor
@Observable
final class CaptionAssistantController {
    static let shared = CaptionAssistantController()

    /// Per-project state, keyed by `CaptionProject.projectUUID`.
    struct Session {
        var input: String = ""
        var isSending: Bool = false
        var errorMessage: String?
        var task: Task<Void, Never>?
        var scrollAnchor: UUID?
        /// Proposal waiting for the review sheet.
        var pendingProposal: CaptionEditProposal?
        /// Backend override for this conversation; nil follows the app setting.
        var backendOverride: CaptionAIBackend?
    }

    private var sessions: [UUID: Session] = [:]

    private init() {}

    // MARK: - Session access

    func session(for projectID: UUID) -> Session {
        sessions[projectID] ?? Session()
    }

    func setInput(_ text: String, for projectID: UUID) {
        var session = self.session(for: projectID)
        session.input = text
        sessions[projectID] = session
    }

    func setError(_ message: String?, for projectID: UUID) {
        var session = self.session(for: projectID)
        session.errorMessage = message
        sessions[projectID] = session
    }

    func setScrollAnchor(_ anchor: UUID?, for projectID: UUID) {
        var session = self.session(for: projectID)
        session.scrollAnchor = anchor
        sessions[projectID] = session
    }

    func setPendingProposal(_ proposal: CaptionEditProposal?, for projectID: UUID) {
        var session = self.session(for: projectID)
        session.pendingProposal = proposal
        sessions[projectID] = session
    }

    func setBackendOverride(_ backend: CaptionAIBackend?, for projectID: UUID) {
        var session = self.session(for: projectID)
        session.backendOverride = backend
        sessions[projectID] = session
    }

    func cancel(projectID: UUID) {
        sessions[projectID]?.task?.cancel()
    }

    func clear(projectID: UUID) {
        sessions[projectID]?.task?.cancel()
        sessions[projectID] = nil
    }

    /// The engine answering for a project right now.
    func backend(for project: CaptionProject) -> CaptionAIBackend {
        session(for: project.projectUUID).backendOverride ?? CaptionSettings.shared.aiBackend
    }

    // MARK: - Sending

    func send(
        instruction: String,
        project: CaptionProject,
        selection: Set<UUID>,
        context: ModelContext
    ) {
        let projectID = project.projectUUID
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var session = self.session(for: projectID)
        guard !session.isSending else { return }

        let config = try? AppConfig.loadFromKeychain()
        let preferred = session.backendOverride ?? CaptionSettings.shared.aiBackend

        let resolved: CaptionAIBackend
        do {
            resolved = try CaptionAIAvailability.shared.resolved(
                preferred: preferred,
                config: config
            )
        } catch {
            setError(error.localizedDescription, for: projectID)
            return
        }

        // Persist the user's turn before starting, so it survives a crash and is
        // on screen while the model thinks.
        let userMessage = CaptionAssistantMessage(role: .user, content: trimmed)
        userMessage.project = project
        context.insert(userMessage)
        project.assistantMessages.append(userMessage)

        session.input = ""
        session.isSending = true
        session.errorMessage = nil
        sessions[projectID] = session

        let request = buildRequest(
            instruction: trimmed,
            project: project,
            selection: selection,
            backend: resolved
        )
        let transcript = project.snapshot()
        let lines = CaptionAIContext.lines(from: transcript.segments)
        let maxRunes = CaptionSettings.shared.maxCueRunes
        let terms = project.usableTerms

        let task = Task { @MainActor [weak self] in
            defer {
                if let self {
                    var session = self.session(for: projectID)
                    session.isSending = false
                    session.task = nil
                    self.sessions[projectID] = session
                }
            }

            do {
                // Built inside the task: a CLI backend has to start the MCP
                // server first, which is async and must not block the send.
                let (engine, release) = try await CaptionAIEngineFactory.makeConversational(
                    backend: resolved,
                    config: config,
                    project: project
                )
                defer { Task { await release() } }

                // A CLI agent's edits come back through MCP, where nothing else
                // knows which engine made them.
                CaptionProposalInbox.setEngineLabel(engine.modelLabel, for: projectID)
                defer { CaptionProposalInbox.clearEngineLabel(for: projectID) }

                let reply = try await engine.converse(request)
                guard let self else { return }
                try Task.checkCancellation()

                let text = reply.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    let message = CaptionAssistantMessage(role: .assistant, content: text)
                    message.project = project
                    context.insert(message)
                    project.assistantMessages.append(message)
                    self.setScrollAnchor(message.id, for: projectID)
                }

                let proposal = Self.proposal(
                    from: reply.edits,
                    lines: lines,
                    transcript: transcript,
                    terms: terms,
                    maxRunes: maxRunes,
                    engine: engine.modelLabel
                )
                if let proposal, !proposal.isEmpty {
                    let row = CaptionAssistantMessage(
                        role: .assistant,
                        content: proposal.summary,
                        kind: .proposal,
                        proposalJSON: proposal.encodedJSON()
                    )
                    row.project = project
                    context.insert(row)
                    project.assistantMessages.append(row)
                    self.setPendingProposal(proposal, for: projectID)
                    self.setScrollAnchor(row.id, for: projectID)
                }

                await self.compactIfNeeded(project: project, engine: engine)
            } catch is CancellationError {
                // User pressed stop; nothing to report.
            } catch {
                self?.setError(error.localizedDescription, for: projectID)
            }
        }

        session = self.session(for: projectID)
        session.task = task
        sessions[projectID] = session
    }

    // MARK: - Request assembly

    /// Builds a turn that fits the backend's window.
    ///
    /// The caption slice is chosen by `CaptionAIContext.retrieve` rather than
    /// being the whole transcript — on the on-device model, sending everything
    /// would overflow the context before the second caption.
    private func buildRequest(
        instruction: String,
        project: CaptionProject,
        selection: Set<UUID>,
        backend: CaptionAIBackend
    ) -> CaptionChatRequest {
        let transcript = project.snapshot()
        let lines = CaptionAIContext.lines(from: transcript.segments)

        let history = project.orderedAssistantMessages
            .filter { !$0.isCompacted && $0.kindEnum == .text }
            .map { CaptionChatTurn(role: $0.role, content: $0.content) }
        // The message just inserted is the instruction itself; don't repeat it.
        let (_, recent) = CaptionAIContext.partition(turns: history.dropLast())

        // Whatever the conversation doesn't use is available for captions.
        let overhead = recent.reduce(0) { $0 + $1.content.count + 12 }
            + project.assistantSummary.count
            + instruction.count
        let lineBudget = max(backend.contextBudgetCharacters - overhead - 400, 300)

        return CaptionChatRequest(
            instruction: instruction,
            summary: project.assistantSummary,
            recentTurns: recent,
            lines: CaptionAIContext.retrieve(
                query: instruction,
                lines: lines,
                selection: selection,
                budget: lineBudget
            ),
            totalLines: lines.count,
            speakers: project.speakers,
            terms: project.usableTerms,
            languageHint: project.languageHint
        )
    }

    /// Maps the model's line numbers onto real segments, then validates.
    ///
    /// The model never sees a UUID, so this is also the point where a
    /// hallucinated line number is dropped rather than becoming an edit.
    nonisolated static func proposal(
        from edits: [CaptionChatEdit],
        lines: [CaptionAILine],
        transcript: CaptionTranscriptSnapshot,
        terms: [CaptionTerm],
        maxRunes: Int,
        engine: String = ""
    ) -> CaptionEditProposal? {
        guard !edits.isEmpty else { return nil }

        var lineByNumber: [Int: CaptionAILine] = [:]
        for line in lines { lineByNumber[line.number] = line }

        var operations: [CaptionEditOperation] = []
        var reasons: [UUID: String] = [:]

        for edit in edits {
            guard let line = lineByNumber[edit.number] else { continue }
            let pieces = edit.pieces
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            switch edit.kind {
            case .replaceText:
                guard let text = pieces.first else { continue }
                operations.append(.replaceText(segment: line.segmentID, newText: text))
            case .split:
                guard pieces.count >= 2 else { continue }
                operations.append(.split(segment: line.segmentID, pieces: pieces))
            case .mergeWithNext:
                guard let next = lineByNumber[edit.number + 1] else { continue }
                operations.append(.merge(segment: line.segmentID, withNext: next.segmentID))
            case .delete:
                operations.append(.delete(segment: line.segmentID))
            }

            if !edit.reason.isEmpty { reasons[line.segmentID] = edit.reason }
        }

        guard !operations.isEmpty else { return nil }

        return CaptionProposalBuilder.build(
            operations: operations,
            transcript: transcript,
            terms: terms,
            // The user asked for these in their own words, so the wording is
            // theirs to choose — validation only checks applicability.
            policy: .free,
            maxRunes: maxRunes,
            summary: "\(operations.count) change\(operations.count == 1 ? "" : "s") to review",
            engine: engine,
            reasons: reasons
        )
    }

    // MARK: - Compaction

    /// Folds older turns into the project's summary once the conversation grows
    /// past what the backend can replay.
    ///
    /// Rows are marked rather than deleted, so the visible transcript is
    /// unchanged — only what we *send* shrinks.
    private func compactIfNeeded(project: CaptionProject, engine: any CaptionAIEngine) async {
        let live = project.orderedAssistantMessages
            .filter { !$0.isCompacted && $0.kindEnum == .text }
        guard live.count > CaptionAIContext.verbatimTurns else { return }

        let turns = live.map { CaptionChatTurn(role: $0.role, content: $0.content) }
        let (older, _) = CaptionAIContext.partition(turns: turns)
        guard !older.isEmpty else { return }

        let transcriptText = older.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
        let existing = project.assistantSummary

        let instruction = """
            Summarize the conversation below in at most three sentences. Keep \
            decisions, caption numbers and anything still outstanding. Drop \
            pleasantries. Reply with the summary only.

            \(transcriptText)
            """

        var merged = existing
        if let reply = try? await engine.converse(CaptionChatRequest(
            instruction: instruction,
            summary: existing,
            recentTurns: [],
            lines: [],
            totalLines: 0,
            speakers: [],
            terms: [],
            languageHint: project.languageHint
        )) {
            let text = reply.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { merged = text }
        } else {
            // Summarizing failed — truncate rather than keep replaying the
            // whole conversation, which would eventually exceed the window.
            merged = String((existing + "\n" + transcriptText).suffix(600))
        }

        project.assistantSummary = merged
        let cutoff = live.count - CaptionAIContext.verbatimTurns
        for message in live.prefix(cutoff) {
            message.isCompacted = true
        }
    }
}
