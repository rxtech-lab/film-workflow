import Foundation

/// What the list should do in response to a transcript or streaming change.
nonisolated enum MessageListPinningAction<ID: Hashable & Sendable>: Equatable {
    case none
    case clearPin
    case pinUserMessageToTop(ID)
    case repinUserMessageToTop(ID)
    case releasePinAndScrollToBottom
    case scrollToBottom
}

/// Decides when the latest user message is pinned to the top of the viewport.
///
/// Ported from rxcode's `MessageList` package. Pure state machine — the view
/// applies the returned action, which keeps the tricky scroll choreography
/// testable without a running app.
///
/// Two levels of state, and the distinction matters:
/// - `pinnedUserMessageID` is **persistent**. It keeps the reserved tail spacer
///   sized, and survives the pin being released.
/// - `isPinningUserMessage` is **transient**. It says whether we are actively
///   re-asserting the scroll position.
///
/// Releasing the pin deliberately does *not* clear the id.
nonisolated struct MessageListPinningController<ID: Hashable & Sendable>: Equatable {
    private(set) var pinnedUserMessageID: ID?
    private(set) var isPinningUserMessage: Bool

    init(pinnedUserMessageID: ID? = nil, isPinningUserMessage: Bool = false) {
        self.pinnedUserMessageID = pinnedUserMessageID
        self.isPinningUserMessage = isPinningUserMessage
    }

    mutating func handleLastMessageChange(
        id: ID?,
        isUserMessage: Bool,
        isStreaming: Bool,
        isAtBottom: Bool
    ) -> MessageListPinningAction<ID> {
        guard let id else {
            clear()
            return .clearPin
        }

        if isUserMessage {
            pinnedUserMessageID = id
            isPinningUserMessage = true
            return .pinUserMessageToTop(id)
        }

        guard isPinningUserMessage, let pinnedUserMessageID else {
            return isAtBottom ? .scrollToBottom : .none
        }

        if isStreaming {
            return .repinUserMessageToTop(pinnedUserMessageID)
        }

        releasePin()
        return .releasePinAndScrollToBottom
    }

    mutating func handleStreamingChange(
        oldValue: Bool,
        newValue: Bool,
        isAtBottom: Bool
    ) -> MessageListPinningAction<ID> {
        guard oldValue && !newValue else { return .none }
        guard isPinningUserMessage else { return isAtBottom ? .scrollToBottom : .none }
        releasePin()
        return .releasePinAndScrollToBottom
    }

    mutating func releasePin() {
        isPinningUserMessage = false
    }

    mutating func clear() {
        pinnedUserMessageID = nil
        isPinningUserMessage = false
    }
}
