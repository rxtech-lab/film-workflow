#if os(macOS)
import Foundation

/// Points a command-line agent at this app's own MCP server.
///
/// The insight that makes the CLI backends cheap: Claude Code and Codex are
/// general coding agents that need a permission broker because they can write
/// files and run shells. Ours needs neither — it works entirely through tools
/// this app already exposes over MCP. So instead of porting an agent runtime we
/// scope the CLI to our own tools and let it call back in, which means the
/// in-process runtime and the CLI agents reach the identical
/// `MCPToolRegistry.invoke` and cannot drift apart.
@MainActor
enum AgentMCPBridge {

    /// Key for our server in the agent's MCP config. Also the tool-name prefix
    /// the agent sees (`mcp__film_workflow__caption_search_segments`), so it has
    /// to be a valid identifier — the server's own name has a hyphen.
    nonisolated static let serverKey = "film_workflow"

    nonisolated static func prefix(_ name: String) -> String {
        "mcp__\(serverKey)__\(name)"
    }

    /// Tool names as the CLI sees them, filtered by the write policy.
    ///
    /// This is what replaced the old four-caption-tool allowlist: the CLI
    /// agents now get the same surface the in-process runtime does, so a thread
    /// on Codex is no less capable than one on the OpenAI loop.
    static func prefixedToolNames(policy: AgentWritePolicy) -> [String] {
        AgentToolPolicy.toolNames(policy: policy).map(prefix)
    }

    struct Endpoint: Sendable {
        var url: String
        var token: String?
    }

    // MARK: - Lifecycle

    /// How many turns are currently relying on the server we started.
    ///
    /// Refcounted because threads run concurrently: without this, the first of
    /// two overlapping CLI turns to finish would stop the server out from under
    /// the second, which would then fail every remaining tool call. Only the
    /// last release actually stops it, and only if the user hadn't enabled the
    /// server themselves.
    private static var holdCount = 0
    private static var startedByUs = false

    /// Starts the MCP server if it isn't already up, and returns where to reach it.
    ///
    /// A user who has never enabled the MCP server still expects the agent to
    /// work, so this starts one on demand rather than telling them to go turn a
    /// setting on — and `release` puts it back the way it was.
    static func acquire() async throws -> Endpoint {
        let settings = MCPSettings.shared
        let server = MCPServer.shared

        if !server.isRunning {
            await server.start()
            // Only claim credit for a start that actually worked, or a failed
            // start would leave `startedByUs` true and stop someone else's
            // server on release.
            if server.isRunning { startedByUs = true }
        }

        guard server.isRunning, let port = settings.actualPort else {
            throw CaptionAIError.backendUnavailable(
                .claudeCode,
                server.lastError ?? "The app's MCP server couldn't start, so the "
                    + "command-line agent has no way to reach your projects."
            )
        }

        holdCount += 1
        return Endpoint(
            url: "http://127.0.0.1:\(port)/mcp",
            token: settings.token
        )
    }

    /// Releases one hold, stopping the server again once the last one goes and
    /// we were the ones who started it.
    static func release() async {
        holdCount = max(0, holdCount - 1)
        guard holdCount == 0, startedByUs, !MCPSettings.shared.enabled else { return }
        startedByUs = false
        await MCPServer.shared.stop()
    }

    // MARK: - Agent configuration

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
}
#endif
