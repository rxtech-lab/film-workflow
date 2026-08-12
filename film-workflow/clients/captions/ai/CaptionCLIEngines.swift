#if os(macOS)
import Foundation

/// Everything a CLI engine needs, resolved on the main actor before the
/// subprocess starts so the engine itself can stay `nonisolated`.
nonisolated struct CaptionCLIContext: Sendable {
    var executable: String
    var endpoint: CaptionMCPBridge.Endpoint
    var captionID: UUID
    var projectName: String
    var model: String
    var workingDirectory: URL
}

/// Shared behaviour of the two command-line engines.
///
/// Everything they do is one agent turn: they read captions and call
/// `caption_propose_edits` through MCP, which is what puts a proposal in front
/// of the user. That holds for splitting and glossary review too — the agent
/// works through the whole transcript itself, so a 60-caption project costs one
/// process launch rather than sixty.
protocol CaptionCLIEngineBase: CaptionBatchAIEngine {
    var context: CaptionCLIContext { get }
    var toolName: String { get }

    /// Runs one turn, with the caption system prompt prepended.
    func run(instruction: String) async throws -> String
}

extension CaptionCLIEngineBase {

    // MARK: - Per-caption entry points
    //
    // Never reached in practice: `CaptionAISplitter` and `CaptionTermReviewer`
    // take the whole-transcript path for any `CaptionBatchAIEngine`, and the
    // transcription pipeline won't resolve to a CLI backend at all. These stay
    // as an honest answer for anything that calls them directly.

    func planSplit(_ request: CaptionSplitRequest) async throws -> CaptionSplitPlan {
        throw CaptionAIError.backendUnavailable(
            backend,
            "\(toolName) works over a whole transcript, not one caption at a time."
        )
    }

    func reviewTerms(_ request: CaptionTermReviewRequest) async throws -> CaptionTermReviewResult {
        throw CaptionAIError.backendUnavailable(
            backend,
            "\(toolName) works over a whole transcript, not one batch of lines at a time."
        )
    }

    // MARK: - Whole-transcript tasks

    func proposeSplits(
        transcript: CaptionTranscriptSnapshot,
        maxRunes: Int,
        terms: [CaptionTerm],
        languageHint: String
    ) async throws -> CaptionEditProposal {
        let overlong = transcript.segments.count { $0.text.count > maxRunes }
        guard overlong > 0 else {
            return CaptionEditProposal(
                summary: "Every caption is already short enough.",
                engine: modelLabel
            )
        }

        return try await collect(policy: .preserveWords) {
            CaptionCLIPrompts.splitInstruction(
                maxRunes: maxRunes,
                minRunes: CaptionProposalBuilder.minimumPieceRunes(maxRunes: maxRunes),
                overlong: overlong,
                total: transcript.segments.count,
                terms: terms
            )
        }
    }

    func proposeTermFixes(
        transcript: CaptionTranscriptSnapshot,
        terms: [CaptionTerm],
        languageHint: String
    ) async throws -> CaptionEditProposal {
        guard !terms.isEmpty else {
            return CaptionEditProposal(
                summary: "Add some terms in the caption setup panel first.",
                engine: modelLabel
            )
        }

        return try await collect(policy: .glossaryOnly) {
            CaptionCLIPrompts.termInstruction(total: transcript.segments.count, terms: terms)
        }
    }

    /// Runs a turn whose result arrives through `caption_propose_edits` rather
    /// than in the reply text.
    ///
    /// The claim has to be released even if the process is killed mid-turn, or
    /// the next chat proposal for this project would be swallowed by a batch
    /// task that is no longer running.
    private func collect(
        policy: CaptionProposalPolicy,
        instruction: () -> String
    ) async throws -> CaptionEditProposal {
        let captionID = context.captionID
        let label = modelLabel

        await MainActor.run {
            CaptionProposalInbox.claim(captionID, policy: policy)
            CaptionProposalInbox.setEngineLabel(label, for: captionID)
        }

        let reply: String
        do {
            reply = try await run(instruction: instruction())
        } catch {
            await MainActor.run {
                CaptionProposalInbox.finish(captionID)
                CaptionProposalInbox.clearEngineLabel(for: captionID)
            }
            throw error
        }

        var proposal = await MainActor.run { () -> CaptionEditProposal in
            let collected = CaptionProposalInbox.finish(captionID)
            CaptionProposalInbox.clearEngineLabel(for: captionID)
            return collected
        }
        proposal.engine = label
        if proposal.summary.isEmpty {
            // The agent's own sentence, when it proposed nothing — that is where
            // the reason lives ("nothing needed splitting", or an explanation).
            proposal.summary = reply.isEmpty ? "\(toolName) proposed no changes." : reply
        }
        return proposal
    }

    /// The turn as the CLI sees it: conversation history plus the request.
    ///
    /// The transcript is deliberately *not* included — the agent fetches what it
    /// needs through `caption_search_segments`, which is the whole reason to use
    /// a tool-calling backend for long transcripts.
    func prompt(for request: CaptionChatRequest) -> String {
        var parts: [String] = []
        if !request.summary.isEmpty {
            parts.append("Earlier in this conversation:\n\(request.summary)")
        }
        for turn in request.recentTurns {
            parts.append("\(turn.role.capitalized): \(turn.content)")
        }
        let glossary = CaptionTermMatching.promptBlock(request.terms)
        if !glossary.isEmpty { parts.append(glossary) }
        parts.append("The transcript has \(request.totalLines) captions.")
        parts.append("Request: \(request.instruction)")
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Claude Code

/// Drives the `claude` CLI in non-interactive mode.
///
/// `--allowedTools` is restricted to our four caption tools, and
/// `--strict-mcp-config` drops whatever MCP servers the user has configured
/// globally. Together those mean no permission prompt can fire — which is why
/// this needs none of the HTTP permission-broker machinery a general coding
/// agent host requires.
nonisolated struct ClaudeCodeCaptionEngine: CaptionCLIEngineBase {
    let context: CaptionCLIContext
    var backend: CaptionAIBackend { .claudeCode }
    var toolName: String { "Claude Code" }

    func converse(_ request: CaptionChatRequest) async throws -> CaptionChatReply {
        let text = try await run(instruction: prompt(for: request))
        guard !text.isEmpty else { throw CaptionAIError.emptyResponse }
        // Edits arrive out of band: the agent calls caption_propose_edits, and
        // that handler puts the proposal in front of the user directly.
        return CaptionChatReply(assistantText: text)
    }

    func run(instruction: String) async throws -> String {
        let configURL = try CaptionMCPBridge.writeClaudeConfig(context.endpoint)
        defer { try? FileManager.default.removeItem(at: configURL) }

        var arguments = [
            "-p", instruction,
            "--output-format", "stream-json",
            // Required by the CLI whenever -p is combined with stream-json.
            "--verbose",
            "--strict-mcp-config",
            "--mcp-config", configURL.path,
            "--allowedTools", CaptionMCPBridge.prefixedToolNames.joined(separator: ","),
            "--append-system-prompt", CaptionMCPBridge.systemPrompt(
                captionID: context.captionID,
                projectName: context.projectName
            ),
        ]
        if !context.model.isEmpty {
            arguments.append(contentsOf: ["--model", context.model])
        }

        let transcript = ClaudeTranscript()
        try await CaptionCLIProcess.run(
            tool: toolName,
            executable: context.executable,
            arguments: arguments,
            environment: CaptionMCPBridge.environment(token: context.endpoint.token),
            workingDirectory: context.workingDirectory,
            onLine: { line in transcript.ingest(line) }
        )
        return transcript.finalText
    }
}

/// Accumulates the assistant text out of `claude --output-format stream-json`.
///
/// A deliberately partial decoder for that NDJSON schema: `result` when the run
/// ends cleanly, `assistant` text blocks as a fallback for the shapes where it
/// doesn't. Anything unrecognized is ignored rather than treated as an error —
/// the CLI adds event types between releases, and an unknown frame must never
/// fail a turn.
private final class ClaudeTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private var assistantChunks: [String] = []
    private var result: String?

    func ingest(_ line: String) {
        guard let data = line.data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = frame["type"] as? String else { return }

        switch type {
        case "result":
            // `is_error` runs carry the error text in the same field; the caller
            // already surfaces a non-zero exit, so just take the text.
            if let text = frame["result"] as? String {
                lock.withLock { result = text }
            }

        case "assistant":
            guard let message = frame["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            let texts = content.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
            guard !texts.isEmpty else { return }
            lock.withLock { assistantChunks.append(contentsOf: texts) }

        default:
            break
        }
    }

    var finalText: String {
        lock.withLock {
            if let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return result.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return assistantChunks
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

// MARK: - Codex

/// Drives `codex exec`.
///
/// Simpler than Claude's path in one respect: `--output-last-message` writes the
/// final answer to a file, so there is no stream to reassemble. `--json` is still
/// requested so a future version of this can show tool activity live.
///
/// `--sandbox read-only` and `--skip-git-repo-check` matter: Codex expects to be
/// pointed at a git repository it may edit, and neither is true here.
nonisolated struct CodexCaptionEngine: CaptionCLIEngineBase {
    let context: CaptionCLIContext
    var backend: CaptionAIBackend { .codex }
    var toolName: String { "Codex" }

    func converse(_ request: CaptionChatRequest) async throws -> CaptionChatReply {
        let text = try await run(instruction: prompt(for: request))
        guard !text.isEmpty else { throw CaptionAIError.emptyResponse }
        return CaptionChatReply(assistantText: text)
    }

    func run(instruction: String) async throws -> String {
        let lastMessageURL = FileStorage.temporaryFileURL(extension: "txt")
        defer { try? FileManager.default.removeItem(at: lastMessageURL) }

        var arguments = ["exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only"]
        for override in CaptionMCPBridge.codexConfigOverrides(context.endpoint) {
            arguments.append(contentsOf: ["-c", override])
        }
        if !context.model.isEmpty {
            arguments.append(contentsOf: ["--model", context.model])
        }
        arguments.append(contentsOf: ["--output-last-message", lastMessageURL.path])
        arguments.append(contentsOf: ["--cd", context.workingDirectory.path])

        let combined = CaptionMCPBridge.systemPrompt(
            captionID: context.captionID,
            projectName: context.projectName
        ) + "\n\n" + instruction

        try await CaptionCLIProcess.run(
            tool: toolName,
            executable: context.executable,
            arguments: arguments,
            environment: CaptionMCPBridge.environment(token: context.endpoint.token),
            workingDirectory: context.workingDirectory,
            // Passed on stdin rather than argv: a long conversation would
            // otherwise run into the argument-length limit.
            stdin: combined,
            onLine: { _ in }
        )

        return ((try? String(contentsOf: lastMessageURL, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
