import Foundation
import SwiftData
import VideoEditorCore

@MainActor enum MCPMarketplaceHandlers {
    static let adminNames: Set<String> = ["marketplace_create", "marketplace_update", "marketplace_upload", "marketplace_generate", "marketplace_render_preview", "marketplace_job_status", "marketplace_retry", "marketplace_publish", "marketplace_workspace", "project_template_from_film"]
    static let names: Set<String> = adminNames.union(["marketplace_list", "marketplace_get", "show_marketplace_item", "marketplace_install", "project_template_apply"])
    static func isMarketplaceTool(_ name: String) -> Bool { names.contains(name.components(separatedBy: "__").last ?? name) }
    private static let text: [String: Any] = ["type": "string"]
    private static func descriptor(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> MCPToolDescriptor {
        MCPToolDescriptor(name: name, description: description, inputSchema: ["type": "object", "properties": properties, "required": required])
    }
    static var descriptors: [MCPToolDescriptor] {
        [
            descriptor("marketplace_list", "Browse published marketplace items. Admins may set drafts:true to list manageable drafts and published items. Returns data without displaying cards; use show_marketplace_item to present an item.", ["kind": text, "query": text, "page": ["type": "integer"], "drafts": ["type": "boolean"]]),
            descriptor("marketplace_get", "Read item data without displaying a card. Admins can read their drafts; other users receive published details and entitled template content. Use show_marketplace_item to present it to the user.", ["item_id": text], required: ["item_id"]),
            descriptor("show_marketplace_item", "The only tool that displays a marketplace item or project template as an interactive native chat card, with cover, preview, instructions and marketplace dependencies. Call once per item after completing the requested authoring/revision work or when the user asks to see it; do not repeat it for intermediate saves or reads. Other marketplace tools return data without displaying cards. Set show_publish_button:false to hide Edit and Publish/Unpublish on this card; defaults to true. Purchase, install and template-use actions remain available.", ["item_id": text, "show_publish_button": ["type": "boolean", "default": true]], required: ["item_id"]),
            descriptor("marketplace_create", "Admin: save a new draft, never publish. item is {kind,title,description,pricePoints,categoryId?,draftId?}; content is a prompt string or definition JSON. Template definition version 1: prompt,videoStyle,editingGuidance,width,height,fps,shots:[{id,title,instructions,durationSeconds,footageRequirementId?,marketplaceItemId?,transition?:{modifierId,parameters,durationSeconds},effects:[]}],footageRequirements:[{id,title,mediaType:video|image|audio,required,instructions}],marketplaceItems:[{itemId,purpose,required}]. Reuse draftId (UUID) on retries. Omit categoryId to use/create General for this kind.", ["item": ["type": "object"], "content": [:]], required: ["item"]),
            descriptor("marketplace_update", "Admin: edit draft listing fields and/or structured content. item fields use the same camelCase names as marketplace_create. Preserve template requirements and references when updating.", ["item_id": text, "item": ["type": "object"], "content": [:]], required: ["item_id"]),
            descriptor("marketplace_upload", "Admin: upload content, preview-image, or preview-video from a source_id in a film or a local file selected/provided by the user. Template previews MUST use mock images: set mock:true. A Remotion item's content is its composition source: pass the composition's source_id with role:content and the app packages the archive itself — never upload a render or a zip you assembled. Upload only the explicitly selected item, never a project package.", ["item_id": text, "role": ["type": "string", "enum": ["content", "preview-image", "preview-video"]], "path": text, "source_id": text, "mock": ["type": "boolean"]], required: ["item_id", "role"]),
            descriptor("marketplace_generate", "Admin: generate content for footage/music or a cover image using existing app generators, inside this item's separate authoring workspace. Returns a job; check marketplace_job_status. Font and sound-effect content need supplied files. kind=image makes a cover; video/music make content. Supply a descriptive prompt.", ["item_id": text, "kind": ["type": "string", "enum": ["image", "video", "music"]], "prompt": text], required: ["item_id", "kind", "prompt"]),
            descriptor("marketplace_render_preview", "Admin: render and upload a <=15s preview plus cover. Templates use generated mock images only; footage/music/sound use actual content; fonts use specimens; effects/transitions use mock demos. For a Remotion composition, supply its rendered movie as demo_path, staged inside the item's authoring workspace. Returns a resumable job.", ["item_id": text, "start": ["type": "number"], "duration": ["type": "number"], "demo_path": text], required: ["item_id"]),
            descriptor("marketplace_job_status", "Admin: read persisted generation/render/upload progress. Completed files remain available for retry after a failure.", ["item_id": text, "job_id": text], required: ["item_id"]),
            descriptor("marketplace_retry", "Admin: retry upload of completed assets, or resume an interrupted generation. Never generate again when a completed file exists.", ["item_id": text, "job_id": text], required: ["item_id", "job_id"]),
            descriptor("marketplace_publish", "Admin: publish/unpublish only when explicitly requested. Create and show the draft first; creating an item does not authorize publishing. Templates require a cover, mock preview and valid published dependencies.", ["item_id": text, "published": ["type": "boolean"]], required: ["item_id", "published"]),
            descriptor("marketplace_workspace", "Admin: get the separate authoring film for a draft. Use its film id with existing generation/Remotion/sequence tools to create mock demonstrations. Original project footage must not be copied here for template previews.", ["item_id": text], required: ["item_id"]),
            descriptor("project_template_from_film", "Admin: extract the selected (or only) sequence into a template draft. Read the returned draft, generalize the project prompt/style and per-shot instructions with marketplace_update, then render a mock preview and call show_marketplace_item once. marketplace_bindings explicitly maps sourceId (or modifier:definitionId) to marketplace item ID. Explicitly map unidentified marketplace assets; never infer marketplace identities from names.", ["sequence_id": text, "prompt": text, "title": text, "draft_id": text, "marketplace_bindings": ["type": "object", "additionalProperties": text]]),
            descriptor("project_template_apply", "Use an entitled template in the specified film. Creates/resumes a NEW sequence without changing existing sequences. footage_bindings maps requirement id to sourceId from footage_list. Returns missing requirements, dependency costs/blockers and sequence_id. Request missing footage and offer generation; paid assets require the user's purchase. Repeat with application_id and bindings to resume. When ready, adapt ONLY the returned sequence then sequence_render.", ["item_id": text, "application_id": text, "footage_bindings": ["type": "object", "additionalProperties": text]], required: ["item_id"]),
            descriptor("marketplace_install", "Install an owned/free marketplace item. Never purchases or charges credits. Returns data without displaying a card. Missing paid items must be bought with the Buy button on show_marketplace_item.", ["item_id": text], required: ["item_id"]),
        ]
    }
    static func handle(name: String, arguments: [String: Any], container: ModelContainer?) async throws -> [String: Any] {
        let service = MarketplaceAuthoringService.shared
        if adminNames.contains(name) { _ = try await service.requireAdmin() }
        func required(_ key: String) throws -> String {
            guard let value = arguments[key] as? String, !value.isEmpty else { throw MCPToolError.invalidArguments("missing \(key)") }; return value
        }
        func document() throws -> ProjectDocument {
            if let doc = try MCPToolRegistry.resolveFilm(arguments["film"]) { return doc }
            if let container, let doc = ProjectDocumentController.shared.document(forContainer: container) ?? service.document(forContainer: container) { return doc }
            guard let doc = ProjectDocumentController.shared.activeDocument else { throw MarketplaceError.noActiveFilm }; return doc
        }
        switch name {
        case "marketplace_list":
            if arguments["drafts"] as? Bool == true { _ = try await service.requireAdmin(); return try result(await service.list(page: arguments["page"] as? Int ?? 1)) }
            let page = try await MarketplaceClient().items(kind: (arguments["kind"] as? String).flatMap(MarketplaceKind.init(rawValue:)), category: nil, query: arguments["query"] as? String ?? "", page: arguments["page"] as? Int ?? 1)
            return try result(page)
        case "marketplace_get": return try await show(required("item_id"))
        case "show_marketplace_item": return try await show(required("item_id"), showPublishButton: arguments["show_publish_button"] as? Bool ?? true)
        case "marketplace_create", "marketplace_update":
            let id = name == "marketplace_update" ? try required("item_id") : nil
            let existing = try await id.asyncMap { try await service.get($0) }
            var input = existing.map(MarketplaceItemInput.init) ?? MarketplaceItemInput()
            if let raw = arguments["item"] as? [String: Any] {
                var base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as! [String: Any]
                base.merge(raw) { _, new in new }
                input = try JSONDecoder().decode(MarketplaceItemInput.self, from: JSONSerialization.data(withJSONObject: base))
            }
            if input.categoryId.isEmpty {
                let categories = try await service.categories()
                if let category = categories.first(where: { $0.kind == input.kind }) { input.categoryId = category.id }
                else { input.categoryId = try await service.createCategory(kind: input.kind, name: "General").id }
            }
            let saved = try await service.save(input, id: id, content: try content(arguments["content"]))
            return try card(saved)
        case "marketplace_upload":
            let itemId = try required("item_id"), role = try required("role")
            let file: URL
            var metadata: MarketplaceItemMetadata?
            if let sourceId = arguments["source_id"] as? String {
                let doc = try document()
                if role == "content", DocumentMediaResolver.parse(sourceId)?.0 == .remotion {
                    (file, metadata) = try compositionArchive(sourceId, itemId: itemId, document: doc, service: service)
                } else {
                    let source = try ProjectTemplateService.source(sourceId, document: doc)
                    let resolver = DocumentMediaResolver(document: doc, width: 1920, height: 1080, fps: 30)
                    guard let url = try await resolver.resolve(source).fileURL else { throw MarketplaceAuthoringError.invalid("Select media with a file.") }; file = url
                }
            } else { file = URL(fileURLWithPath: try required("path")) }
            return try card(await service.upload(itemId: itemId, role: role, file: file, mock: arguments["mock"] as? Bool ?? false, metadata: metadata))
        case "marketplace_generate": return try result(await service.startGeneration(itemId: required("item_id"), kind: required("kind"), prompt: required("prompt")))
        case "marketplace_render_preview": return try result(await service.startPreview(itemId: required("item_id"), start: arguments["start"] as? Double ?? 0, duration: arguments["duration"] as? Double ?? 15, demoPath: arguments["demo_path"] as? String))
        case "marketplace_job_status":
            let jobs = try service.savedJobs(itemId: required("item_id"))
            return try result(jobs.filter { arguments["job_id"] == nil || $0.id == arguments["job_id"] as? String })
        case "marketplace_retry":
            let jobId = try required("job_id")
            guard let job = try service.savedJobs(itemId: required("item_id")).first(where: { $0.id == jobId }) else { throw MarketplaceAuthoringError.invalid("Operation not found.") }
            return try result(await service.retry(job))
        case "marketplace_publish": return try card(await service.publish(required("item_id"), published: arguments["published"] as? Bool ?? false))
        case "marketplace_workspace":
            let doc = try service.workspace(itemId: required("item_id"))
            return MCPToolRegistry.jsonResult(["film": doc.id.uuidString, "path": doc.packageURL.path, "instructions": "Use this film id for mock demonstration generation and rendering. All outputs must stay inside this workspace."])
        case "project_template_from_film":
            let template = try ProjectTemplateService.extract(document: document(), sequenceId: arguments["sequence_id"] as? String, prompt: arguments["prompt"] as? String, marketplaceBindings: arguments["marketplace_bindings"] as? [String: String] ?? [:])
            var input = MarketplaceItemInput(); input.title = arguments["title"] as? String ?? "New Project Template"; input.draftId = arguments["draft_id"] as? String
            input.description = "An adaptable video shot plan."
            let categories = try await service.categories()
            if let category = categories.first(where: { $0.kind == .projectTemplate }) { input.categoryId = category.id }
            else { input.categoryId = try await service.createCategory(kind: .projectTemplate, name: "General").id }
            return try card(await service.save(input, content: template.json()))
        case "project_template_apply":
            let value = try await ProjectTemplateService.apply(itemId: required("item_id"), document: document(), applicationId: arguments["application_id"] as? String, bindings: arguments["footage_bindings"] as? [String: String] ?? [:])
            let item = try await MarketplaceClient().item(value.itemId)
            return try result(MarketplaceCardPayload(marketplaceItem: item, definition: value.template, status: "published", application: value))
        case "marketplace_install":
            let item = try await MarketplaceClient().item(required("item_id"))
            guard await MarketplaceStore.shared.install(item) else { throw MarketplaceAuthoringError.invalid(MarketplaceStore.shared.lastError ?? "Could not install item.") }
            return try await show(item.id)
        default: throw MCPToolError.invalidArguments("Unknown marketplace tool.")
        }
    }
    /// Packages a composition into the zip the marketplace stores as content.
    ///
    /// A Remotion item publishes its *source*, not a render: the buyer installs
    /// TypeScript they go on to edit. Resolving the source id the ordinary way
    /// would hand back whatever the renderer last produced, so this takes the
    /// project folder instead and carries the composition's size, duration and
    /// prompt across in metadata — facts a zip cannot be probed for.
    ///
    /// The archive is written into the item's authoring directory so a failed
    /// upload can be retried from the saved job without rebuilding it.
    private static func compositionArchive(
        _ sourceId: String, itemId: String, document: ProjectDocument, service: MarketplaceAuthoringService
    ) throws -> (URL, MarketplaceItemMetadata) {
        guard let (_, id) = DocumentMediaResolver.parse(sourceId) else {
            throw MarketplaceAuthoringError.invalid("Use a sourceId from footage_list.")
        }
        let project = try MCPLibraryHandlers.fetchRemotion(id: id.uuidString, context: document.container.mainContext)
        let descriptor = RemotionProjectArchive.Descriptor(project: project)
        let destination = try service.directory(for: itemId)
            .appendingPathComponent("composition-\(project.id.uuidString).zip")
        try RemotionProjectArchive.write(project: project.projectDir, descriptor: descriptor, to: destination)
        let prompt = descriptor.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return (destination, MarketplaceItemMetadata(
            durationSeconds: descriptor.durationSeconds,
            width: descriptor.compositionWidth,
            height: descriptor.compositionHeight,
            promptExcerpt: prompt.isEmpty ? nil : String(prompt.prefix(280))
        ))
    }

    static func content(_ value: Any?) throws -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
    static func card(_ draft: MarketplaceAuthoringItem, showPublishButton: Bool = true) throws -> [String: Any] {
        try result(MarketplaceCardPayload(marketplaceItem: draft.item, definition: draft.template, status: draft.status, showPublishButton: showPublishButton))
    }
    static func show(_ id: String, showPublishButton: Bool = true) async throws -> [String: Any] {
        if await MarketplaceAuthoringService.shared.refreshAccess() { return try card(await MarketplaceAuthoringService.shared.get(id), showPublishButton: showPublishButton) }
        let item = try await MarketplaceClient().item(id)
        var definition: ProjectTemplateDefinition?
        if item.kind == .projectTemplate && item.isEntitled {
            let store = MarketplaceStore.shared
            if !store.isInstalled(id) { _ = await store.install(item) }
            if let manifest = store.manifest(for: id) { definition = try ProjectTemplateDefinition.decode(Data(contentsOf: manifest.contentURL(in: store.directory(for: manifest)))) }
        }
        return try result(MarketplaceCardPayload(marketplaceItem: item, definition: definition, status: "published", showPublishButton: showPublishButton))
    }
    static func result<T: Encodable>(_ value: T) throws -> [String: Any] {
        MCPToolRegistry.jsonResult(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)))
    }
}

private extension Optional where Wrapped: Sendable {
    @MainActor func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }; return try await transform(value)
    }
}
