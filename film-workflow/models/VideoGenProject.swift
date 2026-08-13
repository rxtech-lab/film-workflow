import Foundation
import SwiftData

@Model
final class VideoGenProject: GroupableProject {
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var groupID: UUID?

    var provider: String = VideoProvider.google.rawValue
    var prompt: String = ""
    /// Google only — the OpenAI-compatible video API has no equivalent field.
    var negativePrompt: String = ""
    var useSeed: Bool = false
    var seed: Int = 0

    // MARK: - Google / Veo parameters

    var googleModel: String = ""
    var googleAspectRatio: String = VideoAspectRatio.r16x9.rawValue
    var googleResolution: String = VideoResolution.r720p.rawValue
    var googleDuration: String = VideoDuration.s8.rawValue
    var googlePersonGeneration: String = VideoPersonGeneration.allowAll.rawValue
    var googleNumberOfVideos: Int = 1
    var googleGenerateAudio: Bool = true
    /// Relative `images/…` paths, same convention as `GeneratedImage.imageFilePath`,
    /// so a still from the Image Gen tab can be handed straight to Veo.
    var googleFirstFrameImagePath: String?
    var googleLastFrameImagePath: String?
    var googleReferenceImagePaths: [String] = []

    // MARK: - In-flight job
    //
    // Veo runs for minutes and bills on submission, so the operation handle is
    // persisted the moment the provider accepts it. Quitting mid-generation
    // then costs nothing: the tab resumes polling the same job on reopen
    // instead of paying for a second render.

    /// The provider's job handle — a Google operation name (`models/…/operations/…`).
    var pendingJobID: String?
    var pendingJobProvider: String?
    var pendingJobModel: String?
    var pendingJobPrompt: String?
    var pendingJobStartedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \GeneratedVideo.project)
    var generatedFiles: [GeneratedVideo]

    init(name: String) {
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.groupID = nil
        self.provider = VideoProvider.google.rawValue
        self.prompt = ""
        self.negativePrompt = ""
        self.useSeed = false
        self.seed = 0
        self.googleModel = ""
        self.googleAspectRatio = VideoAspectRatio.r16x9.rawValue
        self.googleResolution = VideoResolution.r720p.rawValue
        self.googleDuration = VideoDuration.s8.rawValue
        self.googlePersonGeneration = VideoPersonGeneration.allowAll.rawValue
        self.googleNumberOfVideos = 1
        self.googleGenerateAudio = true
        self.googleReferenceImagePaths = []
        self.generatedFiles = []
    }

    // MARK: - Enum accessors

    var providerEnum: VideoProvider {
        get { VideoProvider(rawValue: provider) ?? .google }
        set { provider = newValue.rawValue }
    }

    var googleAspectRatioEnum: VideoAspectRatio {
        get { VideoAspectRatio(rawValue: googleAspectRatio) ?? .r16x9 }
        set { googleAspectRatio = newValue.rawValue }
    }

    var googleResolutionEnum: VideoResolution {
        get { VideoResolution(rawValue: googleResolution) ?? .r720p }
        set { googleResolution = newValue.rawValue }
    }

    var googleDurationEnum: VideoDuration {
        get { VideoDuration(rawValue: googleDuration) ?? .s8 }
        set { googleDuration = newValue.rawValue }
    }

    var googlePersonGenerationEnum: VideoPersonGeneration {
        get { VideoPersonGeneration(rawValue: googlePersonGeneration) ?? .allowAll }
        set { googlePersonGeneration = newValue.rawValue }
    }

    // MARK: - Derived

    var veoFamily: VeoModelFamily { .from(googleModel) }

    var hasPendingJob: Bool {
        !(pendingJobID ?? "").isEmpty
    }

    /// A job old enough that resuming is more likely to hang than to succeed.
    /// Google keeps operations around for roughly two days; a day is a
    /// comfortable margin for offering "discard" instead.
    var pendingJobIsStale: Bool {
        guard let startedAt = pendingJobStartedAt else { return false }
        return Date().timeIntervalSince(startedAt) > 24 * 60 * 60
    }

    func clearPendingJob() {
        pendingJobID = nil
        pendingJobProvider = nil
        pendingJobModel = nil
        pendingJobPrompt = nil
        pendingJobStartedAt = nil
    }
}
