import Foundation
import SwiftData
import Testing

@testable import film_workflow

@Suite("MCP document routing")
@MainActor
struct MCPDocumentRoutingTests {
    private func temporaryPackage(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPRouting-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
            .appendingPathExtension("rxfilmstudio")
    }

    private func decoded(_ result: [String: Any]) throws -> Any {
        let content = try #require(result["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        return try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    @Test("Every tool schema carries a film argument; film_list reports open films")
    func schemasAndListing() async throws {
        let tools = MCPToolRegistry.allDescriptors()
        #expect(tools.contains { $0.name == "film_list" })
        for tool in tools where tool.name != "film_list" {
            let props = tool.inputSchema["properties"] as? [String: Any]
            #expect(props?["film"] != nil, "\(tool.name) lacks film")
        }

        let urlA = temporaryPackage("Alpha"), urlB = temporaryPackage("Beta")
        try FileManager.default.createDirectory(at: urlA.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: urlB.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: urlA.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: urlB.deletingLastPathComponent())
        }
        let controller = ProjectDocumentController.shared
        let a = try controller.createDocument(at: urlA)
        let b = try controller.createDocument(at: urlB)
        controller.activeDocument = a

        a.container.mainContext.insert(MusicProject(name: "In Alpha"))
        b.container.mainContext.insert(MusicProject(name: "In Beta"))
        // Tool calls open their own context, which only sees saved rows.
        try a.container.mainContext.save()
        try b.container.mainContext.save()

        let listed = try decoded(try await MCPToolRegistry.invoke(name: "film_list", arguments: [:], container: nil)) as? [[String: Any]]
        #expect(listed?.contains { $0["name"] as? String == "Alpha" } == true)
        #expect(listed?.contains { $0["name"] as? String == "Beta" } == true)

        // Default routes to the active film; `film` overrides; "*" spans both.
        let fromActive = try decoded(try await MCPToolRegistry.invoke(
            name: "footage_list", arguments: ["kind": "music"], container: a.container)) as? [[String: Any]]
        #expect(fromActive?.map { $0["name"] as? String } == ["In Alpha"])

        let fromBeta = try decoded(try await MCPToolRegistry.invoke(
            name: "footage_list", arguments: ["kind": "music", "film": "Beta"], container: a.container)) as? [[String: Any]]
        #expect(fromBeta?.map { $0["name"] as? String } == ["In Beta"])

        let byID = try decoded(try await MCPToolRegistry.invoke(
            name: "footage_list", arguments: ["kind": "music", "film": b.id.uuidString], container: nil)) as? [[String: Any]]
        #expect(byID?.map { $0["name"] as? String } == ["In Beta"])

        let all = try decoded(try await MCPToolRegistry.invoke(
            name: "footage_list", arguments: ["kind": "music", "film": "*"], container: nil)) as? [[String: Any]]
        #expect(Set(all?.compactMap { $0["filmName"] as? String } ?? []) == ["Alpha", "Beta"])

        await #expect(throws: MCPToolError.self) {
            _ = try await MCPToolRegistry.invoke(name: "footage_list", arguments: ["kind": "music", "film": "Nope"], container: nil)
        }
        await #expect(throws: MCPToolError.self) {
            _ = try await MCPToolRegistry.invoke(name: "footage_list", arguments: ["kind": "music"], container: nil)
        }

        await controller.close(a)
        await controller.close(b)
    }
}
