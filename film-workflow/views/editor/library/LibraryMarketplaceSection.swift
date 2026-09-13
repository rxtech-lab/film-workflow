import SwiftUI
import VideoEditorCore
import VideoEditorUI

/// One installed marketplace item as the library lists it: a value snapshot
/// of the manifest with the paths resolved, so the view needs no store access.
struct LibraryMarketplaceRow: Identifiable, Hashable {
    let id: String
    let kind: MarketplaceKind
    let title: String
    let subtitle: String
    let previewURL: URL?
    let mediaURL: URL
    let duration: TimeInterval?
    let installedAt: Date

    init(manifest: InstalledMarketplaceManifest, directory: URL) {
        id = manifest.itemID
        kind = manifest.kind
        title = manifest.title
        previewURL = manifest.previewURL(in: directory)
        mediaURL = manifest.contentURL(in: directory)
        duration = manifest.metadata.durationSeconds.flatMap { $0 > 0 ? $0 : nil }
        installedAt = manifest.installedAt
        var parts = [manifest.category]
        if let w = manifest.metadata.width, let h = manifest.metadata.height, w > 0, h > 0 { parts.append("\(w)×\(h)") }
        subtitle = parts.joined(separator: " · ")
    }

    /// What the poster shows: the cached still, else a frame of the footage itself.
    var posterVideoURL: URL? { kind == .footage ? mediaURL : nil }

    /// Rows that pass the panel's search field, in install order.
    static func rows(from manifests: [InstalledMarketplaceManifest], directory: (InstalledMarketplaceManifest) -> URL,
                     search: String) -> [LibraryMarketplaceRow] {
        manifests.map { LibraryMarketplaceRow(manifest: $0, directory: directory($0)) }.filter { row in
            search.isEmpty || row.title.localizedCaseInsensitiveContains(search)
        }
    }

    /// The kinds the Marketplace tab sections, in menu order.
    static let sectionKinds: [MarketplaceKind] = MarketplaceKind.allCases.filter(\.addsToFilm)
}

/// The library's Marketplace tab: everything installed from the marketplace
/// that a film can take in, one collapsible section per kind. Installed
/// items are shared by every film, so a card here is a source to add from,
/// not footage of this film; adding copies it in and the copy appears on
/// the Library tab.
struct LibraryMarketplaceGrid: View {
    let rows: [LibraryMarketplaceRow]
    let groups: [ProjectGroup]
    /// Section headings, as the backend names and draws each kind.
    var taxonomy: MarketplaceTaxonomy = .builtIn
    /// Adds the item to the film, into a folder or ungrouped.
    let onAdd: (LibraryMarketplaceRow, UUID?) -> Void
    let onReveal: (LibraryMarketplaceRow) -> Void
    let onOpenMarketplace: () -> Void

    @State private var collapsed: Set<MarketplaceKind> = []

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12, pinnedViews: [.sectionHeaders]) {
                if rows.isEmpty {
                    empty
                } else {
                    ForEach(LibraryMarketplaceRow.sectionKinds) { kind in
                        let kindRows = rows.filter { $0.kind == kind }
                        if !kindRows.isEmpty { section(kind: kind, rows: kindRows) }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .padding(8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.marketplace.grid")
        .contextMenu {
            Button(action: onOpenMarketplace) { Label("Open Marketplace…", systemImage: "storefront") }
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Nothing Installed", systemImage: "storefront")
        } description: {
            Text("Footage, music, sound effects and Remotion prompts you install from the Marketplace show up here, ready to add to any film.")
        } actions: {
            Button("Open Marketplace…", action: onOpenMarketplace)
        }
        .accessibilityIdentifier("library.marketplace.empty")
    }

    @ViewBuilder
    private func section(kind: MarketplaceKind, rows: [LibraryMarketplaceRow]) -> some View {
        Section {
            if !collapsed.contains(kind) {
                ForEach(rows) { row in
                    rowView(row)
                }
            }
        } header: {
            header(kind: kind, count: rows.count)
        }
    }

    private func header(kind: MarketplaceKind, count: Int) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                if collapsed.contains(kind) { collapsed.remove(kind) } else { collapsed.insert(kind) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed.contains(kind) ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 10)
                Image(systemName: MarketplaceSymbol.resolve(taxonomy.presentation(for: kind).icon, fallback: kind.systemImage))
                Text(taxonomy.presentation(for: kind).label).lineLimit(1)
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
        .accessibilityIdentifier("library.marketplace.section.\(kind.rawValue)")
    }

    private func rowView(_ row: LibraryMarketplaceRow) -> some View {
        LibraryMarketplaceCard(row: row, symbol: MarketplaceSymbol.resolve(taxonomy.presentation(for: row.kind).icon, fallback: row.kind.systemImage))
            .onTapGesture(count: 2) { onAdd(row, nil) }
            .accessibilityAction { onAdd(row, nil) }
            .contextMenu {
                Button { onAdd(row, nil) } label: { Label("Add to Film", systemImage: "plus.square.on.square") }
                if !groups.isEmpty {
                    Menu("Add to Folder") {
                        ForEach(groups) { group in
                            Button(group.name) { onAdd(row, group.id) }
                        }
                    }
                }
                Divider()
                Button { onReveal(row) } label: { Label("Reveal in Finder", systemImage: "folder") }
                Button(action: onOpenMarketplace) { Label("Show in Marketplace…", systemImage: "storefront") }
            }
    }
}

/// An installed item's poster, title and kind, in the same frame as a
/// library card so the two tabs read alike.
struct LibraryMarketplaceCard: View {
    let row: LibraryMarketplaceRow
    /// The kind's symbol as the backend names it; nil falls back to the built-in one.
    var symbol: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            FootageThumbnail(thumbnailURL: row.previewURL, videoURL: row.posterVideoURL, icon: symbol ?? row.kind.systemImage,
                             duration: row.duration, isStill: row.kind == .remotionPrompt)
                .frame(width: FilmstripLayout.posterWidth, height: FilmstripLayout.height)
            Text(row.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text(row.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([row.title, row.duration.map(DurationLabel.short)].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("library.marketplace.\(row.id)")
        .help(String(localized: "\(row.title)\n\(row.subtitle)\nDouble-click to add to this film."))
    }
}
