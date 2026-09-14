import Foundation
import VideoEditorCore

/// A request to show a particular moment of a sequence.
///
/// The agent edits a timeline through MCP, far from any window. Without this
/// the user watches a timeline change under a playhead that never moves — the
/// work happens, but not visibly. A handler that changed a clip posts the clip
/// it touched here, and whichever views are showing that film follow along:
/// the wizard's preview during the first build, the editor during a refine.
///
/// `token` makes two identical focuses distinguishable, so re-adding a clip at
/// the same time still moves the playhead.
nonisolated struct TimelineFocus: Equatable, Sendable, Identifiable {
    let sequenceID: UUID
    let clipID: UUID?
    let time: TimeInterval
    let token: UUID

    var id: UUID { token }

    init(sequenceID: UUID, clipID: UUID? = nil, time: TimeInterval, token: UUID = UUID()) {
        self.sequenceID = sequenceID
        self.clipID = clipID
        // A negative time would seek before the start and strand the playhead.
        self.time = max(0, time)
        self.token = token
    }
}

extension ProjectDocument {
    /// Asks the views showing this film to move to `time` in `sequenceID`.
    func focusTimeline(sequenceID: UUID, clipID: UUID? = nil, time: TimeInterval) {
        pendingTimelineFocus = TimelineFocus(sequenceID: sequenceID, clipID: clipID, time: time)
    }
}

extension SequenceProject {
    /// The clip a caller should focus after an edit whose exact target is not
    /// known: the first one that is new or moved, else the last clip.
    nonisolated static func focusTarget(
        before: Timeline?,
        after: Timeline
    ) -> (clipID: UUID, start: TimeInterval)? {
        let previous = Dictionary(
            (before?.allClips ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let changed = after.allClips
            .sorted { $0.start < $1.start }
            .first { clip in
                guard let old = previous[clip.id] else { return true }
                return old.start != clip.start || old.duration != clip.duration
            }
        if let changed { return (changed.id, changed.start) }
        guard let last = after.allClips.max(by: { $0.start < $1.start }) else { return nil }
        return (last.id, last.start)
    }
}

/// Waits for a player to finish loading, then seeks it.
///
/// The focus and the reload arrive from two different observers of the same
/// edit, in no guaranteed order, so seeking immediately can land on a player
/// that is about to be replaced. The wait is bounded: a media file that never
/// resolves must not leave the follow-along spinning.
@MainActor
enum TimelineFocusFollower {
    static let settleTimeout: Duration = .seconds(3)
    private static let pollInterval: Duration = .milliseconds(50)

    /// Returns false when the wait timed out or the task was cancelled.
    @discardableResult
    static func waitUntilLoaded(_ player: TimelinePlayerController) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: settleTimeout)
        while player.isLoading {
            guard ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: pollInterval) } catch { return false }
        }
        return !Task.isCancelled
    }
}
