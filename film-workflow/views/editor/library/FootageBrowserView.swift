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

    /// Authoring is admin-only. `LibraryPanel` refreshes the flag; observing
    /// it here rebuilds the menus once it lands.
    @State private var authoring = MarketplaceAuthoringService.shared
    @State private var authoringSeed: MarketplaceAuthoringSeed?

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
                    FootageFlowLayout {
                        ForEach(cells) { cell in
                            FootageCellView(cell: cell, libraryItem: libraryItem, isSelected: cell.id == selectedID,
                                            onSelect: { onSelect(cell) }, onSkim: { onSkim(cell, $0) },
                                            player: player, onSeek: { onSeek(cell, $0) },
                                            onCreateMarketplaceItem: seed(for: cell).map { seed in { authoringSeed = seed } })
                        }
                    }
                    .padding(4)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onDeselect)
                .accessibilityIdentifier("footage.versions")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $authoringSeed) { MarketplaceAuthoringEditor(seed: $0) }
    }

    /// The item's own name titles the draft; a take's own title is only "v3".
    private func seed(for cell: FootageCell) -> MarketplaceAuthoringSeed? {
        guard authoring.canAuthor else { return nil }
        return MarketplaceAuthoringSeed(title: title, sourceKind: cell.kind, file: cell.mediaURL)
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
                    .accessibilityIdentifier("footage.version-count")
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
    /// Nil hides the marketplace action, which is all that gates it.
    var onCreateMarketplaceItem: (() -> Void)?

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
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("footage.cell.\(cell.id.uuidString)")
            .contextMenu {
                if let onCreateMarketplaceItem {
                    Button(action: onCreateMarketplaceItem) {
                        Label("Create Marketplace Item…", systemImage: "storefront")
                    }
                    .help("Start a marketplace draft from this take, with its file attached")
                }
            }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            FootageFilmstrip(cell: cell, duration: duration, isSelected: isSelected,
                             player: player, onSkim: onSkim, onSeek: onSeek)
            Text(cell.title).font(.caption).lineLimit(1)
            Text(cell.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(minWidth: 0,
               idealWidth: ceil(FilmstripLayout.preferredWidth(duration: duration, isTemporal: cell.previewSource?.isTemporal == true)),
               maxWidth: .infinity, alignment: .leading)
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
