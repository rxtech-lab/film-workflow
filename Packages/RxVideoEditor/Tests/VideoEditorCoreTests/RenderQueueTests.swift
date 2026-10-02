import Foundation
import Testing
@testable import VideoEditorCore

@MainActor
@Suite("Background render queue")
struct RenderQueueTests {
    private struct Failure: LocalizedError { var errorDescription: String? { "boom" } }

    /// Holds jobs until it is opened; once open, it stays open.
    private final class Gate: @unchecked Sendable {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        private let lock = NSLock()
        func wait() async {
            await withCheckedContinuation { continuation in
                let resume = lock.withLock {
                    if isOpen { return true }
                    continuations.append(continuation)
                    return false
                }
                if resume { continuation.resume() }
            }
        }
        func open() {
            let pending = lock.withLock { isOpen = true; defer { continuations = [] }; return continuations }
            pending.forEach { $0.resume() }
        }
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("Each kind respects its concurrency limit and runs waiters in order")
    func limits() async throws {
        let queue = RenderQueue(finishedLinger: .zero)
        let gate = Gate()
        let jobs = (0..<3).map { index in
            Task { try await queue.run(.waveform, title: "\(index)") { _ in await gate.wait(); return index } }
        }
        await settle { queue.items.count == 3 && queue.items.filter { $0.state == .running }.count == 2 }
        #expect(queue.items.map(\.state) == [.running, .running, .queued])
        #expect(queue.activeCount == 3)
        gate.open()
        var results: [Int] = []
        for job in jobs { results.append(try await job.value) }
        #expect(results == [0, 1, 2])
        #expect(queue.items.isEmpty)
    }

    @Test("Cancelling a queued item removes it without running it")
    func cancelQueued() async throws {
        let queue = RenderQueue(finishedLinger: .zero)
        let gate = Gate()
        let running = Task { try await queue.run(.remotion, title: "first") { _ in await gate.wait() } }
        let waiting = Task { try await queue.run(.remotion, title: "second") { _ in Issue.record("must not run") } }
        await settle { queue.items.count == 2 }
        waiting.cancel()
        await settle { queue.items.count == 1 }
        #expect(queue.items.map(\.title) == ["first"])
        await #expect(throws: CancellationError.self) { try await waiting.value }
        gate.open()
        try await running.value
        #expect(queue.items.isEmpty)
    }

    @Test("Progress is reported, and only prerender failures stay listed")
    func progressAndFailures() async throws {
        let queue = RenderQueue(finishedLinger: .zero)
        let gate = Gate()
        let job = Task {
            try await queue.run(.remotion, title: "comp") { reporter in
                await reporter.update(0.4, detail: "Rendering")
                await gate.wait()
                throw Failure()
            }
        }
        await settle { queue.items.first?.fraction == 0.4 }
        #expect(queue.items.first?.detail == "Rendering")
        gate.open()
        await #expect(throws: Failure.self) { try await job.value }
        #expect(queue.items.first?.state == .failed("boom"))
        #expect(queue.hasFailures && queue.activeCount == 0)
        queue.clearFailures()
        #expect(queue.items.isEmpty)

        await #expect(throws: Failure.self) {
            try await queue.run(.thumbnail, title: "frame") { _ in throw Failure() }
        }
        #expect(queue.items.isEmpty)
    }

    @Test("A finished item lingers before it is removed")
    func finishedLingers() async throws {
        let queue = RenderQueue(finishedLinger: .milliseconds(100))
        try await queue.run(.remotion, title: "comp") { _ in }
        #expect(queue.items.map(\.state) == [.finished])
        #expect(queue.items.first?.fraction == 1)
        #expect(queue.activeCount == 0 && !queue.hasFailures)
        await settle { queue.items.isEmpty }
        #expect(queue.items.isEmpty)
    }

    @Test("Waveform summaries round-trip through their disk archive")
    func waveformArchive() throws {
        let waveform = AudioWaveform(duration: 2.5, peaks: [0, 0.25, 1, 0.125])
        let decoded = try #require(AudioWaveform(archive: waveform.archive))
        #expect(decoded.duration == waveform.duration)
        #expect(decoded.peaks == waveform.peaks)
        #expect(AudioWaveform(archive: Data([1, 2, 3])) == nil)
    }
}
