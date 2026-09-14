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
    /// Previews the surface already has in hand, uploaded with the first save.
    /// A Remotion composition supplies both: its own render, and frame 0
    /// rendered from the archive that is about to be published.
    var previewVideo: URL?
    var previewImage: URL?
    /// Facts the app knows that the server cannot read off the content file —
    /// an archive's dimensions, duration and prompt excerpt.
    var metadata = MarketplaceItemMetadata()
    /// Removed once the uploads land. Nil when the files are the film's own.
    var stagingDirectory: URL?
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
    @State private var categoryEdit: CategoryEdit?
    /// Blocks the form: the schema or the item never arrived.
    @State private var error: String?
    /// One action failed. The form is still usable, so this is raised as an
    /// alert and left in the footer rather than replacing anything.
    @State private var failure: String?
    /// The draft the Save Draft button just wrote. Set only by that button, so
    /// the saves that generation and uploads make on the way never interrupt.
    @State private var savedDraft: MarketplaceAuthoringItem?
    /// Jobs whose failure has already been raised, so reopening an item with an
    /// old failure in its folder does not alert about it again.
    @State private var reportedFailures: Set<String> = []
    @State private var busy = false
    @State private var busyRole: String?
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
    /// Work that stopped without finishing. A generator that the backend
    /// refused fails inside its task, so this is the only place its message
    /// ever reaches the author.
    private var failures: [MarketplaceAuthoringJob] { operations.filter { $0.state == "failed" || $0.state == "interrupted" } }
    private var layout: MarketplaceFormSchema.KindLayout? { schema?.layout(for: input.kind) }
    private var canSave: Bool { !busy && !input.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !input.categoryId.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            // The saved confirmation carries its own actions, so the action
            // bar would only repeat them beside a form that is not showing.
            if savedDraft == nil {
                Divider()
                footer
            }
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 600, idealHeight: 780)
        .task { await load() }
        .onChange(of: input.kind) { chooseCategory() }
        .onChange(of: operationStates) {
            reportFailedJobs()
            Task { if let id = draft?.id, let fresh = try? await service.get(id) { draft = fresh } }
        }
        .alert("Couldn\u{2019}t finish that", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(failure ?? "")
        }
        .sheet(item: $categoryEdit) { categorySheet($0) }
        .sheet(isPresented: $choosingFilmAsset) { MarketplaceFilmAssetPicker { source, document in
            choosingFilmAsset = false
            run(role: "content") {
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

    /// Save status and actions stay available while scrolling the form.
    private var footer: some View {
        HStack(spacing: 10) {
            if busy { ProgressView().controlSize(.small) }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save Draft") { run { savedDraft = try await save() } }
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
        if let savedDraft {
            savedConfirmation(savedDraft)
        } else if let schema {
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
            if input.kind == .audio {
                Section {
                    MarketplaceLyricsEditor(tracks: Binding(get: { input.metadata.lyricTracks ?? [] }, set: { input.metadata.lyricTracks = $0 }))
                    if let draft, draft.item.contentFilename != nil {
                        MarketplaceMusicPreview(item: musicPreviewItem(draft)) {
                            if let url = draft.item.previewVideoUrl { return (url, draft.item.metadata.preview?.startSeconds ?? 0) }
                            return (try await service.localContent(draft), 0)
                        }
                        .id(draft.item.contentFilename)
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            if !failures.isEmpty {
                Section("Needs Attention") {
                    ForEach(failures) { job in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(job.message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                            Button("Try Again") { run { _ = try await service.retry(job) } }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
                .accessibilityIdentifier("marketplace-author-failures")
            }
        }
        .formStyle(.grouped)
        .disabled(busy)
    }

    /// Saving is not publishing. A draft stays private until it is published
    /// from the authoring list, so the confirmation says so and offers the one
    /// way there rather than closing onto nothing.
    private func savedConfirmation(_ item: MarketplaceAuthoringItem) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(.green)
            Text("Draft saved").font(.title3.bold())
            Text("\u{201C}\(item.item.title)\u{201D} is stored as a draft. Publish it from My Marketplace once its cover art is in place.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                Button("Keep Editing") { savedDraft = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Open My Marketplace", systemImage: "person.crop.square") { showMyMarketplace() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("marketplace-author-open-my-items")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("marketplace-author-saved")
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
    /// yet, so a first item never dead-ends on a missing category — and a way
    /// to correct the name or icon of one already there.
    @ViewBuilder
    private func categoryRow(_ field: MarketplaceFormSchema.Field) -> some View {
        let available = categories.filter { $0.kind == input.kind }
        let selected = available.first { $0.id == input.categoryId }
        VStack(alignment: .leading, spacing: 6) {
            // The two actions share the picker's row, on its leading side, so
            // the field reads as one control rather than a control and a
            // stray second line.
            LabeledContent(field.title) {
                HStack(spacing: 12) {
                    // Icons alone, so the row stays the picker's. The titles
                    // still name them for VoiceOver and for the tooltip.
                    HStack(spacing: 10) {
                        if let selected {
                            Button("Edit Category\u{2026}", systemImage: "pencil") { editCategory(.existing(selected)) }
                                .help("Edit \(selected.name)")
                                .accessibilityIdentifier("marketplace-author-edit-category")
                        }
                        Button("New Category\u{2026}", systemImage: "folder.badge.plus") { editCategory(.new) }
                            .help("New Category\u{2026}")
                            .accessibilityIdentifier("marketplace-author-new-category")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    Picker(field.title, selection: $input.categoryId) {
                        Text("Choose a category").tag("")
                        ForEach(available) { category in
                            Label(category.name, systemImage: MarketplaceSymbol.resolve(category.icon, fallback: MarketplaceSymbolCatalog.fallback))
                                .tag(category.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if available.isEmpty { hint(String(localized: "This kind has no categories yet. Add one to continue.")) }
        }
    }

    /// What the category sheet is editing: a new category for the item's kind,
    /// or one that already exists.
    private enum CategoryEdit: Identifiable {
        case new
        case existing(MarketplaceCategory)
        var category: MarketplaceCategory? {
            if case .existing(let value) = self { return value }
            return nil
        }
        var id: String { category?.id ?? "new" }
    }

    private func editCategory(_ edit: CategoryEdit) {
        newCategory = edit.category?.name ?? ""
        newCategoryIcon = edit.category?.icon ?? ""
        categoryEdit = edit
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
            operationProgress(for: "content")
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
                MarketplacePreviewImage(url: draft?.item.previewImageUrl, kind: input.kind, contentMode: .fit)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Cover preview")
                    .accessibilityIdentifier("marketplace-author-cover-preview")
                operationProgress(for: "preview-image")
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
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("marketplace-author-cover-field")
            if let video = layout.previewVideo {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent(input.kind == .audio || input.kind == .soundEffect ? "Audio preview" : "Video") {
                        Text(draft?.item.previewVideoUrl == nil ? "Not set" : "Uploaded")
                            .foregroundStyle(draft?.item.previewVideoUrl == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    }
                    if let draft, let url = draft.item.previewVideoUrl, input.kind == .soundEffect {
                        MarketplaceMusicPreview(item: draft.item) { (url, 0) }
                            .frame(height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if let draft, draft.item.previewVideoUrl != nil, input.kind != .audio {
                        MarketplacePreviewPlayer(item: draft.item)
                            .frame(height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityIdentifier("marketplace-author-video-preview")
                    }
                    operationProgress(for: "preview-video")
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
                        Button(input.kind == .audio || input.kind == .soundEffect ? "Choose Audio Preview…" : "Choose Preview Video…", systemImage: input.kind == .audio || input.kind == .soundEffect ? "waveform" : "film") { selectFile(role: "preview-video") }
                        Button("Generate Preview", systemImage: "wand.and.stars") { generatePreview(layout) }
                    }
                    hint(video.hint)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("marketplace-author-video-field")
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

    /// Work is shown beside the asset it changes, including the save before
    /// an upload or generator has created its persistent job.
    @ViewBuilder
    private func operationProgress(for role: String) -> some View {
        let jobs = running.filter { job in
            job.role == role || (job.operation == "preview" && role.hasPrefix("preview-"))
        }
        if !jobs.isEmpty || busyRole == role {
            VStack(alignment: .leading, spacing: 8) {
                if jobs.isEmpty {
                    ProgressView("Preparing…").controlSize(.small)
                }
                ForEach(jobs) { job in
                    VStack(alignment: .leading, spacing: 4) {
                        if job.progress > 0 {
                            HStack {
                                Text(job.message)
                                Spacer()
                                Text(job.progress, format: .percent.precision(.fractionLength(0)))
                                    .monospacedDigit()
                            }
                            ProgressView(value: job.progress)
                        } else {
                            ProgressView(job.message).controlSize(.small)
                        }
                    }
                }
            }
            .font(.callout)
            .accessibilityIdentifier("marketplace-author-progress-\(role)")
        }
    }

    private func categorySheet(_ edit: CategoryEdit) -> some View {
        let existing = edit.category
        return VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "New Category" : "Edit Category").font(.headline)
            Group {
                if existing == nil {
                    Text("Categories belong to one kind, so this one only shows up for \(layout?.label ?? input.kind.displayName).")
                } else {
                    // The slug is what published items filter on, so it is not
                    // part of the patch and nothing already filed moves.
                    Text("Renaming a category keeps every item already filed under it.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            TextField("Name", text: $newCategory)
                .accessibilityIdentifier("marketplace-author-category-name")
            MarketplaceSymbolPicker(symbol: $newCategoryIcon)
            HStack {
                Button("Cancel") { categoryEdit = nil }
                Spacer()
                Button(existing == nil ? "Add" : "Save") {
                    categoryEdit = nil
                    let name = newCategory, icon = newCategoryIcon
                    run {
                        if let existing {
                            let updated = try await service.updateCategory(id: existing.id, name: name, icon: icon)
                            if let index = categories.firstIndex(where: { $0.id == updated.id }) { categories[index] = updated }
                        } else {
                            let category = try await service.createCategory(kind: input.kind, name: name, icon: icon)
                            categories.append(category)
                            input.categoryId = category.id
                        }
                        newCategory = ""; newCategoryIcon = ""
                    }
                }
                .disabled(newCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("marketplace-author-category-save")
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
                    run(role: kind == "image" ? "preview-image" : "content") {
                        let saved = try await save()
                        _ = try await service.startGeneration(itemId: saved.id, kind: kind, prompt: generationPrompt)
                    }
                }.disabled(generationPrompt.isEmpty)
            }
        }.padding().frame(width: 500)
    }

    // MARK: - Values

    private func musicPreviewItem(_ draft: MarketplaceAuthoringItem) -> MarketplaceItem {
        MarketplaceItem(id: draft.id, kind: .audio, category: draft.item.category, title: input.title,
                        previewImageUrl: draft.item.previewImageUrl, previewVideoUrl: draft.item.previewVideoUrl, metadata: input.metadata)
    }

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
        default:
            // `translations.<locale>.<field>`, e.g. `translations.zh-Hans.title`.
            // The locales are the server's to choose, so this matches the shape
            // rather than a list of languages compiled in here.
            let path = field.id.split(separator: ".", maxSplits: 2).map(String.init)
            guard path.count == 3, path[0] == "translations" else { return nil }
            let (locale, name) = (path[1], path[2])
            return Binding(
                get: { input.translations[locale]?[name] ?? "" },
                set: { value in
                    var localized = input.translations[locale] ?? [:]
                    // An emptied box is a removed translation, not a blank one:
                    // the reader falls back to the text above it.
                    if value.isEmpty { localized.removeValue(forKey: name) } else { localized[name] = value }
                    if localized.isEmpty { input.translations.removeValue(forKey: locale) } else { input.translations[locale] = localized }
                }
            )
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
                // Failures already on disk belong to an earlier session; they
                // are listed in the form, but only a new one raises an alert.
                reportedFailures.formUnion((try? service.savedJobs(itemId: itemId))?.filter(\.isFinished).map(\.id) ?? [])
            } else if let seed, draft == nil {
                input.kind = seed.kind
                input.title = seed.title
                input.metadata = seed.metadata
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
        previewStart = value.item.metadata.preview?.startSeconds ?? 0
    }

    private func save() async throws -> MarketplaceAuthoringItem {
        let content: String? = switch layout?.content.editor ?? .upload {
        case .template: try definition.json()
        case .descriptor: contentText.isEmpty ? nil : contentText
        // `.text` only arrives from a deploy that predates the retirement of
        // the one kind that used it; treat it as an ordinary upload slot.
        case .upload, .text: nil
        }
        var value = try await service.save(input, id: draft?.id, content: content)
        if let file = stagedContent {
            // Only after the upload lands, so a failure leaves it staged to retry.
            // The metadata rides along: a zip has nothing the server can probe.
            value = try await service.upload(itemId: value.id, role: "content", file: file, metadata: seed?.metadata)
            stagedContent = nil
            // Previews the surface rendered for us, rather than a preview job.
            if let cover = seed?.previewImage {
                value = try await service.upload(itemId: value.id, role: "preview-image", file: cover)
            }
            if let video = seed?.previewVideo {
                value = try await service.upload(itemId: value.id, role: "preview-video", file: video)
            }
            if let staging = seed?.stagingDirectory { try? FileManager.default.removeItem(at: staging) }
        }
        draft = value
        return value
    }

    private func generatePreview(_ layout: MarketplaceFormSchema.KindLayout) {
        run(role: "preview-video") { let saved = try await save(); _ = try await service.startPreview(itemId: saved.id, start: previewStart, duration: previewDuration) }
    }

    private func run(role: String? = nil, _ work: @escaping @MainActor () async throws -> Void) {
        busy = true
        busyRole = role
        failure = nil
        Task {
            defer { busy = false; busyRole = nil }
            do { try await work() } catch { self.failure = error.localizedDescription }
        }
    }

    /// Raises the message of any job that has stopped since the last check.
    /// A generator runs in its own task, so a backend refusal lands in the job
    /// and nowhere else unless it is pulled out here.
    private func reportFailedJobs() {
        for job in operations where job.isFinished && !reportedFailures.contains(job.id) {
            reportedFailures.insert(job.id)
            if job.state != "succeeded" { failure = job.message }
        }
    }

    /// Leaves for the authoring list, which is where an item is published.
    private func showMyMarketplace() {
        savedDraft = nil
        MarketplaceWindowRouter.shared.show(.mine)
        openWindow(id: MarketplaceWindowID.value)
        dismiss()
    }

    private func selectFile(role: String) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = role == "preview-image" ? [.image] : role == "preview-video"
            ? ((input.kind == .audio || input.kind == .soundEffect) ? [.audio, .movie] : [.movie]) : [.data]
        guard panel.runModal() == .OK, let file = panel.url else { return }
        if role == "preview-video", layout?.mockPreview == true, !mock { failure = "Confirm that this uploaded preview uses mock images first."; return }
        let editor = layout?.content.editor ?? .upload
        if role == "content" { stagedContent = nil }
        run(role: role) {
            if role == "content", editor != .upload {
                let text = try String(contentsOf: file, encoding: .utf8)
                if editor == .template { definition = try ProjectTemplateDefinition.decode(Data(text.utf8)) } else { contentText = text }
                _ = try await save()
            } else {
                let saved = try await save()
                var metadata = MarketplaceItemMetadata()
                if role == "preview-video" { metadata.preview = .init(startSeconds: previewStart) }
                draft = try await service.upload(itemId: saved.id, role: role, file: file, mock: mock, metadata: metadata)
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
