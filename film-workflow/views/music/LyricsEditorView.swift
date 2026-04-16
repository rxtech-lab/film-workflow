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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                TimeField(time: $entry.timestamp)

                Spacer()

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            }

            TextEditor(text: $entry.content)
                .font(.body)
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.vertical, 4)
    }
}
