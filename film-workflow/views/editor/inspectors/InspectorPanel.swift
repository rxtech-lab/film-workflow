import SwiftData
import SwiftUI
import TipKit
import VideoEditorCore
import VideoEditorUI

/// Right column. The tab row comes from the protocols the selected footage
/// conforms to (`InspectorTabResolver`), plus Clip and Sequence tabs when a
/// clip or a sequence is selected. Selecting never changes the tab: the last
/// tab the user picked is remembered and returns whenever it is offered.
struct InspectorPanel: View {
    let index: LibraryIndex
    @Bindable var state: EditorWindowState
    let document: ProjectDocument
    let sequence: SequenceProject?
    let onRender: () -> Void

    var body: some View {
        let context = InspectorContext(document: document, state: state, index: index, sequence: sequence, onRender: onRender)
        let footage = footageItem.flatMap { index.model(for: $0) }
        let footageTabs = InspectorTabResolver.tabs(
            footage: footage,
            hasClip: sequence != nil && !state.selectedClipIDs.isEmpty,
            sequenceSelected: state.selection?.kind == .sequence,
            context: context
        )
        let tabs = modifierTabs(footageTabs)
        let current = InspectorTabResolver.effectiveTabID(remembered: state.modifierSelection?.tabID ?? state.inspectorTabID, tabs: tabs)
        let tab = tabs.first { $0.id == current }
        VStack(spacing: 0) {
            StudioPanelHeader(title: "Inspector", symbol: "slider.horizontal.3")
            if !tabs.isEmpty {
                Picker("Inspector", selection: Binding(get: { current ?? "" }, set: { id in
                    if id == "effects", let clipID = state.selectedClipID { state.inspectEffects(clipID) }
                    else if id != "transition" { state.modifierSelection = nil; state.inspectorTabID = id }
                })) {
                    ForEach(tabs) { tab in
                        Text(tab.title).tag(tab.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(6)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .padding(10)
                Divider()
            }
            Group {
                if let tab {
                    tab.content()
                } else {
                    StudioEmptyState(title: "Nothing selected", symbol: "slider.horizontal.3",
                                     message: "Select footage to adjust its settings.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(state.modifierSelection.map { String(describing: $0) } ?? String(describing: footage?.libraryItemID))
            if let tab, tab.showsFooter, let footer = (footage as? any InspectorProtocol)?.makeInspectorFooter(context) {
                Divider()
                footer.id(footage?.libraryItemID)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func modifierTabs(_ footageTabs: [InspectorTabDescriptor]) -> [InspectorTabDescriptor] {
        var tabs = footageTabs
        if let selection = state.modifierSelection {
            tabs.append(InspectorTabDescriptor(id: selection.tabID, title: selection.tabID == "effects" ? "Effects" : "Transition",
                                              systemImage: "fx", showsFooter: false) {
                AnyView(ModifierInspector(selection: selection, sequence: sequence))
            })
        } else if let id = state.selectedClipID, sequence?.timeline.acceptsModifiers(on: id) == true {
            tabs.append(InspectorTabDescriptor(id: "effects", title: "Effects", systemImage: "fx", showsFooter: false) {
                AnyView(ModifierInspector(selection: .effects(id), sequence: sequence))
            })
        }
        return tabs
    }

    /// What the footage tabs show: the source of the clip selected on the
    /// timeline, or else the library selection. Selecting in the library
    /// clears the clip selection, so the latest choice wins.
    private var footageItem: LibraryItemID? {
        if let sequence, let clipID = state.selectedClipID, let clip = sequence.timeline.clip(id: clipID),
           let (prefix, id) = DocumentMediaResolver.parse(clip.source.id),
           let kind = FootageKind(rawValue: prefix.rawValue) {
            return LibraryItemID(kind: kind, id: id)
        }
        return state.selection
    }
}

/// The primary action every footage inspector shares.
struct GenerateButton<Tip: TipKitTip>: View {
    let title: LocalizedStringKey
    let isBusy: Bool
    let isEnabled: Bool
    let tip: Tip?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                if isBusy { ProgressView().controlSize(.small) } else { Image(systemName: "wand.and.stars") }
                Text(isBusy ? "Generating…" : title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isBusy || !isEnabled)
        .modifier(OptionalTip(tip: tip))
    }
}

/// `Tip` is a TipKit protocol; the alias keeps the generic readable.
typealias TipKitTip = TipKit.Tip

private struct OptionalTip<T: TipKitTip>: ViewModifier {
    let tip: T?
    func body(content: Content) -> some View {
        if let tip {
            content.popoverTip(tip, arrowEdge: .top)
        } else {
            content
        }
    }
}

extension GenerateButton where Tip == FilmWorkflowTips.GenerateMusicTip {
    init(title: LocalizedStringKey, isBusy: Bool, isEnabled: Bool, action: @escaping () -> Void) {
        self.init(title: title, isBusy: isBusy, isEnabled: isEnabled, tip: nil, action: action)
    }
}
