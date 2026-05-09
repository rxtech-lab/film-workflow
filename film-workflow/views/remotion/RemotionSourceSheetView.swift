#if os(macOS)
import SwiftUI
import AppKit

struct RemotionSourceSheetView: View {
    let projectId: UUID
    /// Bumped by the parent whenever the agent writes a file — triggers a refresh of
    /// the file list and the currently-selected file's contents.
    let refreshToken: Int
    var onDismiss: () -> Void

    @State private var files: [String] = []
    @State private var selected: String?
    @State private var content: String = ""
    @State private var highlighted: AttributedString = AttributedString("")

    private var projectDir: URL {
        FileStorage.remotionProjectDir(id: projectId)
    }

    var body: some View {
        NavigationSplitView {
            List(files, id: \.self, selection: $selected) { path in
                Text(path)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .tag(path)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 380)
            .listStyle(.sidebar)
        } detail: {
            ScrollView([.vertical, .horizontal]) {
                Text(highlighted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .navigationTitle(selected ?? "Source")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { onDismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(content.isEmpty)
            }
        }
        .frame(minWidth: 880, minHeight: 560)
        .task(id: refreshToken) { reloadFiles() }
        .onChange(of: selected) { _, _ in loadContent() }
    }

    private func reloadFiles() {
        let listed = RemotionProjectFiles.list(projectDir: projectDir)
        files = listed
        if let current = selected, listed.contains(current) {
            // Same file still exists — just refresh contents.
            loadContent()
        } else {
            selected = listed.first(where: { $0 == "src/Composition.tsx" }) ?? listed.first
            loadContent()
        }
    }

    private func loadContent() {
        guard let path = selected else {
            content = ""
            highlighted = AttributedString("")
            return
        }
        let url = projectDir.appendingPathComponent(path)
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        content = raw
        highlighted = isHighlightable(path: path)
            ? TSXHighlighter.highlight(raw)
            : plainMonospaced(raw)
    }

    private func isHighlightable(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "tsx" || ext == "ts" || ext == "jsx" || ext == "js"
    }

    private func plainMonospaced(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        a.font = .system(.caption, design: .monospaced)
        a.foregroundColor = .primary
        return a
    }
}
#endif
