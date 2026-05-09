#if os(macOS)
import SwiftUI
import AppKit

struct RemotionSourceSheetView: View {
    let source: String
    var onDismiss: () -> Void

    @State private var highlighted: AttributedString = AttributedString("")

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                Text(highlighted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .task(id: source) {
                highlighted = TSXHighlighter.highlight(source)
            }
            .navigationTitle("Composition.tsx")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(source, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}
#endif
