import Foundation
import Observation
import os
import VideoEditorCore

/// Scrubbing changes the viewer many times per second. Snapshot the transcript
/// once, and invalidate on the actual model reads (including direct cue edits,
/// which do not necessarily update the project's modification date).
@MainActor
final class CaptionLibraryPreviewCache {
    struct Preview {
        let source: LibPreviewSource
        let captionCount: Int
    }

    static let shared = CaptionLibraryPreviewCache()
    private let entries = NSMapTable<CaptionProject, Entry>.weakToStrongObjects()

    @Observable
    fileprivate final class Entry {
        var preview: Preview?
        var validity = OSAllocatedUnfairLock(initialState: true)
    }

    func preview(for project: CaptionProject) -> Preview {
        let entry: Entry
        if let existing = entries.object(forKey: project) {
            entry = existing
        } else {
            entry = Entry()
            entries.setObject(entry, forKey: project)
        }
        if let preview = entry.preview, entry.validity.withLock({ $0 }) { return preview }

        let validity = OSAllocatedUnfairLock(initialState: true)
        entry.validity = validity
        let preview = withObservationTracking {
            project.buildLibraryCaptionPreview()
        } onChange: { [weak entry] in
            // Mark stale synchronously so edit-then-read in the same turn sees
            // fresh cues; notify SwiftUI after the model mutation has finished.
            validity.withLock { $0 = false }
            Task { @MainActor in
                guard let entry, !entry.validity.withLock({ $0 }) else { return }
                entry.preview = nil
            }
        }
        entry.preview = preview
        return preview
    }
}
