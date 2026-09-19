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
    /// the user's endpoint and the subscription gateway are *different
    /// clients* in the SDK's sense, and sharing an id would collapse their
    /// per-thread session and model state into one bucket.
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
    /// - Parameter onModelRejected: Called on the main actor when the
    ///   subscription gateway refuses the model a turn asked for. The SDK
    ///   flattens a thrown error into a description string by the time it
    ///   reaches `AgentEvent.failed`, so the one chance to hand the app a
    ///   *typed* rejection — the thing an "open the picker" alert needs — is
    ///   here, inside the transport. Clients are built per thread, so the
    ///   handler already knows which thread to tell.
    static func makeClients(
        config: AppConfig?,
        onModelRejected: (@MainActor @Sendable (BackendError) -> Void)? = nil
    ) -> [any AgentClient] {
        AgentBackend.supported.compactMap { make($0, config: config, onModelRejected: onModelRejected) }
    }

    static func make(
        _ backend: AgentBackend,
        config: AppConfig?,
        onModelRejected: (@MainActor @Sendable (BackendError) -> Void)? = nil
    ) -> (any AgentClient)? {
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
                configuration: openAICompatibleConfiguration(config: config)
            )

        case .subscription:
            return OpenAIChatClient(
                id: clientID(for: backend),
                displayName: backend.engineLabel,
                configuration: subscriptionConfiguration(
                    config: config,
                    onModelRejected: onModelRejected
                )
            )

        case .claudeCode:
            #if os(macOS)
                return ClaudeCodeClient(
                    id: clientID(for: backend),
                    displayName: backend.engineLabel,
                    binaryPath: AgentBackendAvailability.shared.executablePath(for: backend),
                    // Inert while the turn supplies its own allowlist, which is
                    // always: `allowedToolArgument` drops the pre-approved set
                    // the moment `allowedTools` is non-nil. Kept in step with
                    // the policy anyway, so a turn that ever leaves the
                    // allowlist nil doesn't silently fall back to the SDK's
                    // narrower `defaultSafeTools`.
                    preapprovedTools: AgentToolPolicy.builtInTools
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
                    // App-server accepts non-git working directories.
                    //
                    // `approvalPolicy` is inert: the SDK derives the effective
                    // policy from the turn's `permissionMode`, which is
                    // `.default`, so Codex asks about every command and the
                    // answer comes from `AgentPolicyPermissions`. `sandbox` is
                    // the live one — under `.readOnly` a write fails inside
                    // Codex before our resolver is ever consulted, which is
                    // what used to keep its built-in tools out of reach.
                    approvalPolicy: .never,
                    sandbox: .dangerFullAccess
                )
            #else
                return nil
            #endif
        }
    }

    // MARK: - OpenAI-compatible configurations

    /// The user's own OpenAI-compatible endpoint: a plain URL, streamed.
    private static func openAICompatibleConfiguration(config: AppConfig?) -> OpenAIChatClient.Configuration {
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
        config: AppConfig?,
        onModelRejected: (@MainActor @Sendable (BackendError) -> Void)? = nil
    ) -> OpenAIChatClient.Configuration {
        let configured = config?.subscriptionChatModel.trimmingCharacters(in: .whitespaces)
        return OpenAIChatClient.Configuration.hosted(
            model: configured,
            extraBody: gatewayCaching
        ) { body in
            do {
                let data = try await BackendClient.shared.data(
                    "api/v1/ai/chat",
                    method: "POST",
                    body: body,
                    contentType: "application/json",
                    idempotencyKey: "chat:\(UUID().uuidString)"
                )
                await applyCreditBalance(from: data)
                return data
            } catch let error as BackendError {
                // Read off the body rather than off `configured`: a thread can
                // pin its own model in the engine menu, and it is that id —
                // not the one in Settings — the server just refused.
                let named = error.namingModel(
                    requestedModel(in: body) ?? configured ?? "",
                    capability: .chat
                )
                if named.unavailableModel != nil, let onModelRejected {
                    await MainActor.run { onModelRejected(named) }
                }
                throw named
            }
        }
    }

    /// The `model` field of an outgoing chat request.
    ///
    /// `nonisolated` because it is read from inside the transport closure,
    /// which the SDK runs off the main actor.
    private nonisolated static func requestedModel(in body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let model = json["model"] as? String,
              !model.isEmpty
        else { return nil }
        return model
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
