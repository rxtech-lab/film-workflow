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
        ),
        MCPToolDescriptor(
            name: "video_generate",
            description: "Run video generation for a video project, using the project's configured model and parameters. Blocks for several minutes — if the call times out, the job keeps running: read `pendingJobId` with project_get, or call video_job_status, and use video_resume to collect the result.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string", "description": "VideoGenProject id."] as [String: Any]
                ],
                "required": ["project_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "video_job_status",
            description: "Report whether a video project has a generation still running with the provider, without waiting for it.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string", "description": "VideoGenProject id."] as [String: Any]
                ],
                "required": ["project_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "video_resume",
            description: "Wait for a video project's already-submitted generation and save the result. Use after video_generate timed out. Does not start a new generation, so it never bills twice.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string", "description": "VideoGenProject id."] as [String: Any]
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
        case "video_generate":
            let project = try MCPProjectHandlers.fetchVideo(id: projectId, context: context)
            let generated = try await VideoGenerationService.generate(
                project: project, context: context, config: config
            )
            try context.save()
            return MCPToolRegistry.jsonResult(videoResult(generated))
        case "video_job_status":
            let project = try MCPProjectHandlers.fetchVideo(id: projectId, context: context)
            return MCPToolRegistry.jsonResult([
                "ok": true,
                "pending": project.hasPendingJob,
                "stale": project.pendingJobIsStale,
                "pending_job_id": project.pendingJobID as Any,
                "started_at": project.pendingJobStartedAt.map {
                    ISO8601DateFormatter().string(from: $0)
                } as Any
            ] as [String: Any])
        case "video_resume":
            let project = try MCPProjectHandlers.fetchVideo(id: projectId, context: context)
            guard let generated = try await VideoGenerationService.resume(
                project: project, context: context, config: config
            ) else {
                return MCPToolRegistry.jsonResult([
                    "ok": false,
                    "error": "No generation is pending for this project."
                ] as [String: Any])
            }
            try context.save()
            return MCPToolRegistry.jsonResult(videoResult(generated))
        default:
            throw MCPToolError.invalidArguments("unrecognized: \(name)")
        }
    }

    private static func videoResult(_ generated: GeneratedVideo) -> [String: Any] {
        [
            "ok": true,
            "video_path": generated.videoFilePath,
            "thumbnail_path": generated.thumbnailFilePath as Any,
            "prompt": generated.prompt,
            "model": generated.modelID,
            "duration_seconds": generated.durationSeconds,
            "width": generated.width,
            "height": generated.height
        ] as [String: Any]
    }
}
