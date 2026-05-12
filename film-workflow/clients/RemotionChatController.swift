#if os(macOS)
import Foundation
import SwiftData

enum ChatScrollAnchor: Hashable {
    case message(UUID)
    case typing
}

@MainActor
@Observable
final class RemotionChatController {
    static let shared = RemotionChatController()

    struct Session {
        var input: String = ""
        var isSending: Bool = false
        var errorMessage: String?
        var task: Task<Void, Never>?
        var scrollAnchor: ChatScrollAnchor?
    }

    private var sessions: [UUID: Session] = [:]

    func session(for projectId: UUID) -> Session {
        sessions[projectId] ?? Session()
    }

    func setInput(_ value: String, for projectId: UUID) {
        var s = sessions[projectId] ?? Session()
        s.input = value
        sessions[projectId] = s
    }

    func setError(_ message: String?, for projectId: UUID) {
        var s = sessions[projectId] ?? Session()
        s.errorMessage = message
        sessions[projectId] = s
    }

    func setScrollAnchor(_ value: ChatScrollAnchor?, for projectId: UUID) {
        var s = sessions[projectId] ?? Session()
        s.scrollAnchor = value
        sessions[projectId] = s
    }

    func cancel(projectId: UUID) {
        sessions[projectId]?.task?.cancel()
    }

    func clear(projectId: UUID) {
        sessions[projectId]?.task?.cancel()
        sessions.removeValue(forKey: projectId)
    }

    /// Streams a chat turn for the given project. The agent task is owned by
    /// the controller so it survives view tear-down (tab switch, picker flip).
    /// Returns immediately; observers re-render as the session mutates.
    func send(
        instruction: String,
        project: RemotionProject,
        history: [RemotionMessage],
        config: AppConfig,
        modelContext: ModelContext,
        onFileWritten: @escaping (_ path: String, _ content: String) -> Void = { _, _ in },
        onCompleted: @escaping (_ anyFileWritten: Bool) -> Void = { _ in },
        onError: @escaping (_ error: Error) -> Void = { _ in }
    ) {
        let projectId = project.id
        var session = sessions[projectId] ?? Session()
        guard !session.isSending else { return }

        let userMsg = RemotionMessage(
            role: RemotionMessageRole.user.rawValue,
            content: instruction,
            project: project
        )
        modelContext.insert(userMsg)
        project.messages.append(userMsg)

        session.input = ""
        session.isSending = true
        session.errorMessage = nil

        let bindable = project
        session.task = Task { @MainActor [weak self] in
            defer {
                if let self {
                    var s = self.sessions[projectId] ?? Session()
                    s.isSending = false
                    s.task = nil
                    self.sessions[projectId] = s
                }
            }
            do {
                let stream = RemotionAgent.runEdit(
                    project: bindable,
                    userInstruction: instruction,
                    history: history,
                    config: config
                )

                var anyFileWritten = false
                var pendingToolMessages: [String: RemotionMessage] = [:]
                for try await event in stream {
                    switch event {
                    case .status:
                        break
                    case .toolCall(let id, let name, let args):
                        let msg = RemotionMessage(
                            role: RemotionMessageRole.assistant.rawValue,
                            content: "",
                            project: bindable,
                            kind: .tool,
                            toolName: name,
                            toolArgs: args,
                            toolStatus: .pending,
                            toolCallId: id
                        )
                        modelContext.insert(msg)
                        bindable.messages.append(msg)
                        pendingToolMessages[id] = msg
                    case .toolResult(let id, _, let summary, let ok):
                        if let msg = pendingToolMessages.removeValue(forKey: id) {
                            msg.toolResult = summary
                            msg.toolStatus = (ok ? RemotionToolStatus.ok : .failed).rawValue
                        }
                    case .assistantText(let text):
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { continue }
                        let msg = RemotionMessage(
                            role: RemotionMessageRole.assistant.rawValue,
                            content: trimmed,
                            project: bindable
                        )
                        modelContext.insert(msg)
                        bindable.messages.append(msg)
                    case .fileWritten(let path, let content):
                        anyFileWritten = true
                        if path == "src/Composition.tsx" {
                            bindable.compositionSource = content
                        }
                        onFileWritten(path, content)
                    case .completed:
                        if anyFileWritten {
                            bindable.updatedAt = Date()
                        }
                        onCompleted(anyFileWritten)
                    }
                }
                for msg in pendingToolMessages.values {
                    msg.toolStatus = RemotionToolStatus.failed.rawValue
                    if msg.toolResult == nil { msg.toolResult = "no result" }
                }
            } catch is CancellationError {
                // user-initiated, no error UI
            } catch {
                guard let self else { return }
                var s = self.sessions[projectId] ?? Session()
                s.errorMessage = error.localizedDescription
                self.sessions[projectId] = s
                onError(error)
            }
        }

        sessions[projectId] = session
    }
}
#endif
