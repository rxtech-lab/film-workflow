import SwiftUI
import VideoEditorCore
import VideoEditorUI

/// One installed marketplace item as the library lists it: a value snapshot
/// of the manifest with the paths resolved, so the view needs no store access.
struct LibraryMarketplaceRow: Identifiable, Hashable {
    let id: String
    let kind: MarketplaceKind
    /// Footage only: whether the content file is a still or a clip. Nil from a
    /// manifest written before media types existed, where footage meant video.
    let mediaType: MarketplaceMediaType?
    let title: String
    let subtitle: String
    let previewURL: URL?
    let mediaURL: URL
    let duration: TimeInterval?
    let width: Int?
    let height: Int?
    let installedAt: Date

    init(manifest: InstalledMarketplaceManifest, directory: URL) {
        id = manifest.itemID
        kind = manifest.kind
        mediaType = manifest.metadata.footageMediaType
        title = manifest.title
        previewURL = manifest.previewURL(in: directory)
        mediaURL = manifest.contentURL(in: directory)
        duration = manifest.metadata.durationSeconds.flatMap { $0 > 0 ? $0 : nil }
        width = manifest.metadata.width.flatMap { $0 > 0 ? $0 : nil }
        height = manifest.metadata.height.flatMap { $0 > 0 ? $0 : nil }
        installedAt = manifest.installedAt
        var parts = [manifest.category]
        if let w = width, let h = height { parts.append("\(w)×\(h)") }
        subtitle = parts.joined(separator: " · ")
    }

    /// What the content file is, as the filmstrip and the viewer see it — the
    /// same reading `MarketplaceInstaller` gives it when the item joins a film.
    /// Nil when there is no media to play: a composition ships an archive of
    /// its project, and the global kinds ship no footage at all.
    var sourceKind: SourceKind? {
        switch kind {
        case .footage: return mediaType == .image ? .image : .video
        case .audio, .soundEffect: return .audio
        case .remotion, .font, .transition, .effect, .projectTemplate: return nil
        }
    }

    /// The installed file as a piece of footage, so the Marketplace tab
    /// previews and plays it exactly as the Library tab does its own.
    var footage: FootageCell? {
        guard let sourceKind else { return nil }
        return FootageCell(marketplaceItemID: id, title: title, subtitle: subtitle, kind: sourceKind,
                           mediaURL: mediaURL, thumbnailURL: previewURL, duration: duration,
                           width: width, height: height)
    }

    /// How the viewer shows this item. Marketplace content belongs to no film,
    /// so it has no library item to hang the preview off.
    var preview: MarketplacePreview? {
        footage.map { MarketplacePreview(rowID: id, name: title, cell: $0) }
    }

    /// Whether the card should draw a held frame rather than a strip: a still,
    /// or a composition whose content file is an archive rather than media.
    var isStill: Bool { kind == .remotion || (kind == .footage && mediaType == .image) }

    /// What the poster shows: the cached still, else a frame of the footage
    /// itself. Only a clip has frames to pull — never a still or an archive.
    var posterVideoURL: URL? { kind == .footage && mediaType != .image ? mediaURL : nil }

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
    /// The card the viewer is showing, so it reads as picked the way a
    /// library card does.
    var selectedID: String?
    /// Clears the preview when the click lands between the cards.
    var onDeselect: () -> Void = {}
    /// Drives the playhead the cards draw, shared with the viewer.
    var player: FootagePlayer?
    /// The card under the pointer and how far across it, or nil on the way out.
    var onSkim: (LibraryMarketplaceRow, Double?) -> Void = { _, _ in }
    /// A click: show this item in the viewer, at this point of its length.
    var onSeek: (LibraryMarketplaceRow, Double) -> Void = { _, _ in }

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
        .contentShape(Rectangle())
        .onTapGesture(perform: onDeselect)
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
                FootageFlowLayout {
                    ForEach(rows) { row in
                        rowView(row)
                    }
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
        LibraryMarketplaceCard(row: row, symbol: MarketplaceSymbol.resolve(taxonomy.presentation(for: row.kind).icon, fallback: row.kind.systemImage),
                               isSelected: row.id == selectedID, player: player,
                               onSkim: { onSkim(row, $0) }, onSeek: { onSeek(row, $0) })
            // Single-click previews, so adding to the film moves to the
            // double-click a library card has no use for.
            .onTapGesture(count: 2) { onAdd(row, nil) }
            // A still has no frame to seek to, so its filmstrip takes no
            // clicks; this is what puts one in the viewer.
            .onTapGesture { onSeek(row, 0) }
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

/// An installed item in the same frame as a library card, so the two tabs read
/// and behave alike: media plays under the pointer and seeks on a click, and
/// an item with no footage of its own — a composition's archive — holds its
/// poster instead.
struct LibraryMarketplaceCard: View {
    let row: LibraryMarketplaceRow
    /// The kind's symbol as the backend names it; nil falls back to the built-in one.
    var symbol: String?
    var isSelected = false
    var player: FootagePlayer?
    var onSkim: (Double?) -> Void = { _ in }
    var onSeek: (Double) -> Void = { _ in }

    /// Read off the file when the manifest carries no length, so a strip is
    /// as long as the take it shows.
    @State private var loadedDuration: TimeInterval?

    private var footage: FootageCell? { row.footage }
    private var duration: TimeInterval? { row.duration ?? loadedDuration }
    private var isTemporal: Bool { footage?.previewSource?.isTemporal == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let footage {
                FootageFilmstrip(cell: footage, duration: duration, isSelected: isSelected,
                                 player: player, onSkim: onSkim, onSeek: onSeek)
            } else {
                FootageThumbnail(thumbnailURL: row.previewURL, videoURL: row.posterVideoURL, icon: symbol ?? row.kind.systemImage,
                                 duration: row.duration, isStill: row.isStill, isSelected: isSelected)
                    .frame(width: FilmstripLayout.posterWidth, height: FilmstripLayout.height)
            }
            Text(row.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text(row.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 0,
               idealWidth: ceil(FilmstripLayout.preferredWidth(duration: duration, isTemporal: isTemporal)),
               maxWidth: .infinity, alignment: .leading)
        .padding(5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([row.title, duration.map(DurationLabel.short)].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
        .accessibilityIdentifier("library.marketplace.\(row.id)")
        .help(String(localized: "\(row.title)\n\(row.subtitle)\nClick to preview, double-click to add to this film."))
        .task(id: row.id) {
            loadedDuration = nil
            guard row.duration == nil, let kind = row.sourceKind, kind == .audio || kind == .video else { return }
            let result = await MediaDurationCache.duration(of: row.mediaURL)
            guard !Task.isCancelled else { return }
            loadedDuration = result
        }
    }
}
