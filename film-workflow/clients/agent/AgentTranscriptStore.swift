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
            messages: thread.orderedMessages.compactMap(message(from:)),
            nativeSessionIDs: nativeSessionIDs(for: thread),
            summary: thread.summary,
            compactedMessageIDs: Set(
                thread.orderedMessages.filter(\.isCompacted).map(\.id)
            )
        )
        return sdkThread
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
            guard !row.content.isEmpty else { return nil }
            return RxAgentSDK.AgentMessage(
                id: row.id,
                role: role(row.roleEnum),
                blocks: [.text(id: row.id, row.content)],
                timestamp: row.createdAt
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
    /// `createdAt` is taken from the SDK message when there is one. Rows are
    /// ordered by it, and a turn's prose is persisted after its tool calls have
    /// already landed — stamping it with `Date()` would reorder the reloaded
    /// transcript relative to what the user watched.
    @discardableResult
    static func append(
        role: AgentMessageRole,
        content: String,
        id: UUID? = nil,
        createdAt: Date? = nil,
        to thread: AgentThread,
        context: ModelContext
    ) -> AgentMessage {
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
