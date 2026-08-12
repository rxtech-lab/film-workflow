import Foundation
import SwiftData

/// A cross-workflow collection. One group can contain projects from every
/// domain (for example, the narrative, music, captions, images, and Remotion
/// composition that make up one film).
@Model
final class ProjectGroup {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

/// Scalar group identifiers keep the grouping model independent of five
/// otherwise unrelated SwiftData model graphs. In particular, deleting a group
/// never cascades into deleting a project.
protocol GroupableProject: AnyObject {
    var groupID: UUID? { get set }
    var updatedAt: Date { get set }
}

enum ProjectGroupError: LocalizedError {
    case emptyName
    case duplicateName(String)
    case notFound(UUID)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Group name cannot be empty."
        case .duplicateName(let name):
            return "A group named \"\(name)\" already exists."
        case .notFound(let id):
            return "Project group not found: \(id.uuidString)"
        }
    }
}

@MainActor
enum ProjectGroupService {
    static func create(name: String, context: ModelContext) throws -> ProjectGroup {
        let trimmed = try validatedName(name, excluding: nil, context: context)
        let group = ProjectGroup(name: trimmed)
        context.insert(group)
        try context.save()
        return group
    }

    static func rename(_ group: ProjectGroup, to name: String, context: ModelContext) throws {
        group.name = try validatedName(name, excluding: group.id, context: context)
        group.updatedAt = Date()
        try context.save()
    }

    /// Deletes only the collection. Its projects are deliberately preserved and
    /// become ungrouped, regardless of project type.
    static func delete(_ group: ProjectGroup, context: ModelContext) throws {
        let groupID = group.id
        try ungroupProjects(groupID: groupID, context: context)
        context.delete(group)
        try context.save()
    }

    static func fetch(id: UUID, context: ModelContext) throws -> ProjectGroup {
        let groups = try context.fetch(FetchDescriptor<ProjectGroup>())
        guard let group = groups.first(where: { $0.id == id }) else {
            throw ProjectGroupError.notFound(id)
        }
        return group
    }

    static func move<Project: GroupableProject>(
        _ project: Project,
        to groupID: UUID?,
        context: ModelContext
    ) throws {
        if let groupID {
            _ = try fetch(id: groupID, context: context)
        }
        project.groupID = groupID
        project.updatedAt = Date()
        try context.save()
    }

    static func projectCounts(groupID: UUID, context: ModelContext) throws -> [String: Int] {
        [
            "music": try context.fetch(FetchDescriptor<MusicProject>()).count { $0.groupID == groupID },
            "narrative": try context.fetch(FetchDescriptor<NarrativeProject>()).count { $0.groupID == groupID },
            "caption": try context.fetch(FetchDescriptor<CaptionProject>()).count { $0.groupID == groupID },
            "image": try context.fetch(FetchDescriptor<ImageGenProject>()).count { $0.groupID == groupID },
            "remotion": try context.fetch(FetchDescriptor<RemotionProject>()).count { $0.groupID == groupID }
        ]
    }

    private static func validatedName(
        _ name: String,
        excluding excludedID: UUID?,
        context: ModelContext
    ) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProjectGroupError.emptyName }
        let duplicate = try context.fetch(FetchDescriptor<ProjectGroup>()).contains {
            $0.id != excludedID && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !duplicate else { throw ProjectGroupError.duplicateName(trimmed) }
        return trimmed
    }

    private static func ungroupProjects(groupID: UUID, context: ModelContext) throws {
        for project in try context.fetch(FetchDescriptor<MusicProject>()) where project.groupID == groupID {
            project.groupID = nil
        }
        for project in try context.fetch(FetchDescriptor<NarrativeProject>()) where project.groupID == groupID {
            project.groupID = nil
        }
        for project in try context.fetch(FetchDescriptor<CaptionProject>()) where project.groupID == groupID {
            project.groupID = nil
        }
        for project in try context.fetch(FetchDescriptor<ImageGenProject>()) where project.groupID == groupID {
            project.groupID = nil
        }
        for project in try context.fetch(FetchDescriptor<RemotionProject>()) where project.groupID == groupID {
            project.groupID = nil
        }
    }
}
