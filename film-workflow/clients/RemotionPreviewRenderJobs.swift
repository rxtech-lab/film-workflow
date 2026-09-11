import Foundation

/// Briefly retain unclaimed work so replacing a viewer after an edit can rejoin
/// the existing source render instead of starting again at frame zero.
@MainActor
final class RemotionPreviewRenderJobs {
    typealias Progress = @MainActor (RenderProgress) -> Void
    private struct Job {
        let id: UUID
        let task: Task<URL, Error>
        var consumers: [UUID: Progress]
        var lastProgress: RenderProgress?
        var idleCancellation: Task<Void, Never>?
    }
    private var jobs: [String: Job] = [:]
    private let gracePeriod: Duration

    init(gracePeriod: Duration = .seconds(2)) { self.gracePeriod = gracePeriod }

    func value(for key: String, progress: @escaping Progress,
               operation: @escaping @MainActor (@escaping Progress) async throws -> URL) async throws -> URL {
        try Task.checkCancellation()
        let consumer = UUID()
        if jobs[key] == nil {
            let id = UUID()
            let task = Task { @MainActor in
                try await operation { [weak self] update in
                    guard let self, let current = self.jobs[key], current.id == id else { return }
                    self.jobs[key]?.lastProgress = update
                    for callback in current.consumers.values { callback(update) }
                }
            }
            jobs[key] = Job(id: id, task: task, consumers: [:])
        }
        jobs[key]?.idleCancellation?.cancel()
        jobs[key]?.idleCancellation = nil
        jobs[key]?.consumers[consumer] = progress
        let job = jobs[key]!
        if let update = job.lastProgress { progress(update) }
        defer { release(key: key, consumer: consumer) }
        return try await withTaskCancellationHandler {
            do {
                let result = try await job.task.value
                try Task.checkCancellation()
                return result
            } catch {
                // Failed work must be retryable immediately. An individual cancelled
                // viewer must not discard work that a replacement viewer still needs.
                if !Task.isCancelled, jobs[key]?.id == job.id {
                    jobs.removeValue(forKey: key)?.idleCancellation?.cancel()
                }
                throw error
            }
        } onCancel: {
            Task { @MainActor in self.release(key: key, consumer: consumer) }
        }
    }

    private func release(key: String, consumer: UUID) {
        guard var job = jobs[key], job.consumers.removeValue(forKey: consumer) != nil else { return }
        if job.consumers.isEmpty {
            let id = job.id
            job.idleCancellation = Task { @MainActor [weak self, gracePeriod] in
                do { try await Task.sleep(for: gracePeriod) } catch { return }
                guard let self, let current = self.jobs[key], current.id == id, current.consumers.isEmpty else { return }
                self.jobs.removeValue(forKey: key)
                current.task.cancel()
            }
        }
        jobs[key] = job
    }
}
