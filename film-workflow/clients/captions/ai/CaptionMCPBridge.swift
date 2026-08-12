#if os(macOS)
import Foundation

/// Points a command-line agent at this app's own MCP server.
///
/// The insight that makes the CLI backends cheap: Claude Code and Codex are
/// general coding agents that need a permission broker because they can write
/// files and run shells. Our assistant needs neither — it only reads captions
/// and *proposes* edits, and the app already exposes exactly those operations
/// over MCP. So instead of porting an agent runtime, we scope the CLI to a
/// handful of our own tools and let it call back in.
///
/// `caption_update_segment` is deliberately **not** in the allowlist: it writes
/// immediately. A conversational agent gets `caption_propose_edits`, which
/// queues changes for the user to approve.
@MainActor
enum CaptionMCPBridge {

    /// Key for our server in the agent's MCP config. Also the tool-name prefix
    /// the agent sees (`mcp__film_workflow__caption_search_segments`), so it has
    /// to be a valid identifier — the server's own name has a hyphen.
    nonisolated static let serverKey = "film_workflow"

    /// Read-only tools plus the propose tool. Nothing here can change a caption.
    nonisolated static let allowedTools = [
        "caption_list_segments",
        "caption_search_segments",
        "caption_export",
        "caption_propose_edits",
    ]

    nonisolated static var prefixedToolNames: [String] {
        allowedTools.map { "mcp__\(serverKey)__\($0)" }
    }

    struct Endpoint: Sendable {
        var url: String
        var token: String?
        /// True when this bridge started the server and should stop it again.
        var startedByUs: Bool
    }

    /// Starts the MCP server if it isn't already up, and returns where to reach it.
    ///
    /// A user who has never enabled the MCP server still expects the assistant
    /// to work, so this starts one on demand rather than telling them to go turn
    /// a setting on — and `release` puts it back the way it was.
    static func ensureRunning() async throws -> Endpoint {
        let settings = MCPSettings.shared
        let server = MCPServer.shared

        var startedByUs = false
        if !server.isRunning {
            await server.start()
            startedByUs = true
        }

        guard server.isRunning, let port = settings.actualPort else {
            throw CaptionAIError.backendUnavailable(
                .claudeCode,
                server.lastError ?? "The app's MCP server couldn't start, so the "
                    + "command-line assistant has no way to read your captions."
            )
        }

        return Endpoint(
            url: "http://127.0.0.1:\(port)/mcp",
            token: settings.token,
            startedByUs: startedByUs
        )
    }

    /// Stops the server again if we were the ones who started it.
    static func release(_ endpoint: Endpoint) async {
        guard endpoint.startedByUs, !MCPSettings.shared.enabled else { return }
        await MCPServer.shared.stop()
    }

    /// Writes the `--mcp-config` file Claude Code reads.
    ///
    /// A temp file rather than inline JSON on the command line: the token would
    /// otherwise show up in `ps` output for every user on the machine.
    nonisolated static func writeClaudeConfig(_ endpoint: Endpoint) throws -> URL {
        var server: [String: Any] = [
            "type": "http",
            "url": endpoint.url,
        ]
        if let token = endpoint.token, !token.isEmpty {
            server["headers"] = ["Authorization": "Bearer \(token)"]
        }

        let config: [String: Any] = ["mcpServers": [serverKey: server]]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        let url = FileStorage.temporaryFileURL(extension: "json")
        try data.write(to: url, options: [.atomic])
        // 0600: the file carries a bearer token.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return url
    }

    /// `-c key=value` overrides that register our server with Codex.
    ///
    /// Codex takes the token from an environment variable rather than a header,
    /// which is why `environment(token:)` exists.
    nonisolated static func codexConfigOverrides(_ endpoint: Endpoint) -> [String] {
        var overrides = [
            "mcp_servers.\(serverKey).url=\"\(endpoint.url)\"",
        ]
        if let token = endpoint.token, !token.isEmpty {
            overrides.append(
                "mcp_servers.\(serverKey).bearer_token_env_var=\"\(tokenEnvironmentKey)\""
            )
        }
        return overrides
    }

    nonisolated static let tokenEnvironmentKey = "FILM_WORKFLOW_MCP_TOKEN"

    nonisolated static func environment(token: String?) -> [String: String] {
        var env = RemotionRuntime.enrichedEnvironment()
        if let token, !token.isEmpty { env[tokenEnvironmentKey] = token }
        return env
    }

    /// System prompt shared by both CLI backends.
    ///
    /// Names the tools explicitly because a coding agent's default instinct is
    /// to reach for the filesystem, and there is nothing here for it to edit.
    nonisolated static func systemPrompt(captionID: UUID, projectName: String) -> String {
        """
        You are the caption-editing assistant inside a macOS app called Film \
        Studio. You are not editing a code repository — do not read, write or \
        search files, and do not run shell commands. Everything you need is in \
        the MCP tools below.

        The caption project you are working on is "\(projectName)". Its \
        caption_id is \(captionID.uuidString) — pass it to every tool call.

        Tools:
        - mcp__\(serverKey)__caption_search_segments — find captions by keyword. \
        Prefer this over listing everything.
        - mcp__\(serverKey)__caption_list_segments — page through captions when \
        you need a range rather than a keyword.
        - mcp__\(serverKey)__caption_propose_edits — propose changes. This is the \
        only way to change anything.
        - mcp__\(serverKey)__caption_export — render captions to a file, if asked.

        Propose edits rather than describing them. The user reviews and approves \
        every change before it takes effect, so never claim you have already \
        changed something — say what you have proposed.

        Keep your final reply to a couple of sentences.
        """
    }
}
#endif
