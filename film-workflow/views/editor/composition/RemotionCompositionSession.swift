import CryptoKit
import Foundation
import MotionCore
import MotionEditor
import MotionPortable
import MotionSwiftUI
import Observation
import SwiftData
import VideoEditorCore
import SkiaKit

/// A Remotion clip opened in the editor ("drilled into"): its composition's elements shown as
/// lanes on the app's own timeline, its picture on MotionSwift's canvas, and the selected
/// element in the inspector. Edits are written to `src/Composition.tsx` by MotionSwift's
/// `EditorModel` and mirrored into the document, so the sequence preview, renders and the agent
/// see them.
@MainActor @Observable
final class RemotionCompositionSession {
    let project: RemotionProject
    /// Cached so timeline rebuilds never touch the model after its document closes.
    let projectID: UUID
    /// The sequence clip that was double-clicked, when the session came from the timeline.
    let clipID: UUID?
    private(set) var model: EditorModel?
    private(set) var setupError: String?
    /// The element lanes, rebuilt whenever the composition's tracks change.
    private(set) var timeline = Timeline(tracks: [])
    var selectedClipIDs: Set<UUID> = [] {
        didSet { selectionChanged() }
    }
    var pixelsPerSecond: Double = 60

    @ObservationIgnored private var clipIDsBySource: [String: UUID] = [:]
    @ObservationIgnored private var sourcesByClipID: [UUID: String] = [:]
    private var restingFrame: Int?

    init(project: RemotionProject, clipID: UUID?) {
        self.project = project
        self.projectID = project.id
        self.clipID = clipID
    }

    var name: String { project.name }

    // MARK: Opening

    func open() async {
        guard model == nil else { return }
        setupError = nil
        do {
            let directory = project.projectDir
            try RemotionRuntime.shared.prepareProjectDirectory(directory)
            if !FileManager.default.fileExists(atPath: project.compositionSourceURL.path) {
                guard !project.compositionSource.isEmpty else {
                    setupError = String(localized: "Generate the composition, then edit its elements here.")
                    return
                }
                try RemotionCodeBuilder.writeComposition(project: project, source: project.compositionSource)
            }
            let longest = Double(max(1, project.compositionWidth, project.compositionHeight))
            let scale = min(1, 1280 / longest)
            let editor = EditorModel(
                project: directory,
                entry: MotionSwiftEngine.entry,
                configuration: .init(scale: scale, backend: .gpu)
            )
            model = editor
            await editor.open(compositionID: MotionSwiftEngine.compositionID)
            editor.player.loops = false
            rebuildTimeline()
        } catch {
            setupError = error.localizedDescription
        }
    }

    func reload() async {
        guard let model else {
            await open()
            return
        }
        await model.open(compositionID: MotionSwiftEngine.compositionID)
        rebuildTimeline()
    }

    /// The agent, the Source sheet or another window changed the composition on disk.
    func reloadIfChanged() async {
        guard let model, model.files[RemotionElementsTab.compositionPath] != project.compositionSource else { return }
        await model.open(compositionID: MotionSwiftEngine.compositionID)
        rebuildTimeline()
    }

    /// Copies a MotionSwift edit into the document and reloads every preview of the project.
    func syncFromDisk(context: ModelContext) {
        project.syncCompositionSourceFromDisk(context: context)
        rebuildTimeline()
    }

    // MARK: Clock

    var fps: Double { model?.player.composition?.fps ?? Double(project.compositionFps) }
    var durationInFrames: Int { model?.player.composition?.durationInFrames ?? 1 }

    var playhead: TimeInterval {
        get { Double(restingFrame ?? model?.player.currentFrame ?? 0) / max(1, fps) }
        set {
            restingFrame = nil
            guard let model else { return }
            let frame = clampedFrame(for: newValue)
            if model.player.currentFrame != frame || model.player.isPlaying { model.scrub(to: frame) }
        }
    }

    var isPlaying: Bool { model?.player.isPlaying ?? false }

    func togglePlayback() {
        restingFrame = nil
        guard let player = model?.player else { return }
        if player.isPlaying { player.pause() } else { player.play() }
    }

    func step(by frames: Int) {
        restingFrame = nil
        model?.player.step(by: frames)
    }

    /// Previews `time` while hovering the timeline without moving the resting playhead.
    func skim(to time: TimeInterval) {
        guard let model, !model.player.isPlaying, time.isFinite else { return }
        if restingFrame == nil { restingFrame = model.player.currentFrame }
        let frame = clampedFrame(for: time)
        if model.player.currentFrame != frame { model.scrub(to: frame) }
    }

    /// Restores the resting playhead after the pointer leaves the timeline.
    func endSkim() {
        guard let resting = restingFrame else { return }
        restingFrame = nil
        guard let model, !model.player.isPlaying else { return }
        if model.player.currentFrame != resting { model.scrub(to: resting) }
    }

    private func clampedFrame(for seconds: TimeInterval) -> Int {
        min(max(0, Int((seconds * fps).rounded())), max(0, durationInFrames - 1))
    }

    // MARK: Timeline mapping

    static func displayLabel(for track: ObjectTrack) -> String {
        guard let preview = track.preview, !preview.isEmpty else { return track.label }
        return "\(track.label) · \(preview)"
    }

    /// One lane per element, frontmost first like the sequence timeline, each holding the
    /// element's visible span. Lanes keep their ids across rebuilds so selection survives edits.
    func rebuildTimeline() {
        guard let model, let composition = model.player.composition else { return }
        let fps = max(1, composition.fps)
        let duration = composition.durationInFrames
        var tracks: [Track] = []
        for track in model.timelineTracks.reversed() {
            let clipID = id(for: track.src, salt: "clip")
            let start = Double(track.start) / fps
            let end = Double(max(track.start + 1, track.end(in: duration))) / fps
            let editable: TimelineEditingCapabilities = track.reason == nil ? [.duration, .drag] : []
            let label = Self.displayLabel(for: track)
            let source = ClipSource(id: "element:\(track.src)", kind: .image, displayName: label, capabilities: editable)
            let clip = Clip(id: clipID, source: source, start: start, duration: end - start)
            tracks.append(Track(id: id(for: track.src, salt: "track"), kind: .overlay, name: label, clips: [clip],
                                alias: track.owner.flatMap { $0.isEmpty ? nil : $0 }))
        }
        var next = Timeline(id: id(for: projectID.uuidString, salt: "timeline"), width: composition.width, height: composition.height,
                            fps: Int(fps.rounded()), tracks: tracks)
        next.backgroundHex = "#000000"
        if next != timeline { timeline = next }
    }

    /// Applies what the timeline view changed: moved or trimmed spans become `setTiming` writes
    /// on the elements. Other edits (deleting, splitting, lanes) don't apply to composition code
    /// and are dropped by the rebuild.
    func apply(_ edited: Timeline) {
        guard let model else { return }
        let fps = max(1, self.fps)
        var writes: [(String, Int, Int)] = []
        for clip in edited.allClips {
            guard let source = sourcesByClipID[clip.id],
                  let old = timeline.allClips.first(where: { $0.id == clip.id }) else { continue }
            let start = Int((clip.start * fps).rounded())
            let length = max(1, Int((clip.duration * fps).rounded()))
            let oldStart = Int((old.start * fps).rounded()), oldLength = max(1, Int((old.duration * fps).rounded()))
            if start != oldStart || length != oldLength { writes.append((source, start, length)) }
        }
        // The view's optimistic edit is discarded; the composition is the authority.
        let current = timeline
        timeline = edited
        timeline = current
        guard !writes.isEmpty else { return }
        Task {
            for (source, start, length) in writes { await model.setTiming(of: source, start: start, duration: length) }
            rebuildTimeline()
        }
    }

    // MARK: Selection

    private var applyingModelSelection = false

    func selectElement(_ source: String) {
        restingFrame = nil
        let clipID = id(for: source, salt: "clip")
        selectedClipIDs = [clipID]
    }

    private func selectionChanged() {
        guard !applyingModelSelection, let model else { return }
        guard selectedClipIDs.count == 1, let id = selectedClipIDs.first, let source = sourcesByClipID[id],
              let track = model.timelineTracks.first(where: { $0.src == source }) else {
            if selectedClipIDs.isEmpty, model.selection != nil { model.clearSelection() }
            return
        }
        guard model.selection != source else { return }
        restingFrame = nil
        model.selectTrack(track)
        // Show a frame where the element is visible, so its box and styles resolve.
        let frame = model.player.currentFrame
        if frame < track.start || frame >= track.end(in: durationInFrames) { model.scrub(to: track.start) }
    }

    /// Mirrors a canvas selection onto the timeline.
    func followModelSelection() {
        let wanted: Set<UUID> = model?.selection.flatMap { clipIDsBySource[$0] }.map { [$0] } ?? []
        guard wanted != selectedClipIDs else { return }
        applyingModelSelection = true
        selectedClipIDs = wanted
        applyingModelSelection = false
    }

    // MARK: Ids

    private func id(for source: String, salt: String) -> UUID {
        if salt == "clip", let existing = clipIDsBySource[source] { return existing }
        let digest = Array(SHA256.hash(data: Data("\(salt):\(source)".utf8)))
        let id = UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                             digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
        if salt == "clip" {
            clipIDsBySource[source] = id
            sourcesByClipID[id] = source
        }
        return id
    }
}
