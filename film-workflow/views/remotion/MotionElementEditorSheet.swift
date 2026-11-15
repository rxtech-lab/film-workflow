import MotionEditor
import SwiftData
import SwiftUI

/// Edits a Remotion composition's elements natively with MotionSwift's editor: select
/// on the canvas, drag, change text and styles in the inspector, scrub the element
/// timeline. Edits are written back to the project's TSX source as they are committed.
/// Compositions MotionSwift can't compile show why, and keep the WebKit preview and the
/// Source sheet as the way to change them.
struct MotionElementEditorSheet: View {
    let project: RemotionProject
    let onDone: () -> Void
    @Environment(\.modelContext) private var modelContext
    @State private var model: EditorModel?
    @State private var setupError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    MotionEditorView(model: model)
                } else if let setupError {
                    ContentUnavailableView("Can't Open the Editor", systemImage: "exclamationmark.triangle",
                                           description: Text(setupError))
                } else {
                    ProgressView("Opening composition…")
                }
            }
            .navigationTitle(project.name)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finish() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("motionEditor.done")
                }
            }
        }
        // Full height: a shorter macOS sheet halves the navigation title area.
        .frame(minWidth: 1100, idealWidth: 1280, maxWidth: .infinity, minHeight: 760, idealHeight: 860, maxHeight: .infinity)
        .task { await open() }
        .onDisappear { syncSource() }
    }

    private func open() async {
        guard model == nil else { return }
        do {
            let directory = project.projectDir
            try RemotionRuntime.shared.prepareProjectDirectory(directory)
            let source = directory.appendingPathComponent("src/Composition.tsx")
            if !FileManager.default.fileExists(atPath: source.path), !project.compositionSource.isEmpty {
                try RemotionCodeBuilder.writeComposition(project: project, source: project.compositionSource)
            }
            guard FileManager.default.fileExists(atPath: source.path) else {
                setupError = String(localized: "Create a composition before editing its elements.")
                return
            }
            let editor = EditorModel(project: directory, entry: MotionSwiftEngine.entry)
            model = editor
            await editor.open(compositionID: MotionSwiftEngine.compositionID)
        } catch {
            setupError = error.localizedDescription
        }
    }

    private func finish() {
        syncSource()
        onDone()
    }

    /// Mirrors the edited TSX into the document so renders, the agent and the Source
    /// sheet see the change, then reloads open previews.
    private func syncSource() {
        let url = project.projectDir.appendingPathComponent("src/Composition.tsx")
        guard let source = try? String(contentsOf: url, encoding: .utf8), source != project.compositionSource else { return }
        project.compositionSource = source
        project.updatedAt = Date()
        try? modelContext.save()
        NotificationCenter.default.post(name: .remotionPreviewChanged, object: nil,
                                        userInfo: ["directory": project.projectDir.standardizedFileURL])
    }
}
