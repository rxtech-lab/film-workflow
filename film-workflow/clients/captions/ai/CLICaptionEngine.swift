#if os(macOS)
import Foundation

/// Runs caption translation through the `claude` or `codex` CLI.
///
/// Deliberately *not* an agent turn: no MCP server, no tools, no session to
/// resume. The CLI is used here as a one-shot completion endpoint — prompt in,
/// JSON out — which is what makes it usable for a batched task at all. The
/// agent-window arrangement in `AgentCLIRunner`, where the CLI reads the
/// transcript back over MCP, is the opposite shape and stays where it is.
///
/// Only `translate` is offered. `planSplit` and `reviewTerms` are asked once per
/// caption, and a process launch per caption is not a viable shape at any
/// transcript length; translation batches a hundred captions per launch, so a
/// whole transcript is a handful.
nonisolated struct CLICaptionEngine: CaptionAIEngine {
    let backend: AgentBackend
    let executable: String
    /// Empty means "whatever the CLI defaults to", which is the common case.
    let model: String

    var modelLabel: String {
        model.isEmpty ? backend.engineLabel : "\(backend.engineLabel) (\(model))"
    }

    // MARK: - Unsupported tasks

    func planSplit(_ request: CaptionSplitRequest) async throws -> CaptionSplitPlan {
        throw Self.agentWindowOnly(backend)
    }

    func reviewTerms(_ request: CaptionTermReviewRequest) async throws -> CaptionTermReviewResult {
        throw Self.agentWindowOnly(backend)
    }

    func converse(_ request: CaptionChatRequest) async throws -> CaptionChatReply {
        throw Self.agentWindowOnly(backend)
    }

    private static func agentWindowOnly(_ backend: AgentBackend) -> CaptionAIError {
        .backendUnavailable(
            backend,
            "\(backend.engineLabel) only answers in the agent window. Choose "
                + "Apple Intelligence or an OpenAI-compatible model for this."
        )
    }

    // MARK: - Translate

    func translate(_ request: CaptionTranslateRequest) async throws -> CaptionTranslateResult {
        guard !request.lines.isEmpty else { return CaptionTranslateResult(lines: []) }

        let instructions = CaptionAIPrompts.translateInstructions(
            source: request.sourceLanguage,
            target: request.targetLanguage
        ) + "\n\n" + Self.jsonContract

        let prompt = CaptionAIPrompts.translatePrompt(request)

        let reply: String
        switch backend {
        case .claudeCode:
            reply = try await runClaude(instructions: instructions, prompt: prompt)
        case .codex:
            reply = try await runCodex(instructions: instructions, prompt: prompt)
        case .appleIntelligence, .openAICompatible:
            throw CaptionAIError.backendUnavailable(
                backend,
                "\(backend.engineLabel) doesn't run as a command-line tool."
            )
        }

        guard !reply.isEmpty else { throw CaptionAIError.emptyResponse }
        guard let object = OpenAICaptionEngine.parseJSONObject(reply) else {
            // A coding agent that ran long will stop mid-object; the translation
            // runner answers that by halving the batch, so say which it was.
            if OpenAICaptionEngine.looksTruncated(reply) {
                throw CaptionAIError.contextOverflow("the reply was cut off mid-JSON")
            }
            throw CaptionAIError.malformedResponse(String(reply.prefix(200)))
        }

        let rows = (object["lines"] as? [[String: Any]]) ?? []
        return CaptionTranslateResult(
            lines: rows.compactMap { row in
                guard let number = Self.intValue(row["number"]),
                      let text = row["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return CaptionTranslatedLine(number: number, text: text)
            }
        )
    }

    /// Spelled out because a coding agent's instinct is to explain its work.
    /// Here the JSON *is* the deliverable and prose around it is noise —
    /// tolerated by the parser, but only up to a point.
    private static let jsonContract = """
        Reply with one JSON object and nothing else. No commentary, no code \
        fence, no summary of what you did.

        Shape:
        {"lines":[{"number":1,"text":"the translation of line 1"}]}

        Include one entry for every numbered line you were given, using that \
        same number. Do not read files, run commands, or use any tool — \
        everything you need is in this message.
        """

    // MARK: - Claude Code

    /// `--strict-mcp-config` with an empty config drops whatever MCP servers the
    /// user has configured globally, and `--allowedTools` naming nothing means
    /// no permission prompt can fire and no tool can be reached. This is a
    /// completion, not an agent turn.
    private func runClaude(instructions: String, prompt: String) async throws -> String {
        let configURL = FileStorage.temporaryFileURL(extension: "json")
        try Data(#"{"mcpServers":{}}"#.utf8).write(to: configURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: configURL) }

        var arguments = [
            "-p",
            "--output-format", "text",
            "--strict-mcp-config",
            "--mcp-config", configURL.path,
            "--allowedTools", "",
            "--append-system-prompt", instructions,
        ]
        if !model.isEmpty {
            arguments.append(contentsOf: ["--model", model])
        }

        let output = OutputCollector()
        _ = try await CaptionCLIProcess.run(
            tool: "Claude Code",
            executable: executable,
            arguments: arguments,
            environment: Self.environment,
            workingDirectory: FileStorage.appSupportURL,
            // On stdin rather than argv: a batch of a hundred captions is tens
            // of kilobytes, and the argument-length limit is not somewhere to
            // find out empirically.
            stdin: prompt,
            onLine: { output.append($0) }
        )
        return output.text
    }

    // MARK: - Codex

    /// `--sandbox read-only` and `--skip-git-repo-check` matter for the same
    /// reason they do in `AgentCLIRunner`: Codex expects a git repository it may
    /// edit, and neither is true here. No `-c mcp_servers…` overrides are
    /// passed, so it has nothing to call.
    private func runCodex(instructions: String, prompt: String) async throws -> String {
        let lastMessageURL = FileStorage.temporaryFileURL(extension: "txt")
        defer { try? FileManager.default.removeItem(at: lastMessageURL) }

        var arguments = ["exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only"]
        if !model.isEmpty {
            arguments.append(contentsOf: ["--model", model])
        }
        arguments.append(contentsOf: ["--output-last-message", lastMessageURL.path])
        arguments.append(contentsOf: ["--cd", FileStorage.appSupportURL.path])

        _ = try await CaptionCLIProcess.run(
            tool: "Codex",
            executable: executable,
            arguments: arguments,
            environment: Self.environment,
            workingDirectory: FileStorage.appSupportURL,
            stdin: instructions + "\n\n" + prompt,
            // The JSON event stream is ignored: `--output-last-message` is the
            // authoritative answer and is stable across releases, where the
            // event schema is not.
            onLine: { _ in }
        )

        return ((try? String(contentsOf: lastMessageURL, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    /// The parent environment, minus the MCP token the agent window injects —
    /// this engine deliberately exposes no server, so passing a credential for
    /// one would be pointless at best.
    private static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "FILM_WORKFLOW_MCP_TOKEN")
        return environment
    }

    /// JSON numbers arrive as `Int`, `Double` or a string depending on how the
    /// model felt about quoting them.
    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int: return int
        case let double as Double: return Int(double)
        case let string as String: return Int(string.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
}

/// Accumulates stdout lines from `CaptionCLIProcess`, which delivers them from a
/// Dispatch read handler rather than the calling actor.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
