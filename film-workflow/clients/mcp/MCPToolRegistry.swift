import Foundation
import SwiftData

/// Single source of truth for the tools the server exposes via `tools/list` and
/// dispatches via `tools/call`. Keeping descriptors and invocation in one place
/// avoids drift.
@MainActor
enum MCPToolRegistry {
    /// All tools, in the order surfaced to clients.
    static func allDescriptors() -> [MCPToolDescriptor] {
        var tools: [MCPToolDescriptor] = []
        tools.append(contentsOf: MCPProjectHandlers.descriptors)
        tools.append(contentsOf: MCPPodcastHandlers.descriptors)
        tools.append(contentsOf: MCPGenerateHandlers.descriptors)
        tools.append(contentsOf: MCPCaptionHandlers.descriptors)
        #if os(macOS)
        tools.append(contentsOf: RemotionMCPHandlers.descriptors)
        #endif
        tools.append(contentsOf: MCPSequenceHandlers.descriptors)
        tools.append(listDocumentsDescriptor)
        // Every tool can be pointed at a film other than the active one. Added
        // here rather than in forty descriptors so the schema cannot drift.
        return tools.map(withDocumentArgument)
    }

    static let documentArgument = "document"

    private static func withDocumentArgument(_ tool: MCPToolDescriptor) -> MCPToolDescriptor {
        guard tool.name != listDocumentsDescriptor.name else { return tool }
        var schema = tool.inputSchema
        var properties = (schema["properties"] as? [String: Any]) ?? [:]
        properties[documentArgument] = [
            "type": "string",
            "description": "Which open film to act on: its document id, package path, or name. Defaults to the film whose window is active. `list_projects` also accepts \"*\" for every open film."
        ] as [String: Any]
        schema["properties"] = properties
        return MCPToolDescriptor(name: tool.name, description: tool.description, inputSchema: schema)
    }

    private static let listDocumentsDescriptor = MCPToolDescriptor(
        name: "list_documents",
        description: "List the films (.rxfilmstudio packages) currently open in the app, with the active one flagged. Pass a film's id, path or name as `document` to other tools to work on it.",
        inputSchema: ["type": "object", "properties": [String: Any](), "additionalProperties": false]
    )

    /// Resolves the `document` argument to a film, or throws when it names
    /// nothing that is open.
    static func resolveDocument(_ value: Any?) throws -> ProjectDocument? {
        guard let raw = value as? String else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key != "*" else { return nil }
        let controller = ProjectDocumentController.shared
        if let uuid = UUID(uuidString: key), let doc = controller.document(id: uuid) { return doc }
        if let doc = controller.document(for: URL(fileURLWithPath: key)) { return doc }
        if let doc = controller.openDocuments.first(where: { $0.displayName.localizedCaseInsensitiveCompare(key) == .orderedSame }) {
            return doc
        }
        throw MCPToolError.invalidArguments("no open film matches document \"\(key)\"; call list_documents")
    }

    static func documentSummary(_ doc: ProjectDocument) -> [String: Any] {
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
        container defaultContainer: ModelContainer?
    ) async throws -> [String: Any] {
        if name == listDocumentsDescriptor.name {
            return jsonResult(ProjectDocumentController.shared.openDocuments.map(documentSummary))
        }

        var arguments = rawArguments
        let documentValue = arguments.removeValue(forKey: documentArgument)

        // `list_projects` across every open film: run it per film and tag rows.
        if name == "list_projects", (documentValue as? String) == "*" {
            var items: [[String: Any]] = []
            for doc in ProjectDocumentController.shared.openDocuments {
                let result = try await invoke(name: name, arguments: arguments, container: doc.container)
                let rows = ((result["structuredContent"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
                for var row in rows {
                    row["documentId"] = doc.id.uuidString
                    row["documentName"] = doc.displayName
                    items.append(row)
                }
            }
            return jsonResult(items)
        }

        let container: ModelContainer
        if let doc = try resolveDocument(documentValue) {
            container = doc.container
        } else if let defaultContainer {
            container = defaultContainer
        } else {
            throw MCPToolError.invalidArguments("no film is open; open one in the app or pass `document`")
        }
        let context = ModelContext(container)

        if MCPProjectHandlers.canHandle(name) {
            return try await MCPProjectHandlers.handle(name: name, arguments: arguments, context: context)
        }
        if MCPPodcastHandlers.canHandle(name) {
            return try await MCPPodcastHandlers.handle(name: name, arguments: arguments, context: context)
        }
        if MCPGenerateHandlers.canHandle(name) {
            return try await MCPGenerateHandlers.handle(name: name, arguments: arguments, context: context)
        }
        if MCPCaptionHandlers.canHandle(name) {
            return try await MCPCaptionHandlers.handle(name: name, arguments: arguments, context: context)
        }
        if MCPSequenceHandlers.canHandle(name) {
            return try await MCPSequenceHandlers.handle(name: name, arguments: arguments, context: context)
        }
        #if os(macOS)
        if RemotionMCPHandlers.canHandle(name) {
            return try await RemotionMCPHandlers.handle(name: name, arguments: arguments, context: context)
        }
        #else
        if name.hasPrefix("remotion_") && name != "remotion_list_projects" {
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
