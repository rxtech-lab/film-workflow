#if os(macOS)
import Foundation
import SwiftData

/// Drives the `claude` and `codex` CLIs as agent backends.
///
/// Both are pointed at this app's own MCP server (`AgentMCPBridge`) and scoped
/// to the tools the write policy allows, so they reach exactly the same
/// `MCPToolRegistry.invoke` the in-process runtime does. Neither is allowed to
/// touch the filesystem or run shells, which is why no permission broker is
/// needed — a general coding agent host would need one, this does not.
///
/// Unlike the single-shot caption engine this replaces, the run streams: tool
/// calls and results are emitted as they happen, so the transcript shows the
/// same live tool cards the OpenAI loop produces.
@MainActor
enum AgentCLIRunner {

    struct Context {
        var backend: AgentBackend
        var executable: String
        var endpoint: AgentMCPBridge.Endpoint
        var model: String
        /// Native session id to resume, when we have one for this backend.
        var resumeSessionID: String?
        var systemPrompt: String
        /// The turn to send. Already excludes replayed history when resuming.
        var prompt: String
        var policy: AgentWritePolicy
    }

    static func run(context: Context) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    try await execute(context: context, emit: { continuation.yield($0) })
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Execution

    private static func execute(
        context: Context,
        emit: @escaping (AgentEvent) -> Void
    ) async throws {
        do {
            try await launch(context: context, emit: emit)
        } catch {
            // A resume that the CLI no longer recognizes (session expired, CLI
            // upgraded, history diverged) must not lose the user's turn. Retry
            // once from scratch — the caller passes a prompt that carries our
            // own replayed history, so a fresh session loses no context.
            guard context.resumeSessionID != nil, !(error is CancellationError) else { throw error }
            var retry = context
            retry.resumeSessionID = nil
            emit(.status("Couldn't resume the previous session; starting a new one."))
            try await launch(context: retry, emit: emit)
        }
    }

    private static func launch(
        context: Context,
        emit: @escaping (AgentEvent) -> Void
    ) async throws {
        switch context.backend {
        case .claudeCode:
            try await runClaude(context: context, emit: emit)
        case .codex:
            try await runCodex(context: context, emit: emit)
        case .appleIntelligence, .openAICompatible:
            assertionFailure("AgentCLIRunner called with a non-CLI backend")
        }
    }

    // MARK: - Claude Code

    /// `--strict-mcp-config` drops whatever MCP servers the user has configured
    /// globally, and `--allowedTools` names only ours, so no permission prompt
    /// can fire and the CLI cannot reach anything outside this app.
    private static func runClaude(
        context: Context,
        emit: @escaping (AgentEvent) -> Void
    ) async throws {
        let configURL = try AgentMCPBridge.writeClaudeConfig(context.endpoint)
        defer { try? FileManager.default.removeItem(at: configURL) }

        var arguments = [
            "-p", context.prompt,
            "--output-format", "stream-json",
            // Required by the CLI whenever -p is combined with stream-json.
            "--verbose",
            "--strict-mcp-config",
            "--mcp-config", configURL.path,
            "--allowedTools",
            AgentMCPBridge.prefixedToolNames(policy: context.policy).joined(separator: ","),
            "--append-system-prompt", context.systemPrompt,
        ]
        if !context.model.isEmpty {
            arguments.append(contentsOf: ["--model", context.model])
        }
        if let resume = context.resumeSessionID, !resume.isEmpty {
            arguments.append(contentsOf: ["--resume", resume])
        }

        let sink = ClaudeStreamSink(emit: emit)
        _ = try await CaptionCLIProcess.run(
            tool: "Claude Code",
            executable: context.executable,
            arguments: arguments,
            environment: AgentMCPBridge.environment(token: context.endpoint.token),
            workingDirectory: FileStorage.appSupportURL,
            onLine: { line in sink.ingest(line) }
        )

        try sink.finish()
    }

    // MARK: - Codex

    /// `--sandbox read-only` and `--skip-git-repo-check` matter: Codex expects
    /// to be pointed at a git repository it may edit, and neither is true here.
    ///
    /// No resume flag is passed. Codex's resume interface has moved between
    /// releases, and getting it wrong silently starts a junk session rather than
    /// failing loudly — so this backend always replays our own history in the
    /// prompt, which we control. `--output-last-message` remains the
    /// authoritative final answer; the JSON stream is only used for tool cards.
    private static func runCodex(
        context: Context,
        emit: @escaping (AgentEvent) -> Void
    ) async throws {
        let lastMessageURL = FileStorage.temporaryFileURL(extension: "txt")
        defer { try? FileManager.default.removeItem(at: lastMessageURL) }

        var arguments = ["exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only"]
        for override in AgentMCPBridge.codexConfigOverrides(context.endpoint) {
            arguments.append(contentsOf: ["-c", override])
        }
        if !context.model.isEmpty {
            arguments.append(contentsOf: ["--model", context.model])
        }
        arguments.append(contentsOf: ["--output-last-message", lastMessageURL.path])
        arguments.append(contentsOf: ["--cd", FileStorage.appSupportURL.path])

        let sink = CodexStreamSink(emit: emit)
        let combined = context.systemPrompt + "\n\n" + context.prompt

        _ = try await CaptionCLIProcess.run(
            tool: "Codex",
            executable: context.executable,
            arguments: arguments,
            environment: AgentMCPBridge.environment(token: context.endpoint.token),
            workingDirectory: FileStorage.appSupportURL,
            // Passed on stdin rather than argv: a long conversation would
            // otherwise run into the argument-length limit.
            stdin: combined,
            onLine: { line in sink.ingest(line) }
        )

        let text = ((try? String(contentsOf: lastMessageURL, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try sink.finish(finalText: text)
    }
}

// MARK: - Claude stream

/// Decodes `claude --output-format stream-json` into `AgentEvent`s.
///
/// A deliberately partial decoder: it understands the frames it needs and
/// **ignores everything else**. The CLI adds event types between releases, and
/// an unknown frame must never fail a turn.
///
/// `@unchecked Sendable` with a lock because `CaptionCLIProcess` delivers lines
/// from a Dispatch read handler, off the main actor.
private final class ClaudeStreamSink: @unchecked Sendable {
    private let lock = NSLock()
    private let emit: @Sendable (AgentEvent) -> Void

    private var assistantChunks: [String] = []
    private var result: String?
    private var sessionID: String?
    /// tool_use id → name, so a tool_result can be attributed to its call.
    private var toolNames: [String: String] = [:]

    init(emit: @escaping (AgentEvent) -> Void) {
        // The emit closure is only ever called under the lock, and the
        // continuation it feeds is itself thread-safe.
        self.emit = { event in emit(event) }
    }

    func ingest(_ line: String) {
        guard let data = line.data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = frame["type"] as? String
        else { return }

        switch type {
        case "system":
            guard let id = frame["session_id"] as? String, !id.isEmpty else { return }
            lock.withLock {
                guard sessionID != id else { return }
                sessionID = id
                emit(.sessionID(id))
            }

        case "assistant":
            guard let message = frame["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { return }
            for block in content {
                switch block["type"] as? String {
                case "text":
                    guard let text = block["text"] as? String,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { continue }
                    lock.withLock { assistantChunks.append(text) }
                case "tool_use":
                    guard let id = block["id"] as? String,
                          let name = block["name"] as? String
                    else { continue }
                    let args = Self.encode(block["input"])
                    lock.withLock {
                        toolNames[id] = name
                        emit(.toolCall(id: id, name: Self.strippedPrefix(name), args: args))
                    }
                default:
                    continue
                }
            }

        case "user":
            // Tool results come back as a synthetic user turn.
            guard let message = frame["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { return }
            for block in content where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String else { continue }
                let ok = !((block["is_error"] as? Bool) ?? false)
                let summary = Self.summarize(block["content"])
                lock.withLock {
                    let name = toolNames[id] ?? "tool"
                    emit(.toolResult(
                        id: id,
                        name: Self.strippedPrefix(name),
                        summary: summary,
                        ok: ok
                    ))
                }
            }

        case "result":
            // `is_error` runs carry the error text in the same field; a non-zero
            // exit is surfaced by the process runner, so just take the text.
            if let id = frame["session_id"] as? String, !id.isEmpty {
                lock.withLock {
                    guard sessionID != id else { return }
                    sessionID = id
                    emit(.sessionID(id))
                }
            }
            if let text = frame["result"] as? String {
                lock.withLock { result = text }
            }

        default:
            break
        }
    }

    /// Emits the final assistant text and completion, or throws if the run
    /// produced nothing at all.
    func finish() throws {
        let text: String = lock.withLock {
            if let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return result.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return assistantChunks
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { throw CaptionAIError.emptyResponse }
        emit(.assistantText(text))
        emit(.completed)
    }

    // MARK: - Helpers

    /// `mcp__film_workflow__caption_export` → `caption_export`, so tool cards
    /// read the same whichever backend produced them.
    static func strippedPrefix(_ name: String) -> String {
        let prefix = "mcp__\(AgentMCPBridge.serverKey)__"
        return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
    }

    static func encode(_ value: Any?) -> String {
        guard let value,
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .fragmentsAllowed]
              ),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    /// Tool result content is either a string or MCP content blocks.
    static func summarize(_ content: Any?) -> String {
        var text = ""
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            text = blocks
                .compactMap { $0["text"] as? String }
                .joined(separator: " ")
        }
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > 200 ? String(collapsed.prefix(200)) + "…" : collapsed
    }
}

// MARK: - Codex stream

/// Decodes `codex exec --json` into tool events.
///
/// Codex's event schema has changed shape across releases, so this recognizes
/// several spellings and ignores anything it doesn't know. The final answer is
/// never taken from here — it comes from `--output-last-message`, which is
/// stable — so a schema change costs tool cards, not the turn.
private final class CodexStreamSink: @unchecked Sendable {
    private let lock = NSLock()
    private let emit: @Sendable (AgentEvent) -> Void
    private var openCalls: [String: String] = [:]

    init(emit: @escaping (AgentEvent) -> Void) {
        self.emit = { event in emit(event) }
    }

    func ingest(_ line: String) {
        guard let data = line.data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        // Events are nested under `msg` in current releases and flat in older
        // ones; accept either.
        let body = (frame["msg"] as? [String: Any]) ?? frame
        guard let type = body["type"] as? String else { return }

        switch type {
        case "session_configured", "session.created":
            guard let id = body["session_id"] as? String, !id.isEmpty else { return }
            lock.withLock { emit(.sessionID(id)) }

        case "mcp_tool_call_begin", "mcp_tool_call.begin":
            let id = (body["call_id"] as? String) ?? UUID().uuidString
            let name = Self.toolName(from: body)
            lock.withLock {
                openCalls[id] = name
                emit(.toolCall(id: id, name: name, args: ClaudeStreamSink.encode(body["arguments"])))
            }

        case "mcp_tool_call_end", "mcp_tool_call.end":
            let id = (body["call_id"] as? String) ?? ""
            let ok = !((body["is_error"] as? Bool) ?? false)
            lock.withLock {
                let name = openCalls.removeValue(forKey: id) ?? Self.toolName(from: body)
                emit(.toolResult(
                    id: id,
                    name: name,
                    summary: ClaudeStreamSink.summarize(body["result"] ?? body["content"]),
                    ok: ok
                ))
            }

        default:
            break
        }
    }

    func finish(finalText: String) throws {
        guard !finalText.isEmpty else { throw CaptionAIError.emptyResponse }
        // Any tool call still open never reported an end frame; close it so the
        // transcript doesn't keep a spinner running forever.
        lock.withLock {
            for (id, name) in openCalls {
                emit(.toolResult(id: id, name: name, summary: "no result", ok: false))
            }
            openCalls.removeAll()
        }
        emit(.assistantText(finalText))
        emit(.completed)
    }

    private static func toolName(from body: [String: Any]) -> String {
        let raw = (body["tool"] as? String)
            ?? (body["tool_name"] as? String)
            ?? (body["name"] as? String)
            ?? "tool"
        return ClaudeStreamSink.strippedPrefix(raw)
    }
}
#endif
