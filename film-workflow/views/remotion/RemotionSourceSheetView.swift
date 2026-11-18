#if os(macOS)
import SwiftUI
import AppKit

/// A file and line in a Remotion project to open in the source editor.
struct RemotionSourceLocation: Hashable, Identifiable {
    let file: String
    let line: Int
    var id: String { "\(file):\(line)" }
}

/// The Remotion project's source files, editable. Saving writes the file and calls `onSaved`, so
/// the owner can copy the composition into the document and reload every preview. Edits made
/// elsewhere since the file was opened (the agent, the canvas editor) are never overwritten
/// silently.
struct RemotionSourceSheetView: View {
    let projectDir: URL
    /// Bumped by the parent whenever the agent writes a file — triggers a refresh of
    /// the file list and the currently-selected file's contents.
    let refreshToken: Int
    /// Opens this file at this line instead of the composition.
    var initialLocation: RemotionSourceLocation?
    /// Called with the project-relative path after a save.
    var onSaved: (String) -> Void = { _ in }
    var onDismiss: () -> Void

    @State private var files: [String] = []
    @State private var selected: String?
    /// The editor's text and the file's bytes when it was loaded or saved.
    @State private var content = ""
    @State private var loaded = ""
    @State private var reveal: CodeReveal?
    @State private var saving = false
    @State private var savedFeedback = 0
    @State private var notice: String?
    @State private var errorMessage: String?
    @State private var pendingSelection: String?
    @State private var confirmingSwitch = false
    @State private var confirmingClose = false
    @State private var conflict = false

    private var isDirty: Bool { content != loaded }

    var body: some View {
        NavigationSplitView {
            List(files, id: \.self, selection: selection) { path in
                Text(path)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .tag(path)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 380)
            .listStyle(.sidebar)
        } detail: {
            if selected != nil {
                CodeTextView(text: $content, highlights: isHighlightable(path: selected ?? ""), reveal: reveal)
                    .disabled(saving)
            } else {
                ContentUnavailableView("No File Selected", systemImage: "doc.text")
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { isDirty ? (confirmingClose = true) : onDismiss() }
                    .disabled(saving)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                    show(String(localized: "Copied"))
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(content.isEmpty)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save(overwrite: false) }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!isDirty || saving || selected == nil)
                    .accessibilityIdentifier("remotion.source.save")
            }
        }
        .overlay {
            if saving {
                ProgressView("Saving…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice)
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: notice)
        .sensoryFeedback(.success, trigger: savedFeedback)
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmingSwitch, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) {
                selected = pendingSelection
                loadContent()
            }
        } message: {
            Text("Your edits to \(selected ?? "this file") haven't been saved.")
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmingClose, titleVisibility: .visible) {
            Button("Save and Close") { save(overwrite: false, closing: true) }
            Button("Discard Changes", role: .destructive) { onDismiss() }
        } message: {
            Text("Your edits to \(selected ?? "this file") haven't been saved.")
        }
        .alert("File changed on disk", isPresented: $conflict) {
            Button("Overwrite", role: .destructive) { save(overwrite: true) }
            Button("Reload from Disk") { loadContent() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(selected ?? "This file") was changed by the agent or the editor after you opened it. Overwrite those changes, or reload and lose your edits?")
        }
        .alert("Couldn't Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
        .interactiveDismissDisabled(isDirty || saving)
        .frame(minWidth: 880, idealWidth: 1040, maxWidth: .infinity, minHeight: 560, idealHeight: 720, maxHeight: .infinity)
        .task(id: refreshToken) { reloadFiles() }
    }

    private var title: String {
        guard let selected else { return String(localized: "Source") }
        return isDirty ? "\(selected) — \(String(localized: "Edited"))" : selected
    }

    /// File selection that asks before dropping unsaved edits.
    private var selection: Binding<String?> {
        Binding(get: { selected }, set: { path in
            guard path != selected else { return }
            if isDirty {
                pendingSelection = path
                confirmingSwitch = true
            } else {
                selected = path
                loadContent()
            }
        })
    }

    private func reloadFiles() {
        let listed = RemotionProjectFiles.list(projectDir: projectDir)
        files = listed
        if selected == nil, let initialLocation, listed.contains(initialLocation.file) {
            selected = initialLocation.file
            loadContent()
            reveal = CodeReveal(line: initialLocation.line)
        } else if let current = selected, listed.contains(current) {
            // The agent wrote files: refresh, unless that would drop the user's edits.
            if !isDirty { loadContent() }
        } else {
            selected = listed.first(where: { $0 == "src/Composition.tsx" }) ?? listed.first
            loadContent()
        }
    }

    private func loadContent() {
        guard let path = selected else {
            content = ""
            loaded = ""
            return
        }
        let raw = (try? String(contentsOf: projectDir.appendingPathComponent(path), encoding: .utf8)) ?? ""
        loaded = raw
        content = raw
    }

    private func save(overwrite: Bool, closing: Bool = false) {
        guard let path = selected, !saving else { return }
        let url = projectDir.appendingPathComponent(path)
        let disk = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !overwrite, disk != loaded {
            conflict = true
            return
        }
        saving = true
        let text = content
        Task {
            do {
                try await Task.detached { try text.write(to: url, atomically: true, encoding: .utf8) }.value
                loaded = text
                saving = false
                savedFeedback += 1
                onSaved(path)
                if closing { onDismiss() } else { show(String(localized: "Saved")) }
            } catch {
                saving = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func show(_ message: String) {
        notice = message
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if notice == message { notice = nil }
        }
    }

    private func isHighlightable(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "tsx" || ext == "ts" || ext == "jsx" || ext == "js"
    }
}
#endif
