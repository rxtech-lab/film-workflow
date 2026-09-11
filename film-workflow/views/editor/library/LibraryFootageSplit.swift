import SwiftUI

/// The library grid above the selected item's footage. Both children keep
/// their identity while the footage pane folds down to its header, so the
/// grid's scroll position and the pane's thumbnails survive a toggle.
struct LibraryFootageSplit<Content: View, Footage: View>: View {
    let document: ProjectDocument
    let footageVisible: Bool
    let content: Content
    let footage: Footage

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var footageHeight: CGFloat
    @State private var dragStartHeight: CGFloat?

    static var dividerHeight: CGFloat { 6 }
    static var collapsedHeight: CGFloat { FootageBrowserView.headerHeight + dividerHeight }
    private let minContentHeight: CGFloat = 180
    private let minFootageHeight: CGFloat = 150

    init(document: ProjectDocument, footageVisible: Bool,
         @ViewBuilder content: () -> Content, @ViewBuilder footage: () -> Footage) {
        self.document = document
        self.footageVisible = footageVisible
        self.content = content()
        self.footage = footage()
        _footageHeight = State(initialValue: document.panelLayout.sizes(for: .libraryRows)?.last ?? 200)
    }

    var body: some View {
        GeometryReader { geometry in
            let height = clampedHeight(footageHeight, available: geometry.size.height)
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Animate the surrounding layout, not the cards inside the grid.
                    .transaction { $0.animation = nil }
                VStack(spacing: 0) {
                    resizeHandle(height: height, available: geometry.size.height)
                        .allowsHitTesting(footageVisible)
                    footage.frame(width: geometry.size.width, height: height)
                }
                // The pane keeps its full height while only its header stays in view.
                .frame(height: footageVisible ? height + Self.dividerHeight : Self.collapsedHeight, alignment: .top)
                .clipped()
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: footageVisible)
        }
    }

    private func clampedHeight(_ height: CGFloat, available: CGFloat) -> CGFloat {
        min(max(minFootageHeight, height), max(minFootageHeight, available - minContentHeight - Self.dividerHeight))
    }

    private func resize(to height: CGFloat, available: CGFloat) {
        footageHeight = clampedHeight(height, available: available)
        // Use the same workspace layout entry as the previous native split. Never
        // save the collapsed height, so reopening restores the user's height.
        document.setPanelSizes([available - Self.dividerHeight - footageHeight, footageHeight], for: .libraryRows)
    }

    private func resizeHandle(height: CGFloat, available: CGFloat) -> some View {
        Color.clear
            .frame(height: Self.dividerHeight)
            .overlay { Divider().allowsHitTesting(false) }
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: .top))
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let initial = dragStartHeight ?? height
                    dragStartHeight = initial
                    resize(to: initial - value.translation.height, available: available)
                }
                .onEnded { _ in dragStartHeight = nil })
            .accessibilityElement()
            .accessibilityLabel("Footage pane height")
            .accessibilityValue("\(Int(height)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: resize(to: height + 20, available: available)
                case .decrement: resize(to: height - 20, available: available)
                @unknown default: break
                }
            }
    }
}
