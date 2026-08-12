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
        return tools
    }

    /// Dispatch a tool call. Returns the MCP `tools/call` result envelope (with
    /// `content: [...]`, optionally `isError`).
    static func invoke(
        name: String,
        arguments: [String: Any],
        container: ModelContainer
    ) async throws -> [String: Any] {
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
