import FilmTemplateKit
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

    /// Tools that only mean something inside a Simple mode run.
    ///
    /// A normal conversation has a transcript to ask questions in, so a wizard
    /// page there would have nowhere to appear; offering these to every thread
    /// would invite the agent to call one and get an error back.
    static let wizardOnly: Set<String> = Set(WizardTool.all)

    /// What a Simple mode thread is allowed to do.
    ///
    /// Narrower than a conversation on purpose. The wizard drives a fixed
    /// sequence of phases, and a tool outside that arc — rendering, podcasts,
    /// publishing to the marketplace — is a way for a run to wander off instead
    /// of producing the first cut the user asked for.
    ///
    /// Narrower is not the same as crippled, though. A run has no transcript to
    /// fall back on: whatever the wizard cannot do, nobody does. So everything
    /// on the path from a brief to a first cut belongs here, including the
    /// three that a run needs and a conversation can improvise around —
    /// reading the model catalog, taking a marketplace asset into the film, and
    /// authoring the Remotion cards the shot plan asks for.
    static let simpleModeTools: Set<String> = ([
        WebTool.read,
        "film_list",
        // `models_list` first: an item's model id is curated per account, so
        // without it the only way to name one is to guess, and every guess
        // comes back as "this model is not available for the selected
        // capability".
        "models_list",
        // `show_marketplace_item` is the only tool that draws a card, and the
        // card is the only thing carrying a Buy button — without it a paid
        // asset can never be bought, so the run reports it as un-owned and
        // moves on. `marketplace_add_to_film` is what actually lands an asset
        // in the library; `marketplace_install` only downloads it.
        "marketplace_list", "marketplace_get", "show_marketplace_item",
        "marketplace_install", "marketplace_add_to_film",
        "project_template_apply",
        "footage_list", "footage_get", "footage_create", "footage_update", "footage_import",
        "folder_list", "folder_create",
        "image_generate", "music_generate", "narration_generate",
        "sequence_list", "sequence_get", "sequence_create",
        "sequence_add_track", "sequence_reorder_tracks", "sequence_add_clip", "sequence_remove_clip", "sequence_set_timeline",
        "caption_create",
    ] as Set<String>).union(wizardOnly).union(remotionAuthoringTools)

    /// Composing and checking a Remotion card.
    ///
    /// Title cards, lower thirds and end cards are Remotion compositions, and a
    /// wizard run that can create one but cannot write its source, add an asset
    /// to it or look at the result is left placing a card it has never seen.
    /// Screenshots matter most: they are the run's only way to catch a shot
    /// that renders wrong, since the user does not see the cut until the
    /// preview at the end.
    #if os(macOS)
        static let remotionAuthoringTools: Set<String> = Set(
            RemotionMCPHandlers.descriptors.map(\.name)
        )
    #else
        static let remotionAuthoringTools: Set<String> = []
    #endif

    /// The descriptors a thread may call.
    static func descriptors(
        policy: AgentWritePolicy,
        mode: AgentThreadMode = .conversation
    ) -> [MCPToolDescriptor] {
        let withheld = withheldNames(policy: policy, mode: mode)
        return MCPToolRegistry.allDescriptors().filter { descriptor in
            guard !withheld.contains(descriptor.name) else { return false }
            guard case .simpleMode = mode else { return true }
            return simpleModeTools.contains(descriptor.name)
        }
    }

    static func toolNames(
        policy: AgentWritePolicy,
        mode: AgentThreadMode = .conversation
    ) -> [String] {
        descriptors(policy: policy, mode: mode).map(\.name)
    }

    static func withheldNames(
        policy: AgentWritePolicy,
        mode: AgentThreadMode = .conversation
    ) -> Set<String> {
        var withheld = switch policy {
        case .review: alwaysWithheld.union(reviewWithheld)
        case .direct: alwaysWithheld
        }
        if case .conversation = mode { withheld.formUnion(wizardOnly) }
        return withheld
    }

    static func allows(
        _ name: String,
        policy: AgentWritePolicy,
        mode: AgentThreadMode = .conversation
    ) -> Bool {
        // Decided first: a built-in is not in `MCPToolRegistry`, so the checks
        // below would judge it against lists it was never a candidate for and
        // allow or refuse it by accident.
        if isBuiltIn(name) { return !mode.isSimpleMode }
        guard !withheldNames(policy: policy, mode: mode).contains(name) else { return false }
        if case .simpleMode = mode, !simpleModeTools.contains(name) { return false }
        return !MCPMarketplaceHandlers.adminNames.contains(name)
            || MarketplaceAuthoringService.shared.canAuthor
    }

    // MARK: - Built-in engine tools

    /// A CLI engine's own tools, offered alongside the app's MCP surface.
    ///
    /// These belong to the `claude` and `codex` processes, not to us: they are
    /// not in `MCPToolRegistry`, so every other rule in this file — the write
    /// policy, the Simple mode allowlist, the admin check — is about names that
    /// can never appear here. They are decided in one place, ``isBuiltIn``.
    ///
    /// The list has to be exhaustive rather than indicative. `--allowedTools`
    /// is a complete enumeration of what is pre-approved, so a built-in left
    /// off it is a tool the model can see and cannot use — which reads to the
    /// user as the agent refusing to do its job.
    static let builtInTools: [String] = [
        "Bash", "BashOutput", "KillShell",
        "Edit", "MultiEdit", "Write", "NotebookEdit",
        "Read", "Glob", "Grep", "LS",
        "WebFetch", "WebSearch",
        "Task", "Agent", "TaskOutput",
        // Bookkeeping the CLI drives itself. Cheap to allow, and a refused
        // `TodoWrite` costs a wasted turn for nothing.
        "TodoRead", "TodoWrite", "ExitPlanMode", "AskUserQuestion",
    ]

    private static let builtInToolNames: Set<String> = Set(builtInTools)

    static func isBuiltIn(_ name: String) -> Bool {
        builtInToolNames.contains(name)
    }

    /// The built-ins a thread in `mode` may use.
    ///
    /// Empty for Simple mode. A wizard run is unattended by design — it shows
    /// one status line instead of a transcript, and `maxToolIterations` is
    /// raised so it can work for a long time without the user in the loop.
    /// A shell in that setting is a different proposition from a shell in a
    /// conversation somebody is watching, and nothing on the path from a brief
    /// to a first cut needs one: Remotion sources have
    /// `remotion_write_file`/`remotion_edit_file`.
    static func builtInTools(mode: AgentThreadMode) -> [String] {
        mode.isSimpleMode ? [] : builtInTools
    }

    /// Everything a turn may call: the MCP tools the policy exposes, plus the
    /// engine's own built-ins when it has any.
    static func allowedToolNames(
        policy: AgentWritePolicy,
        mode: AgentThreadMode = .conversation,
        includeBuiltIns: Bool
    ) -> [String] {
        toolNames(policy: policy, mode: mode)
            + (includeBuiltIns ? builtInTools(mode: mode) : [])
    }

    /// The MCP tools withheld from a turn.
    ///
    /// Built-ins are no longer added here. They used to be, as the structural
    /// half of a guarantee the prompt only asked for; the app now offers them
    /// deliberately, so the withholding that remains is the write policy's.
    static func disallowedToolNames(
        policy: AgentWritePolicy,
        mode: AgentThreadMode = .conversation
    ) -> [String] {
        Array(withheldNames(policy: policy, mode: mode))
    }
}

/// Answers a CLI agent's approval hook the way the allowlist already did.
///
/// Claude Code runs the `PreToolUse` hook for `Bash`, `Edit`, `Write`,
/// `MultiEdit` and every `mcp__*` call *before* it consults `--allowedTools`,
/// so a deny from the hook overrides the pre-approval and the model sees "the
/// user declined this tool call" for a tool the user never got asked about.
/// This resolver closes that gap: a tool the current write policy exposes is
/// allowed without a prompt (the policy is the user's standing answer), and
/// anything else is refused with a reason the model can act on rather than a
/// silent no.
///
/// It is also the *only* gate on Codex, which ignores `allowedTools` and
/// `disallowedTools` entirely and asks about a shell command or a file change
/// as a synthesised `Bash` or `Edit` request.
///
/// Reads the policy on every call rather than capturing it, so flipping
/// Settings › Write policy mid-conversation applies to the next tool call.
struct AgentPolicyPermissions: PermissionResolving {
    /// Which thread is asking. The allowlist is per thread now that Simple mode
    /// threads see a narrower surface, and this hook runs before
    /// `--allowedTools`, so without the thread it would allow a tool the turn
    /// was never offered.
    let threadID: UUID?

    init(threadID: UUID? = nil) {
        self.threadID = threadID
    }

    func resolve(_ request: PermissionRequest) async -> PermissionDecision {
        let bare = MCPToolName.bare(request.toolName)
        let threadID = threadID
        let allowed = await MainActor.run {
            AgentToolPolicy.allows(
                bare,
                policy: AgentSettings.shared.writePolicy,
                mode: AgentController.shared.mode(forThreadID: threadID)
            )
        }
        if allowed { return .allow }
        return .denyWithReason(
            reason: "\(bare) is not available in this conversation. "
                + "Use the tools listed in the system prompt instead."
        )
    }
}
