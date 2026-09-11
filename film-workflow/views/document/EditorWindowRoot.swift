import SwiftData
import SwiftUI

/// Root of one editor window: resolves the film for the window's URL, installs
/// its model container and storage in the environment, and keeps
/// `ProjectDocumentController.activeDocument` pointed at the key window.
struct EditorWindowRoot: View {
    let documentURL: URL?

    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.openWindow) private var openWindow
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
            } else if openError != nil {
                Color.clear.frame(minWidth: 480, minHeight: 320)
            } else {
                ProgressView()
                    .frame(minWidth: 480, minHeight: 320)
            }
        }
        .alert("Couldn’t Open Film", isPresented: Binding(
            get: { openError != nil },
            set: { if !$0 { openError = nil; dismiss() } }
        )) {
            Button("OK") { openError = nil; dismiss() }
        } message: {
            Text(openError ?? "")
        }
        .task(id: documentURL) {
            guard let documentURL else {
                // Launch/restoration can create a value-less editor window.
                // There is no document to open, so return to the welcome screen.
                openWindow(id: WelcomeWindowID.value)
                dismiss()
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

private struct EditorWindowContent: View {
    let document: ProjectDocument

    var body: some View {
        EditorWindowView(document: document)
    }
}
