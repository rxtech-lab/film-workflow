import Foundation
import Testing
@testable import film_workflow

@MainActor
@Suite("Video polling recovery")
struct VideoPollingTests {
    private func job(status: String) -> BackendVideoClient.Job {
        .init(id: "existing-job", status: status, progressPercent: 25,
              resultUrl: nil, resultMeta: nil, error: nil)
    }

    @Test func retriesTemporaryFailuresOnTheSameJob() async throws {
        let failures: [Error] = [URLError(.timedOut), URLError(.networkConnectionLost),
                                 BackendError.server(503, nil), BackendError.server(429, nil)]
        var polls = 0
        var delays: [TimeInterval] = []
        let result = try await BackendVideoClient.waitForJob(
            jobID: "existing-job", startedAt: Date(),
            fetchJob: { id in
                #expect(id == "existing-job")
                let attempt = polls
                polls += 1
                if attempt < failures.count { throw failures[attempt] }
                return job(status: attempt == failures.count ? "running" : "succeeded")
            },
            sleep: { delays.append($0) }
        )
        #expect(result.status == "succeeded")
        #expect(polls == 6)
        #expect(delays == [3, 4, 5, 6, 7])
    }

    @Test func permanentFailureDoesNotRetry() async {
        var polls = 0
        do {
            _ = try await BackendVideoClient.waitForJob(
                jobID: "existing-job", startedAt: Date(),
                fetchJob: { _ in polls += 1; throw BackendError.badRequest("Job missing") },
                sleep: { _ in Issue.record("Must not retry a rejected poll") }
            )
            Issue.record("Expected permanent failure")
        } catch VideoGenError.jobFailed(let message) {
            #expect(message == "Job missing")
        } catch { Issue.record("Unexpected error: \(error)") }
        #expect(polls == 1)
    }

    @Test func cancellationDoesNotRetry() async {
        do {
            _ = try await BackendVideoClient.waitForJob(
                jobID: "existing-job", startedAt: Date(),
                fetchJob: { _ in throw URLError(.cancelled) },
                sleep: { _ in Issue.record("Must not retry cancellation") }
            )
            Issue.record("Expected cancellation")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func overallDeadlineStillStopsWaiting() async {
        do {
            _ = try await BackendVideoClient.waitForJob(
                jobID: "existing-job", startedAt: Date(), timeout: 0,
                fetchJob: { _ in Issue.record("Budget already expired"); return job(status: "running") }
            )
            Issue.record("Expected wait timeout")
        } catch VideoGenError.timedOut { }
        catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func onlyRecoverableErrorsAreRetried() {
        #expect(BackendVideoClient.isTransientPollError(BackendError.server(408, nil)))
        #expect(!BackendVideoClient.isTransientPollError(BackendError.unauthorized))
        #expect(!BackendVideoClient.isTransientPollError(URLError(.cancelled)))
        #expect(!BackendVideoClient.isTransientPollError(BackendError.decoding(URLError(.badServerResponse))))
    }
}
