import Foundation
import SwiftData

/// The one place video generation happens, shared by the Video tab and the MCP
/// `video_generate` tool.
///
/// Split into submit and wait because a video job is expensive and slow: the
/// provider's handle is written to the store the instant it is issued, so
/// cancelling, crashing, or quitting costs the user nothing but time. Anything
/// that abandons the wait leaves `pendingJob*` in place for `resume` to pick up;
/// only success and a hard provider failure clear it.
@MainActor
enum VideoGenerationService {
    @discardableResult
    static func generate(
        project: VideoGenProject,
        context: ModelContext,
        config: AppConfig,
        onProgress: VideoProgressHandler? = nil
    ) async throws -> GeneratedVideo {
        let job = try await start(project: project, context: context, config: config, onProgress: onProgress)
        return try await finish(job: job, project: project, context: context, config: config, onProgress: onProgress)
    }

    /// Reconnects to a job a previous run submitted. Returns nil when the
    /// project has nothing pending.
    @discardableResult
    static func resume(
        project: VideoGenProject,
        context: ModelContext,
        config: AppConfig,
        onProgress: VideoProgressHandler? = nil
    ) async throws -> GeneratedVideo? {
        guard let id = project.pendingJobID, !id.isEmpty else { return nil }
        let provider = VideoProvider(rawValue: project.pendingJobProvider ?? "") ?? project.providerEnum
        let job = VideoGenJob(id: id, provider: provider)
        return try await finish(job: job, project: project, context: context, config: config, onProgress: onProgress)
    }

    /// Forgets a pending job without waiting for it. The provider may still
    /// finish and bill it; this only stops the app from tracking it.
    static func abandonPendingJob(_ project: VideoGenProject, context: ModelContext) {
        project.clearPendingJob()
        project.updatedAt = Date()
        try? context.save()
    }

    // MARK: - Phases

    private static func start(
        project: VideoGenProject,
        context: ModelContext,
        config: AppConfig,
        onProgress: VideoProgressHandler?
    ) async throws -> VideoGenJob {
        onProgress?(.submitting)

        guard !project.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VideoGenError.missingConfig
        }

        let job: VideoGenJob
        switch project.providerEnum {
        case .google:
            guard !config.googleAIKey.isEmpty, !project.googleModel.isEmpty else {
                throw VideoGenError.missingConfig
            }
            let family = project.veoFamily
            job = try await VideoGenClient.startGoogleVeo(
                prompt: project.prompt,
                negativePrompt: project.negativePrompt,
                model: project.googleModel,
                aspectRatio: project.googleAspectRatioEnum,
                resolution: project.googleResolutionEnum,
                duration: project.googleDurationEnum,
                personGeneration: project.googlePersonGenerationEnum,
                numberOfVideos: project.googleNumberOfVideos,
                generateAudio: project.googleGenerateAudio,
                seed: project.useSeed ? project.seed : nil,
                firstFrame: project.googleFirstFrameImagePath.flatMap(VideoInputImage.init(relativePath:)),
                lastFrame: project.googleLastFrameImagePath.flatMap(VideoInputImage.init(relativePath:)),
                referenceImages: family.supportsReferenceImages
                    ? project.googleReferenceImagePaths.compactMap(VideoInputImage.init(relativePath:))
                    : [],
                apiKey: config.googleAIKey
            )
        }

        // Persisted before anything blocks: from here on the job survives a
        // quit, and resuming it is free where re-submitting would not be.
        project.pendingJobID = job.id
        project.pendingJobProvider = project.provider
        project.pendingJobModel = currentModel(for: project)
        project.pendingJobPrompt = project.prompt
        project.pendingJobStartedAt = Date()
        project.updatedAt = Date()
        try? context.save()

        return job
    }

    private static func finish(
        job: VideoGenJob,
        project: VideoGenProject,
        context: ModelContext,
        config: AppConfig,
        onProgress: VideoProgressHandler?
    ) async throws -> GeneratedVideo {
        let startedAt = project.pendingJobStartedAt ?? Date()
        let prompt = project.pendingJobPrompt ?? project.prompt
        let model = project.pendingJobModel ?? currentModel(for: project)

        let result: VideoGenResult
        do {
            switch job.provider {
            case .google:
                guard !config.googleAIKey.isEmpty else { throw VideoGenError.missingConfig }
                result = try await VideoGenClient.awaitGoogleCompletion(
                    operationName: job.id,
                    apiKey: config.googleAIKey,
                    startedAt: startedAt,
                    onProgress: onProgress
                )
            }
        } catch let error as VideoGenError {
            // The provider said no — the job will never produce anything, so
            // stop offering to resume it. A timeout is deliberately not in this
            // list: that job is still running.
            switch error {
            case .jobFailed, .noVideoInResponse:
                project.clearPendingJob()
                try? context.save()
            default:
                break
            }
            throw error
        }

        onProgress?(.saving)

        let relativePath = try FileStorage.importVideo(
            movingFrom: result.fileURL,
            fileExtension: result.fileExtension
        )
        let videoURL = FileStorage.absoluteURL(for: relativePath)

        let thumbnailPath = await VideoThumbnailer.generate(for: videoURL)
        let probed = await VideoThumbnailer.probe(url: videoURL)

        let generated = GeneratedVideo(
            videoFilePath: relativePath,
            thumbnailFilePath: thumbnailPath,
            prompt: prompt,
            modelID: model,
            providerName: job.provider.rawValue,
            durationSeconds: probed?.duration ?? 0,
            width: probed?.width ?? 0,
            height: probed?.height ?? 0,
            project: project
        )
        context.insert(generated)

        project.clearPendingJob()
        project.updatedAt = Date()
        try? context.save()

        return generated
    }

    private static func currentModel(for project: VideoGenProject) -> String {
        switch project.providerEnum {
        case .google: return project.googleModel
        }
    }
}
