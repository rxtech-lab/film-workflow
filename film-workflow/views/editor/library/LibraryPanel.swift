import SwiftData
import SwiftUI

/// Left column: the grouped project list on top, the selected project's
/// footage underneath.
struct LibraryPanel: View {
    let index: LibraryIndex
    let groups: [ProjectGroup]
    @Bindable var state: EditorWindowState
    let onCreate: (FootageKind, UUID?) -> Void
    let onMove: (LibraryItemID, UUID?) -> Void
    let onCreateGroup: () -> Void
    let onRenameGroup: (ProjectGroup) -> Void
    let onDeleteGroup: (ProjectGroup) -> Void
    let onRename: (LibraryRow) -> Void
    let onDelete: (LibraryRow) -> Void

    @State private var filter: FootageKind?
    @State private var searchText = ""

    private var rows: [LibraryRow] {
        index.rows().filter { row in
            (filter == nil || row.id.kind == filter) &&
            (searchText.isEmpty || row.name.localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    TextField("Filter", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    Picker("Kind", selection: $filter) {
                        Text("All").tag(FootageKind?.none)
                        ForEach(FootageKind.allCases) { kind in
                            Label(kind.displayName, systemImage: kind.systemImage).tag(FootageKind?.some(kind))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 100)
                }
                .padding(8)
                LibraryList(
                    rows: rows,
                    groups: groups,
                    selection: Binding(get: { state.selection }, set: { state.select($0) }),
                    onMove: onMove,
                    onCreate: onCreate,
                    onCreateGroup: onCreateGroup,
                    onRenameGroup: onRenameGroup,
                    onDeleteGroup: onDeleteGroup,
                    onRename: onRename,
                    onDelete: onDelete
                )
            }
            .frame(minHeight: 160)
            .accountSidebarFooter()

            FootageBrowserView(
                title: state.selection.flatMap { index.name(of: $0) } ?? "Footage",
                cells: state.selection.map { index.footage(for: $0) } ?? []
            )
            .frame(minHeight: 120, idealHeight: 200)
        }
    }
}
