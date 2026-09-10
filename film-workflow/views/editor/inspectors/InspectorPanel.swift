import SwiftData
import SwiftUI
import VideoEditorCore
import VideoEditorUI

/// Right column: parameters and Generate for the selected footage, the
/// sequence settings and renders, or the selected timeline clip.
struct InspectorPanel: View {
    let index: LibraryIndex
    @Bindable var state: EditorWindowState
    let document: ProjectDocument
    let sequence: SequenceProject?
    let onRender: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $state.inspectorTab) {
                Text("Footage").tag(InspectorTab.footage)
                Text("Sequence").tag(InspectorTab.sequence)
                Text("Clip").tag(InspectorTab.clip)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch state.inspectorTab {
            case .footage:
                footageInspector
            case .sequence:
                if let sequence {
                    SequenceInspector(sequence: sequence, document: document, onRender: onRender)
                } else {
                    ContentUnavailableView("No Sequence", systemImage: "film.stack")
                }
            case .clip:
                if let sequence, let clipID = state.selectedClipID {
                    clipInspector(sequence: sequence, clipID: clipID)
                } else {
                    ContentUnavailableView("No Clip Selected", systemImage: "rectangle.dashed",
                                           description: Text("Select a clip on the timeline."))
                }
            }
        }
    }

    @ViewBuilder
    private var footageInspector: some View {
        switch state.selection?.kind {
        case .music?:
            if let p = state.selection.flatMap({ index.music($0.id) }) { MusicInspector(project: p).id(p.id) } else { empty }
        case .narration?:
            if let p = state.selection.flatMap({ index.narration($0.id) }) { NarrationInspector(project: p).id(p.id) } else { empty }
        case .caption?:
            if let p = state.selection.flatMap({ index.caption($0.id) }) { CaptionInspector(project: p).id(p.projectUUID) } else { empty }
        case .image?:
            if let p = state.selection.flatMap({ index.image($0.id) }) { ImageInspector(project: p).id(p.id) } else { empty }
        case .video?:
            if let p = state.selection.flatMap({ index.video($0.id) }) { VideoInspector(project: p).id(p.id) } else { empty }
        case .remotion?:
            if let p = state.selection.flatMap({ index.remotion($0.id) }) { RemotionInspector(project: p).id(p.id) } else { empty }
        case .imported?:
            if let a = state.selection.flatMap({ index.imported($0.id) }) { ImportedInspector(asset: a).id(a.id) } else { empty }
        case .sequence?:
            if let sequence { SequenceInspector(sequence: sequence, document: document, onRender: onRender) } else { empty }
        case nil:
            empty
        }
    }

    private var empty: some View {
        ContentUnavailableView("Nothing Selected", systemImage: "slider.horizontal.3",
                               description: Text("Select footage in the library to see its parameters."))
    }

    @ViewBuilder
    private func clipInspector(sequence: SequenceProject, clipID: UUID) -> some View {
        let timeline = Binding(get: { sequence.timeline }, set: { sequence.timeline = $0 })
        let remotion = remotionProject(for: clipID, in: sequence)
        let status: String? = remotion.map { project in
            RemotionRenderService.cachedRender(project: project, width: sequence.width, height: sequence.height, fps: sequence.fps, context: document.container.mainContext) == nil
                ? "Not rendered for this sequence" : ""
        }.flatMap { $0.isEmpty ? nil : $0 }
        ClipInspectorView(timeline: timeline, clipID: clipID, renderStatus: status, onRender: remotion == nil ? nil : onRender)
    }

    private func remotionProject(for clipID: UUID, in sequence: SequenceProject) -> RemotionProject? {
        guard let clip = sequence.timeline.clip(id: clipID), clip.source.kind == .remotion,
              let (prefix, id) = DocumentMediaResolver.parse(clip.source.id), prefix == .remotion else { return nil }
        return index.remotion(id)
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

/// Inspector layout: parameters and Generate above, versions below.
struct InspectorLayout<Parameters: View, Versions: View>: View {
    let versionsTitle: LocalizedStringKey
    let versionCount: Int
    @ViewBuilder let parameters: () -> Parameters
    @ViewBuilder let versions: () -> Versions

    var body: some View {
        VSplitView {
            parameters()
                .frame(minHeight: 200)
            VStack(spacing: 0) {
                HStack {
                    Text(versionsTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(versionCount)").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.bar)
                Divider()
                versions()
            }
            .frame(minHeight: 140, idealHeight: 260)
        }
    }
}

import TipKit
