import SwiftUI
import VideoEditorCore
import VideoEditorUI

/// A project's current output, with the same poster and timing as its footage.
struct LibraryItemCard: View {
    let row: LibraryRow
    let footage: FootageCell?
    let payload: FootageDragPayload?
    let isSelected: Bool

    @State private var loadedDuration: TimeInterval?

    private var duration: TimeInterval? { footage?.duration ?? loadedDuration }

    private var dragItem: FootageDragItem? {
        guard var item = payload?.item else { return nil }
        item.duration = item.duration ?? duration
        return item
    }

    @ViewBuilder
    var body: some View {
        if let item = dragItem {
            content.timelineDraggable(item, thumbnailURL: payload?.thumbnailURL) { provider in
                provider.register(LibraryDragToken(item: row.id))
            }
        } else {
            content.draggable(LibraryDragToken(item: row.id))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 5) {
            FootageThumbnail(
                thumbnailURL: footage?.thumbnailURL,
                videoURL: footage?.kind == .video ? footage?.mediaURL : nil,
                icon: footage?.kind.symbolName ?? row.id.kind.systemImage,
                duration: duration,
                isStill: footage?.kind == .image,
                isSelected: isSelected
            )
            .overlay(alignment: .topLeading) {
                if row.versions.count > 1 {
                    Label("\(row.versions.count)", systemImage: "square.stack")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                        .help("\(row.versions.count) versions")
                }
            }
            Text(row.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Label(row.id.kind.displayName, systemImage: row.id.kind.systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
        .accessibilityIdentifier("library.item.\(row.id.id.uuidString)")
        .help("\(row.name)\n\(row.subtitle)")
        .task(id: footage) {
            loadedDuration = nil
            guard let footage, footage.duration == nil,
                  footage.kind == .audio || footage.kind == .video,
                  let url = footage.mediaURL else { return }
            let result = await MediaDurationCache.duration(of: url)
            guard !Task.isCancelled else { return }
            loadedDuration = result
        }
    }
}
