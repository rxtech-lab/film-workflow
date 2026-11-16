import AppKit
import MotionCore
import MotionEditor
import MotionPortable
import MotionSwiftUI
import SwiftData
import SwiftUI
import VideoEditorCore
import VideoEditorUI

/// The viewer while a Remotion clip is open: MotionSwift's canvas, where elements are selected,
/// moved and resized, above the transport. Status appears as overlays.
struct RemotionCompositionViewer: View {
    @Bindable var session: RemotionCompositionSession
    @State private var viewport = CanvasViewport()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(session.timeline.width)×\(session.timeline.height) · \(Int(session.fps.rounded()))p")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Label(session.name, systemImage: "sparkles.rectangle.stack").lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(.bar)
            if let model = session.model {
                EditorCanvas(model: model, viewport: $viewport)
                    .background { CompositionFrameObserver(session: session, model: model) }
                    .overlay {
                        if let failure = failureMessage(for: model) {
                            VStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.orange)
                                Text("Render Error").font(.headline)
                                Text(failure)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(6)
                                Button("Reload Composition") {
                                    Task { await session.reload() }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                            .padding(20)
                            .frame(maxWidth: 420)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                            .padding()
                        } else if model.player.displayedFrame == nil {
                            ProgressView("Rendering composition…")
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .top) {
                        if model.status != .idle, failureMessage(for: model) == nil {
                            ProgressView().controlSize(.small).padding(8)
                                .background(.regularMaterial, in: Capsule()).padding(.top, 10)
                                .accessibilityLabel("Saving composition")
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let notice = model.notice {
                            Text(notice.message).font(.callout).padding(.horizontal, 12).padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule()).padding(.bottom, 14)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                                .allowsHitTesting(false)
                        }
                    }
                    .animation(.snappy, value: model.notice)
                    .accessibilityIdentifier("composition.canvas")
                transport(model)
            } else if let error = session.setupError {
                ContentUnavailableView("Can’t Open the Composition", systemImage: "exclamationmark.triangle", description: Text(error))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Opening composition…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sensoryFeedback(.selection, trigger: session.model?.selectionFeedback ?? 0)
        .sensoryFeedback(.alignment, trigger: session.model?.snapFeedback ?? 0)
        .sensoryFeedback(.impact(weight: .medium), trigger: session.model?.commitFeedback ?? 0)
        .sensoryFeedback(.error, trigger: session.model?.refusalFeedback ?? 0)
    }

    private func failureMessage(for model: EditorModel) -> String? {
        if case .failed(let message) = model.status { return message }
        return model.player.renderError
    }

    private func transport(_ model: EditorModel) -> some View {
        HStack(spacing: 14) {
            Button("Backward One Frame", systemImage: "backward.frame.fill") { session.step(by: -1) }
                .accessibilityIdentifier("composition.previous-frame")
            Button(model.player.isPlaying ? "Pause" : "Play", systemImage: model.player.isPlaying ? "pause.fill" : "play.fill") {
                session.togglePlayback()
            }
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityIdentifier("composition.play")
            Button("Forward One Frame", systemImage: "forward.frame.fill") { session.step(by: 1) }
                .accessibilityIdentifier("composition.next-frame")
            Text(Timecode.string(seconds: session.playhead, fps: max(1, Int(session.fps.rounded()))))
                .font(.callout.monospacedDigit())
                .accessibilityIdentifier("composition.timecode")
            Spacer()
            Toggle(isOn: Binding(get: { model.snapsToGuides }, set: { model.snapsToGuides = $0 })) {
                Label("Snap", systemImage: "square.and.line.vertical.and.square")
            }
            .toggleStyle(.button)
            .help("Snap to canvas and sibling edges and centers")
            Button("Fit", systemImage: "arrow.down.right.and.arrow.up.left") {
                viewport.normalizeRotation()
                withAnimation { viewport = CanvasViewport() }
            }
            .disabled(viewport.isIdentity)
            .help("Reset zoom, pan and rotation")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(.bar)
    }
}

/// Per-frame observation kept out of the viewer's body: the element lanes grow as elements first
/// appear on screen, and canvas selections reach the timeline.
private struct CompositionFrameObserver: View {
    let session: RemotionCompositionSession
    let model: EditorModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: model.player.currentFrame) { model.observeKeyframePlayhead() }
            .onChange(of: model.player.displayedFrame?.frame) {
                model.observeTimelineFrame()
                session.rebuildTimeline()
            }
            .onChange(of: model.timelineTracks) { session.rebuildTimeline() }
            .onChange(of: model.selection) { session.followModelSelection() }
    }
}

/// The timeline panel while a Remotion clip is open: a path back to the sequence, then the
/// composition's elements as lanes on the app's own timeline. Moving or trimming a span changes
/// when its element appears; undo and redo act on the composition source.
struct RemotionCompositionTimelinePanel: View {
    @Bindable var session: RemotionCompositionSession
    let sequenceName: String?
    @Binding var skimming: Bool
    let onClose: () -> Void
    @Environment(\.modelContext) private var modelContext

    init(
        session: RemotionCompositionSession,
        sequenceName: String?,
        skimming: Binding<Bool> = .constant(false),
        onClose: @escaping () -> Void
    ) {
        self.session = session
        self.sequenceName = sequenceName
        self._skimming = skimming
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            Divider()
            if session.model != nil {
                SequenceTimelineView(
                    timeline: Binding(get: { session.timeline }, set: { session.apply($0) }),
                    playhead: Binding(get: { session.playhead }, set: { session.playhead = $0 }),
                    selectedClipIDs: $session.selectedClipIDs,
                    pixelsPerSecond: $session.pixelsPerSecond,
                    skimming: $skimming,
                    isPlaying: session.isPlaying,
                    onSkim: { time in
                        if let time { session.skim(to: time) } else { session.endSkim() }
                    },
                    onDrop: { _, _, _ in },
                    onDeleteClips: { _ in },
                    onDeselect: { session.selectedClipIDs = [] }
                )
                .accessibilityIdentifier("composition.timeline")
                .overlay {
                    if session.timeline.tracks.isEmpty {
                        ContentUnavailableView("No Editable Elements", systemImage: "square.dashed",
                                               description: Text("This composition has no visual elements to place on lanes."))
                            .allowsHitTesting(false)
                    }
                }
            } else if let error = session.setupError {
                ContentUnavailableView("Can’t Open the Composition", systemImage: "exclamationmark.triangle", description: Text(error))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Reading composition…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onKeyPress(.space) {
            session.togglePlayback()
            return .handled
        }
        .task(id: session.projectID) { await session.open() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            session.endSkim()
        }
        .onChange(of: skimming) { _, enabled in
            if !enabled { session.endSkim() }
        }
        .onChange(of: session.model?.files[RemotionElementsTab.compositionPath]) { _, _ in
            // MotionSwift wrote an edit back to disk.
            session.syncFromDisk(context: modelContext)
        }
        .onChange(of: session.project.compositionSource) { _, _ in
            Task { await session.reloadIfChanged() }
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Button(action: onClose) {
                Label(sequenceName ?? String(localized: "Sequence"), systemImage: "chevron.backward")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Back to the sequence timeline")
            .accessibilityIdentifier("composition.back")
            Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
            Label(session.name, systemImage: "sparkles.rectangle.stack").lineLimit(1).fontWeight(.medium)
            Spacer()
            if let model = session.model {
                Button("Undo", systemImage: "arrow.uturn.backward") { Task { await model.undo(); session.rebuildTimeline() } }
                    .keyboardShortcut("z")
                    .disabled(!model.canUndo || model.status != .idle)
                    .help(model.undoActionName.map { "Undo \($0)" } ?? String(localized: "Undo"))
                Button("Redo", systemImage: "arrow.uturn.forward") { Task { await model.redo(); session.rebuildTimeline() } }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo || model.status != .idle)
                    .help(model.redoActionName.map { "Redo \($0)" } ?? String(localized: "Redo"))
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.bar)
    }
}

/// The inspector while a Remotion clip is open: the selected element's properties, edited in
/// MotionSwift's dedicated sheets and written back to the composition, or the selectable element
/// directory when nothing is selected yet.
struct RemotionCompositionInspector: View {
    @Bindable var session: RemotionCompositionSession
    @Environment(\.modelContext) private var modelContext
    @State private var codeLocation: RemotionSourceLocation?

    var body: some View {
        content
            .sheet(item: $codeLocation) { location in
                RemotionSourceSheetView(projectDir: session.project.projectDir, refreshToken: 0, initialLocation: location,
                                        onSaved: { _ in
                                            session.syncFromDisk(context: modelContext)
                                            Task { await session.reloadIfChanged() }
                                        }) { codeLocation = nil }
            }
    }

    @ViewBuilder private var content: some View {
        if let model = session.model, model.selection != nil {
            NavigationStack {
                EditorInspector(model: model) { codeLocation = RemotionSourceLocation(file: $0.file, line: $0.line) }
                    .navigationTitle(selectedTitle(in: model))
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button("All Elements", systemImage: "chevron.backward") {
                                session.selectedClipIDs = []
                            }
                            .help("Back to element list")
                        }
                    }
            }
            .accessibilityIdentifier("composition.inspector")
        } else if let model = session.model, !model.timelineTracks.isEmpty {
            List {
                Section {
                    ForEach(model.timelineTracks) { track in
                        Button {
                            session.selectElement(track.src)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(RemotionCompositionSession.displayLabel(for: track))
                                        .lineLimit(1)
                                    Text(detail(track, in: model))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Elements (\(model.timelineTracks.count))")
                } footer: {
                    Text("Select any element on the canvas, timeline, or from this list to inspect and edit its text, props, and style.")
                }
            }
        } else {
            ContentUnavailableView("No Element Selected", systemImage: "cursorarrow.click",
                                   description: Text("Select an element on the canvas or the timeline to edit it."))
        }
    }

    private func selectedTitle(in model: EditorModel) -> String {
        guard let track = model.selectedTrack else { return String(localized: "Element") }
        return RemotionCompositionSession.displayLabel(for: track)
    }

    private func detail(_ track: ObjectTrack, in model: EditorModel) -> String {
        let duration = model.player.composition?.durationInFrames ?? (track.start + 1)
        let range = String(localized: "Frames \(track.start)–\(track.end(in: duration))")
        guard let owner = track.owner, !owner.isEmpty else { return range }
        return "\(owner) · \(range)"
    }
}
