import SwiftData
import SwiftUI

/// Arms the removal of one take. The confirmation itself lives on whatever
/// draws the list — see `RecordingTakeRemovalConfirmation` — so a list of takes
/// asks the question once instead of once per row.
struct RecordingTakeRemoveButton: View {
    let take: RecordingTake
    @Binding var selection: RecordingTake?

    var body: some View {
        Button("Remove Take", systemImage: "trash", role: .destructive) {
            selection = take
        }
        .accessibilityLabel("Remove \(take.name)")
        .accessibilityIdentifier("recording.take.remove.\(take.id.uuidString)")
        .help("Remove this take from the library. Existing timeline clips keep working.")
    }
}

/// Asks before a take leaves the library, then removes it.
///
/// A modifier rather than logic inside the button because the versions sheet
/// offers the same command from a right-click menu: menu content is torn down
/// the moment it is picked, so the dialog has to live on the row that owns the
/// pending take, not on the button that set it.
struct RecordingTakeRemovalConfirmation: ViewModifier {
    @Binding var take: RecordingTake?

    @Environment(\.modelContext) private var context
    @Environment(\.undoManager) private var undoManager
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Remove this take?",
                isPresented: Binding(get: { take != nil }, set: { if !$0 { take = nil } }),
                titleVisibility: .visible,
                presenting: take
            ) { target in
                Button("Remove Take", role: .destructive) {
                    remove(target)
                    take = nil
                }
                Button("Cancel", role: .cancel) { take = nil }
            } message: { target in
                Text("“\(target.name)” leaves the library. Clips already on a timeline keep working, and Undo brings the take back.")
            }
            .alert("Couldn’t Remove Take", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }

    @MainActor
    private func remove(_ target: RecordingTake) {
        do { try RecordingTakeLibrary.remove(target, context: context, undoManager: undoManager) }
        catch { self.error = error.localizedDescription }
    }
}
