import SwiftUI

/// Reads the live catalog entry so ownership and installation stay current.
struct MarketplaceItemSheet: View {
    let itemID: String
    let store: MarketplaceStore
    let isSignedIn: Bool
    let hasActiveFilm: Bool
    let onAddToFilm: (MarketplaceItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let item = store.item(itemID) {
                MarketplaceItemDetail(item: item, store: store, isSignedIn: isSignedIn,
                                      hasActiveFilm: hasActiveFilm, onAddToFilm: { onAddToFilm(item) })
            } else {
                ContentUnavailableView("Item unavailable", systemImage: "storefront",
                                       description: Text("This item is no longer in the catalog."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background {
            Color(nsColor: .windowBackgroundColor)
                .overlay(alignment: .top) {
                    LinearGradient(colors: [.accentColor.opacity(0.08), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(height: 460)
                }
                .ignoresSafeArea()
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close item details")
            .accessibilityLabel("Close item details")
            .accessibilityIdentifier("marketplace-detail-done")
            .padding(28)
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 560, idealHeight: 740)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("marketplace-detail")
    }
}

/// An artwork-led page with controls floating above the scrolling content.
struct MarketplaceItemDetail: View {
    let item: MarketplaceItem
    let store: MarketplaceStore
    let isSignedIn: Bool
    let hasActiveFilm: Bool
    let onAddToFilm: () -> Void
    @State private var navigation = AppNavigation.shared
    @State private var templateDefinition: ProjectTemplateDefinition?
    @Environment(\.openWindow) private var openWindow

    private var isInstalled: Bool { store.isInstalled(item.id) }
    private var isBusy: Bool { store.busyItemIDs.contains(item.id) }
    private var progress: Double? { store.downloadProgress[item.id] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero
                VStack(alignment: .leading, spacing: 24) {
                    heading
                    if !item.description.isEmpty {
                        MarketplaceDescriptionSection(text: item.description)
                    }
                    facts
                    if let tags = item.metadata.tags, !tags.isEmpty {
                        FlowLayout(spacing: 8) {
                            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                                Text(tag)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(.primary.opacity(0.045), in: .capsule)
                            }
                        }
                    }
                    if item.kind == .projectTemplate {
                        MarketplaceTemplateSections(item: item, definition: templateDefinition)
                    }
                    if item.kind == .remotion, let excerpt = item.metadata.promptExcerpt, !excerpt.isEmpty {
                        MarketplacePromptSection(title: "Prompt preview", prompt: excerpt)
                    }
                    if isInstalled, !item.kind.installedHint.isEmpty {
                        Label(item.kind.installedHint, systemImage: "checkmark.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionBar
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .padding(.top, 8)
        }
        .task(id: isInstalled) {
            templateDefinition = nil
            if item.kind == .projectTemplate, let manifest = store.manifest(for: item.id) {
                templateDefinition = try? ProjectTemplateDefinition.decode(Data(contentsOf: manifest.contentURL(in: store.directory(for: manifest))))
            }
        }
    }

    private var hero: some View {
        Group {
            if item.kind == .audio || item.kind == .soundEffect {
                MarketplaceMusicPreview(item: item,
                    canPlay: item.previewVideoUrl != nil || isInstalled || (item.isEntitled && isSignedIn)) {
                    try await store.audioPreviewSource(for: item)
                }
            } else {
                MarketplacePreviewPlayer(item: item)
            }
        }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 24))
            .overlay {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                Label(store.label(for: item.kind), systemImage: store.symbol(for: item.kind))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .glassEffect(.regular, in: .capsule)
                    .padding(14)
                    .padding(.trailing, 58)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("marketplace-detail-preview")
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.categoryLabel)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(item.title)
                .font(.system(size: 30, weight: .semibold))
                .tracking(-0.6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    acquisitionSummary
                    Spacer(minLength: 12)
                    actionRow
                }
                VStack(alignment: .leading, spacing: 14) {
                    acquisitionSummary
                    actionRow
                }
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("marketplace-detail-actions")
    }

    private var acquisitionSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if isInstalled { Text("In your library") }
                else if item.owned && !item.isFree { Text("Purchased") }
                else if item.isFree { Text("Free") }
                else { Text("\(item.pricePoints.formatted()) credits") }
            }
            .font(.headline)
            if isInstalled, (item.kind.addsToFilm || item.kind == .projectTemplate), !hasActiveFilm {
                Text("Open a film to use this item")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !isInstalled {
                Text(item.isEntitled ? LocalizedStringKey("Install to your library") : LocalizedStringKey("Buy once, use in your films"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            if !isSignedIn && (!item.isFree || !isInstalled) {
                Button(item.isFree ? LocalizedStringKey("Sign In to Install") : LocalizedStringKey("Sign In to Buy")) { navigation.requestSignIn() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("marketplace-sign-in")
            } else if !item.isEntitled {
                Button { Task { await store.purchase(item) } } label: {
                    if isBusy { ProgressView().controlSize(.small) }
                    else { Text("Buy for \(item.pricePoints.formatted()) credits") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
                .accessibilityIdentifier("marketplace-buy")
            } else if let progress {
                ProgressView(value: progress) { Text("Downloading — \(Int(progress * 100))%") }
                    .frame(width: 200)
            } else if !isInstalled {
                Button { Task { await store.install(item) } } label: {
                    if isBusy { ProgressView().controlSize(.small) }
                    else { Label("Install", systemImage: "arrow.down") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
                .accessibilityIdentifier("marketplace-install")
            } else {
                Menu {
                    Button("Reveal in Finder") { store.revealInFinder(item.id) }
                    Button("Uninstall", role: .destructive) { store.uninstall(item.id) }
                } label: {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                }
                .fixedSize()
                .accessibilityIdentifier("marketplace-installed")
                if item.kind == .projectTemplate {
                    Button("Use in Current Film") {
                        MarketplaceAgentLauncher.start(item: item, instruction: "Use project template \(item.id) in my current film. Inspect my footage, show the template, collect missing footage, and create a new sequence.")
                        openWindow(id: AgentWindowID.value)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasActiveFilm)
                    .accessibilityIdentifier("marketplace-use-template")
                }
                if item.kind.addsToFilm {
                    Button("Add to Film", systemImage: "plus", action: onAddToFilm)
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasActiveFilm)
                        .help(hasActiveFilm ? "Add this item to the film in front" : "Open a film to add this item")
                        .accessibilityIdentifier("marketplace-add-to-film")
                }
            }
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var facts: some View {
        let rows = factRows
        if !rows.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 20) {
                ForEach(rows, id: \.label) { row in
                    VStack(alignment: .leading, spacing: 7) {
                        Label(row.label, systemImage: row.symbol)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(row.value)
                            .font(.callout.weight(.medium))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            .background(.primary.opacity(0.035), in: .rect(cornerRadius: 20))
        }
    }

    private var factRows: [(label: String, value: String, symbol: String)] {
        var rows: [(label: String, value: String, symbol: String)] = []
        if let seconds = item.metadata.durationSeconds, seconds > 0 {
            rows.append((String(localized: "Duration"), Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)), "clock"))
        }
        if let width = item.metadata.width, let height = item.metadata.height, width > 0, height > 0 {
            rows.append((String(localized: "Resolution"), "\(width) × \(height)", "arrow.up.left.and.arrow.down.right"))
        }
        if let family = item.metadata.fontFamily, !family.isEmpty {
            rows.append((String(localized: "Family"), family, "textformat"))
        }
        if let descriptor = item.metadata.descriptor {
            rows.append((String(localized: "Filter"), descriptor.filterName, "camera.filters"))
        }
        if let bytes = item.contentSizeBytes, bytes > 0 {
            rows.append((String(localized: "Download"), ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), "arrow.down.circle"))
        }
        return rows
    }
}
