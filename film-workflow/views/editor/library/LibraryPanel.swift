import AppKit
import SwiftData
import SwiftUI
import VideoEditorCore

/// Left column: folders of footage cards on top, the selected project's
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
    let onExport: (LibraryRow) -> Void
    let onShowVersions: (LibraryRow, UUID?) -> Void
    /// Backs the Marketplace tab. Nil hides the tab.
    var marketplace: MarketplaceStore? = .shared

    @Environment(\.openWindow) private var openWindow
    @State private var tab: LibraryTab = .library
    @State private var filter: FootageKind?
    @State private var searchText = ""
    @State private var marketplaceError: String?
    @FocusState private var filterFocused: Bool
    /// Set once the user toggles the pane; until then the document's saved state applies.
    @State private var footageToggled: Bool?

    private var footageVisible: Bool { footageToggled ?? document.panelLayout.footageBrowserVisible ?? true }

    private var rows: [LibraryRow] {
        index.rows().filter { row in
            (filter == nil || row.id.kind == filter) &&
            (searchText.isEmpty || row.name.localizedCaseInsensitiveContains(searchText))
        }
    }

    private var marketplaceRows: [LibraryMarketplaceRow] {
        guard let marketplace else { return [] }
        return LibraryMarketplaceRow.rows(from: marketplace.libraryItems, directory: marketplace.directory(for:), search: searchText)
    }

    var body: some View {
        LibraryFootageSplit(document: document, footageVisible: footageVisible) {
            VStack(spacing: 0) {
                StudioPanelHeader(title: "Library", symbol: "sidebar.left") {
                    if marketplace != nil {
                        Picker("Show", selection: $tab) {
                            ForEach(LibraryTab.allCases) { tab in
                                Text(tab.title).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("library.tab")
                    }
                }
                .simultaneousGesture(TapGesture().onEnded { dismissTextFieldFocus() })
                HStack(spacing: 6) {
                    TextField("Filter", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .focused($filterFocused)
                        .onExitCommand { filterFocused = false }
                    // Marketplace items are sectioned by kind already.
                    if tab == .library {
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
                }
                .padding(8)
                Group {
                    switch tab {
                    case .library: libraryGrid
                    case .marketplace:
                        LibraryMarketplaceGrid(rows: marketplaceRows, groups: groups, taxonomy: marketplace?.taxonomy ?? .builtIn,
                                               onAdd: addMarketplaceItem,
                                               onReveal: { marketplace?.revealInFinder($0.id) },
                                               onOpenMarketplace: { openWindow(id: MarketplaceWindowID.value) })
                            .task { await marketplace?.loadTaxonomy() }
                    }
                }
                // Clicking away from the filter gives up the caret, the way it
                // does for a field elsewhere on macOS. Simultaneous so the
                // grid's own selection and drag gestures still see the click.
                .simultaneousGesture(TapGesture().onEnded { dismissTextFieldFocus() })
            }
            .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
        } footage: {
            footageBrowser
                .simultaneousGesture(TapGesture().onEnded { dismissTextFieldFocus() })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: rows.map(\.id)) { await warmDurations() }
        // A new window's initial focus goes to its first text field, which puts
        // the caret in this filter before anyone asked for it. Handing it back
        // leaves the panel unfocused without disabling the field — a click into
        // it still focuses normally.
        //
        // Watched for a moment rather than checked once: that focus is assigned
        // as the window becomes key, which can land either side of this view's
        // appearance. The window is short enough that it can't catch a real
        // click, and it closes as soon as focus has been handed back.
        .task {
            for _ in 0..<5 {
                if filterFocused {
                    filterFocused = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        .contextMenu {
            Button(action: onImport) {
                Label("Import Media…", systemImage: "square.and.arrow.down")
            }
            Button { openWindow(id: MarketplaceWindowID.value) } label: {
                Label("From Marketplace…", systemImage: "storefront")
            }
        }
        .alert("Couldn’t Add to Film", isPresented: Binding(get: { marketplaceError != nil }, set: { if !$0 { marketplaceError = nil } })) {
            Button("OK") { marketplaceError = nil }
        } message: {
            Text(marketplaceError ?? "")
        }
    }

    /// Hands back the caret when the user clicks in the library.
    ///
    /// Clearing `filterFocused` only covers this panel's own field, and the
    /// field the user was typing in is often somewhere else — an inspector, an
    /// inline rename — so the window's first responder goes too. Only when it
    /// is text being edited: anything else there (the timeline, a list) is
    /// holding key handling the click should leave alone.
    private func dismissTextFieldFocus() {
        filterFocused = false
        let window = NSApp.keyWindow
        // Anything editing text is an input client — the field editor a
        // TextField types into, and SwiftUI's own text views, whose classes
        // are not public.
        guard let responder = window?.firstResponder, responder is any NSTextInputClient else { return }
        window?.makeFirstResponder(nil)
    }

    private var libraryGrid: some View {
        LibraryGrid(
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
            onExport: onExport,
            onShowVersions: onShowVersions,
            currentVersion: { currentVersion(for: $0) },
            onSelectVersion: selectVersion,
            dragPayload: dragPayload,
            footage: currentFootage,
            player: state.footagePlayer,
            onSkim: { item, cell, fraction in
                if let fraction { state.skimFootage(item, cellID: cell.id, fraction: fraction) }
                else { state.endFootageSkim() }
            },
            onSeek: { item, cell, fraction in state.seekFootage(item, cellID: cell.id, fraction: fraction) }
        )
    }

    @ViewBuilder
    private var footageBrowser: some View {
    let cells = state.selection.map { index.footage(for: $0) } ?? []
    FootageBrowserView(
        libraryItem: state.selection,
        title: state.selection.flatMap { index.name(of: $0) } ?? "Footage",
        cells: cells,
        selectedID: state.selection.flatMap { currentVersion(for: $0) } ?? cells.first?.id,
        onSelect: { cell in
            if let item = state.selection { state.setCurrentVersion(cell.id, for: item) }
        },
        onDeselect: { state.select(nil) },
        player: state.footagePlayer,
        onSkim: { cell, fraction in
            if let fraction, let item = state.selection {
                state.skimFootage(item, cellID: cell.id, fraction: fraction)
            } else {
                state.endFootageSkim()
            }
        },
        onSeek: { cell, fraction in
            if let item = state.selection { state.seekFootage(item, cellID: cell.id, fraction: fraction) }
        },
        isExpanded: footageVisible,
        onToggle: toggleFootage
    )
    }

    /// Copies an installed marketplace item into this film, switches to the
    /// Library tab and selects the copy, so it is previewed and ready to drag.
    private func addMarketplaceItem(_ row: LibraryMarketplaceRow, groupID: UUID?) {
        guard let marketplace, let manifest = marketplace.manifest(for: row.id) else {
            marketplaceError = MarketplaceError.notInstalled.errorDescription
            return
        }
        Task {
            do {
                let added = try await MarketplaceInstaller.addToFilm(manifest, contentURL: row.mediaURL, document: document, groupID: groupID)
                tab = .library
                state.select(added)
            } catch {
                marketplaceError = error.localizedDescription
            }
        }
    }

    private func toggleFootage() {
        let visible = !footageVisible
        footageToggled = visible
        document.setFootageBrowserVisible(visible)
    }

    /// The version in force for an item: the one chosen here, a caption
    /// project's active transcript, else the newest.
    private func currentVersion(for item: LibraryItemID) -> UUID? {
        if item.kind == .caption { return index.caption(item.id)?.activeVersionID }
        return state.currentVersion(for: item) ?? index.footage(for: item).first?.id
    }

    /// Versions that are footage become the preview and drag payload; a
    /// caption transcript is activated on the project; sequence renders, which
    /// the footage strip does not list, open the sheet.
    private func selectVersion(_ row: LibraryRow, _ versionID: UUID) {
        switch row.id.kind {
        case .music, .narration, .image, .video, .remotion:
            state.setCurrentVersion(versionID, for: row.id)
        case .caption:
            if let p = index.caption(row.id.id) { _ = CaptionTranscriptionService.activateVersion(versionID, in: p) }
        case .sequence, .imported:
            onShowVersions(row, versionID)
        }
    }

    private func dragPayload(for row: LibraryRow) -> FootageDragPayload? {
        let cell = currentFootage(for: row.id)
        guard let cell else { return row.dragItem.map { FootageDragPayload(item: $0, thumbnailURL: nil) } }
        var item = cell.drag
        if item.duration == nil, let url = cell.mediaURL, let cached = MediaDurationCache.cached(url) {
            item.duration = cached
        }
        return FootageDragPayload(item: item, thumbnailURL: cell.thumbnailURL)
    }

    private func currentFootage(for item: LibraryItemID) -> FootageCell? {
        let cells = index.footage(for: item)
        return currentVersion(for: item).flatMap { id in cells.first { $0.id == id } } ?? cells.first
    }

    /// Reads the length of every generated audio take once, so a row dragged
    /// straight from the grid already knows how long it is.
    private func warmDurations() async {
        for row in rows where row.id.kind == .music || row.id.kind == .narration {
            for cell in index.footage(for: row.id) where cell.duration == nil {
                guard !Task.isCancelled, let url = cell.mediaURL else { return }
                _ = await MediaDurationCache.duration(of: url)
            }
        }
    }
}

/// What the library panel lists: this film's footage, or what is installed
/// from the marketplace and can be added to it.
enum LibraryTab: String, CaseIterable, Identifiable {
    case library
    case marketplace

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .library: return "Library"
        case .marketplace: return "Marketplace"
        }
    }
}
