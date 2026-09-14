import SwiftUI

/// Packs duration-sized cards in order, constraining long cards to the panel
/// so their filmstrips can continue on additional lines.
struct FootageFlowLayout: Layout {
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, result.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: frame.width, height: nil))
        }
    }

    private func arrange(width: CGFloat?, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let idealWidths = subviews.map { $0.sizeThatFits(.unspecified).width }
        let availableWidth = max(1, width.flatMap { $0.isFinite ? $0 : nil }
            ?? (idealWidths.reduce(0, +) + CGFloat(max(0, subviews.count - 1)) * spacing))
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for (subview, idealWidth) in zip(subviews, idealWidths) {
            let cardWidth = min(availableWidth, idealWidth)
            let size = subview.sizeThatFits(ProposedViewSize(width: cardWidth, height: nil))
            if x > 0 && x + cardWidth > availableWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: cardWidth, height: size.height))
            x += cardWidth + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: availableWidth, height: y + rowHeight), frames)
    }
}
