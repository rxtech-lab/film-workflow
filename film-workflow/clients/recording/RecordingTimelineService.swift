import AppKit
import SwiftData
import VideoEditorCore

@MainActor enum RecordingTimelineService {
    static func take(id: UUID, context: ModelContext) throws -> RecordingTake {
        guard let take = try context.fetch(FetchDescriptor<RecordingTake>(predicate: #Predicate { $0.id == id })).first else { throw RecordingError.message("Recording take not found.") }; return take
    }
    static func resolve(id: UUID, context: ModelContext) throws -> (RecordingTake, RecordingComponent) {
        let takes = try context.fetch(FetchDescriptor<RecordingTake>())
        if let take = takes.first(where: { $0.id == id }), let primary = take.primary { return (take, primary) }
        for take in takes { if let component = take.components.first(where: { $0.id == id }) { return (take, component) } }
        throw RecordingError.message("Recording media is unavailable.")
    }
    @discardableResult static func insert(take: RecordingTake, into sequence: SequenceProject, at time: Double, undoManager: UndoManager? = nil) throws -> [UUID] {
        guard time.isFinite, time >= 0 else { throw RecordingError.message("Invalid insertion time.") }
        var timeline = sequence.timeline
        let group = UUID(), instance = UUID()
        let primarySource = take.primary?.sourceID ?? ""
        var instances: [String: UUID] = [primarySource: instance]
        var ids: [UUID] = [], tracks: [String: UUID] = [:]
        // The screen claims its lane first: the camera is placed above whatever
        // index it lands on, and zoom clips need the placed screen clip.
        var screenClips: [UUID: Clip] = [:]
        let ordered = take.components.enumerated().sorted {
            let a = priority($0.element.role), b = priority($1.element.role)
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        for original in ordered where original.duration > 0 {
            var component = original
            let presentationSource = (component.role == .screen || component.role == .cursor) && !component.sourceID.isEmpty ? component.sourceID : primarySource
            if instances[presentationSource] == nil { instances[presentationSource] = UUID() }
            if let captured = original.presentation, var defaults = take.project?.presentation {
                defaults.cameraAspectRatio = captured.role == .camera ? captured.sourceAspectRatio : nil; defaults.sourceAspectRatio = captured.sourceAspectRatio; defaults.role = captured.role; defaults.pointer = captured.pointer; defaults.timeOffset = captured.timeOffset; component.presentation = defaults
            }
            let key = component.role.rawValue + ":" + component.sourceID
            let range = (time + component.start)..<(time + component.start + component.duration)
            let trackID = tracks[key] ?? lane(&timeline, for: component, range: range, screen: screenClips[instances[presentationSource] ?? instance])
            tracks[key] = trackID
            let source = ClipSource(id: "screenRecording:\(component.id)", kind: component.sourceKind, displayName: component.name, capabilities: [.drag, .duration, .cut])
            let clip = Clip(source: source, start: time + component.start, duration: component.duration, sourceDuration: component.duration, text: component.sourceKind == .captions ? take.project?.shortcutStyle ?? .caption : nil, linkGroupID: group, recordingInstanceID: instances[presentationSource], recording: component.presentation, recordingShortcuts: component.role == .shortcuts ? component.cues : nil)
            try TimelineEditor.insert(&timeline, clip: clip, on: trackID); ids.append(clip.id)
            if component.role == .screen { screenClips[instances[presentationSource] ?? instance] = clip }
        }
        // Auto zoom becomes clips once, so every zoom is visible and editable
        // rather than invented again at each render.
        for (_, screen) in screenClips.sorted(by: { $0.value.start < $1.value.start }) {
            let source = ClipSource(id: DocumentMediaResolver.sourceID(.recordingZoom, screen.id), kind: .zoom, displayName: "Zoom", capabilities: [.drag, .duration, .cut])
            ids.append(contentsOf: TimelineEditor.materializeAutoZoom(&timeline, screenClipID: screen.id, source: source))
        }
        sequence.editTimeline(timeline, undoManager: undoManager, actionName: "Add Recording")
        return ids
    }

    /// The lane a component belongs on: an existing one of the right kind whose
    /// clips leave `range` free, preferring the lane this component already
    /// used, or a new one. The camera must sit above its screen, and the
    /// compositor paints the track array from the bottom up.
    private static func lane(_ timeline: inout Timeline, for component: RecordingComponent, range: Range<Double>, screen: Clip?) -> UUID {
        let kind: TrackKind
        switch component.role {
        case .screen, .camera: kind = .video
        case .cursor: kind = .overlay
        case .shortcuts: kind = .caption
        default: kind = .audio
        }
        let screenIndex = screen.flatMap { clip in timeline.tracks.firstIndex { $0.clips.contains { $0.id == clip.id } } }
        let limit = component.role == .camera ? screenIndex : nil
        if let index = freeTrack(timeline, kind: kind, range: range, alias: component.name, below: limit) {
            return timeline.tracks[index].id
        }
        let id = component.role == .camera && screenIndex != nil
            ? TimelineEditor.addTrack(&timeline, kind: kind, at: screenIndex!)
            : TimelineEditor.addTrack(&timeline, kind: kind)
        try? TimelineEditor.setTrackAlias(&timeline, trackID: id, alias: component.name)
        return id
    }

    /// The topmost lane of `kind` with room for `range`, preferring one this
    /// take already named. `below` caps the index, for a camera that has to
    /// draw over its screen.
    private static func freeTrack(_ timeline: Timeline, kind: TrackKind, range: Range<Double>, alias: String?, below: Int?) -> Int? {
        let candidates = timeline.tracks.indices.filter { index in
            guard timeline.tracks[index].kind == kind else { return false }
            if let below, index >= below { return false }
            return !timeline.tracks[index].clips.contains { $0.start < range.upperBound && range.lowerBound < $0.end }
        }
        return candidates.first { timeline.tracks[$0].alias == alias } ?? candidates.first
    }

    static func previewTimeline(_ take: RecordingTake) throws -> Timeline {
        let sequence = SequenceProject(name: take.name)
        sequence.timeline = Timeline(width: max(2, take.primary?.width ?? 1920), height: max(2, take.primary?.height ?? 1080), fps: take.project?.settings.fps ?? 60, tracks: [])
        try insert(take: take, into: sequence, at: 0)
        // The library preview shows the primary window and its associated overlays.
        let primaryID = sequence.timeline.allClips.first { $0.recording?.role == .screen }?.recordingInstanceID
        if let primaryID {
            var timeline = sequence.timeline
            for index in timeline.tracks.indices {
                timeline.tracks[index].clips.removeAll { $0.recordingInstanceID != primaryID && ($0.recording != nil || $0.recordingZoom != nil) }
            }
            sequence.timeline = timeline
        }
        return sequence.timeline
    }
    /// Processing order, not lane order: the screen claims its video lane
    /// before the camera is placed above it, and the lanes that insert at the
    /// top are created last so they end up in display order.
    private static func priority(_ role: RecordingComponent.Role) -> Int { switch role { case .screen: 0; case .camera: 1; case .cursor: 2; case .shortcuts: 3; default: 4 } }
    static func writeTransparentPixel(directory: URL, storage: ProjectStorage) throws -> String? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32) else { return nil }
        bitmap.setColor(.clear, atX: 0, y: 0)
        let url = directory.appendingPathComponent("cursor.png")
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }; try png.write(to: url)
        return storage.relativePath(for: url)
    }
}
