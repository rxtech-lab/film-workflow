import CryptoKit
import Foundation
import SwiftData
import VideoEditorCore

/// One line in the library list, whatever the underlying model.
struct LibraryRow: Identifiable, Hashable {
    let id: LibraryItemID
    let name: String
    let subtitle: String
    let updatedAt: Date
    let groupID: UUID?
    /// Drag payload for the row itself: the newest output, if any.
    let dragItem: FootageDragItem?
    /// Every generated output, render or transcript of this item, newest first.
    let versions: [LibraryVersion]
    /// Added to this film from the marketplace, and so never offered back to
    /// it: republishing someone else's item is not a thing to invite.
    var isFromMarketplace = false
}

/// One version of a library item as the library shows it: a label and a line
/// of detail, plus the id the versions sheet uses to pick it out.
struct LibraryVersion: Identifiable, Hashable {
    let id: UUID
    let label: String
    let detail: String
}

/// Everything the library needs from the store, refetched by SwiftUI queries
/// in `EditorWindowView` and passed down as plain values.
struct LibraryIndex {
    var recordings: [ScreenRecordingProject] = []
    var music: [MusicProject] = []
    var narrations: [NarrativeProject] = []
    var captions: [CaptionProject] = []
    var images: [ImageGenProject] = []
    var videos: [VideoGenProject] = []
    var remotions: [RemotionProject] = []
    var imported: [ImportedAsset] = []
    var sequences: [SequenceProject] = []
    var sequenceRenders: [SequenceRender] = []
    var remotionRenders: [RemotionRender] = []

    func rows() -> [LibraryRow] {
        var rows: [LibraryRow] = []
        rows += sequences.map {
            LibraryRow(id: LibraryItemID(kind: .sequence, id: $0.id), name: $0.name, subtitle: "\($0.width)×\($0.height) · \($0.fps) fps", updatedAt: $0.updatedAt, groupID: $0.groupID,
                       dragItem: nil, versions: sequenceVersions($0))
        }
        rows += music.map { p in
            let newest = p.generatedFiles.max { $0.createdAt < $1.createdAt }
            return LibraryRow(id: LibraryItemID(kind: .music, id: p.id), name: p.name, subtitle: outputSubtitle(newest: newest?.createdAt, duration: newest?.durationSeconds), updatedAt: p.updatedAt, groupID: p.groupID,
                              dragItem: newest?.dragItem, versions: generatedVersions(p.generatedFiles, id: \.id, createdAt: \.createdAt, detail: { durationLabel($0.durationSeconds) }))
        }
        rows += narrations.map { p in
            let newest = p.generatedFiles.max { $0.createdAt < $1.createdAt }
            return LibraryRow(id: LibraryItemID(kind: .narration, id: p.id), name: p.name, subtitle: outputSubtitle(newest: newest?.createdAt, duration: newest?.durationSeconds), updatedAt: p.updatedAt, groupID: p.groupID,
                              dragItem: newest?.dragItem, versions: generatedVersions(p.generatedFiles, id: \.id, createdAt: \.createdAt, detail: { durationLabel($0.durationSeconds) }))
        }
        rows += captions.map { p in
            let count = p.activeSegmentCount
            return LibraryRow(id: LibraryItemID(kind: .caption, id: p.projectUUID), name: p.name, subtitle: count == 0 ? "No captions" : "\(count) captions", updatedAt: p.updatedAt, groupID: p.groupID,
                       dragItem: count > 0 ? p.dragItem : nil, versions: captionVersions(p))
        }
        rows += images.map { p in
            let newest = p.generatedFiles.max { $0.createdAt < $1.createdAt }
            return LibraryRow(id: LibraryItemID(kind: .image, id: p.id), name: p.name, subtitle: outputSubtitle(newest: newest?.createdAt), updatedAt: p.updatedAt, groupID: p.groupID,
                              dragItem: newest?.dragItem, versions: generatedVersions(p.generatedFiles, id: \.id, createdAt: \.createdAt))
        }
        rows += videos.map { p in
            let newest = p.generatedFiles.max { $0.createdAt < $1.createdAt }
            return LibraryRow(id: LibraryItemID(kind: .video, id: p.id), name: p.name, subtitle: outputSubtitle(newest: newest?.createdAt), updatedAt: p.updatedAt, groupID: p.groupID,
                              dragItem: newest?.dragItem, versions: generatedVersions(p.generatedFiles, id: \.id, createdAt: \.createdAt, detail: { $0.dimensionsLabel }))
        }
        rows += remotions.map { p in
            LibraryRow(id: LibraryItemID(kind: .remotion, id: p.id), name: p.name, subtitle: "\(Int(p.durationSeconds))s · \(p.compositionWidth)×\(p.compositionHeight)", updatedAt: p.updatedAt, groupID: p.groupID,
                       dragItem: p.dragItem, versions: remotionVersions(p), isFromMarketplace: p.marketplaceItemId != nil)
        }
        rows += imported.map { a in
            LibraryRow(id: LibraryItemID(kind: .imported, id: a.id), name: a.name, subtitle: a.dimensionsLabel, updatedAt: a.updatedAt, groupID: a.groupID,
                       dragItem: a.dragItem, versions: [], isFromMarketplace: a.marketplaceItemId != nil)
        }
        rows += recordings.map { p in
            let newest = p.visibleTakes.max { $0.createdAt < $1.createdAt }
            return LibraryRow(id: .init(kind: .screenRecording, id: p.id), name: p.name, subtitle: newest.map { "\(Int($0.duration))s · \(p.visibleTakes.count) takes" } ?? "Ready to record", updatedAt: p.updatedAt, groupID: p.groupID, dragItem: newest?.dragItem, versions: versions(for: .init(kind: .screenRecording, id: p.id)))
        }
        return rows.sorted { $0.updatedAt > $1.updatedAt }
    }

    func recording(_ id: UUID) -> ScreenRecordingProject? { recordings.first { $0.id == id } }
    func sequence(_ id: UUID) -> SequenceProject? { sequences.first { $0.id == id } }
    func music(_ id: UUID) -> MusicProject? { music.first { $0.id == id } }
    func narration(_ id: UUID) -> NarrativeProject? { narrations.first { $0.id == id } }
    func caption(_ id: UUID) -> CaptionProject? { captions.first { $0.projectUUID == id } }
    func image(_ id: UUID) -> ImageGenProject? { images.first { $0.id == id } }
    func video(_ id: UUID) -> VideoGenProject? { videos.first { $0.id == id } }
    func remotion(_ id: UUID) -> RemotionProject? { remotions.first { $0.id == id } }
    func imported(_ id: UUID) -> ImportedAsset? { imported.first { $0.id == id } }

    func name(of item: LibraryItemID) -> String? {
        switch item.kind {
        case .screenRecording: recording(item.id)?.name
        case .sequence: sequence(item.id)?.name
        case .music: music(item.id)?.name
        case .narration: narration(item.id)?.name
        case .caption: caption(item.id)?.name
        case .image: image(item.id)?.name
        case .video: video(item.id)?.name
        case .remotion: remotion(item.id)?.name
        case .imported: imported(item.id)?.name
        }
    }

    /// Whether this item was added from the marketplace. Only the kinds
    /// `MarketplaceInstaller` creates can be: everything else is the film's own.
    func isFromMarketplace(_ item: LibraryItemID) -> Bool {
        switch item.kind {
        case .imported: return imported(item.id)?.marketplaceItemId != nil
        case .remotion: return remotion(item.id)?.marketplaceItemId != nil
        case .screenRecording, .sequence, .music, .narration, .caption, .image, .video: return false
        }
    }

    /// The model behind a library item, as the footage protocols see it.
    /// The one place the inspector resolves a kind to a concrete type.
    func model(for item: LibraryItemID) -> (any FootageProtocol)? {
        switch item.kind {
        case .screenRecording: return recording(item.id)
        case .sequence: return sequence(item.id)
        case .music: return music(item.id)
        case .narration: return narration(item.id)
        case .caption: return caption(item.id)
        case .image: return image(item.id)
        case .video: return video(item.id)
        case .remotion: return remotion(item.id)
        case .imported: return imported(item.id)
        }
    }

    // MARK: - Versions

    /// The versions of one item, newest first. Empty for imported files.
    func versions(for item: LibraryItemID) -> [LibraryVersion] {
        switch item.kind {
        case .screenRecording:
            guard let project = recording(item.id) else { return [] }
            let visible = Set(project.visibleTakes.map(\.id))
            return generatedVersions(project.takes, id: \.id, createdAt: \.createdAt, detail: { durationLabel($0.duration) }).filter { visible.contains($0.id) }
        case .sequence: return sequence(item.id).map(sequenceVersions) ?? []
        case .music: return music(item.id).map { generatedVersions($0.generatedFiles, id: \.id, createdAt: \.createdAt, detail: { durationLabel($0.durationSeconds) }) } ?? []
        case .narration: return narration(item.id).map { generatedVersions($0.generatedFiles, id: \.id, createdAt: \.createdAt, detail: { durationLabel($0.durationSeconds) }) } ?? []
        case .caption: return caption(item.id).map(captionVersions) ?? []
        case .image: return image(item.id).map { generatedVersions($0.generatedFiles, id: \.id, createdAt: \.createdAt) } ?? []
        case .video: return video(item.id).map { generatedVersions($0.generatedFiles, id: \.id, createdAt: \.createdAt, detail: { $0.dimensionsLabel }) } ?? []
        case .remotion: return remotion(item.id).map(remotionVersions) ?? []
        case .imported: return []
        }
    }

    /// Generated outputs carry no version number of their own; they are
    /// numbered by age, the way the footage browser labels them.
    private func generatedVersions<T>(_ files: [T], id: KeyPath<T, UUID>, createdAt: KeyPath<T, Date>, detail: ((T) -> String?)? = nil) -> [LibraryVersion] {
        let sorted = files.sorted { $0[keyPath: createdAt] > $1[keyPath: createdAt] }
        return sorted.enumerated().map { i, file in
            let date = file[keyPath: createdAt].formatted(date: .abbreviated, time: .shortened)
            let extra = detail?(file)
            return LibraryVersion(id: file[keyPath: id], label: "v\(sorted.count - i)", detail: extra.map { "\($0) · \(date)" } ?? date)
        }
    }

    private func sequenceVersions(_ sequence: SequenceProject) -> [LibraryVersion] {
        sequenceRenders.filter { $0.sequenceID == sequence.id }
            .sorted { $0.versionNumber > $1.versionNumber }
            .map { LibraryVersion(id: $0.id, label: $0.versionLabel, detail: "\($0.dimensionsLabel) · \($0.createdAt.formatted(date: .abbreviated, time: .shortened))") }
    }

    private func remotionVersions(_ project: RemotionProject) -> [LibraryVersion] {
        remotionRenders.filter { $0.projectID == project.id }
            .sorted { $0.versionNumber > $1.versionNumber }
            .map { LibraryVersion(id: $0.id, label: $0.versionLabel, detail: "\($0.dimensionsLabel) · \($0.createdAt.formatted(date: .abbreviated, time: .shortened))") }
    }

    private func captionVersions(_ project: CaptionProject) -> [LibraryVersion] {
        project.orderedVersions.map { version in
            var parts = ["\(version.segmentCount) captions"]
            if let provider = version.providerEnum { parts.append(provider.displayName) }
            parts.append(version.createdAt.formatted(date: .abbreviated, time: .shortened))
            return LibraryVersion(id: version.id, label: "v\(version.number)", detail: parts.joined(separator: " · "))
        }
    }

    /// Length then date, or just the date while the length is still unknown.
    private func outputSubtitle(newest: Date?, duration: Double? = nil) -> String {
        guard let newest else { return String(localized: "Not generated yet") }
        let date = newest.formatted(date: .abbreviated, time: .shortened)
        return durationLabel(duration).map { "\($0) · \(date)" } ?? date
    }

    /// "12s" for a known length, nil for zero or missing.
    private func durationLabel(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        return "\(Int(seconds.rounded()))s"
    }

    /// The outputs of one project as draggable footage, newest first.
    func footage(for item: LibraryItemID) -> [FootageCell] {
        let date: (Date) -> String = { $0.formatted(date: .abbreviated, time: .shortened) }
        switch item.kind {
        case .screenRecording:
            guard let p = recording(item.id) else { return [] }
            return p.takes.sorted { $0.createdAt > $1.createdAt }.enumerated().compactMap { i, f in
                guard !f.isRemovedFromLibrary else { return nil }
                return FootageCell(id: f.id, title: "v\(p.takes.count - i)", subtitle: "\(Int(f.duration))s", footage: f)
            }
        case .music:
            guard let p = music(item.id) else { return [] }
            return p.generatedFiles.sorted { $0.createdAt > $1.createdAt }.enumerated().map { i, f in
                FootageCell(id: f.id, title: "v\(p.generatedFiles.count - i)", subtitle: durationLabel(f.durationSeconds) ?? date(f.createdAt), footage: f)
            }
        case .narration:
            guard let p = narration(item.id) else { return [] }
            return p.generatedFiles.sorted { $0.createdAt > $1.createdAt }.enumerated().map { i, f in
                FootageCell(id: f.id, title: "v\(p.generatedFiles.count - i)", subtitle: durationLabel(f.durationSeconds) ?? date(f.createdAt), footage: f)
            }
        case .caption:
            guard let p = caption(item.id) else { return [] }
            let count = p.libraryPreviewCaptionCount
            guard count > 0 else { return [] }
            return [FootageCell(id: p.activeVersionID ?? p.projectUUID, title: p.activeVersion.map { "v\($0.number)" } ?? "Captions", subtitle: "\(count) captions", footage: p)]
        case .image:
            guard let p = image(item.id) else { return [] }
            return p.generatedFiles.sorted { $0.createdAt > $1.createdAt }.enumerated().map { i, f in
                FootageCell(id: f.id, title: "v\(p.generatedFiles.count - i)", subtitle: date(f.createdAt), footage: f)
            }
        case .video:
            guard let p = video(item.id) else { return [] }
            return p.generatedFiles.sorted { $0.createdAt > $1.createdAt }.enumerated().map { i, f in
                FootageCell(id: f.id, title: "v\(p.generatedFiles.count - i)", subtitle: f.dimensionsLabel, footage: f)
            }
        case .remotion:
            guard let p = remotion(item.id) else { return [] }
            // One cell per render, newest first, so the strip lists the same
            // versions the card's badge counts. Before the first render there
            // is nothing on disk, so the project itself stands in and previews
            // live off its source.
            let renders = remotionRenders.filter { $0.projectID == p.id }.sorted { $0.versionNumber > $1.versionNumber }
            guard !renders.isEmpty else {
                return [FootageCell(id: p.id, title: p.name, subtitle: "\(Int(p.durationSeconds))s · renders on demand", footage: p)]
            }
            return renders.map { FootageCell(render: $0, project: p) }
        case .imported:
            guard let a = imported(item.id) else { return [] }
            return [FootageCell(id: a.id, title: a.name, subtitle: a.dimensionsLabel, footage: a, thumbnailURL: a.dragThumbnailURL)]
        case .sequence:
            return []
        }
    }
}

/// One output as the footage browser and the viewer see it: a plain value
/// snapshot of a `TimelineDraggable`, so the views need no model access.
struct FootageCell: Identifiable, Hashable {
    let id: UUID
    let title: String
    let subtitle: String
    let kind: SourceKind
    let thumbnailURL: URL?
    /// The file to play or show. Nil for captions and unrendered Remotion.
    let mediaURL: URL?
    /// Known length; nil when only the file knows (generated audio).
    let duration: TimeInterval?
    let drag: FootageDragItem
    let previewSource: LibPreviewSource?
    let captionStyle: TextStyle?
    let captionAudioURL: URL?
    let previewFPS: Int
    let previewDirectory: URL?

    /// One rendered take of a Remotion project.
    ///
    /// The cell plays the render's own file — that is the point of picking a
    /// version — so it reads as `.video` rather than `.remotion`, which would
    /// send the viewer back to rendering the live source. What it drags is
    /// still the project: the timeline renders Remotion for the sequence it
    /// lands in, so a clip is never pinned to one file.
    @MainActor
    init(render: RemotionRender, project: RemotionProject) {
        self.id = render.id
        self.title = render.versionLabel
        self.subtitle = render.dimensionsLabel
        self.kind = .video
        self.thumbnailURL = render.thumbnailURL
        self.mediaURL = render.videoURL
        self.duration = render.durationSeconds > 0 ? render.durationSeconds : nil
        self.drag = project.dragItem
        self.previewSource = .file(id: "remotion-render:\(render.id.uuidString)", kind: .video,
                                   mediaURL: render.videoURL, thumbnailURL: render.thumbnailURL,
                                   duration: render.durationSeconds > 0 ? render.durationSeconds : nil)
        self.captionStyle = nil
        self.captionAudioURL = nil
        self.previewFPS = render.fps
        self.previewDirectory = nil
    }

    @MainActor
    init(id: UUID, title: String, subtitle: String, footage: some TimelineDraggable, thumbnailURL: URL? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = footage.timelineKind
        self.thumbnailURL = thumbnailURL ?? footage.thumbnailURL
        self.mediaURL = footage.mediaURL
        self.previewSource = (footage as? any LibPreviewableProtocol)?.makeLibPreviewSource()
        self.duration = previewSource?.duration ?? footage.knownDuration
        self.drag = footage.dragItem
        self.captionStyle = (footage as? CaptionProject)?.captionStyle
        self.captionAudioURL = (footage as? CaptionProject).flatMap { $0.hasAudio ? $0.audioURL : nil }
        self.previewFPS = (footage as? RemotionProject)?.compositionFps ?? 30
        self.previewDirectory = (footage as? RemotionProject)?.projectDir.standardizedFileURL
    }

    /// Content installed from the marketplace, which no film owns and no model
    /// stands behind: the file on disk is everything the strip and the viewer
    /// need. It drags nothing — adding the item to the film is what makes a
    /// copy the timeline can take.
    init(marketplaceItemID: String, title: String, subtitle: String, kind: SourceKind, mediaURL: URL,
         thumbnailURL: URL?, duration: TimeInterval?, width: Int? = nil, height: Int? = nil) {
        let source = ClipSource(id: "marketplace:\(marketplaceItemID)", kind: kind, displayName: title)
        self.id = Self.installedID(marketplaceItemID)
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.thumbnailURL = thumbnailURL
        self.mediaURL = mediaURL
        self.duration = duration
        self.drag = FootageDragItem(source: source, duration: duration, naturalWidth: width, naturalHeight: height)
        self.previewSource = .file(id: source.id, kind: kind, mediaURL: mediaURL, thumbnailURL: thumbnailURL, duration: duration)
        self.captionStyle = nil
        self.captionAudioURL = nil
        self.previewFPS = 30
        self.previewDirectory = nil
    }

    /// A marketplace item is named by a server-issued string, and a cell by a
    /// UUID. Hashing the one into the other keeps a card's identity — and so
    /// the player's idea of what is loaded — stable across installs and
    /// launches, whatever shape the server's ids take.
    private static func installedID(_ itemID: String) -> UUID {
        if let parsed = UUID(uuidString: itemID) { return parsed }
        let hex = SHA256.hash(data: Data(itemID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let groups = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4),
                      hex.dropFirst(16).prefix(4), hex.dropFirst(20).prefix(12)]
        return UUID(uuidString: groups.joined(separator: "-")) ?? UUID()
    }
}
