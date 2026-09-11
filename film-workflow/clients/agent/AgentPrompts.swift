import Foundation
import RxAgentSDK
import SwiftData

/// The agent window's instructions, as an `AgentContext`.
///
/// One context shared by every engine — the in-process clients and both CLI
/// agents see the same instructions, so behaviour doesn't drift depending on
/// which engine answered. The SDK renders it into `--append-system-prompt` for
/// Claude, a prompt prefix for Codex and ACP, and a `system` message for the
/// in-process clients.
///
/// Nothing here replays the conversation any more: `Agent` carries the
/// transcript in `AgentSendRequest.history` and its own rolling summary, so the
/// `turn(instruction:summary:recentTurns:)` builder this replaces is gone.
@MainActor
enum AgentPrompts {

    /// `toolNames` is passed in rather than derived here so the prompt can never
    /// promise a tool the policy is withholding.
    static func context(
        target: AgentTarget,
        toolNames: [String],
        policy: AgentWritePolicy,
        context modelContext: ModelContext,
        toolNamePrefix: String = ""
    ) -> AgentContext {
        AgentContext {
            """
            You are the assistant inside Film Studio, a macOS app for making \
            short films: music, narration, captions, generated images and \
            Remotion video compositions.

            You are not editing a code repository. Do not read, write or search \
            files on disk and do not run shell commands — the only exception is \
            the Remotion tools below, which edit one project's composition \
            source through the app. Everything you need is in the tools.
            """

            AgentTargetResolver.promptBlock(for: target, context: modelContext)

            if let doc = ProjectDocumentController.shared.document(
                forContainer: modelContext.container
            ) {
                """
                The open film is "\(doc.displayName)" (document id \(doc.id.uuidString)); \
                tools act on it unless you pass `document` to address another open film.
                """
            }

            if !toolNames.isEmpty {
                """
                Tools available to you:
                \(toolNames.map { "- \(toolNamePrefix)\($0)" }.joined(separator: "\n"))
                """
            }

            """
            Work in the app, not in prose. If the user asks for a change, make \
            it with a tool rather than describing what they could do. Prefer \
            searching over listing everything — caption_search_segments before \
            caption_list_segments, get_project before list_projects when you \
            already know the id.
            """

            #if os(macOS)
                if toolNames.contains(where: { $0.hasPrefix("remotion_") }) {
                    RemotionMCPHandlers.authoringInstructions
                }
            #endif

            switch policy {
            case .review:
                """
                Captions are under review control: \(toolNamePrefix)caption_propose_edits \
                is the only way to change one, and it queues your changes for \
                the user to approve. It covers wording, splits and merges, \
                timing (retime) and a single line's translation \
                (set_translation) — so a one-line translation fix goes here, \
                not through \(toolNamePrefix)caption_translate, which redoes a \
                whole language. Never claim you have changed a caption — say \
                what you have proposed. Everything else you do takes effect \
                immediately.
                """
            case .direct:
                """
                Your changes take effect immediately, including caption edits. \
                Be careful with anything that replaces existing work, and say \
                what you changed.
                """
            }

            """
            Keep your final reply short — a couple of sentences saying what you \
            did. The user can see the tool calls, so don't narrate them.
            """
        }
    }

    /// The instruction handed to whichever engine compacts a thread's history.
    static func summarizationInstruction(existing: String, transcript: String) -> String {
        var parts: [String] = []
        if !existing.isEmpty {
            parts.append("The conversation so far has been summarized as:\n\(existing)")
        }
        parts.append("""
            Summarize the conversation below in at most three sentences, folding \
            in the summary above if there is one. Keep decisions, identifiers \
            and anything still outstanding. Drop pleasantries. Reply with the \
            summary only.

            \(transcript)
            """)
        return parts.joined(separator: "\n\n")
    }
}
