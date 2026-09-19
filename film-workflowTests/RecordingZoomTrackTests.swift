import AppKit
import SwiftData
import Testing
import VideoEditorCore
@testable import film_workflow

@MainActor @Suite("Recording lanes, zoom clips and per-component previews", .serialized)
struct RecordingZoomTrackTests {
    /// A take with a screen, a camera, a cursor and a shortcut lane, whose
    /// screen carries clicks the presentation is set to zoom on.
    private func take(autoZoom: Bool = true) -> RecordingTake {
        var presentation = RecordingClipPresentation()
        presentation.autoZoom = autoZoom
        presentation.zoomScale = 2.5
        presentation.sourceAspectRatio = 16.0 / 9
        presentation.pointer = (0..<40).map { step in
            let time = Double(step) * 0.25
            return .init(time: time, x: 0.4, y: 0.6, clicked: [1.0, 1.25, 6.0].contains(time))
        }
        var cameraPresentation = RecordingClipPresentation()
        cameraPresentation.role = .camera
        let screen = RecordingComponent(role: .screen, name: "Safari", filePath: "screen.mov", duration: 10,
                                        width: 1920, height: 1080, sourceID: "1", presentation: presentation)
        let camera = RecordingComponent(role: .camera, name: "FaceTime", filePath: "camera.mov", duration: 10,
                                        width: 1280, height: 720, sourceID: "cam", presentation: cameraPresentation)
        let cursors = RecordingComponentBuilder.cursors(for: [screen], path: "cursor.png", defaults: .init())
        let shortcuts = RecordingComponent(role: .shortcuts, name: "Shortcuts", filePath: "", duration: 10,
                                           cues: [.init(start: 1, end: 2.5, text: "⌘C"), .init(start: 5, end: 6.5, text: "⌘V")])
        let take = RecordingTake(name: "Demo")
        take.duration = 10
        take.components = [screen, camera] + cursors + [shortcuts]
        return take
    }

    @Test func screenLandsOnTheSequenceVideoTrack() throws {
        let sequence = SequenceProject(name: "Timeline")
        let originalV1 = try #require(sequence.timeline.tracks.first { $0.kind == .video })
        _ = try RecordingTimelineService.insert(take: take(autoZoom: false), into: sequence, at: 0)
        let timeline = sequence.timeline
        let screen = try #require(timeline.allClips.first { $0.recording?.role == .screen })
        let camera = try #require(timeline.allClips.first { $0.recording?.role == .camera })
        let cursor = try #require(timeline.allClips.first { $0.recording?.role == .cursor })
        let shortcuts = try #require(timeline.allClips.first { $0.recordingShortcuts != nil })

        // The recording joins the film's own video lane rather than an R lane.
        #expect(timeline.track(containing: screen.id)?.id == originalV1.id)
        #expect(!timeline.tracks.contains { $0.name.hasPrefix("R") })
        #expect(timeline.track(containing: cursor.id)?.kind == .overlay)
        #expect(timeline.track(containing: shortcuts.id)?.kind == .caption)

        // The compositor paints the array from the bottom up, so the camera
        // bubble has to sit at a lower index than the screen it draws over.
        let screenIndex = try #require(timeline.tracks.firstIndex { $0.clips.contains { $0.id == screen.id } })
        let cameraIndex = try #require(timeline.tracks.firstIndex { $0.clips.contains { $0.id == camera.id } })
        #expect(cameraIndex < screenIndex)
        #expect(timeline.track(containing: camera.id)?.kind == .video)
    }

    @Test func screenFallsBackWhenTheVideoTrackIsBusy() throws {
        let sequence = SequenceProject(name: "Timeline")
        var timeline = sequence.timeline
        let v1 = try #require(timeline.tracks.first { $0.kind == .video })
        let blocker = Clip(source: .init(id: "video:\(UUID())", kind: .video, displayName: "Blocker"), start: 0, duration: 20)
        try TimelineEditor.insert(&timeline, clip: blocker, on: v1.id)
        sequence.timeline = timeline

        _ = try RecordingTimelineService.insert(take: take(autoZoom: false), into: sequence, at: 2)
        let screen = try #require(sequence.timeline.allClips.first { $0.recording?.role == .screen })
        let track = try #require(sequence.timeline.track(containing: screen.id))
        #expect(track.kind == .video)
        #expect(track.id != v1.id)
        #expect(sequence.timeline.clip(id: blocker.id)?.start == 0)
    }

    @Test func autoZoomMaterializesClipsOnce() throws {
        let sequence = SequenceProject(name: "Timeline")
        let ids = try RecordingTimelineService.insert(take: take(), into: sequence, at: 0)
        let timeline = sequence.timeline
        let lane = try #require(timeline.tracks.first { $0.kind == .zoom })
        // The clicks at 1 and 1.25 fall in one window; the one at 6 opens another.
        #expect(lane.clips.count == 2)
        #expect(lane.alias == "Zoom")
        #expect(lane.clips.allSatisfy { $0.recordingZoom?.scale == 2.5 })
        #expect(lane.clips.allSatisfy { $0.source.kind == .zoom })
        // Zoom clips are not part of the take's edit group: a linked trim
        // requires every member to move its edge by the same amount.
        #expect(lane.clips.allSatisfy { $0.linkGroupID == nil })
        #expect(ids.count == timeline.allClips.count)

        let screen = try #require(timeline.allClips.first { $0.recording?.role == .screen })
        #expect(screen.recording?.autoZoom == false)
        let resolved = try #require(timeline.resolvedRecordingClip(screen).recording)
        #expect(resolved.zooms.count == 2)
        // A second insertion gets its own instance, and reuses the lane rather
        // than stacking another one on top.
        _ = try RecordingTimelineService.insert(take: take(), into: sequence, at: 20)
        #expect(Set(sequence.timeline.allClips.compactMap(\.recordingInstanceID)).count == 2)
        #expect(sequence.timeline.tracks.filter { $0.kind == .zoom }.count == 1)
        #expect(sequence.timeline.tracks.filter { $0.kind == .zoom }.flatMap(\.clips).count == 4)
    }

    @Test func previewTimelineDropsOtherWindowsZoomClips() throws {
        var presentation = RecordingClipPresentation()
        presentation.autoZoom = true
        presentation.pointer = [.init(time: 1, x: 0.3, y: 0.3, clicked: true)]
        let first = RecordingComponent(role: .screen, name: "First", filePath: "a.mov", duration: 8, width: 800, height: 600, sourceID: "1", presentation: presentation)
        let second = RecordingComponent(role: .screen, name: "Second", filePath: "b.mov", duration: 8, width: 800, height: 600, sourceID: "2", presentation: presentation)
        let take = RecordingTake(name: "Two windows")
        take.duration = 8
        take.components = [first, second]
        let preview = try RecordingTimelineService.previewTimeline(take)
        #expect(preview.allClips.filter { $0.recording?.role == .screen }.count == 1)
        let primary = try #require(preview.allClips.first { $0.recording?.role == .screen }?.recordingInstanceID)
        // A zoom clip carries no presentation, so the old filter let it through.
        #expect(preview.allClips.allSatisfy { $0.recordingZoom == nil || $0.recordingInstanceID == primary })
        #expect(preview.allClips.contains { $0.recordingZoom != nil })
    }

    @Test func eachComponentPreviewsItselfRatherThanTheComposite() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ZoomPreview-\(UUID()).rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let context = document.container.mainContext
        let project = ScreenRecordingProject(name: "Demo")
        let recorded = take()
        recorded.project = project
        context.insert(project)
        context.insert(recorded)
        try context.save()

        let resolver = DocumentMediaResolver(document: document, width: 1920, height: 1080, fps: 60)
        let size = CGSize(width: 240, height: 136)
        var previews: [RecordingComponent.Role: LibPreviewSource] = [:]
        for component in recorded.components {
            let source = ClipSource(id: "screenRecording:\(component.id)", kind: component.sourceKind, displayName: component.name)
            previews[component.role] = try #require(await resolver.libraryPreview(for: source))
        }
        // Each component is its own preview, and its own cache entry: sharing
        // the take's id made every lane show one memoised composite frame.
        #expect(Set(previews.values.map(\.id)).count == previews.count)
        for (role, preview) in previews {
            #expect(preview.id == "screenRecording:\(try #require(recorded.components.first { $0.role == role }).id)")
        }
        let takePreview = try #require(await resolver.libraryPreview(for: recorded.clipSource))
        #expect(takePreview.id == recorded.clipSource.id)

        // The generated lanes draw their own content; the media-backed ones
        // have no file here, so only the drawn ones can be compared.
        let cursor = try #require(await previews[.cursor]?.thumbnail(at: 1.5, maximumSize: size))
        let shortcuts = try #require(await previews[.shortcuts]?.thumbnail(at: 1.5, maximumSize: size))
        #expect(bytes(cursor) != bytes(shortcuts))
        // A moment with no cue and a moment with one do not look the same.
        let quiet = try #require(await previews[.shortcuts]?.thumbnail(at: 4, maximumSize: size))
        #expect(bytes(shortcuts) != bytes(quiet))
        await document.close()
    }

    private func bytes(_ image: CGImage) -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
