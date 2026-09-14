import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import VideoEditorCore

/// What a library take seeds a new marketplace draft with: the item it should
/// become, and the file that becomes its content the first time it is saved.
struct MarketplaceAuthoringSeed: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var kind: MarketplaceKind
    var contentFile: URL
}

/// Create or edit one marketplace item.
///
/// The fields come from the backend's form schema, the same one the website's
/// admin form renders, so the two never drift. Nothing is drawn until that
/// schema and the item have landed.
struct MarketplaceAuthoringEditor: View {
    var itemId: String?
    /// Set when the editor was opened from footage rather than from the
    /// marketplace window. Only ever read for a new item.
    var seed: MarketplaceAuthoringSeed?
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
    /// A file waiting to become this item's content. It cannot be uploaded
    /// before the draft exists, so it rides along with the first save.
    @State private var stagedContent: URL?

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
            Divider()
            footer
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
        .accessibilityIdentifier("marketplace-author-editor")
    }

    // MARK: - Chrome

    /// Identity, not actions: what is being edited and what state it is in.
    /// Publishing and deleting belong to the item's row in the authoring list.
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: input.kind.systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Text(layout?.label ?? input.kind.displayName)
                    if let draft {
                        Text("\u{00B7}")
                        Text(draft.status == "published" ? "Published" : "Draft")
                            .foregroundStyle(draft.status == "published" ? Color.green : Color.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var headerTitle: String {
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return draft == nil ? String(localized: "New Marketplace Item") : String(localized: "Untitled Item")
    }

    /// One place for progress and the last message, so the form itself never
    /// jumps as a save succeeds or fails.
    private var footer: some View {
        HStack(spacing: 10) {
            if busy { ProgressView().controlSize(.small) }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(2)
            } else if let notice {
                Label(notice, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save Draft") { run { _ = try await save(); notice = "Draft saved" } }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(schema == nil || !canSave)
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
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
            if let draft { heroSection(draft) }
            ForEach(schema.sections) { section in
                Section {
                    ForEach(schema.fields(section, for: input.kind)) { field in row(field) }
                } header: {
                    Text(section.title)
                } footer: {
                    if let help = section.help { hint(help) }
                }
            }
            if let layout {
                contentSection(layout)
                previewSection(layout)
            }
            if !running.isEmpty {
                Section("In Progress") {
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

    /// The listing as buyers see it, edge to edge above the fields, so the
    /// effect of every upload below is visible without leaving the sheet.
    private func heroSection(_ draft: MarketplaceAuthoringItem) -> some View {
        Section {
            MarketplacePreviewPlayer(item: draft.item)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        } footer: {
            hint(draft.item.previewImageUrl == nil
                 ? String(localized: "No cover art yet. Buyers see the placeholder above until one is uploaded.")
                 : String(localized: "How this item appears in the catalog."))
        }
    }

    /// Secondary explanatory copy, used for every section footer and field help
    /// so the form has one voice.
    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
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
                        TextField(field.title, text: value, axis: .vertical)
                            .lineLimit(3...8)
                    case .toggle:
                        Toggle(field.title, isOn: Binding(get: { value.wrappedValue == "true" }, set: { value.wrappedValue = $0 ? "true" : "false" }))
                    case .text, .tags, .number:
                        TextField(field.title, text: value, prompt: field.placeholder.map(Text.init))
                    }
                }
                .accessibilityIdentifier("marketplace-author-\(field.id.replacingOccurrences(of: ".", with: "-"))")
                if let help = field.help { hint(help) }
            }
        }
    }

    /// The category picker, with its own escape hatch for a kind that has none
    /// yet, so a first item never dead-ends on a missing category.
    @ViewBuilder
    private func categoryRow(_ field: MarketplaceFormSchema.Field) -> some View {
        let available = categories.filter { $0.kind == input.kind }
        VStack(alignment: .leading, spacing: 6) {
            Picker(field.title, selection: $input.categoryId) {
                Text("Choose a category").tag("")
                ForEach(available) { category in Text(category.name).tag(category.id) }
            }
            HStack {
                Spacer()
                Button("New Category\u{2026}", systemImage: "folder.badge.plus") { addingCategory = true }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            if available.isEmpty { hint(String(localized: "This kind has no categories yet. Add one to continue.")) }
        }
    }

    @ViewBuilder
    private func contentSection(_ layout: MarketplaceFormSchema.KindLayout) -> some View {
        Section {
            switch layout.content.editor {
            case .template:
                MarketplaceTemplateEditor(definition: $definition)
            case .descriptor:
                MarketplaceModifierEditor(kind: input.kind, text: $contentText)
            case .text:
                TextEditor(text: $contentText)
                    .font(.body.monospaced())
                    .frame(minHeight: 160)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            case .upload:
                LabeledContent("File") {
                    if let filename = draft?.item.contentFilename {
                        Text(filename).lineLimit(1).truncationMode(.middle)
                    } else if let stagedContent {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(stagedContent.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            hint(String(localized: "Uploads when you save the draft."))
                        }
                    } else {
                        Text("Nothing uploaded yet").foregroundStyle(.secondary)
                    }
                }
            }
            actionRow {
                Button("Choose File…", systemImage: "folder") { selectFile(role: "content") }
                if layout.filmAsset {
                    Button("Use Film Footage…", systemImage: "film") { choosingFilmAsset = true }
                        .disabled(ProjectDocumentController.shared.activeDocument == nil)
                }
                ForEach(layout.generators.filter { $0 != .image }, id: \.self) { generator in
                    Button(generator.title, systemImage: "sparkles") { generationKind = generator.rawValue; generationPrompt = input.description }
                }
            }
        } header: {
            Text(layout.content.title)
        } footer: {
            hint(layout.content.hint)
        }
    }

    /// The small bordered buttons a file slot offers, kept on one line and
    /// aligned with the fields above them.
    private func actionRow(@ViewBuilder _ buttons: () -> some View) -> some View {
        HStack(spacing: 8) {
            buttons()
            Spacer(minLength: 0)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private func previewSection(_ layout: MarketplaceFormSchema.KindLayout) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Cover") {
                    Text(draft?.item.previewImageUrl == nil ? "Not set" : "Uploaded")
                        .foregroundStyle(draft?.item.previewImageUrl == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                }
                actionRow {
                    Button("Choose Cover…", systemImage: "photo") { selectFile(role: "preview-image") }
                    if layout.generators.contains(.image) {
                        Button("Generate Cover…", systemImage: "sparkles") {
                            generationKind = "image"
                            generationPrompt = "Cover art for \(input.title). \(input.description)"
                        }
                    }
                }
                hint(layout.previewImage.hint)
            }
            if let video = layout.previewVideo {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Video") {
                        Text(draft?.item.previewVideoUrl == nil ? "Not set" : "Uploaded")
                            .foregroundStyle(draft?.item.previewVideoUrl == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    }
                    // Both fields drive the rendered preview, so they sit
                    // together rather than beside the buttons that use them.
                    HStack(spacing: 14) {
                        LabeledContent("Start") {
                            TextField("Start seconds", value: $previewStart, format: .number)
                                .labelsHidden()
                                .frame(width: 70)
                        }
                        LabeledContent("Length") {
                            TextField("Length seconds", value: $previewDuration, format: .number)
                                .labelsHidden()
                                .frame(width: 70)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    actionRow {
                        Button("Choose Preview Video…", systemImage: "film") { selectFile(role: "preview-video") }
                        Button("Generate Preview", systemImage: "wand.and.stars") { generatePreview(layout) }
                    }
                    hint(video.hint)
                }
                if layout.mockPreview {
                    Toggle("Uploaded preview uses mock images, without original project footage", isOn: $mock)
                }
            }
        } header: {
            Text("Previews")
        } footer: {
            hint(String(localized: "Cover art is required before an item can be published."))
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
            } else if let seed, draft == nil {
                input.kind = seed.kind
                input.title = seed.title
                stagedContent = seed.contentFile
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
        var value = try await service.save(input, id: draft?.id, content: content)
        if let file = stagedContent {
            // Only after the upload lands, so a failure leaves it staged to retry.
            value = try await service.upload(itemId: value.id, role: "content", file: file)
            stagedContent = nil
        }
        draft = value
        return value
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
        if role == "content" { stagedContent = nil }
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
