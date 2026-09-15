import Foundation
import SwiftData

/// Single source of truth for the tools the server exposes via `tools/list` and
/// dispatches via `tools/call`. Keeping descriptors and invocation in one place
/// avoids drift.
///
/// The surface mirrors the editor: `film_*` for open documents, `footage_*` and
/// `folder_*` for the library, `sequence_*` for timelines, and one family per
/// generator (`music_*`, `narration_*`, `image_*`, `video_*`, `caption_*`,
/// `remotion_*`, `podcast_*`).
@MainActor
enum MCPToolRegistry {
    /// All tools, in the order surfaced to clients.
    static func allDescriptors() -> [MCPToolDescriptor] {
        var tools: [MCPToolDescriptor] = []
        tools.append(showSignInDialogDescriptor)
        tools.append(filmListDescriptor)
        tools.append(contentsOf: MCPModelHandlers.descriptors)
        tools.append(contentsOf: MCPMarketplaceHandlers.descriptors.filter { !MCPMarketplaceHandlers.adminNames.contains($0.name) || MarketplaceAuthoringService.shared.canAuthor })
        tools.append(contentsOf: MCPLibraryHandlers.descriptors)
        tools.append(contentsOf: MCPSequenceHandlers.descriptors)
        tools.append(contentsOf: MCPGenerateHandlers.descriptors)
        tools.append(contentsOf: MCPCaptionHandlers.descriptors)
        #if os(macOS)
        tools.append(contentsOf: RemotionMCPHandlers.descriptors)
        #endif
        tools.append(contentsOf: MCPPodcastHandlers.descriptors)
        tools.append(contentsOf: MCPWebHandlers.descriptors)
        tools.append(contentsOf: MCPWizardHandlers.descriptors)
        // Film tools can be pointed at a film other than the active one. Added
        // here rather than in fifty descriptors so the schema cannot drift.
        return tools.map(withFilmArgument)
    }

    static let filmArgument = "film"

    /// Tools that answer for the account rather than for a film, and so carry
    /// no `film` argument: offering one would promise a routing that does not
    /// exist.
    static var filmlessTools: Set<String> {
        MCPModelHandlers.toolNames.union([filmListDescriptor.name, showSignInDialogDescriptor.name])
    }

    private static func withFilmArgument(_ tool: MCPToolDescriptor) -> MCPToolDescriptor {
        guard !filmlessTools.contains(tool.name) else { return tool }
        var schema = tool.inputSchema
        var properties = (schema["properties"] as? [String: Any]) ?? [:]
        properties[filmArgument] = [
            "type": "string",
            "description": "Which open film to act on: its id, package path, or name from film_list. Defaults to the film whose window is active. `footage_list` also accepts \"*\" for every open film."
        ] as [String: Any]
        schema["properties"] = properties
        return MCPToolDescriptor(name: tool.name, description: tool.description, inputSchema: schema)
    }

    private static let showSignInDialogDescriptor = MCPToolDescriptor(
        name: "show_sign_in_dialog",
        description: "Open the app's native RxLab sign-in dialog if the user is not signed in. Use when the user asks to sign in or a tool reports that sign-in is required. No film or arguments are needed. Returns immediately; the user completes sign-in in the dialog. If already signed in, reports that without opening a dialog.",
        inputSchema: ["type": "object", "properties": [String: Any](), "additionalProperties": false]
    )

    private static let filmListDescriptor = MCPToolDescriptor(
        name: "film_list",
        description: "The films (.rxfilmstudio documents) open in the app, with the active one flagged. Film tools act on the active film unless you pass one of these ids, paths or names as `film`.",
        inputSchema: ["type": "object", "properties": [String: Any](), "additionalProperties": false]
    )

    /// Resolves the `film` argument to an open document, or throws when it
    /// names nothing that is open.
    static func resolveFilm(_ value: Any?) throws -> ProjectDocument? {
        guard let raw = value as? String else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key != "*" else { return nil }
        let controller = ProjectDocumentController.shared
        if let uuid = UUID(uuidString: key), let doc = controller.document(id: uuid) ?? MarketplaceAuthoringService.shared.document(id: uuid) { return doc }
        if let doc = controller.document(for: URL(fileURLWithPath: key)) { return doc }
        if let doc = controller.openDocuments.first(where: { $0.displayName.localizedCaseInsensitiveCompare(key) == .orderedSame }) {
            return doc
        }
        throw MCPToolError.invalidArguments("no open film matches \"\(key)\"; call film_list")
    }

    static func filmSummary(_ doc: ProjectDocument) -> [String: Any] {
        [
            "id": doc.id.uuidString,
            "name": doc.displayName,
            "path": doc.packageURL.path,
            "isActive": ProjectDocumentController.shared.activeDocument === doc
        ]
    }

    /// Dispatch a tool call. Returns the MCP `tools/call` result envelope (with
    /// `content: [...]`, optionally `isError`).
    static func invoke(
        name: String,
        arguments rawArguments: [String: Any],
        container defaultContainer: ModelContainer?,
        auth: AuthManager = .shared
    ) async throws -> [String: Any] {
        if name == showSignInDialogDescriptor.name {
            if auth.isAuthenticated {
                return jsonResult([
                    "status": "already_signed_in",
                    "isAuthenticated": true,
                    "message": "The user is already signed in."
                ] as [String: Any])
            }
            AppNavigation.shared.requestSignIn()
            return jsonResult([
                "status": "sign_in_requested",
                "isAuthenticated": false,
                "message": "Sign-in dialog requested. Wait for the user to finish signing in before retrying the operation that requires an account."
            ] as [String: Any])
        }
        if MCPMarketplaceHandlers.isMarketplaceTool(name) {
            return try await MCPMarketplaceHandlers.handle(name: name, arguments: rawArguments, container: defaultContainer)
        }
        if MCPWebHandlers.canHandle(name) {
            // Reading a web page has nothing to do with a film, and the wizard
            // may call it before one is the active document.
            var arguments = rawArguments
            arguments.removeValue(forKey: filmArgument)
            return try await MCPWebHandlers.handle(name: name, arguments: arguments)
        }
        if name == filmListDescriptor.name {
            return jsonResult(ProjectDocumentController.shared.openDocuments.map(filmSummary))
        }
        if MCPModelHandlers.canHandle(name) {
            // The catalog belongs to the account, not to a film, and the
            // wizard reads it before one is the active document.
            var arguments = rawArguments
            arguments.removeValue(forKey: filmArgument)
            return try await MCPModelHandlers.handle(name: name, arguments: arguments)
        }

        var arguments = rawArguments
        let filmValue = arguments.removeValue(forKey: filmArgument)

        // `footage_list` across every open film: run it per film and tag rows.
        if name == "footage_list", (filmValue as? String) == "*" {
            var items: [[String: Any]] = []
            for doc in ProjectDocumentController.shared.openDocuments {
                let result = try await invoke(name: name, arguments: arguments, container: doc.container)
                let rows = ((result["structuredContent"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
                for var row in rows {
                    row["filmId"] = doc.id.uuidString
                    row["filmName"] = doc.displayName
                    items.append(row)
                }
            }
            return jsonResult(items)
        }

        let container: ModelContainer
        if let doc = try resolveFilm(filmValue) {
            container = doc.container
        } else if let defaultContainer {
            container = defaultContainer
        } else {
            throw MCPToolError.invalidArguments("no film is open; open one in the app or pass `film`")
        }
        let context = ModelContext(container)

        if MCPLibraryHandlers.canHandle(name) {
            return try await MCPLibraryHandlers.handle(name: name, arguments: arguments, context: context)
        }
        if MCPSequenceHandlers.canHandle(name) {
            return try await MCPSequenceHandlers.handle(name: name, arguments: arguments, context: context)
        }
        if MCPGenerateHandlers.canHandle(name) {
            return try await MCPGenerateHandlers.handle(name: name, arguments: arguments, context: context)
        }
        if MCPCaptionHandlers.canHandle(name) {
            return try await MCPCaptionHandlers.handle(name: name, arguments: arguments, context: context)
        }
        if MCPPodcastHandlers.canHandle(name) {
            return try await MCPPodcastHandlers.handle(name: name, arguments: arguments, context: context)
        }
        if MCPWizardHandlers.canHandle(name) {
            return try await MCPWizardHandlers.handle(name: name, arguments: arguments, context: context)
        }
        #if os(macOS)
        if RemotionMCPHandlers.canHandle(name) {
            return try await RemotionMCPHandlers.handle(name: name, arguments: arguments, context: context)
        }
        #else
        if name.hasPrefix("remotion_") {
            // Should never get here — descriptors aren't surfaced — but be defensive.
            throw MCPToolError.macOSOnly
        }
        #endif
        throw MCPToolError.invalidArguments("unknown tool: \(name)")
    }

    // MARK: - Helpers shared by handlers

    /// Build a single-text-content tools/call result envelope.
    static func textResult(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]]]
    }

    /// Build a tools/call result envelope with both a JSON object (for clients that
    /// inspect structured content) and a textual fallback. Per the MCP spec,
    /// `structuredContent` must be a JSON object — arrays are wrapped in `{ items: [...] }`.
    static func jsonResult(_ payload: Any) -> [String: Any] {
        let structured: [String: Any]
        if let dict = payload as? [String: Any] {
            structured = dict
        } else if let arr = payload as? [Any] {
            structured = ["items": arr]
        } else {
            structured = ["value": payload]
        }
        let pretty = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return [
            "content": [["type": "text", "text": pretty]],
            "structuredContent": structured
        ]
    }
}
