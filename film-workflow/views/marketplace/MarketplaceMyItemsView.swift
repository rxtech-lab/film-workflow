import SwiftUI

/// The signed-in author's drafts and published items, filtered before pagination.
struct MarketplaceMyItemsView: View {
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

    private struct Request: Equatable {
        var page: Int
        var status: String?
        var query: String
        var refreshID: Int
    }

    private var request: Request {
        Request(page: number, status: status, query: query, refreshID: refreshID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("My Marketplace").font(.title2.bold())
                    Text("Manage your drafts and published items.").foregroundStyle(.secondary)
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
        .sheet(item: $selected, onDismiss: onItemsChanged) { item in
            MarketplaceAuthoringEditor(itemId: item.id)
        }
        .accessibilityIdentifier("marketplace-my-items-content")
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading your items…")
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
        return HStack(spacing: 12) {
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
            Button("Edit", systemImage: "pencil") { selected = value }
                .accessibilityIdentifier("marketplace-edit-\(value.id)")
            Button(published ? "Unpublish" : "Publish", systemImage: published ? "arrow.down.circle" : "arrow.up.circle") {
                changePublication(value)
            }
            .accessibilityIdentifier("marketplace-publish-\(value.id)")
        }
        .buttonStyle(.bordered)
        .disabled(busyItemID != nil)
        .padding(.vertical, 8)
    }

    private func load() async {
        let loading = request
        isLoading = true
        error = nil
        page = nil
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            if !loading.query.isEmpty { try await Task.sleep(for: .milliseconds(300)) }
            let result = try await service.list(page: loading.page, mine: true, status: loading.status, query: loading.query)
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
}
