import SwiftUI

/// One choice in an `OptionGroup` or `Chips`.
struct JSONRenderOption: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let detail: String?
    let badge: String?
    let image: String?

    /// Options are written either as objects or, for short lists, as bare
    /// strings. A bare string is its own id and title.
    static func list(from value: JSONRenderValue?, resolver: JSONRenderResolver) -> [JSONRenderOption] {
        resolver.array(value).enumerated().compactMap { index, entry in
            if case .string(let plain) = entry {
                return JSONRenderOption(
                    id: plain, title: plain, subtitle: nil, detail: nil, badge: nil, image: nil
                )
            }
            guard let object = entry.object else { return nil }
            let id = resolver.string(object["id"] ?? object["value"])
                ?? resolver.string(object["title"])
                ?? String(index)
            return JSONRenderOption(
                id: id,
                title: resolver.string(object["title"] ?? object["label"]) ?? id,
                subtitle: resolver.string(object["subtitle"]),
                detail: resolver.string(object["detail"] ?? object["description"]),
                badge: resolver.string(object["badge"]),
                image: resolver.string(object["imageUrl"] ?? object["image"] ?? object["thumbnail"])
            )
        }
    }
}

/// Selectable cards, single or multiple choice, bound to one state path.
struct JSONRenderOptionGroup: View {
    let element: JSONRenderElement
    let context: JSONRenderContext

    private var options: [JSONRenderOption] {
        JSONRenderOption.list(from: element.prop("options"), resolver: context.resolver)
    }

    private var allowsMultiple: Bool {
        context.resolver.bool(element.prop("multiple"))
            ?? context.resolver.bool(element.prop("multiSelect"))
            ?? false
    }

    private var path: String? {
        JSONRenderResolver.bindPath(element.prop("value"))
            ?? JSONRenderResolver.bindPath(element.prop("statePath"))
            ?? element.prop("statePath")?.string
    }

    private var maximumColumns: Int {
        max(1, min(4, context.resolver.integer(element.prop("columns")) ?? 4))
    }

    private var label: String? { context.resolver.string(element.prop("label")) }

    private var selection: Set<String> {
        guard let path, let value = context.state.value(at: path) else { return [] }
        if let array = value.array {
            return Set(array.compactMap(\.string))
        }
        return value.string.map { [$0] } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label {
                Text(label).font(.system(size: 13, weight: .semibold))
            }
            OptionCardLayout(maximumColumns: maximumColumns) {
                ForEach(options) { option in
                    JSONRenderOptionCard(
                        option: option,
                        isSelected: selection.contains(option.id),
                        provider: context.imageProvider
                    ) {
                        toggle(option.id)
                    }
                }
            }
            if options.isEmpty {
                JSONRenderPlaceholder(text: "No options were provided")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ id: String) {
        guard let path else { return }
        if allowsMultiple {
            var current = selection
            if current.contains(id) { current.remove(id) } else { current.insert(id) }
            // Keep the author's order rather than the set's, so the value the
            // agent reads back matches the order it listed the options in.
            let ordered = options.map(\.id).filter { current.contains($0) }
            context.state.set(.array(ordered.map { .string($0) }), at: path)
        } else {
            context.state.set(.string(id), at: path)
        }
    }
}

/// Wraps cards to fit the available width and gives every row the same height.
private struct OptionCardLayout: Layout {
    let maximumColumns: Int
    private let minimumCardWidth: CGFloat = 220
    private let spacing: CGFloat = 10

    init(maximumColumns: Int) {
        self.maximumColumns = maximumColumns
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let metrics = metrics(for: proposal.width, subviews: subviews)
        return CGSize(width: metrics.width, height: metrics.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let metrics = metrics(for: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let column = index % metrics.columns
            let row = index / metrics.columns
            subview.place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(column) * (metrics.cardWidth + spacing),
                    y: bounds.minY + CGFloat(row) * (metrics.cardHeight + spacing)
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: metrics.cardWidth, height: metrics.cardHeight)
            )
        }
    }

    private struct Metrics {
        let width: CGFloat
        let height: CGFloat
        let columns: Int
        let cardWidth: CGFloat
        let cardHeight: CGFloat
    }

    private func metrics(for proposedWidth: CGFloat?, subviews: Subviews) -> Metrics {
        guard !subviews.isEmpty else {
            return Metrics(width: 0, height: 0, columns: 1, cardWidth: 0, cardHeight: 0)
        }
        let columnLimit = max(1, min(maximumColumns, subviews.count))
        let idealWidth = CGFloat(columnLimit) * minimumCardWidth + CGFloat(columnLimit - 1) * spacing
        let width = proposedWidth.flatMap { $0.isFinite ? max(0, $0) : nil } ?? idealWidth
        let columns = min(columnLimit, max(1, Int((width + spacing) / (minimumCardWidth + spacing))))
        let cardWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        // Measure all content at its wrapped width before assigning a shared height.
        let cardHeight = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: cardWidth, height: nil)).height
        }.max() ?? 0
        let rows = (subviews.count + columns - 1) / columns
        return Metrics(
            width: width,
            height: CGFloat(rows) * cardHeight + CGFloat(rows - 1) * spacing,
            columns: columns,
            cardWidth: cardWidth,
            cardHeight: cardHeight
        )
    }
}

struct JSONRenderOptionCard: View {
    let option: JSONRenderOption
    let isSelected: Bool
    let provider: JSONRenderImageProvider?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                if option.image != nil {
                    JSONRenderImageContent(source: option.image, height: 96, provider: provider)
                }
                HStack(alignment: .top, spacing: 8) {
                    Text(option.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                        .fixedSize()
                }
                if let badge = option.badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                }
                if let subtitle = option.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail = option.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.leading)
            // Fill the common height proposed by OptionCardLayout.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
            .background(
                (isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(isHovered ? 0.06 : 0.03)),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.07))
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("json-render.option.\(option.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct JSONRenderToggle: View {
    let element: JSONRenderElement
    let context: JSONRenderContext

    private var label: String {
        context.resolver.string(element.prop("label"))
            ?? context.resolver.string(element.prop("title"))
            ?? ""
    }

    private var path: String? {
        JSONRenderResolver.bindPath(element.prop("value"))
            ?? JSONRenderResolver.bindPath(element.prop("checked"))
            ?? element.prop("statePath")?.string
    }

    var body: some View {
        if let path {
            Toggle(isOn: Binding(
                get: { context.state.value(at: path)?.bool ?? false },
                set: { context.state.set(.bool($0), at: path) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 13))
                    if let detail = context.resolver.string(element.prop("detail")) {
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("json-render.toggle")
        } else {
            JSONRenderPlaceholder(text: "Toggle without a state binding")
        }
    }
}

/// A compact multi-select of short labels.
struct JSONRenderChips: View {
    let element: JSONRenderElement
    let context: JSONRenderContext

    private var options: [JSONRenderOption] {
        JSONRenderOption.list(from: element.prop("options"), resolver: context.resolver)
    }

    private var path: String? {
        JSONRenderResolver.bindPath(element.prop("value")) ?? element.prop("statePath")?.string
    }

    private var selection: Set<String> {
        guard let path, let value = context.state.value(at: path) else { return [] }
        if let array = value.array { return Set(array.compactMap(\.string)) }
        return value.string.map { [$0] } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label = context.resolver.string(element.prop("label")) {
                Text(label).font(.system(size: 13, weight: .semibold))
            }
            FlowLayout(spacing: 6) {
                ForEach(options) { option in
                    let selected = selection.contains(option.id)
                    Button {
                        guard let path else { return }
                        var current = selection
                        if selected { current.remove(option.id) } else { current.insert(option.id) }
                        let ordered = options.map(\.id).filter { current.contains($0) }
                        context.state.set(.array(ordered.map { .string($0) }), at: path)
                    } label: {
                        Text(option.title)
                            .font(.system(size: 12))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05),
                                in: Capsule()
                            )
                            .overlay {
                                Capsule().strokeBorder(
                                    selected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08)
                                )
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct JSONRenderTextField: View {
    let element: JSONRenderElement
    let context: JSONRenderContext

    private var path: String? {
        JSONRenderResolver.bindPath(element.prop("value")) ?? element.prop("statePath")?.string
    }

    var body: some View {
        if let path {
            VStack(alignment: .leading, spacing: 4) {
                if let label = context.resolver.string(element.prop("label")) {
                    Text(label).font(.system(size: 13, weight: .semibold))
                }
                TextField(
                    context.resolver.string(element.prop("placeholder")) ?? "",
                    text: Binding(
                        get: { context.state.value(at: path)?.string ?? "" },
                        set: { context.state.set(.string($0), at: path) }
                    ),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            }
        } else {
            JSONRenderPlaceholder(text: "Text field without a state binding")
        }
    }
}

/// Wraps chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for row in layout(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
