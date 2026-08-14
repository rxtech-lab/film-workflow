import Foundation
import SwiftData

/// What the agent does as a turn unfolds, in the order it happens.
///
/// Every backend produces this same stream — the in-process loop below and both
/// CLI engines — so the UI renders tool activity identically regardless of which
/// engine answered.
nonisolated enum AgentEvent: Sendable {
    case status(String)
    case toolCall(id: String, name: String, args: String)
    case toolResult(id: String, name: String, summary: String, ok: Bool)
    case assistantText(String)
    /// A CLI backend reported its native session id, for resuming this thread.
    case sessionID(String)
    case completed
}

nonisolated enum AgentRuntimeError: LocalizedError {
    case missingLLMConfig
    case missingSubscriptionModel
    case maxIterationsExceeded(Int)

    var errorDescription: String? {
        switch self {
        case .missingLLMConfig:
            return "Set an OpenAI-compatible endpoint, key and model in Settings › AI Provider."
        case .missingSubscriptionModel:
            return "Choose a chat model in Settings › AI Provider, or pick one from the engine menu below the composer."
        case .maxIterationsExceeded(let n):
            return "The agent stopped after \(n) rounds of tool calls without finishing."
        }
    }
}

/// Everything a turn needs, resolved before it starts.
nonisolated struct AgentRunRequest: Sendable {
    var instruction: String
    var summary: String
    var recentTurns: [AgentChatTurn]
    var target: AgentTarget
    var policy: AgentWritePolicy
    var maxIterations: Int
}

/// Posted after a tool call that changed a project, so a tab showing that
/// project can refresh.
///
/// Replaces the Remotion agent's `onFileWritten` callback: the agent no longer
/// knows what a Remotion file is, but every mutation still goes through one
/// place, so one notification covers all of them.
extension Notification.Name {
    static let agentDidMutateProject = Notification.Name("agentDidMutateProject")
}

/// The in-process tool-calling loop, over the app's own MCP tools.
///
/// Descended from the Remotion agent's loop, which was the only real
/// tool-calling implementation in the app. What changed is where tools come
/// from: instead of seven hardcoded Remotion functions it asks
/// `AgentToolPolicy` for descriptors and dispatches through
/// `MCPToolRegistry.invoke` — the same entry point external agents reach over
/// HTTP. The loop mechanics are unchanged, and the comments below explain which
/// parts are load-bearing.
@MainActor
enum AgentRuntime {

    /// Tool result text longer than this is truncated before it goes back to
    /// the model. Individual handlers cap their own output, but a paginated
    /// list with a large limit can still be big enough to crowd out the
    /// conversation.
    private static let maxToolResultCharacters = 120_000

    /// `route` and `model` are resolved by the caller rather than read back out
    /// of `config`: the engine a thread picked decides where the turn goes, and
    /// a thread may pin a model the settings don't name.
    static func run(
        request: AgentRunRequest,
        config: AppConfig,
        route: AIRoute,
        model: String,
        container: ModelContainer
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    try await runLoop(
                        request: request,
                        config: config,
                        route: route,
                        model: model,
                        container: container,
                        emit: { continuation.yield($0) }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Loop

    private static func runLoop(
        request: AgentRunRequest,
        config: AppConfig,
        route: AIRoute,
        model: String,
        container: ModelContainer,
        emit: @escaping (AgentEvent) -> Void
    ) async throws {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw route == .subscription
                ? AgentRuntimeError.missingSubscriptionModel
                : AgentRuntimeError.missingLLMConfig
        }

        let tools = AgentToolPolicy.openAIToolDefinitions(policy: request.policy)
        let context = ModelContext(container)

        // Cache the static prefix (system prompt) so the Vercel AI Gateway pins a
        // prompt-cache breakpoint there. Every iteration replays these tokens;
        // only newly appended tool results vary.
        var messages: [OpenAIRichMessage] = []
        messages.append(OpenAIRichMessage(
            role: "system",
            content: AgentPrompts.system(
                target: request.target,
                toolNames: tools.map(\.name),
                policy: request.policy,
                context: context
            ),
            cacheControl: true
        ))
        messages.append(OpenAIRichMessage(
            role: "user",
            content: AgentPrompts.turn(
                instruction: request.instruction,
                summary: request.summary,
                recentTurns: request.recentTurns
            ),
            cacheControl: true
        ))

        for _ in 0..<max(1, request.maxIterations) {
            try Task.checkCancellation()

            let response: OpenAIAssistantResponse
            switch route {
            case .subscription:
                response = try await OpenAIClient.chatWithToolsViaSubscription(
                    messages: messages,
                    tools: tools,
                    model: model,
                    extraBody: ["providerOptions": ["gateway": ["caching": "auto"]]]
                )
            case .byok:
                response = try await OpenAIClient.chatWithTools(
                    messages: messages,
                    tools: tools,
                    endpoint: config.openAIEndpoint,
                    apiKey: config.openAIKey,
                    model: model,
                    extraBody: ["providerOptions": ["gateway": ["caching": "auto"]]]
                )
            }

            if let text = response.content?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                emit(.assistantText(text))
            }

            if response.toolCalls.isEmpty {
                emit(.completed)
                return
            }

            let assistantIndex = messages.count
            messages.append(OpenAIRichMessage(
                role: "assistant",
                content: response.content,
                toolCalls: response.toolCalls
            ))

            // Tool results for this assistant turn must form a contiguous block
            // immediately after it — Anthropic (via the Vercel AI Gateway)
            // rejects interleaved roles. Image attachments are user-role, so
            // they are held back until the whole tool_result block is in place.
            var pendingUserFollowups: [OpenAIRichMessage] = []

            for call in response.toolCalls {
                try Task.checkCancellation()
                emit(.toolCall(id: call.id, name: call.name, args: call.argumentsJSON))

                do {
                    try await dispatch(
                        call: call,
                        policy: request.policy,
                        container: container,
                        messages: &messages,
                        pendingUserFollowups: &pendingUserFollowups,
                        emit: emit
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    emit(.toolResult(
                        id: call.id,
                        name: call.name,
                        summary: "failed: \(error.localizedDescription)",
                        ok: false
                    ))
                    messages.append(OpenAIRichMessage(
                        role: "tool",
                        content: errorJSON(error.localizedDescription),
                        toolCallId: call.id,
                        name: call.name
                    ))
                }
            }

            // Safety net: every tool_call must have a matching tool_result before
            // the next request, or the conversation is malformed. A dispatch that
            // threw before appending gets a stub here.
            ensureToolResults(
                forAssistantAt: assistantIndex,
                expectedCalls: response.toolCalls,
                in: &messages
            )

            messages.append(contentsOf: pendingUserFollowups)
        }

        throw AgentRuntimeError.maxIterationsExceeded(request.maxIterations)
    }

    // MARK: - Dispatch

    private static func dispatch(
        call: OpenAIToolCall,
        policy: AgentWritePolicy,
        container: ModelContainer,
        messages: inout [OpenAIRichMessage],
        pendingUserFollowups: inout [OpenAIRichMessage],
        emit: (AgentEvent) -> Void
    ) async throws {
        // The model can only have seen allowed tools, but a hallucinated name
        // must not become a way around the policy.
        guard AgentToolPolicy.allows(call.name, policy: policy) else {
            let message = "\(call.name) is not available. "
                + "Use caption_propose_edits to change captions."
            emit(.toolResult(id: call.id, name: call.name, summary: message, ok: false))
            messages.append(OpenAIRichMessage(
                role: "tool",
                content: errorJSON(message),
                toolCallId: call.id,
                name: call.name
            ))
            return
        }

        let arguments = parseArgs(call.argumentsJSON)
        let result = try await MCPToolRegistry.invoke(
            name: call.name,
            arguments: arguments,
            container: container
        )

        let isError = (result["isError"] as? Bool) ?? false
        let parsed = split(content: result["content"])

        // Structured content is what a tool means; the text blocks are its
        // rendering. Prefer structured when both exist so the model reads the
        // machine-readable form.
        var body = parsed.text
        if let structured = result["structuredContent"],
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            body = json
        }
        if body.isEmpty { body = isError ? "{\"ok\":false}" : "{\"ok\":true}" }
        if body.count > maxToolResultCharacters {
            body = String(body.prefix(maxToolResultCharacters)) + "\n…(truncated)"
        }

        messages.append(OpenAIRichMessage(
            role: "tool",
            content: body,
            toolCallId: call.id,
            name: call.name
        ))

        // Images come back as MCP image blocks (base64 + mimeType) and have to
        // be re-sent as user-role image parts — a tool_result cannot carry an
        // image in the OpenAI shape. This is how the agent actually sees a
        // rendered Remotion frame.
        if !parsed.images.isEmpty {
            var followupParts: [OpenAIContentPart] = [
                .text("Result of \(call.name):")
            ]
            for dataURL in parsed.images {
                followupParts.append(.imageURL(dataURL))
            }
            pendingUserFollowups.append(
                OpenAIRichMessage(role: "user", parts: followupParts)
            )
        }

        emit(.toolResult(
            id: call.id,
            name: call.name,
            summary: summarize(parsed.text.isEmpty ? body : parsed.text),
            ok: !isError
        ))

        if !isError {
            NotificationCenter.default.post(
                name: .agentDidMutateProject,
                object: nil,
                userInfo: ["tool": call.name]
            )
        }
    }

    // MARK: - Result parsing

    private struct ParsedContent {
        var text: String = ""
        /// `data:` URLs, ready for `OpenAIContentPart.imageURL`.
        var images: [String] = []
    }

    private static func split(content: Any?) -> ParsedContent {
        guard let blocks = content as? [[String: Any]] else { return ParsedContent() }
        var parsed = ParsedContent()
        var texts: [String] = []

        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String { texts.append(text) }
            case "image":
                guard let data = block["data"] as? String, !data.isEmpty else { continue }
                let mime = (block["mimeType"] as? String) ?? "image/png"
                parsed.images.append("data:\(mime);base64,\(data)")
            default:
                continue
            }
        }

        parsed.text = texts.joined(separator: "\n")
        return parsed
    }

    /// One short line for the tool card in the transcript.
    private static func summarize(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > 200 ? String(collapsed.prefix(200)) + "…" : collapsed
    }

    // MARK: - Helpers

    private static func ensureToolResults(
        forAssistantAt assistantIndex: Int,
        expectedCalls: [OpenAIToolCall],
        in messages: inout [OpenAIRichMessage]
    ) {
        guard assistantIndex >= 0, assistantIndex < messages.count else { return }

        // Walk forward from the assistant message over the contiguous run of
        // tool-role messages belonging to this turn.
        var present: Set<String> = []
        var index = assistantIndex + 1
        while index < messages.count, messages[index].role == "tool" {
            if let id = messages[index].toolCallId { present.insert(id) }
            index += 1
        }

        for call in expectedCalls where !present.contains(call.id) {
            messages.insert(
                OpenAIRichMessage(
                    role: "tool",
                    content: "{\"ok\":false,\"error\":\"no result\"}",
                    toolCallId: call.id,
                    name: call.name
                ),
                at: index
            )
            index += 1
        }
    }

    private static func parseArgs(_ raw: String) -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }

    private static func errorJSON(_ message: String) -> String {
        "{\"ok\":false,\"error\":\(jsonString(message))}"
    }

    private static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: [s],
            options: [.fragmentsAllowed]
        )) ?? Data()
        guard var encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        if encoded.hasPrefix("["), encoded.hasSuffix("]") {
            encoded.removeFirst()
            encoded.removeLast()
        }
        return encoded
    }
}
