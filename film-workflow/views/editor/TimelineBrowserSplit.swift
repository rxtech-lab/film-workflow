import SwiftUI

/// Both children keep their identity while the browser slides out of the layout.
/// Replacing a split with its timeline child would discard scroll, tool and thumbnail state.
struct TimelineBrowserSplit<Content: View, Browser: View>: View {
    let document: ProjectDocument
    let browserVisible: Bool
    let content: Content
    let browser: Browser

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var browserWidth: CGFloat
    @State private var dragStartWidth: CGFloat?

    private let dividerWidth: CGFloat = 6

    init(document: ProjectDocument, browserVisible: Bool,
         @ViewBuilder content: () -> Content, @ViewBuilder browser: () -> Browser) {
        self.document = document
        self.browserVisible = browserVisible
        self.content = content()
        self.browser = browser()
        _browserWidth = State(initialValue: document.panelLayout.sizes(for: .timelineColumns)?.last ?? 300)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = clampedWidth(browserWidth, available: geometry.size.width)
            HStack(spacing: 0) {
                content
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    // Animate the surrounding layout, not clip positions or the playhead.
                    .transaction { $0.animation = nil }
                HStack(spacing: 0) {
                    resizeHandle(width: width, available: geometry.size.width)
                    browser.frame(width: width, height: geometry.size.height)
                }
                // The browser retains its full content width as its visible area changes.
                .frame(width: browserVisible ? width + dividerWidth : 0, alignment: .leading)
                .clipped()
                .allowsHitTesting(browserVisible)
                .accessibilityHidden(!browserVisible)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: browserVisible)
        }
    }

    private func clampedWidth(_ width: CGFloat, available: CGFloat) -> CGFloat {
        min(max(240, width), min(460, max(0, available - 360 - dividerWidth)))
    }

    private func resize(to width: CGFloat, available: CGFloat) {
        browserWidth = clampedWidth(width, available: available)
        // Use the same workspace layout entry as the previous native split. Never
        // save the animated zero width, so reopening restores the user's width.
        document.setPanelSizes([available - dividerWidth - browserWidth, browserWidth], for: .timelineColumns)
    }

    private func resizeHandle(width: CGFloat, available: CGFloat) -> some View {
        Color.clear
            .frame(width: dividerWidth)
            .overlay { Divider().allowsHitTesting(false) }
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: .trailing))
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let initial = dragStartWidth ?? width
                    dragStartWidth = initial
                    resize(to: initial - value.translation.width, available: available)
                }
                .onEnded { _ in dragStartWidth = nil })
            .accessibilityElement()
            .accessibilityLabel("Effects browser width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: resize(to: width + 20, available: available)
                case .decrement: resize(to: width - 20, available: available)
                @unknown default: break
                }
            }
    }
}
