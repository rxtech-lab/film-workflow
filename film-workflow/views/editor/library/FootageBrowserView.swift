import AppKit
import SwiftUI
import VideoEditorCore
import VideoEditorUI

/// The outputs of the selected project as a grid of draggable cells. Clicking
/// a cell shows it in the viewer; dragging one places it on the timeline.
struct FootageBrowserView: View {
    let title: String
    let cells: [FootageCell]
    let selectedID: UUID?
    let onSelect: (FootageCell) -> Void

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
                            FootageCellView(cell: cell, isSelected: cell.id == selectedID, onSelect: { onSelect(cell) })
                        }
                    }
                    .padding(4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FootageCellView: View {
    let cell: FootageCell
    var isSelected = false
    var onSelect: () -> Void = {}

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
            .background(isSelected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            // Select on press, not on release: a drag source swallows taps
            // unless the mouse stays perfectly still, and a press is what a
            // drag begins with anyway.
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in onSelect() })
            .timelineDraggable(dragItem, thumbnailURL: cell.thumbnailURL)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let url = cell.thumbnailURL, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: icon).font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .bottomTrailing) {
                if let duration {
                    Text(DurationLabel.short(duration))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
                        .padding(3)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            }
            Text(cell.title).font(.caption).lineLimit(1)
            Text(cell.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .help("Click to preview, drag onto the timeline")
        .task(id: cell.id) {
            guard cell.duration == nil, cell.kind == .audio || cell.kind == .video, let url = cell.mediaURL else { return }
            loadedDuration = await MediaDurationCache.duration(of: url)
        }
    }

    private var icon: String { cell.kind.symbolName }
}
