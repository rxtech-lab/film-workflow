import Foundation

/// What a thread is for.
///
/// Almost every thread is a conversation in the agent window. A Simple mode
/// thread is different in kind: it drives a wizard the user is looking at
/// instead of a transcript, so it gets the wizard tools, a narrower allowlist,
/// and a system prompt that describes phases rather than a chat.
nonisolated enum AgentThreadMode: Equatable, Sendable {
    case conversation
    case simpleMode(templateID: String)

    private static let simplePrefix = "simple:"

    /// Round-trips through the single string column on `AgentThread`.
    init(raw: String) {
        guard raw.hasPrefix(Self.simplePrefix) else {
            self = .conversation
            return
        }
        let id = String(raw.dropFirst(Self.simplePrefix.count))
        self = id.isEmpty ? .conversation : .simpleMode(templateID: id)
    }

    var raw: String {
        switch self {
        case .conversation: ""
        case .simpleMode(let id): Self.simplePrefix + id
        }
    }

    var templateID: String? {
        if case .simpleMode(let id) = self { return id }
        return nil
    }

    var isSimpleMode: Bool { templateID != nil }
}
