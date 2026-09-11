import AppKit
import SwiftUI
import VideoEditorCore
import VideoEditorUI

/// The outputs of the selected project as a grid of draggable cells. Clicking
/// a cell shows it in the viewer; dragging one places it on the timeline.
/// Moving the pointer across a cell plays that take in the viewer, the way
/// the timeline previews the frame under the pointer when Skim is on.
struct FootageBrowserView: View {
    let libraryItem: LibraryItemID?
    let title: String
    let cells: [FootageCell]
    let selectedID: UUID?
    let onSelect: (FootageCell) -> Void
    let onDeselect: () -> Void
    /// The cell under the pointer and how far across it the pointer is
    /// (0...1), or nil once the pointer leaves the cell.
    var player: FootagePlayer?
    var onSkim: (FootageCell, Double?) -> Void = { _, _ in }

    var onSeek: (FootageCell, Double) -> Void = { _, _ in }
    /// Collapsed, only the header row stays in view; the split above keeps
    /// the pane's height so expanding returns it to where it was.
    var isExpanded = true
    var onToggle: () -> Void = {}

    /// The header's fixed height, which is all that remains of a collapsed pane.
    static let headerHeight: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            header
            if cells.isEmpty {
                StudioEmptyState(title: "No footage yet", symbol: "rectangle.stack",
                                 message: "Import media or generate footage, then drag it to the timeline.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(cells) { cell in
                            FootageCellView(cell: cell, libraryItem: libraryItem, isSelected: cell.id == selectedID,
                                            onSelect: { onSelect(cell) }, onSkim: { onSkim(cell, $0) },
                                            player: player, onSeek: { onSeek(cell, $0) })
                        }
                    }
                    .padding(4)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onDeselect)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text("\(cells.count)").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.headerHeight)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse footage" : "Expand footage")
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("toggle-footage-browser")
    }
}

struct FootageCellView: View {
    let cell: FootageCell
    let libraryItem: LibraryItemID?
    var isSelected = false
    var onSelect: () -> Void = {}
    var onSkim: (Double?) -> Void = { _ in }

    var player: FootagePlayer?
    var onSeek: (Double) -> Void = { _ in }

    @State private var loadedDuration: TimeInterval?
    private var duration: TimeInterval? { cell.duration ?? loadedDuration }

    /// The payload carries the length once it is known, so the timeline can
    /// draw the clip at its true size while it is still being dragged.
    private var dragItem: FootageDragItem {
        var item = cell.drag
        if item.duration == nil, let duration { item.duration = duration }
        return item
    }

    var body: some View {
        content
            .padding(4)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            // Select on press, not on release: a drag source swallows taps
            // unless the mouse stays perfectly still, and a press is what a
            // drag begins with anyway.
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in onSelect() })
            .timelineDraggable(dragItem, thumbnailURL: cell.thumbnailURL) { provider in
                if let libraryItem { provider.register(LibraryDragToken(item: libraryItem)) }
            }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            FootageFilmstrip(cell: cell, duration: duration, isSelected: isSelected,
                             player: player, onSkim: onSkim, onSeek: onSeek)
            Text(cell.title).font(.caption).lineLimit(1)
            Text(cell.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .help("Click to preview, drag onto the timeline or into a library group")
        .task(id: cell) {
            loadedDuration = nil
            guard cell.duration == nil, cell.kind == .audio || cell.kind == .video, let url = cell.mediaURL else { return }
            let result = await MediaDurationCache.duration(of: url)
            guard !Task.isCancelled else { return }
            loadedDuration = result
        }
    }

}
