#if os(macOS)
import AppKit
import SwiftUI

/// A line to scroll to and select in a `CodeTextView`. A new `id` repeats the request.
struct CodeReveal: Equatable {
    let line: Int
    let id = UUID()
}

/// Plain-text code editing with TSX highlighting: no smart quotes, dashes or spelling
/// corrections, native undo and the find bar, and no line wrapping.
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var highlights = true
    var reveal: CodeReveal?

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = Self.font
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier("remotion.source.editor")
        textView.string = text
        context.coordinator.highlight(textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            let selection = textView.selectedRanges
            textView.string = text
            let length = (text as NSString).length
            textView.selectedRanges = selection.map {
                let range = $0.rangeValue
                return NSValue(range: NSRange(location: min(range.location, length), length: 0))
            }
            context.coordinator.highlight(textView)
        }
        if let reveal, reveal != context.coordinator.revealed {
            context.coordinator.revealed = reveal
            DispatchQueue.main.async { Self.reveal(line: reveal.line, in: textView) }
        }
    }

    /// Selects `line` (1-based) and scrolls it into view.
    static func reveal(line: Int, in textView: NSTextView) {
        let source = textView.string as NSString
        var location = 0
        var current = 1
        while current < line, location < source.length {
            location = NSMaxRange(source.lineRange(for: NSRange(location: location, length: 0)))
            current += 1
        }
        let range = source.lineRange(for: NSRange(location: min(location, source.length), length: 0))
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView
        var revealed: CodeReveal?

        init(_ parent: CodeTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            highlight(textView)
        }

        func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            if parent.highlights {
                TSXHighlighter.apply(to: storage, font: CodeTextView.font)
            } else {
                storage.setAttributes([.font: CodeTextView.font, .foregroundColor: NSColor.textColor],
                                      range: NSRange(location: 0, length: storage.length))
            }
        }
    }
}
#endif
