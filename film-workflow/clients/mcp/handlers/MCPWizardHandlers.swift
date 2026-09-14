import FilmTemplateKit
import Foundation
import JSONRenderUI
import SwiftData

/// The tools a Simple mode run uses to put a page in front of the user.
///
/// The wizard shows pages, not a transcript, so the agent cannot ask a question
/// by writing one. Instead it calls one of these: the arguments are the page,
/// the app parks them on the session, and the user's answer comes back as the
/// next turn. The tool result always tells the agent to stop, because a model
/// that keeps working after presenting a page is deciding on the user's behalf.
@MainActor
enum MCPWizardHandlers {
    static let descriptors: [MCPToolDescriptor] = [
        MCPToolDescriptor(
            name: WizardTool.presentTemplates,
            description: "Show the user the marketplace project templates you recommend, so they can pick one. Only valid during the research phase of a Simple mode run. After calling this, stop: the user's choice arrives as your next message.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "candidates": [
                        "type": "array",
                        "description": "Between one and five templates, best first.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "item_id": ["type": "string", "description": "The marketplace item id, from marketplace_list."] as [String: Any],
                                "reason": ["type": "string", "description": "One sentence on why this fits this company and this footage."] as [String: Any],
                                "fit_score": ["type": "number", "description": "Optional 0–1 confidence."] as [String: Any],
                            ] as [String: Any],
                            "required": ["item_id", "reason"],
                        ] as [String: Any],
                    ] as [String: Any],
                    "summary": [
                        "type": "string",
                        "description": "Optional one-line summary of what you learned about the company, shown above the templates.",
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["candidates"],
            ]
        ),
        MCPToolDescriptor(
            name: WizardTool.skipTemplates,
            description: "Report that no marketplace project template fits, so the film should be built from the brief instead. Use this when marketplace_list with kind project_template returns nothing, or nothing close enough to be worth offering — never present a template of another kind. Only valid during the research phase. After calling this, stop: the user's answer arrives as your next message.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "reason": [
                        "type": "string",
                        "description": "One sentence the user will read, saying what you searched for and what you found.",
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["reason"],
            ]
        ),
        MCPToolDescriptor(
            name: WizardTool.presentOptions,
            description: "Show the user a page of choices — which footage goes where, style, music — described as a json-render spec. Only valid during the planning phase of a Simple mode run. After calling this, stop: the user's answers arrive as your next message. The system prompt lists the element types and props you may use.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "spec": [
                        "type": "object",
                        "description": "A json-render document: { \"root\": \"<id>\", \"elements\": { \"<id>\": { \"type\", \"props\", \"children\" } } }.",
                    ] as [String: Any],
                    "initial_state": [
                        "type": "object",
                        "description": "Starting values for the paths the page binds, so it opens on your recommendation.",
                    ] as [String: Any],
                    "title": ["type": "string", "description": "Heading for the page."] as [String: Any],
                ] as [String: Any],
                "required": ["spec"],
            ]
        ),
        MCPToolDescriptor(
            name: WizardTool.reportProgress,
            description: "Tell the user what you are doing right now, in a few present-tense words (\"Reading acme.com…\"). Shown as the wizard's status line. Call it before anything slow.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "message": ["type": "string", "description": "A short present-tense line."] as [String: Any],
                ] as [String: Any],
                "required": ["message"],
            ]
        ),
    ]

    static func canHandle(_ name: String) -> Bool { WizardTool.isWizardTool(name) }

    static func handle(
        name: String,
        arguments: [String: Any],
        context: ModelContext
    ) async throws -> [String: Any] {
        guard let session = SimpleModeCoordinator.shared.session(forContainer: context.container) else {
            throw MCPToolError.invalidArguments(SimpleModeError.noSession.localizedDescription)
        }

        switch name {
        case WizardTool.presentTemplates:
            return try await presentTemplates(arguments, session: session)
        case WizardTool.skipTemplates:
            let reason = (arguments["reason"] as? String) ?? ""
            return MCPToolRegistry.textResult(try session.skipTemplates(reason: reason))
        case WizardTool.presentOptions:
            return try presentOptions(arguments, session: session)
        case WizardTool.reportProgress:
            let message = (arguments["message"] as? String) ?? ""
            return MCPToolRegistry.textResult(try session.report(progress: message))
        default:
            throw MCPToolError.invalidArguments("unknown tool: \(name)")
        }
    }

    // MARK: - Templates

    private static func presentTemplates(
        _ arguments: [String: Any],
        session: SimpleModeSession
    ) async throws -> [String: Any] {
        let raw = (arguments["candidates"] as? [[String: Any]]) ?? []
        guard !raw.isEmpty else {
            throw MCPToolError.invalidArguments("candidates must list at least one template, each with an item_id from marketplace_list; if the marketplace has no project template that fits, call \(WizardTool.skipTemplates) instead")
        }

        let client = MarketplaceClient()
        var choices: [TemplateChoice] = []
        var unknown: [String] = []

        for entry in raw.prefix(5) {
            guard let itemId = entry["item_id"] as? String, !itemId.isEmpty else { continue }
            let reason = (entry["reason"] as? String) ?? ""
            // A hallucinated id is dropped rather than fatal: four good
            // suggestions beat an error the user has to wait through.
            guard let item = try? await client.item(itemId) else {
                unknown.append(itemId)
                continue
            }
            guard item.kind == .projectTemplate else {
                unknown.append(itemId)
                continue
            }
            choices.append(choice(for: item, reason: reason))
            session.rememberCandidate(item)
        }

        guard !choices.isEmpty else {
            throw MCPToolError.invalidArguments(
                "none of those ids is a marketplace project template"
                    + (unknown.isEmpty ? "" : " (\(unknown.joined(separator: ", ")))")
                    + "; call marketplace_list with kind project_template and use the ids it returns, or \(WizardTool.skipTemplates) if it returns none"
            )
        }

        var message = try session.present(
            templates: choices,
            summary: arguments["summary"] as? String
        )
        if !unknown.isEmpty {
            message += " Skipped unknown or non-template ids: \(unknown.joined(separator: ", "))."
        }
        return MCPToolRegistry.textResult(message)
    }

    static func choice(for item: MarketplaceItem, reason: String) -> TemplateChoice {
        let template = item.metadata.template
        return TemplateChoice(
            id: item.id,
            title: item.title,
            summary: item.description,
            reason: reason,
            previewImageURL: item.previewImageUrl,
            badge: item.isEntitled ? nil : "\(item.pricePoints) credits",
            shotCount: template?.shotCount,
            footageCount: template?.footageRequirements.count
        )
    }

    // MARK: - Options

    private static func presentOptions(
        _ arguments: [String: Any],
        session: SimpleModeSession
    ) throws -> [String: Any] {
        guard let rawSpec = arguments["spec"] else {
            throw MCPToolError.invalidArguments("spec is required" + specHint)
        }
        let spec: JSONRenderSpec
        do {
            spec = try JSONRenderSpec.decode(any: rawSpec)
        } catch {
            // Two bad specs and the wizard stops asking, so the user is not
            // stuck behind a page the agent cannot write.
            let reason = error.localizedDescription
            if session.recordRejectedOptions(reason) {
                return MCPToolRegistry.textResult(
                    "That spec could not be rendered either (\(reason)), so the wizard is going ahead with your recommendation. Continue to the build phase."
                )
            }
            throw MCPToolError.invalidArguments("spec could not be read: \(reason)." + specHint)
        }

        let initial = arguments["initial_state"].map { JSONRenderValue.from(any: $0) }
        var message = try session.present(
            spec: spec,
            title: arguments["title"] as? String,
            initialState: initial
        )
        let unsupported = spec.unsupportedTypes(in: JSONRenderComponentCatalog.names)
        if !unsupported.isEmpty {
            message += " Note: these element types are not in the catalog and drew as placeholders — \(unsupported.joined(separator: ", "))."
        }
        return MCPToolRegistry.textResult(message)
    }

    private static let specHint = """
     A spec is an object with `root` (an element id) and `elements` (a map of id \
    to { type, props, children }). Supported types: \
    \(JSONRenderComponentCatalog.names.sorted().joined(separator: ", ")).
    """
}
