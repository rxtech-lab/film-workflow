import AppKit
import SwiftData

@MainActor enum RecordingTakeLibrary {
    static func remove(_ take: RecordingTake, context: ModelContext, undoManager: UndoManager? = nil) throws {
        try setRemoved(true, take: take, context: context, undoManager: undoManager)
    }

    private static func setRemoved(_ removed: Bool, take: RecordingTake, context: ModelContext, undoManager: UndoManager?) throws {
        guard take.modelContext === context, !take.isDeleted else { throw RecordingError.message("This recording take is no longer available.") }
        let previous = take.isRemovedFromLibrary
        guard previous != removed else { return }
        let updatedAt = take.project?.updatedAt
        take.isRemovedFromLibrary = removed
        take.project?.updatedAt = Date()
        do {
            try context.save()
        } catch {
            take.isRemovedFromLibrary = previous
            if let updatedAt { take.project?.updatedAt = updatedAt }
            throw error
        }
        undoManager?.registerUndo(withTarget: take) { [weak undoManager] take in
            do { try setRemoved(previous, take: take, context: context, undoManager: undoManager) }
            catch { RecordingSources.shared.error = error.localizedDescription }
        }
        undoManager?.setActionName(String(localized: "Remove Recording Take"))
    }
}
