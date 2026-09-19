import Foundation
import VideoEditorCore

nonisolated enum RecordingComponentBuilder {
    static func cursors(for components: [RecordingComponent], path: String, defaults: RecordingClipPresentation) -> [RecordingComponent] {
        components.filter { $0.role == .screen }.map { screen in
            var presentation = defaults
            presentation.role = .cursor
            presentation.pointer = screen.presentation?.pointer ?? []
            presentation.timeOffset = screen.start
            presentation.sourceAspectRatio = screen.presentation?.sourceAspectRatio
            return RecordingComponent(role: .cursor, name: "Cursor — \(screen.name)", filePath: path,
                                      start: screen.start, duration: screen.duration, sourceID: screen.sourceID,
                                      presentation: presentation, sourceIdentity: screen.sourceIdentity, geometry: screen.geometry)
        }
    }
}
