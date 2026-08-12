import Foundation

/// How much the agent is allowed to change without asking.
nonisolated enum AgentWritePolicy: String, CaseIterable, Identifiable, Sendable {
    /// Tools that write captions in place are withheld, so caption edits have to
    /// go through `caption_propose_edits` and land in the review sheet.
    case review
    /// Everything is exposed. The agent can write captions directly.
    case direct

    var id: String { rawValue }
}

/// Which MCP tools an agent thread may call.
///
/// The rule is deliberately simple: **every thread sees every tool, regardless
/// of which tab it was opened from or what it targets.** That is the point of
/// the system-wide window — a thread opened from Music can fix a caption, and a
/// caption thread can read a Remotion composition. The thread's target only
/// shapes the system prompt (see `AgentTargetResolver.promptBlock`), it does not
/// gate capability.
///
/// The one exception is the write policy. Under `.review`, tools that mutate
/// captions in place are withheld so the agent's only route to changing a
/// caption is `caption_propose_edits`, which queues a proposal for the user to
/// approve. This is the same guarantee the old caption-only CLI allowlist gave,
/// preserved now that the allowlist itself is gone.
@MainActor
enum AgentToolPolicy {

    /// Tools withheld under `.review` because they write captions immediately.
    ///
    /// `caption_transcribe` is here for the same reason as `caption_update_segment`:
    /// it replaces every caption in the project, which is the largest destructive
    /// edit in the app and not something to do without being asked.
    static let reviewWithheld: Set<String> = [
        "caption_update_segment",
        "caption_transcribe",
    ]

    /// Tools never offered to the agent under any policy.
    ///
    /// Deleting a project is not something a conversational agent should be one
    /// hallucinated argument away from; the user has a delete button.
    static let alwaysWithheld: Set<String> = [
        "delete_project",
        "delete_project_group",
    ]

    /// The descriptors a thread may call.
    static func descriptors(policy: AgentWritePolicy) -> [MCPToolDescriptor] {
        let withheld = withheldNames(policy: policy)
        return MCPToolRegistry.allDescriptors().filter { !withheld.contains($0.name) }
    }

    static func toolNames(policy: AgentWritePolicy) -> [String] {
        descriptors(policy: policy).map(\.name)
    }

    static func withheldNames(policy: AgentWritePolicy) -> Set<String> {
        switch policy {
        case .review: return alwaysWithheld.union(reviewWithheld)
        case .direct: return alwaysWithheld
        }
    }

    static func allows(_ name: String, policy: AgentWritePolicy) -> Bool {
        !withheldNames(policy: policy).contains(name)
    }

    // MARK: - Conversion

    /// MCP descriptors as OpenAI function-calling definitions.
    ///
    /// A straight field rename — `MCPToolDescriptor.inputSchema` and
    /// `OpenAIToolDefinition.parametersSchema` are both a JSON Schema object —
    /// which is what makes the in-process runtime and the CLI backends able to
    /// share one tool surface without a translation layer.
    static func openAIToolDefinitions(policy: AgentWritePolicy) -> [OpenAIToolDefinition] {
        descriptors(policy: policy).map {
            OpenAIToolDefinition(
                name: $0.name,
                description: $0.description,
                parametersSchema: $0.inputSchema
            )
        }
    }
}
