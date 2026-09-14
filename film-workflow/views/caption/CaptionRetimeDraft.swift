import Foundation

/// Session-local timing values. Rendering and playback read these values rather
/// than repeatedly sorting/faulting the project's SwiftData relationships.
struct CaptionRetimeDraft {
    struct Range: Equatable {
        var startMs: Int
        var endMs: Int

        var isValid: Bool { endMs > startMs && startMs >= 0 }
    }

    let order: [UUID]
    private let indices: [UUID: Int]
    private let originals: [UUID: Range]
    private var ranges: [UUID: Range]
    private var changedIDs: Set<UUID> = []
    private var invalidIDs: Set<UUID>

    init(segments: [CaptionSegment] = []) {
        order = segments.map(\.uuid)
        indices = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        originals = Dictionary(uniqueKeysWithValues: segments.map {
            ($0.uuid, Range(startMs: $0.startMs, endMs: $0.endMs))
        })
        ranges = originals
        invalidIDs = Set(originals.compactMap { $0.value.isValid ? nil : $0.key })
    }

    var changedCount: Int { changedIDs.count }
    var hasInvalidRange: Bool { !invalidIDs.isEmpty }

    /// Only saving needs an ordered pass; the header/footer use changedCount.
    var pendingIDs: [UUID] { order.filter { changedIDs.contains($0) } }

    subscript(id: UUID) -> Range? { ranges[id] }
    func originalRange(for id: UUID) -> Range? { originals[id] }
    func index(of id: UUID) -> Int? { indices[id] }

    mutating func apply(_ ms: Int, to boundary: CaptionTimestampBoundary, for id: UUID) {
        guard var range = ranges[id] else { return }
        switch boundary {
        case .start:
            range.startMs = max(ms, 0)
            if range.endMs <= range.startMs { range.endMs = range.startMs + 1 }
        case .end:
            range.endMs = max(ms, range.startMs + 1)
        }
        ranges[id] = range
        if range == originals[id] {
            changedIDs.remove(id)
        } else {
            changedIDs.insert(id)
        }
        if range.isValid {
            invalidIDs.remove(id)
        } else {
            invalidIDs.insert(id)
        }
    }
}
