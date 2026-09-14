import SwiftUI

/// `Stack`, `VStack`, `HStack` and `Section`.
struct JSONRenderStack: View {
    let element: JSONRenderElement
    let children: [JSONRenderNode]
    let context: JSONRenderContext

    private var isHorizontal: Bool {
        if element.type == "HStack" { return true }
        if element.type == "VStack" { return false }
        return context.resolver.string(element.prop("direction"))?.lowercased() == "horizontal"
    }

    private var spacing: CGFloat {
        context.resolver.cgFloat(element.prop("spacing")) ?? 12
    }

    private var title: String? { context.resolver.string(element.prop("title")) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            if isHorizontal {
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(Array(children.enumerated()), id: \.offset) { $1 }
                }
            } else {
                VStack(alignment: .leading, spacing: spacing) {
                    ForEach(Array(children.enumerated()), id: \.offset) { $1 }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A fixed-column grid. Columns default to two, which is what an option page
/// of media cards wants.
struct JSONRenderGrid: View {
    let element: JSONRenderElement
    let children: [JSONRenderNode]
    let context: JSONRenderContext

    private var columns: Int {
        max(1, min(6, context.resolver.integer(element.prop("columns")) ?? 2))
    }

    private var spacing: CGFloat {
        context.resolver.cgFloat(element.prop("spacing")) ?? 12
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
            alignment: .leading,
            spacing: spacing
        ) {
            ForEach(Array(children.enumerated()), id: \.offset) { $1 }
        }
    }
}

/// A titled container.
struct JSONRenderCard: View {
    let element: JSONRenderElement
    let children: [JSONRenderNode]
    let context: JSONRenderContext

    private var title: String? { context.resolver.string(element.prop("title")) }
    private var subtitle: String? { context.resolver.string(element.prop("subtitle")) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: 3) {
                    if let title {
                        Text(title).font(.system(size: 15, weight: .semibold))
                    }
                    if let subtitle {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(Array(children.enumerated()), id: \.offset) { $1 }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06))
        }
    }
}

/// `Heading`, `Text` and `Caption`.
struct JSONRenderText: View {
    let element: JSONRenderElement
    let context: JSONRenderContext

    private var text: String {
        context.resolver.string(element.prop("text"))
            ?? context.resolver.string(element.prop("value"))
            ?? ""
    }

    private var font: Font {
        if element.type == "Caption" { return .system(size: 11) }
        if element.type == "Text" { return .system(size: 13) }
        return switch context.resolver.integer(element.prop("level")) ?? 2 {
        case ...1: .system(size: 22, weight: .bold)
        case 2: .system(size: 17, weight: .semibold)
        default: .system(size: 14, weight: .semibold)
        }
    }

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(font)
                .foregroundStyle(element.type == "Caption" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A remote URL, or anything the host can resolve through the image provider
/// (a source id, a package-relative path).
struct JSONRenderImageView: View {
    let element: JSONRenderElement
    let context: JSONRenderContext

    private var source: String? {
        context.resolver.string(element.prop("url"))
            ?? context.resolver.string(element.prop("src"))
            ?? context.resolver.string(element.prop("source"))
    }

    private var height: CGFloat {
        context.resolver.cgFloat(element.prop("height")) ?? 120
    }

    var body: some View {
        JSONRenderImageContent(source: source, height: height, provider: context.imageProvider)
    }
}

struct JSONRenderImageContent: View {
    let source: String?
    let height: CGFloat
    let provider: JSONRenderImageProvider?

    var body: some View {
        Group {
            if let source, let url = URL(string: source), url.scheme == "http" || url.scheme == "https" {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                    case .failure: placeholder
                    default: ProgressView().controlSize(.small)
                    }
                }
            } else if let source, let image = provider?(source) {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var placeholder: some View {
        ZStack {
            Color.primary.opacity(0.06)
            Image(systemName: "photo")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.tertiary)
        }
    }
}
