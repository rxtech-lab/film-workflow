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
}

/// Everything the library needs from the store, refetched by SwiftUI queries
/// in `EditorWindowView` and passed down as plain values.
struct LibraryIndex {
    var music: [MusicProject] = []
    var narrations: [NarrativeProject] = []
    var captions: [CaptionProject] = []
    var images: [ImageGenProject] = []
    var videos: [VideoGenProject] = []
    var remotions: [RemotionProject] = []
    var imported: [ImportedAsset] = []
    var sequences: [SequenceProject] = []

    func rows() -> [LibraryRow] {
        var rows: [LibraryRow] = []
        rows += sequences.map {
            LibraryRow(id: LibraryItemID(kind: .sequence, id: $0.id), name: $0.name, subtitle: "\($0.width)×\($0.height) · \($0.fps) fps", updatedAt: $0.updatedAt, groupID: $0.groupID, dragItem: nil)
        }
        rows += music.map { p in
            let newest = p.generatedFiles.max { $0.createdAt < $1.createdAt }
            return LibraryRow(id: LibraryItemID(kind: .music, id: p.id), name: p.name, subtitle: "\(p.generatedFiles.count) versions", updatedAt: p.updatedAt, groupID: p.groupID,
                              dragItem: newest.map { FootageDragItem(source: ClipSource(id: DocumentMediaResolver.sourceID(.music, $0.id), kind: .audio, displayName: p.name)) })
        }
        rows += narrations.map { p in
            let newest = p.generatedFiles.max { $0.createdAt < $1.createdAt }
            return LibraryRow(id: LibraryItemID(kind: .narration, id: p.id), name: p.name, subtitle: "\(p.generatedFiles.count) versions", updatedAt: p.updatedAt, groupID: p.groupID,
                              dragItem: newest.map { FootageDragItem(source: ClipSource(id: DocumentMediaResolver.sourceID(.narration, $0.id), kind: .audio, displayName: p.name)) })
        }
        rows += captions.map { p in
            LibraryRow(id: LibraryItemID(kind: .caption, id: p.projectUUID), name: p.name, subtitle: p.activeSegmentCount == 0 ? "No captions" : "\(p.activeSegmentCount) captions", updatedAt: p.updatedAt, groupID: p.groupID,
                       dragItem: p.activeSegmentCount > 0 ? FootageDragItem(source: ClipSource(id: DocumentMediaResolver.sourceID(.caption, p.projectUUID), kind: .captions, displayName: p.name), duration: Double(p.audioDurationMs) / 1000) : nil)
        }
        rows += images.map { p in
            let newest = p.generatedFiles.max { $0.createdAt < $1.createdAt }
            return LibraryRow(id: LibraryItemID(kind: .image, id: p.id), name: p.name, subtitle: "\(p.generatedFiles.count) images", updatedAt: p.updatedAt, groupID: p.groupID,
                              dragItem: newest.map { FootageDragItem(source: ClipSource(id: DocumentMediaResolver.sourceID(.image, $0.id), kind: .image, displayName: p.name)) })
        }
        rows += videos.map { p in
            let newest = p.generatedFiles.max { $0.createdAt < $1.createdAt }
            return LibraryRow(id: LibraryItemID(kind: .video, id: p.id), name: p.name, subtitle: "\(p.generatedFiles.count) clips", updatedAt: p.updatedAt, groupID: p.groupID,
                              dragItem: newest.map { FootageDragItem(source: ClipSource(id: DocumentMediaResolver.sourceID(.video, $0.id), kind: .video, displayName: p.name), duration: $0.durationSeconds, naturalWidth: $0.width, naturalHeight: $0.height) })
        }
        rows += remotions.map { p in
            LibraryRow(id: LibraryItemID(kind: .remotion, id: p.id), name: p.name, subtitle: "\(Int(p.durationSeconds))s · \(p.compositionWidth)×\(p.compositionHeight)", updatedAt: p.updatedAt, groupID: p.groupID,
                       dragItem: FootageDragItem(source: ClipSource(id: DocumentMediaResolver.sourceID(.remotion, p.id), kind: .remotion, displayName: p.name), duration: p.durationSeconds, naturalWidth: p.compositionWidth, naturalHeight: p.compositionHeight))
        }
        rows += imported.map { a in
            let kind: SourceKind = a.kindEnum == .image ? .image : (a.kindEnum == .audio ? .audio : .video)
            return LibraryRow(id: LibraryItemID(kind: .imported, id: a.id), name: a.name, subtitle: a.dimensionsLabel, updatedAt: a.updatedAt, groupID: a.groupID,
                              dragItem: FootageDragItem(source: ClipSource(id: DocumentMediaResolver.sourceID(.imported, a.id), kind: kind, displayName: a.name), duration: a.durationSeconds > 0 ? a.durationSeconds : nil, naturalWidth: a.width, naturalHeight: a.height))
        }
        return rows.sorted { $0.updatedAt > $1.updatedAt }
    }

    func sequence(_ id: UUID) -> SequenceProject? { sequences.first { $0.id == id } }
    func music(_ id: UUID) -> MusicProject? { music.first { $0.id == id } }
    func narration(_ id: UUID) -> NarrativeProject? { narrations.first { $0.id == id } }
    func caption(_ id: UUID) -> CaptionProject? { captions.first { $0.projectUUID == id } }
    func image(_ id: UUID) -> ImageGenProject? { images.first { $0.id == id } }
    func video(_ id: UUID) -> VideoGenProject? { videos.first { $0.id == id } }
    func remotion(_ id: UUID) -> RemotionProject? { remotions.first { $0.id == id } }
    func imported(_ id: UUID) -> ImportedAsset? { imported.first { $0.id == id } }

    func name(of item: LibraryItemID) -> String? {
        rows().first { $0.id == item }?.name
    }

    /// The outputs of one project as draggable footage, newest first.
    func footage(for item: LibraryItemID) -> [FootageCell] {
        switch item.kind {
        case .music:
            guard let p = music(item.id) else { return [] }
            return p.generatedFiles.sorted { $0.createdAt > $1.createdAt }.enumerated().map { i, f in
                FootageCell(id: f.id, title: "v\(p.generatedFiles.count - i)", subtitle: f.createdAt.formatted(date: .abbreviated, time: .shortened), kind: .audio, thumbnailURL: nil,
                            drag: FootageDragItem(source: ClipSource(id: DocumentMediaResolver.sourceID(.music, f.id), kind: .audio, displayName: "\(p.name) v\(p.generatedFiles.count - i)")))
            }
        case .narration:
            guard let p = narration(item.id) else { return [] }
            return p.generatedFiles.sorted { $0.createdAt > $1.createdAt }.enumerated().map { i, f in
                FootageCell(id: f.id, title: "v\(p.generatedFiles.count - i)", subtitle: f.createdAt.formatted(date: .abbreviated, time: .shortened), kind: .audio, thumbnailURL: nil,
                            drag: FootageDragItem(source: ClipSource(id: DocumentMediaResolver.sourceID(.narration, f.id), kind: .audio, displayName: "\(p.name) v\(p.generatedFiles.count - i)")))
            }
        case .caption:
            guard let p = caption(item.id), p.activeSegmentCount > 0 else { return [] }
            return [FootageCell(id: p.projectUUID, title: p.name, subtitle: "\(p.activeSegmentCount) captions", kind: .captions, thumbnailURL: nil,
                                drag: FootageDragItem(source: ClipSource(id: DocumentMediaResolver.sourceID(.caption, p.projectUUID), kind: .captions, displayName: p.name), duration: Double(p.audioDurationMs) / 1000))]
        case .image:
            guard let p = image(item.id) else { return [] }
            return p.generatedFiles.sorted { $0.createdAt > $1.createdAt }.enumerated().map { i, f in
                FootageCell(id: f.id, title: "v\(p.generatedFiles.count - i)", subtitle: f.createdAt.formatted(date: .abbreviated, time: .shortened), kind: .image, thumbnailURL: f.imageURL,
                            drag: FootageDragItem(source: ClipSource(id: DocumentMediaResolver.sourceID(.image, f.id), kind: .image, displayName: "\(p.name) v\(p.generatedFiles.count - i)")))
            }
        case .video:
            guard let p = video(item.id) else { return [] }
            return p.generatedFiles.sorted { $0.createdAt > $1.createdAt }.enumerated().map { i, f in
                FootageCell(id: f.id, title: "v\(p.generatedFiles.count - i)", subtitle: f.dimensionsLabel, kind: .video, thumbnailURL: f.thumbnailURL,
                            drag: FootageDragItem(source: ClipSource(id: DocumentMediaResolver.sourceID(.video, f.id), kind: .video, displayName: "\(p.name) v\(p.generatedFiles.count - i)"), duration: f.durationSeconds, naturalWidth: f.width, naturalHeight: f.height))
            }
        case .remotion:
            guard let p = remotion(item.id) else { return [] }
            return [FootageCell(id: p.id, title: p.name, subtitle: "\(Int(p.durationSeconds))s · renders on demand", kind: .remotion, thumbnailURL: nil,
                                drag: FootageDragItem(source: ClipSource(id: DocumentMediaResolver.sourceID(.remotion, p.id), kind: .remotion, displayName: p.name), duration: p.durationSeconds, naturalWidth: p.compositionWidth, naturalHeight: p.compositionHeight))]
        case .imported:
            guard let a = imported(item.id) else { return [] }
            let kind: SourceKind = a.kindEnum == .image ? .image : (a.kindEnum == .audio ? .audio : .video)
            return [FootageCell(id: a.id, title: a.name, subtitle: a.dimensionsLabel, kind: kind, thumbnailURL: a.thumbnailURL ?? (a.kindEnum == .image ? a.resolveURL() : nil),
                                drag: FootageDragItem(source: ClipSource(id: DocumentMediaResolver.sourceID(.imported, a.id), kind: kind, displayName: a.name), duration: a.durationSeconds > 0 ? a.durationSeconds : nil, naturalWidth: a.width, naturalHeight: a.height))]
        case .sequence:
            return []
        }
    }
}

struct FootageCell: Identifiable, Hashable {
    let id: UUID
    let title: String
    let subtitle: String
    let kind: SourceKind
    let thumbnailURL: URL?
    let drag: FootageDragItem
}
