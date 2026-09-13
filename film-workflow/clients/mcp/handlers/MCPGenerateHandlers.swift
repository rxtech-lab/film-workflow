import Foundation
import SwiftData

/// One "generate" tool per generator kind. Each runs the same flow the
/// inspector's Generate button runs and keeps the result as a new take on the
/// item, so the library, the viewer and the timeline see it immediately.
@MainActor
enum MCPGenerateHandlers {
    static let descriptors: [MCPToolDescriptor] = [
        MCPToolDescriptor(
            name: "narration_generate",
            description: "Speak a narration item's paragraphs with its speakers' voices (Gemini or Azure TTS, per the item's provider) and keep the audio and transcript as a new take. Set paragraphs and speakers first with footage_update or the podcast_* tools.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "footage_id": ["type": "string", "description": "A narration item's id."] as [String: Any]
                ],
                "required": ["footage_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "music_generate",
            description: "Generate a music item's track (Lyria) from its prompt, genre, structure and lyrics settings, and keep it as a new take.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "footage_id": ["type": "string", "description": "A music item's id."] as [String: Any]
                ],
                "required": ["footage_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "image_generate",
            description: "Generate an image item's picture with its configured provider, model and prompt, and keep it as a new take.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "footage_id": ["type": "string", "description": "An image item's id."] as [String: Any]
                ],
                "required": ["footage_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "video_generate",
            description: "Generate a video item's clip (Veo) with its configured model and prompt, and keep it as a new take. Blocks for several minutes. If the call times out the job keeps running: check with video_job_status and collect it with video_resume rather than generating again.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "footage_id": ["type": "string", "description": "A video item's id."] as [String: Any]
                ],
                "required": ["footage_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "video_job_status",
            description: "Whether a video item still has a generation running with the provider, without waiting for it.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "footage_id": ["type": "string", "description": "A video item's id."] as [String: Any]
                ],
                "required": ["footage_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "video_resume",
            description: "Wait for a video item's already-submitted generation and keep the result as a new take. Use after video_generate timed out. Never starts a new generation, so it cannot bill twice.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "footage_id": ["type": "string", "description": "A video item's id."] as [String: Any]
                ],
                "required": ["footage_id"]
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
        guard let footageID = arguments["footage_id"] as? String else {
            throw MCPToolError.invalidArguments("missing footage_id")
        }
        let config: AppConfig
        do {
            config = try AppConfig.loadFromKeychain()
        } catch {
            throw MCPToolError.underlying(error)
        }

        switch name {
        case "narration_generate":
            let project = try MCPLibraryHandlers.fetchNarration(id: footageID, context: context)
            let generated = try await NarrativeGenerationService.generate(
                project: project, context: context, config: config
            )
            try context.save()
            return MCPToolRegistry.jsonResult([
                "ok": true,
                "sourceId": DocumentMediaResolver.sourceID(.narration, generated.id),
                "audioPath": generated.audioFilePath,
                "transcript": generated.transcriptText,
                "provider": generated.providerName,
                "durationSeconds": generated.durationSeconds
            ] as [String: Any])
        case "music_generate":
            let project = try MCPLibraryHandlers.fetchMusic(id: footageID, context: context)
            let generated = try await MusicGenerationService.generate(
                project: project, context: context, config: config
            )
            try context.save()
            return MCPToolRegistry.jsonResult([
                "ok": true,
                "sourceId": DocumentMediaResolver.sourceID(.music, generated.id),
                "audioPath": generated.audioFilePath,
                "lyrics": generated.lyricsText as Any,
                "durationSeconds": generated.durationSeconds
            ] as [String: Any])
        case "image_generate":
            let project = try MCPLibraryHandlers.fetchImage(id: footageID, context: context)
            let generated = try await ImageGenerationService.generate(
                project: project, context: context, config: config
            )
            try context.save()
            return MCPToolRegistry.jsonResult([
                "ok": true,
                "sourceId": DocumentMediaResolver.sourceID(.image, generated.id),
                "imagePath": generated.imageFilePath,
                "prompt": generated.prompt
            ] as [String: Any])
        case "video_generate":
            let project = try MCPLibraryHandlers.fetchVideo(id: footageID, context: context)
            let generated = try await VideoGenerationService.generate(
                project: project, context: context, config: config
            )
            try context.save()
            return MCPToolRegistry.jsonResult(videoResult(generated))
        case "video_job_status":
            let project = try MCPLibraryHandlers.fetchVideo(id: footageID, context: context)
            return MCPToolRegistry.jsonResult([
                "ok": true,
                "pending": project.hasPendingJob,
                "stale": project.pendingJobIsStale,
                "pendingJobId": project.pendingJobID as Any,
                "startedAt": project.pendingJobStartedAt.map {
                    ISO8601DateFormatter().string(from: $0)
                } as Any
            ] as [String: Any])
        case "video_resume":
            let project = try MCPLibraryHandlers.fetchVideo(id: footageID, context: context)
            guard let generated = try await VideoGenerationService.resume(
                project: project, context: context, config: config
            ) else {
                return MCPToolRegistry.jsonResult([
                    "ok": false,
                    "error": "No generation is pending for this item."
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
            "sourceId": DocumentMediaResolver.sourceID(.video, generated.id),
            "videoPath": generated.videoFilePath,
            "thumbnailPath": generated.thumbnailFilePath as Any,
            "prompt": generated.prompt,
            "model": generated.modelID,
            "durationSeconds": generated.durationSeconds,
            "width": generated.width,
            "height": generated.height
        ] as [String: Any]
    }
}
