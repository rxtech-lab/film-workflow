import SwiftUI

struct LyricsEditorView: View {
    @Binding var entries: [LyricEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lyrics")
                .font(.headline)

            Button {
                addEntry()
            } label: {
                Label("Add Lyric Section", systemImage: "plus")
            }
            .buttonStyle(.bordered)

            if entries.isEmpty {
                ContentUnavailableView(
                    "No Lyrics",
                    systemImage: "text.quote",
                    description: Text("Add lyric sections to include lyrics in your song.")
                )
            } else {
                LazyVStack(spacing: 12) {
                    ForEach($entries) { $entry in
                        LyricEntryRow(
                            entry: $entry,
                            onDelete: {
                                withAnimation {
                                    entries.removeAll { $0.id == entry.id }
                                }
                            }
                        )
                    }
                    .onMove { from, to in
                        entries.move(fromOffsets: from, toOffset: to)
                    }
                }
            }
        }
    }

    private func addEntry() {
        let lastTimestamp = entries.last?.timestamp ?? 0
        let entry = LyricEntry(
            timestamp: lastTimestamp,
            content: ""
        )
        withAnimation {
            entries.append(entry)
        }
    }
}

struct LyricEntryRow: View {
    @Binding var entry: LyricEntry
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()

            bodyRow
                .padding(16)
        }
        .background(Color.platformControlBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var headerRow: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                TimeField(time: $entry.timestamp)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.platformControlBackground)
            .clipShape(Capsule())
            .foregroundStyle(.primary)

            Spacer()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }

    private var bodyRow: some View {
        TextEditor(text: $entry.content)
            .font(.body)
            .frame(minHeight: 80)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Color.platformControlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
