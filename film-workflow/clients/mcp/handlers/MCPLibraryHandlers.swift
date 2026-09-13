import Foundation
import SwiftData
import VideoEditorCore

/// The film's library for agents: every footage item, the folders they sit
/// in, and the takes (generated outputs, renders, transcripts) each one holds.
///
/// One id space. An item is addressed by the same `footage_id` the editor
/// selects (`id` on the model, `projectUUID` on captions), so the id in a tool
/// result is the id a thread is targeted at and the id the inspector shows.
/// Kinds are the library's own `FootageKind` names.
@MainActor
enum MCPLibraryHandlers {
    static let descriptors: [MCPToolDescriptor] = [
        MCPToolDescriptor(
            name: "footage_list",
            description: "The film's library: every footage item — music, narration, captions, images, video, Remotion compositions, imported files — and its sequences. Each row carries `id` (the footage_id other tools take), `kind`, `name`, `folderId`, `versionCount` and `sourceId`: the newest take, ready for sequence_add_clip (null until something has been generated). Pass `include_versions` to get every take with its own `sourceId`. Filter with `kind`, and with `folder_id` (null for items in no folder).",
            inputSchema: [
                "type": "object",
                "properties": [
                    "kind": kindProperty(FootageKind.allCases),
                    "folder_id": nullableFolderIDProperty,
                    "include_versions": ["type": "boolean", "description": "Also return each item's takes, newest first. Default false."] as [String: Any],
                ]
            ]
        ),
        MCPToolDescriptor(
            name: "footage_get",
            description: "Everything about one library item: its parameters (the inspector's fields, which footage_update can change) and its takes, newest first, each with a `sourceId` for the timeline. A captions item returns a summary only — read the captions themselves with caption_list_segments or caption_search_segments. A sequence returns its timeline, like sequence_get.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "footage_id": footageIDProperty
                ],
                "required": ["footage_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "footage_create",
            description: "Add a new item to the library. Returns it, with its id. Imported files come in through footage_import instead. A new Remotion composition is seeded with a default source and starts its live preview.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "kind": kindProperty(FootageKind.creatable),
                    "name": ["type": "string", "description": "Display name. Defaults to the library's own default for the kind, e.g. 'Untitled Music'."] as [String: Any],
                    "folder_id": ["type": "string", "description": "Optional folder id to file it under."] as [String: Any]
                ],
                "required": ["kind"]
            ]
        ),
        MCPToolDescriptor(
            name: "footage_update",
            description: "Change an item's parameters — the fields the inspector shows. `fields` is an object; keys that don't belong to the item's kind are ignored. Every kind: name. Narration: provider (Gemini|Azure), sceneDescription, notes, context, speakers (array of {displayName, voice, geminiVoice, azureVoice, azurePitch, azureRate, azureVolume, azureRole, azureStyleDegree}), paragraphs (array of {speakerId, emotion, content}), azureOutputFormat (mp3|wav). Music: inputMode (editor|prompt), promptText, generalPrompt, genre, instruments (array), bpm, keyScale, mood, musicLength, generationType (withLyrics|noLyrics), lyricsLanguage, outputFormat (mp3|wav), songStructureEntries (array of {type, startTime, endTime, intensity, description}), lyricEntries (array of {timestamp, content}). Image: provider (openai|google), prompt, googleModel, googleAspectRatio, googleResolution, openAIModel, openAISize, openAICustomWidth, openAICustomHeight, openAIQuality, openAIFormat, openAICompression, openAIBackground, openAITransparent. Video: prompt, negativePrompt, googleModel, googleAspectRatio (16:9|9:16), googleResolution (720p|1080p|4k), googleDuration (4|5|6|8), googlePersonGeneration (allow_all|allow_adult|dont_allow), googleNumberOfVideos, googleGenerateAudio, useSeed, seed. Remotion: text, durationSeconds, themeColorHex (#RRGGBB), prompt, compositionWidth, compositionHeight, compositionFps, compositionSource (the TSX of src/Composition.tsx). Captions: provider (WhisperKit|OpenAI|Azure|Gemini, or \"\" for the app default), language, maxSpeakers, diarizationEnabled, wordTimestampsEnabled — the captions themselves are edited with the caption_* tools. Sequence: width, height, fps. Changing parameters never touches existing takes; run the kind's generate tool for a new one.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "footage_id": footageIDProperty,
                    "fields": ["type": "object", "additionalProperties": true] as [String: Any]
                ],
                "required": ["footage_id", "fields"]
            ]
        ),
        MCPToolDescriptor(
            name: "footage_delete",
            description: "Remove an item from the library along with its takes and files on disk (a referenced import stays where it is on disk). Sequences that used it keep their clips but can no longer resolve them. Requires confirm=true.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "footage_id": footageIDProperty,
                    "confirm": ["type": "boolean", "description": "Must be true to confirm permanent deletion."] as [String: Any]
                ],
                "required": ["footage_id", "confirm"]
            ]
        ),
        MCPToolDescriptor(
            name: "footage_duplicate",
            description: "Copy an item's parameters into a new item in the same folder. Takes are not copied; reference images, frames and a composition's source directory are. Imported files cannot be duplicated — import them again.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "footage_id": footageIDProperty,
                    "new_name": ["type": "string", "description": "Optional. Defaults to '<original name> Copy'."] as [String: Any]
                ],
                "required": ["footage_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "footage_move",
            description: "File an item under a folder, or pass folder_id null to take it out of its folder.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "footage_id": footageIDProperty,
                    "folder_id": nullableFolderIDProperty
                ],
                "required": ["footage_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "footage_import",
            description: "Bring a video, audio or image file from disk into the library as an imported item. Returns it with its `sourceId`, ready for sequence_add_clip.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute path of the file."] as [String: Any],
                    "copy": ["type": "boolean", "description": "Copy into the film package (default true) or reference in place."] as [String: Any],
                    "name": ["type": "string", "description": "Display name; defaults to the file name."] as [String: Any],
                    "folder_id": ["type": "string", "description": "Optional folder id to file it under."] as [String: Any],
                ],
                "required": ["path"]
            ]
        ),
        MCPToolDescriptor(
            name: "folder_list",
            description: "The library's folders, with how many items of each kind they hold.",
            inputSchema: ["type": "object", "properties": [:] as [String: Any]]
        ),
        MCPToolDescriptor(
            name: "folder_create",
            description: "Create a library folder. Folders are flat and can hold items of every kind.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Unique display name."] as [String: Any]
                ],
                "required": ["name"]
            ]
        ),
        MCPToolDescriptor(
            name: "folder_rename",
            description: "Rename a library folder.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "folder_id": folderIDProperty,
                    "name": ["type": "string", "description": "New unique display name."] as [String: Any]
                ],
                "required": ["folder_id", "name"]
            ]
        ),
        MCPToolDescriptor(
            name: "folder_delete",
            description: "Delete a folder. Its items are kept and simply leave the folder. Requires confirm=true.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "folder_id": folderIDProperty,
                    "confirm": ["type": "boolean", "description": "Must be true to confirm deletion."] as [String: Any]
                ],
                "required": ["folder_id", "confirm"]
            ]
        )
    ]

    static let toolNames: Set<String> = Set(descriptors.map(\.name))

    static func canHandle(_ name: String) -> Bool { toolNames.contains(name) }

    static func handle(
        name: String,
        arguments: [String: Any],
        context: ModelContext
    ) async throws -> [String: Any] {
        switch name {
        case "footage_list":
            return try list(arguments, context: context)
        case "footage_get":
            let item = try item(from: arguments, context: context)
            return MCPToolRegistry.jsonResult(full(item, context: context))
        case "footage_create":
            return try await create(arguments, context: context)
        case "footage_update":
            guard let fields = arguments["fields"] as? [String: Any] else {
                throw MCPToolError.invalidArguments("missing fields")
            }
            let item = try item(from: arguments, context: context)
            try apply(fields, to: item, context: context)
            return MCPToolRegistry.jsonResult(full(item, context: context))
        case "footage_delete":
            guard arguments["confirm"] as? Bool == true else {
                throw MCPToolError.invalidArguments("confirm must be true")
            }
            let item = try item(from: arguments, context: context)
            let id = item.id.uuidString
            ProjectLifecycleService.delete(item.libraryID, context: context)
            return MCPToolRegistry.jsonResult(["ok": true, "id": id] as [String: Any])
        case "footage_duplicate":
            let item = try item(from: arguments, context: context)
            let copy = try duplicate(item, newName: arguments["new_name"] as? String, context: context)
            return MCPToolRegistry.jsonResult(summary(copy, context: context))
        case "footage_move":
            let item = try item(from: arguments, context: context)
            let folderID = try optionalFolderID(arguments["folder_id"], context: context)
            try move(item, to: folderID, context: context)
            return MCPToolRegistry.jsonResult(summary(item, context: context))
        case "footage_import":
            return try await importFile(arguments, context: context)
        case "folder_list":
            let groups = try context.fetch(FetchDescriptor<ProjectGroup>(sortBy: [SortDescriptor(\.name)]))
            return MCPToolRegistry.jsonResult(try groups.map { try folderPayload($0, context: context) })
        case "folder_create":
            guard let folderName = arguments["name"] as? String else {
                throw MCPToolError.invalidArguments("missing name")
            }
            let group = try ProjectGroupService.create(name: folderName, context: context)
            return MCPToolRegistry.jsonResult(try folderPayload(group, context: context))
        case "folder_rename":
            let group = try folder(from: arguments, context: context)
            guard let folderName = arguments["name"] as? String else {
                throw MCPToolError.invalidArguments("missing name")
            }
            try ProjectGroupService.rename(group, to: folderName, context: context)
            return MCPToolRegistry.jsonResult(try folderPayload(group, context: context))
        case "folder_delete":
            guard arguments["confirm"] as? Bool == true else {
                throw MCPToolError.invalidArguments("confirm must be true")
            }
            let group = try folder(from: arguments, context: context)
            let id = group.id.uuidString
            try ProjectGroupService.delete(group, context: context)
            return MCPToolRegistry.jsonResult(["ok": true, "id": id, "itemsKept": true] as [String: Any])
        default:
            throw MCPToolError.invalidArguments("unrecognized: \(name)")
        }
    }

    // MARK: - Items

    /// One library row with its model, so callers switch on the kind once.
    enum Item {
        case music(MusicProject)
        case narration(NarrativeProject)
        case caption(CaptionProject)
        case image(ImageGenProject)
        case video(VideoGenProject)
        case remotion(RemotionProject)
        case sequence(SequenceProject)
        case imported(ImportedAsset)

        var kind: FootageKind {
            switch self {
            case .music: .music
            case .narration: .narration
            case .caption: .caption
            case .image: .image
            case .video: .video
            case .remotion: .remotion
            case .sequence: .sequence
            case .imported: .imported
            }
        }

        var id: UUID {
            switch self {
            case .music(let p): p.id
            case .narration(let p): p.id
            case .caption(let p): p.projectUUID
            case .image(let p): p.id
            case .video(let p): p.id
            case .remotion(let p): p.id
            case .sequence(let p): p.id
            case .imported(let a): a.id
            }
        }

        var libraryID: LibraryItemID { LibraryItemID(kind: kind, id: id) }

        var name: String {
            switch self {
            case .music(let p): p.name
            case .narration(let p): p.name
            case .caption(let p): p.name
            case .image(let p): p.name
            case .video(let p): p.name
            case .remotion(let p): p.name
            case .sequence(let p): p.name
            case .imported(let a): a.name
            }
        }

        var groupID: UUID? {
            switch self {
            case .music(let p): p.groupID
            case .narration(let p): p.groupID
            case .caption(let p): p.groupID
            case .image(let p): p.groupID
            case .video(let p): p.groupID
            case .remotion(let p): p.groupID
            case .sequence(let p): p.groupID
            case .imported(let a): a.groupID
            }
        }

        var createdAt: Date {
            switch self {
            case .music(let p): p.createdAt
            case .narration(let p): p.createdAt
            case .caption(let p): p.createdAt
            case .image(let p): p.createdAt
            case .video(let p): p.createdAt
            case .remotion(let p): p.createdAt
            case .sequence(let p): p.createdAt
            case .imported(let a): a.createdAt
            }
        }

        var updatedAt: Date {
            switch self {
            case .music(let p): p.updatedAt
            case .narration(let p): p.updatedAt
            case .caption(let p): p.updatedAt
            case .image(let p): p.updatedAt
            case .video(let p): p.updatedAt
            case .remotion(let p): p.updatedAt
            case .sequence(let p): p.updatedAt
            case .imported(let a): a.updatedAt
            }
        }

        /// The model as the folder service sees it.
        var groupable: any GroupableProject {
            switch self {
            case .music(let p): p
            case .narration(let p): p
            case .caption(let p): p
            case .image(let p): p
            case .video(let p): p
            case .remotion(let p): p
            case .sequence(let p): p
            case .imported(let a): a
            }
        }
    }

    // MARK: Fetchers

    static func fetchMusic(id: String, context: ModelContext) throws -> MusicProject {
        let uuid = try uuid(id)
        guard let p = try context.fetch(FetchDescriptor<MusicProject>(predicate: #Predicate { $0.id == uuid })).first else {
            throw MCPToolError.notFound(id)
        }
        return p
    }

    static func fetchNarration(id: String, context: ModelContext) throws -> NarrativeProject {
        let uuid = try uuid(id)
        guard let p = try context.fetch(FetchDescriptor<NarrativeProject>(predicate: #Predicate { $0.id == uuid })).first else {
            throw MCPToolError.notFound(id)
        }
        return p
    }

    static func fetchImage(id: String, context: ModelContext) throws -> ImageGenProject {
        let uuid = try uuid(id)
        guard let p = try context.fetch(FetchDescriptor<ImageGenProject>(predicate: #Predicate { $0.id == uuid })).first else {
            throw MCPToolError.notFound(id)
        }
        return p
    }

    static func fetchVideo(id: String, context: ModelContext) throws -> VideoGenProject {
        let uuid = try uuid(id)
        guard let p = try context.fetch(FetchDescriptor<VideoGenProject>(predicate: #Predicate { $0.id == uuid })).first else {
            throw MCPToolError.notFound(id)
        }
        return p
    }

    static func fetchRemotion(id: String, context: ModelContext) throws -> RemotionProject {
        let uuid = try uuid(id)
        guard let p = try context.fetch(FetchDescriptor<RemotionProject>(predicate: #Predicate { $0.id == uuid })).first else {
            throw MCPToolError.notFound(id)
        }
        return p
    }

    static func fetchSequence(id: String, context: ModelContext) throws -> SequenceProject {
        let uuid = try uuid(id)
        guard let p = try context.fetch(FetchDescriptor<SequenceProject>(predicate: #Predicate { $0.id == uuid })).first else {
            throw MCPToolError.notFound(id)
        }
        return p
    }

    static func fetchImported(id: String, context: ModelContext) throws -> ImportedAsset {
        let uuid = try uuid(id)
        guard let a = try context.fetch(FetchDescriptor<ImportedAsset>(predicate: #Predicate { $0.id == uuid })).first else {
            throw MCPToolError.notFound(id)
        }
        return a
    }

    /// Finds the item with `id`, whatever its kind. A `kind` hint skips the
    /// other stores.
    static func item(id: String, kind: FootageKind? = nil, context: ModelContext) throws -> Item {
        _ = try uuid(id)
        for candidate in kind.map({ [$0] }) ?? FootageKind.allCases {
            let found: Item?
            switch candidate {
            case .music: found = (try? fetchMusic(id: id, context: context)).map(Item.music)
            case .narration: found = (try? fetchNarration(id: id, context: context)).map(Item.narration)
            case .caption: found = (try? MCPCaptionHandlers.fetchCaption(id: id, context: context)).map(Item.caption)
            case .image: found = (try? fetchImage(id: id, context: context)).map(Item.image)
            case .video: found = (try? fetchVideo(id: id, context: context)).map(Item.video)
            case .remotion: found = (try? fetchRemotion(id: id, context: context)).map(Item.remotion)
            case .sequence: found = (try? fetchSequence(id: id, context: context)).map(Item.sequence)
            case .imported: found = (try? fetchImported(id: id, context: context)).map(Item.imported)
            }
            if let found { return found }
        }
        throw MCPToolError.notFound(id)
    }

    /// The item's display name, or nil when nothing has that id any more.
    static func name(id: UUID, kind: FootageKind?, context: ModelContext) -> String? {
        (try? item(id: id.uuidString, kind: kind, context: context))?.name
    }

    private static func item(from arguments: [String: Any], context: ModelContext) throws -> Item {
        guard let id = arguments["footage_id"] as? String else {
            throw MCPToolError.invalidArguments("missing footage_id")
        }
        return try item(id: id, context: context)
    }

    private static func uuid(_ id: String) throws -> UUID {
        guard let uuid = UUID(uuidString: id) else {
            throw MCPToolError.invalidArguments("\(id) is not an id; ids come from footage_list")
        }
        return uuid
    }

    // MARK: - Listing

    private static func list(_ arguments: [String: Any], context: ModelContext) throws -> [String: Any] {
        var kinds = FootageKind.allCases
        if let raw = arguments["kind"] as? String {
            guard let kind = FootageKind(rawValue: raw) else { throw MCPToolError.unknownKind(raw) }
            kinds = [kind]
        }
        let filter = try folderFilter(arguments, context: context)
        let includeVersions = (arguments["include_versions"] as? Bool) ?? false

        var items: [Item] = []
        for kind in kinds {
            switch kind {
            case .music: items += try context.fetch(FetchDescriptor<MusicProject>()).map(Item.music)
            case .narration: items += try context.fetch(FetchDescriptor<NarrativeProject>()).map(Item.narration)
            case .caption: items += try context.fetch(FetchDescriptor<CaptionProject>()).map(Item.caption)
            case .image: items += try context.fetch(FetchDescriptor<ImageGenProject>()).map(Item.image)
            case .video: items += try context.fetch(FetchDescriptor<VideoGenProject>()).map(Item.video)
            case .remotion: items += try context.fetch(FetchDescriptor<RemotionProject>()).map(Item.remotion)
            case .sequence: items += try context.fetch(FetchDescriptor<SequenceProject>()).map(Item.sequence)
            case .imported: items += try context.fetch(FetchDescriptor<ImportedAsset>()).map(Item.imported)
            }
        }
        let rows = items
            .filter { filter.matches($0.groupID) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { item -> [String: Any] in
                var row = summary(item, context: context)
                if includeVersions { row["versions"] = versions(of: item, context: context) }
                return row
            }
        return MCPToolRegistry.jsonResult(rows)
    }

    // MARK: - Create

    private static func create(_ arguments: [String: Any], context: ModelContext) async throws -> [String: Any] {
        guard let raw = arguments["kind"] as? String else { throw MCPToolError.invalidArguments("missing kind") }
        guard let kind = FootageKind(rawValue: raw) else { throw MCPToolError.unknownKind(raw) }
        guard FootageKind.creatable.contains(kind) else {
            throw MCPToolError.invalidArguments("\(raw) items are added with footage_import")
        }
        let folderID = try optionalFolderID(arguments["folder_id"], context: context)
        guard let libraryID = ProjectLifecycleService.create(kind: kind, groupID: folderID, context: context) else {
            throw MCPToolError.unknownKind(raw)
        }
        try context.save()
        let item = try item(id: libraryID.id.uuidString, kind: kind, context: context)
        if let name = (arguments["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            try apply(["name": name], to: item, context: context)
        }

        var payload = summary(item, context: context)
        #if os(macOS)
        if case .remotion(let p) = item {
            // Seed a default composition so callers get something to preview
            // without a round-trip to a model, then start the native preview.
            p.createdViaMCP = true
            let source = RemotionCodeBuilder.defaultComposition(project: p)
            p.compositionSource = source
            try? RemotionCodeBuilder.writeComposition(project: p, source: source)
            try? context.save()

            var previewStatus = "starting"
            var previewURL: String?
            do {
                previewURL = try await RemotionPreviewSessions.shared.keepRunning(project: p).absoluteString
                previewStatus = "running"
            } catch {
                previewStatus = "failed: \(error.localizedDescription)"
            }
            payload["preview"] = ["status": previewStatus, "url": previewURL as Any] as [String: Any]
            payload["compositionSource"] = source
        }
        #endif
        return MCPToolRegistry.jsonResult(payload)
    }

    // MARK: - Import

    private static func importFile(_ arguments: [String: Any], context: ModelContext) async throws -> [String: Any] {
        guard let path = arguments["path"] as? String else { throw MCPToolError.invalidArguments("missing path") }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw MCPToolError.invalidArguments("no file at \(path)") }
        guard let kind = MediaImportSheet.kind(of: url) else { throw MCPToolError.invalidArguments("not a video, audio or image file") }
        let folderID = try optionalFolderID(arguments["folder_id"], context: context)
        let copy = (arguments["copy"] as? Bool) ?? true
        let storage = ProjectStorage.forContainer(context.container)
        let asset = ImportedAsset(name: (arguments["name"] as? String) ?? url.deletingPathExtension().lastPathComponent, kind: kind, originalPath: url.path)
        asset.groupID = folderID
        do {
            if copy {
                asset.relativePath = try storage.copyFile(from: url, kind: .imported, fallbackExtension: kind == .image ? "png" : "mp4")
            } else {
                asset.bookmarkData = try url.bookmarkData()
            }
        } catch {
            throw MCPToolError.underlying(error)
        }
        let mediaURL = asset.relativePath.map(storage.absoluteURL(for:)) ?? url
        await MediaImporter.probe(asset, mediaURL: mediaURL, kind: kind, storage: storage)
        context.insert(asset)
        try context.save()
        var payload = full(.imported(asset), context: context)
        payload["stored"] = copy ? "copied" : "referenced"
        return MCPToolRegistry.jsonResult(payload)
    }

    // MARK: - Move

    private static func move(_ item: Item, to folderID: UUID?, context: ModelContext) throws {
        switch item {
        case .music(let p): try ProjectGroupService.move(p, to: folderID, context: context)
        case .narration(let p): try ProjectGroupService.move(p, to: folderID, context: context)
        case .caption(let p): try ProjectGroupService.move(p, to: folderID, context: context)
        case .image(let p): try ProjectGroupService.move(p, to: folderID, context: context)
        case .video(let p): try ProjectGroupService.move(p, to: folderID, context: context)
        case .remotion(let p): try ProjectGroupService.move(p, to: folderID, context: context)
        case .sequence(let p): try ProjectGroupService.move(p, to: folderID, context: context)
        case .imported(let a): try ProjectGroupService.move(a, to: folderID, context: context)
        }
    }

    // MARK: - Update

    private static func apply(_ fields: [String: Any], to item: Item, context: ModelContext) throws {
        switch item {
        case .music(let p): applyMusicFields(p, fields: fields); p.updatedAt = Date()
        case .narration(let p): applyNarrationFields(p, fields: fields); p.updatedAt = Date()
        case .caption(let p): applyCaptionFields(p, fields: fields); p.updatedAt = Date()
        case .image(let p): applyImageFields(p, fields: fields); p.updatedAt = Date()
        case .video(let p): applyVideoFields(p, fields: fields); p.updatedAt = Date()
        case .remotion(let p):
            #if os(macOS)
            applyRemotionFields(p, fields: fields)
            #else
            if let s = fields["name"] as? String { p.name = s }
            #endif
            p.updatedAt = Date()
        case .sequence(let p): applySequenceFields(p, fields: fields); p.updatedAt = Date()
        case .imported(let a):
            if let s = fields["name"] as? String { a.name = s }
            a.updatedAt = Date()
        }
        try context.save()
    }

    // MARK: - Duplicate

    private static func duplicate(_ item: Item, newName: String?, context: ModelContext) throws -> Item {
        let storage = ProjectStorage.forContainer(context.container)
        switch item {
        case .narration(let src):
            let copy = NarrativeProject(name: newName ?? (src.name + " Copy"))
            copy.groupID = src.groupID
            copy.provider = src.provider
            copy.sceneDescription = src.sceneDescription
            copy.notes = src.notes
            copy.context = src.context
            copy.azureOutputFormat = src.azureOutputFormat
            copy.speakers = src.speakers
            copy.paragraphs = src.paragraphs
            context.insert(copy)
            try context.save()
            return .narration(copy)
        case .music(let src):
            let copy = MusicProject(name: newName ?? (src.name + " Copy"))
            copy.groupID = src.groupID
            copy.inputMode = src.inputMode
            copy.promptText = src.promptText
            copy.generalPrompt = src.generalPrompt
            copy.genre = src.genre
            copy.instruments = src.instruments
            copy.bpm = src.bpm
            copy.keyScale = src.keyScale
            copy.mood = src.mood
            copy.musicLength = src.musicLength
            copy.generationType = src.generationType
            copy.lyricsLanguage = src.lyricsLanguage
            copy.outputFormat = src.outputFormat
            copy.songStructureEntries = src.songStructureEntries
            copy.lyricEntries = src.lyricEntries
            copy.referenceImagePaths = src.referenceImagePaths.compactMap(storage.copyStoredFile(atRelative:))
            context.insert(copy)
            try context.save()
            return .music(copy)
        case .image(let src):
            let copy = ImageGenProject(name: newName ?? (src.name + " Copy"))
            copy.groupID = src.groupID
            copy.provider = src.provider
            copy.prompt = src.prompt
            copy.googleModel = src.googleModel
            copy.googleAspectRatio = src.googleAspectRatio
            copy.googleResolution = src.googleResolution
            copy.openAIModel = src.openAIModel
            copy.openAISize = src.openAISize
            copy.openAICustomWidth = src.openAICustomWidth
            copy.openAICustomHeight = src.openAICustomHeight
            copy.openAIQuality = src.openAIQuality
            copy.openAIFormat = src.openAIFormat
            copy.openAICompression = src.openAICompression
            copy.openAIBackground = src.openAIBackground
            copy.openAITransparent = src.openAITransparent
            context.insert(copy)
            try context.save()
            return .image(copy)
        case .video(let src):
            let copy = VideoGenProject(name: newName ?? (src.name + " Copy"))
            copy.groupID = src.groupID
            copy.provider = src.provider
            copy.prompt = src.prompt
            copy.negativePrompt = src.negativePrompt
            copy.useSeed = src.useSeed
            copy.seed = src.seed
            copy.googleModel = src.googleModel
            copy.googleAspectRatio = src.googleAspectRatio
            copy.googleResolution = src.googleResolution
            copy.googleDuration = src.googleDuration
            copy.googlePersonGeneration = src.googlePersonGeneration
            copy.googleNumberOfVideos = src.googleNumberOfVideos
            copy.googleGenerateAudio = src.googleGenerateAudio
            // Frames and references are copied so deleting either item cannot
            // pull the files out from under the other. The pending job and the
            // takes deliberately do not come along.
            copy.googleFirstFrameImagePath = src.googleFirstFrameImagePath.flatMap(storage.copyStoredFile(atRelative:))
            copy.googleLastFrameImagePath = src.googleLastFrameImagePath.flatMap(storage.copyStoredFile(atRelative:))
            copy.googleReferenceImagePaths = src.googleReferenceImagePaths.compactMap(storage.copyStoredFile(atRelative:))
            context.insert(copy)
            try context.save()
            return .video(copy)
        case .remotion(let src):
            #if os(macOS)
            let copy = RemotionProjectService.duplicate(src, newName: newName, context: context)
            copy.groupID = src.groupID
            try context.save()
            return .remotion(copy)
            #else
            throw MCPToolError.macOSOnly
            #endif
        case .caption(let src):
            let copy = CaptionProject(name: newName ?? (src.name + " Copy"))
            copy.groupID = src.groupID
            copy.audioFilePath = src.audioFilePath
            // The copy references the same audio, so it must not own it —
            // otherwise deleting either item would break the other.
            copy.ownsAudioFile = false
            copy.sourceKind = src.sourceKind
            copy.sourceNarrativeID = src.sourceNarrativeID
            copy.sourceNarrativeName = src.sourceNarrativeName
            copy.audioDurationMs = src.audioDurationMs
            copy.provider = src.provider
            copy.languageHint = src.languageHint
            copy.maxSpeakers = src.maxSpeakers
            copy.diarizationEnabled = src.diarizationEnabled
            copy.wordTimestampsEnabled = src.wordTimestampsEnabled
            copy.referenceUnits = src.referenceUnits
            copy.speakers = src.speakers
            copy.terms = src.terms
            copy.alignmentQuality = src.alignmentQuality
            copy.alignmentMatchRatio = src.alignmentMatchRatio
            // Version records are value types carrying their own UUIDs, so
            // copying them verbatim keeps `activeVersionID` and every segment's
            // `versionID` pointing at the right run.
            copy.versions = src.versions
            copy.activeVersionID = src.activeVersionID
            copy.displayedTranslationLanguage = src.displayedTranslationLanguage
            context.insert(copy)
            // Captions are child models, so they have to be cloned explicitly.
            // Iterating `segments` rather than `orderedSegments` on purpose: the
            // latter is the active version only, and a duplicate that silently
            // dropped every other take would be a data loss the user can't see.
            for segment in src.segments {
                let clone = CaptionSegment(
                    orderIndex: segment.orderIndex,
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    text: segment.text,
                    speakerId: segment.speakerId,
                    providerSpeakerNumber: segment.providerSpeakerNumber,
                    locale: segment.locale,
                    confidence: segment.confidence,
                    isEstimatedTiming: segment.isEstimatedTiming,
                    words: segment.words
                )
                clone.versionID = segment.versionID
                clone.translations = segment.translations
                clone.project = copy
                context.insert(clone)
            }
            try context.save()
            return .caption(copy)
        case .sequence(let src):
            let copy = SequenceProject(name: newName ?? (src.name + " Copy"))
            copy.groupID = src.groupID
            copy.width = src.width
            copy.height = src.height
            copy.fps = src.fps
            copy.timelinePixelsPerSecond = src.timelinePixelsPerSecond
            var timeline = src.timeline
            timeline.id = copy.id
            copy.timeline = timeline
            context.insert(copy)
            try context.save()
            return .sequence(copy)
        case .imported:
            throw MCPToolError.invalidArguments("imported files cannot be duplicated; call footage_import again")
        }
    }

    // MARK: - Folders

    private static func folderPayload(_ group: ProjectGroup, context: ModelContext) throws -> [String: Any] {
        var counts = try ProjectGroupService.projectCounts(groupID: group.id, context: context)
        // The service still counts under the model's old name.
        if let narration = counts.removeValue(forKey: "narrative") { counts[FootageKind.narration.rawValue] = narration }
        return [
            "id": group.id.uuidString,
            "name": group.name,
            "createdAt": isoDate(group.createdAt),
            "updatedAt": isoDate(group.updatedAt),
            "itemCount": counts.values.reduce(0, +),
            "itemCounts": counts
        ]
    }

    private static func folder(from arguments: [String: Any], context: ModelContext) throws -> ProjectGroup {
        guard let idString = arguments["folder_id"] as? String, let id = UUID(uuidString: idString) else {
            throw MCPToolError.invalidArguments("folder_id must be a folder id from folder_list")
        }
        return try ProjectGroupService.fetch(id: id, context: context)
    }

    private static func optionalFolderID(_ raw: Any?, context: ModelContext) throws -> UUID? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let value = raw as? String, let id = UUID(uuidString: value) else {
            throw MCPToolError.invalidArguments("folder_id must be a folder id or null")
        }
        _ = try ProjectGroupService.fetch(id: id, context: context)
        return id
    }

    private static func folderFilter(_ arguments: [String: Any], context: ModelContext) throws -> FolderFilter {
        guard arguments.keys.contains("folder_id") else { return .all }
        let raw = arguments["folder_id"]
        guard !(raw is NSNull) else { return .loose }
        guard let value = raw as? String, let id = UUID(uuidString: value) else {
            throw MCPToolError.invalidArguments("folder_id must be a folder id or null")
        }
        _ = try ProjectGroupService.fetch(id: id, context: context)
        return .folder(id)
    }

    private enum FolderFilter {
        case all
        case loose
        case folder(UUID)

        func matches(_ groupID: UUID?) -> Bool {
            switch self {
            case .all: return true
            case .loose: return groupID == nil
            case .folder(let expected): return groupID == expected
            }
        }
    }

    // MARK: - Encoders

    /// The library row: what `footage_list` returns per item.
    static func summary(_ item: Item, context: ModelContext) -> [String: Any] {
        var out: [String: Any] = [
            "id": item.id.uuidString,
            "kind": item.kind.rawValue,
            "name": item.name,
            "folderId": item.groupID.map { $0.uuidString as Any } ?? NSNull(),
            "createdAt": isoDate(item.createdAt),
            "updatedAt": isoDate(item.updatedAt),
        ]
        let takes = versions(of: item, context: context)
        out["versionCount"] = takes.count
        out["sourceId"] = newestSourceID(of: item) as Any? ?? NSNull()
        switch item {
        case .caption(let p):
            out["captionCount"] = p.activeSegmentCount
            out["hasAudio"] = p.hasAudio
        case .remotion(let p):
            out["durationSeconds"] = p.durationSeconds
            out["width"] = p.compositionWidth
            out["height"] = p.compositionHeight
            out["fps"] = p.compositionFps
        case .sequence(let s):
            out["width"] = s.width
            out["height"] = s.height
            out["fps"] = s.fps
            out["durationSeconds"] = s.timeline.duration
            out["clipCount"] = s.timeline.allClips.count
        case .imported(let a):
            out["mediaKind"] = a.kind
            out["durationSeconds"] = a.durationSeconds
            out["width"] = a.width
            out["height"] = a.height
        case .video(let p):
            if p.hasPendingJob { out["pendingJobId"] = p.pendingJobID as Any }
        default:
            break
        }
        return out
    }

    /// The `sourceId` the library drags for this item: its newest take.
    private static func newestSourceID(of item: Item) -> String? {
        switch item {
        case .music(let p):
            return p.generatedFiles.max { $0.createdAt < $1.createdAt }.map { DocumentMediaResolver.sourceID(.music, $0.id) }
        case .narration(let p):
            return p.generatedFiles.max { $0.createdAt < $1.createdAt }.map { DocumentMediaResolver.sourceID(.narration, $0.id) }
        case .image(let p):
            return p.generatedFiles.max { $0.createdAt < $1.createdAt }.map { DocumentMediaResolver.sourceID(.image, $0.id) }
        case .video(let p):
            return p.generatedFiles.max { $0.createdAt < $1.createdAt }.map { DocumentMediaResolver.sourceID(.video, $0.id) }
        case .caption(let p):
            return p.activeSegmentCount > 0 ? DocumentMediaResolver.sourceID(.caption, p.projectUUID) : nil
        case .remotion(let p):
            return DocumentMediaResolver.sourceID(.remotion, p.id)
        case .imported(let a):
            return DocumentMediaResolver.sourceID(.imported, a.id)
        case .sequence:
            return nil
        }
    }

    /// The item's takes, newest first, labelled the way the footage browser
    /// labels them.
    static func versions(of item: Item, context: ModelContext) -> [[String: Any]] {
        switch item {
        case .music(let p):
            let files = p.generatedFiles.sorted { $0.createdAt > $1.createdAt }
            return files.enumerated().map { i, f in
                [
                    "id": f.id.uuidString,
                    "label": "v\(files.count - i)",
                    "sourceId": DocumentMediaResolver.sourceID(.music, f.id),
                    "audioPath": f.audioFilePath,
                    "lyrics": f.lyricsText as Any,
                    "durationSeconds": f.durationSeconds,
                    "createdAt": isoDate(f.createdAt),
                ]
            }
        case .narration(let p):
            let files = p.generatedFiles.sorted { $0.createdAt > $1.createdAt }
            return files.enumerated().map { i, f in
                [
                    "id": f.id.uuidString,
                    "label": "v\(files.count - i)",
                    "sourceId": DocumentMediaResolver.sourceID(.narration, f.id),
                    "audioPath": f.audioFilePath,
                    "transcript": f.transcriptText,
                    "provider": f.providerName,
                    "speakers": f.speakerSummary,
                    "durationSeconds": f.durationSeconds,
                    "createdAt": isoDate(f.createdAt),
                ]
            }
        case .image(let p):
            let files = p.generatedFiles.sorted { $0.createdAt > $1.createdAt }
            return files.enumerated().map { i, f in
                [
                    "id": f.id.uuidString,
                    "label": "v\(files.count - i)",
                    "sourceId": DocumentMediaResolver.sourceID(.image, f.id),
                    "imagePath": f.imageFilePath,
                    "prompt": f.prompt,
                    "createdAt": isoDate(f.createdAt),
                ]
            }
        case .video(let p):
            let files = p.generatedFiles.sorted { $0.createdAt > $1.createdAt }
            return files.enumerated().map { i, f in
                [
                    "id": f.id.uuidString,
                    "label": "v\(files.count - i)",
                    "sourceId": DocumentMediaResolver.sourceID(.video, f.id),
                    "videoPath": f.videoFilePath,
                    "thumbnailPath": f.thumbnailFilePath as Any,
                    "prompt": f.prompt,
                    "model": f.modelID,
                    "durationSeconds": f.durationSeconds,
                    "width": f.width,
                    "height": f.height,
                    "createdAt": isoDate(f.createdAt),
                ]
            }
        case .caption(let p):
            // Transcript versions. Only the active one goes on a timeline, so
            // the sourceId lives on the item rather than on each version.
            return p.orderedVersions.map { v in
                [
                    "id": v.id.uuidString,
                    "label": "v\(v.number)",
                    "number": v.number,
                    "language": v.languageCode,
                    "provider": v.provider,
                    "captionCount": v.segmentCount,
                    "isActive": v.id == p.activeVersionID,
                    "createdAt": isoDate(v.createdAt),
                ]
            }
        case .remotion(let p):
            // Renders are a cache keyed by source hash; the composition itself
            // is what goes on a timeline and re-renders when it changes.
            return RemotionRenderService.renders(for: p, context: context)
                .sorted { $0.versionNumber > $1.versionNumber }
                .map { r in
                    [
                        "id": r.id.uuidString,
                        "label": r.versionLabel,
                        "path": r.videoURL.path,
                        "width": r.width,
                        "height": r.height,
                        "fps": r.fps,
                        "durationSeconds": r.durationSeconds,
                        "createdAt": isoDate(r.createdAt),
                    ]
                }
        case .sequence(let s):
            return SequenceRenderService.renders(for: s, context: context).map(MCPSequenceHandlers.renderJSON)
        case .imported:
            return []
        }
    }

    /// The item's full state: summary, parameters and takes.
    static func full(_ item: Item, context: ModelContext) -> [String: Any] {
        var out: [String: Any]
        switch item {
        case .music(let p): out = musicFields(p)
        case .narration(let p): out = narrationFields(p)
        case .image(let p): out = imageFields(p)
        case .video(let p): out = videoFields(p)
        case .remotion(let p): out = remotionFields(p)
        case .caption(let p): out = MCPCaptionHandlers.summary(p)
        case .sequence(let s): out = MCPSequenceHandlers.timelineJSON(s, context: context)
        case .imported(let a): out = importedFields(a)
        }
        out.merge(summary(item, context: context)) { _, row in row }
        out["versions"] = versions(of: item, context: context)
        return out
    }

    /// Full state of a narration item. Shared with the podcast tools.
    static func narrationFull(_ p: NarrativeProject, context: ModelContext) -> [String: Any] {
        full(.narration(p), context: context)
    }

    private static func narrationFields(_ p: NarrativeProject) -> [String: Any] {
        [
            "provider": p.provider,
            "sceneDescription": p.sceneDescription,
            "notes": p.notes,
            "context": p.context,
            "azureOutputFormat": p.azureOutputFormat,
            "speakers": p.speakers.map { speaker -> [String: Any] in
                [
                    "id": speaker.id.uuidString,
                    "displayName": speaker.displayName,
                    "voice": speaker.voice,
                    "geminiVoice": speaker.geminiVoice,
                    "azureVoice": speaker.azureVoice,
                    "azurePitch": speaker.azurePitch,
                    "azureRate": speaker.azureRate,
                    "azureVolume": speaker.azureVolume,
                    "azureRole": speaker.azureRole,
                    "azureStyleDegree": speaker.azureStyleDegree
                ]
            },
            "paragraphs": p.paragraphs.map { para -> [String: Any] in
                [
                    "id": para.id.uuidString,
                    "speakerId": para.speakerId.uuidString,
                    "emotion": para.emotion,
                    "content": para.content
                ]
            },
        ]
    }

    private static func musicFields(_ p: MusicProject) -> [String: Any] {
        [
            "inputMode": p.inputMode,
            "promptText": p.promptText,
            "generalPrompt": p.generalPrompt,
            "genre": p.genre,
            "instruments": p.instruments,
            "bpm": p.bpm,
            "keyScale": p.keyScale,
            "mood": p.mood,
            "musicLength": p.musicLength,
            "generationType": p.generationType,
            "lyricsLanguage": p.lyricsLanguage,
            "outputFormat": p.outputFormat,
            "referenceImagePaths": p.referenceImagePaths,
            "songStructureEntries": p.songStructureEntries.map {
                [
                    "id": $0.id.uuidString,
                    "type": $0.type.rawValue,
                    "startTime": $0.startTime,
                    "endTime": $0.endTime,
                    "intensity": $0.intensity,
                    "description": $0.description
                ] as [String: Any]
            },
            "lyricEntries": p.lyricEntries.map {
                [
                    "id": $0.id.uuidString,
                    "timestamp": $0.timestamp,
                    "content": $0.content
                ] as [String: Any]
            },
        ]
    }

    private static func imageFields(_ p: ImageGenProject) -> [String: Any] {
        [
            "provider": p.provider,
            "prompt": p.prompt,
            "googleModel": p.googleModel,
            "googleAspectRatio": p.googleAspectRatio,
            "googleResolution": p.googleResolution,
            "openAIModel": p.openAIModel,
            "openAISize": p.openAISize,
            "openAICustomWidth": p.openAICustomWidth,
            "openAICustomHeight": p.openAICustomHeight,
            "openAIQuality": p.openAIQuality,
            "openAIFormat": p.openAIFormat,
            "openAICompression": p.openAICompression,
            "openAIBackground": p.openAIBackground,
            "openAITransparent": p.openAITransparent,
        ]
    }

    private static func videoFields(_ p: VideoGenProject) -> [String: Any] {
        [
            "provider": p.provider,
            "prompt": p.prompt,
            "negativePrompt": p.negativePrompt,
            "useSeed": p.useSeed,
            "seed": p.seed,
            "googleModel": p.googleModel,
            "googleAspectRatio": p.googleAspectRatio,
            "googleResolution": p.googleResolution,
            "googleDuration": p.googleDuration,
            "googlePersonGeneration": p.googlePersonGeneration,
            "googleNumberOfVideos": p.googleNumberOfVideos,
            "googleGenerateAudio": p.googleGenerateAudio,
            "googleFirstFrameImagePath": p.googleFirstFrameImagePath as Any,
            "googleLastFrameImagePath": p.googleLastFrameImagePath as Any,
            "googleReferenceImagePaths": p.googleReferenceImagePaths,
            // Surfaced so an agent whose video_generate call timed out can tell
            // a job that is still running from one that never started.
            "pendingJobId": p.pendingJobID as Any,
            "pendingJobStartedAt": p.pendingJobStartedAt.map(isoDate) as Any,
        ]
    }

    private static func remotionFields(_ p: RemotionProject) -> [String: Any] {
        [
            "text": p.text,
            "durationSeconds": p.durationSeconds,
            "themeColorHex": p.themeColorHex,
            "prompt": p.prompt,
            "compositionWidth": p.compositionWidth,
            "compositionHeight": p.compositionHeight,
            "compositionFps": p.compositionFps,
            "compositionSource": p.compositionSource,
            "imagePaths": p.imagePaths,
            "referenceImagePath": p.referenceImagePath as Any,
            "audioFilePaths": p.audioFilePaths,
        ]
    }

    private static func importedFields(_ a: ImportedAsset) -> [String: Any] {
        [
            "mediaKind": a.kind,
            "path": a.relativePath.map { ProjectStorage.for(model: a).absoluteURL(for: $0).path } ?? a.originalPath,
            "referenced": a.isReferenced,
            "durationSeconds": a.durationSeconds,
            "width": a.width,
            "height": a.height,
        ]
    }

    // MARK: - Field appliers

    /// Patch a captions item's settings. The captions themselves are edited
    /// through the caption_* tools, not here.
    private static func applyCaptionFields(_ p: CaptionProject, fields: [String: Any]) {
        if let s = fields["name"] as? String { p.name = s }
        if let s = fields["provider"] as? String {
            // "" clears the override and falls back to the app default.
            if s.isEmpty || CaptionProvider(rawValue: s) != nil { p.provider = s }
        }
        if let s = fields["language"] as? String { p.languageHint = s }
        if let n = fields["maxSpeakers"] as? Int { p.maxSpeakers = clampCaptionMaxSpeakers(n) }
        if let b = fields["diarizationEnabled"] as? Bool { p.diarizationEnabled = b }
        if let b = fields["wordTimestampsEnabled"] as? Bool { p.wordTimestampsEnabled = b }
    }

    private static func applyNarrationFields(_ p: NarrativeProject, fields: [String: Any]) {
        if let s = fields["name"] as? String { p.name = s }
        if let s = fields["provider"] as? String, NarrativeProvider(rawValue: s) != nil { p.provider = s }
        if let s = fields["sceneDescription"] as? String { p.sceneDescription = s }
        if let s = fields["notes"] as? String { p.notes = s }
        if let s = fields["context"] as? String { p.context = s }
        if let s = fields["azureOutputFormat"] as? String, AzureAudioFormat(rawValue: s) != nil { p.azureOutputFormat = s }
        if let arr = fields["speakers"] as? [[String: Any]] {
            p.speakers = arr.map { dict in
                NarrativeSpeaker(
                    id: (dict["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
                    displayName: (dict["displayName"] as? String) ?? "",
                    voice: (dict["voice"] as? String) ?? GeminiVoice.achernar.rawValue,
                    geminiVoice: (dict["geminiVoice"] as? String) ?? "",
                    azureVoice: (dict["azureVoice"] as? String) ?? "",
                    azurePitch: (dict["azurePitch"] as? String) ?? "",
                    azureRate: (dict["azureRate"] as? String) ?? "",
                    azureVolume: (dict["azureVolume"] as? String) ?? "",
                    azureRole: (dict["azureRole"] as? String) ?? "",
                    azureStyleDegree: (dict["azureStyleDegree"] as? Double) ?? 1.0
                )
            }
        }
        if let arr = fields["paragraphs"] as? [[String: Any]] {
            p.paragraphs = arr.map { dict in
                NarrativeParagraph(
                    id: (dict["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
                    speakerId: (dict["speakerId"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
                    emotion: (dict["emotion"] as? String) ?? "",
                    content: (dict["content"] as? String) ?? ""
                )
            }
        }
    }

    private static func applyMusicFields(_ p: MusicProject, fields: [String: Any]) {
        if let s = fields["name"] as? String { p.name = s }
        if let s = fields["inputMode"] as? String, InputMode(rawValue: s) != nil { p.inputMode = s }
        if let s = fields["promptText"] as? String { p.promptText = s }
        if let s = fields["generalPrompt"] as? String { p.generalPrompt = s }
        if let s = fields["genre"] as? String, MusicGenre(rawValue: s) != nil { p.genre = s }
        if let arr = fields["instruments"] as? [String] { p.instruments = arr }
        if let n = fields["bpm"] as? Int { p.bpm = n } else if let n = fields["bpm"] as? Double { p.bpm = Int(n) }
        if let s = fields["keyScale"] as? String, KeyScale(rawValue: s) != nil { p.keyScale = s }
        if let s = fields["mood"] as? String, Mood(rawValue: s) != nil { p.mood = s }
        if let s = fields["musicLength"] as? String, MusicLength(rawValue: s) != nil { p.musicLength = s }
        if let s = fields["generationType"] as? String, GenerationType(rawValue: s) != nil { p.generationType = s }
        if let s = fields["lyricsLanguage"] as? String, LyricsLanguage(rawValue: s) != nil { p.lyricsLanguage = s }
        if let s = fields["outputFormat"] as? String, AudioFormat(rawValue: s) != nil { p.outputFormat = s }
        if let arr = fields["songStructureEntries"] as? [[String: Any]] {
            p.songStructureEntries = arr.compactMap { dict in
                guard let typeRaw = dict["type"] as? String,
                      let typeEnum = SongSectionType(rawValue: typeRaw) else { return nil }
                return SongStructureEntry(
                    id: (dict["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
                    type: typeEnum,
                    startTime: (dict["startTime"] as? Double) ?? 0,
                    endTime: (dict["endTime"] as? Double) ?? 0,
                    intensity: (dict["intensity"] as? Double) ?? 0.5,
                    description: (dict["description"] as? String) ?? ""
                )
            }
        }
        if let arr = fields["lyricEntries"] as? [[String: Any]] {
            p.lyricEntries = arr.map { dict in
                LyricEntry(
                    id: (dict["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
                    timestamp: (dict["timestamp"] as? Double) ?? 0,
                    content: (dict["content"] as? String) ?? ""
                )
            }
        }
    }

    private static func applyImageFields(_ p: ImageGenProject, fields: [String: Any]) {
        if let s = fields["name"] as? String { p.name = s }
        if let s = fields["provider"] as? String, ImageProvider(rawValue: s) != nil { p.provider = s }
        if let s = fields["prompt"] as? String { p.prompt = s }
        if let s = fields["googleModel"] as? String { p.googleModel = s }
        if let s = fields["googleAspectRatio"] as? String, ImageAspectRatio(rawValue: s) != nil { p.googleAspectRatio = s }
        if let s = fields["googleResolution"] as? String, ImageResolution(rawValue: s) != nil { p.googleResolution = s }
        if let s = fields["openAIModel"] as? String { p.openAIModel = s }
        if let s = fields["openAISize"] as? String, ImageSize(rawValue: s) != nil { p.openAISize = s }
        if let n = fields["openAICustomWidth"] as? Int { p.openAICustomWidth = n }
        if let n = fields["openAICustomHeight"] as? Int { p.openAICustomHeight = n }
        if let s = fields["openAIQuality"] as? String, ImageQuality(rawValue: s) != nil { p.openAIQuality = s }
        if let s = fields["openAIFormat"] as? String, ImageFormat(rawValue: s) != nil { p.openAIFormat = s }
        if let n = fields["openAICompression"] as? Int { p.openAICompression = n }
        if let s = fields["openAIBackground"] as? String, ImageBackground(rawValue: s) != nil { p.openAIBackground = s }
        if let b = fields["openAITransparent"] as? Bool { p.openAITransparent = b }
    }

    private static func applyVideoFields(_ p: VideoGenProject, fields: [String: Any]) {
        if let s = fields["name"] as? String { p.name = s }
        if let s = fields["prompt"] as? String { p.prompt = s }
        if let s = fields["negativePrompt"] as? String { p.negativePrompt = s }
        if let s = fields["googleModel"] as? String { p.googleModel = s }
        if let s = fields["googleAspectRatio"] as? String, VideoAspectRatio(rawValue: s) != nil { p.googleAspectRatio = s }
        if let s = fields["googleResolution"] as? String, VideoResolution(rawValue: s) != nil { p.googleResolution = s }
        if let s = fields["googleDuration"] as? String, VideoDuration(rawValue: s) != nil { p.googleDuration = s }
        if let n = fields["googleDuration"] as? Int, VideoDuration(rawValue: String(n)) != nil { p.googleDuration = String(n) }
        if let s = fields["googlePersonGeneration"] as? String, VideoPersonGeneration(rawValue: s) != nil { p.googlePersonGeneration = s }
        if let n = fields["googleNumberOfVideos"] as? Int { p.googleNumberOfVideos = n }
        if let b = fields["googleGenerateAudio"] as? Bool { p.googleGenerateAudio = b }
        if let b = fields["useSeed"] as? Bool { p.useSeed = b }
        if let n = fields["seed"] as? Int { p.seed = n }
        // The agent can set fields in any order, so the combination is only
        // legal once every key has been applied.
        VeoModelFamily.clamp(p)
    }

    private static func applySequenceFields(_ s: SequenceProject, fields: [String: Any]) {
        if let name = fields["name"] as? String { s.name = name }
        var timeline = s.timeline
        var touched = false
        if let w = intValue(fields["width"]), w > 0 { timeline.width = w; s.width = w; touched = true }
        if let h = intValue(fields["height"]), h > 0 { timeline.height = h; s.height = h; touched = true }
        if let f = intValue(fields["fps"]), f > 0 { timeline.fps = f; s.fps = f; touched = true }
        if touched { s.timeline = timeline }
    }

    #if os(macOS)
    private static func applyRemotionFields(_ p: RemotionProject, fields: [String: Any]) {
        if let s = fields["name"] as? String { p.name = s }
        if let s = fields["text"] as? String { p.text = s }
        if let n = fields["durationSeconds"] as? Double { p.durationSeconds = n }
        else if let n = fields["durationSeconds"] as? Int { p.durationSeconds = Double(n) }
        if let s = fields["themeColorHex"] as? String { p.themeColorHex = s }
        if let s = fields["prompt"] as? String { p.prompt = s }
        if let n = fields["compositionWidth"] as? Int { p.compositionWidth = n }
        if let n = fields["compositionHeight"] as? Int { p.compositionHeight = n }
        if let n = fields["compositionFps"] as? Int { p.compositionFps = n }

        let providedSource = fields["compositionSource"] as? String
        if let s = providedSource { p.compositionSource = s }

        // Keep src/Composition.tsx on disk in sync. Remotion's still/render CLI
        // reads durationInFrames / fps / width / height from the COMPOSITION_*
        // exports in this file (see Packages/RxRemotion/Sources/RxRemotion/Resources/Template/src/Root.tsx). If we
        // only update the SwiftData model, `bun remotion still --frame N` keeps
        // clamping to the old durationInFrames.
        let constantKeys = ["durationSeconds", "compositionWidth", "compositionHeight", "compositionFps"]
        let touchedConstants = constantKeys.contains(where: { fields[$0] != nil })
        if providedSource != nil || touchedConstants {
            var source = p.compositionSource
            if touchedConstants && !source.isEmpty {
                let patched = RemotionCodeBuilder.patchProjectConstants(in: source, project: p)
                if patched != source {
                    source = patched
                    p.compositionSource = patched
                }
            }
            if !source.isEmpty {
                try? RemotionCodeBuilder.writeComposition(project: p, source: source)
            }
        }
    }
    #endif

    // MARK: - Schema bits

    private static func kindProperty(_ kinds: [FootageKind]) -> [String: Any] {
        [
            "type": "string",
            "enum": kinds.map(\.rawValue),
            "description": "A footage kind, as the library names them."
        ]
    }

    private static let footageIDProperty: [String: Any] = [
        "type": "string",
        "description": "The item's id from footage_list."
    ]

    private static let folderIDProperty: [String: Any] = [
        "type": "string",
        "description": "A folder id from folder_list."
    ]

    private static let nullableFolderIDProperty: [String: Any] = [
        "anyOf": [
            ["type": "string"],
            ["type": "null"]
        ],
        "description": "A folder id from folder_list. Null means items in no folder; omit from footage_list to include every folder."
    ]

    private static func intValue(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let d = value as? Double { return Int(d) }
        return nil
    }
}

private func isoDate(_ d: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: d)
}
