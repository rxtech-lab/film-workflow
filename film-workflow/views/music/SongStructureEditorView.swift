import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxX = max(maxX, currentX - spacing)
        }

        return (CGSize(width: maxX, height: currentY + lineHeight), positions)
    }
}

struct SongStructureEditorView: View {
    @Binding var entries: [SongStructureEntry]
    var duration: TimeInterval = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Song Structure")
                .font(.headline)

            FlowLayout(spacing: 8) {
                ForEach(SongSectionType.allCases) { type in
                    Button {
                        addEntry(type: type)
                    } label: {
                        Label {
                            Text("+ \(Text(type.localizedName))")
                        } icon: {
                            Image(systemName: iconForType(type))
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            if entries.isEmpty {
                ContentUnavailableView(
                    "No Sections",
                    systemImage: "music.note.list",
                    description: Text("Add sections above to define your song structure.")
                )
                .frame(maxWidth: .infinity)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach($entries) { $entry in
                        let targetID = entry.id
                        let currentIndex = entries.firstIndex { $0.id == targetID } ?? 0
                        let canMoveUp = currentIndex > 0
                        let canMoveDown = currentIndex < entries.count - 1
                        SongStructureEntryRow(
                            entry: $entry,
                            duration: duration,
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

    private func addEntry(type: SongSectionType) {
        let lastEnd = entries.last?.endTime ?? 0
        let entry = SongStructureEntry(
            type: type,
            startTime: lastEnd,
            endTime: lastEnd + 20,
            intensity: 0.5,
            description: ""
        )
        withAnimation {
            entries.append(entry)
        }
    }

    private func iconForType(_ type: SongSectionType) -> String {
        switch type {
        case .intro: return "arrow.right.circle"
        case .verse: return "text.alignleft"
        case .chorus: return "music.mic"
        case .bridge: return "arrow.triangle.branch"
        case .outro: return "arrow.left.circle"
        case .build: return "chart.line.uptrend.xyaxis"
        }
    }
}

struct SongStructureEntryRow: View {
    @Binding var entry: SongStructureEntry
    var duration: TimeInterval
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
                Image(systemName: "music.note")
                Text(entry.type.rawValue)
                    .font(.subheadline)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(colorForType(entry.type).opacity(0.2))
            .foregroundStyle(colorForType(entry.type))
            .clipShape(Capsule())

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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                #if os(iOS)
                TimeRangeButton(
                    startTime: $entry.startTime,
                    endTime: $entry.endTime,
                    duration: duration
                )
                #else
                TimeField(time: $entry.startTime)
                Text("–")
                    .foregroundStyle(.secondary)
                TimeField(time: $entry.endTime)
                #endif
                Spacer()
            }

            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Slider(value: $entry.intensity, in: 0 ... 1)
                Text(entry.intensityLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }

            TextEditor(text: $entry.description)
                .font(.body)
                .frame(minHeight: 60)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.platformControlBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func colorForType(_ type: SongSectionType) -> Color {
        switch type {
        case .intro: return .blue
        case .verse: return .green
        case .chorus: return .orange
        case .bridge: return .purple
        case .outro: return .red
        case .build: return .yellow
        }
    }
}

#Preview("Song Structure Editor") {
    @Previewable @State var entries = [
        SongStructureEntry(
            type: .intro,
            startTime: 0,
            endTime: 20,
            intensity: 0.3,
            description: "Soft intro with piano"
        ),
        SongStructureEntry(
            type: .verse,
            startTime: 20,
            endTime: 50,
            intensity: 0.5,
            description: "First verse"
        ),
        SongStructureEntry(
            type: .chorus,
            startTime: 50,
            endTime: 80,
            intensity: 0.8,
            description: "Main chorus with full instrumentation"
        )
    ]

    SongStructureEditorView(entries: $entries, duration: 180)
        .frame(width: 500, height: 600)
}

#Preview("Song Structure Entry Row") {
    @Previewable @State var entry = SongStructureEntry(
        type: .chorus,
        startTime: 60,
        endTime: 90,
        intensity: 0.7,
        description: "Main chorus with full instrumentation"
    )

    Form {
        SongStructureEntryRow(entry: $entry, duration: 180) {
            print("Delete tapped")
        }
    }
    .frame(width: 400, height: 200)
}
