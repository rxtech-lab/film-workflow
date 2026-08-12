import Foundation
import SwiftData
import SwiftUI

/// What an agent thread is pointed at.
///
/// A thread is free-form: it may target a project in any tab, or nothing at all.
/// The target does **not** gate which tools the agent can call — every thread
/// gets the whole MCP surface (see `AgentToolPolicy`). It only shapes the system
/// prompt and supplies the default project id the agent would otherwise have to
/// discover with `list_projects` on every turn.
nonisolated enum AgentTargetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case caption
    case remotion
    case music
    case narrative
    case imageGen

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .none: return "No project"
        case .caption: return "Caption"
        case .remotion: return "Remotion"
        case .music: return "Music"
        case .narrative: return "Narrative"
        case .imageGen: return "Image"
        }
    }

    var systemImage: String {
        switch self {
        case .none: return "circle.dashed"
        case .caption: return "captions.bubble"
        case .remotion: return "film.stack"
        case .music: return "music.note"
        case .narrative: return "text.book.closed"
        case .imageGen: return "photo.on.rectangle.angled"
        }
    }

    /// The `type` discriminator `MCPProjectHandlers` expects, so a prompt can
    /// tell the agent what to pass to `get_project` / `update_project`.
    var mcpProjectType: String? {
        switch self {
        case .none: return nil
        case .caption: return "caption"
        case .remotion: return "remotion"
        case .music: return "music"
        case .narrative: return "narrative"
        case .imageGen: return "image"
        }
    }

    /// Kinds offered in the target picker. Remotion projects only exist where
    /// the runtime can spawn a subprocess.
    static var selectable: [AgentTargetKind] {
        #if os(macOS)
            return allCases
        #else
            return allCases.filter { $0 != .remotion }
        #endif
    }
}

/// A resolved pointer to one project, safe to persist and to hand across
/// boundaries.
///
/// Carries a plain `UUID` rather than a `PersistentIdentifier` for the same
/// reason `CaptionProject.projectUUID` exists: a `PersistentIdentifier` is not
/// stable across store migrations and cannot be put in a scene payload.
nonisolated struct AgentTarget: Codable, Hashable, Sendable {
    var kind: AgentTargetKind
    var projectUUID: UUID?

    static let none = AgentTarget(kind: .none, projectUUID: nil)

    var isEmpty: Bool { kind == .none || projectUUID == nil }

    init(kind: AgentTargetKind, projectUUID: UUID?) {
        self.kind = kind
        self.projectUUID = projectUUID
    }
}

// MARK: - Resolution

/// Looks a target's project up and describes it for a prompt.
///
/// Every lookup goes through the `MCPProjectHandlers` fetchers rather than
/// reimplementing identity: those already know that Caption uses `projectUUID`,
/// Remotion uses `id`, and the remaining three have no explicit id and are
/// addressed by `stableID(of:)` — a UUID hashed from the persistent identifier.
/// Using the same functions here guarantees the id the agent sees in a tool
/// result is the id the window is targeting.
@MainActor
enum AgentTargetResolver {

    /// Human-readable project name, or nil when the target no longer resolves
    /// (the project was deleted while a thread pointed at it).
    static func name(for target: AgentTarget, context: ModelContext) -> String? {
        guard let uuid = target.projectUUID else { return nil }
        let id = uuid.uuidString
        switch target.kind {
        case .none:
            return nil
        case .caption:
            return (try? MCPCaptionHandlers.fetchCaption(id: id, context: context))?.name
        case .music:
            return (try? MCPProjectHandlers.fetchMusic(id: id, context: context))?.name
        case .narrative:
            return (try? MCPProjectHandlers.fetchNarrative(id: id, context: context))?.name
        case .imageGen:
            return (try? MCPProjectHandlers.fetchImage(id: id, context: context))?.name
        case .remotion:
            #if os(macOS)
                return (try? MCPProjectHandlers.fetchRemotion(id: id, context: context))?.name
            #else
                return nil
            #endif
        }
    }

    /// The block appended to the system prompt so the agent knows what it is
    /// working on and which id to pass to tools.
    static func promptBlock(for target: AgentTarget, context: ModelContext) -> String {
        guard !target.isEmpty,
              let uuid = target.projectUUID,
              let type = target.kind.mcpProjectType
        else {
            return """
                No project is selected. Use list_projects to find one, and ask the \
                user which they mean if it is ambiguous.
                """
        }

        let name = name(for: target, context: context) ?? "(unavailable)"
        var block = """
            The user is working on the \(type) project "\(name)".
            Its id is \(uuid.uuidString) — pass it as `project_id` (or `caption_id` \
            for caption_* tools) unless the user asks about something else.
            """

        if target.kind == .caption {
            block += """


                Caption ids and project ids are the same value here.
                """
        }
        return block
    }
}
