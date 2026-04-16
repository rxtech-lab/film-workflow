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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Song Structure")
                .font(.headline)

            FlowLayout(spacing: 8) {
                ForEach(SongSectionType.allCases) { type in
                    Button {
                        addEntry(type: type)
                    } label: {
                        Label("+ \(type.rawValue)", systemImage: iconForType(type))
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
                ScrollView(showsIndicators: false) {
                    ForEach($entries) { $entry in
                        SongStructureEntryRow(
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
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.type.rawValue)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(colorForType(entry.type).opacity(0.2))
                    .foregroundStyle(colorForType(entry.type))
                    .clipShape(Capsule())

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                    TimeField(time: $entry.startTime)
                    Text("–")
                        .foregroundStyle(.secondary)
                    TimeField(time: $entry.endTime)
                }

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
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
                .padding(4)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.vertical, 4)
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

    SongStructureEditorView(entries: $entries)
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
        SongStructureEntryRow(entry: $entry) {
            print("Delete tapped")
        }
    }
    .frame(width: 400, height: 200)
}
