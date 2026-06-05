import Foundation
import SwiftData

/// Podcast tools. A "podcast" is backed by the existing `NarrativeProject`
/// (multi-speaker TTS): the podcast's *content* is its ordered paragraphs, its
/// *speakers* map to `NarrativeSpeaker`, and the *backend* is the TTS provider
/// (Gemini | Azure). These tools give MCP clients a podcast-shaped surface over
/// that model: create a podcast, add/update/remove content lines, discover the
/// speakers/params a backend supports, and patch podcast settings.
@MainActor
enum MCPPodcastHandlers {
    static let descriptors: [MCPToolDescriptor] = [
        MCPToolDescriptor(
            name: "podcast_create",
            description: "Create a new podcast (backed by a narrative TTS project). Returns the full podcast state including its id, default backend, and the seeded default speaker.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Display name. Defaults to 'Untitled Podcast'."] as [String: Any]
                ]
            ]
        ),
        MCPToolDescriptor(
            name: "podcast_list_speakers",
            description: "List the speakers (available voices) and tunable params for a podcast backend. Pass `backend` ('Gemini' or 'Azure') to scope; omit to get both. Gemini exposes a fixed catalog of named voices (each with a vibe) and supports at most 2 speakers; Azure takes a free-form Azure short voice name plus prosody params (pitch/rate/volume), a speaking role, and a style degree. Use this before configuring speakers via podcast_update_settings.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "backend": ["type": "string", "enum": ["Gemini", "Azure"], "description": "Which TTS backend to describe. Omit for all backends."] as [String: Any]
                ]
            ]
        ),
        MCPToolDescriptor(
            name: "podcast_add_content",
            description: "Append (or insert) one content line to a podcast. Each line is spoken by one speaker. `speaker_id` must reference a speaker on the podcast (see podcast get/settings); if omitted the podcast's first speaker is used. Optional `index` inserts at that 0-based position instead of appending. Returns the created line (with its id) and the updated content list.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "podcast_id": ["type": "string", "description": "Podcast id."] as [String: Any],
                    "content": ["type": "string", "description": "The text this speaker says."] as [String: Any],
                    "speaker_id": ["type": "string", "description": "Optional speaker UUID. Defaults to the first speaker."] as [String: Any],
                    "emotion": ["type": "string", "description": "Optional delivery/emotion hint (e.g. enthusiastic, sad, whispers)."] as [String: Any],
                    "index": ["type": "integer", "description": "Optional 0-based insert position. Defaults to end."] as [String: Any]
                ],
                "required": ["podcast_id", "content"]
            ]
        ),
        MCPToolDescriptor(
            name: "podcast_update_content",
            description: "Update an existing podcast content line by id. Only the provided fields change. Returns the updated line and the full content list.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "podcast_id": ["type": "string", "description": "Podcast id."] as [String: Any],
                    "content_id": ["type": "string", "description": "Content line UUID (a paragraph id)."] as [String: Any],
                    "content": ["type": "string", "description": "New text. Omit to leave unchanged."] as [String: Any],
                    "speaker_id": ["type": "string", "description": "New speaker UUID. Omit to leave unchanged."] as [String: Any],
                    "emotion": ["type": "string", "description": "New emotion hint. Omit to leave unchanged."] as [String: Any]
                ],
                "required": ["podcast_id", "content_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "podcast_remove_content",
            description: "Remove a podcast content line by id. Returns the remaining content list.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "podcast_id": ["type": "string", "description": "Podcast id."] as [String: Any],
                    "content_id": ["type": "string", "description": "Content line UUID to remove."] as [String: Any]
                ],
                "required": ["podcast_id", "content_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "podcast_update_settings",
            description: "Patch podcast settings. Recognized fields: name, backend (Gemini|Azure), sceneDescription, notes, context, azureOutputFormat (mp3|wav), and speakers (array of {id?, displayName, voice (Gemini voice name), geminiVoice, azureVoice, azurePitch, azureRate, azureVolume, azureRole, azureStyleDegree}). Replacing `speakers` re-defines the podcast's cast; use podcast_list_speakers to discover valid voices/params. This does NOT touch content lines — use the podcast_*_content tools for those. Unknown keys are ignored.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "podcast_id": ["type": "string", "description": "Podcast id."] as [String: Any],
                    "fields": ["type": "object", "additionalProperties": true, "description": "Settings to patch."] as [String: Any]
                ],
                "required": ["podcast_id", "fields"]
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
        case "podcast_create":
            let displayName = (arguments["name"] as? String) ?? "Untitled Podcast"
            let p = NarrativeProject(name: displayName)
            context.insert(p)
            try context.save()
            return MCPToolRegistry.jsonResult(MCPProjectHandlers.narrativeFull(p))

        case "podcast_list_speakers":
            return MCPToolRegistry.jsonResult(listSpeakers(backend: arguments["backend"] as? String))

        case "podcast_add_content":
            return try addContent(arguments: arguments, context: context)

        case "podcast_update_content":
            return try updateContent(arguments: arguments, context: context)

        case "podcast_remove_content":
            return try removeContent(arguments: arguments, context: context)

        case "podcast_update_settings":
            return try updateSettings(arguments: arguments, context: context)

        default:
            throw MCPToolError.invalidArguments("unrecognized: \(name)")
        }
    }

    // MARK: - Backend catalog

    private static func listSpeakers(backend raw: String?) -> [String: Any] {
        let requested = raw.flatMap(NarrativeProvider.init(rawValue:))
        let backends: [NarrativeProvider] = requested.map { [$0] } ?? NarrativeProvider.allCases
        let emotions = EmotionPreset.allCases.map(\.rawValue)
        let out = backends.map { provider -> [String: Any] in
            switch provider {
            case .gemini:
                return [
                    "backend": provider.rawValue,
                    "maxSpeakers": provider.maxSpeakers as Any,
                    "voices": GeminiVoice.allCases.map { ["name": $0.rawValue, "vibe": $0.vibe] as [String: Any] },
                    "params": [
                        "speakerFields": ["voice", "emotion"],
                        "voiceField": "voice",
                        "emotions": emotions
                    ] as [String: Any]
                ]
            case .azure:
                return [
                    "backend": provider.rawValue,
                    "maxSpeakers": provider.maxSpeakers as Any,
                    // Azure voices are arbitrary Azure short names (e.g. en-US-JennyNeural);
                    // there's no fixed enum, so callers supply the string directly.
                    "voices": [] as [Any],
                    "params": [
                        "speakerFields": ["azureVoice", "azurePitch", "azureRate", "azureVolume", "azureRole", "azureStyleDegree", "emotion"],
                        "voiceField": "azureVoice",
                        "voiceNote": "Any Azure neural short name, e.g. en-US-JennyNeural.",
                        "roles": AzureRole.allCases.map(\.rawValue),
                        "pitch": AzureProsodyPreset.pitchSuggestions,
                        "rate": AzureProsodyPreset.rateSuggestions,
                        "volume": AzureProsodyPreset.volumeSuggestions,
                        "styleDegree": ["min": 0.01, "max": 2.0, "default": 1.0] as [String: Any],
                        "outputFormats": AzureAudioFormat.allCases.map(\.rawValue),
                        "emotions": emotions
                    ] as [String: Any]
                ]
            }
        }
        return ["backends": out]
    }

    // MARK: - Content (paragraph) mutations

    private static func addContent(arguments: [String: Any], context: ModelContext) throws -> [String: Any] {
        let p = try podcast(from: arguments, context: context)
        guard let content = arguments["content"] as? String else {
            throw MCPToolError.invalidArguments("missing content")
        }

        let speakerId: UUID
        if let raw = arguments["speaker_id"] as? String {
            guard let uuid = UUID(uuidString: raw), p.speakers.contains(where: { $0.id == uuid }) else {
                throw MCPToolError.invalidArguments("speaker_id does not match any speaker on this podcast")
            }
            speakerId = uuid
        } else if let first = p.speakers.first {
            speakerId = first.id
        } else {
            throw MCPToolError.invalidArguments("podcast has no speakers; configure speakers via podcast_update_settings first")
        }

        let paragraph = NarrativeParagraph(
            speakerId: speakerId,
            emotion: (arguments["emotion"] as? String) ?? "",
            content: content
        )

        if let index = intArg(arguments["index"]), index >= 0, index < p.paragraphs.count {
            p.paragraphs.insert(paragraph, at: index)
        } else {
            p.paragraphs.append(paragraph)
        }
        p.updatedAt = Date()
        try context.save()

        return MCPToolRegistry.jsonResult([
            "ok": true,
            "content": encodeParagraph(paragraph),
            "contents": p.paragraphs.map(encodeParagraph)
        ] as [String: Any])
    }

    private static func updateContent(arguments: [String: Any], context: ModelContext) throws -> [String: Any] {
        let p = try podcast(from: arguments, context: context)
        let id = try contentID(from: arguments)
        guard let index = p.paragraphs.firstIndex(where: { $0.id == id }) else {
            throw MCPToolError.invalidArguments("content_id not found on this podcast")
        }

        var paragraph = p.paragraphs[index]
        if let s = arguments["content"] as? String { paragraph.content = s }
        if let s = arguments["emotion"] as? String { paragraph.emotion = s }
        if let raw = arguments["speaker_id"] as? String {
            guard let uuid = UUID(uuidString: raw), p.speakers.contains(where: { $0.id == uuid }) else {
                throw MCPToolError.invalidArguments("speaker_id does not match any speaker on this podcast")
            }
            paragraph.speakerId = uuid
        }
        p.paragraphs[index] = paragraph
        p.updatedAt = Date()
        try context.save()

        return MCPToolRegistry.jsonResult([
            "ok": true,
            "content": encodeParagraph(paragraph),
            "contents": p.paragraphs.map(encodeParagraph)
        ] as [String: Any])
    }

    private static func removeContent(arguments: [String: Any], context: ModelContext) throws -> [String: Any] {
        let p = try podcast(from: arguments, context: context)
        let id = try contentID(from: arguments)
        guard p.paragraphs.contains(where: { $0.id == id }) else {
            throw MCPToolError.invalidArguments("content_id not found on this podcast")
        }
        p.paragraphs.removeAll { $0.id == id }
        p.updatedAt = Date()
        try context.save()

        return MCPToolRegistry.jsonResult([
            "ok": true,
            "removed": id.uuidString,
            "contents": p.paragraphs.map(encodeParagraph)
        ] as [String: Any])
    }

    // MARK: - Settings

    private static func updateSettings(arguments: [String: Any], context: ModelContext) throws -> [String: Any] {
        let p = try podcast(from: arguments, context: context)
        guard let fields = arguments["fields"] as? [String: Any] else {
            throw MCPToolError.invalidArguments("missing fields")
        }

        if let s = fields["name"] as? String { p.name = s }
        // Accept either `backend` (podcast vocabulary) or `provider` (model vocabulary).
        if let s = (fields["backend"] as? String) ?? (fields["provider"] as? String),
           NarrativeProvider(rawValue: s) != nil { p.provider = s }
        if let s = fields["sceneDescription"] as? String { p.sceneDescription = s }
        if let s = fields["notes"] as? String { p.notes = s }
        if let s = fields["context"] as? String { p.context = s }
        if let s = fields["azureOutputFormat"] as? String, AzureAudioFormat(rawValue: s) != nil { p.azureOutputFormat = s }
        if let arr = fields["speakers"] as? [[String: Any]] {
            p.speakers = arr.map(makeSpeaker(from:))
        }
        p.updatedAt = Date()
        try context.save()

        return MCPToolRegistry.jsonResult(MCPProjectHandlers.narrativeFull(p))
    }

    // MARK: - Helpers

    private static func podcast(from arguments: [String: Any], context: ModelContext) throws -> NarrativeProject {
        guard let id = arguments["podcast_id"] as? String else {
            throw MCPToolError.invalidArguments("missing podcast_id")
        }
        return try MCPProjectHandlers.fetchNarrative(id: id, context: context)
    }

    private static func contentID(from arguments: [String: Any]) throws -> UUID {
        guard let raw = arguments["content_id"] as? String, let uuid = UUID(uuidString: raw) else {
            throw MCPToolError.invalidArguments("missing or invalid content_id")
        }
        return uuid
    }

    private static func intArg(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? Double { return Int(n) }
        return nil
    }

    private static func encodeParagraph(_ para: NarrativeParagraph) -> [String: Any] {
        [
            "id": para.id.uuidString,
            "speakerId": para.speakerId.uuidString,
            "emotion": para.emotion,
            "content": para.content
        ]
    }

    private static func makeSpeaker(from dict: [String: Any]) -> NarrativeSpeaker {
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
