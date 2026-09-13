import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import VideoEditorCore

struct MarketplaceManageItems: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page: MarketplaceAuthoringPage?
    @State private var error: String?
    @State private var selected: MarketplaceAuthoringItem?
    @State private var creating = false
    @State private var number = 1
    var body: some View {
        VStack(spacing: 12) {
            HStack { Text("Manage Marketplace Items").font(.title2); Spacer(); Button("Create Item", systemImage: "plus") { creating = true }; Button("Done") { dismiss() } }
            if let error { Text(error).foregroundStyle(.red) }
            List(page?.items ?? []) { draft in
                Button { selected = draft } label: {
                    HStack { Label(draft.item.title, systemImage: draft.item.kind.systemImage); Spacer(); Text(draft.status.capitalized).foregroundStyle(.secondary); MarketplacePriceBadge(item: draft.item) }
                }.buttonStyle(.plain)
            }
            HStack { Button("Previous") { number -= 1 }.disabled(number <= 1); Spacer(); Text("Page \(number)"); Spacer(); Button("Next") { number += 1 }.disabled(number >= (page?.pageCount ?? 1)) }
        }.padding().frame(width: 700, height: 520)
        .task(id: number) { await load() }
        .sheet(item: $selected, onDismiss: { Task { await load() } }) { item in MarketplaceAuthoringEditor(itemId: item.id) }
        .sheet(isPresented: $creating, onDismiss: { Task { await load() } }) { MarketplaceAuthoringEditor() }
        .accessibilityIdentifier("marketplace-manage-items")
    }
    private func load() async { do { page = try await MarketplaceAuthoringService.shared.list(page: number); error = nil } catch { self.error = error.localizedDescription } }
}

/// Create or edit one marketplace item.
///
/// The fields come from the backend's form schema, the same one the website's
/// admin form renders, so the two never drift. Nothing is drawn until that
/// schema and the item have landed.
struct MarketplaceAuthoringEditor: View {
    var itemId: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var service = MarketplaceAuthoringService.shared
    @State private var input = MarketplaceItemInput()
    @State private var draft: MarketplaceAuthoringItem?
    @State private var definition = ProjectTemplateDefinition()
    @State private var contentText = ""
    @State private var categories: [MarketplaceCategory] = []
    @State private var schema: MarketplaceFormSchema?
    @State private var newCategory = ""
    @State private var newCategoryIcon = ""
    @State private var addingCategory = false
    @State private var error: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var mock = false
    @State private var previewStart: Double = 0
    @State private var previewDuration: Double = 15
    @State private var generationPrompt = ""
    @State private var choosingFilmAsset = false
    @State private var generationKind: String?
    @State private var confirmingDelete = false
    @State private var confirmingDeleteAgain = false

    /// Every job of this draft, finished ones included: their states drive the
    /// refresh below, so an upload that lands updates the previews.
    private var operations: [MarketplaceAuthoringJob] { service.jobs.values.filter { $0.itemId == draft?.id }.sorted { $0.updatedAt > $1.updatedAt } }
    private var operationStates: String { operations.map { "\($0.id):\($0.state)" }.sorted().joined(separator: ",") }
    /// Only work still in flight is shown; a finished job speaks through the item itself.
    private var running: [MarketplaceAuthoringJob] { operations.filter { !$0.isFinished } }
    private var layout: MarketplaceFormSchema.KindLayout? { schema?.layout(for: input.kind) }
    private var canSave: Bool { !busy && !input.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !input.categoryId.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 600, idealHeight: 780)
        .task { await load() }
        .onChange(of: input.kind) { chooseCategory() }
        .onChange(of: operationStates) { Task { if let id = draft?.id, let fresh = try? await service.get(id) { draft = fresh } } }
        .sheet(isPresented: $addingCategory) { categorySheet }
        .sheet(isPresented: $choosingFilmAsset) { MarketplaceFilmAssetPicker { source, document in
            choosingFilmAsset = false
            run {
                let saved = try await save()
                let resolver = DocumentMediaResolver(document: document, width: 1920, height: 1080, fps: 30)
                guard let file = try await resolver.resolve(source).fileURL else { throw MarketplaceAuthoringError.invalid("Select a playable asset.") }
                draft = try await service.upload(itemId: saved.id, role: "content", file: file)
            }
        } }
        .sheet(isPresented: Binding(get: { generationKind != nil }, set: { if !$0 { generationKind = nil } })) { generationSheet }
        .confirmationDialog("Delete “\(input.title)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete…", role: .destructive) { confirmingDeleteAgain = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the item and everything uploaded for it from the marketplace.")
        }
        // Deleting takes the files with it, so it asks twice.
        .alert("Delete permanently?", isPresented: $confirmingDeleteAgain) {
            Button("Delete Permanently", role: .destructive) { deleteDraft() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The item, its content file and its previews cannot be recovered.")
        }
        .accessibilityIdentifier("marketplace-author-editor")
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Text(draft == nil ? "Create Marketplace Item" : "Edit Marketplace Item").font(.title2)
            Spacer()
            Button("Done") { dismiss() }
            if draft != nil {
                Button("Delete", role: .destructive) { confirmingDelete = true }
                    .disabled(busy)
                    .accessibilityIdentifier("marketplace-author-delete")
            }
            Button("Save Draft") { run { _ = try await save(); notice = "Draft saved" } }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(schema == nil || !canSave)
            if let draft {
                Button(draft.status == "published" ? "Unpublish" : "Publish") {
                    run {
                        let publishing = draft.status != "published"
                        let saved = try await save()
                        self.draft = try await service.publish(saved.id, published: publishing)
                        notice = self.draft?.status == "published" ? "Published to Marketplace" : "Unpublished"
                    }
                }.disabled(busy || schema == nil)
            }
        }.padding()
    }

    @ViewBuilder
    private var content: some View {
        if let schema {
            form(schema)
        } else if let error {
            ContentUnavailableView {
                Label("Couldn’t open the editor", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else {
            ProgressView("Loading the form…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Form

    private func form(_ schema: MarketplaceFormSchema) -> some View {
        Form {
            if error != nil || notice != nil {
                Section {
                    if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
                    if let notice { Text(notice).foregroundStyle(.secondary) }
                }
            }
            if let draft {
                Section {
                    MarketplacePreviewPlayer(item: draft.item)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            ForEach(schema.sections) { section in
                Section(section.title) {
                    if let help = section.help { Text(help).font(.caption).foregroundStyle(.secondary) }
                    ForEach(schema.fields(section, for: input.kind)) { field in row(field) }
                }
            }
            if let layout {
                contentSection(layout)
                previewSection(layout)
            }
            agentSection
            if !running.isEmpty {
                Section("In progress") {
                    ForEach(running) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.message).font(.callout)
                            ProgressView(value: job.progress)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(busy)
    }

    /// One schema field. The schema names it and says what it accepts; this
    /// only picks the control, and skips anything it has no binding for.
    @ViewBuilder
    private func row(_ field: MarketplaceFormSchema.Field) -> some View {
        if field.id == "categoryId" {
            categoryRow(field)
        } else if let value = binding(for: field) {
            VStack(alignment: .leading, spacing: 4) {
                // Applied to a Group, the identifier lands on the control itself.
                Group {
                    switch field.type {
                    case .select:
                        Picker(field.title, selection: value) {
                            ForEach(field.options ?? [], id: \.value) { option in Text(option.label).tag(option.value) }
                        }
                        .disabled(field.lockedWhenSaved == true && draft != nil)
                    case .multiline:
                        TextField(field.title, text: value, axis: .vertical).lineLimit(2...6)
                    case .toggle:
                        Toggle(field.title, isOn: Binding(get: { value.wrappedValue == "true" }, set: { value.wrappedValue = $0 ? "true" : "false" }))
                    case .text, .tags, .number:
                        TextField(field.title, text: value, prompt: field.placeholder.map(Text.init))
                    }
                }
                .accessibilityIdentifier("marketplace-author-\(field.id.replacingOccurrences(of: ".", with: "-"))")
                if let help = field.help { Text(help).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder
    private func categoryRow(_ field: MarketplaceFormSchema.Field) -> some View {
        Picker(field.title, selection: $input.categoryId) {
            Text("Choose a category").tag("")
            ForEach(categories.filter { $0.kind == input.kind }) { category in Text(category.name).tag(category.id) }
        }
        Button("New Category…") { addingCategory = true }
    }

    @ViewBuilder
    private func contentSection(_ layout: MarketplaceFormSchema.KindLayout) -> some View {
        Section(layout.content.title) {
            switch layout.content.editor {
            case .template:
                MarketplaceTemplateEditor(definition: $definition)
            case .descriptor:
                MarketplaceModifierEditor(kind: input.kind, text: $contentText)
            case .text:
                TextEditor(text: $contentText).frame(minHeight: 160).border(.quaternary)
            case .upload:
                if let filename = draft?.item.contentFilename { LabeledContent("File", value: filename) }
            }
            HStack {
                Button("Choose File…") { selectFile(role: "content") }
                if layout.filmAsset {
                    Button("Use Film Footage…") { choosingFilmAsset = true }
                        .disabled(ProjectDocumentController.shared.activeDocument == nil)
                }
                ForEach(layout.generators.filter { $0 != .image }, id: \.self) { generator in
                    Button(generator.title) { generationKind = generator.rawValue; generationPrompt = input.description }
                }
            }
            Text(layout.content.hint).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func previewSection(_ layout: MarketplaceFormSchema.KindLayout) -> some View {
        Section("Previews") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Button("Choose Cover…") { selectFile(role: "preview-image") }
                    if layout.generators.contains(.image) {
                        Button("Generate Cover…") { generationKind = "image"; generationPrompt = "Cover art for \(input.title). \(input.description)" }
                    }
                }
                Text(layout.previewImage.hint).font(.caption).foregroundStyle(.secondary)
            }
            if let video = layout.previewVideo {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Button("Choose Preview Video…") { selectFile(role: "preview-video") }
                        TextField("Start seconds", value: $previewStart, format: .number).frame(width: 110)
                        TextField("Length seconds", value: $previewDuration, format: .number).frame(width: 110)
                        Button("Generate Preview") { generatePreview(layout) }
                    }
                    Text(video.hint).font(.caption).foregroundStyle(.secondary)
                }
                if layout.mockPreview {
                    Toggle("Uploaded preview uses mock images, without original project footage", isOn: $mock)
                }
            }
        }
    }

    private var agentSection: some View {
        Section {
            Button("Continue with Agent", systemImage: "bubble.left.and.bubble.right") {
                askAgent("Help me finish this marketplace draft. Read and show it, prepare missing content and previews, and keep it as a draft until I request publishing.")
            }
            if input.kind == .projectTemplate, ProjectDocumentController.shared.activeDocument != nil {
                Button("Create from Current Film with Agent") {
                    askAgent("Inspect my film and selected sequence. Turn it into an adaptable project template with generalized prompt, style, shots, footage instructions and marketplace references. Update this draft and prepare a mock-image preview.")
                }
            }
        }
    }

    private var categorySheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Category").font(.headline)
            Text("Categories belong to one kind, so this one only shows up for \(layout?.label ?? input.kind.displayName).").font(.caption).foregroundStyle(.secondary)
            TextField("Name", text: $newCategory)
            TextField("Icon", text: $newCategoryIcon)
                .help("SF Symbol for the sidebar row, e.g. music.note. Blank uses a folder.")
            HStack {
                Button("Cancel") { addingCategory = false }
                Spacer()
                Button("Add") {
                    addingCategory = false
                    run {
                        let category = try await service.createCategory(kind: input.kind, name: newCategory, icon: newCategoryIcon)
                        categories.append(category)
                        input.categoryId = category.id
                        newCategory = ""; newCategoryIcon = ""
                    }
                }.disabled(newCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding().frame(width: 420).textFieldStyle(.roundedBorder)
    }

    private var generationSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Describe what to generate").font(.headline)
            TextEditor(text: $generationPrompt).frame(height: 140).border(.quaternary)
            HStack {
                Button("Cancel") { generationKind = nil }
                Spacer()
                Button("Generate") {
                    let kind = generationKind ?? "image"
                    generationKind = nil
                    run { let saved = try await save(); _ = try await service.startGeneration(itemId: saved.id, kind: kind, prompt: generationPrompt) }
                }.disabled(generationPrompt.isEmpty)
            }
        }.padding().frame(width: 500)
    }

    // MARK: - Values

    /// Maps a schema field id onto the input it edits. An id this build does
    /// not know returns nil, and the field is left out rather than drawn dead.
    private func binding(for field: MarketplaceFormSchema.Field) -> Binding<String>? {
        switch field.id {
        case "kind":
            return Binding(get: { input.kind.rawValue }, set: { if let kind = MarketplaceKind(rawValue: $0) { input.kind = kind } })
        case "title": return $input.title
        case "description": return $input.description
        case "pricePoints":
            return Binding(get: { String(input.pricePoints) }, set: { input.pricePoints = Int($0.filter(\.isNumber)) ?? 0 })
        case "metadata.tags":
            return Binding(get: { input.metadata.tags?.joined(separator: ", ") ?? "" },
                           set: { input.metadata.tags = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } })
        case "metadata.fontFamily":
            return Binding(get: { input.metadata.fontFamily ?? "" }, set: { input.metadata.fontFamily = $0.isEmpty ? nil : $0 })
        default: return nil
        }
    }

    // MARK: - Work

    private func load() async {
        error = nil
        if input.draftId == nil { input.draftId = UUID().uuidString }
        do {
            _ = try await service.requireAdmin()
            async let form = service.schema()
            async let all = service.categories()
            let (schema, categories) = try await (form, all)
            self.schema = schema
            self.categories = categories
            if let itemId {
                load(try await service.get(itemId))
                _ = try? service.savedJobs(itemId: itemId)
            }
            chooseCategory()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func chooseCategory() {
        if !categories.contains(where: { $0.id == input.categoryId && $0.kind == input.kind }) {
            input.categoryId = categories.first { $0.kind == input.kind }?.id ?? ""
        }
    }

    private func load(_ value: MarketplaceAuthoringItem) {
        draft = value
        input = .init(value)
        contentText = value.contentText ?? ""
        definition = value.template ?? .init()
        mock = value.item.metadata.preview?.mock ?? false
    }

    private func save() async throws -> MarketplaceAuthoringItem {
        let content: String? = switch layout?.content.editor ?? .upload {
        case .template: try definition.json()
        case .descriptor, .text: contentText.isEmpty ? nil : contentText
        case .upload: nil
        }
        let value = try await service.save(input, id: draft?.id, content: content)
        draft = value
        return value
    }

    private func deleteDraft() {
        guard let id = draft?.id else { return }
        run {
            try await service.delete(id)
            dismiss()
        }
    }

    private func generatePreview(_ layout: MarketplaceFormSchema.KindLayout) {
        if layout.content.editor == .text {
            askAgent("Create a mock demonstration from this item's actual content, render it inside marketplace_workspace, then generate and upload its preview.")
        } else {
            run { let saved = try await save(); _ = try await service.startPreview(itemId: saved.id, start: previewStart, duration: previewDuration) }
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true
        error = nil
        Task { do { try await work() } catch { self.error = error.localizedDescription }; busy = false }
    }

    private func askAgent(_ instruction: String) {
        run {
            let saved = try await save()
            MarketplaceAgentLauncher.start(item: saved.item, instruction: "Marketplace item \(saved.id). \(instruction)")
            openWindow(id: AgentWindowID.value)
        }
    }

    private func selectFile(role: String) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = role == "preview-image" ? [.image] : role == "preview-video" ? [.movie] : [.data]
        guard panel.runModal() == .OK, let file = panel.url else { return }
        if role == "preview-video", layout?.mockPreview == true, !mock { error = "Confirm that this uploaded preview uses mock images first."; return }
        let editor = layout?.content.editor ?? .upload
        run {
            if role == "content", editor != .upload {
                let text = try String(contentsOf: file, encoding: .utf8)
                if editor == .template { definition = try ProjectTemplateDefinition.decode(Data(text.utf8)) } else { contentText = text }
                _ = try await save()
            } else {
                let saved = try await save()
                draft = try await service.upload(itemId: saved.id, role: role, file: file, mock: mock)
            }
        }
    }
}

private struct MarketplaceFilmAssetPicker: View {
    var onSelect: (ClipSource, ProjectDocument) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row] = []
    @State private var error: String?
    struct Row: Identifiable { var id: String; var name: String; var source: ClipSource; var document: ProjectDocument }
    var body: some View {
        VStack { HStack { Text("Choose Film Footage").font(.headline); Spacer(); Button("Cancel") { dismiss() } }; if let error { Text(error).foregroundStyle(.red) }; List(rows) { row in Button(row.name) { onSelect(row.source, row.document) } } }
            .padding().frame(width: 500, height: 400)
            .task {
                guard let document = ProjectDocumentController.shared.activeDocument else { return }
                do {
                    let result = try await MCPLibraryHandlers.handle(name: "footage_list", arguments: [:], context: document.container.mainContext)
                    let items = (result["structuredContent"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
                    rows = items.compactMap { item in guard let id = item["sourceId"] as? String, let source = try? ProjectTemplateService.source(id, document: document), source.kind != .captions else { return nil }; return Row(id: id, name: item["name"] as? String ?? "Footage", source: source, document: document) }
                } catch { self.error = error.localizedDescription }
            }
    }
}
