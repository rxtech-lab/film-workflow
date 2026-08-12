import Foundation
import SwiftData
import Testing

@testable import film_workflow

/// The two tools a command-line agent is allowed to call. These are the surface
/// that decides whether an agent can damage a transcript, so they get tested
/// against a real (in-memory) store rather than a stub.
@Suite("MCP caption AI tools")
@MainActor
struct MCPCaptionAITests {

    // MARK: - Fixture

    private func makeProject(texts: [String]) throws -> (CaptionProject, ModelContext) {
        let schema = Schema([
            CaptionProject.self,
            CaptionSegment.self,
            CaptionAssistantMessage.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)

        let project = CaptionProject(name: "Test captions")
        context.insert(project)

        for (index, text) in texts.enumerated() {
            let segment = CaptionSegment(
                orderIndex: index,
                startMs: index * 1_000,
                endMs: (index + 1) * 1_000,
                text: text,
                words: text.split(separator: " ").enumerated().map { position, word in
                    CaptionWord(
                        text: String(word),
                        offsetMs: index * 1_000 + position * 100,
                        durationMs: 100
                    )
                }
            )
            segment.project = project
            context.insert(segment)
        }
        try context.save()
        return (project, context)
    }

    private func payload(_ result: [String: Any]) throws -> [String: Any] {
        // `jsonResult` wraps the object in MCP's content envelope.
        let content = try #require(result["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        let data = try #require(text.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Search

    @Test("Search finds captions by keyword, ignoring case and punctuation")
    func searchMatchesNormalized() async throws {
        let (project, context) = try makeProject(texts: [
            "Welcome to the show.",
            "Today we're talking about RxLab.",
            "Thanks for listening.",
        ])

        let result = try await MCPCaptionHandlers.handle(
            name: "caption_search_segments",
            arguments: [
                "caption_id": project.projectUUID.uuidString,
                "query": "rxlab",
            ],
            context: context
        )
        let json = try payload(result)

        #expect(json["total"] as? Int == 1)
        let segments = try #require(json["segments"] as? [[String: Any]])
        #expect(segments.count == 1)
        #expect(segments[0]["index"] as? Int == 1)
    }

    @Test("Search can pull in neighbouring captions")
    func searchIncludesContext() async throws {
        let (project, context) = try makeProject(texts: [
            "One.", "Two.", "Three needle.", "Four.", "Five.",
        ])

        let result = try await MCPCaptionHandlers.handle(
            name: "caption_search_segments",
            arguments: [
                "caption_id": project.projectUUID.uuidString,
                "query": "needle",
                "context": 1,
            ],
            context: context
        )
        let json = try payload(result)
        let segments = try #require(json["segments"] as? [[String: Any]])

        #expect(segments.map { $0["index"] as? Int } == [1, 2, 3])
        // Only the real hit is flagged as a match.
        #expect(segments.filter { $0["isMatch"] as? Bool == true }.count == 1)
    }

    @Test("An empty query is rejected rather than matching everything")
    func searchRejectsEmptyQuery() async throws {
        let (project, context) = try makeProject(texts: ["One."])

        await #expect(throws: MCPToolError.self) {
            _ = try await MCPCaptionHandlers.handle(
                name: "caption_search_segments",
                arguments: ["caption_id": project.projectUUID.uuidString, "query": "   "],
                context: context
            )
        }
    }

    // MARK: - Propose

    @Test("Proposing edits changes nothing until the user approves")
    func proposeDoesNotMutate() async throws {
        let (project, context) = try makeProject(texts: ["Original text here."])
        let before = project.orderedSegments[0].text

        let result = try await MCPCaptionHandlers.handle(
            name: "caption_propose_edits",
            arguments: [
                "caption_id": project.projectUUID.uuidString,
                "summary": "one fix",
                "edits": [
                    ["index": 0, "kind": "replace_text", "text": "Replacement text here."]
                ],
            ],
            context: context
        )
        let json = try payload(result)

        #expect(json["accepted"] as? Int == 1)
        // The caption itself is untouched.
        #expect(project.orderedSegments[0].text == before)
        // And the proposal is waiting in the assistant.
        #expect(project.assistantMessages.count == 1)
        #expect(project.assistantMessages[0].kindEnum == .proposal)
        #expect(project.assistantMessages[0].proposal?.items.count == 1)
    }

    @Test("Out-of-range indices are reported, not silently ignored")
    func proposeReportsBadIndices() async throws {
        let (project, context) = try makeProject(texts: ["One.", "Two."])

        let result = try await MCPCaptionHandlers.handle(
            name: "caption_propose_edits",
            arguments: [
                "caption_id": project.projectUUID.uuidString,
                "edits": [
                    ["index": 0, "kind": "delete"],
                    ["index": 99, "kind": "delete"],
                    ["index": 1, "kind": "sing_a_song"],
                ],
            ],
            context: context
        )
        let json = try payload(result)

        #expect(json["accepted"] as? Int == 1)
        let rejected = try #require(json["rejected"] as? [[String: Any]])
        #expect(rejected.count == 2)
    }

    @Test("Merging the last caption is rejected")
    func proposeRejectsTerminalMerge() async throws {
        let (project, context) = try makeProject(texts: ["One.", "Two."])

        let result = try await MCPCaptionHandlers.handle(
            name: "caption_propose_edits",
            arguments: [
                "caption_id": project.projectUUID.uuidString,
                "edits": [["index": 1, "kind": "merge_with_next"]],
            ],
            context: context
        )
        let json = try payload(result)

        #expect(json["accepted"] as? Int == 0)
        #expect((json["rejected"] as? [[String: Any]])?.count == 1)
    }

    @Test("A split that changes the words comes back flagged")
    func proposeFlagsWordChangingSplit() async throws {
        let (project, context) = try makeProject(texts: ["one two three four five six"])

        let result = try await MCPCaptionHandlers.handle(
            name: "caption_propose_edits",
            arguments: [
                "caption_id": project.projectUUID.uuidString,
                "edits": [
                    ["index": 0, "kind": "split", "pieces": ["one two three", "completely different"]]
                ],
            ],
            context: context
        )
        let json = try payload(result)

        #expect(json["accepted"] as? Int == 1)
        #expect(json["flagged"] as? Int == 1)
        let items = try #require(json["items"] as? [[String: Any]])
        #expect(items[0]["ok"] as? Bool == false)
    }

    @Test("A valid split is accepted unflagged")
    func proposeAcceptsGoodSplit() async throws {
        let (project, context) = try makeProject(texts: ["one two three four five six"])

        let result = try await MCPCaptionHandlers.handle(
            name: "caption_propose_edits",
            arguments: [
                "caption_id": project.projectUUID.uuidString,
                "edits": [
                    ["index": 0, "kind": "split", "pieces": ["One two three,", "four five six."]]
                ],
            ],
            context: context
        )
        let json = try payload(result)

        #expect(json["accepted"] as? Int == 1)
        #expect(json["flagged"] as? Int == 0)
    }

    // MARK: - Batch runs

    @Test("A claimed project routes proposals to the batch task, not the assistant")
    func claimedProposalsGoToTheInbox() async throws {
        let (project, context) = try makeProject(texts: [
            "one two three four five six",
            "seven eight nine ten",
        ])
        CaptionProposalInbox.claim(project.projectUUID, policy: .preserveWords)
        CaptionProposalInbox.setEngineLabel("Codex", for: project.projectUUID)
        defer { CaptionProposalInbox.clearEngineLabel(for: project.projectUUID) }

        // Two calls, as the system prompt tells an agent to batch its work.
        for edit in [
            ["index": 0, "kind": "split", "pieces": ["One two three,", "four five six."]],
            ["index": 1, "kind": "split", "pieces": ["Seven eight,", "nine ten."]],
        ] {
            _ = try await MCPCaptionHandlers.handle(
                name: "caption_propose_edits",
                arguments: ["caption_id": project.projectUUID.uuidString, "edits": [edit]],
                context: context
            )
        }

        // Nothing reached the assistant window.
        #expect(project.assistantMessages.isEmpty)

        let collected = CaptionProposalInbox.finish(project.projectUUID)
        #expect(collected.items.count == 2)
        #expect(collected.items.allSatisfy { $0.verdict.isOK })
        #expect(collected.engine == "Codex")
    }

    @Test("A batch split run judges by preserveWords, not by the chat policy")
    func claimedSplitRejectsWordChanges() async throws {
        let (project, context) = try makeProject(texts: ["one two three four five six"])
        CaptionProposalInbox.claim(project.projectUUID, policy: .preserveWords)

        _ = try await MCPCaptionHandlers.handle(
            name: "caption_propose_edits",
            arguments: [
                "caption_id": project.projectUUID.uuidString,
                // "seven" was never spoken; a chat edit could say this, a split
                // never can.
                "edits": [["index": 0, "kind": "split", "pieces": ["One two three,", "four five seven."]]],
            ],
            context: context
        )

        let collected = CaptionProposalInbox.finish(project.projectUUID)
        #expect(collected.items.count == 1)
        #expect(collected.items[0].verdict == .wordsChanged)
    }

    @Test("Without a claim, proposals still reach the assistant window")
    func unclaimedProposalsGoToTheAssistant() async throws {
        let (project, context) = try makeProject(texts: ["one two three four five six"])

        _ = try await MCPCaptionHandlers.handle(
            name: "caption_propose_edits",
            arguments: [
                "caption_id": project.projectUUID.uuidString,
                "edits": [["index": 0, "kind": "split", "pieces": ["One two three,", "four five six."]]],
            ],
            context: context
        )
        #expect(project.assistantMessages.count == 1)
        #expect(CaptionProposalInbox.finish(project.projectUUID).items.isEmpty)
    }

    @Test("CLI engines can review a saved transcript but not one being transcribed")
    func cliBackendsSupportTranscriptReviewOnly() {
        for backend in [CaptionAIBackend.claudeCode, .codex] {
            #expect(backend.supports(.transcriptReview))
            #expect(backend.supports(.conversation))
            // The captions don't exist yet mid-transcription, so an agent that
            // reads them over MCP has nothing to read.
            #expect(!backend.supports(.cueRefinement))
        }
        for backend in [CaptionAIBackend.appleIntelligence, .openAICompatible] {
            #expect(backend.supports(.cueRefinement))
        }
    }

    @Test("An empty edit list is rejected outright")
    func proposeRejectsEmptyBatch() async throws {
        let (project, context) = try makeProject(texts: ["One."])

        await #expect(throws: MCPToolError.self) {
            _ = try await MCPCaptionHandlers.handle(
                name: "caption_propose_edits",
                arguments: ["caption_id": project.projectUUID.uuidString, "edits": [[String: Any]]()],
                context: context
            )
        }
    }

    @Test("A batch of malformed edits reports why rather than throwing")
    func proposeExplainsMalformedEdits() async throws {
        let (project, context) = try makeProject(texts: ["One."])

        // An agent that sends nonsense should get a diagnosis it can act on, not
        // a protocol error that tells it nothing.
        let result = try await MCPCaptionHandlers.handle(
            name: "caption_propose_edits",
            arguments: [
                "caption_id": project.projectUUID.uuidString,
                "edits": [[String: Any]()],
            ],
            context: context
        )
        let json = try payload(result)

        #expect(json["accepted"] as? Int == 0)
        #expect((json["rejected"] as? [[String: Any]])?.count == 1)
        #expect(project.assistantMessages.isEmpty)
    }

    // MARK: - Registration

    @Test("Both tools are registered and reachable")
    func toolsAreRegistered() {
        #expect(MCPCaptionHandlers.canHandle("caption_search_segments"))
        #expect(MCPCaptionHandlers.canHandle("caption_propose_edits"))
    }

    @Test("The CLI allowlist can't write captions directly")
    func allowlistExcludesDirectWrites() {
        #expect(!CaptionMCPBridge.allowedTools.contains("caption_update_segment"))
        #expect(!CaptionMCPBridge.allowedTools.contains("caption_transcribe"))
        #expect(!CaptionMCPBridge.allowedTools.contains("caption_set_speakers"))
        #expect(CaptionMCPBridge.allowedTools.contains("caption_propose_edits"))
        #expect(
            CaptionMCPBridge.prefixedToolNames
                .allSatisfy { $0.hasPrefix("mcp__film_workflow__") }
        )
    }
}
