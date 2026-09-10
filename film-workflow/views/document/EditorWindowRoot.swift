import SwiftData
import SwiftUI

/// Root of one editor window: resolves the film for the window's URL, installs
/// its model container and storage in the environment, and keeps
/// `ProjectDocumentController.activeDocument` pointed at the key window.
struct EditorWindowRoot: View {
    let documentURL: URL?

    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismiss) private var dismiss
    @State private var controller = ProjectDocumentController.shared
    @State private var document: ProjectDocument?
    @State private var openError: String?

    var body: some View {
        Group {
            if let document {
                EditorWindowContent(document: document)
                    .modelContainer(document.container)
                    .environment(\.projectDocument, document)
                    .environment(\.projectStorage, document.storage)
                    .environment(AgentController.shared)
                    .navigationTitle(document.displayName)
                    .navigationDocument(document.packageURL)
                    .onChange(of: controlActiveState, initial: true) { _, state in
                        if state == .key { controller.activeDocument = document }
                    }
                    .onDisappear {
                        Task { await controller.close(document) }
                    }
            } else if let openError {
                ContentUnavailableView {
                    Label("Couldn’t Open Film", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(openError)
                } actions: {
                    Button("Close") { dismiss() }
                }
                .frame(minWidth: 480, minHeight: 320)
            } else {
                ProgressView()
                    .frame(minWidth: 480, minHeight: 320)
            }
        }
        .task(id: documentURL) {
            guard let documentURL else {
                openError = "No film was selected."
                return
            }
            do {
                document = try controller.openOrReuse(documentURL)
                dismissWindow(id: WelcomeWindowID.value)
            } catch {
                openError = error.localizedDescription
            }
        }
    }
}

/// The editor itself. Phase 1 shows the existing tab UI inside the document
/// window; the Final Cut–style shell replaces it in a later phase.
private struct EditorWindowContent: View {
    let document: ProjectDocument

    var body: some View {
        ContentView()
    }
}
