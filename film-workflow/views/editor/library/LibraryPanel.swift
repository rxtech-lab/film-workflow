import SwiftData
import SwiftUI
import VideoEditorCore

/// Left column: the grouped project list on top, the selected project's
/// footage underneath.
struct LibraryPanel: View {
    let index: LibraryIndex
    let groups: [ProjectGroup]
    @Bindable var state: EditorWindowState
    let document: ProjectDocument
    let onCreate: (FootageKind, UUID?) -> Void
    let onMove: (LibraryItemID, UUID?) -> Void
    let onImport: () -> Void
    let onCreateGroup: () -> Void
    let onRenameGroup: (ProjectGroup) -> Void
    let onDeleteGroup: (ProjectGroup) -> Void
    let onRename: (LibraryRow) -> Void
    let onDelete: (LibraryRow) -> Void
    let onShowVersions: (LibraryRow, UUID?) -> Void

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
                StudioPanelHeader(title: "Library", symbol: "sidebar.left")
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
                    onImport: onImport,
                    onCreateGroup: onCreateGroup,
                    onRenameGroup: onRenameGroup,
                    onDeleteGroup: onDeleteGroup,
                    onRename: onRename,
                    onDelete: onDelete,
                    onShowVersions: onShowVersions,
                    currentVersion: { currentVersion(for: $0) },
                    onSelectVersion: selectVersion,
                    dragPayload: dragPayload
                )
            }
            .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
            .background(PersistedPanelSplit(document: document, panel: .libraryRows))

            let cells = state.selection.map { index.footage(for: $0) } ?? []
            FootageBrowserView(
                libraryItem: state.selection,
                title: state.selection.flatMap { index.name(of: $0) } ?? "Footage",
                cells: cells,
                selectedID: state.selection.flatMap { currentVersion(for: $0) } ?? cells.first?.id,
                onSelect: { cell in
                    if let item = state.selection { state.setCurrentVersion(cell.id, for: item) }
                },
                onDeselect: { state.select(nil) }
            )
            .frame(maxWidth: .infinity, minHeight: 150, idealHeight: 200, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: rows.map(\.id)) { await warmDurations() }
        .contextMenu {
            Button(action: onImport) {
                Label("Import Media…", systemImage: "square.and.arrow.down")
            }
        }
    }

    /// The version in force for an item: the one chosen here, a caption
    /// project's active transcript, else the newest.
    private func currentVersion(for item: LibraryItemID) -> UUID? {
        if item.kind == .caption { return index.caption(item.id)?.activeVersionID }
        return state.currentVersion(for: item) ?? index.footage(for: item).first?.id
    }

    /// Versions that are footage become the preview and drag payload; a
    /// caption transcript is activated on the project; renders open the sheet.
    private func selectVersion(_ row: LibraryRow, _ versionID: UUID) {
        switch row.id.kind {
        case .music, .narration, .image, .video:
            state.setCurrentVersion(versionID, for: row.id)
        case .caption:
            if let p = index.caption(row.id.id) { _ = CaptionTranscriptionService.activateVersion(versionID, in: p) }
        case .sequence, .remotion, .imported:
            onShowVersions(row, versionID)
        }
    }

    private func dragPayload(for row: LibraryRow) -> FootageDragPayload? {
        let cells = index.footage(for: row.id)
        let cell = state.currentVersion(for: row.id).flatMap { id in cells.first { $0.id == id } } ?? cells.first
        guard let cell else { return row.dragItem.map { FootageDragPayload(item: $0, thumbnailURL: nil) } }
        var item = cell.drag
        if item.duration == nil, let url = cell.mediaURL, let cached = MediaDurationCache.cached(url) {
            item.duration = cached
        }
        return FootageDragPayload(item: item, thumbnailURL: cell.thumbnailURL)
    }

    /// Reads the length of every generated audio take once, so a row dragged
    /// straight from the list already knows how long it is.
    private func warmDurations() async {
        for row in rows where row.id.kind == .music || row.id.kind == .narration {
            for cell in index.footage(for: row.id) where cell.duration == nil {
                guard !Task.isCancelled, let url = cell.mediaURL else { return }
                _ = await MediaDurationCache.duration(of: url)
            }
        }
    }
}
