import Foundation
import Testing
@testable import RxRemotion

@MainActor struct WebPageOperationTests {
    @Test func cancellationUnblocksMissingCallbackAndIgnoresLateReply() async throws {
        let operation = WebPageOperation<Int>()
        var reply: (@MainActor (Result<Int, Error>) -> Void)?
        let waiting = Task { @MainActor in
            try await operation.wait { reply = $0 }
        }
        while reply == nil { await Task.yield() }
        operation.cancel()
        do { _ = try await waiting.value; Issue.record("Expected cancellation") }
        catch is CancellationError {}
        reply?(.success(42))
        operation.cancel()
    }
    @Test func cancellationBeforeRegistrationDoesNotStartWork() async throws {
        let operation = WebPageOperation<Int>()
        operation.cancel()
        do {
            _ = try await operation.wait { _ in Issue.record("Cancelled operation started") }
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
    }
}
