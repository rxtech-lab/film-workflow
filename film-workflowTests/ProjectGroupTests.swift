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

    @Test("MCP creates groups, assigns projects, filters lists, and ungroups")
    func mcpGroupLifecycle() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let createGroupResult = try await MCPProjectHandlers.handle(
            name: "create_project_group",
            arguments: ["name": "Trailer"],
            context: context
        )
        let groupPayload = try #require(try decoded(createGroupResult) as? [String: Any])
        let groupID = try #require(groupPayload["id"] as? String)

        let createProjectResult = try await MCPProjectHandlers.handle(
            name: "create_project",
            arguments: [
                "type": "music",
                "name": "Trailer score",
                "group_id": groupID,
            ],
            context: context
        )
        let projectPayload = try #require(try decoded(createProjectResult) as? [String: Any])
        let projectID = try #require(projectPayload["id"] as? String)
        #expect(projectPayload["groupId"] as? String == groupID)

        let groupedList = try await MCPProjectHandlers.handle(
            name: "list_projects",
            arguments: ["type": "music", "group_id": groupID],
            context: context
        )
        let groupedItems = try #require(try decoded(groupedList) as? [[String: Any]])
        #expect(groupedItems.count == 1)

        _ = try await MCPProjectHandlers.handle(
            name: "move_project_to_group",
            arguments: ["type": "music", "id": projectID, "group_id": NSNull()],
            context: context
        )

        let ungroupedList = try await MCPProjectHandlers.handle(
            name: "list_projects",
            arguments: ["type": "music", "group_id": NSNull()],
            context: context
        )
        let ungroupedItems = try #require(try decoded(ungroupedList) as? [[String: Any]])
        #expect(ungroupedItems.count == 1)
        #expect(ungroupedItems.first?["groupId"] is NSNull)
    }

    @Test("MCP destructive tools require explicit confirmation")
    func mcpDeleteRequiresConfirmation() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let music = MusicProject(name: "Keep me")
        context.insert(music)
        try context.save()
        let id = MCPProjectHandlers.stableID(of: music).uuidString

        await #expect(throws: MCPToolError.self) {
            _ = try await MCPProjectHandlers.handle(
                name: "delete_project",
                arguments: ["type": "music", "id": id, "confirm": false],
                context: context
            )
        }
        #expect(try context.fetch(FetchDescriptor<MusicProject>()).count == 1)

        _ = try await MCPProjectHandlers.handle(
            name: "delete_project",
            arguments: ["type": "music", "id": id, "confirm": true],
            context: context
        )
        #expect(try context.fetch(FetchDescriptor<MusicProject>()).isEmpty)
    }
}
