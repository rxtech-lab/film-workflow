import Foundation
import RxAgentSDK

/// Builds the `RxAgentSDK` clients that back this app's five engines.
///
/// Every engine is now an `AgentClient`, so the agent window has one code path
/// instead of three: the in-process loop, the CLI runners and the on-device
/// model all decode into the SDK's `AgentEvent` stream and fold into the same
/// transcript. What used to be `AgentRuntime` and `AgentCLIRunner` is gone —
/// their jobs are `OpenAIChatClient` and `ClaudeCodeClient`/`CodexClient`.
///
/// The app's own tools reach every one of them the same way: as an
/// ``MCPServerSpec`` pointing at this app's embedded MCP server. A CLI agent
/// gets it as a config file; the in-process clients speak MCP themselves. That
/// is what keeps a thread on Codex exactly as capable as one on the OpenAI
/// loop, which was the original point of the MCP bridge.
@MainActor
enum AgentClientFactory {

    /// The SDK client id for an engine.
    ///
    /// Not `AgentClientID.openAICompatible` for both OpenAI-shaped engines:
    /// BYOK and the subscription gateway are *different clients* in the SDK's
    /// sense, and sharing an id would collapse their per-thread session and
    /// model state into one bucket.
    static func clientID(for backend: AgentBackend) -> AgentClientID {
        switch backend {
        case .appleIntelligence: .foundationModels
        case .openAICompatible: .openAICompatible
        case .subscription: AgentClientID("rxfilm-subscription")
        case .claudeCode: .claudeCode
        case .codex: .codex
        }
    }

    static func backend(for clientID: AgentClientID) -> AgentBackend? {
        AgentBackend.supported.first { Self.clientID(for: $0) == clientID }
    }

    /// Every engine this platform can offer, in preference order.
    ///
    /// Built unconditionally rather than filtered by availability: a client that
    /// cannot run reports so through `isAvailable()`, and the engine menu needs
    /// to list it anyway so it can explain *why* it is unavailable.
    static func makeClients(config: AppConfig?) -> [any AgentClient] {
        AgentBackend.supported.compactMap { make($0, config: config) }
    }

    static func make(_ backend: AgentBackend, config: AppConfig?) -> (any AgentClient)? {
        switch backend {
        case .appleIntelligence:
            return FoundationModelsClient(
                id: clientID(for: backend),
                displayName: backend.engineLabel,
                contextBudget: backend.contextBudgetCharacters
            )

        case .openAICompatible:
            return OpenAIChatClient(
                id: clientID(for: backend),
                displayName: backend.engineLabel,
                configuration: byokConfiguration(config: config)
            )

        case .subscription:
            return OpenAIChatClient(
                id: clientID(for: backend),
                displayName: backend.engineLabel,
                configuration: subscriptionConfiguration(config: config)
            )

        case .claudeCode:
            #if os(macOS)
                return ClaudeCodeClient(
                    id: clientID(for: backend),
                    displayName: backend.engineLabel,
                    binaryPath: AgentBackendAvailability.shared.executablePath(for: backend),
                    // The agent has no business touching the filesystem here, so
                    // none of Claude's own tools are pre-approved. The turn's
                    // allowlist (see `AgentToolPolicy`) is the whole surface.
                    preapprovedTools: []
                )
            #else
                return nil
            #endif

        case .codex:
            #if os(macOS)
                return CodexClient(
                    id: clientID(for: backend),
                    displayName: backend.engineLabel,
                    binaryPath: AgentBackendAvailability.shared.executablePath(for: backend),
                    // App-server accepts non-git working directories. Keep the
                    // film package read-only; tools reach the app through MCP.
                    approvalPolicy: .never,
                    sandbox: .readOnly
                )
            #else
                return nil
            #endif
        }
    }

    // MARK: - OpenAI-compatible configurations

    /// Bring-your-own-key: a plain endpoint, streamed.
    private static func byokConfiguration(config: AppConfig?) -> OpenAIChatClient.Configuration {
        let endpoint = (config?.openAIEndpoint ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (config?.openAIKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        return OpenAIChatClient.Configuration(
            endpoint: resolveEndpoint(endpoint),
            defaultModel: config?.openAIModel.trimmingCharacters(in: .whitespaces),
            extraBody: gatewayCaching,
            streaming: true,
            headers: { key.isEmpty ? [:] : ["Authorization": "Bearer \(key)"] }
        )
    }

    /// The RxFilm gateway, reached through `BackendClient`.
    ///
    /// A hosted transport rather than a URL because this endpoint is not just an
    /// address: `BackendClient` holds the account's token and refreshes it, the
    /// call carries an idempotency key, and the reply carries the account's
    /// remaining credits, which have to land in `CreditBalanceStore` or the
    /// balance the user sees goes stale after every turn.
    ///
    /// The cost is streaming — `BackendClient` returns `Data`, so a subscription
    /// turn arrives in one block. Everything else behaves identically.
    private static func subscriptionConfiguration(
        config: AppConfig?
    ) -> OpenAIChatClient.Configuration {
        OpenAIChatClient.Configuration.hosted(
            model: config?.subscriptionChatModel.trimmingCharacters(in: .whitespaces),
            extraBody: gatewayCaching
        ) { body in
            let data = try await BackendClient.shared.data(
                "api/v1/ai/chat",
                method: "POST",
                body: body,
                contentType: "application/json",
                idempotencyKey: "chat:\(UUID().uuidString)"
            )
            await applyCreditBalance(from: data)
            return data
        }
    }

    /// Lets the Vercel AI Gateway pin a prompt-cache breakpoint. Every iteration
    /// of a tool-calling loop replays the system prompt; only appended tool
    /// results vary, so caching is the difference between paying for that prefix
    /// once and paying for it on every round.
    private static let gatewayCaching: [String: JSONValue] = [
        "providerOptions": .object([
            "gateway": .object(["caching": .string("auto")]),
        ]),
    ]

    private static func applyCreditBalance(from data: Data) async {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["rxlab_usage"] as? [String: Any],
              let available = usage["availablePoints"] as? Int
        else { return }
        await MainActor.run {
            CreditBalanceStore.shared.apply(available: available)
        }
    }

    /// Accepts the three shapes users actually paste: a bare host, a `/v1` base,
    /// or the full completions URL.
    static func resolveEndpoint(_ raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasSuffix("/chat/completions") {
            return URL(string: trimmed)
        }
        if trimmed.hasSuffix("/v1") || trimmed.contains("/v1/") {
            return URL(string: trimmed + "/chat/completions")
        }
        return URL(string: trimmed + "/v1/chat/completions")
    }
}
