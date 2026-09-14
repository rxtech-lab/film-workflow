import Foundation
import SwiftUI

/// Loads an image the spec referenced by something other than a URL — a
/// source id, a package-relative path — so the app can show the user's own
/// uploads on an option card without the renderer knowing what a film is.
public typealias JSONRenderImageProvider = @MainActor (String) -> Image?

/// Renders a json-render spec.
///
/// The catalog is closed on purpose: the agent is told which types exist, and
/// anything else draws a small placeholder instead of failing. Recursion is
/// bounded by a depth cap and a visited set, because a spec that names itself
/// as its own child would otherwise hang the window.
public struct JSONRenderView: View {
    public static let maxDepth = 24

    let spec: JSONRenderSpec
    let state: JSONRenderState
    let imageProvider: JSONRenderImageProvider?

    public init(
        spec: JSONRenderSpec,
        state: JSONRenderState,
        imageProvider: JSONRenderImageProvider? = nil
    ) {
        self.spec = spec
        self.state = state
        self.imageProvider = imageProvider
    }

    public var body: some View {
        JSONRenderNode(
            id: spec.root,
            context: JSONRenderContext(
                spec: spec,
                resolver: JSONRenderResolver(state: state),
                imageProvider: imageProvider
            ),
            depth: 0,
            ancestors: []
        )
    }
}

/// What every component needs: the spec to look up children, the resolver for
/// props, and the image loader.
struct JSONRenderContext {
    let spec: JSONRenderSpec
    let resolver: JSONRenderResolver
    let imageProvider: JSONRenderImageProvider?

    var state: JSONRenderState { resolver.state }
}

/// One element and its subtree.
struct JSONRenderNode: View {
    let id: String
    let context: JSONRenderContext
    let depth: Int
    let ancestors: Set<String>

    var body: some View {
        if let element = context.spec.element(id),
           depth < JSONRenderView.maxDepth,
           !ancestors.contains(id) {
            if context.resolver.evaluate(element.visible) {
                JSONRenderComponent(
                    element: element,
                    children: children(of: element),
                    context: context
                )
            }
        } else if context.spec.element(id) == nil {
            // A child id with no element: the agent named a section it never
            // wrote. Say so rather than leaving a gap the user cannot explain.
            JSONRenderPlaceholder(text: "Missing element \"\(id)\"")
        }
    }

    private func children(of element: JSONRenderElement) -> [JSONRenderNode] {
        element.children.map { child in
            JSONRenderNode(
                id: child,
                context: context,
                depth: depth + 1,
                ancestors: ancestors.union([id])
            )
        }
    }
}

/// Every element type the renderer draws.
///
/// Public because two callers outside the renderer need it: the prompt that
/// tells the agent what it may use, and the tool that tells it which types in a
/// rejected spec were not understood.
public nonisolated enum JSONRenderComponentCatalog {
    public static let names: Set<String> = [
        "Stack", "VStack", "HStack", "Grid", "Card", "Section",
        "Heading", "Text", "Caption", "Image", "Divider", "Spacer",
        "OptionGroup", "Toggle", "Chips", "TextField",
    ]
}

/// Dispatch from a type name to a component.
struct JSONRenderComponent: View {
    let element: JSONRenderElement
    let children: [JSONRenderNode]
    let context: JSONRenderContext

    var body: some View {
        switch element.type {
        case "Stack", "VStack", "HStack", "Section":
            JSONRenderStack(element: element, children: children, context: context)
        case "Grid":
            JSONRenderGrid(element: element, children: children, context: context)
        case "Card":
            JSONRenderCard(element: element, children: children, context: context)
        case "Heading", "Text", "Caption":
            JSONRenderText(element: element, context: context)
        case "Image":
            JSONRenderImageView(element: element, context: context)
        case "Divider":
            Divider()
        case "Spacer":
            Spacer(minLength: context.resolver.cgFloat(element.prop("minLength")) ?? 0)
        case "OptionGroup":
            JSONRenderOptionGroup(element: element, context: context)
        case "Toggle":
            JSONRenderToggle(element: element, context: context)
        case "Chips":
            JSONRenderChips(element: element, context: context)
        case "TextField":
            JSONRenderTextField(element: element, context: context)
        default:
            JSONRenderPlaceholder(text: "Unsupported element \"\(element.type)\"")
        }
    }
}

/// Shown where an element could not be drawn. Visible but quiet: the page is
/// still usable, and the gap is explainable.
struct JSONRenderPlaceholder: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "questionmark.square.dashed")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 4)
            .accessibilityIdentifier("json-render.placeholder")
    }
}
