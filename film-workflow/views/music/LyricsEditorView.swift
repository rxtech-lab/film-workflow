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
                        let targetID = entry.id
                        let currentIndex = entries.firstIndex { $0.id == targetID } ?? 0
                        let canMoveUp = currentIndex > 0
                        let canMoveDown = currentIndex < entries.count - 1
                        LyricEntryRow(
                            entry: $entry,
                            onDelete: {
                                withAnimation {
                                    entries.removeAll { $0.id == targetID }
                                }
                            },
                            onMoveUp: canMoveUp ? {
                                guard let from = entries.firstIndex(where: { $0.id == targetID }),
                                      from > 0 else { return }
                                withAnimation {
                                    entries.move(
                                        fromOffsets: IndexSet(integer: from),
                                        toOffset: from - 1
                                    )
                                }
                            } : nil,
                            onMoveDown: canMoveDown ? {
                                guard let from = entries.firstIndex(where: { $0.id == targetID }),
                                      from < entries.count - 1 else { return }
                                withAnimation {
                                    entries.move(
                                        fromOffsets: IndexSet(integer: from),
                                        toOffset: from + 2
                                    )
                                }
                            } : nil
                        )
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
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil

    @State private var moveTrigger = 0

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
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: moveTrigger)
        #endif
    }

    private var headerRow: some View {
        HStack {
            #if os(iOS)
            Menu {
                Button {
                    moveTrigger += 1
                    onMoveUp?()
                } label: {
                    Label("Move Up", systemImage: "arrow.up")
                }
                .disabled(onMoveUp == nil)

                Button {
                    moveTrigger += 1
                    onMoveDown?()
                } label: {
                    Label("Move Down", systemImage: "arrow.down")
                }
                .disabled(onMoveDown == nil)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Reorder")
            #endif

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

            #if os(macOS)
            Button {
                onMoveUp?()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(onMoveUp == nil)
            .help("Move up")

            Button {
                onMoveDown?()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(onMoveDown == nil)
            .help("Move down")
            #endif

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
