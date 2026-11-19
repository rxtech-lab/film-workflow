import Foundation
import Observation
import SwiftUI
import VideoEditorCore

/// Fixed-height rows let both columns use the same window and keep the full scroll extent.
struct TimelineRowWindow: Equatable {
    private let rows: Range<Int>
    private let pinnedCapacity: Int

    init(offset: CGFloat, height: CGFloat, rulerHeight: CGFloat, rowHeight: CGFloat) {
        // Round out to groups of rows and keep an extra group on each side so
        // a scroll only changes the view hierarchy after crossing a group boundary.
        let batchSize = 4
        let top = max(0, offset) - rulerHeight
        let first = max(0, Int(floor(top / rowHeight)))
        let end = max(first, Int(ceil((top + height) / rowHeight)))
        let lower = max(0, (first / batchSize - 1) * batchSize)
        let upper = ((end + batchSize - 1) / batchSize + 1) * batchSize
        rows = lower..<upper
        pinnedCapacity = Int(ceil(height / rowHeight))
    }

    func indices(trackCount: Int, pinnedRows: [Int], activeRow: Int?, clipRowOffset: Int) -> [Int] {
        let bounds = 0..<trackCount
        var indices = Set(rows.clamped(to: bounds))
        // A pinned track can still be visible after scrolling past its layout position.
        indices.formUnion(pinnedRows.prefix(pinnedCapacity).prefix { $0 < rows.lowerBound })
        if let activeRow { indices.insert(activeRow) }
        if clipRowOffset != 0 {
            // Clips dragged to another lane are still hosted by their original rows.
            let sourceRows = (rows.lowerBound - clipRowOffset)..<(rows.upperBound - clipRowOffset)
            indices.formUnion(sourceRows.clamped(to: bounds))
        }
        return indices.sorted()
    }
}

/// Scroll updates are observed by the rows, pins and skimmer that use them.
/// Horizontal geometry is read on demand when anchoring a zoom.
@Observable
final class TimelineViewportState {
    @ObservationIgnored var horizontal = TimelineViewport()
    var rowWindow: TimelineRowWindow?
    var verticalOffset: CGFloat = 0
    var hoverTime: TimeInterval?

    func pinnedOffset(threshold: CGFloat) -> CGFloat {
        max(0, verticalOffset - threshold)
    }
}

struct TimelineTrackLayout {
    let tracks: [Track]
    let indicesByID: [UUID: Int]
    let trackIDs: Set<UUID>
    let pinnedRows: [Int]
    let pinSlots: [Int: Int]

    init(tracks: [Track]) {
        var indices: [UUID: Int] = [:]
        var pinned: [Int] = []
        var slots: [Int: Int] = [:]
        for (index, track) in tracks.enumerated() {
            indices[track.id] = index
            if track.isPinned {
                slots[index] = pinned.count
                pinned.append(index)
            }
        }
        self.tracks = tracks
        indicesByID = indices
        trackIDs = Set(indices.keys)
        pinnedRows = pinned
        pinSlots = slots
    }
}

struct TimelineTrackRows<Row: View>: View {
    let layout: TimelineTrackLayout
    let viewport: TimelineViewportState
    let initialWindow: TimelineRowWindow
    let width: CGFloat
    let rowHeight: CGFloat
    let activeTrackID: UUID?
    let reorderAnimation: Animation?
    var clipRowOffset = 0
    @ViewBuilder let row: (Track, Int) -> Row

    private struct PositionedTrack: Identifiable {
        var id: UUID { track.id }
        let track: Track
        let index: Int
    }

    var body: some View {
        let window = viewport.rowWindow ?? initialWindow
        let indices = window.indices(trackCount: layout.tracks.count, pinnedRows: layout.pinnedRows,
                                     activeRow: activeTrackID.flatMap { layout.indicesByID[$0] }, clipRowOffset: clipRowOffset)
        TimelineRowsLayout(width: width, rowHeight: rowHeight, rowCount: layout.tracks.count) {
            ForEach(indices.map { PositionedTrack(track: layout.tracks[$0], index: $0) }) { track in
                row(track.track, track.index)
                    .layoutValue(key: TimelineRowIndex.self, value: track.index)
            }
        }
        .animation(reorderAnimation, value: layout.indicesByID)
    }
}

nonisolated private struct TimelineRowIndex: LayoutValueKey {
    static let defaultValue = 0
}

/// Reserve the space for every row while laying out and hit-testing the mounted rows at their actual positions.
private struct TimelineRowsLayout: Layout {
    let width: CGFloat
    let rowHeight: CGFloat
    let rowCount: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: width, height: CGFloat(rowCount) * rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let y = bounds.minY + CGFloat(subview[TimelineRowIndex.self]) * rowHeight
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: rowHeight))
        }
    }
}

struct TimelineTrackRowPosition: ViewModifier {
    let viewport: TimelineViewportState
    let reorderOffset: CGFloat
    let pinThreshold: CGFloat?
    let isDragging: Bool
    let reorderAnimation: Animation?

    func body(content: Content) -> some View {
        let pinned = pinThreshold.map { viewport.pinnedOffset(threshold: $0) } ?? 0
        let floating = isDragging || pinned > 0
        content
            .background {
                // A row held over the translucent lanes needs an opaque background.
                if pinned > 0 { Rectangle().fill(Color(nsColor: .windowBackgroundColor)) }
            }
            .shadow(color: .black.opacity(floating ? 0.25 : 0), radius: floating ? 6 : 0, y: floating ? 3 : 0)
            .offset(y: reorderOffset)
            .animation(isDragging ? nil : reorderAnimation, value: reorderOffset)
            // Pinning follows the scroll position without interpolating it.
            .offset(y: pinned)
            .zIndex(isDragging ? 2 : (pinned > 0 ? 1 : 0))
    }
}
