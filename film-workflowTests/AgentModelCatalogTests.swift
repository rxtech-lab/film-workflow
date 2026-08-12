import Foundation
import Testing

@testable import film_workflow

/// The model catalogue for the CLI agent backends.
///
/// Everything here is parsing and selection — no subprocess is spawned, so the
/// suite doesn't need `codex` installed and doesn't change answer when a new
/// model ships.
@Suite("Agent model catalog")
struct AgentModelCatalogTests {

    // MARK: - Codex discovery

    #if os(macOS)
        /// A trimmed `codex debug models` reply. The real one is a single ~320 KB
        /// line, nearly all of it `base_instructions` — kept here in miniature so
        /// the "we never retain it" expectation below has something to bite on.
        private static let debugModelsJSON = """
        {"models":[
          {"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","description":"Latest frontier agentic coding model.",
           "default_reasoning_level":"low",
           "supported_reasoning_levels":[{"effort":"low","description":"Fast"},{"effort":"high","description":"Deep"},{"effort":"ultra","description":"Deepest"}],
           "visibility":"list","priority":1,"base_instructions":"You are Codex, an agent based on GPT-5."},
          {"slug":"gpt-5.6-sol-wm","display_name":"GPT-5.6-Sol-WM","visibility":"hide","priority":2,
           "supported_reasoning_levels":[{"effort":"low"}]},
          {"slug":"gpt-5.5","display_name":"GPT-5.5","description":"Previous generation.",
           "default_reasoning_level":"medium",
           "supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"xhigh"}],
           "visibility":"list","priority":3},
          {"slug":"codex-auto-review","display_name":"Codex Auto Review","hidden":true,"priority":4}
        ]}
        """

        private func parseDebugModels() throws -> [AgentModelOption] {
            try CodexModelsClient.parse(#require(Self.debugModelsJSON.data(using: .utf8)))
        }

        @Test("Only listable models survive")
        func hiddenModelsAreDropped() throws {
            let models = try parseDebugModels()
            #expect(models.map(\.id) == ["gpt-5.6-sol", "gpt-5.5"])
        }

        @Test("Names, descriptions and reasoning levels are carried over")
        func fieldsAreMapped() throws {
            let models = try parseDebugModels()
            let sol = try #require(models.first { $0.id == "gpt-5.6-sol" })
            #expect(sol.displayName == "GPT-5.6-Sol")
            #expect(sol.detail == "Latest frontier agentic coding model.")
            #expect(sol.efforts == ["low", "high", "ultra"])
            #expect(sol.defaultEffort == "low")
        }

        /// The reason parsing is selective rather than a straight `Codable`
        /// decode: retaining `base_instructions` would put hundreds of kilobytes
        /// of prompt into the `UserDefaults` cache.
        @Test("Prompt text is never retained")
        func baseInstructionsAreDiscarded() throws {
            let models = try parseDebugModels()
            let encoded = try String(data: JSONEncoder().encode(models), encoding: .utf8) ?? ""
            #expect(!encoded.contains("You are Codex"))
        }

        @Test("Models are ordered by the CLI's own priority")
        func priorityOrdersTheList() throws {
            let json = """
            {"models":[{"slug":"b","priority":9},{"slug":"a","priority":1}]}
            """
            let models = try CodexModelsClient.parse(#require(json.data(using: .utf8)))
            #expect(models.map(\.id) == ["a", "b"])
        }

        @Test("Envelopes the CLI has used across releases all parse")
        func tolerantOfShape() throws {
            let shapes = [
                #"{"data":[{"slug":"gpt-5.5"}]}"#,
                #"{"items":[{"id":"gpt-5.5"}]}"#,
                #"[{"model":"gpt-5.5"}]"#,
                #"["gpt-5.5"]"#,
            ]
            for shape in shapes {
                let models = try CodexModelsClient.parse(#require(shape.data(using: .utf8)))
                #expect(models.map(\.id) == ["gpt-5.5"], "shape: \(shape)")
            }
        }

        @Test("An entry with no usable id is skipped, not fatal")
        func unusableEntriesAreSkipped() throws {
            let json = #"{"models":[{"description":"no id here"},{"slug":"gpt-5.5"}]}"#
            let models = try CodexModelsClient.parse(#require(json.data(using: .utf8)))
            #expect(models.map(\.id) == ["gpt-5.5"])
        }

        @Test("Output that isn't JSON at all throws")
        func garbageThrows() throws {
            let data = try #require("not json".data(using: .utf8))
            #expect(throws: CodexModelsError.self) { try CodexModelsClient.parse(data) }
        }

        @Test("A missing display_name is derived from the slug")
        func displayNameFallsBackToSlug() {
            #expect(CodexModelsClient.displayName(for: "gpt-5.4-mini") == "GPT 5.4 Mini")
        }
    #endif

    // MARK: - Effort validation

    /// Model and effort are chosen in two different places — effort in Settings,
    /// model possibly overridden per thread — and Codex's levels are not uniform
    /// across models. These pin the guard that keeps the two from drifting into
    /// a combination the CLI rejects.
    ///
    /// Run against a fixed list rather than `AgentModelCatalog.shared`, whose
    /// contents depend on what `codex` last reported on this machine.
    private static let codexOptions = [
        AgentModelOption(id: "deep", displayName: "Deep", efforts: ["low", "high", "ultra"]),
        AgentModelOption(id: "shallow", displayName: "Shallow", efforts: ["low", "high"]),
        AgentModelOption(id: "effortless", displayName: "Effortless"),
    ]

    @Test("An unset effort sends nothing")
    func emptyEffortIsDropped() {
        #expect(AgentModelCatalog.effort(for: "deep", configured: "", in: Self.codexOptions) == nil)
        #expect(AgentModelCatalog.effort(for: "deep", configured: "  ", in: Self.codexOptions) == nil)
    }

    @Test("A supported effort is sent as-is")
    func supportedEffortSurvives() {
        #expect(
            AgentModelCatalog.effort(for: "deep", configured: "ultra", in: Self.codexOptions) == "ultra"
        )
    }

    /// The case this whole guard exists for: effort was set while one model was
    /// selected, then a thread pinned a model that doesn't take it.
    @Test("An effort the model doesn't accept is dropped")
    func unsupportedEffortIsDropped() {
        #expect(
            AgentModelCatalog.effort(for: "shallow", configured: "ultra", in: Self.codexOptions) == nil
        )
    }

    /// A model id we don't recognize is one the user typed, so they know more
    /// about it than the catalogue does — pass the effort through rather than
    /// second-guessing them. Same for a model that advertised no levels at all.
    @Test("An unknown model keeps whatever effort was set")
    func customModelPassesEffortThrough() {
        #expect(
            AgentModelCatalog.effort(for: "unreleased", configured: "high", in: Self.codexOptions) == "high"
        )
        #expect(
            AgentModelCatalog.effort(for: "effortless", configured: "high", in: Self.codexOptions) == "high"
        )
    }

    @Test("The picker offers the model's own levels, generic ones otherwise")
    func effortsFollowTheModel() {
        #expect(
            AgentModelCatalog.efforts(forCodexModel: "deep", in: Self.codexOptions)
                == ["low", "high", "ultra"]
        )
        #expect(
            AgentModelCatalog.efforts(forCodexModel: "unreleased", in: Self.codexOptions)
                == AgentModelCatalog.genericCodexEfforts
        )
        #expect(
            AgentModelCatalog.efforts(forCodexModel: "", in: Self.codexOptions)
                == AgentModelCatalog.genericCodexEfforts
        )
    }

    // MARK: - Backend lookup

    @Test("Claude Code's list is fixed and carries no effort setting")
    func claudeListIsFixed() {
        let claude = AgentModelCatalog.claudeModels
        #expect(claude.contains { $0.id == "opus" })
        #expect(claude.contains { $0.id == "sonnet" })
        // The `default` alias is deliberately absent — an empty selection
        // already means "leave it to the CLI".
        #expect(!claude.contains { $0.id == "default" })
        // Nothing here takes a reasoning level; only Codex does.
        #expect(claude.allSatisfy { $0.efforts.isEmpty })
    }

    /// The aliases and the GPT ids name models in different namespaces, and
    /// handing one backend the other's list is the bug this guards.
    @Test("Each backend gets its own list, and the non-CLI ones get none")
    @MainActor
    func optionsAreScopedToTheirBackend() {
        let catalog = AgentModelCatalog.shared
        let claudeIDs = Set(catalog.options(for: .claudeCode).map(\.id))

        #expect(claudeIDs == Set(AgentModelCatalog.claudeModels.map(\.id)))
        #expect(catalog.options(for: .codex).allSatisfy { !claudeIDs.contains($0.id) })
        #expect(catalog.options(for: .appleIntelligence).isEmpty)
        #expect(catalog.options(for: .openAICompatible).isEmpty)
    }

    @Test("An unknown id still renders as itself")
    @MainActor
    func displayNameFallsBackToTheID() {
        #expect(
            AgentModelCatalog.shared.displayName(for: "opus", backend: .claudeCode) == "Opus"
        )
        #expect(
            AgentModelCatalog.shared.displayName(for: "made-up", backend: .claudeCode) == "made-up"
        )
    }
}

/// Per-thread model overrides.
@Suite("Agent thread model overrides")
@MainActor
struct AgentThreadModelOverrideTests {

    @Test("A thread starts with no override")
    func defaultsToNothing() {
        let thread = AgentThread()
        #expect(thread.modelOverride(for: .claudeCode) == nil)
        #expect(thread.modelOverride(for: .codex) == nil)
    }

    /// The reason overrides are keyed per backend rather than stored in one
    /// field: `sonnet` means nothing to Codex, and `gpt-5.5` means nothing to
    /// Claude Code, so switching engines must not carry a model across.
    @Test("Each backend keeps its own model")
    func overridesDoNotLeakBetweenBackends() {
        let thread = AgentThread()
        thread.setModelOverride("sonnet", for: .claudeCode)
        thread.setModelOverride("gpt-5.5", for: .codex)

        #expect(thread.modelOverride(for: .claudeCode) == "sonnet")
        #expect(thread.modelOverride(for: .codex) == "gpt-5.5")
    }

    @Test("Clearing one backend leaves the other alone")
    func clearingIsScoped() {
        let thread = AgentThread()
        thread.setModelOverride("sonnet", for: .claudeCode)
        thread.setModelOverride("gpt-5.5", for: .codex)

        thread.setModelOverride(nil, for: .claudeCode)
        #expect(thread.modelOverride(for: .claudeCode) == nil)
        #expect(thread.modelOverride(for: .codex) == "gpt-5.5")

        // An empty string is the same request as nil — it's what the "Default
        // model" row and a cleared text field both produce.
        thread.setModelOverride("", for: .codex)
        #expect(thread.modelOverride(for: .codex) == nil)
    }

    @Test("Overrides and resume ids don't disturb each other")
    func overridesAreSeparateFromSessionIDs() {
        let thread = AgentThread()
        thread.setProviderSessionID("session-abc", for: .claudeCode)
        thread.setModelOverride("opus", for: .claudeCode)

        #expect(thread.providerSessionID(for: .claudeCode) == "session-abc")
        #expect(thread.modelOverride(for: .claudeCode) == "opus")

        thread.clearProviderSessionIDs()
        #expect(thread.providerSessionID(for: .claudeCode) == nil)
        #expect(thread.modelOverride(for: .claudeCode) == "opus")
    }
}
