import Foundation
import SwiftData
import SwiftUI

/// What an agent thread is pointed at.
///
/// A thread is free-form: it may target one item in the film's library, a
/// sequence, or nothing at all (the whole film). The target does **not** gate
/// which tools the agent can call — every thread gets the whole MCP surface
/// (see `AgentToolPolicy`). It only shapes the system prompt and supplies the
/// default id the agent would otherwise have to discover with `footage_list`
/// on every turn.
///
/// Raw values are persisted on `AgentThread`, so the older spellings stay.
nonisolated enum AgentTargetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case caption
    case remotion
    case music
    case narrative
    case imageGen
    case videoGen
    case screenRecording
    case sequence

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .none: return "Whole film"
        case .caption: return "Captions"
        case .remotion: return "Remotion"
        case .music: return "Music"
        case .narrative: return "Narration"
        case .imageGen: return "Images"
        case .screenRecording: return "Screen Recording"
        case .videoGen: return "Video"
        case .sequence: return "Sequence"
        }
    }

    var systemImage: String {
        switch self {
        case .none: return "film"
        case .caption: return "captions.bubble"
        case .remotion: return "atom"
        case .music: return "music.note"
        case .narrative: return "text.book.closed"
        case .imageGen: return "photo.on.rectangle.angled"
        case .screenRecording: return "record.circle"
        case .videoGen: return "video.badge.waveform"
        case .sequence: return "film.stack"
        }
    }

    /// The library kind this target is, so a prompt and the `@` mention token
    /// speak the library's language rather than this enum's.
    var footageKind: FootageKind? {
        switch self {
        case .none: return nil
        case .caption: return .caption
        case .remotion: return .remotion
        case .music: return .music
        case .narrative: return .narration
        case .imageGen: return .image
        case .screenRecording: return .screenRecording
        case .videoGen: return .video
        case .sequence: return .sequence
        }
    }

    init(footageKind: FootageKind) {
        switch footageKind {
        case .caption: self = .caption
        case .remotion: self = .remotion
        case .music: self = .music
        case .narration: self = .narrative
        case .image: self = .imageGen
        case .screenRecording: self = .screenRecording
        case .video: self = .videoGen
        case .sequence: self = .sequence
        case .imported: self = .none
        }
    }

    /// How a prompt names the kind: "the music item", "the sequence".
    var promptNoun: String {
        switch self {
        case .none: return "film"
        case .caption: return "captions item"
        case .remotion: return "Remotion composition"
        case .music: return "music item"
        case .narrative: return "narration item"
        case .imageGen: return "image item"
        case .screenRecording: return "screen recording item"
        case .videoGen: return "video item"
        case .sequence: return "sequence"
        }
    }

    /// Kinds offered in the target picker. Remotion compositions only exist
    /// where the runtime can spawn a subprocess.
    static var selectable: [AgentTargetKind] {
        #if os(macOS)
            return allCases
        #else
            return allCases.filter { $0 != .remotion }
        #endif
    }
}

/// A resolved pointer to one library item, safe to persist and to hand across
/// boundaries.
///
/// Carries the plain `UUID` the library uses (`id` on the model,
/// `projectUUID` on captions) rather than a `PersistentIdentifier`, which is
/// not stable across store migrations and cannot be put in a scene payload.
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

/// Looks a target's item up and describes it for a prompt.
///
/// Every lookup goes through `MCPLibraryHandlers`, the same fetchers the tools
/// use, so the id the agent sees in a tool result is the id the window is
/// targeted at.
@MainActor
enum AgentTargetResolver {

    /// Human-readable item name, or nil when the target no longer resolves
    /// (the item was deleted while a thread pointed at it).
    static func name(for target: AgentTarget, context: ModelContext) -> String? {
        guard let uuid = target.projectUUID, let kind = target.kind.footageKind else { return nil }
        return MCPLibraryHandlers.name(id: uuid, kind: kind, context: context)
    }

    /// The block appended to the system prompt so the agent knows what it is
    /// working on and which id to pass to tools. `toolNamePrefix` is the
    /// spelling the engine sees (`mcp__film_workflow__` for a CLI agent).
    static func promptBlock(
        for target: AgentTarget,
        context: ModelContext,
        toolNamePrefix: String = ""
    ) -> String {
        let tool = { (name: String) in toolNamePrefix + name }
        guard !target.isEmpty, let uuid = target.projectUUID else {
            return """
                Nothing in the library is selected, so the thread is about the whole \
                film. Use \(tool("footage_list")) to see what it contains, and ask the \
                user which item they mean if it is ambiguous.
                """
        }

        let name = name(for: target, context: context) ?? "(no longer in the library)"
        let noun = target.kind.promptNoun
        if target.kind == .sequence {
            return """
                The user has the sequence "\(name)" selected. Its id is \(uuid.uuidString) — \
                pass it as `sequence_id` to the sequence tools, or as `footage_id` to \
                \(tool("footage_get")) and \(tool("footage_update")), unless the user asks \
                about something else.
                """
        }
        return """
            The user has the \(noun) "\(name)" selected in the library. Its id is \
            \(uuid.uuidString) — pass it as `footage_id` unless the user asks about \
            something else.
            """
    }
}
