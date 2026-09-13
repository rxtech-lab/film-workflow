import SwiftUI
import VideoEffectsCore
import VideoEffectsUI

struct MarketplaceTemplateEditor: View {
    @Binding var definition: ProjectTemplateDefinition
    @State private var choosingDependency = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Project prompt").font(.headline)
            TextEditor(text: $definition.prompt).frame(minHeight: 90).border(.quaternary).accessibilityIdentifier("template-prompt")
            TextField("Video style", text: $definition.videoStyle, axis: .vertical).lineLimit(2...5)
            TextField("Editing guidance", text: $definition.editingGuidance, axis: .vertical).lineLimit(2...5)
            HStack {
                TextField("Width", value: $definition.width, format: .number).frame(width: 110)
                Text("×")
                TextField("Height", value: $definition.height, format: .number).frame(width: 110)
                TextField("FPS", value: $definition.fps, format: .number).frame(width: 90)
            }
            ForEach($definition.shots) { $shot in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Shot title", text: $shot.title)
                        TextField("Shot direction and framing", text: $shot.instructions, axis: .vertical).lineLimit(2...4)
                        HStack {
                            TextField("Suggested seconds", value: $shot.durationSeconds, format: .number).frame(width: 120)
                            Text("seconds").foregroundStyle(.secondary)
                            Spacer()
                            Button("Move Up", systemImage: "arrow.up") { move(shot.id, offset: -1) }
                            Button("Move Down", systemImage: "arrow.down") { move(shot.id, offset: 1) }
                            Button("Remove", systemImage: "trash", role: .destructive) { remove(shot.id) }
                        }.labelStyle(.iconOnly)
                        Picker("Footage", selection: Binding(get: { shot.footageRequirementId ?? "" }, set: { shot.footageRequirementId = $0.isEmpty ? nil : $0; if !$0.isEmpty { shot.marketplaceItemId = nil } })) {
                            Text("Marketplace source").tag("")
                            ForEach(definition.footageRequirements) { r in Text(r.title).tag(r.id) }
                        }
                        if shot.footageRequirementId == nil {
                            Picker("Marketplace source", selection: Binding(get: { shot.marketplaceItemId ?? "" }, set: { shot.marketplaceItemId = $0.isEmpty ? nil : $0 })) {
                                Text("Choose an item").tag("")
                                ForEach(definition.marketplaceItems) { item in Text(item.purpose).tag(item.itemId) }
                            }
                        }
                        Picker("Transition to next shot", selection: Binding(get: { shot.transition?.modifierId ?? "" }, set: { id in shot.transition = id.isEmpty ? nil : .init(modifierId: id, parameters: ModifierCatalog.current.transition(id)?.defaults ?? [:], durationSeconds: 0.5); includeDependency(id) })) {
                            Text("Cut").tag("")
                            ForEach(ModifierCatalog.current.transitions, id: \.id) { transition in Text(transition.name).tag(transition.id) }
                        }
                        if let transition = shot.transition, let modifier = ModifierCatalog.current.transition(transition.modifierId) {
                            TextField("Transition seconds", value: Binding(get: { shot.transition?.durationSeconds ?? 0.5 }, set: { shot.transition?.durationSeconds = $0 }), format: .number)
                            ModifierParameterEditor(definition: modifier, parameters: Binding(get: { shot.transition?.parameters ?? [:] }, set: { shot.transition?.parameters = $0 }))
                        }
                        Menu("Add effect") {
                            ForEach(ModifierCatalog.current.effects, id: \.id) { effect in
                                Button(effect.name) { shot.effects.append(.init(modifierId: effect.id, parameters: effect.defaults)); includeDependency(effect.id) }
                            }
                        }
                        ForEach(Array(shot.effects.enumerated()), id: \.offset) { index, effect in
                            HStack { Text(ModifierCatalog.current.effect(effect.modifierId)?.name ?? effect.modifierId); Spacer(); Button("Remove effect") { shot.effects.remove(at: index) } }.font(.caption)
                            if let modifier = ModifierCatalog.current.effect(effect.modifierId) {
                                ModifierParameterEditor(definition: modifier, parameters: Binding(get: { shot.effects[index].parameters }, set: { shot.effects[index].parameters = $0 }))
                            }
                        }
                    }
                } label: { Text(shot.title) }
            }
            Button("Add Shot", systemImage: "plus") {
                let id = UUID().uuidString, title = "Shot \(definition.shots.count + 1)"
                definition.footageRequirements.append(.init(id: id, title: title))
                definition.shots.append(.init(id: id, title: title, footageRequirementId: id))
            }.accessibilityIdentifier("template-add-shot")
            Text("Footage the user should provide").font(.headline)
            ForEach($definition.footageRequirements) { $requirement in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Footage title", text: $requirement.title)
                        Picker("Media", selection: $requirement.mediaType) { Text("Video").tag("video"); Text("Image").tag("image"); Text("Audio").tag("audio") }
                        Toggle("Required", isOn: $requirement.required)
                        TextField("What to provide, how to frame it, and what should happen", text: $requirement.instructions, axis: .vertical).lineLimit(2...5)
                    }
                }
            }
            Text("Marketplace items").font(.headline)
            ForEach($definition.marketplaceItems) { $reference in
                HStack {
                    TextField("How this item is used", text: $reference.purpose)
                    Toggle("Required", isOn: $reference.required)
                    Button("Remove", systemImage: "minus.circle") { definition.marketplaceItems.removeAll { $0.itemId == reference.itemId } }.labelStyle(.iconOnly)
                }
            }
            Button("Add Marketplace Item", systemImage: "plus") { choosingDependency = true }
            Text("Users purchase missing paid items separately.").font(.caption).foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .sheet(isPresented: $choosingDependency) {
            MarketplaceAssetPicker { item in
                if !definition.marketplaceItems.contains(where: { $0.itemId == item.id }) { definition.marketplaceItems.append(.init(itemId: item.id, purpose: item.title)) }
                choosingDependency = false
            }
        }
    }
    private func includeDependency(_ modifierId: String) {
        for manifest in MarketplaceStore.shared.installed.values where manifest.kind == .effect || manifest.kind == .transition {
            let url = manifest.contentURL(in: MarketplaceStore.shared.directory(for: manifest))
            guard let descriptor = try? InstalledModifierLoader.descriptor(at: url, expecting: manifest.kind), descriptor.id == modifierId else { continue }
            if !definition.marketplaceItems.contains(where: { $0.itemId == manifest.itemID }) { definition.marketplaceItems.append(.init(itemId: manifest.itemID, purpose: manifest.title)) }
        }
    }
    private func move(_ id: String, offset: Int) {
        guard let index = definition.shots.firstIndex(where: { $0.id == id }), definition.shots.indices.contains(index + offset) else { return }
        definition.shots.swapAt(index, index + offset)
    }
    private func remove(_ id: String) {
        let requirement = definition.shots.first { $0.id == id }?.footageRequirementId
        definition.shots.removeAll { $0.id == id }
        if let requirement, !definition.shots.contains(where: { $0.footageRequirementId == requirement }) { definition.footageRequirements.removeAll { $0.id == requirement } }
    }
}

struct MarketplaceAssetPicker: View {
    var onSelect: (MarketplaceItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var page: MarketplaceCatalogPage?
    @State private var error: String?
    @State private var requestedPage = 1
    var body: some View {
        VStack {
            HStack { Text("Choose a Marketplace Item").font(.headline); Spacer(); Button("Done") { dismiss() } }
            TextField("Search items", text: $query).textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(.red) }
            List(page?.items.filter { $0.kind != .projectTemplate } ?? []) { item in
                Button { onSelect(item) } label: {
                    HStack { Label(item.title, systemImage: item.kind.systemImage); Spacer(); MarketplacePriceBadge(item: item) }
                }.buttonStyle(.plain)
            }
            HStack { Button("Previous") { requestedPage -= 1 }.disabled(requestedPage <= 1); Spacer(); Button("Next") { requestedPage += 1 }.disabled(requestedPage >= (page?.pageCount ?? 1)) }
        }.padding().frame(width: 520, height: 450)
        .task(id: "\(query):\(requestedPage)") {
            do { try await Task.sleep(for: .milliseconds(250)); page = try await MarketplaceClient().items(kind: nil, category: nil, query: query, page: requestedPage); error = nil }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
        .onChange(of: query) { requestedPage = 1 }
    }
}
