import Foundation
import SwiftData

@Model
final class ImageGenProject {
    var name: String
    var createdAt: Date
    var updatedAt: Date

    var provider: String
    var prompt: String

    // Google / google-routed OpenAI parameters.
    var googleAspectRatio: String
    var googleResolution: String

    // OpenAI image-gen parameters.
    var openAIModel: String
    var openAISize: String
    var openAICustomWidth: Int = 1024
    var openAICustomHeight: Int = 1024
    var openAIQuality: String
    var openAIFormat: String
    var openAICompression: Int
    var openAIBackground: String
    var openAITransparent: Bool

    @Relationship(deleteRule: .cascade, inverse: \GeneratedImage.project)
    var generatedFiles: [GeneratedImage]

    init(name: String) {
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.provider = ImageProvider.openai.rawValue
        self.prompt = ""
        self.googleAspectRatio = ImageAspectRatio.r1x1.rawValue
        self.googleResolution = ImageResolution.r1k.rawValue
        self.openAIModel = ""
        self.openAISize = ImageSize.s1024x1024.rawValue
        self.openAICustomWidth = 1024
        self.openAICustomHeight = 1024
        self.openAIQuality = ImageQuality.auto.rawValue
        self.openAIFormat = ImageFormat.png.rawValue
        self.openAICompression = 80
        self.openAIBackground = ImageBackground.auto.rawValue
        self.openAITransparent = false
        self.generatedFiles = []
    }

    // MARK: - Enum accessors

    var providerEnum: ImageProvider {
        get { ImageProvider(rawValue: provider) ?? .openai }
        set { provider = newValue.rawValue }
    }

    var googleAspectRatioEnum: ImageAspectRatio {
        get { ImageAspectRatio(rawValue: googleAspectRatio) ?? .r1x1 }
        set { googleAspectRatio = newValue.rawValue }
    }

    var googleResolutionEnum: ImageResolution {
        get { ImageResolution(rawValue: googleResolution) ?? .r1k }
        set { googleResolution = newValue.rawValue }
    }

    var openAISizeEnum: ImageSize {
        get { ImageSize(rawValue: openAISize) ?? .s1024x1024 }
        set { openAISize = newValue.rawValue }
    }

    var openAIQualityEnum: ImageQuality {
        get { ImageQuality(rawValue: openAIQuality) ?? .auto }
        set { openAIQuality = newValue.rawValue }
    }

    var openAIFormatEnum: ImageFormat {
        get { ImageFormat(rawValue: openAIFormat) ?? .png }
        set { openAIFormat = newValue.rawValue }
    }

    var openAIBackgroundEnum: ImageBackground {
        get { ImageBackground(rawValue: openAIBackground) ?? .auto }
        set { openAIBackground = newValue.rawValue }
    }
}
