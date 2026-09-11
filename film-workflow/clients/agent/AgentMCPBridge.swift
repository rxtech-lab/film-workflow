#if os(macOS)
import Foundation
import RxAgentSDK

/// Points every agent engine at this app's own MCP server.
///
/// The insight that makes all five engines cheap: Claude Code and Codex are
/// general coding agents that need a permission broker because they can write
/// files and run shells. Ours needs neither — it works entirely through tools
/// this app already exposes over MCP. So instead of porting an agent runtime we
/// scope each engine to our own tools and let it call back in, which means the
/// in-process clients and the CLI agents reach the identical
/// `MCPToolRegistry.invoke` and cannot drift apart.
///
/// What changed in the RxAgentSDK migration: this no longer renders anyone's
/// config dialect. It hands back an ``MCPServerSpec`` and the SDK writes
/// Claude's `--mcp-config`, Codex's `-c mcp_servers.…` overrides, or connects
/// to it directly from an in-process client. The per-CLI config rendering that
/// used to live here was the main thing that had to be updated whenever a CLI
/// changed its flags.
@MainActor
enum AgentMCPBridge {

    /// Key for our server in the agent's MCP config. Also the tool-name prefix
    /// a CLI agent sees (`mcp__film_workflow__caption_search_segments`), so it
    /// has to be a valid identifier — the server's own name has a hyphen.
    nonisolated static let serverKey = "film_workflow"

    nonisolated static let documentHeader = "X-RxFilm-Document"

    nonisolated static func prefix(_ name: String) -> String {
        MCPToolName.prefixed(name, server: serverKey)
    }

    // MARK: - Lifecycle

    /// How many turns are currently relying on the server we started.
    ///
    /// Refcounted because threads run concurrently: without this, the first of
    /// two overlapping turns to finish would stop the server out from under the
    /// second, which would then fail every remaining tool call. Only the last
    /// release actually stops it, and only if the user hadn't enabled the
    /// server themselves.
    private static var holdCount = 0
    private static var startedByUs = false

    /// Starts the MCP server if it isn't already up, and returns the spec that
    /// points an agent at it.
    ///
    /// A user who has never enabled the MCP server still expects the agent to
    /// work, so this starts one on demand rather than telling them to go turn a
    /// setting on — and `release` puts it back the way it was.
    static func acquire(documentID: UUID? = nil) async throws -> MCPServerSpec {
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
                    + "agent has no way to reach your projects."
            )
        }

        holdCount += 1

        var headers: [String: String] = [:]
        if let token = settings.token, !token.isEmpty {
            // The SDK routes this to Claude's config headers and to Codex's
            // `bearer_token_env_var`, which keeps it out of `ps` output.
            headers["Authorization"] = "Bearer \(token)"
        }
        if let documentID {
            // Pins every tool call from this session to one film.
            headers[documentHeader] = documentID.uuidString
        }

        guard let url = URL(string: "http://127.0.0.1:\(port)/mcp") else {
            throw CaptionAIError.backendUnavailable(.claudeCode, "Invalid MCP server address.")
        }
        return MCPServerSpec.http(name: serverKey, url: url, headers: headers)
    }

    /// Releases one hold, stopping the server again once the last one goes and
    /// we were the ones who started it.
    static func release() async {
        holdCount = max(0, holdCount - 1)
        guard holdCount == 0, startedByUs, !MCPSettings.shared.enabled else { return }
        startedByUs = false
        await MCPServer.shared.stop()
    }

    /// Environment every CLI engine is launched with, so `node`, `npx` and the
    /// rest resolve the way they do in the user's shell.
    nonisolated static func environment() -> [String: String] {
        RemotionRuntime.enrichedEnvironment()
    }
}
#endif
