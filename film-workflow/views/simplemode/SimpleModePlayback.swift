import Foundation
import Observation
import VideoEditorCore

/// The wizard previews like the editor: MotionSwift draws the picture (`MotionSequenceStage`)
/// and the transport is the clock that plays the sound.
@MainActor @Observable
final class SimpleModePlayback {
    let player = TimelinePlayerController()
    private(set) var timeline: Timeline?
    /// Kept for the host's status overlay; the MotionSwift stage reports its own failures.
    private(set) var preparation: String?
    private(set) var error: String?

    func load(_ sequence: SequenceProject?, document: ProjectDocument) {
        guard let sequence, !sequence.timeline.allClips.isEmpty else {
            unload()
            return
        }
        timeline = sequence.timeline
        let resolver = DocumentMediaResolver(document: document, width: sequence.width, height: sequence.height, fps: sequence.fps)
        player.load(sequence.timeline, resolver: resolver, audioOnly: true)
    }

    func unload() {
        player.unload()
        timeline = nil
        preparation = nil
        error = nil
    }
}
