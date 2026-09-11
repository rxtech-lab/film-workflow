import Foundation
import RxAgentSDK
import SwiftData
import Testing

@testable import film_workflow

/// The seams where this app meets RxAgentSDK.
///
/// Each of these is a place where a mistake is invisible until a user hits it:
/// a thread that forgets which engine it was on, a reloaded conversation that
/// replays turns it had already compacted away, or a tool spelling that the
/// write policy fails to catch.
/// The app's `AgentThread`/`AgentMessage` SwiftData models share their names
/// with the SDK's value types, so both are spelled out below wherever one is
/// constructed.
@Suite("RxAgentSDK migration")
@MainActor
struct AgentSDKMigrationTests {

    private func makeStore() throws -> ModelContext {
        let schema = Schema([film_workflow.AgentThread.self, film_workflow.AgentMessage.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    // MARK: - Client identity

    @Test("Every engine maps to a distinct SDK client id, and back")
    func clientIDsRoundTrip() {
        var seen: Set<AgentClientID> = []
        for backend in AgentBackend.supported {
            let id = AgentClientFactory.clientID(for: backend)
            #expect(seen.insert(id).inserted, "duplicate client id for \(backend.rawValue)")
            #expect(AgentClientFactory.backend(for: id) == backend)
        }
    }

    /// BYOK and the subscription gateway are both OpenAI-shaped, but they are
    /// different accounts with different models. Sharing a client id would
    /// collapse their per-thread session and model state into one bucket.
    @Test("The two OpenAI-shaped engines do not share a client id")
    func openAIEnginesAreDistinct() {
        #expect(
            AgentClientFactory.clientID(for: .openAICompatible)
                != AgentClientFactory.clientID(for: .subscription)
        )
    }

    @Test("Endpoints are resolved from all three shapes users paste")
    func endpointResolution() {
        #expect(
            AgentClientFactory.resolveEndpoint("https://api.openai.com/v1")?.absoluteString
                == "https://api.openai.com/v1/chat/completions"
        )
        #expect(
            AgentClientFactory.resolveEndpoint("https://api.openai.com/v1/chat/completions")?
                .absoluteString == "https://api.openai.com/v1/chat/completions"
        )
        #expect(
            AgentClientFactory.resolveEndpoint("https://example.com/")?.absoluteString
                == "https://example.com/v1/chat/completions"
        )
        #expect(AgentClientFactory.resolveEndpoint("   ") == nil)
    }

    // MARK: - Transcript round trip

    @Test("A persisted transcript reloads into the SDK thread")
    func transcriptRoundTrip() throws {
        let context = try makeStore()
        let thread = film_workflow.AgentThread(title: "Test")
        context.insert(thread)

        AgentTranscriptStore.append(role: .user, content: "hello", to: thread, context: context)
        let tool = film_workflow.AgentMessage(
            role: .assistant,
            content: "",
            kind: .tool,
            toolName: "caption_export",
            toolArgs: #"{"caption_id":"abc"}"#,
            toolResult: "done",
            toolStatus: .ok,
            toolCallId: "call_1"
        )
        AgentTranscriptStore.attach(tool, to: thread, context: context)
        AgentTranscriptStore.append(role: .assistant, content: "exported", to: thread, context: context)

        let sdkThread = AgentTranscriptStore.load(thread)

        #expect(sdkThread.messages.count == 3)
        #expect(sdkThread.messages[0].plainText == "hello")

        let call = try #require(sdkThread.messages[1].toolCalls.first)
        #expect(call.name == "caption_export")
        #expect(call.input["caption_id"]?.stringValue == "abc")
        #expect(call.result == "done")
        #expect(!call.isError)
        #expect(sdkThread.messages[2].plainText == "exported")
    }

    /// A spinner that survives a relaunch never stops, because the process that
    /// would have completed the call is gone.
    @Test("A tool row still pending on reload comes back failed, not spinning")
    func stalledToolRowReloadsAsFailed() throws {
        let context = try makeStore()
        let thread = film_workflow.AgentThread()
        context.insert(thread)

        let tool = film_workflow.AgentMessage(
            role: .assistant,
            content: "",
            kind: .tool,
            toolName: "caption_transcribe",
            toolStatus: .pending,
            toolCallId: "call_1"
        )
        AgentTranscriptStore.attach(tool, to: thread, context: context)

        let call = try #require(AgentTranscriptStore.load(thread).messages.first?.toolCalls.first)
        #expect(call.isComplete)
        #expect(call.isError)
    }

    /// Compaction is keyed by message id, so a reload that minted fresh ids
    /// would silently replay everything the last session had folded away.
    @Test("Compaction state survives a reload")
    func compactionSurvivesReload() throws {
        let context = try makeStore()
        let thread = film_workflow.AgentThread()
        context.insert(thread)

        let old = AgentTranscriptStore.append(
            role: .user, content: "ancient history", to: thread, context: context
        )
        old.isCompacted = true
        AgentTranscriptStore.append(
            role: .user, content: "recent", to: thread, context: context
        )
        thread.summary = "they discussed ancient history"

        let sdkThread = AgentTranscriptStore.load(thread)

        #expect(sdkThread.summary == "they discussed ancient history")
        #expect(sdkThread.messages.count == 2)
        #expect(sdkThread.replayableHistory().map(\.plainText) == ["recent"])
    }

    @Test("Per-engine resume ids survive a round trip")
    func sessionIDsRoundTrip() throws {
        let context = try makeStore()
        let thread = film_workflow.AgentThread()
        context.insert(thread)
        thread.setProviderSessionID("claude-session", for: .claudeCode)
        thread.setProviderSessionID("codex-session", for: .codex)

        let sdkThread = AgentTranscriptStore.load(thread)
        #expect(sdkThread.resumeID(for: AgentClientFactory.clientID(for: .claudeCode))
            == "claude-session")
        #expect(sdkThread.resumeID(for: AgentClientFactory.clientID(for: .codex))
            == "codex-session")

        // And back the other way, after a turn reports a new one.
        let fresh = film_workflow.AgentThread()
        context.insert(fresh)
        AgentTranscriptStore.saveSessionIDs(from: sdkThread, to: fresh)
        #expect(fresh.providerSessionID(for: .claudeCode) == "claude-session")
        #expect(fresh.providerSessionID(for: .codex) == "codex-session")
    }

    /// A proposal is reviewed through the app's own sheet and has no SDK
    /// equivalent; what the *model* needs to know is the outcome, which arrives
    /// as a separate system row.
    @Test("Proposal rows are not replayed to the model")
    func proposalRowsAreNotReplayed() throws {
        let context = try makeStore()
        let thread = film_workflow.AgentThread()
        context.insert(thread)

        let proposal = film_workflow.AgentMessage(
            role: .assistant,
            content: "3 changes",
            kind: .proposal,
            proposalProjectUUID: UUID()
        )
        AgentTranscriptStore.attach(proposal, to: thread, context: context)
        AgentTranscriptStore.append(
            role: .system,
            content: "The user applied 2 of 3 proposed changes.",
            to: thread,
            context: context
        )

        let sdkThread = AgentTranscriptStore.load(thread)
        #expect(sdkThread.messages.count == 1)
        #expect(sdkThread.messages[0].role == .system)
        #expect(sdkThread.messages[0].plainText.contains("applied 2 of 3"))
    }

    // MARK: - Prompt

    @Test("The prompt names tools the way the engine will see them")
    func promptUsesTheRightToolSpelling() throws {
        let schema = Schema([film_workflow.AgentThread.self, film_workflow.AgentMessage.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let names = AgentToolPolicy.toolNames(policy: .review)

        // A CLI agent namespaces everything it discovers over MCP…
        let cli = AgentPrompts.context(
            target: AgentTarget.none,
            toolNames: names,
            policy: .review,
            context: container.mainContext,
            toolNamePrefix: "mcp__film_workflow__"
        ).renderText()
        #expect(cli.contains("mcp__film_workflow__caption_export"))

        // …while an in-process client speaks MCP itself and sees bare names.
        let inProcess = AgentPrompts.context(
            target: AgentTarget.none,
            toolNames: names,
            policy: .review,
            context: container.mainContext
        ).renderText()
        #expect(inProcess.contains("- caption_export"))
        #expect(!inProcess.contains("mcp__film_workflow__caption_export"))
    }

    @Test("The review policy's caption rule reaches the rendered prompt")
    func reviewPolicyIsStated() throws {
        let schema = Schema([film_workflow.AgentThread.self, film_workflow.AgentMessage.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let review = AgentPrompts.context(
            target: AgentTarget.none,
            toolNames: AgentToolPolicy.toolNames(policy: .review),
            policy: .review,
            context: container.mainContext
        ).renderText()
        #expect(review.contains("caption_propose_edits"))
        #expect(review.contains("Never claim you have changed a caption"))

        let direct = AgentPrompts.context(
            target: AgentTarget.none,
            toolNames: AgentToolPolicy.toolNames(policy: .direct),
            policy: .direct,
            context: container.mainContext
        ).renderText()
        #expect(direct.contains("take effect immediately"))
    }

    // MARK: - Tool scoping

    /// The agent window is not a coding agent. A prompt asking it not to run
    /// shells is a request; the denylist is the guarantee.
    @Test("A CLI agent's own filesystem and shell tools are withheld")
    func codingAgentToolsAreWithheld() {
        let disallowed = AgentToolPolicy.disallowedToolNames(policy: .direct)
        for name in ["Bash", "Write", "Edit", "Read", "WebFetch", "Task"] {
            #expect(disallowed.contains(name), "\(name) should be withheld")
        }
        #expect(disallowed.contains("delete_project"))
    }

    @Test("Withheld tools are refused in both spellings")
    func withheldToolsRefusedBothWays() {
        let policy = AgentWritePolicy.review
        let request = AgentSendRequest(
            threadID: AgentThreadID(),
            prompt: "x",
            workingDirectory: URL(filePath: "/tmp"),
            mcpServers: [.http(
                name: AgentMCPBridge.serverKey,
                url: URL(string: "http://127.0.0.1:1/mcp")!
            )],
            allowedTools: AgentToolPolicy.toolNames(policy: policy),
            disallowedTools: AgentToolPolicy.disallowedToolNames(policy: policy)
        )

        #expect(request.permitsTool(named: "caption_search_segments"))
        #expect(request.permitsTool(named: "mcp__film_workflow__caption_search_segments"))

        for name in ["Bash", "caption_update_segment", "delete_project"] {
            #expect(!request.permitsTool(named: name))
            #expect(!request.permitsTool(named: "mcp__film_workflow__\(name)"))
        }
    }
}
