import Foundation
import SwiftData
import VideoEditorCore

/// A film's edit: the timeline the bottom panel shows and the renderer exports.
///
/// The timeline itself is a Codable value from the video editor package,
/// stored as JSON so the package stays free of SwiftData.
@Model
final class SequenceProject: GroupableProject {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var groupID: UUID?

    var width: Int = 1920
    var height: Int = 1080
    var fps: Int = 30
    var timelineData: Data = Data()
    var timelinePixelsPerSecond: Double = 40

    @Transient private var cachedTimeline: Timeline?
    @Transient private var cachedTimelineData: Data?

    init(name: String) {
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.groupID = nil
        var timeline = Timeline(width: 1920, height: 1080, fps: 30)
        timeline.id = id
        self.timelineData = (try? TimelineCodec.encode(timeline)) ?? Data()
        self.cachedTimeline = timeline
        self.cachedTimelineData = self.timelineData
    }

    var timeline: Timeline {
        get {
            // Register the stored data dependency even on a cache hit so inspector
            // controls and thumbnails refresh after an atomic timeline edit.
            let data = timelineData
            // A save from another context refreshes timelineData directly.
            // The decoded cache is valid only for those exact stored bytes.
            if let cachedTimeline, cachedTimelineData == data { return cachedTimeline }
            let decoded = Self.repairingRemotionKinds((try? TimelineCodec.decode(data)) ?? Timeline(width: width, height: height, fps: fps))
            cachedTimeline = decoded
            cachedTimelineData = data
            return decoded
        }
        set {
            cachedTimeline = newValue
            width = newValue.width
            height = newValue.height
            fps = newValue.fps
            if let data = try? TimelineCodec.encode(newValue), data != timelineData {
                timelineData = data
                updatedAt = Date()
            }
            cachedTimelineData = timelineData
        }
    }

    /// The source id is authoritative. A `remotion:` clip stored with another
    /// kind (an agent-written timeline did this) skips the live preview and
    /// sits on a "Not rendered yet" slate even when a render exists.
    private static func repairingRemotionKinds(_ timeline: Timeline) -> Timeline {
        var timeline = timeline
        for t in timeline.tracks.indices {
            for c in timeline.tracks[t].clips.indices {
                let source = timeline.tracks[t].clips[c].source
                guard source.kind != .remotion, DocumentMediaResolver.parse(source.id)?.0 == .remotion else { continue }
                timeline.tracks[t].clips[c].source = ClipSource(id: source.id, kind: .remotion, displayName: source.displayName)
            }
        }
        return timeline
    }

    /// Uses the window's native undo stack so Edit > Undo/Redo and their
    /// keyboard shortcuts share history with the editor's text fields.
    func editTimeline(_ newValue: Timeline, undoManager: UndoManager?, actionName: String = String(localized: "Edit Timeline")) {
        let previous = timeline
        guard previous != newValue else { return }
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] sequence in
            sequence.editTimeline(previous, undoManager: undoManager, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        timeline = newValue
    }
}
