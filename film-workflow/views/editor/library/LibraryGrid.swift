import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import VideoEditorCore
import VideoEditorUI

/// Collapsible folders containing duration-scaled, wrapping footage strips.
struct LibraryGrid: View {
    let rows: [LibraryRow]
    let groups: [ProjectGroup]
    @Binding var selection: LibraryItemID?
    let onMove: (LibraryItemID, UUID?) -> Void
    let onCreate: (FootageKind, UUID?) -> Void
    let onImport: () -> Void
    @Environment(\.openWindow) private var openWindow
    let onCreateGroup: () -> Void
    let onRenameGroup: (ProjectGroup) -> Void
    let onDeleteGroup: (ProjectGroup) -> Void
    let onRename: (LibraryRow) -> Void
    let onDelete: (LibraryRow) -> Void
    /// Exports a row's footage to a file on disk. Offered for Remotion rows.
    let onExport: (LibraryRow) -> Void
    /// Opens the versions sheet for a row, on one version or the whole list.
    let onShowVersions: (LibraryRow, UUID?) -> Void
    /// Creates the captions for a narration row and puts them on the timeline.
    var onCreateCaptions: (LibraryRow) -> Void = { _ in }
    /// The version a row currently previews and drags, if it has one.
    let currentVersion: (LibraryItemID) -> UUID?
    /// Makes a version the current one.
    let onSelectVersion: (LibraryRow, UUID) -> Void
    /// What a row drags: its current version as footage, with a thumbnail for the drag card.
    let dragPayload: (LibraryRow) -> FootageDragPayload?
    let footage: (LibraryItemID) -> FootageCell?
    var player: FootagePlayer?
    var onSkim: (LibraryItemID, FootageCell, Double?) -> Void = { _, _, _ in }
    var onSeek: (LibraryItemID, FootageCell, Double) -> Void = { _, _, _ in }

    @State private var collapsed: Set<UUID> = []
    @State private var ungroupedCollapsed = false
    /// Gates the marketplace actions: only an author can create drafts.
    /// `LibraryPanel` refreshes the flag.
    @State private var authoring = MarketplaceAuthoringService.shared
    @State private var authoringSeed: MarketplaceAuthoringSeed?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12, pinnedViews: [.sectionHeaders]) {
                section(group: nil, rows: rows.filter { $0.groupID == nil })
                ForEach(groups) { group in
                    section(group: group, rows: rows.filter { $0.groupID == group.id })
                }
            }
            .accessibilityElement(children: .contain)
            .padding(8)
        }
        .contentShape(Rectangle())
        .onTapGesture { selection = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.grid")
        .contextMenu {
            creationMenu(groupID: nil)
        }
        .sheet(item: $authoringSeed) { MarketplaceAuthoringEditor(seed: $0) }
    }

    @ViewBuilder
    private func section(group: ProjectGroup?, rows: [LibraryRow]) -> some View {
        Section {
            if !isCollapsed(group) {
                if rows.isEmpty {
                    Text("Drop footage here")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        .modifier(LibraryGroupDropTarget(groupID: group?.id, onMove: move))
                } else {
                    FootageFlowLayout {
                        ForEach(rows) { row in
                            rowView(row)
                        }
                    }
                }
            }
        } header: {
            header(group: group, count: rows.count)
        }
    }

    private func rowView(_ row: LibraryRow) -> some View {
        LibraryItemCard(row: row, footage: footage(row.id), payload: dragPayload(row), isSelected: selection == row.id,
                        player: player,
                        onSkim: { fraction in
                            if let cell = footage(row.id) { onSkim(row.id, cell, fraction) }
                        },
                        onSeek: { fraction in
                            if let cell = footage(row.id) { onSeek(row.id, cell, fraction) }
                        })
        .modifier(LibraryGroupDropTarget(groupID: row.groupID, onMove: move))
        .onTapGesture { selection = row.id }
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
            if selection != row.id { selection = row.id }
        })
        .accessibilityAction { selection = row.id }
        .contextMenu {
            versionsMenu(row)
            if row.id.kind == .narration {
                Button { onCreateCaptions(row) } label: {
                    Label("Create Captions", systemImage: "captions.bubble")
                }
                .help("Add captions for this narration to the timeline, ready to transcribe")
                Divider()
            }
            Button("Rename…") { onRename(row) }
            MoveToProjectGroupMenu(groups: groups, currentGroupID: row.groupID) { onMove(row.id, $0) }
            if row.id.kind == .remotion {
                Divider()
                Button { onExport(row) } label: { Label("Export…", systemImage: "square.and.arrow.down") }
            }
            if row.id.kind == .sequence, authoring.canAuthor {
                Divider()
                Button { createMarketplaceTemplate(from: row) } label: {
                    Label("Create Marketplace Template…", systemImage: "storefront")
                }
            }
            // Seeded from the version in force, which is the one the card shows.
            if authoring.canAuthor, let cell = footage(row.id),
               let seed = MarketplaceAuthoringSeed(title: row.name, sourceKind: cell.kind, file: cell.mediaURL) {
                Divider()
                Button { authoringSeed = seed } label: {
                    Label("Create Marketplace Item…", systemImage: "storefront")
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { onDelete(row) }
        }
    }

    /// Hands the sequence to the agent, which extracts it into a draft project
    /// template and generalizes it. The draft is never published from here.
    private func createMarketplaceTemplate(from row: LibraryRow) {
        MarketplaceAgentLauncher.start(
            title: row.name,
            instruction: """
                Create a marketplace project template from sequence \(row.id.id.uuidString) (“\(row.name)”) in my current film. \
                Extract it with project_template_from_film, then generalize the project prompt, video style, per-shot instructions \
                and footage requirements so it adapts to other footage. Update the draft, prepare a mock-image preview, and show it \
                to me. Keep it a draft until I ask for it to be published.
                """
        )
        openWindow(id: AgentWindowID.value)
    }

    /// Each version is a checkable item; the checked one is current.
    @ViewBuilder
    private func versionsMenu(_ row: LibraryRow) -> some View {
        if !row.versions.isEmpty {
            let current = currentVersion(row.id)
            Menu {
                ForEach(row.versions) { version in
                    Toggle(isOn: Binding(
                        get: { version.id == current },
                        set: { if $0 { onSelectVersion(row, version.id) } }
                    )) {
                        Text("\(version.label) · \(version.detail)")
                    }
                }
                Divider()
                Button("Show All Versions…") { onShowVersions(row, nil) }
            } label: {
                Label("Versions (\(row.versions.count))", systemImage: "square.stack")
            }
            Divider()
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
                Text(group?.name ?? String(localized: "Ungrouped")).lineLimit(1)
                Text("\(count)").foregroundStyle(.tertiary)
                Spacer()
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("library.folder.\(group?.id.uuidString ?? "ungrouped")")
        .modifier(LibraryGroupDropTarget(groupID: group?.id, onMove: move))
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
        Button(action: onImport) {
            Label("Import Media…", systemImage: "square.and.arrow.down")
        }
        Button { openWindow(id: MarketplaceWindowID.value) } label: {
            Label("From Marketplace…", systemImage: "storefront")
        }
        Divider()
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

    private func move(_ item: LibraryItemID, to groupID: UUID?) {
        onMove(item, groupID)
        if let groupID { collapsed.remove(groupID) } else { ungroupedCollapsed = false }
    }
}

/// The same drop area works on a group header, its rows and its empty state.
private struct LibraryGroupDropTarget: ViewModifier {
    let groupID: UUID?
    let onMove: (LibraryItemID, UUID?) -> Void
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(isTargeted ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .dropDestination(for: LibraryDragToken.self) { tokens, _ in
                for token in tokens { onMove(token.item, groupID) }
                return !tokens.isEmpty
            } isTargeted: { isTargeted = $0 }
    }
}

/// A row's current output as footage, plus the picture for the drag card.
struct FootageDragPayload {
    let item: FootageDragItem
    let thumbnailURL: URL?
}

/// Drag payload for moving a library item between groups. Footage rides
/// along the same drag through `timelineDraggable`.
struct LibraryDragToken: Codable, Transferable {
    let item: LibraryItemID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .rxLibraryItem)
    }
}

extension UTType {
    static let rxLibraryItem = UTType(exportedAs: "rxlab.film-workflow.library-item", conformingTo: .data)
}
