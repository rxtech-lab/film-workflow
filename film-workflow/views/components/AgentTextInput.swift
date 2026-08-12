import SwiftUI

#if os(macOS)
import AppKit

/// The composer's text field, hosting an `NSTextView` directly.
///
/// Ported from rxcode's `IMETextView`. Two reasons it is not a `TextEditor`:
///
/// 1. **IME correctness.** SwiftUI's `TextEditor` overrides `insertText` to
///    enforce binding sync, which races with the input method and discards
///    composing Hangul (and Japanese kana) on commit. Owning the `NSTextView`
///    lets us skip binding write-back while marked text is active, which
///    removes the race.
/// 2. **Key handling.** Enter-to-send with Shift+Enter for a newline, ↑/↓ for
///    history, Tab to accept a completion and Escape to dismiss a popup all need
///    `doCommand(by:)`, which `TextEditor` does not expose.
struct AgentTextInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var hasMarkedText: Bool

    /// Bumping this UUID asks the view to take first responder. Plain SwiftUI
    /// re-renders must NOT steal focus — that races with text selection in the
    /// transcript above.
    var focusTrigger: UUID?

    var font: NSFont
    var textColor: NSColor
    var placeholder: String = ""

    var onReturn: () -> Void
    /// Return `true` to consume the key; `false` lets the text view handle it.
    var onUpArrow: () -> Bool = { false }
    var onDownArrow: () -> Bool = { false }
    var onTab: () -> Bool = { false }
    var onEscape: () -> Bool = { false }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = AgentNSTextView()
        textView.delegate = context.coordinator
        textView.font = font
        textView.textColor = textColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        applyCallbacks(to: textView)
        return scrollView
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        guard let textView = nsView.documentView as? AgentNSTextView else { return }
        if textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        }
        textView.delegate = nil
        textView.clearCallbacks()
        textView.undoManager?.removeAllActions(withTarget: textView)
        textView.allowsUndo = false
        nsView.documentView = nil
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? AgentNSTextView else { return }
        applyCallbacks(to: textView)

        // Skip write-in while the IME is composing — same reason the coordinator
        // skips write-back. Compare against the coordinator's cached value so we
        // don't materialize `textView.string` (O(n)) on every parent re-render.
        if !textView.hasMarkedText(), context.coordinator.lastAppliedText != text {
            textView.string = text
            context.coordinator.lastAppliedText = text
        }
        if textView.font != font { textView.font = font }
        if textView.textColor != textColor { textView.textColor = textColor }
        if textView.placeholder != placeholder { textView.placeholder = placeholder }

        // Take first responder only when an explicit focus request fires (the
        // UUID changed), never on a plain re-render.
        if let trigger = focusTrigger,
           trigger != context.coordinator.lastAppliedFocusTrigger {
            context.coordinator.lastAppliedFocusTrigger = trigger
            if let window = textView.window, window.isKeyWindow,
               window.firstResponder !== textView {
                DispatchQueue.main.async {
                    textView.window?.makeFirstResponder(textView)
                }
            }
        }
    }

    private func applyCallbacks(to textView: AgentNSTextView) {
        textView.onReturn = onReturn
        textView.onUpArrow = onUpArrow
        textView.onDownArrow = onDownArrow
        textView.onTab = onTab
        textView.onEscape = onEscape
        textView.onMarkedTextChange = { active in
            if hasMarkedText != active { hasMarkedText = active }
        }
        textView.onFocusChange = { focused in
            if isFocused != focused { isFocused = focused }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>
        var lastAppliedText: String = ""
        var lastAppliedFocusTrigger: UUID?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Skip binding write-back during IME composition; the binding picks
            // up the committed text from the next textDidChange after the IME
            // finalizes.
            if textView.hasMarkedText() { return }
            let current = textView.string
            lastAppliedText = current
            if text.wrappedValue != current {
                text.wrappedValue = current
            }
        }
    }
}

// MARK: - NSTextView subclass

final class AgentNSTextView: NSTextView {
    var onReturn: () -> Void = {}
    var onUpArrow: () -> Bool = { false }
    var onDownArrow: () -> Bool = { false }
    var onTab: () -> Bool = { false }
    var onEscape: () -> Bool = { false }
    var onMarkedTextChange: (Bool) -> Void = { _ in }
    var onFocusChange: (Bool) -> Void = { _ in }

    func clearCallbacks() {
        onReturn = {}
        onUpArrow = { false }
        onDownArrow = { false }
        onTab = { false }
        onEscape = { false }
        onMarkedTextChange = { _ in }
        onFocusChange = { _ in }
    }

    var placeholder: String = "" {
        didSet { needsDisplay = true }
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocusChange(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onFocusChange(false) }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        let padding = textContainer?.lineFragmentPadding ?? 0
        let inset = textContainerInset
        let rect = NSRect(
            x: inset.width + padding,
            y: inset.height,
            width: max(0, bounds.width - inset.width * 2 - padding),
            height: max(0, bounds.height - inset.height * 2)
        )
        placeholder.draw(in: rect, withAttributes: [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.placeholderTextColor,
        ])
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onMarkedTextChange(hasMarkedText())
    }

    override func unmarkText() {
        super.unmarkText()
        onMarkedTextChange(false)
    }

    override func keyDown(with event: NSEvent) {
        // Shift+Enter: AppKit doesn't bind this to a doCommand. Force-commit any
        // composing IME text first, then insert the newline through NSTextView so
        // the insertion point and scroll position update together.
        if event.keyCode == 36, event.modifierFlags.contains(.shift) {
            commitMarkedTextIfNeeded()
            insertText("\n", replacementRange: selectedRange())
            revealInsertionPoint()
            return
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            // The IME has already committed any composing text via insertText:
            // before this command is dispatched, so the binding is up to date.
            onReturn()
            return
        case #selector(insertTab(_:)):
            if onTab() { return }
        case #selector(moveUp(_:)):
            if onUpArrow() { return }
        case #selector(moveDown(_:)):
            if onDownArrow() { return }
        case #selector(cancelOperation(_:)):
            if onEscape() { return }
        default:
            break
        }
        super.doCommand(by: selector)
    }

    private func commitMarkedTextIfNeeded() {
        guard hasMarkedText() else { return }
        let range = markedRange()
        guard range.location != NSNotFound, range.length > 0,
              let storage = textStorage,
              NSMaxRange(range) <= (storage.string as NSString).length
        else { return }
        let composing = (storage.string as NSString).substring(with: range)
        insertText(composing, replacementRange: range)
    }

    private func revealInsertionPoint() {
        let length = (string as NSString).length
        let location = min(max(selectedRange().location, 0), length)
        scrollRangeToVisible(NSRange(location: location, length: 0))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let length = (self.string as NSString).length
            let location = min(max(self.selectedRange().location, 0), length)
            self.scrollRangeToVisible(NSRange(location: location, length: 0))
        }
    }
}
#endif
