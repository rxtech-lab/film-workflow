import Foundation
import SwiftData
import Testing

@testable import film_workflow

/// The tools an agent is allowed to call, and what the propose path does with
/// them. This is the surface that decides whether an agent can damage a
/// transcript, so it is tested against a real (in-memory) store rather than a
/// stub.
@Suite("MCP caption AI tools")
@MainActor
struct MCPCaptionAITests {

    // MARK: - Fixture

    private func makeProject(texts: [String]) throws -> (CaptionProject, ModelContext) {
        let schema = Schema([
            CaptionProject.self,
            CaptionSegment.self,
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
        // And the proposal is parked for the agent window to review.
        let pending = AgentController.shared.pendingProposal(forProjectUUID: project.projectUUID)
        #expect(pending?.items.count == 1)
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

        // Nothing reached the agent window.
        #expect(AgentController.shared.pendingProposal(forProjectUUID: project.projectUUID) == nil)

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
        #expect(AgentController.shared.pendingProposal(forProjectUUID: project.projectUUID) != nil)
        #expect(CaptionProposalInbox.finish(project.projectUUID).items.isEmpty)
    }

    @Test("CLI engines can review a saved transcript but not one being transcribed")
    func cliBackendsSupportTranscriptReviewOnly() {
        for backend in [AgentBackend.claudeCode, .codex] {
            #expect(backend.supports(.transcriptReview))
            #expect(backend.supports(.conversation))
            // The captions don't exist yet mid-transcription, so an agent that
            // reads them over MCP has nothing to read.
            #expect(!backend.supports(.cueRefinement))
        }
        for backend in [AgentBackend.appleIntelligence, .openAICompatible] {
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
        #expect(AgentController.shared.pendingProposal(forProjectUUID: project.projectUUID) == nil)
    }

    // MARK: - Timing and translation proposals

    @Test("A retime is proposed rather than applied, and keeps the old times until approved")
    func proposeRetimeQueuesTheChange() async throws {
        let (project, context) = try makeProject(texts: ["One.", "Two."])

        let result = try await MCPCaptionHandlers.handle(
            name: "caption_propose_edits",
            arguments: [
                "caption_id": project.projectUUID.uuidString,
                "edits": [["index": 1, "kind": "retime", "end_ms": 1_800]],
            ],
            context: context
        )
        let json = try payload(result)

        #expect(json["accepted"] as? Int == 1)
        // Untouched until the user approves.
        #expect(project.orderedSegments[1].endMs == 2_000)

        let pending = try #require(
            AgentController.shared.pendingProposal(forProjectUUID: project.projectUUID)
        )
        // Only `end_ms` was given, so the start has to come from the caption.
        guard case .retime(_, let startMs, let endMs) = pending.items[0].operation else {
            Issue.record("expected a retime operation")
            return
        }
        #expect(startMs == 1_000)
        #expect(endMs == 1_800)

        let applied = CaptionEditApplier.apply(pending.items, to: project, context: context)
        #expect(applied == 1)
        #expect(project.orderedSegments[1].endMs == 1_800)
        #expect(project.orderedSegments[1].startMs == 1_000)
    }

    @Test("A retime naming neither bound is rejected")
    func proposeRetimeNeedsABound() async throws {
        let (project, context) = try makeProject(texts: ["One."])

        let result = try await MCPCaptionHandlers.handle(
            name: "caption_propose_edits",
            arguments: [
                "caption_id": project.projectUUID.uuidString,
                "edits": [
                    ["index": 0, "kind": "retime"],
                    ["index": 0, "kind": "retime", "start_ms": 900, "end_ms": 400],
                ],
            ],
            context: context
        )
        let json = try payload(result)

        #expect(json["accepted"] as? Int == 0)
        #expect((json["rejected"] as? [[String: Any]])?.count == 2)
    }

    @Test("One line's translation can be proposed without touching the rest")
    func proposeTranslationForASingleCaption() async throws {
        let (project, context) = try makeProject(texts: ["Carry your identity.", "Pick your community."])
        project.orderedSegments[0].setTranslation("带上你的身份。", language: "zh-Hans")
        project.orderedSegments[1].setTranslation("选择你的社区。", language: "zh-Hans")
        try context.save()

        let result = try await MCPCaptionHandlers.handle(
            name: "caption_propose_edits",
            arguments: [
                "caption_id": project.projectUUID.uuidString,
                "edits": [
                    [
                        "index": 0,
                        "kind": "set_translation",
                        "language": "zh-Hans",
                        "text": "身份随行。",
                        "reason": "Parallel cadence with the next line.",
                    ]
                ],
            ],
            context: context
        )
        let json = try payload(result)
        #expect(json["accepted"] as? Int == 1)
        // Nothing is written before approval.
        #expect(project.orderedSegments[0].translatedText("zh-Hans") == "带上你的身份。")

        let pending = try #require(
            AgentController.shared.pendingProposal(forProjectUUID: project.projectUUID)
        )
        let applied = CaptionEditApplier.apply(
            pending.items, to: project, context: context, engine: "gpt-4o"
        )
        #expect(applied == 1)
        #expect(project.orderedSegments[0].translatedText("zh-Hans") == "身份随行。")
        // The other caption's translation is left exactly as it was.
        #expect(project.orderedSegments[1].translatedText("zh-Hans") == "选择你的社区。")
        // The source text didn't change, so the approved wording isn't stale…
        #expect(!project.orderedSegments[0].isTranslationStale("zh-Hans"))
        // …and it is marked hand-written, so a later bulk pass leaves it alone.
        let translation = try #require(project.orderedSegments[0].translation("zh-Hans"))
        #expect(translation.isUserEdited)
        #expect(translation.model == "gpt-4o")
    }

    @Test("A translation edit without a language is rejected")
    func proposeTranslationNeedsALanguage() async throws {
        let (project, context) = try makeProject(texts: ["One."])

        let result = try await MCPCaptionHandlers.handle(
            name: "caption_propose_edits",
            arguments: [
                "caption_id": project.projectUUID.uuidString,
                "edits": [["index": 0, "kind": "set_translation", "text": "一。"]],
            ],
            context: context
        )
        let json = try payload(result)

        #expect(json["accepted"] as? Int == 0)
        #expect((json["rejected"] as? [[String: Any]])?.count == 1)
    }

    @Test("Under the direct policy a translation can be written in place")
    func updateSegmentWritesATranslation() async throws {
        let (project, context) = try makeProject(texts: ["Carry your identity."])

        let result = try await MCPCaptionHandlers.handle(
            name: "caption_update_segment",
            arguments: [
                "caption_id": project.projectUUID.uuidString,
                "index": 0,
                "translation": "身份随行。",
                "translation_language": "zh-Hans",
            ],
            context: context
        )
        let json = try payload(result)

        #expect(project.orderedSegments[0].translatedText("zh-Hans") == "身份随行。")
        #expect((json["translations"] as? [String: Any])?["zh-Hans"] as? String == "身份随行。")
        // The original is untouched by a translation-only write.
        #expect(project.orderedSegments[0].text == "Carry your identity.")
    }

    @Test("Writing a translation without naming its language is an error, not a guess")
    func updateSegmentTranslationNeedsALanguage() async throws {
        let (project, context) = try makeProject(texts: ["One."])

        await #expect(throws: MCPToolError.self) {
            _ = try await MCPCaptionHandlers.handle(
                name: "caption_update_segment",
                arguments: [
                    "caption_id": project.projectUUID.uuidString,
                    "index": 0,
                    "translation": "一。",
                ],
                context: context
            )
        }
    }

    // MARK: - Registration

    @Test("Both tools are registered and reachable")
    func toolsAreRegistered() {
        #expect(MCPCaptionHandlers.canHandle("caption_search_segments"))
        #expect(MCPCaptionHandlers.canHandle("caption_propose_edits"))
    }

    @Test("Under the review policy the agent can't write captions directly")
    func reviewPolicyExcludesDirectWrites() {
        let review = AgentToolPolicy.toolNames(policy: .review)
        // The two tools that rewrite caption text without asking.
        #expect(!review.contains("caption_update_segment"))
        #expect(!review.contains("caption_transcribe"))
        // The only route to changing a caption, which queues a proposal.
        #expect(review.contains("caption_propose_edits"))
        // Deliberately still allowed: renaming a speaker is a small, obvious
        // edit the user can undo, and withholding it would make "label speaker 1
        // as Alice" impossible.
        #expect(review.contains("caption_set_speakers"))
        // Never offered under any policy.
        #expect(!review.contains("delete_project"))
        #expect(!AgentToolPolicy.toolNames(policy: .direct).contains("delete_project"))
    }

    @Test("The direct policy lifts the caption write restriction")
    func directPolicyAllowsWrites() {
        #expect(AgentToolPolicy.toolNames(policy: .direct).contains("caption_update_segment"))
    }

    @Test("Every exposed tool converts to a usable OpenAI function definition")
    func toolsConvertToOpenAIDefinitions() {
        let definitions = AgentToolPolicy.openAIToolDefinitions(policy: .review)
        #expect(!definitions.isEmpty)
        #expect(definitions.allSatisfy { !$0.name.isEmpty && !$0.description.isEmpty })
        // A JSON Schema object is what the function-calling API requires.
        #expect(definitions.allSatisfy { $0.parametersSchema["type"] as? String == "object" })
    }

    @Test("Command-line agents are given the same tools, MCP-prefixed")
    func cliToolNamesMatchThePolicy() {
        #if os(macOS)
            let prefixed = AgentMCPBridge.prefixedToolNames(policy: .review)
            #expect(prefixed.count == AgentToolPolicy.toolNames(policy: .review).count)
            #expect(prefixed.allSatisfy { $0.hasPrefix("mcp__film_workflow__") })
            #expect(!prefixed.contains("mcp__film_workflow__caption_update_segment"))
        #endif
    }
}
