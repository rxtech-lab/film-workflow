import CoreGraphics
import Foundation
import VideoEditorCore

// Every footage model the library shows can be dragged onto the timeline.
// The clip source ids follow `DocumentMediaResolver`'s grammar so the
// resolver can find the file again when the sequence plays or exports.

extension GeneratedMusic: TimelineDurationChangeable, TimelineCuttable, TimelineReversible, TimelineSpeedChangeable {
    var clipSource: ClipSource {
        ClipSource(id: DocumentMediaResolver.sourceID(.music, id), kind: .audio,
                   displayName: versionedName(project?.name ?? String(localized: "Music"), version: versionNumber))
    }
    var mediaURL: URL? { audioURL }
    var storedDuration: TimeInterval? { durationSeconds > 0 ? durationSeconds : nil }
    private var versionNumber: Int? { project.flatMap { takeNumber(of: id, in: $0.generatedFiles.map { ($0.id, $0.createdAt) }) } }
}

extension GeneratedNarrative: TimelineDurationChangeable, TimelineCuttable, TimelineReversible, TimelineSpeedChangeable {
    var clipSource: ClipSource {
        ClipSource(id: DocumentMediaResolver.sourceID(.narration, id), kind: .audio,
                   displayName: versionedName(project?.name ?? String(localized: "Narration"), version: versionNumber))
    }
    var mediaURL: URL? { audioURL }
    var storedDuration: TimeInterval? { durationSeconds > 0 ? durationSeconds : nil }
    private var versionNumber: Int? { project.flatMap { takeNumber(of: id, in: $0.generatedFiles.map { ($0.id, $0.createdAt) }) } }
}

extension GeneratedImage: TimelineDurationChangeable, TimelineCuttable {
    var clipSource: ClipSource {
        ClipSource(id: DocumentMediaResolver.sourceID(.image, id), kind: .image,
                   displayName: versionedName(project?.name ?? String(localized: "Image"), version: versionNumber))
    }
    var mediaURL: URL? { imageURL }
    var thumbnailURL: URL? { imageURL }
    private var versionNumber: Int? { project.flatMap { takeNumber(of: id, in: $0.generatedFiles.map { ($0.id, $0.createdAt) }) } }
}

extension GeneratedVideo: TimelineDurationChangeable, TimelineCuttable, TimelineSpeedChangeable {
    var clipSource: ClipSource {
        ClipSource(id: DocumentMediaResolver.sourceID(.video, id), kind: .video,
                   displayName: versionedName(project?.name ?? String(localized: "Video"), version: versionNumber))
    }
    var mediaURL: URL? { videoURL }
    var storedDuration: TimeInterval? { durationSeconds > 0 ? durationSeconds : nil }
    var naturalSize: CGSize? { width > 0 && height > 0 ? CGSize(width: width, height: height) : nil }
    private var versionNumber: Int? { project.flatMap { takeNumber(of: id, in: $0.generatedFiles.map { ($0.id, $0.createdAt) }) } }
}

extension ImportedAsset: TimelineDurationChangeable, TimelineCuttable, TimelineReversible, TimelineSpeedChangeable {
    var canReverse: Bool { kindEnum == .audio }
    var canChangeSpeed: Bool { kindEnum != .image }
    var clipSource: ClipSource {
        let kind: SourceKind = kindEnum == .image ? .image : (kindEnum == .audio ? .audio : .video)
        return ClipSource(id: DocumentMediaResolver.sourceID(.imported, id), kind: kind, displayName: name)
    }
    var mediaURL: URL? { resolveURL() }
    var storedDuration: TimeInterval? { kindEnum != .image && durationSeconds > 0 ? durationSeconds : nil }
    var naturalSize: CGSize? { width > 0 && height > 0 ? CGSize(width: width, height: height) : nil }
    /// Stills stand in for their own thumbnail.
    var dragThumbnailURL: URL? { thumbnailURL ?? (kindEnum == .image ? resolveURL() : nil) }
}

/// Renders on demand for the sequence's size, so it has a length but no file yet.
extension RemotionProject: TimelineDurationChangeable, TimelineCuttable, TimelineSpeedChangeable {
    var clipSource: ClipSource {
        ClipSource(id: DocumentMediaResolver.sourceID(.remotion, id), kind: .remotion, displayName: name)
    }
    var mediaURL: URL? { nil }
    var storedDuration: TimeInterval? { durationSeconds > 0 ? durationSeconds : nil }
    var naturalSize: CGSize? { CGSize(width: compositionWidth, height: compositionHeight) }
}

/// Timed cues; the audio they were transcribed from sets the length.
extension CaptionProject: TimelineDurationChangeable, TimelineCuttable {
    var clipSource: ClipSource {
        ClipSource(id: DocumentMediaResolver.sourceID(.caption, projectUUID), kind: .captions, displayName: name)
    }
    var mediaURL: URL? { nil }
    var storedDuration: TimeInterval? { audioDurationMs > 0 ? Double(audioDurationMs) / 1000 : nil }
}

// MARK: - Version naming

/// Generated takes are numbered by age, oldest first, the way the library labels them.
private func takeNumber(of id: UUID, in files: [(id: UUID, createdAt: Date)]) -> Int? {
    let ordered = files.sorted { $0.createdAt < $1.createdAt }
    return ordered.firstIndex { $0.id == id }.map { $0 + 1 }
}

private func versionedName(_ name: String, version: Int?) -> String {
    version.map { "\(name) v\($0)" } ?? name
}
