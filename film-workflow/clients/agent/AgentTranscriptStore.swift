import Foundation
import RxAgentSDK
import SwiftData

/// Moves a thread's transcript between SwiftData and the SDK.
///
/// The SDK's `AgentThread` is in-memory and rebuilt per session; ours has to
/// survive a relaunch, so SwiftData stays the system of record and the SDK
/// thread is hydrated from it. Two directions:
///
/// - **Load** turns persisted rows into `RxAgentSDK.AgentMessage` values so a
///   reopened thread arrives with its history, its rolling summary, and each
///   engine's own resume id intact.
/// - **Record** folds the live event stream back into rows as it happens, so a
///   crash mid-turn loses at most the turn in flight.
///
/// Row ids are reused as SDK message ids rather than minted fresh. That is what
/// lets compaction survive a relaunch: `compactedMessageIDs` is a set of message
/// ids, and a thread whose ids changed on load would replay everything it had
/// already folded away.
@MainActor
enum AgentTranscriptStore {

    // MARK: - Loading

    /// Hydrates `thread` into a fresh SDK thread.
    static func load(_ thread: AgentThread) -> RxAgentSDK.AgentThread {
        let sdkThread = RxAgentSDK.AgentThread()
        sdkThread.title = thread.title.isEmpty ? nil : thread.title
        sdkThread.load(
            messages: messages(from: thread),
            nativeSessionIDs: nativeSessionIDs(for: thread),
            summary: thread.summary,
            compactedMessageIDs: Set(
                thread.orderedMessages.filter(\.isCompacted).map(\.id)
            )
        )
        return sdkThread
    }

    private static func messages(from thread: AgentThread) -> [RxAgentSDK.AgentMessage] {
        let rows = thread.orderedMessages
        guard let json = thread.transcriptJSON,
              let snapshot = try? JSONDecoder().decode(TranscriptSnapshot.self, from: Data(json.utf8)),
              snapshot.version == 1 else {
            // Old histories contain flattened prose and timestamps only. Keep
            // that content intact; its original block boundaries are unknown.
            return rows.compactMap(message(from:))
        }
        let rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let toolRows = Dictionary(rows.compactMap { row -> (String, AgentMessage)? in
            guard row.kindEnum == .tool else { return nil }
            return (row.toolCallId ?? row.id.uuidString, row)
        }, uniquingKeysWith: { first, _ in first })
        var included: Set<UUID> = []
        var messages: [RxAgentSDK.AgentMessage] = []
        for saved in snapshot.messages {
            guard let row = rowsByID[saved.id], row.kindEnum != .proposal else { continue }
            included.insert(row.id)
            let blocks = saved.blocks.compactMap { block -> AgentBlock? in
                switch block {
                case .text(let id, let text): return .text(id: id, text)
                case .thinking(let id, let text): return .thinking(id: id, text)
                case .toolCall(let id):
                    guard let tool = toolRows[id], let call = message(from: tool)?.toolCalls.first else { return nil }
                    included.insert(tool.id)
                    return .toolCall(call)
                }
            }
            messages.append(RxAgentSDK.AgentMessage(id: row.id, role: role(row.roleEnum), blocks: blocks,
                                                   timestamp: row.createdAt, error: saved.error,
                                                   attachments: attachments(from: row)))
        }
        // Preserve rows saved after the last snapshot (for example, a local
        // proposal outcome or a tool interrupted before a message boundary).
        // Never sort the snapshot itself: its explicit order is authoritative.
        for row in rows where !included.contains(row.id) {
            guard let extra = message(from: row) else { continue }
            let position = messages.firstIndex { $0.timestamp > extra.timestamp } ?? messages.endIndex
            messages.insert(extra, at: position)
        }
        return messages
    }

    /// Each engine's own native session id, keyed the way the SDK keys them.
    private static func nativeSessionIDs(for thread: AgentThread) -> [AgentClientID: String] {
        var result: [AgentClientID: String] = [:]
        for backend in AgentBackend.allCases {
            guard let id = thread.providerSessionID(for: backend), !id.isEmpty else { continue }
            result[AgentClientFactory.clientID(for: backend)] = id
        }
        return result
    }

    /// One persisted row as an SDK message.
    ///
    /// A proposal row has no SDK equivalent and is deliberately dropped from the
    /// model's view: what the agent needs to know about a proposal is whether
    /// the user accepted it, and that arrives as the separate `system` row
    /// `AgentController.recordProposalOutcome` writes.
    static func message(from row: AgentMessage) -> RxAgentSDK.AgentMessage? {
        switch row.kindEnum {
        case .text:
            let attachments = attachments(from: row)
            guard !row.content.isEmpty || !attachments.isEmpty else { return nil }
            return RxAgentSDK.AgentMessage(
                id: row.id,
                role: role(row.roleEnum),
                blocks: [.text(id: row.id, row.content)],
                timestamp: row.createdAt,
                attachments: attachments
            )

        case .tool:
            guard let name = row.toolName else { return nil }
            // A row still marked pending never got a result — the app quit
            // mid-turn. Reloading it as pending would leave a spinner running
            // forever, so it comes back as a failure instead.
            let stalled = row.toolStatusEnum == .pending || row.toolStatusEnum == nil
            return RxAgentSDK.AgentMessage(
                id: row.id,
                role: .assistant,
                blocks: [.toolCall(AgentToolCall(
                    id: row.toolCallId ?? row.id.uuidString,
                    name: name,
                    input: input(from: row.toolArgs),
                    result: row.toolResult ?? (stalled ? "no result" : nil),
                    isError: stalled || row.toolStatusEnum == .failed,
                    hasCompleteInput: row.toolArgs != nil
                ))],
                timestamp: row.createdAt
            )

        case .proposal:
            return nil
        }
    }

    private static func role(_ role: AgentMessageRole) -> AgentRole {
        switch role {
        case .user: .user
        case .assistant: .assistant
        case .system: .system
        }
    }

    private static func input(from json: String?) -> [String: JSONValue] {
        guard let json,
              let value = JSONValue(jsonString: json),
              case .object(let fields) = value
        else { return [:] }
        return fields
    }

    // MARK: - Recording

    /// Appends a plain row and returns it.
    ///
    /// `createdAt` is taken from the SDK message when available. The ordered
    /// snapshot preserves interleaved blocks; timestamps remain the fallback
    /// for legacy history and local rows outside the SDK transcript.
    @discardableResult
    static func append(
        role: AgentMessageRole,
        content: String,
        id: UUID? = nil,
        createdAt: Date? = nil,
        to thread: AgentThread,
        context: ModelContext
    ) -> AgentMessage {
        if let id, let existing = thread.messages.first(where: { $0.id == id }) {
            existing.content = content
            if let createdAt { existing.createdAt = createdAt }
            return existing
        }
        let row = AgentMessage(role: role, content: content)
        if let id { row.id = id }
        if let createdAt { row.createdAt = createdAt }
        attach(row, to: thread, context: context)
        return row
    }

    static func attach(_ row: AgentMessage, to thread: AgentThread, context: ModelContext) {
        row.thread = thread
        context.insert(row)
        thread.messages.append(row)
        thread.updatedAt = Date()
    }

    /// Saves text/thinking/tool references in exactly the order the live SDK
    /// transcript renders. Flattened text remains available to existing callers,
    /// but is never used to reconstruct a snapshotted assistant message.
    static func saveTranscript(from sdkThread: RxAgentSDK.AgentThread, to thread: AgentThread, context: ModelContext) {
        var rowsByID = Dictionary(thread.messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var saved: [TranscriptSnapshot.Message] = []
        for message in sdkThread.messages {
            let row: AgentMessage
            if let existing = rowsByID[message.id] {
                row = existing
            } else {
                let role: AgentMessageRole = switch message.role {
                case .user: .user
                case .assistant: .assistant
                case .system: .system
                }
                row = append(role: role, content: message.plainText, id: message.id,
                             createdAt: message.timestamp, to: thread, context: context)
                rowsByID[message.id] = row
            }
            if row.kindEnum == .text { row.content = message.plainText }
            // Sent attachments are immutable. Encode once, rather than copying
            // image bytes again at every assistant message boundary.
            if row.attachmentsData == nil, !message.attachments.isEmpty {
                row.attachmentsData = try? PropertyListEncoder().encode(message.attachments)
            }
            let blocks: [TranscriptSnapshot.Block] = message.blocks.map { block in
                switch block {
                case .text(let id, let text): return .text(id: id, text)
                case .thinking(let id, let text): return .thinking(id: id, text)
                case .toolCall(let call): return .toolCall(id: call.id)
                }
            }
            saved.append(.init(id: message.id, blocks: blocks, error: message.error))
        }
        if let data = try? JSONEncoder().encode(TranscriptSnapshot(messages: saved)) {
            thread.transcriptJSON = String(decoding: data, as: UTF8.self)
        }
    }

    private static func attachments(from row: AgentMessage) -> [AgentAttachment] {
        guard let data = row.attachmentsData else { return [] }
        return (try? PropertyListDecoder().decode([AgentAttachment].self, from: data)) ?? []
    }

    // MARK: - Saving compaction state

    /// Writes the SDK thread's compaction state back onto the persisted rows.
    ///
    /// Rows are *marked*, never deleted: the visible transcript is unchanged and
    /// only what we send shrinks. That distinction is the whole design — a user
    /// scrolling back should still find what they asked an hour ago.
    static func saveCompaction(
        from sdkThread: RxAgentSDK.AgentThread,
        to thread: AgentThread
    ) {
        guard thread.summary != sdkThread.summary
            || !sdkThread.compactedMessageIDs.isEmpty
        else { return }

        thread.summary = sdkThread.summary
        let compacted = sdkThread.compactedMessageIDs
        for row in thread.messages where compacted.contains(row.id) && !row.isCompacted {
            row.isCompacted = true
        }
    }

    /// Writes each engine's native session id back onto the persisted thread.
    static func saveSessionIDs(
        from sdkThread: RxAgentSDK.AgentThread,
        to thread: AgentThread
    ) {
        for (clientID, sessionID) in sdkThread.nativeSessionIDs {
            guard let backend = AgentClientFactory.backend(for: clientID) else { continue }
            guard thread.providerSessionID(for: backend) != sessionID else { continue }
            thread.setProviderSessionID(sessionID, for: backend)
        }
    }
}

/// App-owned encoding, independent of the SDK's non-Codable UI value types.
private nonisolated struct TranscriptSnapshot: Codable {
    var version = 1
    var messages: [Message]

    nonisolated struct Message: Codable {
        var id: UUID
        var blocks: [Block]
        var error: String?
    }

    nonisolated enum Block: Codable {
        case text(id: UUID, String)
        case thinking(id: UUID, String)
        case toolCall(id: String)
    }
}
