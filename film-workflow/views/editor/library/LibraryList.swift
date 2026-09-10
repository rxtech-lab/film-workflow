import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import VideoEditorCore

/// Groups and their projects of every kind, with drag-to-regroup.
struct LibraryList: View {
    let rows: [LibraryRow]
    let groups: [ProjectGroup]
    @Binding var selection: LibraryItemID?
    let onMove: (LibraryItemID, UUID?) -> Void
    let onCreate: (FootageKind, UUID?) -> Void
    let onCreateGroup: () -> Void
    let onRenameGroup: (ProjectGroup) -> Void
    let onDeleteGroup: (ProjectGroup) -> Void
    let onRename: (LibraryRow) -> Void
    let onDelete: (LibraryRow) -> Void

    @State private var collapsed: Set<UUID> = []
    @State private var ungroupedCollapsed = false

    var body: some View {
        List(selection: $selection) {
            section(group: nil, rows: rows.filter { $0.groupID == nil })
            ForEach(groups) { group in
                section(group: group, rows: rows.filter { $0.groupID == group.id })
            }
        }
        .listStyle(.sidebar)
        .contextMenu {
            creationMenu(groupID: nil)
        }
    }

    @ViewBuilder
    private func section(group: ProjectGroup?, rows: [LibraryRow]) -> some View {
        Section {
            if !isCollapsed(group) {
                if rows.isEmpty {
                    Text("Drop footage here")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(rows) { row in
                        rowView(row)
                            .tag(row.id)
                            .draggable(LibraryDragToken(item: row.id))
                    }
                }
            }
        } header: {
            header(group: group, count: rows.count)
        }
    }

    private func rowView(_ row: LibraryRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.id.kind.systemImage)
                .foregroundStyle(row.id.kind == .sequence ? Color.accentColor : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).lineLimit(1)
                Text(row.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 1)
        .contextMenu {
            creationMenu(groupID: row.groupID)
            Divider()
            Button("Rename…") { onRename(row) }
            MoveToProjectGroupMenu(groups: groups, currentGroupID: row.groupID) { onMove(row.id, $0) }
            Divider()
            Button("Delete…", role: .destructive) { onDelete(row) }
        }
    }

    private func header(group: ProjectGroup?, count: Int) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                if let group {
                    if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
                } else {
                    ungroupedCollapsed.toggle()
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed(group) ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 10)
                Image(systemName: group == nil ? "tray" : (isCollapsed(group) ? "folder" : "folder.fill"))
                Text(group?.name ?? String(localized: "Ungrouped"))
                Text("\(count)").foregroundStyle(.tertiary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dropDestination(for: LibraryDragToken.self) { tokens, _ in
            for token in tokens { onMove(token.item, group?.id) }
            return !tokens.isEmpty
        }
        .contextMenu {
            creationMenu(groupID: group?.id)
            if let group {
                Divider()
                Button("Rename Group…") { onRenameGroup(group) }
                Divider()
                Button("Delete Group…", role: .destructive) { onDeleteGroup(group) }
            }
        }
    }

    @ViewBuilder
    private func creationMenu(groupID: UUID?) -> some View {
        Menu("New") {
            ForEach(FootageKind.creatable) { kind in
                Button { onCreate(kind, groupID) } label: { Label(kind.displayName, systemImage: kind.systemImage) }
            }
        }
        Button { onCreateGroup() } label: { Label("New Folder…", systemImage: "folder.badge.plus") }
    }

    private func isCollapsed(_ group: ProjectGroup?) -> Bool {
        group.map { collapsed.contains($0.id) } ?? ungroupedCollapsed
    }
}

/// Drag payload for moving a library item between groups.
struct LibraryDragToken: Codable, Transferable {
    let item: LibraryItemID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .rxLibraryItem)
    }
}

extension UTType {
    static let rxLibraryItem = UTType(exportedAs: "rxlab.film-workflow.library-item", conformingTo: .data)
}
