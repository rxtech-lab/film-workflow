import Foundation
import SwiftData

/// One exported mp4 of a sequence, kept inside the film package.
@Model
final class SequenceRender {
    var id: UUID = UUID()
    var sequenceID: UUID
    var versionNumber: Int
    /// Package-relative, `Renders/Sequences/<sequenceID>/v003.mp4`.
    var filePath: String
    var thumbnailFilePath: String?
    var width: Int
    var height: Int
    var fps: Int
    var durationSeconds: Double
    var preset: String
    var createdAt: Date
    /// Package-relative caption files written beside this version, such as
    /// `Renders/Sequences/<sequenceID>/v003.en.srt`. Empty unless the render
    /// delivered captions as separate files.
    var captionFilePaths: [String] = []

    init(sequenceID: UUID, versionNumber: Int, filePath: String, thumbnailFilePath: String? = nil, width: Int, height: Int, fps: Int, durationSeconds: Double, preset: String, captionFilePaths: [String] = []) {
        self.sequenceID = sequenceID
        self.versionNumber = versionNumber
        self.filePath = filePath
        self.thumbnailFilePath = thumbnailFilePath
        self.width = width
        self.height = height
        self.fps = fps
        self.durationSeconds = durationSeconds
        self.preset = preset
        self.createdAt = Date()
        self.captionFilePaths = captionFilePaths
    }

    var videoURL: URL { ProjectStorage.for(model: self).absoluteURL(for: filePath) }
    var captionFileURLs: [URL] { captionFilePaths.map { ProjectStorage.for(model: self).absoluteURL(for: $0) } }
    var thumbnailURL: URL? { thumbnailFilePath.map { ProjectStorage.for(model: self).absoluteURL(for: $0) } }
    var versionLabel: String { "v\(versionNumber)" }
    var dimensionsLabel: String {
        var parts: [String] = []
        if durationSeconds > 0 { parts.append("\(Int(durationSeconds.rounded()))s") }
        if width > 0, height > 0 { parts.append("\(width)×\(height)") }
        if fps > 0 { parts.append("\(fps) fps") }
        parts.append(preset.uppercased())
        return parts.joined(separator: " · ")
    }
}
