import Foundation
import SwiftData

/// One agent conversation.
///
/// Threads are free-form rather than owned by a project: each picks its own
/// target, several can run at once, and a thread with no target at all is
/// useful (asking about projects before deciding which to open). That is why
/// this is a top-level `@Model` with a plain `targetUUID` instead of a
/// relationship to any one project type — the five project models have no
/// common supertype, and a relationship to each would make retargeting a
/// schema-level operation.
@Model
final class AgentThread {
    var id: UUID = UUID()
    var title: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// Kept at the top of the thread menu. Survives archiving order changes.
    var isPinned: Bool = false

    // MARK: - Target

    var targetKind: String = AgentTargetKind.none.rawValue
    var targetUUID: UUID?

    // MARK: - Backend

    /// Empty means "follow `AgentSettings.shared.defaultBackend`". Stored rather
    /// than resolved so a thread started on Codex keeps answering on Codex after
    /// the user changes the app default.
    var backendRaw: String = ""

    /// Native session ids for CLI backends, keyed by `AgentBackend.rawValue`,
    /// as JSON.
    ///
    /// Per-backend rather than a single field because Claude Code and Codex
    /// session ids are not interchangeable: handing one to the other resumes
    /// nothing and, worse, can make the CLI create a junk session. Same reason
    /// rxcode's `ChatThread` keeps `providerSessionIdsJSON`.
    var providerSessionIDsJSON: String?

    // MARK: - Content

    @Relationship(deleteRule: .cascade, inverse: \AgentMessage.thread)
    var messages: [AgentMessage] = []

    /// Rolling summary of turns that have been compacted away.
    ///
    /// Older turns are folded into this rather than replayed verbatim; on Apple
    /// Intelligence the window is small enough that a long conversation cannot
    /// be replayed at all.
    var summary: String = ""

    init(
        title: String = "",
        target: AgentTarget = .none,
        backend: AgentBackend? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isPinned = false
        self.targetKind = target.kind.rawValue
        self.targetUUID = target.projectUUID
        self.backendRaw = backend?.rawValue ?? ""
        self.providerSessionIDsJSON = nil
        self.messages = []
        self.summary = ""
    }

    // MARK: - Accessors

    var target: AgentTarget {
        get {
            AgentTarget(
                kind: AgentTargetKind(rawValue: targetKind) ?? .none,
                projectUUID: targetUUID
            )
        }
        set {
            targetKind = newValue.kind.rawValue
            targetUUID = newValue.projectUUID
        }
    }

    /// The thread's backend override, or nil to follow the app default.
    var backendOverride: AgentBackend? {
        get { backendRaw.isEmpty ? nil : AgentBackend(rawValue: backendRaw) }
        set { backendRaw = newValue?.rawValue ?? "" }
    }

    var orderedMessages: [AgentMessage] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }

    /// Text turns that still count toward what we send the model.
    var liveTextMessages: [AgentMessage] {
        orderedMessages.filter { !$0.isCompacted && $0.kindEnum == .text }
    }

    /// The title shown in the thread menu. Falls back to the first thing the
    /// user said, so a thread is recognizable without being named by hand.
    var displayTitle: String {
        if !title.isEmpty { return title }
        guard let first = orderedMessages.first(where: { $0.roleEnum == .user && $0.kindEnum == .text })
        else { return "New Thread" }
        let line = first.content
            .split(separator: "\n")
            .first
            .map(String.init) ?? first.content
        return line.count > 48 ? String(line.prefix(48)) + "…" : line
    }

    // MARK: - Provider sessions

    func providerSessionID(for backend: AgentBackend) -> String? {
        guard let providerSessionIDsJSON,
              let data = providerSessionIDsJSON.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return map[backend.rawValue]
    }

    func setProviderSessionID(_ id: String?, for backend: AgentBackend) {
        var map: [String: String] = [:]
        if let providerSessionIDsJSON,
           let data = providerSessionIDsJSON.data(using: .utf8),
           let existing = try? JSONDecoder().decode([String: String].self, from: data) {
            map = existing
        }
        if let id, !id.isEmpty {
            map[backend.rawValue] = id
        } else {
            map.removeValue(forKey: backend.rawValue)
        }
        providerSessionIDsJSON = (try? JSONEncoder().encode(map))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Drops every stored resume id. Called when the transcript is cleared or
    /// compacted hard enough that the CLI's own history would disagree with ours.
    func clearProviderSessionIDs() {
        providerSessionIDsJSON = nil
    }
}
