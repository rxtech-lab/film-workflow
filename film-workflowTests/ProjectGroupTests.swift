import Foundation
import SwiftData
import Testing

@testable import film_workflow

@Suite("Project groups")
@MainActor
struct ProjectGroupTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            MusicProject.self,
            GeneratedMusic.self,
            NarrativeProject.self,
            GeneratedNarrative.self,
            RemotionProject.self,
            ImageGenProject.self,
            GeneratedImage.self,
            CaptionProject.self,
            CaptionSegment.self,
            ProjectGroup.self,
            AgentThread.self,
            AgentMessage.self,
        ])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }

    private func decoded(_ result: [String: Any]) throws -> Any {
        let content = try #require(result["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        let data = try #require(text.data(using: .utf8))
        return try JSONSerialization.jsonObject(with: data)
    }

    @Test("Deleting a group preserves every project type as ungrouped")
    func deleteGroupPreservesProjects() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let group = try ProjectGroupService.create(name: "Launch Film", context: context)

        let music = MusicProject(name: "Score")
        let narrative = NarrativeProject(name: "Voiceover")
        let caption = CaptionProject(name: "English captions")
        let image = ImageGenProject(name: "Poster")
        let remotion = RemotionProject(name: "Final edit")
        let projects: [any GroupableProject] = [music, narrative, caption, image, remotion]
        for project in projects { project.groupID = group.id }
        context.insert(music)
        context.insert(narrative)
        context.insert(caption)
        context.insert(image)
        context.insert(remotion)
        try context.save()

        let counts = try ProjectGroupService.projectCounts(groupID: group.id, context: context)
        #expect(counts.values.reduce(0, +) == 5)

        try ProjectGroupService.delete(group, context: context)

        #expect(try context.fetch(FetchDescriptor<ProjectGroup>()).isEmpty)
        #expect(projects.allSatisfy { $0.groupID == nil })
        #expect(try context.fetch(FetchDescriptor<MusicProject>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<NarrativeProject>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<CaptionProject>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<ImageGenProject>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<RemotionProject>()).count == 1)
    }

    @Test("MCP creates folders, files items in them, filters lists, and unfiles")
    func mcpFolderLifecycle() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let createFolderResult = try await MCPLibraryHandlers.handle(
            name: "folder_create",
            arguments: ["name": "Trailer"],
            context: context
        )
        let folderPayload = try #require(try decoded(createFolderResult) as? [String: Any])
        let folderID = try #require(folderPayload["id"] as? String)

        let createResult = try await MCPLibraryHandlers.handle(
            name: "footage_create",
            arguments: [
                "kind": "music",
                "name": "Trailer score",
                "folder_id": folderID,
            ],
            context: context
        )
        let itemPayload = try #require(try decoded(createResult) as? [String: Any])
        let itemID = try #require(itemPayload["id"] as? String)
        #expect(itemPayload["folderId"] as? String == folderID)
        #expect(itemPayload["kind"] as? String == "music")
        #expect(itemPayload["name"] as? String == "Trailer score")
        // The id is the library's own, not a hash of the persistent identifier.
        let music = try #require(context.fetch(FetchDescriptor<MusicProject>()).first)
        #expect(itemID == music.id.uuidString)

        let filedList = try await MCPLibraryHandlers.handle(
            name: "footage_list",
            arguments: ["kind": "music", "folder_id": folderID],
            context: context
        )
        let filedItems = try #require(try decoded(filedList) as? [[String: Any]])
        #expect(filedItems.count == 1)

        _ = try await MCPLibraryHandlers.handle(
            name: "footage_move",
            arguments: ["footage_id": itemID, "folder_id": NSNull()],
            context: context
        )

        let looseList = try await MCPLibraryHandlers.handle(
            name: "footage_list",
            arguments: ["kind": "music", "folder_id": NSNull()],
            context: context
        )
        let looseItems = try #require(try decoded(looseList) as? [[String: Any]])
        #expect(looseItems.count == 1)
        #expect(looseItems.first?["folderId"] is NSNull)

        let folders = try #require(try decoded(try await MCPLibraryHandlers.handle(
            name: "folder_list", arguments: [:], context: context
        )) as? [[String: Any]])
        #expect(folders.first?["itemCount"] as? Int == 0)
    }

    @Test("MCP destructive tools require explicit confirmation")
    func mcpDeleteRequiresConfirmation() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let music = MusicProject(name: "Keep me")
        context.insert(music)
        try context.save()
        let id = music.id.uuidString

        await #expect(throws: MCPToolError.self) {
            _ = try await MCPLibraryHandlers.handle(
                name: "footage_delete",
                arguments: ["footage_id": id, "confirm": false],
                context: context
            )
        }
        #expect(try context.fetch(FetchDescriptor<MusicProject>()).count == 1)

        _ = try await MCPLibraryHandlers.handle(
            name: "footage_delete",
            arguments: ["footage_id": id, "confirm": true],
            context: context
        )
        #expect(try context.fetch(FetchDescriptor<MusicProject>()).isEmpty)
    }
}
