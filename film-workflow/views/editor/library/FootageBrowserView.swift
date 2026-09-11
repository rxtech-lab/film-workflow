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
    var onSkim: (FootageCell, Double?) -> Void = { _, _ in }

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(cells.count)").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()
            if cells.isEmpty {
                StudioEmptyState(title: "No footage yet", symbol: "rectangle.stack",
                                 message: "Import media or generate footage, then drag it to the timeline.")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(cells) { cell in
                            FootageCellView(cell: cell, libraryItem: libraryItem, isSelected: cell.id == selectedID,
                                            onSelect: { onSelect(cell) }, onSkim: { onSkim(cell, $0) })
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
}

struct FootageCellView: View {
    let cell: FootageCell
    let libraryItem: LibraryItemID?
    var isSelected = false
    var onSelect: () -> Void = {}
    var onSkim: (Double?) -> Void = { _ in }

    @State private var loadedDuration: TimeInterval?
    /// Where the pointer is across the poster, in points, while it is over it.
    @State private var skimX: CGFloat?

    private var duration: TimeInterval? { cell.duration ?? loadedDuration }

    /// Stills and captions have nothing to skim through; unrendered takes
    /// have no file to play.
    private var skimmable: Bool {
        (cell.kind == .video || cell.kind == .audio) && cell.mediaURL != nil
    }

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
            .background(isSelected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .onChange(of: skimmable) { _, on in if !on { skimX = nil } }
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
            FootageThumbnail(thumbnailURL: cell.thumbnailURL,
                             videoURL: cell.kind == .video ? cell.mediaURL : nil,
                             icon: cell.kind.symbolName, duration: duration,
                             isStill: cell.kind == .image, isSelected: isSelected)
                .overlay { if skimmable { skimmer } }
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

    /// Tracks the pointer across the poster and marks where it is. A drag
    /// already carries the take somewhere; skimming then would fight it.
    private var skimmer: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Color.clear
                if let skimX {
                    Rectangle()
                        .fill(.white)
                        .frame(width: 1)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .offset(x: skimX)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    guard FootageDragSession.shared.item == nil else { return }
                    let width = max(1, geometry.size.width)
                    let x = min(max(0, point.x), width)
                    skimX = x
                    onSkim(x / width)
                case .ended:
                    skimX = nil
                    onSkim(nil)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }
}
