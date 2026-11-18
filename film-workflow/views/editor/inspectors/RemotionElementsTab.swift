import MotionCore
import MotionEditor
import MotionPortable
import MotionSwiftUI
import SkiaKit
import SwiftData
import SwiftUI

/// The Remotion composition's elements, editable with MotionSwift from the inspector: pick an
/// element from the list to open its properties (MotionSwift's `EditorInspector`), where static
/// values are edited in dedicated sheets and written back to the TSX. Edits reach the timeline,
/// the sequence preview and the agent through `syncCompositionSourceFromDisk`.
/// "Open Composition" drills into it in the editor: element timing on the app's timeline,
/// dragging and resizing on the canvas.
struct RemotionElementsTab: View {
    let project: RemotionProject
    /// Opens the composition in the editor: elements on the timeline, picture on the canvas.
    var onOpenComposition: () -> Void = {}
    @Environment(\.modelContext) private var modelContext
    @State private var model: EditorModel?
    @State private var setupError: String?
    @State private var path: [String] = []
    @State private var codeLocation: RemotionSourceLocation?

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationDestination(for: String.self) { source in
                    if let model {
                        EditorInspector(model: model) { codeLocation = RemotionSourceLocation(file: $0.file, line: $0.line) }
                            .navigationTitle(model.timelineTracks.first { $0.src == source }.map(RemotionCompositionSession.displayLabel) ?? String(localized: "Element"))
                            .task(id: source) { select(source) }
                            .accessibilityIdentifier("remotion.elements.inspector")
                    }
                }
        }
        .sheet(item: $codeLocation) { location in
            RemotionSourceSheetView(projectDir: project.projectDir, refreshToken: 0, initialLocation: location,
                                    onSaved: { _ in project.syncCompositionSourceFromDisk(context: modelContext) }) { codeLocation = nil }
        }
        .task(id: project.id) { await open() }
        .onChange(of: model?.player.displayedFrame?.frame) { _, _ in
            model?.observeTimelineFrame()
        }
        .onChange(of: model?.files[Self.compositionPath]) { _, _ in
            // MotionSwift wrote an edit back to disk.
            project.syncCompositionSourceFromDisk(context: modelContext)
        }
        .onChange(of: project.compositionSource) { _, source in
            // The agent, the Source sheet or the canvas editor changed the composition.
            guard let model, model.files[Self.compositionPath] != source else { return }
            Task { await model.open(compositionID: MotionSwiftEngine.compositionID) }
        }
        .sensoryFeedback(.selection, trigger: model?.selectionFeedback ?? 0)
    }

    static let compositionPath = "src/Composition.tsx"

    @ViewBuilder private var content: some View {
        if let model {
            List {
                Section {
                    ForEach(model.timelineTracks) { track in
                        NavigationLink(value: track.src) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(RemotionCompositionSession.displayLabel(for: track)).lineLimit(1)
                                Text(detail(track, in: model)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .accessibilityIdentifier("remotion.elements.row")
                    }
                } header: {
                    Text("Elements")
                } footer: {
                    Text("Select an element to edit its text and style. Open the composition to change its timing, or move and resize it on the canvas. Double-clicking the clip on the timeline does the same.")
                }
            }
            .overlay {
                if model.timelineTracks.isEmpty {
                    switch model.status {
                    case .failed(let message):
                        ContentUnavailableView("Can't Read the Composition", systemImage: "exclamationmark.triangle", description: Text(message))
                    case .idle:
                        ContentUnavailableView("No Editable Elements", systemImage: "square.dashed",
                                               description: Text("This composition has no elements MotionSwift can edit."))
                    default:
                        ProgressView("Reading composition…")
                    }
                }
            }
            .toolbar {
                ToolbarItem {
                    Button("Open Composition", systemImage: "cursorarrow.motionlines", action: onOpenComposition)
                        .help("Edit the elements' timing on the timeline and move or resize them on the canvas")
                        .accessibilityIdentifier("remotion.elements.canvas")
                }
            }
        } else if let setupError {
            ContentUnavailableView("Can't Open the Composition", systemImage: "exclamationmark.triangle", description: Text(setupError))
        } else if project.compositionSource.isEmpty {
            ContentUnavailableView("No Composition Yet", systemImage: "sparkles.rectangle.stack",
                                   description: Text("Generate the composition, then edit its elements here."))
        } else {
            ProgressView("Opening composition…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detail(_ track: ObjectTrack, in model: EditorModel) -> String {
        let duration = model.player.composition?.durationInFrames ?? (track.start + 1)
        let range = String(localized: "Frames \(track.start)–\(track.end(in: duration))")
        guard let owner = track.owner, !owner.isEmpty else { return range }
        return "\(owner) · \(range)"
    }

    private func open() async {
        model = nil
        path = []
        setupError = nil
        guard !project.compositionSource.isEmpty else { return }
        do {
            let directory = project.projectDir
            try RemotionRuntime.shared.prepareProjectDirectory(directory)
            if !FileManager.default.fileExists(atPath: project.compositionSourceURL.path) {
                try RemotionCodeBuilder.writeComposition(project: project, source: project.compositionSource)
            }
            // Layout only: run on GPU at quarter scale so inspector discovery and style resolution stay instant.
            let editor = EditorModel(
                project: directory,
                entry: MotionSwiftEngine.entry,
                configuration: .init(scale: 0.25, backend: .gpu)
            )
            model = editor
            await editor.open(compositionID: MotionSwiftEngine.compositionID)
        } catch {
            setupError = error.localizedDescription
        }
    }

    /// Selects the element and moves the playhead into its range, so its box and resolved
    /// styles come from a frame where it is visible.
    private func select(_ source: String) {
        guard let model, let track = model.timelineTracks.first(where: { $0.src == source }) else { return }
        model.selectTrack(track)
        let duration = model.player.composition?.durationInFrames ?? track.start + 1
        let frame = model.player.currentFrame
        if frame < track.start || frame >= track.end(in: duration) { model.scrub(to: track.start) }
    }
}
