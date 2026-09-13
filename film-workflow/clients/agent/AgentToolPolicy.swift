import Foundation
import RxAgentSDK

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
    /// it replaces every caption on the item, which is the largest destructive
    /// edit in the app and not something to do without being asked.
    static let reviewWithheld: Set<String> = [
        "caption_update_segment",
        "caption_transcribe",
    ]

    /// Tools never offered to the agent under any policy.
    ///
    /// Deleting footage or a folder is not something a conversational agent
    /// should be one hallucinated argument away from; the user has a delete
    /// button in the library.
    static let alwaysWithheld: Set<String> = [
        "footage_delete",
        "folder_delete",
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
        !withheldNames(policy: policy).contains(name) && (!MCPMarketplaceHandlers.adminNames.contains(name) || MarketplaceAuthoringService.shared.canAuthor)
    }

    // MARK: - Coding-agent tools

    /// A CLI agent's own built-in tools, all of which are withheld.
    ///
    /// The agent window is not a coding agent: it works entirely through the
    /// MCP tools above, and the system prompt says as much. But a prompt is a
    /// request, not a guarantee — a model that decides to `Bash` its way to an
    /// answer would be running shell commands against the user's machine on the
    /// strength of a sentence asking it not to.
    ///
    /// So the real guarantee is structural, in two layers: `--allowedTools`
    /// names only our MCP surface, so nothing else is pre-approved, and these
    /// names are additionally passed to `--disallowedTools` so an attempt is
    /// refused outright rather than routed to an approval resolver that has no
    /// UI to ask with.
    static let codingAgentTools: [String] = [
        "Bash", "BashOutput", "KillShell",
        "Edit", "MultiEdit", "Write", "NotebookEdit",
        "Read", "Glob", "Grep", "LS",
        "WebFetch", "WebSearch",
        "Task", "Agent", "TaskOutput",
    ]

    /// Everything withheld from a turn: the policy's own withholdings plus the
    /// agent's built-in tools.
    static func disallowedToolNames(policy: AgentWritePolicy) -> [String] {
        Array(withheldNames(policy: policy)) + codingAgentTools
    }
}

/// Answers a CLI agent's approval hook the way the allowlist already did.
///
/// Claude Code runs the `PreToolUse` hook for every `mcp__*` call *before* it
/// consults `--allowedTools`, so a deny from the hook overrides the
/// pre-approval and the model sees "the user declined this tool call" for a
/// tool the user never got asked about. This resolver closes that gap: a tool
/// the current write policy exposes is allowed without a prompt (the policy is
/// the user's standing answer), and anything else is refused with a reason the
/// model can act on rather than a silent no.
///
/// Reads the policy on every call rather than capturing it, so flipping
/// Settings › Write policy mid-conversation applies to the next tool call.
struct AgentPolicyPermissions: PermissionResolving {
    func resolve(_ request: PermissionRequest) async -> PermissionDecision {
        let bare = MCPToolName.bare(request.toolName)
        let allowed = await MainActor.run {
            AgentToolPolicy.allows(bare, policy: AgentSettings.shared.writePolicy)
        }
        if allowed { return .allow }
        return .denyWithReason(
            reason: "\(bare) is not available in this conversation. "
                + "Use the tools listed in the system prompt instead."
        )
    }
}
