import Foundation
import SwiftData

@Model
final class GeneratedVideo {
    /// Relative, e.g. `videos/<uuid>.mp4`.
    var videoFilePath: String
    /// Locally extracted poster frame, `images/<uuid>.jpg`. Optional because a
    /// thumbnail failure must never discard an otherwise-good render.
    var thumbnailFilePath: String?
    var prompt: String
    var modelID: String
    var providerName: String
    var durationSeconds: Double
    var width: Int
    var height: Int
    var createdAt: Date
    var project: VideoGenProject?

    init(
        videoFilePath: String,
        thumbnailFilePath: String? = nil,
        prompt: String,
        modelID: String,
        providerName: String,
        durationSeconds: Double = 0,
        width: Int = 0,
        height: Int = 0,
        project: VideoGenProject
    ) {
        self.videoFilePath = videoFilePath
        self.thumbnailFilePath = thumbnailFilePath
        self.prompt = prompt
        self.modelID = modelID
        self.providerName = providerName
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.createdAt = Date()
        self.project = project
    }

    var videoURL: URL {
        FileStorage.absoluteURL(for: videoFilePath)
    }

    var thumbnailURL: URL? {
        thumbnailFilePath.map { FileStorage.absoluteURL(for: $0) }
    }

    var fileExtension: String {
        (videoFilePath as NSString).pathExtension
    }

    /// "8s · 1280×720", collapsing whichever half we couldn't probe.
    var dimensionsLabel: String {
        var parts: [String] = []
        if durationSeconds > 0 {
            parts.append("\(Int(durationSeconds.rounded()))s")
        }
        if width > 0, height > 0 {
            parts.append("\(width)×\(height)")
        }
        return parts.joined(separator: " · ")
    }
}
