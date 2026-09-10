import Foundation

/// The footage being dragged right now, recorded when the drag starts.
///
/// macOS hands drop targets the pasteboard data only when the drop lands,
/// so a lane hovering the pointer could not otherwise know what is coming or
/// how long it is. Anything that starts a footage drag calls `begin`, and
/// the timeline reads `item` on entry to draw the clip at its true length.
@MainActor
public final class FootageDragSession {
    public static let shared = FootageDragSession()

    public private(set) var item: FootageDragItem?

    private init() {}

    /// Records the item for the drag that is starting.
    public func begin(_ item: FootageDragItem) {
        self.item = item
    }

    public func end() {
        item = nil
    }
}
