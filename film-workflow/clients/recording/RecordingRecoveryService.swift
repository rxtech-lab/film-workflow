import AVFoundation
import SwiftData
import VideoEditorCore

nonisolated struct RecordingCheckpoint: Codable {
    var version = 1
    var operationID: UUID
    var projectID: UUID
    var phase: String
    var elapsed: Double
    var settings: RecordingSettings
    var actions: [RecordingAction]
    var components: [RecordingComponent]
    var pointer: [RecordingPointerSample]
    var shortcuts: [TextCue]
    var takeID: UUID?
    var pointersBySource: [String: [RecordingPointerSample]]?
}

@MainActor enum RecordingRecoveryService {
    static func recover(_ document: ProjectDocument) async {
        let root = document.packageURL.appendingPathComponent("Media/ScreenRecordings")
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        let checkpoints = files.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "Session.json" }
        for url in checkpoints {
            guard var checkpoint = try? JSONDecoder().decode(RecordingCheckpoint.self, from: Data(contentsOf: url)), checkpoint.takeID == nil, checkpoint.phase != "idle", checkpoint.version == 1 else { continue }
            do {
                let id = checkpoint.projectID
                guard let project = try document.container.mainContext.fetch(FetchDescriptor<ScreenRecordingProject>(predicate: #Predicate { $0.id == id })).first else { continue }
                if let saved = project.takes.first(where: { $0.operationID == checkpoint.operationID }) {
                    checkpoint.takeID = saved.id; checkpoint.phase = "idle"
                    try JSONEncoder().encode(checkpoint).write(to: url, options: .atomic); continue
                }
                if checkpoint.settings.mode == .actions, checkpoint.components.isEmpty {
                    // Keep recovered actions as a revision; never overwrite a newer edit.
                    let destination = url.deletingLastPathComponent().appendingPathComponent("Recovered-Actions.json")
                    try JSONEncoder().encode(checkpoint.actions).write(to: destination, options: .atomic)
                    if project.actions.isEmpty { project.actions = checkpoint.actions }
                } else {
                    var components: [RecordingComponent] = []
                    for var component in checkpoint.components {
                        let media = AVURLAsset(url: document.storage.absoluteURL(for: component.filePath))
                        guard let duration = try? await media.load(.duration), duration.seconds.isFinite, duration.seconds > 0 else { continue }
                        component.duration = duration.seconds
                        var presentation = project.presentation; presentation.pointer = component.role == .screen ? checkpoint.pointersBySource?[component.sourceID] ?? checkpoint.pointer : checkpoint.pointer; presentation.timeOffset = component.start; presentation.sourceAspectRatio = Double(component.width) / Double(max(1, component.height))
                        if component.role == .camera { presentation.role = .camera; component.presentation = presentation }
                        if component.role == .screen { presentation.role = .screen; component.presentation = presentation }
                        components.append(component)
                    }
                    guard !components.isEmpty else { continue }
                    let take = RecordingTake(name: project.name + " · Recovered Take")
                    take.operationID = checkpoint.operationID
                    take.duration = components.map { $0.start + $0.duration }.max() ?? checkpoint.elapsed
                    if let path = try RecordingTimelineService.writeTransparentPixel(directory: url.deletingLastPathComponent(), storage: document.storage) {
                        components += RecordingComponentBuilder.cursors(for: components, path: path, defaults: project.presentation)
                    }
                    components.append(.init(role: .shortcuts, name: "Shortcuts", filePath: "", duration: take.duration, cues: checkpoint.shortcuts))
                    take.components = components; take.isInterrupted = true; take.project = project; take.actionsData = try JSONEncoder().encode(checkpoint.actions)
                    document.container.mainContext.insert(take); checkpoint.takeID = take.id
                }
                try document.container.mainContext.save(); checkpoint.phase = "idle"
                try JSONEncoder().encode(checkpoint).write(to: url, options: .atomic)
            } catch { RecordingSources.shared.error = "A recording needs recovery: \(error.localizedDescription)" }
        }
    }
}
