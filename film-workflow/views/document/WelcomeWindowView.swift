import SwiftUI

nonisolated enum WelcomeWindowID {
    static let value = "welcome"
}

/// Shown at launch and whenever no film is open: New, Open, and recents.
struct WelcomeWindowView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var controller = ProjectDocumentController.shared
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                Text("RxFilmStudio")
                    .font(.largeTitle.weight(.semibold))
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await createFilm() }
                } label: {
                    Label("New Film…", systemImage: "plus.square")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {
                    Task { await openFilm() }
                } label: {
                    Label("Open…", systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.borderless)
            .padding(28)
            .frame(width: 300)

            Divider()

            List {
                Section("Recent Films") {
                    let recents = controller.recentDocumentURLs
                    if recents.isEmpty {
                        Text("No recent films")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(recents, id: \.self) { url in
                        let exists = FileManager.default.fileExists(atPath: url.path)
                        Button {
                            open(url)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.deletingPathExtension().lastPathComponent)
                                    .font(.headline)
                                Text(url.deletingLastPathComponent().path(percentEncoded: false))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!exists)
                        .opacity(exists ? 1 : 0.5)
                        .contextMenu {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 360)
        }
        .frame(width: 660, height: 420)
        .onAppear {
            controller.openWindowRequest = { url in
                openWindow(id: EditorWindowID.value, value: url)
            }
        }
        .alert("Couldn’t Open Film", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func open(_ url: URL) {
        openWindow(id: EditorWindowID.value, value: url)
    }

    private func createFilm() async {
        guard let url = await controller.presentNewPanel() else { return }
        do {
            try controller.createDocument(at: url)
            open(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openFilm() async {
        guard let url = await controller.presentOpenPanel() else { return }
        open(url)
    }
}

nonisolated enum EditorWindowID {
    static let value = "editor"
}
