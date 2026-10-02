import SwiftUI
import VideoEditorCore

/// Scene id for the render queue window, shared by the scene declaration and
/// every `openWindow` call.
nonisolated enum RenderQueueWindowID {
    static let value = "render-queue"
}

/// Toolbar entry for background rendering: shows whether work is pending and
/// opens the queue window.
struct RenderQueueToolbarButton: View {
    @Environment(\.openWindow) private var openWindow
    private var queue: RenderQueue { .shared }

    var body: some View {
        Button {
            openWindow(id: RenderQueueWindowID.value)
        } label: {
            Label("Queue", systemImage: "square.stack.3d.up")
                .overlay(alignment: .topTrailing) {
                    if queue.activeCount > 0 || queue.hasFailures {
                        Circle()
                            .fill(queue.hasFailures ? Color.red : Color.accentColor)
                            .frame(width: 6, height: 6)
                            .offset(x: 3, y: -2)
                    }
                }
        }
        .help(queue.activeCount > 0 ? "Rendering \(queue.activeCount) item(s) in the background" : "Background rendering queue")
        .accessibilityIdentifier("toolbar.renderQueue")
    }
}

/// Queued and running background renders, each with a linear progress bar.
/// One app-wide window: the queue is shared by every open film.
struct RenderQueueWindowView: View {
    private var queue: RenderQueue { .shared }
    /// Debounced empty state: back-to-back renders briefly leave the queue
    /// empty, which would otherwise flicker between the list and the empty page.
    @State private var showsEmptyState = RenderQueue.shared.items.isEmpty

    var body: some View {
        NavigationStack {
            Group {
                if queue.items.isEmpty && showsEmptyState {
                    ContentUnavailableView("Nothing in the Queue", systemImage: "checkmark.circle",
                                           description: Text("Composition prerenders, thumbnails and waveforms appear here while they render."))
                } else {
                    List(queue.items) { item in
                        RenderQueueRow(item: item)
                    }
                    .animation(.default, value: queue.items.map(\.id))
                }
            }
            .task(id: queue.items.isEmpty) {
                guard queue.items.isEmpty else {
                    showsEmptyState = false
                    return
                }
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled { showsEmptyState = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Render Queue")
            .toolbar {
                if queue.hasFailures {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Clear Failed") { queue.clearFailures() }
                    }
                }
            }
        }
        .frame(minWidth: 300, maxWidth: 400, minHeight: 200, maxHeight: 300)
    }
}

private struct RenderQueueRow: View {
    let item: RenderQueue.Item

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.title.isEmpty ? item.kind.displayName : item.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(item.kind.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                switch item.state {
                case .queued:
                    ProgressView(value: 0).progressViewStyle(.linear)
                    Text("Waiting…").font(.caption).foregroundStyle(.secondary)
                case .running:
                    if let fraction = item.fraction {
                        ProgressView(value: fraction).progressViewStyle(.linear)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                case .finished:
                    ProgressView(value: 1).progressViewStyle(.linear).tint(.green)
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        let percent = item.fraction.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""
        return (item.detail ?? String(localized: "Rendering")) + percent
    }
}

private extension RenderQueue.Kind {
    var displayName: String {
        switch self {
        case .remotion: String(localized: "Composition")
        case .thumbnail: String(localized: "Thumbnail")
        case .waveform: String(localized: "Waveform")
        }
    }

    var systemImage: String {
        switch self {
        case .remotion: "curlybraces.square"
        case .thumbnail: "photo"
        case .waveform: "waveform"
        }
    }
}
