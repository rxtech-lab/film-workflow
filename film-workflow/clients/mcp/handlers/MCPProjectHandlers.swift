import Foundation
import SwiftData

/// Unified CRUD + duplicate, discriminated by `type`: "narrative" | "music" | "image" | "remotion".
@MainActor
enum MCPProjectHandlers {
    static let descriptors: [MCPToolDescriptor] = [
        MCPToolDescriptor(
            name: "list_projects",
            description: "List all projects of the given type. Returns id/name/createdAt/updatedAt.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "type": typeProperty
                ],
                "required": ["type"]
            ]
        ),
        MCPToolDescriptor(
            name: "get_project",
            description: "Fetch the full state of a project by id. Payload shape depends on `type`.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "type": typeProperty,
                    "id": ["type": "string", "description": "Project UUID."] as [String: Any]
                ],
                "required": ["type", "id"]
            ]
        ),
        MCPToolDescriptor(
            name: "create_project",
            description: "Create a new project of the given type. Returns the new project id.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "type": typeProperty,
                    "name": ["type": "string", "description": "Display name. Defaults to 'Untitled Project'."] as [String: Any]
                ],
                "required": ["type"]
            ]
        ),
        MCPToolDescriptor(
            name: "update_project",
            description: "Patch fields on a project. `fields` is an object whose recognized keys depend on `type` (see field allowlists in tool description). Unknown keys are ignored. Narrative fields: name, provider (Gemini|Azure), sceneDescription, notes, context, speakers (array of {displayName, voice, geminiVoice, azureVoice, azurePitch, azureRate, azureVolume, azureRole, azureStyleDegree}), paragraphs (array of {speakerId, emotion, content}), azureOutputFormat (mp3|wav). Music fields: name, inputMode (editor|prompt), promptText, generalPrompt, genre, instruments (array), bpm, keyScale, mood, musicLength, generationType (withLyrics|noLyrics), lyricsLanguage, outputFormat (mp3|wav), songStructureEntries (array of {type, startTime, endTime, intensity, description}), lyricEntries (array of {timestamp, content}). Image fields: name, provider (openai|google), prompt, googleModel, googleAspectRatio, googleResolution, openAIModel, openAISize, openAICustomWidth, openAICustomHeight, openAIQuality, openAIFormat, openAICompression, openAIBackground, openAITransparent. Remotion fields: name, text, durationSeconds, themeColorHex (#RRGGBB), prompt, compositionWidth, compositionHeight, compositionFps, compositionSource (TSX).",
            inputSchema: [
                "type": "object",
                "properties": [
                    "type": typeProperty,
                    "id": ["type": "string"] as [String: Any],
                    "fields": ["type": "object", "additionalProperties": true] as [String: Any]
                ],
                "required": ["type", "id", "fields"]
            ]
        ),
        MCPToolDescriptor(
            name: "delete_project",
            description: "Delete a project of the given type, including any owned files on disk.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "type": typeProperty,
                    "id": ["type": "string"] as [String: Any]
                ],
                "required": ["type", "id"]
            ]
        ),
        MCPToolDescriptor(
            name: "duplicate_project",
            description: "Duplicate a project of the given type. Generated-files history is NOT copied; reference assets / per-project remotion dir ARE copied.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "type": typeProperty,
                    "id": ["type": "string"] as [String: Any],
                    "new_name": ["type": "string", "description": "Optional. Defaults to '<original name> Copy'."] as [String: Any]
                ],
                "required": ["type", "id"]
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
        guard let typeRaw = arguments["type"] as? String,
              let type = ProjectType(rawValue: typeRaw) else {
            throw MCPToolError.unknownProjectType((arguments["type"] as? String) ?? "<missing>")
        }

        switch name {
        case "list_projects":
            return try listProjects(type: type, context: context)
        case "get_project":
            guard let id = arguments["id"] as? String else {
                throw MCPToolError.invalidArguments("missing id")
            }
            return try getProject(type: type, id: id, context: context)
        case "create_project":
            let displayName = (arguments["name"] as? String) ?? "Untitled Project"
            return try await createProject(type: type, name: displayName, context: context)
        case "update_project":
            guard let id = arguments["id"] as? String,
                  let fields = arguments["fields"] as? [String: Any] else {
                throw MCPToolError.invalidArguments("missing id or fields")
            }
            return try updateProject(type: type, id: id, fields: fields, context: context)
        case "delete_project":
            guard let id = arguments["id"] as? String else {
                throw MCPToolError.invalidArguments("missing id")
            }
            return try deleteProject(type: type, id: id, context: context)
        case "duplicate_project":
            guard let id = arguments["id"] as? String else {
                throw MCPToolError.invalidArguments("missing id")
            }
            let newName = arguments["new_name"] as? String
            return try duplicateProject(type: type, id: id, newName: newName, context: context)
        default:
            throw MCPToolError.invalidArguments("unrecognized: \(name)")
        }
    }

    // MARK: - Listing

    private static func listProjects(type: ProjectType, context: ModelContext) throws -> [String: Any] {
        switch type {
        case .narrative:
            let items = try context.fetch(FetchDescriptor<NarrativeProject>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            ))
            return MCPToolRegistry.jsonResult(items.map(narrativeSummary))
        case .music:
            let items = try context.fetch(FetchDescriptor<MusicProject>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            ))
            return MCPToolRegistry.jsonResult(items.map(musicSummary))
        case .image:
            let items = try context.fetch(FetchDescriptor<ImageGenProject>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            ))
            return MCPToolRegistry.jsonResult(items.map(imageSummary))
        case .remotion:
            #if os(macOS)
            let items = try context.fetch(FetchDescriptor<RemotionProject>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            ))
            return MCPToolRegistry.jsonResult(items.map(remotionSummary))
            #else
            throw MCPToolError.macOSOnly
            #endif
        case .caption:
            let items = try context.fetch(FetchDescriptor<CaptionProject>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            ))
            return MCPToolRegistry.jsonResult(items.map(MCPCaptionHandlers.summary))
        }
    }

    // MARK: - Get

    private static func getProject(type: ProjectType, id: String, context: ModelContext) throws -> [String: Any] {
        switch type {
        case .narrative:
            let p = try fetchNarrative(id: id, context: context)
            return MCPToolRegistry.jsonResult(narrativeFull(p))
        case .music:
            let p = try fetchMusic(id: id, context: context)
            return MCPToolRegistry.jsonResult(musicFull(p))
        case .image:
            let p = try fetchImage(id: id, context: context)
            return MCPToolRegistry.jsonResult(imageFull(p))
        case .remotion:
            #if os(macOS)
            let p = try fetchRemotion(id: id, context: context)
            return MCPToolRegistry.jsonResult(remotionFull(p))
            #else
            throw MCPToolError.macOSOnly
            #endif
        case .caption:
            // Summary only — a full transcript would blow the result size. Use
            // caption_list_segments to page through the captions themselves.
            let p = try MCPCaptionHandlers.fetchCaption(id: id, context: context)
            return MCPToolRegistry.jsonResult(MCPCaptionHandlers.summary(p))
        }
    }

    // MARK: - Create

    private static func createProject(type: ProjectType, name: String, context: ModelContext) async throws -> [String: Any] {
        switch type {
        case .narrative:
            let p = NarrativeProject(name: name)
            context.insert(p)
            try context.save()
            return MCPToolRegistry.jsonResult(narrativeSummary(p))
        case .music:
            let p = MusicProject(name: name)
            context.insert(p)
            try context.save()
            return MCPToolRegistry.jsonResult(musicSummary(p))
        case .image:
            let p = ImageGenProject(name: name)
            context.insert(p)
            try context.save()
            return MCPToolRegistry.jsonResult(imageSummary(p))
        case .remotion:
            #if os(macOS)
            let p = RemotionProject(name: name)
            p.createdViaMCP = true
            context.insert(p)
            try context.save()
            // Seed a default no-AI composition so callers get a ready-to-preview
            // project without a round-trip to the LLM agent. Then bring up Studio.
            let source = RemotionCodeBuilder.defaultComposition(project: p)
            p.compositionSource = source
            try? RemotionCodeBuilder.writeComposition(project: p, source: source)
            try? context.save()

            var studioStatus: String = "starting"
            var studioURL: String?
            do {
                try await RemotionRuntime.shared.start(projectId: p.id)
                studioURL = RemotionRuntime.shared.currentURL?.absoluteString
                studioStatus = "running"
            } catch {
                studioStatus = "failed: \(error.localizedDescription)"
            }

            var summary = remotionSummary(p)
            summary["studio"] = [
                "status": studioStatus,
                "url": studioURL as Any
            ] as [String: Any]
            summary["compositionSource"] = source
            return MCPToolRegistry.jsonResult(summary)
            #else
            throw MCPToolError.macOSOnly
            #endif
        case .caption:
            let p = CaptionProject(name: name)
            context.insert(p)
            try context.save()
            return MCPToolRegistry.jsonResult(MCPCaptionHandlers.summary(p))
        }
    }

    // MARK: - Update

    private static func updateProject(
        type: ProjectType,
        id: String,
        fields: [String: Any],
        context: ModelContext
    ) throws -> [String: Any] {
        switch type {
        case .narrative:
            let p = try fetchNarrative(id: id, context: context)
            applyNarrativeFields(p, fields: fields)
            p.updatedAt = Date()
            try context.save()
            return MCPToolRegistry.jsonResult(narrativeFull(p))
        case .music:
            let p = try fetchMusic(id: id, context: context)
            applyMusicFields(p, fields: fields)
            p.updatedAt = Date()
            try context.save()
            return MCPToolRegistry.jsonResult(musicFull(p))
        case .image:
            let p = try fetchImage(id: id, context: context)
            applyImageFields(p, fields: fields)
            p.updatedAt = Date()
            try context.save()
            return MCPToolRegistry.jsonResult(imageFull(p))
        case .remotion:
            #if os(macOS)
            let p = try fetchRemotion(id: id, context: context)
            applyRemotionFields(p, fields: fields)
            p.updatedAt = Date()
            try context.save()
            return MCPToolRegistry.jsonResult(remotionFull(p))
            #else
            throw MCPToolError.macOSOnly
            #endif
        case .caption:
            let p = try MCPCaptionHandlers.fetchCaption(id: id, context: context)
            applyCaptionFields(p, fields: fields)
            p.updatedAt = Date()
            try context.save()
            return MCPToolRegistry.jsonResult(MCPCaptionHandlers.summary(p))
        }
    }

    // MARK: - Delete

    private static func deleteProject(type: ProjectType, id: String, context: ModelContext) throws -> [String: Any] {
        switch type {
        case .narrative:
            let p = try fetchNarrative(id: id, context: context)
            for f in p.generatedFiles { FileStorage.deleteFile(at: f.audioFilePath) }
            context.delete(p)
        case .music:
            let p = try fetchMusic(id: id, context: context)
            for f in p.generatedFiles { FileStorage.deleteFile(at: f.audioFilePath) }
            for path in p.referenceImagePaths { FileStorage.deleteFile(at: path) }
            context.delete(p)
        case .image:
            let p = try fetchImage(id: id, context: context)
            for f in p.generatedFiles { FileStorage.deleteFile(at: f.imageFilePath) }
            context.delete(p)
        case .remotion:
            #if os(macOS)
            let p = try fetchRemotion(id: id, context: context)
            RemotionProjectService.delete(p, context: context)
            #else
            throw MCPToolError.macOSOnly
            #endif
        case .caption:
            let p = try MCPCaptionHandlers.fetchCaption(id: id, context: context)
            // Only delete audio the project owns; narrative-sourced projects
            // point at a GeneratedNarrative's file, which must survive.
            if p.ownsAudioFile, !p.audioFilePath.isEmpty {
                FileStorage.deleteFile(at: p.audioFilePath)
            }
            context.delete(p)
        }
        try context.save()
        return MCPToolRegistry.jsonResult(["ok": true, "id": id])
    }

    // MARK: - Duplicate

    private static func duplicateProject(
        type: ProjectType,
        id: String,
        newName: String?,
        context: ModelContext
    ) throws -> [String: Any] {
        switch type {
        case .narrative:
            let src = try fetchNarrative(id: id, context: context)
            let copy = NarrativeProject(name: newName ?? (src.name + " Copy"))
            copy.provider = src.provider
            copy.sceneDescription = src.sceneDescription
            copy.notes = src.notes
            copy.context = src.context
            copy.azureOutputFormat = src.azureOutputFormat
            copy.speakers = src.speakers
            copy.paragraphs = src.paragraphs
            context.insert(copy)
            try context.save()
            return MCPToolRegistry.jsonResult(narrativeSummary(copy))
        case .music:
            let src = try fetchMusic(id: id, context: context)
            let copy = MusicProject(name: newName ?? (src.name + " Copy"))
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
            #if os(macOS)
            copy.referenceImagePaths = src.referenceImagePaths.compactMap(RemotionProjectService.copyStoredFile(atRelative:))
            #else
            copy.referenceImagePaths = src.referenceImagePaths
            #endif
            context.insert(copy)
            try context.save()
            return MCPToolRegistry.jsonResult(musicSummary(copy))
        case .image:
            let src = try fetchImage(id: id, context: context)
            let copy = ImageGenProject(name: newName ?? (src.name + " Copy"))
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
            return MCPToolRegistry.jsonResult(imageSummary(copy))
        case .remotion:
            #if os(macOS)
            let src = try fetchRemotion(id: id, context: context)
            let copy = RemotionProjectService.duplicate(src, newName: newName, context: context)
            try context.save()
            return MCPToolRegistry.jsonResult(remotionSummary(copy))
            #else
            throw MCPToolError.macOSOnly
            #endif
        case .caption:
            let src = try MCPCaptionHandlers.fetchCaption(id: id, context: context)
            let copy = CaptionProject(name: newName ?? (src.name + " Copy"))
            copy.audioFilePath = src.audioFilePath
            // The copy references the same audio, so it must not own it —
            // otherwise deleting either project would break the other.
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
            context.insert(copy)
            // Captions are child models, so they have to be cloned explicitly.
            for segment in src.orderedSegments {
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
                clone.project = copy
                context.insert(clone)
            }
            try context.save()
            return MCPToolRegistry.jsonResult(MCPCaptionHandlers.summary(copy))
        }
    }

    // MARK: - Fetchers

    static func fetchNarrative(id: String, context: ModelContext) throws -> NarrativeProject {
        guard let uuid = UUID(uuidString: id) else { throw MCPToolError.projectNotFound(id) }
        let all = try context.fetch(FetchDescriptor<NarrativeProject>())
        guard let p = all.first(where: { summaryUUID(of: $0) == uuid }) else {
            throw MCPToolError.projectNotFound(id)
        }
        return p
    }

    static func fetchMusic(id: String, context: ModelContext) throws -> MusicProject {
        guard let uuid = UUID(uuidString: id) else { throw MCPToolError.projectNotFound(id) }
        let all = try context.fetch(FetchDescriptor<MusicProject>())
        guard let p = all.first(where: { summaryUUID(of: $0) == uuid }) else {
            throw MCPToolError.projectNotFound(id)
        }
        return p
    }

    static func fetchImage(id: String, context: ModelContext) throws -> ImageGenProject {
        guard let uuid = UUID(uuidString: id) else { throw MCPToolError.projectNotFound(id) }
        let all = try context.fetch(FetchDescriptor<ImageGenProject>())
        guard let p = all.first(where: { summaryUUID(of: $0) == uuid }) else {
            throw MCPToolError.projectNotFound(id)
        }
        return p
    }

    #if os(macOS)
    static func fetchRemotion(id: String, context: ModelContext) throws -> RemotionProject {
        guard let uuid = UUID(uuidString: id) else { throw MCPToolError.projectNotFound(id) }
        let all = try context.fetch(FetchDescriptor<RemotionProject>())
        guard let p = all.first(where: { $0.id == uuid }) else {
            throw MCPToolError.projectNotFound(id)
        }
        return p
    }
    #endif

    /// Stable id derived from the SwiftData PersistentIdentifier so we can hand a
    /// UUID-shaped identifier back to clients for the @Model types that don't
    /// declare an explicit `id`.
    static func stableID(of obj: any PersistentModel) -> UUID {
        // Hash the persistent identifier description into a UUID.
        let s = String(describing: obj.persistentModelID)
        return UUID.deterministic(from: s)
    }

    private static func summaryUUID(of p: NarrativeProject) -> UUID { stableID(of: p) }
    private static func summaryUUID(of p: MusicProject) -> UUID { stableID(of: p) }
    private static func summaryUUID(of p: ImageGenProject) -> UUID { stableID(of: p) }

    // MARK: - Encoders

    private static func narrativeSummary(_ p: NarrativeProject) -> [String: Any] {
        [
            "id": stableID(of: p).uuidString,
            "type": "narrative",
            "name": p.name,
            "createdAt": isoDate(p.createdAt),
            "updatedAt": isoDate(p.updatedAt)
        ]
    }
    private static func musicSummary(_ p: MusicProject) -> [String: Any] {
        [
            "id": stableID(of: p).uuidString,
            "type": "music",
            "name": p.name,
            "createdAt": isoDate(p.createdAt),
            "updatedAt": isoDate(p.updatedAt)
        ]
    }
    private static func imageSummary(_ p: ImageGenProject) -> [String: Any] {
        [
            "id": stableID(of: p).uuidString,
            "type": "image",
            "name": p.name,
            "createdAt": isoDate(p.createdAt),
            "updatedAt": isoDate(p.updatedAt)
        ]
    }
    #if os(macOS)
    private static func remotionSummary(_ p: RemotionProject) -> [String: Any] {
        [
            "id": p.id.uuidString,
            "type": "remotion",
            "name": p.name,
            "createdAt": isoDate(p.createdAt),
            "updatedAt": isoDate(p.updatedAt)
        ]
    }
    #else
    private static func remotionSummary(_ p: NSObject) -> [String: Any] { [:] }
    #endif

    static func narrativeFull(_ p: NarrativeProject) -> [String: Any] {
        var out = narrativeSummary(p)
        out["provider"] = p.provider
        out["sceneDescription"] = p.sceneDescription
        out["notes"] = p.notes
        out["context"] = p.context
        out["azureOutputFormat"] = p.azureOutputFormat
        out["speakers"] = p.speakers.map { speaker -> [String: Any] in
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
        }
        out["paragraphs"] = p.paragraphs.map { para -> [String: Any] in
            [
                "id": para.id.uuidString,
                "speakerId": para.speakerId.uuidString,
                "emotion": para.emotion,
                "content": para.content
            ]
        }
        out["generatedFiles"] = p.generatedFiles.map { f -> [String: Any] in
            [
                "audioFilePath": f.audioFilePath,
                "transcriptText": f.transcriptText,
                "providerName": f.providerName,
                "speakerSummary": f.speakerSummary,
                "createdAt": isoDate(f.createdAt)
            ]
        }
        return out
    }

    private static func musicFull(_ p: MusicProject) -> [String: Any] {
        var out = musicSummary(p)
        out["inputMode"] = p.inputMode
        out["promptText"] = p.promptText
        out["generalPrompt"] = p.generalPrompt
        out["genre"] = p.genre
        out["instruments"] = p.instruments
        out["bpm"] = p.bpm
        out["keyScale"] = p.keyScale
        out["mood"] = p.mood
        out["musicLength"] = p.musicLength
        out["generationType"] = p.generationType
        out["lyricsLanguage"] = p.lyricsLanguage
        out["outputFormat"] = p.outputFormat
        out["referenceImagePaths"] = p.referenceImagePaths
        out["songStructureEntries"] = p.songStructureEntries.map {
            [
                "id": $0.id.uuidString,
                "type": $0.type.rawValue,
                "startTime": $0.startTime,
                "endTime": $0.endTime,
                "intensity": $0.intensity,
                "description": $0.description
            ] as [String: Any]
        }
        out["lyricEntries"] = p.lyricEntries.map {
            [
                "id": $0.id.uuidString,
                "timestamp": $0.timestamp,
                "content": $0.content
            ] as [String: Any]
        }
        out["generatedFiles"] = p.generatedFiles.map {
            [
                "audioFilePath": $0.audioFilePath,
                "lyricsText": $0.lyricsText as Any,
                "createdAt": isoDate($0.createdAt)
            ] as [String: Any]
        }
        return out
    }

    private static func imageFull(_ p: ImageGenProject) -> [String: Any] {
        var out = imageSummary(p)
        out["provider"] = p.provider
        out["prompt"] = p.prompt
        out["googleModel"] = p.googleModel
        out["googleAspectRatio"] = p.googleAspectRatio
        out["googleResolution"] = p.googleResolution
        out["openAIModel"] = p.openAIModel
        out["openAISize"] = p.openAISize
        out["openAICustomWidth"] = p.openAICustomWidth
        out["openAICustomHeight"] = p.openAICustomHeight
        out["openAIQuality"] = p.openAIQuality
        out["openAIFormat"] = p.openAIFormat
        out["openAICompression"] = p.openAICompression
        out["openAIBackground"] = p.openAIBackground
        out["openAITransparent"] = p.openAITransparent
        out["generatedFiles"] = p.generatedFiles.map {
            [
                "imageFilePath": $0.imageFilePath,
                "prompt": $0.prompt,
                "createdAt": isoDate($0.createdAt)
            ] as [String: Any]
        }
        return out
    }

    #if os(macOS)
    private static func remotionFull(_ p: RemotionProject) -> [String: Any] {
        var out = remotionSummary(p)
        out["text"] = p.text
        out["durationSeconds"] = p.durationSeconds
        out["themeColorHex"] = p.themeColorHex
        out["prompt"] = p.prompt
        out["compositionWidth"] = p.compositionWidth
        out["compositionHeight"] = p.compositionHeight
        out["compositionFps"] = p.compositionFps
        out["compositionSource"] = p.compositionSource
        out["imagePaths"] = p.imagePaths
        out["referenceImagePath"] = p.referenceImagePath as Any
        out["audioFilePaths"] = p.audioFilePaths
        return out
    }
    #endif

    // MARK: - Field appliers

    /// Patch a caption project's settings. Captions themselves are edited via
    /// `caption_update_segment`, not here.
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

    private static func applyNarrativeFields(_ p: NarrativeProject, fields: [String: Any]) {
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
        // exports in this file (see RemotionRuntime/template/src/Root.tsx). If we
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

    private static let typeProperty: [String: Any] = [
        "type": "string",
        "enum": ["narrative", "music", "image", "remotion", "caption"],
        "description": "Which domain the project belongs to. For 'caption', project_get returns a summary only — use caption_list_segments to read the captions."
    ]
}

enum ProjectType: String {
    case narrative
    case music
    case image
    case remotion
    case caption
}

private func isoDate(_ d: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: d)
}

extension UUID {
    /// Build a deterministic UUID from a string. Used to surface SwiftData
    /// `PersistentIdentifier`s as stable UUID-shaped ids over MCP.
    static func deterministic(from s: String) -> UUID {
        var hasher = Hasher()
        hasher.combine(s)
        let h1 = hasher.finalize()
        var hasher2 = Hasher()
        hasher2.combine("salt:" + s)
        let h2 = hasher2.finalize()
        var bytes = [UInt8](repeating: 0, count: 16)
        var v1 = UInt64(bitPattern: Int64(h1))
        var v2 = UInt64(bitPattern: Int64(h2))
        for i in 0..<8 { bytes[i] = UInt8(v1 & 0xff); v1 >>= 8 }
        for i in 0..<8 { bytes[i + 8] = UInt8(v2 & 0xff); v2 >>= 8 }
        // Stamp version 4 / variant RFC4122.
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
