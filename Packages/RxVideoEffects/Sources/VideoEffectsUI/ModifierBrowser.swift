import AppKit
import Combine
import CoreImage
import SwiftUI
import UniformTypeIdentifiers
import VideoEffectsCore

public extension UTType {
    static let videoModifier = UTType(exportedAs: "com.rxlab.video-modifier", conformingTo: .data)
}

@Observable @MainActor
public final class ModifierDragSession {
    public static let shared = ModifierDragSession()
    public private(set) var item: ModifierDragItem?
    public func begin(_ item: ModifierDragItem) { self.item = item }
    public func end() { item = nil }
}

public struct ModifierThumbnail: View {
    let item: ModifierDragItem
    let parameters: ModifierParameters?
    @State private var hovering = false
    /// An installed definition's own preview still. Shown at rest; hovering
    /// switches to the live sample so the animation contract is the same for
    /// every item.
    @State private var externalPreview: NSImage?
    private static let context = CIContext(options: [.cacheIntermediates: false])
    public init(item: ModifierDragItem, parameters: ModifierParameters? = nil) { self.item = item; self.parameters = parameters }
    private var previewURL: URL? { ModifierCatalog.current.previewURLs[item.definitionID] }
    public var body: some View {
        Group {
            if let externalPreview, !hovering {
                Image(nsImage: externalPreview).resizable().aspectRatio(16 / 9, contentMode: .fill).clipped()
            } else {
                TimelineView(.animation(minimumInterval: 1 / 24, paused: !hovering)) { clock in
                    let phase = hovering ? clock.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2 : 0.5
                    let sample = ModifierSample.image(item, progress: phase, parameters: parameters, effectAmount: hovering ? (1 - cos(phase * .pi * 2)) / 2 : 1)
                    if let sample, let image = Self.context.createCGImage(sample, from: sample.extent) {
                        Image(decorative: image, scale: 1).resizable().aspectRatio(16 / 9, contentMode: .fit)
                    } else { Color.gray.aspectRatio(16 / 9, contentMode: .fit) }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .onHover { hovering = $0 }
        .task(id: previewURL) {
            guard let url = previewURL else { externalPreview = nil; return }
            let loaded = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
            externalPreview = loaded
        }
        .accessibilityLabel(item.kind == .effect ? "Effect preview" : "Transition preview")
    }
}

public struct ModifierBrowser: View {
    let onSelect: (ModifierDragItem) -> Void
    @State private var kind: ModifierKind = .effect
    @State private var search = ""
    /// Bumped when definitions are installed or removed so the grid re-reads the catalog.
    @State private var catalogGeneration = 0
    public init(onSelect: @escaping (ModifierDragItem) -> Void) { self.onSelect = onSelect }
    private var items: [ModifierDragItem] {
        _ = catalogGeneration
        let catalog = ModifierCatalog.current
        let ids = kind == .effect ? catalog.effects.map(\.id) : catalog.transitions.map(\.id)
        return ids.map { ModifierDragItem(kind: kind, definitionID: $0) }.filter {
            search.isEmpty || catalog.definition($0)?.name.localizedCaseInsensitiveContains(search) == true
                || catalog.definition($0)?.summary.localizedCaseInsensitiveContains(search) == true
        }
    }
    public var body: some View {
        VStack(spacing: 8) {
            ModifierBrowserTabs(selection: $kind)
                .frame(maxWidth: .infinity).frame(height: 24)
            TextField("Search effects and transitions", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("modifier-search")
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 115), alignment: .top)], spacing: 12) {
                    ForEach(items, id: \.self) { item in
                        let definition = ModifierCatalog.current.definition(item)
                        VStack(alignment: .leading, spacing: 4) {
                            ModifierThumbnail(item: item)
                            Text(definition?.name ?? item.definitionID).font(.caption.weight(.medium)).lineLimit(2)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(item) }
                        .onDrag {
                            ModifierDragSession.shared.begin(item)
                            let provider = NSItemProvider()
                            let data = try? JSONEncoder().encode(item)
                            provider.registerDataRepresentation(forTypeIdentifier: UTType.videoModifier.identifier, visibility: .all) { completion in
                                completion(data, nil); return nil
                            }
                            return provider
                        } preview: {
                            ModifierThumbnail(item: item).frame(width: 140)
                        }
                        .help(definition?.summary ?? "")
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier(item.definitionID)
                    }
                }
                if items.isEmpty { Text("No matching items").foregroundStyle(.secondary).padding() }
            }
        }.padding(10)
        .onReceive(NotificationCenter.default.publisher(for: ModifierCatalog.didChangeNotification).receive(on: RunLoop.main)) { _ in catalogGeneration += 1 }
    }
}

/// Native equal-width segments fill the browser instead of hugging their labels.
private struct ModifierBrowserTabs: NSViewRepresentable {
    @Binding var selection: ModifierKind
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: [String(localized: "Effects"), String(localized: "Transitions")], trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.select(_:)))
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setAccessibilityLabel("Browser")
        control.setAccessibilityIdentifier("modifier-browser-tabs")
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = selection == .effect ? 0 : 1
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
    }
    final class Coordinator: NSObject {
        var selection: Binding<ModifierKind>
        init(selection: Binding<ModifierKind>) { self.selection = selection }
        @objc func select(_ sender: NSSegmentedControl) { selection.wrappedValue = sender.selectedSegment == 0 ? .effect : .transition }
    }
}
