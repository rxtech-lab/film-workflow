import SwiftData
import SwiftUI

/// Renders the same cross-type groups inside each project tab while filtering
/// the rows to that tab's project model.
struct GroupedProjectSections<Project, RowContent>: View
where Project: PersistentModel & GroupableProject & Identifiable, Project.ID: Hashable, RowContent: View {
    let projects: [Project]
    let groups: [ProjectGroup]
    let dragIdentifier: (Project) -> String
    let onMove: (Project, UUID?) -> Void
    let onCreateProject: (UUID?) -> Void
    let onCreateGroup: () -> Void
    let onRenameGroup: (ProjectGroup) -> Void
    let onDeleteGroup: (ProjectGroup) -> Void
    @ViewBuilder let rowContent: (Project) -> RowContent

    @State private var collapsedGroupIDs: Set<UUID> = []
    @State private var isUngroupedCollapsed = false

    var body: some View {
        Section {
            if !isUngroupedCollapsed {
                projectRows(projects.filter { $0.groupID == nil })
            }
        } header: {
            groupHeader(group: nil, count: projects.count { $0.groupID == nil })
        }

        ForEach(groups) { group in
            let groupedProjects = projects.filter { $0.groupID == group.id }
            Section {
                if !collapsedGroupIDs.contains(group.id) {
                    projectRows(groupedProjects)
                }
            } header: {
                groupHeader(group: group, count: groupedProjects.count)
            }
        }
    }

    @ViewBuilder
    private func projectRows(_ rows: [Project]) -> some View {
        if rows.isEmpty {
            Text("Drop projects here")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            ForEach(rows) { project in
                rowContent(project)
                    .draggable(dragToken(for: project))
            }
        }
    }

    private func groupHeader(group: ProjectGroup?, count: Int) -> some View {
        Button {
            toggleCollapsed(group)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed(group) ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 10)
                Image(systemName: group == nil
                    ? "tray"
                    : (isCollapsed(group) ? "folder" : "folder.fill"))
                Text(group?.name ?? String(localized: "Ungrouped"))
                Text("\(count)")
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dropDestination(for: String.self) { payloads, _ in
            move(payloads: payloads, to: group?.id)
        } isTargeted: { isTargeted in
            // The system's section-header drop highlight supplies the visual
            // feedback. Consuming the value here keeps the closure explicit.
            _ = isTargeted
        }
        .contextMenu {
            ProjectCreationMenuItems(
                onCreateProject: { onCreateProject(group?.id) },
                onCreateGroup: onCreateGroup
            )

            if let group {
                Divider()
                Button("Rename Group…") { onRenameGroup(group) }
                Divider()
                Button("Delete Group…", role: .destructive) { onDeleteGroup(group) }
            }
        }
    }

    private func isCollapsed(_ group: ProjectGroup?) -> Bool {
        if let group { return collapsedGroupIDs.contains(group.id) }
        return isUngroupedCollapsed
    }

    private func toggleCollapsed(_ group: ProjectGroup?) {
        withAnimation(.snappy(duration: 0.2)) {
            if let group {
                if collapsedGroupIDs.contains(group.id) {
                    collapsedGroupIDs.remove(group.id)
                } else {
                    collapsedGroupIDs.insert(group.id)
                }
            } else {
                isUngroupedCollapsed.toggle()
            }
        }
    }

    private func dragToken(for project: Project) -> String {
        "film-workflow-project:\(dragIdentifier(project))"
    }

    private func move(payloads: [String], to groupID: UUID?) -> Bool {
        var handled = false
        for payload in payloads {
            guard let project = projects.first(where: { dragToken(for: $0) == payload }) else {
                continue
            }
            onMove(project, groupID)
            handled = true
        }
        return handled
    }
}

struct ProjectCreationMenuItems: View {
    let onCreateProject: () -> Void
    let onCreateGroup: () -> Void

    var body: some View {
        Button(action: onCreateProject) {
            Label("New Project", systemImage: "plus")
        }
        Button(action: onCreateGroup) {
            Label("New Folder…", systemImage: "folder.badge.plus")
        }
    }
}

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
                Text("Groups are shared by Music, Narrative, Captions, Image, and Remotion projects.")
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
