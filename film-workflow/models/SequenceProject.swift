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

    init(name: String) {
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.groupID = nil
        var timeline = Timeline(width: 1920, height: 1080, fps: 30)
        timeline.id = id
        self.timelineData = (try? TimelineCodec.encode(timeline)) ?? Data()
        self.cachedTimeline = timeline
    }

    var timeline: Timeline {
        get {
            if let cachedTimeline { return cachedTimeline }
            let decoded = (try? TimelineCodec.decode(timelineData)) ?? Timeline(width: width, height: height, fps: fps)
            cachedTimeline = decoded
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
        }
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
