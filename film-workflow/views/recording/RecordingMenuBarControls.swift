import AppKit
import SwiftUI

struct RecordingMenuBarControls: View {
    @State private var session = RecordingSession.shared
    @State private var setup = RecordingSetup.shared
    @State private var documents = ProjectDocumentController.shared
    @State private var choosingFilm = false
    @State private var error: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if session.isActive {
            RecordingSessionControls()
        } else if setup.isPresented {
            Text(setup.document?.displayName ?? "Recording").font(.headline)
            Button("Show Recording Setup", systemImage: "record.circle") { RecordingWindows.shared.showSetup() }
            Button("Cancel Recording Setup", role: .cancel) { setup.cancel() }
        } else {
            if let document = documents.activeDocument {
                Text(document.displayName).font(.headline)
            }
            Button("Quick Recording…", systemImage: "record.circle") {
                Task { await quickRecord() }
            }
            .disabled(choosingFilm)
            .accessibilityIdentifier("recording.quickStart")
            if let document = documents.activeDocument {
                Button("Show Film", systemImage: "film") {
                    openWindow(id: EditorWindowID.value, value: document.packageURL)
                    NSApp.activate()
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
    }

    private func quickRecord() async {
        guard !choosingFilm else { return }
        choosingFilm = true; error = nil
        defer { choosingFilm = false }
        do {
            let document: ProjectDocument
            if let active = documents.activeDocument {
                document = active
            } else {
                NSApp.activate()
                guard let url = await documents.presentNewPanel(name: String(localized: "Screen Recordings")) else { return }
                document = try documents.createDocument(at: url)
                openWindow(id: EditorWindowID.value, value: url)
            }
            try setup.openQuickRecording(in: document)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
