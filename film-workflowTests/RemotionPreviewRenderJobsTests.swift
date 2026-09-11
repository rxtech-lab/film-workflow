import Foundation
import Testing
@testable import film_workflow

@Suite("Shared Remotion preview work", .serialized)
@MainActor
struct RemotionPreviewRenderJobsTests {
    @Test("An edit rejoins running work and receives its latest progress")
    func replacementReusesRender() async throws {
        let jobs = RemotionPreviewRenderJobs(gracePeriod: .seconds(1))
        let url = URL(fileURLWithPath: "/tmp/shared-preview.mov")
        let update = RenderProgress(stage: .rendering, fraction: 0.5, detail: "15 / 30")
        var starts = 0
        var gate: CheckedContinuation<Void, Never>?
        var replay: RenderProgress?
        let first = Task {
            try await jobs.value(for: "source", progress: { _ in }) { progress in
                starts += 1; progress(update)
                await withCheckedContinuation { gate = $0 }
                return url
            }
        }
        try await until { gate != nil }
        first.cancel()
        // Let the cancelled viewer detach before its replacement requests the same source.
        try await Task.sleep(for: .milliseconds(20))
        let replacement = Task {
            try await jobs.value(for: "source", progress: { replay = $0 }) { _ in
                starts += 1
                return url
            }
        }
        try await until { replay != nil }
        gate?.resume()
        #expect(try await replacement.value == url)
        do { _ = try await first.value; Issue.record("Cancelled viewer completed") } catch is CancellationError {}
        #expect(starts == 1 && replay == update)
    }

    @Test("Unclaimed work stops after the grace period and a failed render can retry")
    func cancellationAndRetry() async throws {
        let jobs = RemotionPreviewRenderJobs(gracePeriod: .milliseconds(30))
        var started = false, stopped = false
        let pending = Task {
            try await jobs.value(for: "cancel", progress: { _ in }) { _ in
                started = true
                defer { stopped = true }
                try await Task.sleep(for: .seconds(10))
                return URL(fileURLWithPath: "/tmp/cancelled-preview.mov")
            }
        }
        try await until { started }
        pending.cancel()
        try await until { stopped }
        do { _ = try await pending.value; Issue.record("Unclaimed render completed") } catch is CancellationError {}
        enum Failure: Error { case render }
        do {
            _ = try await jobs.value(for: "retry", progress: { _ in }) { _ in throw Failure.render }
            Issue.record("Failed render completed")
        } catch Failure.render {}
        let url = URL(fileURLWithPath: "/tmp/retried-preview.mov")
        #expect(try await jobs.value(for: "retry", progress: { _ in }) { _ in url } == url)
    }

    @Test("Preview resolution is bounded for landscape and portrait sequences")
    func previewResolution() {
        #expect(RemotionPreviewRenderCache.captureScale(width: 1920, height: 1080) == 0.5)
        #expect(RemotionPreviewRenderCache.captureScale(width: 1080, height: 1920) == 0.5)
        #expect(RemotionPreviewRenderCache.captureScale(width: 3840, height: 2160) == 0.25)
        #expect(RemotionPreviewRenderCache.captureScale(width: 640, height: 360) == 1)
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition(), "Preview job did not reach its expected state")
    }
}
