import Foundation
import SwiftData

/// Create, rename and delete for every footage kind in one place, so the
/// library, the inspectors and MCP agree on what a deletion cleans up.
@MainActor
enum ProjectLifecycleService {
    static func create(kind: FootageKind, groupID: UUID?, context: ModelContext) -> LibraryItemID? {
        switch kind {
        case .music:
            let p = MusicProject(name: "Untitled Music"); p.groupID = groupID
            context.insert(p); return LibraryItemID(kind: .music, id: p.id)
        case .narration:
            let p = NarrativeProject(name: "Untitled Narration"); p.groupID = groupID
            context.insert(p); return LibraryItemID(kind: .narration, id: p.id)
        case .caption:
            let p = CaptionProject(name: "Untitled Captions"); p.groupID = groupID
            p.languageHint = CaptionSettings.shared.defaultLanguageHint
            p.maxSpeakers = CaptionSettings.shared.defaultMaxSpeakers
            context.insert(p); return LibraryItemID(kind: .caption, id: p.projectUUID)
        case .image:
            let p = ImageGenProject(name: "Untitled Images"); p.groupID = groupID
            context.insert(p); return LibraryItemID(kind: .image, id: p.id)
        case .screenRecording:
            let p = ScreenRecordingProject(name: "Untitled Screen Recording"); p.groupID = groupID
            context.insert(p); return LibraryItemID(kind: .screenRecording, id: p.id)
        case .video:
            let p = VideoGenProject(name: "Untitled Video"); p.groupID = groupID
            context.insert(p); return LibraryItemID(kind: .video, id: p.id)
        case .remotion:
            let p = RemotionProject(name: "Untitled Composition"); p.groupID = groupID
            context.insert(p); return LibraryItemID(kind: .remotion, id: p.id)
        case .sequence:
            let count = (try? context.fetchCount(FetchDescriptor<SequenceProject>())) ?? 0
            let p = SequenceProject(name: "Sequence \(count + 1)"); p.groupID = groupID
            context.insert(p); return LibraryItemID(kind: .sequence, id: p.id)
        case .imported:
            return nil
        }
    }

    static func delete(_ item: LibraryItemID, context: ModelContext) {
        let storage = ProjectStorage.forContainer(context.container)
        let id = item.id
        switch item.kind {
        case .music:
            guard let p = try? context.fetch(FetchDescriptor<MusicProject>(predicate: #Predicate { $0.id == id })).first else { return }
            for f in p.generatedFiles { storage.deleteFile(at: f.audioFilePath) }
            for path in p.referenceImagePaths { storage.deleteFile(at: path) }
            context.delete(p)
        case .narration:
            guard let p = try? context.fetch(FetchDescriptor<NarrativeProject>(predicate: #Predicate { $0.id == id })).first else { return }
            for f in p.generatedFiles { storage.deleteFile(at: f.audioFilePath) }
            context.delete(p)
        case .caption:
            guard let p = try? context.fetch(FetchDescriptor<CaptionProject>(predicate: #Predicate { $0.projectUUID == id })).first else { return }
            if p.ownsAudioFile, !p.audioFilePath.isEmpty { storage.deleteFile(at: p.audioFilePath) }
            context.delete(p)
        case .image:
            guard let p = try? context.fetch(FetchDescriptor<ImageGenProject>(predicate: #Predicate { $0.id == id })).first else { return }
            for f in p.generatedFiles { storage.deleteFile(at: f.imageFilePath) }
            context.delete(p)
        case .screenRecording:
            guard let p = try? context.fetch(FetchDescriptor<ScreenRecordingProject>(predicate: #Predicate { $0.id == id })).first else { return }
            guard RecordingSession.shared.project?.id != p.id || !RecordingSession.shared.isActive else { return }
            for take in p.takes { for component in take.components { if !component.filePath.isEmpty { storage.deleteFile(at: component.filePath) } } }
            context.delete(p)
        case .video:
            guard let p = try? context.fetch(FetchDescriptor<VideoGenProject>(predicate: #Predicate { $0.id == id })).first else { return }
            for f in p.generatedFiles {
                storage.deleteFile(at: f.videoFilePath)
                if let t = f.thumbnailFilePath { storage.deleteFile(at: t) }
            }
            for path in p.googleReferenceImagePaths { storage.deleteFile(at: path) }
            if let path = p.googleFirstFrameImagePath { storage.deleteFile(at: path) }
            if let path = p.googleLastFrameImagePath { storage.deleteFile(at: path) }
            context.delete(p)
        case .remotion:
            guard let p = try? context.fetch(FetchDescriptor<RemotionProject>(predicate: #Predicate { $0.id == id })).first else { return }
            RemotionProjectService.delete(p, context: context)
        case .sequence:
            guard let p = try? context.fetch(FetchDescriptor<SequenceProject>(predicate: #Predicate { $0.id == id })).first else { return }
            SequenceRenderService.deleteAll(for: p, context: context)
            context.delete(p)
        case .imported:
            guard let p = try? context.fetch(FetchDescriptor<ImportedAsset>(predicate: #Predicate { $0.id == id })).first else { return }
            if let path = p.relativePath { storage.deleteFile(at: path) }
            if let t = p.thumbnailFilePath { storage.deleteFile(at: t) }
            context.delete(p)
        }
        try? context.save()
    }

    static func deletionMessage(for kind: FootageKind, name: String) -> String {
        switch kind {
        case .music: return "\"\(name)\" and its generated audio and reference files will be permanently deleted."
        case .narration: return "\"\(name)\" and its generated audio will be permanently deleted."
        case .caption: return "\"\(name)\", its transcript versions, and any audio it owns will be permanently deleted."
        case .image: return "\"\(name)\" and its generated images will be permanently deleted."
        case .screenRecording: return "This recording and all its takes will be permanently deleted."
        case .video: return "\"\(name)\" and its generated videos will be permanently deleted."
        case .remotion: return "\"\(name)\", its Remotion source, assets and renders will be permanently deleted."
        case .sequence: return "\"\(name)\" and its renders will be permanently deleted. Footage stays in the library."
        case .imported: return "\"\(name)\" will be removed from the film." + " A referenced file stays where it is on disk."
        }
    }
}
