import SwiftUI

nonisolated enum WelcomeWindowID {
    static let value = "welcome"
}

/// Shown at launch and whenever no film is open: New, Open, and recents.
struct WelcomeWindowView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var controller = ProjectDocumentController.shared
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            introduction
                .padding(32)
                .frame(width: 310)
                .frame(maxHeight: .infinity)
                .background(.regularMaterial)

            recentFilms
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 760, height: 460)
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

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 76, height: 76)
                .padding(.leading, -6)
                .accessibilityHidden(true)

            Text("RxFilmStudio")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .padding(.top, 18)
            Text("Your next story starts here.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            VStack(spacing: 10) {
                Button {
                    Task { await createFilm() }
                } label: {
                    Label("New Film…", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                }
                .buttonStyle(.glassProminent)
                .tint(.accentColor)

                Button {
                    Task { await openFilm() }
                } label: {
                    Label("Open Film…", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
            .font(.system(size: 13, weight: .semibold))
            .padding(.top, 32)

            Spacer(minLength: 24)

            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var recentFilms: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent Films")
                    .font(.system(size: 20, weight: .semibold))
                Text("Pick up where you left off.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            if controller.recentDocumentURLs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text("A fresh start")
                        .font(.headline)
                    Text("Create a film or open an existing one.\nYour recent films will appear here.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(controller.recentDocumentURLs, id: \.self) { url in
                            WelcomeRecentFilmRow(url: url) { open(url) }
                        }
                    }
                    .padding(2)
                }
            }
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

private struct WelcomeRecentFilmRow: View {
    let url: URL
    let action: () -> Void
    @State private var isHovered = false

    private var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private var location: String {
        let parent = url.deletingLastPathComponent().path(percentEncoded: false)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return parent == home ? "~" : parent.hasPrefix(home + "/")
            ? "~" + parent.dropFirst(home.count) : parent
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "film")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(exists ? Color.accentColor : Color.secondary)
                    .frame(width: 44, height: 48)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(location)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !exists {
                        Text("File unavailable")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .background(
                Color.primary.opacity(isHovered && exists ? 0.07 : 0.03),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(isHovered && exists ? 0.12 : 0.05))
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!exists)
        .onHover { isHovered = $0 }
        .help(url.path(percentEncoded: false))
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .disabled(!exists)
        }
    }
}
