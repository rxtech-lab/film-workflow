import SwiftUI

/// The authoring list: the signed-in author's drafts and published items, or
/// every item this account may manage. Filtered before pagination.
///
/// Publishing and deleting live in each row's context menu rather than on the
/// row or inside the editor, so the list stays readable and a destructive
/// action is never one stray click away.
struct MarketplaceAuthoringListView: View {
    /// Whose items the list shows. The editor and the row actions are the same
    /// either way; only the request and the heading differ.
    enum Scope {
        case mine
        case all

        var title: LocalizedStringKey {
            switch self {
            case .mine: return "My Marketplace"
            case .all: return "Manage Items"
            }
        }

        var subtitle: LocalizedStringKey {
            switch self {
            case .mine: return "Your drafts and published items."
            case .all: return "Every marketplace item you can manage."
            }
        }
    }

    var scope: Scope = .mine
    var query: String
    var refreshID: Int
    var onCreate: () -> Void
    var onItemsChanged: () -> Void

    @State private var service = MarketplaceAuthoringService.shared
    @State private var page: MarketplaceAuthoringPage?
    @State private var number = 1
    @State private var status: String?
    @State private var isLoading = false
    @State private var error: String?
    @State private var selected: MarketplaceAuthoringItem?
    @State private var busyItemID: String?
    @State private var pendingDeletion: MarketplaceAuthoringItem?
    @State private var confirmingDeleteAgain = false

    private struct Request: Equatable {
        var page: Int
        var status: String?
        var query: String
        var refreshID: Int
        var mine: Bool
    }

    private var request: Request {
        Request(page: number, status: status, query: query, refreshID: refreshID, mine: scope == .mine)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(scope.title).font(.title2.bold())
                    Text(scope.subtitle).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Status", selection: $status) {
                    Text("All").tag(String?.none)
                    Text("Drafts").tag(String?.some("draft"))
                    Text("Published").tag(String?.some("published"))
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                .accessibilityIdentifier("marketplace-my-status")
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            content
        }
        .padding(16)
        .task(id: request) { await load() }
        .onChange(of: query) { number = 1 }
        .onChange(of: status) { number = 1 }
        .onChange(of: scope == .mine) { number = 1 }
        .sheet(item: $selected, onDismiss: onItemsChanged) { item in
            MarketplaceAuthoringEditor(itemId: item.id)
        }
        .confirmationDialog("Delete “\(pendingDeletion?.item.title ?? "")”?",
                            isPresented: Binding(get: { pendingDeletion != nil && !confirmingDeleteAgain },
                                                 set: { if !$0 && !confirmingDeleteAgain { pendingDeletion = nil } }),
                            titleVisibility: .visible) {
            Button("Delete…", role: .destructive) { confirmingDeleteAgain = true }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("This removes the item and everything uploaded for it from the marketplace.")
        }
        // Deleting takes the files with it, so it asks twice.
        .alert("Delete permanently?", isPresented: $confirmingDeleteAgain) {
            Button("Delete Permanently", role: .destructive) { deleteItem() }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("The item, its content file and its previews cannot be recovered.")
        }
        .accessibilityIdentifier("marketplace-my-items-content")
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading items…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let page, !page.items.isEmpty {
            List(page.items) { item in
                row(item)
            }
            .listStyle(.inset)
            if page.pageCount > 1 {
                HStack {
                    Button("Previous") { number = page.page - 1 }.disabled(page.page <= 1)
                    Spacer()
                    Text("Page \(page.page) of \(page.pageCount)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Next") { number = page.page + 1 }.disabled(page.page >= page.pageCount)
                }
            }
        } else if error != nil, page == nil {
            ContentUnavailableView {
                Label("Couldn’t load your items", systemImage: "wifi.exclamationmark")
            } actions: {
                Button("Try Again") { onItemsChanged() }
            }
        } else if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView {
                Label(status == "published" ? "No published items" : status == "draft" ? "No drafts" : "No marketplace items yet",
                      systemImage: "square.stack")
            } description: {
                Text("Create an item, prepare its content and previews, then publish it to the marketplace.")
            } actions: {
                Button("Create Item", systemImage: "plus", action: onCreate)
            }
        }
    }

    private func row(_ value: MarketplaceAuthoringItem) -> some View {
        let published = value.status == "published"
        return Button { selected = value } label: {
            HStack(spacing: 12) {
                Image(systemName: value.item.kind.systemImage)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        MarketplacePriceBadge(item: value.item)
                        Text(value.item.title).font(.headline).lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        Text(value.item.kind.displayName)
                        Text(published ? "Published" : "Draft")
                            .foregroundStyle(published ? Color.green : Color.orange)
                            .accessibilityIdentifier("marketplace-item-status-\(value.id)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if busyItemID == value.id { ProgressView().controlSize(.small) }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .disabled(busyItemID != nil)
        .contextMenu { menu(value) }
        .accessibilityIdentifier("marketplace-row-\(value.id)")
    }

    @ViewBuilder
    private func menu(_ value: MarketplaceAuthoringItem) -> some View {
        let published = value.status == "published"
        Button("Edit…", systemImage: "pencil") { selected = value }
            .accessibilityIdentifier("marketplace-edit-\(value.id)")
        Button(published ? "Unpublish" : "Publish", systemImage: published ? "arrow.down.circle" : "arrow.up.circle") {
            changePublication(value)
        }
        .accessibilityIdentifier("marketplace-publish-\(value.id)")
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { pendingDeletion = value }
            .accessibilityIdentifier("marketplace-delete-\(value.id)")
    }

    private func load() async {
        let loading = request
        isLoading = true
        error = nil
        page = nil
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            if !loading.query.isEmpty { try await Task.sleep(for: .milliseconds(300)) }
            let result = try await service.list(page: loading.page, mine: loading.mine, status: loading.status, query: loading.query)
            try Task.checkCancellation()
            guard loading == request else { return }
            page = result
        } catch {
            guard !Task.isCancelled, loading == request else { return }
            self.error = error.localizedDescription
        }
    }

    private func changePublication(_ value: MarketplaceAuthoringItem) {
        guard busyItemID == nil else { return }
        busyItemID = value.id
        error = nil
        Task {
            defer { busyItemID = nil }
            do {
                // A status change uses the saved content and its prepared preview.
                _ = try await service.publish(value.id, published: value.status != "published")
                onItemsChanged()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func deleteItem() {
        guard let value = pendingDeletion else { return }
        pendingDeletion = nil
        busyItemID = value.id
        error = nil
        Task {
            defer { busyItemID = nil }
            do {
                try await service.delete(value.id)
                onItemsChanged()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
