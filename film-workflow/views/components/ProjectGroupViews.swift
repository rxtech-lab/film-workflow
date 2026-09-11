import SwiftData
import SwiftUI

/// Shared context-menu affordance used by every project type.
struct MoveToProjectGroupMenu: View {
    let groups: [ProjectGroup]
    let currentGroupID: UUID?
    let onMove: (UUID?) -> Void

    var body: some View {
        Menu {
            Button {
                onMove(nil)
            } label: {
                groupLabel("Ungrouped", selected: currentGroupID == nil)
            }

            if !groups.isEmpty {
                Divider()
                ForEach(groups) { group in
                    Button {
                        onMove(group.id)
                    } label: {
                        groupLabel(group.name, selected: currentGroupID == group.id)
                    }
                }
            }
        } label: {
            Label("Move to Group", systemImage: "folder")
        }
    }

    private func groupLabel(_ name: String, selected: Bool) -> some View {
        Label(name, systemImage: selected ? "checkmark" : "folder")
    }
}

struct ProjectGroupEditorTarget: Identifiable {
    let id = UUID()
    let group: ProjectGroup?

    static var create: ProjectGroupEditorTarget { ProjectGroupEditorTarget(group: nil) }
    static func rename(_ group: ProjectGroup) -> ProjectGroupEditorTarget {
        ProjectGroupEditorTarget(group: group)
    }
}

private struct ProjectGroupDialogsModifier: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    @Binding var editor: ProjectGroupEditorTarget?
    @Binding var name: String
    @Binding var pendingDeletion: ProjectGroup?
    @Binding var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .alert(
                editor?.group == nil ? "New Project Group" : "Rename Project Group",
                isPresented: Binding(
                    get: { editor != nil },
                    set: { if !$0 { editor = nil } }
                )
            ) {
                TextField("Group name", text: $name)
                Button("Cancel", role: .cancel) { editor = nil }
                Button(editor?.group == nil ? "Create" : "Rename") { submitEditor() }
            } message: {
                Text("Groups hold every kind of footage and sequences.")
            }
            .confirmationDialog(
                "Delete this project group?",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDeletion
            ) { group in
                Button("Delete Group", role: .destructive) { delete(group) }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: { group in
                Text("\"\(group.name)\" will be deleted. Its projects will be kept and moved to Ungrouped.")
            }
            .alert(
                "Couldn’t Update Project Groups",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "An unknown error occurred.")
            }
    }

    private func submitEditor() {
        guard let target = editor else { return }
        do {
            if let group = target.group {
                try ProjectGroupService.rename(group, to: name, context: modelContext)
            } else {
                _ = try ProjectGroupService.create(name: name, context: modelContext)
            }
            editor = nil
        } catch {
            editor = nil
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ group: ProjectGroup) {
        do {
            try ProjectGroupService.delete(group, context: modelContext)
            pendingDeletion = nil
        } catch {
            pendingDeletion = nil
            errorMessage = error.localizedDescription
        }
    }
}

extension View {
    func projectGroupDialogs(
        editor: Binding<ProjectGroupEditorTarget?>,
        name: Binding<String>,
        pendingDeletion: Binding<ProjectGroup?>,
        errorMessage: Binding<String?>
    ) -> some View {
        modifier(ProjectGroupDialogsModifier(
            editor: editor,
            name: name,
            pendingDeletion: pendingDeletion,
            errorMessage: errorMessage
        ))
    }
}
