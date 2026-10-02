import Foundation
import Observation

/// App-wide background rendering queue. Each kind of work runs with its own
/// concurrency limit, so a long composition prerender never starves timeline
/// thumbnails or waveforms. Items are listed while queued or running; a
/// finished item lingers briefly so fast renders don't flash by, and a failed
/// item stays listed until it is cleared.
@MainActor
@Observable
public final class RenderQueue {
    public static let shared = RenderQueue()

    public enum Kind: String, Sendable, CaseIterable {
        case remotion, thumbnail, waveform

        var limit: Int {
            switch self {
            case .remotion: 1
            case .thumbnail: 4
            case .waveform: 2
            }
        }
    }

    public enum State: Sendable, Equatable {
        case queued, running, finished, failed(String)
    }

    public struct Item: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let kind: Kind
        public let title: String
        public var detail: String?
        /// `nil` while the amount of remaining work is unknown.
        public var fraction: Double?
        public var state: State
    }

    /// Reports progress for one item. Safe to call from any isolation.
    public struct Reporter: Sendable {
        let id: UUID
        let queue: RenderQueue

        @MainActor
        public func update(_ fraction: Double?, detail: String? = nil) {
            queue.update(id, fraction: fraction, detail: detail)
        }

        public nonisolated func report(_ fraction: Double?, detail: String? = nil) {
            Task { @MainActor in update(fraction, detail: detail) }
        }
    }

    public private(set) var items: [Item] = []

    public var activeCount: Int { items.count { $0.isActive } }
    public var hasFailures: Bool { items.contains(where: \.isFailed) }

    private var running: [Kind: Int] = [:]
    private var waiters: [Kind: [(id: UUID, continuation: CheckedContinuation<Void, Error>)]] = [:]

    /// How long a finished item stays listed before it is removed.
    private let finishedLinger: Duration

    public init(finishedLinger: Duration = .seconds(3)) {
        self.finishedLinger = finishedLinger
    }

    /// Waits for a slot of `kind`, then runs `operation` in the caller's task,
    /// so cancelling the caller cancels (or dequeues) the work.
    public func run<T: Sendable>(_ kind: Kind, title: String,
                                 operation: @escaping @Sendable (Reporter) async throws -> T) async throws -> T {
        let id = UUID()
        items.append(Item(id: id, kind: kind, title: title, state: .queued))
        do {
            try await acquire(kind, id: id)
        } catch {
            items.removeAll { $0.id == id }
            throw error
        }
        defer { release(kind) }
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].state = .running }
        do {
            let value = try await operation(Reporter(id: id, queue: self))
            finish(id)
            return value
        } catch {
            // Thumbnails and waveforms are best-effort; only a failed prerender
            // is worth keeping in front of the user.
            if error is CancellationError || Task.isCancelled || kind != .remotion {
                items.removeAll { $0.id == id }
            } else if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].state = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    public func clearFailures() {
        items.removeAll(where: \.isFailed)
    }

    private func finish(_ id: UUID) {
        guard finishedLinger > .zero, let index = items.firstIndex(where: { $0.id == id }) else {
            items.removeAll { $0.id == id }
            return
        }
        items[index].state = .finished
        items[index].fraction = 1
        Task { [weak self, finishedLinger] in
            try? await Task.sleep(for: finishedLinger)
            self?.items.removeAll { $0.id == id && $0.state == .finished }
        }
    }

    private func update(_ id: UUID, fraction: Double?, detail: String?) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state == .running else { return }
        items[index].fraction = fraction.map { min(1, max(0, $0)) }
        if let detail { items[index].detail = detail }
    }

    private func acquire(_ kind: Kind, id: UUID) async throws {
        try Task.checkCancellation()
        if running[kind, default: 0] < kind.limit {
            running[kind, default: 0] += 1
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[kind, default: []].append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.dequeue(kind, id: id) }
        }
    }

    private func dequeue(_ kind: Kind, id: UUID) {
        guard let index = waiters[kind]?.firstIndex(where: { $0.id == id }) else { return }
        waiters[kind]!.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Hands the slot straight to the next waiter, preserving FIFO order.
    private func release(_ kind: Kind) {
        if var queue = waiters[kind], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[kind] = queue
            next.continuation.resume()
        } else {
            running[kind, default: 1] -= 1
        }
    }
}

public extension RenderQueue.Item {
    /// Queued or running: still has work to do.
    var isActive: Bool { state == .queued || state == .running }

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
}
