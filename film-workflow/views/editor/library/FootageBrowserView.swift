import AppKit
import SwiftUI
import VideoEditorCore

/// The outputs of the selected project as a grid of draggable cells.
struct FootageBrowserView: View {
    let title: String
    let cells: [FootageCell]

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
                ContentUnavailableView {
                    Label("No Footage", systemImage: "rectangle.dashed")
                } description: {
                    Text("Generate something, or import a file, then drag it onto the timeline.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(cells) { cell in
                            FootageCellView(cell: cell)
                                .draggable(cell.drag)
                        }
                    }
                    .padding(8)
                }
            }
        }
    }
}

struct FootageCellView: View {
    let cell: FootageCell

    var body: some View {
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
            Text(cell.title).font(.caption).lineLimit(1)
            Text(cell.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .help("Drag onto the timeline")
    }

    private var icon: String {
        switch cell.kind {
        case .audio: return "waveform"
        case .video: return "film"
        case .image: return "photo"
        case .captions: return "captions.bubble"
        case .remotion: return "atom"
        }
    }
}
