import Foundation
import SwiftData

/// Per-domain "generate" tools — these run a full generation flow and persist
/// the result via the same services the SwiftUI tabs use.
@MainActor
enum MCPGenerateHandlers {
    static let descriptors: [MCPToolDescriptor] = [
        MCPToolDescriptor(
            name: "narrative_generate",
            description: "Run TTS for a narrative project and save the resulting audio + transcript. Uses the keys configured in Settings → AI Provider.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string", "description": "NarrativeProject id."] as [String: Any]
                ],
                "required": ["project_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "music_generate",
            description: "Run music generation for a music project (Lyria via the Google AI key). Saves the audio + lyrics to disk.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string", "description": "MusicProject id."] as [String: Any]
                ],
                "required": ["project_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "image_generate",
            description: "Run image generation for an image project, using the project's configured provider/model/parameters.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string", "description": "ImageGenProject id."] as [String: Any]
                ],
                "required": ["project_id"]
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
        guard let projectId = arguments["project_id"] as? String else {
            throw MCPToolError.invalidArguments("missing project_id")
        }
        let config: AppConfig
        do {
            config = try AppConfig.loadFromKeychain()
        } catch {
            throw MCPToolError.underlying(error)
        }

        switch name {
        case "narrative_generate":
            let project = try MCPProjectHandlers.fetchNarrative(id: projectId, context: context)
            let generated = try await NarrativeGenerationService.generate(
                project: project, context: context, config: config
            )
            try context.save()
            return MCPToolRegistry.jsonResult([
                "ok": true,
                "audio_path": generated.audioFilePath,
                "transcript": generated.transcriptText,
                "provider": generated.providerName
            ] as [String: Any])
        case "music_generate":
            let project = try MCPProjectHandlers.fetchMusic(id: projectId, context: context)
            let generated = try await MusicGenerationService.generate(
                project: project, context: context, config: config
            )
            try context.save()
            return MCPToolRegistry.jsonResult([
                "ok": true,
                "audio_path": generated.audioFilePath,
                "lyrics": generated.lyricsText as Any
            ] as [String: Any])
        case "image_generate":
            let project = try MCPProjectHandlers.fetchImage(id: projectId, context: context)
            let generated = try await ImageGenerationService.generate(
                project: project, context: context, config: config
            )
            try context.save()
            return MCPToolRegistry.jsonResult([
                "ok": true,
                "image_path": generated.imageFilePath,
                "prompt": generated.prompt
            ] as [String: Any])
        default:
            throw MCPToolError.invalidArguments("unrecognized: \(name)")
        }
    }
}
