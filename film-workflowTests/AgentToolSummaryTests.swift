import Foundation
import RxAgentSDK
import Testing

@testable import film_workflow

/// What a tool call is allowed to say in the transcript.
///
/// The rule the card exists to enforce is that a chat list shows one subject
/// and a count, never the whole argument dictionary — a regression here puts a
/// prompt, a file body or a UUID back in the middle of the conversation.
@Suite("Agent tool summary")
struct AgentToolSummaryTests {

    private func call(
        _ name: String,
        _ input: [String: JSONValue] = [:],
        result: String? = nil
    ) -> AgentToolCall {
        AgentToolCall(id: "t1", name: name, input: input, result: result, hasCompleteInput: true)
    }

    // MARK: - Titles

    @Test("Snake-cased names read as a sentence, verb first")
    func titles() {
        #expect(AgentToolSummary.title(for: "caption_update_segment") == "Update caption segment")
        #expect(AgentToolSummary.title(for: "create_project") == "Create project")
        #expect(AgentToolSummary.title(for: "image_generate") == "Generate image")
        #expect(AgentToolSummary.title(for: "move_project_to_group") == "Move project to group")
        #expect(AgentToolSummary.title(for: "video_job_status") == "Video job status")
    }

    @Test("Tools from other servers keep the name they came with")
    func foreignToolTitles() {
        #expect(AgentToolSummary.title(for: "Read") == "Read")
        #expect(AgentToolSummary.title(for: "Bash") == "Bash")
    }

    @Test("The MCP server prefix never reaches the card")
    func stripsPrefix() {
        let summary = AgentToolSummary(call: call("mcp__film_workflow__caption_export"))
        #expect(summary.name == "caption_export")
        #expect(summary.title == "Export caption")
    }

    // MARK: - Subject

    @Test("One argument names the subject, the rest are only counted")
    func subjectAndHiddenCount() {
        let summary = AgentToolSummary(call: call(
            "caption_update_segment",
            [
                "caption_id": .string("8F2C-AAAA"),
                "index": .number(12),
                "text": .string("Hello there"),
                "speaker": .string("Narrator"),
            ]
        ))
        #expect(summary.subject == "Hello there")
        #expect(summary.hiddenCount == 3)
    }

    @Test("An id alone is no subject — the card stays quiet rather than print a UUID")
    func idsAreNotSubjects() {
        let summary = AgentToolSummary(call: call(
            "caption_list_segments",
            ["caption_id": .string("8F2C-AAAA")]
        ))
        #expect(summary.subject == nil)
        #expect(summary.hiddenCount == 1)
    }

    @Test("Paths shorten to the file, prompts truncate, numbers keep their key")
    func subjectFormatting() {
        let path = AgentToolSummary(call: call(
            "remotion_write_file",
            ["path": .string("/Users/me/Films/a/src/Main.tsx"), "content": .string("…")]
        ))
        #expect(path.subject == "Main.tsx")

        let long = String(repeating: "a", count: 200)
        let prompt = AgentToolSummary(call: call("image_generate", ["prompt": .string(long)]))
        #expect(prompt.subject?.count == 57)  // 56 + the ellipsis
        #expect(prompt.subject?.hasSuffix("…") == true)

        let numbered = AgentToolSummary(call: call("sequence_remove_clip", ["index": .number(3)]))
        #expect(numbered.subject == "index 3")
    }

    @Test("A multi-line argument is flattened — the row is one line")
    func subjectIsSingleLine() {
        let summary = AgentToolSummary(call: call(
            "caption_update_segment",
            ["text": .string("first line\nsecond line")]
        ))
        #expect(summary.subject == "first line second line")
    }

    @Test("Structured arguments never become the subject")
    func structuredArgumentsStayHidden() {
        let summary = AgentToolSummary(call: call(
            "caption_set_speakers",
            ["caption_id": .string("x"), "labels": .array([.string("A"), .string("B")])]
        ))
        #expect(summary.subject == nil)
        #expect(summary.hiddenCount == 2)
    }

    @Test("Empty input means nothing to hide")
    func emptyInput() {
        let summary = AgentToolSummary(call: call("list_projects"))
        #expect(summary.subject == nil)
        #expect(summary.hiddenCount == 0)
    }
}
