import Foundation
import SwiftUI

/// A message a `MessageList` can render.
///
/// Deliberately does **not** refine `Identifiable`, unlike rxcode's original.
/// SwiftData's `@Model` macro synthesizes a main-actor-isolated `Identifiable`
/// conformance, which cannot satisfy the `ID: Sendable` constraint the pinning
/// controller needs. Asking for a separate `messageID` sidesteps that entirely,
/// and the identity is still whatever the model calls `id`.
protocol MessageListItem {
    associatedtype MessageID: Hashable & Sendable

    var messageID: MessageID { get }
    var isUserMessage: Bool { get }
    /// Rows that are chrome rather than content — a typing indicator, a spacer.
    ///
    /// Excluded from "is there real content after the pinned user message?", so
    /// a spinner appearing on its own never releases the pin.
    var isMessageListAccessory: Bool { get }
}

extension MessageListItem {
    var isMessageListAccessory: Bool { false }
}

/// A chat transcript that pins the latest user message to the top of the
/// viewport while the reply streams in below it.
///
/// Ported from rxcode's `MessageList` package, minus its bidirectional
/// pagination (an agent thread is loaded whole) and its performance counters.
///
/// **The mechanism.** Sending a message does not `scrollTo(userMessage, .top)`.
/// Instead a tail spacer is sized so that `turnHeight + spacer == viewport`, and
/// a 1pt anchor sits *below* that spacer. Scrolling to the anchor puts the
/// spacer's end at the viewport bottom, which is exactly the position where the
/// user's message rests at the top with reserved space filling the rest. As the
/// reply grows, the spacer shrinks toward zero and the very same anchor becomes
/// ordinary follow-the-bottom behaviour. Because the pin and the auto-scroll aim
/// at one target, they can never disagree — a separate `scrollTo(_, .top)` is
/// what used to cause a visible jump whenever the spacer hadn't settled.
struct MessageList<Message: MessageListItem, RowContent: View, TrailingContent: View>: View {
    private let messages: [Message]
    private let isStreaming: Bool
    private let shouldScrollToBottom: Bool
    private let scrollToBottomAnimated: Bool
    @Binding private var isAtBottom: Bool
    private let rowContent: (Message) -> RowContent
    private let trailingContent: () -> TrailingContent

    @State private var anchor = MessageListScrollAnchor()
    @State private var pinning = MessageListPinningController<Message.MessageID>()
    @State private var scrollPhase: ScrollPhase = .idle
    @State private var scrollViewHeight: CGFloat = 0
    @State private var latestUserMinY: CGFloat = 0
    @State private var tailMarkerMinY: CGFloat = 0
    @State private var activeTurnMaxMeasuredHeight: CGFloat = 0
    @State private var canReleasePinnedUserMessageByScroll = false
    @State private var pinTask: Task<Void, Never>?
    @State private var bottomScrollTask: Task<Void, Never>?
    @State private var lastStreamingBottomScrollDate = Date.distantPast

    init(
        messages: [Message],
        isStreaming: Bool = false,
        shouldScrollToBottom: Bool = false,
        scrollToBottomAnimated: Bool = true,
        isAtBottom: Binding<Bool> = .constant(true),
        @ViewBuilder rowContent: @escaping (Message) -> RowContent,
        @ViewBuilder trailingContent: @escaping () -> TrailingContent
    ) {
        self.messages = messages
        self.isStreaming = isStreaming
        self.shouldScrollToBottom = shouldScrollToBottom
        self.scrollToBottomAnimated = scrollToBottomAnimated
        self._isAtBottom = isAtBottom
        self.rowContent = rowContent
        self.trailingContent = trailingContent
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(messages, id: \.messageID) { message in
                        let messageID = message.messageID
                        rowContent(message)
                            .onGeometryChange(for: CGFloat.self) { geometry in
                                geometry.frame(in: .named(MessageListConstants.coordinateSpaceName)).minY
                            } action: { value in
                                guard messageID == pinning.pinnedUserMessageID else { return }
                                updateLatestUserMinY(value)
                            }
                            .id(messageID)
                    }

                    trailingContent()

                    tailMarker
                    // The tail spacer is sized so that `turnHeight + spacer == viewport`
                    // (see `pinTailSpacerHeight`). The bottom anchor therefore sits BELOW
                    // the spacer: scrolling to it places the spacer's end at the viewport
                    // bottom, which is exactly the position where the latest user message
                    // rests at the top with the reserved space filling the rest. As the
                    // turn grows the spacer shrinks toward zero, at which point the same
                    // anchor naturally follows the streaming response.
                    pinTailSpacer
                    bottomAnchor
                }
                .coordinateSpace(.named(MessageListConstants.coordinateSpaceName))
            }
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                scrollViewHeight = height
            }
            .onScrollGeometryChange(for: MessageListScrollMetrics.self) { geometry in
                MessageListScrollMetrics(
                    contentHeight: geometry.contentSize.height,
                    visibleMinY: geometry.visibleRect.minY,
                    visibleMaxY: geometry.visibleRect.maxY
                )
            } action: { _, metrics in
                handleScrollMetrics(metrics, proxy: proxy)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { oldOffsetY, offsetY in
                guard isDirectUserScroll,
                      pinning.isPinningUserMessage,
                      canReleasePinnedUserMessageByScroll,
                      offsetY > oldOffsetY + MessageListConstants.userScrollDownDelta
                else { return }
                releasePinnedUserMessage(proxy: proxy)
            }
            .onScrollPhaseChange { _, phase in
                scrollPhase = phase
            }
            .task {
                if shouldScrollToBottom {
                    scrollToBottom(proxy: proxy, animated: false)
                }
            }
            .onChange(of: shouldScrollToBottom) { _, shouldScroll in
                guard shouldScroll else { return }
                guard !pinning.isPinningUserMessage else { return }
                // While streaming, the caller toggles this once per delta.
                // Scrolling immediately on each toggle stacks a fresh spring
                // animation per delta — the visible "scrolls a lot" churn.
                // Funnel it through the same throttle the message-change path
                // uses so it collapses to roughly one scroll per interval.
                // Non-streaming toggles keep the immediate path so they stay
                // snappy and exact.
                if isStreaming {
                    scheduleScrollToBottom(proxy: proxy)
                    return
                }
                anchor.resetToBottom()
                scrollToBottom(proxy: proxy, animated: scrollToBottomAnimated)
            }
            .onChange(of: isStreaming) { oldValue, newValue in
                if !newValue {
                    lastStreamingBottomScrollDate = .distantPast
                }
                applyPinningAction(
                    pinning.handleStreamingChange(
                        oldValue: oldValue,
                        newValue: newValue,
                        isAtBottom: isAnchoredAtBottom
                    ),
                    proxy: proxy
                )
            }
            .onChange(of: messageListChangeToken) { oldToken, newToken in
                handleMessageListChange(oldToken: oldToken, newToken: newToken, proxy: proxy)
            }
            .onDisappear {
                pinTask?.cancel()
                bottomScrollTask?.cancel()
            }
        }
    }

    // MARK: - Sentinel rows

    private var tailMarker: some View {
        Color.clear
            .frame(height: 1)
            .id(MessageListConstants.tailMarkerID)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.frame(in: .named(MessageListConstants.coordinateSpaceName)).minY
            } action: { value in
                updateTailMarkerMinY(value)
            }
    }

    private var pinTailSpacer: some View {
        Color.clear.frame(height: pinTailSpacerHeight)
    }

    private var bottomAnchor: some View {
        Color.clear
            .frame(height: 1)
            .id(MessageListConstants.bottomAnchorID)
    }

    // MARK: - Scroll phase

    private var isUserDrivenScroll: Bool {
        switch scrollPhase {
        case .interacting, .tracking, .decelerating: true
        case .idle, .animating: false
        @unknown default: false
        }
    }

    /// Excludes `.decelerating`, which our own animated scrolls pass through on
    /// macOS — treating those as user scrolls would let the app release its own
    /// pin the moment it set it.
    private var isDirectUserScroll: Bool {
        switch scrollPhase {
        case .interacting, .tracking: true
        case .idle, .animating, .decelerating: false
        @unknown default: false
        }
    }

    // MARK: - Geometry

    private var pinTailSpacerHeight: CGFloat {
        // Persistent reservation: as long as there is a latest user message, reserve
        // `viewport - turnHeight` at the bottom so the turn (latest user message →
        // end of content) can rest at the top of the viewport. This is keyed off the
        // tracked user message — NOT the transient `isPinningUserMessage` flag — so the
        // reserved space survives scrolling and the pin "releasing"; it only collapses
        // naturally as the turn grows to fill the viewport, or when the latest user
        // message changes (which resets the measurement to the new turn).
        guard pinning.pinnedUserMessageID != nil, scrollViewHeight > 0 else { return 0 }
        return max(0, scrollViewHeight - activeTurnHeight - MessageListConstants.minimumPinnedTailSpacing)
    }

    private var rawActiveTurnMeasuredHeight: CGFloat {
        max(0, tailMarkerMinY - latestUserMinY)
    }

    private var activeTurnHeight: CGFloat {
        // Use only the settled, ratcheted height (committed from `handleScrollMetrics`).
        // Mixing in the live `rawActiveTurnMeasuredHeight` here would let a mid-frame
        // desync between the two geometry anchors momentarily shrink the spacer.
        activeTurnMaxMeasuredHeight
    }

    private var pinnedTurnFillsViewport: Bool {
        guard scrollViewHeight > 0 else { return false }
        return activeTurnHeight >= scrollViewHeight - MessageListConstants.minimumPinnedTailSpacing
    }

    private var isAnchoredAtBottom: Bool {
        anchor.isNearBottom && isAtBottom
    }

    // MARK: - Derived transcript state

    private var latestContentItem: Message? {
        messages.last { !$0.isMessageListAccessory }
    }

    private var latestUserMessageID: Message.MessageID? {
        messages.last { $0.isUserMessage }?.messageID
    }

    private var hasContentAfterPinnedUserMessage: Bool {
        guard let pinnedID = pinning.pinnedUserMessageID,
              let pinnedIndex = messages.firstIndex(where: { $0.messageID == pinnedID })
        else { return false }

        let nextIndex = messages.index(after: pinnedIndex)
        guard nextIndex < messages.endIndex else { return false }
        return messages[nextIndex...].contains { !$0.isMessageListAccessory }
    }

    private var shouldReleasePinnedUserMessageForFilledTurn: Bool {
        pinning.isPinningUserMessage
            && hasContentAfterPinnedUserMessage
            && pinnedTurnFillsViewport
    }

    private var messageListChangeToken: MessageListChangeToken<Message.MessageID> {
        MessageListChangeToken(
            ids: messages.map(\.messageID),
            latestContentID: latestContentItem?.messageID,
            latestUserMessageID: latestUserMessageID
        )
    }

    // MARK: - Change handling

    private func handleScrollMetrics(_ metrics: MessageListScrollMetrics, proxy: ScrollViewProxy) {
        let decision = anchor.apply(
            contentHeight: metrics.contentHeight,
            visibleMaxY: metrics.visibleMaxY,
            isUserDriven: isUserDrivenScroll
        )
        updateIsAtBottomBinding(anchor.isNearBottom)

        // Commit the active-turn height here rather than from the per-row geometry
        // callbacks. This callback fires once the scroll view's geometry has settled
        // for the frame, so `latestUserMinY` and `tailMarkerMinY` are guaranteed to
        // reflect the same layout pass. Reading them from the individual row
        // callbacks could capture a transient state where one anchor moved (e.g. a
        // lazy row above the turn was just realized while scrolling) but the other
        // had not — which would ratchet a bogus height and permanently collapse the
        // reserved tail spacer.
        updateActiveTurnMaxMeasuredHeight()

        if shouldReleasePinnedUserMessageForFilledTurn, !isUserDrivenScroll {
            releasePinnedUserMessage(proxy: proxy)
        }

        if decision == .scrollToBottom,
           isAtBottom,
           isStreaming,
           !isUserDrivenScroll,
           !pinning.isPinningUserMessage {
            scheduleScrollToBottom(proxy: proxy)
        }
    }

    private func handleMessageListChange(
        oldToken: MessageListChangeToken<Message.MessageID>,
        newToken: MessageListChangeToken<Message.MessageID>,
        proxy: ScrollViewProxy
    ) {
        // Drop a stale pin if its message is no longer present (e.g. switching
        // threads or clearing a transcript). The persistent tail spacer is keyed off
        // `pinnedUserMessageID`, so a dangling id would otherwise reserve space for a
        // message that no longer exists.
        if let pinnedID = pinning.pinnedUserMessageID,
           !messages.contains(where: { $0.messageID == pinnedID }) {
            clearPinnedUserMessage()
        }

        let latestContentItem = latestContentItem
        if oldToken.latestUserMessageID != newToken.latestUserMessageID,
           let latestUserMessageID = newToken.latestUserMessageID,
           isStreaming || latestContentItem?.isUserMessage == true {
            let action = pinning.handleLastMessageChange(
                id: latestUserMessageID,
                isUserMessage: true,
                isStreaming: isStreaming,
                isAtBottom: isAnchoredAtBottom
            )
            applyPinningAction(action, proxy: proxy)
            return
        }

        let action = pinning.handleLastMessageChange(
            id: latestContentItem?.messageID,
            isUserMessage: latestContentItem?.isUserMessage == true,
            isStreaming: isStreaming,
            isAtBottom: isAnchoredAtBottom
        )
        applyPinningAction(action, proxy: proxy)
    }

    private func updateIsAtBottomBinding(_ value: Bool) {
        guard isAtBottom != value else { return }
        isAtBottom = value
    }

    // MARK: - Scrolling

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        // While reserved spacing exists below the latest turn, the content already fits
        // in the viewport — a follow/auto scroll would only pull the empty reserved
        // space into view and shove the turn around. Only scroll once the turn has
        // outgrown the viewport (no spacing left). The one scroll allowed to move into
        // the reserved area is the initial turn placement, which goes through
        // `scrollLatestTurnIntoView` (a direct `proxy.scrollTo`), not this path.
        guard pinTailSpacerHeight <= 0 else { return }

        if animated {
            withAnimation(.spring(duration: MessageListConstants.scrollAnimationSeconds, bounce: 0)) {
                proxy.scrollTo(MessageListConstants.bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(MessageListConstants.bottomAnchorID, anchor: .bottom)
        }
    }

    private func scheduleScrollToBottom(proxy: ScrollViewProxy) {
        guard bottomScrollTask == nil else { return }
        let delayNanoseconds = scrollToBottomDelayNanoseconds()
        bottomScrollTask = Task { @MainActor in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            bottomScrollTask = nil
            guard isAnchoredAtBottom, !isUserDrivenScroll, !pinning.isPinningUserMessage else { return }
            if isStreaming {
                lastStreamingBottomScrollDate = Date()
            }
            scrollToBottom(proxy: proxy, animated: true)
        }
    }

    private func scrollToBottomDelayNanoseconds() -> UInt64 {
        guard isStreaming else {
            return MessageListConstants.layoutSettleDelayNanoseconds
        }
        let elapsed = Date().timeIntervalSince(lastStreamingBottomScrollDate)
        let delay = max(0, MessageListConstants.streamingBottomScrollInterval - elapsed)
        return UInt64(delay * 1_000_000_000)
    }

    /// Positions the latest user turn by scrolling to the bottom anchor — NOT by
    /// scrolling the user message to the top. See the type's documentation for why.
    private func scrollLatestTurnIntoView(proxy: ScrollViewProxy, animated: Bool) {
        bottomScrollTask?.cancel()
        bottomScrollTask = nil
        pinTask?.cancel()
        canReleasePinnedUserMessageByScroll = false

        pinTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }

            if animated {
                withAnimation(.spring(duration: MessageListConstants.pinAnimationSeconds, bounce: 0.05)) {
                    proxy.scrollTo(MessageListConstants.bottomAnchorID, anchor: .bottom)
                }
                try? await Task.sleep(for: MessageListConstants.pinAnimationDuration)
            }

            // Re-assert across several frames so the position tracks the tail spacer
            // as it settles to its final size (the turn height is measured a frame or
            // two after the freshly-added content lays out).
            for _ in 0..<8 {
                guard !Task.isCancelled else { return }
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    proxy.scrollTo(MessageListConstants.bottomAnchorID, anchor: .bottom)
                }
                try? await Task.sleep(for: .milliseconds(16))
            }

            // Only arm manual release once settled, or our own animated scroll
            // would immediately look like a user scroll and release the pin.
            guard !Task.isCancelled, pinning.isPinningUserMessage else { return }
            canReleasePinnedUserMessageByScroll = true
        }
    }

    private func releasePinnedUserMessage(proxy: ScrollViewProxy) {
        pinTask?.cancel()
        canReleasePinnedUserMessageByScroll = false
        pinning.releasePin()
        anchor.resetToBottom()
        updateIsAtBottomBinding(true)
        scrollToBottom(proxy: proxy, animated: true)
    }

    private func clearPinnedUserMessage() {
        pinTask?.cancel()
        pinning.clear()
        latestUserMinY = 0
        tailMarkerMinY = 0
        activeTurnMaxMeasuredHeight = 0
        canReleasePinnedUserMessageByScroll = false
    }

    private func applyPinningAction(
        _ action: MessageListPinningAction<Message.MessageID>,
        proxy: ScrollViewProxy
    ) {
        switch action {
        case .none:
            break
        case .clearPin:
            clearPinnedUserMessage()
        case .pinUserMessageToTop:
            resetPinnedTurnMeasurements()
            canReleasePinnedUserMessageByScroll = false
            scrollLatestTurnIntoView(proxy: proxy, animated: true)
        case .repinUserMessageToTop:
            // New streaming content arrived. While the reserved spacing still absorbs
            // the growth, the turn stays put on its own — re-asserting the scroll would
            // just cause an unnecessary jump. Only re-position once the spacing is gone.
            if pinTailSpacerHeight <= 0 {
                scrollLatestTurnIntoView(proxy: proxy, animated: false)
            }
        case .releasePinAndScrollToBottom:
            releasePinnedUserMessage(proxy: proxy)
        case .scrollToBottom:
            scheduleScrollToBottom(proxy: proxy)
        }
    }

    private func resetPinnedTurnMeasurements() {
        latestUserMinY = 0
        tailMarkerMinY = 0
        activeTurnMaxMeasuredHeight = 0
    }

    // MARK: - Measurement
    //
    // Every write below runs in an animation-suppressing transaction:
    // measurement must never animate, or the spacer visibly springs while the
    // turn is still laying out.

    private func updateLatestUserMinY(_ value: CGFloat) {
        guard abs(value - latestUserMinY) > 0.5 else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            latestUserMinY = value
        }
    }

    private func updateTailMarkerMinY(_ value: CGFloat) {
        guard abs(value - tailMarkerMinY) > 0.5 else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            tailMarkerMinY = value
        }
    }

    private func updateActiveTurnMaxMeasuredHeight() {
        // Keep measuring the turn height while a latest user message is tracked, even
        // after the pin "releases", so the persistent tail spacer stays correctly sized.
        guard pinning.pinnedUserMessageID != nil else { return }
        let measured = rawActiveTurnMeasuredHeight
        // Ratcheted: only ever grows. A transient shrink would grow the spacer
        // and visibly shove the transcript.
        guard measured > activeTurnMaxMeasuredHeight + 0.5 else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            activeTurnMaxMeasuredHeight = measured
        }
    }
}

extension MessageList where TrailingContent == EmptyView {
    init(
        messages: [Message],
        isStreaming: Bool = false,
        shouldScrollToBottom: Bool = false,
        scrollToBottomAnimated: Bool = true,
        isAtBottom: Binding<Bool> = .constant(true),
        @ViewBuilder rowContent: @escaping (Message) -> RowContent
    ) {
        self.init(
            messages: messages,
            isStreaming: isStreaming,
            shouldScrollToBottom: shouldScrollToBottom,
            scrollToBottomAnimated: scrollToBottomAnimated,
            isAtBottom: isAtBottom,
            rowContent: rowContent,
            trailingContent: { EmptyView() }
        )
    }
}

nonisolated struct MessageListScrollMetrics: Equatable {
    var contentHeight: CGFloat
    var visibleMinY: CGFloat
    var visibleMaxY: CGFloat
}

/// One `Equatable` value covering structure *and* identity, so a single
/// `onChange` catches insertions, deletions and a new latest turn.
private nonisolated struct MessageListChangeToken<ID: Hashable & Sendable>: Equatable {
    var ids: [ID]
    var latestContentID: ID?
    var latestUserMessageID: ID?
}

private nonisolated enum MessageListConstants {
    static let bottomAnchorID = "message-list-bottom-anchor"
    static let tailMarkerID = "message-list-tail-marker"
    static let coordinateSpaceName = "message-list-content"
    static let minimumPinnedTailSpacing: CGFloat = 16
    static let userScrollDownDelta: CGFloat = 4
    static let layoutSettleDelayNanoseconds: UInt64 = 8_000_000
    static let streamingBottomScrollInterval: TimeInterval = 1.5
    static let scrollAnimationSeconds: Double = 0.18
    static let pinAnimationDuration: Duration = .milliseconds(250)
    static let pinAnimationSeconds: Double = 0.25
}
