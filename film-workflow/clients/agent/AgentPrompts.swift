import Foundation
import SwiftData

/// System prompts for the agent window.
///
/// One prompt shared by every backend — the in-process loop and both CLI agents
/// see the same instructions, so behaviour doesn't drift depending on which
/// engine answered.
@MainActor
enum AgentPrompts {

    /// The whole system prompt for a turn.
    ///
    /// `toolNames` is passed in rather than derived here so the prompt can never
    /// promise a tool the policy is withholding.
    static func system(
        target: AgentTarget,
        toolNames: [String],
        policy: AgentWritePolicy,
        context: ModelContext,
        toolNamePrefix: String = ""
    ) -> String {
        var parts: [String] = []

        parts.append("""
            You are the assistant inside Film Studio, a macOS app for making \
            short films: music, narration, captions, generated images and \
            Remotion video compositions.

            You are not editing a code repository. Do not read, write or search \
            files on disk and do not run shell commands — the only exception is \
            the Remotion tools below, which edit one project's composition \
            source through the app. Everything you need is in the tools.
            """)

        parts.append(AgentTargetResolver.promptBlock(for: target, context: context))

        if !toolNames.isEmpty {
            let listed = toolNames.map { "- \(toolNamePrefix)\($0)" }.joined(separator: "\n")
            parts.append("""
                Tools available to you:
                \(listed)
                """)
        }

        parts.append("""
            Work in the app, not in prose. If the user asks for a change, make \
            it with a tool rather than describing what they could do. Prefer \
            searching over listing everything — caption_search_segments before \
            caption_list_segments, get_project before list_projects when you \
            already know the id.
            """)

        switch policy {
        case .review:
            parts.append("""
                Caption text is under review control: \(toolNamePrefix)caption_propose_edits \
                is the only way to change a caption, and it queues your changes \
                for the user to approve. Never claim you have changed a caption \
                — say what you have proposed. Everything else you do takes \
                effect immediately.
                """)
        case .direct:
            parts.append("""
                Your changes take effect immediately, including caption edits. \
                Be careful with anything that replaces existing work, and say \
                what you changed.
                """)
        }

        parts.append("""
            Keep your final reply short — a couple of sentences saying what you \
            did. The user can see the tool calls, so don't narrate them.
            """)

        return parts.joined(separator: "\n\n")
    }

    /// The turn itself: rolling summary, recent turns, then the new instruction.
    ///
    /// The project's contents are deliberately **not** inlined. A tool-calling
    /// agent should fetch what it needs, which is what makes a long transcript
    /// or a large composition workable at all.
    static func turn(
        instruction: String,
        summary: String,
        recentTurns: [AgentChatTurn]
    ) -> String {
        var parts: [String] = []
        if !summary.isEmpty {
            parts.append("Earlier in this conversation:\n\(summary)")
        }
        for turn in recentTurns {
            parts.append("\(turn.role.capitalized): \(turn.content)")
        }
        parts.append("Request: \(instruction)")
        return parts.joined(separator: "\n\n")
    }
}

/// One replayed conversation turn.
nonisolated struct AgentChatTurn: Sendable, Hashable {
    var role: String
    var content: String

    init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}
