import Foundation
import Testing

@testable import film_workflow

/// The pinning state machine ported from rxcode.
///
/// Worth testing directly because the behaviour it drives — the user's message
/// jumping to the top and staying there while the reply streams — is otherwise
/// only observable by watching the app, and the failure modes are subtle
/// (a pin that never releases, or one that releases a frame too early).
@Suite("Message list pinning")
struct MessageListPinningTests {

    private typealias Controller = MessageListPinningController<Int>
    private typealias Action = MessageListPinningAction<Int>

    @Test("A new user message pins to the top")
    func userMessagePins() {
        var controller = Controller()
        let action = controller.handleLastMessageChange(
            id: 1, isUserMessage: true, isStreaming: false, isAtBottom: true
        )
        #expect(action == .pinUserMessageToTop(1))
        #expect(controller.pinnedUserMessageID == 1)
        #expect(controller.isPinningUserMessage)
    }

    @Test("Assistant content arriving while streaming re-pins rather than releasing")
    func streamingRepins() {
        var controller = Controller()
        _ = controller.handleLastMessageChange(
            id: 1, isUserMessage: true, isStreaming: true, isAtBottom: true
        )
        let action = controller.handleLastMessageChange(
            id: 2, isUserMessage: false, isStreaming: true, isAtBottom: true
        )
        #expect(action == .repinUserMessageToTop(1))
        #expect(controller.isPinningUserMessage)
    }

    @Test("Assistant content arriving after streaming ends releases the pin")
    func nonStreamingContentReleases() {
        var controller = Controller()
        _ = controller.handleLastMessageChange(
            id: 1, isUserMessage: true, isStreaming: true, isAtBottom: true
        )
        let action = controller.handleLastMessageChange(
            id: 2, isUserMessage: false, isStreaming: false, isAtBottom: true
        )
        #expect(action == .releasePinAndScrollToBottom)
        #expect(!controller.isPinningUserMessage)
    }

    @Test("Releasing the pin keeps the tracked id, so the tail spacer stays sized")
    func releaseKeepsTrackedID() {
        var controller = Controller()
        _ = controller.handleLastMessageChange(
            id: 1, isUserMessage: true, isStreaming: true, isAtBottom: true
        )
        controller.releasePin()
        #expect(!controller.isPinningUserMessage)
        // This is the distinction the whole layout depends on: the reserved
        // space is keyed off the id, not off the transient flag.
        #expect(controller.pinnedUserMessageID == 1)
    }

    @Test("The end of streaming releases a held pin")
    func streamingEndReleases() {
        var controller = Controller()
        _ = controller.handleLastMessageChange(
            id: 1, isUserMessage: true, isStreaming: true, isAtBottom: true
        )
        let action = controller.handleStreamingChange(
            oldValue: true, newValue: false, isAtBottom: true
        )
        #expect(action == .releasePinAndScrollToBottom)
    }

    @Test("Streaming starting is not a release")
    func streamingStartIsNoop() {
        var controller = Controller()
        let action = controller.handleStreamingChange(
            oldValue: false, newValue: true, isAtBottom: true
        )
        #expect(action == .none)
    }

    @Test("With no pin, streaming ending only follows the bottom when already there")
    func unpinnedStreamingEnd() {
        var controller = Controller()
        #expect(
            controller.handleStreamingChange(oldValue: true, newValue: false, isAtBottom: true)
                == .scrollToBottom
        )
        #expect(
            controller.handleStreamingChange(oldValue: true, newValue: false, isAtBottom: false)
                == .none
        )
    }

    @Test("An emptied transcript clears the pin")
    func emptyTranscriptClears() {
        var controller = Controller()
        _ = controller.handleLastMessageChange(
            id: 1, isUserMessage: true, isStreaming: true, isAtBottom: true
        )
        let action = controller.handleLastMessageChange(
            id: nil, isUserMessage: false, isStreaming: false, isAtBottom: true
        )
        #expect(action == .clearPin)
        #expect(controller.pinnedUserMessageID == nil)
    }
}

/// The "am I following the bottom?" anchor.
@Suite("Message list scroll anchor")
struct MessageListScrollAnchorTests {

    @Test("Growing content pulls the view down while anchored")
    func growthFollowsBottom() {
        var anchor = MessageListScrollAnchor()
        anchor.apply(contentHeight: 500, visibleMaxY: 500, isUserDriven: false)
        #expect(
            anchor.apply(contentHeight: 600, visibleMaxY: 500, isUserDriven: false)
                == .scrollToBottom
        )
    }

    @Test("A deliberate scroll up un-sticks the anchor")
    func userScrollReleases() {
        var anchor = MessageListScrollAnchor()
        anchor.apply(contentHeight: 1000, visibleMaxY: 1000, isUserDriven: false)
        // Same height, viewport now far from the bottom, driven by the user.
        anchor.apply(contentHeight: 1000, visibleMaxY: 200, isUserDriven: true)
        #expect(!anchor.isNearBottom)
        #expect(
            anchor.apply(contentHeight: 1100, visibleMaxY: 200, isUserDriven: false) == .none
        )
    }

    @Test("A layout settle cannot un-stick the anchor")
    func layoutSettleKeepsAnchor() {
        var anchor = MessageListScrollAnchor()
        anchor.apply(contentHeight: 1000, visibleMaxY: 1000, isUserDriven: false)
        // A tall card lays out in one frame: the distance from the bottom is
        // suddenly huge, but the user never touched anything. If this released
        // the anchor, the pending auto-scroll would bail and strand the view.
        anchor.apply(contentHeight: 1000, visibleMaxY: 200, isUserDriven: false)
        #expect(anchor.isNearBottom)
        #expect(
            anchor.apply(contentHeight: 1100, visibleMaxY: 200, isUserDriven: false)
                == .scrollToBottom
        )
    }
}
