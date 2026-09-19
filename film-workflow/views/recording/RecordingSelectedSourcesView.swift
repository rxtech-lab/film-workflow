import SwiftUI

/// The same source list stays visible from selection through recording.
struct RecordingSelectedSourcesView: View {
    let sources: [RecordingSource]
    let width: CGFloat
    var recording = false
    var paused = false
    var remove: ((String) -> Void)?

    static func selections(settings: RecordingSettings, catalog: RecordingSources) -> [RecordingSource] {
        let available: [RecordingSource]
        switch settings.sourceKind {
        case .window: available = catalog.windows
        case .display, .area: available = catalog.displays
        case .device: available = catalog.deviceScreens
        }
        return settings.captureSourceIDs.filter { !$0.isEmpty }.map { id in
            var source = available.first { $0.id == id } ?? RecordingSource(id: id, name: "Unavailable \(settings.sourceKind.rawValue) (\(id))", kind: settings.sourceKind.rawValue)
            if settings.sourceKind == .area { source.name = "Area · \(source.name)" }
            return source
        }
    }
    static func columns(width: CGFloat) -> Int { max(1, Int((width + 6) / 260)) }
    static func height(count: Int, width: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let rows = (count + columns(width: width) - 1) / columns(width: width)
        return 24 + min(194, CGFloat(rows * 40 - 6))
    }

    var body: some View {
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(recording ? (paused ? "Paused" : "Recording") : "Selected Sources") · \(sources.count)")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                ScrollView(.vertical) {
                    let columns = Self.columns(width: width)
                    VStack(spacing: 6) {
                        ForEach(0..<((sources.count + columns - 1) / columns), id: \.self) { row in
                            HStack(spacing: 6) {
                                ForEach(Array(sources.dropFirst(row * columns).prefix(columns))) { source in
                                    sourceCell(source)
                                }
                                ForEach(0..<max(0, columns - min(columns, sources.count - row * columns)), id: \.self) { _ in
                                    Color.clear.frame(maxWidth: .infinity).frame(height: 34)
                                }
                            }
                        }
                    }.padding(.trailing, 4)
                }
            }.frame(height: Self.height(count: sources.count, width: width))
        }
    }

    private func sourceCell(_ source: RecordingSource) -> some View {
        HStack(spacing: 7) {
            Image(systemName: recording ? (paused ? "pause.circle.fill" : "record.circle.fill") : "checkmark.circle.fill")
                .foregroundStyle(recording ? (paused ? Color.orange : .red) : .accentColor)
                .accessibilityHidden(true)
            Text(source.name).font(.callout).lineLimit(1).truncationMode(.middle)
                .help(source.name).accessibilityIdentifier("recording.selectedSource.\(source.id)")
            Spacer(minLength: 0)
            if let remove {
                Button { remove(source.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Deselect \(source.name)")
                    .accessibilityIdentifier("recording.deselectSource.\(source.id)")
            }
        }
        .padding(.horizontal, 9).frame(maxWidth: .infinity).frame(height: 34)
        .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 8))
    }
}
