import Foundation
import RxAgentSDK
import SwiftData
import SwiftUI

nonisolated struct MarketplaceCardPayload: Codable, Sendable {
    var marketplaceItem: MarketplaceItem
    var definition: ProjectTemplateDefinition?
    var status: String?
    var application: ProjectTemplateApplication?
    /// Absent on saved cards from before authoring controls were configurable.
    var showPublishButton: Bool?
    static func decode(_ raw: String?) -> Self? {
        guard let raw else { return nil }
        return decodeValue(raw, depth: 0)
    }
    private static func decodeValue(_ value: Any, depth: Int) -> Self? {
        guard depth < 6 else { return nil }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let text = value as? String, let data = text.data(using: .utf8) {
            if let card = try? decoder.decode(Self.self, from: data) { return card }
            if let nested = try? JSONSerialization.jsonObject(with: data) { return decodeValue(nested, depth: depth + 1) }
        } else if let object = value as? [String: Any] {
            if let data = try? JSONSerialization.data(withJSONObject: object), let card = try? decoder.decode(Self.self, from: data) { return card }
            for key in ["structuredContent", "content", "result", "text"] {
                if let nested = object[key], let card = decodeValue(nested, depth: depth + 1) { return card }
            }
        } else if let array = value as? [Any] {
            for nested in array { if let card = decodeValue(nested, depth: depth + 1) { return card } }
        }
        return nil
    }
}

@MainActor enum MarketplaceAgentLauncher {
    static func start(item: MarketplaceItem, instruction: String, document: ProjectDocument? = nil) {
        start(title: item.title, instruction: instruction, document: document)
    }

    /// Opens a thread for marketplace work that has no item yet, such as
    /// turning a sequence into a template draft.
    static func start(title: String, instruction: String, document: ProjectDocument? = nil) {
        let document = document ?? ProjectDocumentController.shared.activeDocument
        let context = AppModelContainer.shared.mainContext
        let thread = AgentThread(title: title)
        thread.documentID = document?.id; thread.documentPath = document?.packageURL.path
        context.insert(thread); try? context.save()
        AppNavigation.shared.pendingAgentThreadID = thread.id
        AgentController.shared.send(instruction: instruction, thread: thread, context: context, container: document?.container)
    }
}

struct MarketplaceTemplateDetails: View {
    let item: MarketplaceItem
    var definition: ProjectTemplateDefinition?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let prompt = definition?.prompt ?? item.metadata.promptExcerpt, !prompt.isEmpty {
                DisclosureGroup("Project prompt") { Text(prompt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
            let requirements = definition?.footageRequirements ?? item.metadata.template?.footageRequirements ?? []
            if !requirements.isEmpty {
                Text("Footage to provide").font(.headline)
                ForEach(requirements) { requirement in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(requirement.title).font(.subheadline.weight(.semibold))
                        Text("\(requirement.mediaType.capitalized) · \(requirement.required ? "Required" : "Optional")").font(.caption).foregroundStyle(.secondary)
                        Text(requirement.instructions).font(.callout).textSelection(.enabled)
                    }
                }
            }
            if let definition {
                DisclosureGroup("\(definition.shots.count) shots · \(definition.videoStyle)") {
                    ForEach(definition.shots) { shot in Text("\(shot.title) · \(shot.durationSeconds.formatted())s\n\(shot.instructions)").frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3) }
                    Text(definition.editingGuidance).font(.caption)
                }
            }
            let references = definition?.marketplaceItems ?? item.metadata.template?.marketplaceItems ?? []
            if !references.isEmpty {
                Text("Marketplace items").font(.headline)
                ForEach(references) { reference in MarketplaceDependencyRow(reference: reference) }
            }
        }
    }
}
struct MarketplaceDependencyRow: View {
    let reference: ProjectTemplateDefinition.Dependency
    @State private var item: MarketplaceItem?
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item?.title ?? reference.purpose)
                Spacer()
                if let item {
                    if item.isEntitled { Text(item.isFree ? "Free" : "Owned").foregroundStyle(.secondary) }
                    else { Button("Buy · \(item.pricePoints) credits") { Task { busy = true; _ = await MarketplaceStore.shared.purchase(item); self.item = try? await MarketplaceClient().item(item.id); busy = false } }.disabled(busy) }
                }
            }.font(.callout)
            Text(reference.purpose).font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task { do { item = try await MarketplaceClient().item(reference.itemId) } catch { self.error = "This item is unavailable." } }
    }
}

struct MarketplaceChatCard: View {
    let payload: MarketplaceCardPayload
    var showPublishButton = true
    @State private var current: MarketplaceItem?
    @State private var editing = false
    @State private var busy = false
    @State private var error: String?
    @State private var liveStatus: String?
    @State private var currentDefinition: ProjectTemplateDefinition?
    @Environment(\.openWindow) private var openWindow
    private var item: MarketplaceItem { current ?? payload.marketplaceItem }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MarketplacePreviewPlayer(item: item).aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
            HStack { Text(item.title).font(.headline); Spacer(); MarketplacePriceBadge(item: item) }
            if let status = liveStatus ?? payload.status { Label(status.capitalized, systemImage: status == "published" ? "checkmark.seal" : "square.and.pencil").font(.caption).foregroundStyle(.secondary) }
            Text(item.description).font(.callout).textSelection(.enabled)
            if item.kind == .projectTemplate { MarketplaceTemplateDetails(item: item, definition: currentDefinition ?? payload.definition) }
            if let application = payload.application {
                Label(application.state == "ready" ? "Sequence ready" : "Gathering footage", systemImage: "list.clipboard").font(.headline)
                ForEach(application.missingRequirements, id: \.self) { id in
                    if let requirement = application.template.footageRequirements.first(where: { $0.id == id }) { Text("Needed: \(requirement.title) — \(requirement.instructions)").font(.callout) }
                }
                ForEach(application.blockers, id: \.self) { Text($0).font(.callout).foregroundStyle(.orange) }
            }
            HStack {
                if showPublishButton && MarketplaceAuthoringService.shared.canAuthor {
                    Button("Edit") { editing = true }
                    Button((liveStatus ?? payload.status) == "published" ? "Unpublish" : "Publish") { action { let saved = try await MarketplaceAuthoringService.shared.publish(item.id, published: (liveStatus ?? payload.status) != "published"); current = saved.item; liveStatus = saved.status } }
                }
                if (liveStatus ?? payload.status ?? "published") == "published" {
                if !item.isEntitled { Button("Buy · \(item.pricePoints) credits") { action { _ = await MarketplaceStore.shared.purchase(item); current = try await MarketplaceClient().item(item.id) } } }
                else if item.kind == .projectTemplate {
                    Button("Use in Current Film") { MarketplaceAgentLauncher.start(item: item, instruction: "Apply marketplace project template \(item.id) to the current film. Inspect the existing footage, show the template card, collect missing requirements, and build a new sequence."); openWindow(id: AgentWindowID.value) }
                        .disabled(ProjectDocumentController.shared.activeDocument == nil)
                } else { Button("Install") { action { _ = await MarketplaceStore.shared.install(item) } } }
                }
                if busy { ProgressView().controlSize(.small) }
            }.disabled(busy)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
        }
        .padding(14).frame(maxWidth: 520, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("marketplace-chat-card")
        .task { await refresh() }
        .sheet(isPresented: $editing, onDismiss: { Task { await refresh() } }) { MarketplaceAuthoringEditor(itemId: item.id) }
    }
    private func refresh() async {
        if await MarketplaceAuthoringService.shared.refreshAccess(), let fresh = try? await MarketplaceAuthoringService.shared.get(item.id) {
            current = fresh.item; currentDefinition = fresh.template; liveStatus = fresh.status
        } else if let fresh = try? await MarketplaceClient().item(item.id) { current = fresh }
    }
    private func action(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true; error = nil
        Task { do { try await work() } catch { self.error = error.localizedDescription }; busy = false }
    }
}
