import Foundation
import SwiftData

/// One rendered mp4 of a Remotion project, kept inside the film package.
///
/// Doubles as the render cache: `sourceHash` covers the composition source,
/// assets and output settings, so a timeline render can reuse a file when
/// nothing changed. Linked to its project by scalar id, like `groupID`, so a
/// project deletion removes renders explicitly rather than by cascade.
@Model
final class RemotionRender {
    var id: UUID = UUID()
    var projectID: UUID
    var versionNumber: Int
    var sourceHash: String
    var width: Int
    var height: Int
    var fps: Int
    /// Package-relative, `Renders/Remotion/<projectID>/v003-<hash8>.mp4`.
    var filePath: String
    var thumbnailFilePath: String?
    var durationSeconds: Double
    var createdAt: Date

    init(
        projectID: UUID,
        versionNumber: Int,
        sourceHash: String,
        width: Int,
        height: Int,
        fps: Int,
        filePath: String,
        thumbnailFilePath: String? = nil,
        durationSeconds: Double = 0
    ) {
        self.projectID = projectID
        self.versionNumber = versionNumber
        self.sourceHash = sourceHash
        self.width = width
        self.height = height
        self.fps = fps
        self.filePath = filePath
        self.thumbnailFilePath = thumbnailFilePath
        self.durationSeconds = durationSeconds
        self.createdAt = Date()
    }

    var videoURL: URL {
        ProjectStorage.for(model: self).absoluteURL(for: filePath)
    }

    var thumbnailURL: URL? {
        thumbnailFilePath.map { ProjectStorage.for(model: self).absoluteURL(for: $0) }
    }

    var versionLabel: String { "v\(versionNumber)" }

    /// "8s · 1920×1080 · 30 fps"
    var dimensionsLabel: String {
        var parts: [String] = []
        if durationSeconds > 0 { parts.append("\(Int(durationSeconds.rounded()))s") }
        parts.append("\(width)×\(height)")
        parts.append("\(fps) fps")
        return parts.joined(separator: " · ")
    }
}
