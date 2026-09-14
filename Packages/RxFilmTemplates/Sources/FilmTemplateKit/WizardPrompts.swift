import Foundation

/// One uploaded file, as the prompts describe it to the agent.
public struct WizardUploadDescription: Hashable, Sendable {
    public var sourceId: String
    public var name: String
    public var kind: String
    public var durationSeconds: Double?

    public init(sourceId: String, name: String, kind: String, durationSeconds: Double? = nil) {
        self.sourceId = sourceId
        self.name = name
        self.kind = kind
        self.durationSeconds = durationSeconds
    }

    var line: String {
        var text = "- \(sourceId) · \(name) · \(kind)"
        if let durationSeconds, durationSeconds > 0 {
            text += String(format: " · %.1fs", durationSeconds)
        }
        return text
    }
}

/// Everything the agent is told during a run, per template.
///
/// The instructions live beside the template rather than in `AgentPrompts`
/// because they are template-specific: a product demo would ask for different
/// research and different options, while the phase protocol stays the same.
public struct WizardPromptSet: Hashable, Sendable {
    /// The phase protocol, appended to the system prompt for a wizard thread.
    /// `tool` namespaces a tool name for the engine that will read it.
    public var systemBlock: @Sendable (_ tool: @Sendable (String) -> String) -> String
    /// First turn: read the site, then propose templates.
    public var research: @Sendable (
        _ intake: IntakeSubmission,
        _ uploads: [WizardUploadDescription],
        _ queries: [String],
        _ tool: @Sendable (String) -> String
    ) -> String
    /// Second turn: inspect the chosen template, then present options.
    public var planOptions: @Sendable (
        _ itemId: String,
        _ title: String,
        _ tool: @Sendable (String) -> String
    ) -> String
    /// Third turn: build the sequence.
    public var build: @Sendable (
        _ itemId: String,
        _ selectionsJSON: String,
        _ tool: @Sendable (String) -> String
    ) -> String
    /// Later turns: change what is already there.
    public var refine: @Sendable (_ instruction: String, _ tool: @Sendable (String) -> String) -> String

    public init(
        systemBlock: @escaping @Sendable (@Sendable (String) -> String) -> String,
        research: @escaping @Sendable (IntakeSubmission, [WizardUploadDescription], [String], @Sendable (String) -> String) -> String,
        planOptions: @escaping @Sendable (String, String, @Sendable (String) -> String) -> String,
        build: @escaping @Sendable (String, String, @Sendable (String) -> String) -> String,
        refine: @escaping @Sendable (String, @Sendable (String) -> String) -> String
    ) {
        self.systemBlock = systemBlock
        self.research = research
        self.planOptions = planOptions
        self.build = build
        self.refine = refine
    }

    public static func == (lhs: WizardPromptSet, rhs: WizardPromptSet) -> Bool { true }
    public func hash(into hasher: inout Hasher) {}
}

public extension WizardPromptSet {
    /// The json-render subset the wizard can draw, written out for the model.
    /// The renderer is lenient, but a spec it cannot draw still costs the user
    /// a question, so the catalog is spelled out with an example.
    static let specReference = """
    A page is one JSON object: a `root` element id and a flat `elements` map.

    {
      "root": "page",
      "elements": {
        "page":  { "type": "Stack", "props": { "spacing": 16 }, "children": ["hero", "music"] },
        "hero":  { "type": "OptionGroup", "props": {
                     "label": "Opening shot",
                     "value": { "$bindState": "/footage/hero" },
                     "columns": 2,
                     "options": [
                       { "id": "imported:1E2A…", "title": "office-wide.mov", "subtitle": "12s clip",
                         "imageUrl": "imported:1E2A…" },
                       { "id": "generate", "title": "Generate one", "subtitle": "We'll make a still" }
                     ] } },
        "music": { "type": "Toggle", "props": {
                     "label": "Add music", "value": { "$bindState": "/style/music" } } }
      }
    }

    Element types and their props:
    - Stack — `direction` ("vertical" | "horizontal"), `spacing`, `title`; uses `children`.
    - Grid — `columns`, `spacing`; uses `children`.
    - Card — `title`, `subtitle`; uses `children`.
    - Heading — `text`, `level` (1–3). Text — `text`. Caption — `text`. Divider. Spacer.
    - Image — `url` (http/https) or a sourceId the film already holds; `height`.
    - OptionGroup — `label`, `options`, `multiple` (default false), `columns`,
      `value` bound with `{"$bindState": "/path"}`. Each option: `id`, `title`,
      `subtitle`, `detail`, `badge`, `imageUrl` (a URL or a sourceId).
    - Toggle — `label`, `detail`, `value` bound with `$bindState`.
    - Chips — `label`, `options`, `value` bound with `$bindState` (always multi-select).
    - TextField — `label`, `placeholder`, `value` bound with `$bindState`.

    Also available: `{"$state": "/path"}` to read a value into any prop,
    `{"$template": "Hello ${/name}"}` to interpolate one, and a `visible` array
    on an element (`[{"$state": "/style/music"}]`, `{"not": …}`, `{"eq": [a, b]}`)
    to show it only when a condition holds.

    Bind every choice to a path under a section you name (`/footage/…`,
    `/style/…`, `/music/…`), and send the starting values as `initial_state`
    so the page opens on your recommendation rather than empty.
    """

    /// The Company intro video script.
    static let companyIntro = WizardPromptSet(
        systemBlock: { tool in
            """
            ## Simple mode: company intro video

            You are building the user's first cut inside a guided wizard, not a
            chat. The film and its library already exist and the user's uploads
            are already imported — never import them again.

            The run has four phases, and each one ends by calling exactly one
            wizard tool and then stopping. Do not continue past the tool call;
            the user's answer arrives as your next turn.

            1. Research — read the site, rank marketplace project templates,
               call `\(tool(WizardTool.presentTemplates))`.
            2. Plan — inspect the chosen template, call
               `\(tool(WizardTool.presentOptions))` with a page of choices.
            3. Build — apply the template and finish the sequence, then reply
               with one sentence.
            4. Refine — change what exists when the user asks.

            Rules for the whole run:
            - The user cannot read your prose during phases 1 and 2. Every
              question goes through `\(tool(WizardTool.presentOptions))`; never
              end a turn with a question in text.
            - Call `\(tool(WizardTool.reportProgress))` with a short
              present-tense line ("Reading acme.com…", "Placing the opening
              shot…") before anything slow. The wizard shows it as status.
            - `\(tool(WebTool.read))` is the only way to reach the web.
            - Work on the one sequence `\(tool("project_template_apply"))`
              returns. Do not create extra sequences.
            - Prefer the user's own footage over marketplace footage wherever a
              shot allows it.

            ### Page format for \(tool(WizardTool.presentOptions))

            \(specReference)
            """
        },
        research: { intake, uploads, queries, tool in
            var lines: [String] = []
            lines.append("Phase 1 — research.")
            lines.append("")
            lines.append("Company website: \(intake.website?.absoluteString ?? intake.websiteText)")
            if !intake.description.isEmpty {
                lines.append("What the user wants this film to say: \(intake.description)")
            }
            lines.append("Film name: \(intake.projectName)")
            lines.append("")
            if uploads.isEmpty {
                lines.append("The user uploaded no footage, so the film will lean on marketplace assets and generated stills.")
            } else {
                lines.append("Footage the user uploaded, already in the library:")
                lines.append(contentsOf: uploads.map(\.line))
            }
            lines.append("")
            lines.append("""
            Do this:
            1. `\(tool(WebTool.read))` the website. In two sentences, note what \
            the company does, who it sells to, the tone of its writing, and any \
            brand colours you can see.
            2. `\(tool("marketplace_list"))` with kind `project_template`, \
            trying these queries: \(queries.map { "\"\($0)\"" }.joined(separator: ", ")). \
            Use `\(tool("marketplace_get"))` on anything promising to read its \
            footage requirements.
            3. Rank 3 to 5 templates by how well they fit both the company and \
            the footage on hand — a template that needs six clips is a poor fit \
            for two uploads.
            4. Call `\(tool(WizardTool.presentTemplates))` with those candidates, \
            each with a one-sentence reason, then stop.
            """)
            return lines.joined(separator: "\n")
        },
        planOptions: { itemId, title, tool in
            """
            Phase 2 — plan. The user chose "\(title)" (`\(itemId)`).

            Do this:
            1. `\(tool("marketplace_get"))` that template and read every footage \
            requirement, its media type and its instructions, plus any \
            marketplace items it depends on.
            2. `\(tool("footage_list"))` to see the user's uploads with their \
            sourceIds and durations.
            3. `\(tool("marketplace_list"))` for music that suits the tone, and \
            for footage that could cover any requirement the uploads cannot.
            4. Call `\(tool(WizardTool.presentOptions))` with one page that asks:
               - for each footage requirement, an OptionGroup of the uploads \
            that fit its media type, plus "Generate one" and, when the \
            requirement is optional, "Skip". Show a thumbnail by passing the \
            upload's sourceId as `imageUrl`. Bind each to `/footage/<requirementId>`.
               - the style choices the template actually offers, as Toggles \
            under `/style/…` (captions, an end card with the website, and so on).
               - music: an OptionGroup under `/music/track` with two or three \
            marketplace tracks and a "No music" option.
            Preselect your recommendation in `initial_state`, then stop.
            """
        },
        build: { itemId, selectionsJSON, tool in
            """
            Phase 3 — build. The user confirmed these choices:

            \(selectionsJSON)

            Do this:
            1. `\(tool("project_template_apply"))` with item_id `\(itemId)` and \
            `footage_bindings` taken from `/footage/…` (requirement id to \
            sourceId). Leave out any requirement the user chose to skip.
            2. If it comes back `collecting`, read `missing_requirements` and \
            `blockers`. Generate a still with `\(tool("image_generate"))` where \
            the user asked for one, drop optional requirements the user skipped, \
            and call it again with the same `application_id`. If a blocker is a \
            paid item the user does not own, leave it out and say so at the end.
            3. On the sequence it returns, apply the rest of the choices: add \
            the chosen music to the audio track for the sequence's length, add \
            captions if asked, add the end card if asked.
            4. Call `\(tool(WizardTool.reportProgress))` before each of these steps.

            Finish with one sentence describing the cut. Do not call a wizard \
            tool in this phase.
            """
        },
        refine: { instruction, tool in
            """
            Phase 4 — refine. The user asks: \(instruction)

            Change the existing sequence with the sequence tools. Do not create \
            a new sequence and do not re-apply the project template. Call \
            `\(tool(WizardTool.reportProgress))` as you work, and finish with one \
            sentence saying what changed.
            """
        }
    )
}
