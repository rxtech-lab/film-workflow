import SwiftUI
import VideoEditorCore

enum TimelineTrackFilterType: Hashable, Identifiable, Sendable {
    case kind(TrackKind)
    case element(String)
    case otherElement

    var id: Self { self }

    var accessibilitySuffix: String {
        switch self {
        case .kind(let kind): kind.rawValue
        case .element(let name): name
        case .otherElement: "other.element"
        }
    }

    @ViewBuilder var label: some View {
        switch self {
        case .kind(let kind): Label(kind.filterLabel, systemImage: kind.symbolName)
        case .element(let name): Text(verbatim: name)
        case .otherElement: Text("Other Elements")
        }
    }
}

struct TimelineTrackFilterSheet: View {
    let types: [TimelineTrackFilterType]
    let onApply: (Set<TimelineTrackFilterType>?) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Nil follows all types, including ones discovered while the sheet is open.
    @State private var selection: Set<TimelineTrackFilterType>?

    init(types: [TimelineTrackFilterType], selection: Set<TimelineTrackFilterType>?,
         onApply: @escaping (Set<TimelineTrackFilterType>?) -> Void) {
        self.types = types
        self.onApply = onApply
        _selection = State(initialValue: selection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Filter Timeline").font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(types) { type in
                        Toggle(isOn: includes(type)) { type.label }
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("timeline.filter.type.\(type.accessibilitySuffix)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)

            HStack {
                Button("Select All") { selection = nil }
                    .accessibilityIdentifier("timeline.filter.show-all")
                Button("Clear All") { selection = [] }
                    .accessibilityIdentifier("timeline.filter.clear-all")
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    onApply(selection.flatMap { Set(types).isSubset(of: $0) ? nil : $0 })
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("timeline.filter.apply")
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func includes(_ type: TimelineTrackFilterType) -> Binding<Bool> {
        Binding(
            get: { selection?.contains(type) ?? true },
            set: { isSelected in
                var updated = selection ?? Set(types)
                if isSelected { updated.insert(type) } else { updated.remove(type) }
                selection = updated
            }
        )
    }
}

extension TrackKind {
    var filterLabel: LocalizedStringKey {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .overlay: "Overlay"
        case .caption: "Caption"
        case .zoom: "Zoom"
        }
    }
}
