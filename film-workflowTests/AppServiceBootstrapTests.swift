import AppKit
import Foundation
import SwiftUI
import Testing
@testable import film_workflow

@Suite(.serialized)
@MainActor
struct AppServiceBootstrapTests {
    private var snapshot: AccountSnapshot {
        AccountSnapshot(user: SubscriptionUser(id: "test", name: "Test", email: ""),
                        billing: BillingSnapshot(enabled: true, balancePoints: 42, reservedPoints: 0,
                                                 availablePoints: 42, pointsPerUsd: 100),
                        urls: .init(credits: "/credits", usage: "/usage"))
    }

    @Test("Dismissing the startup view still completes the account request exactly once")
    func windowDismissalKeepsStartupAlive() async throws {
        let bootstrap = AppServiceBootstrap()
        let gate = StartupGate()
        let cancelled = CancellationRecorder()
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [StartupBalanceURLProtocol.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        var requests = 0
        let store = CreditBalanceStore(isAuthenticated: { true }, loadAccount: {
            _ = try await session.data(from: URL(string: "https://balance.bootstrap.test/api/v1/me")!)
            requests += 1
            return snapshot
        })
        var starts = 0
        var completed = false
        let operation: @MainActor () async -> Void = {
            starts += 1
            await gate.wait()
            #expect(!Task.isCancelled)
            await store.refresh()
            completed = true
        }
        let host = NSHostingView(rootView: StartupTestView(visible: true, bootstrap: bootstrap,
                                                         operation: operation, cancelled: cancelled))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { gate.release(); window.close() }
        try await waitUntil { starts == 1 }

        // Remove the actual SwiftUI subtree that owns .task, as happens when
        // opening/restoring an editor dismisses the welcome window.
        host.rootView = StartupTestView(visible: false, bootstrap: bootstrap,
                                       operation: operation, cancelled: cancelled)
        host.layoutSubtreeIfNeeded()
        try await waitUntil { cancelled.value }
        #expect(!completed)
        gate.release()
        try await waitUntil { completed }
        #expect(store.availablePoints == 42)
        #expect(store.error == nil)
        #expect(requests == 1)
        await bootstrap.run { Issue.record("Another window must not repeat startup") }
        #expect(starts == 1)
    }

    @Test("A window cancelled before bootstrap starts can still initialize services")
    func alreadyCancelledWindow() async {
        let bootstrap = AppServiceBootstrap()
        let gate = StartupGate()
        var completed = false
        let caller = Task {
            await gate.wait()
            #expect(Task.isCancelled)
            await bootstrap.run {
                #expect(!Task.isCancelled)
                completed = true
            }
        }
        caller.cancel()
        gate.release()
        await caller.value
        #expect(completed)
    }

    @Test("Cancelled balance requests preserve the balance without reporting a server failure",
          arguments: [false, true])
    func cancellationDoesNotBecomeServerError(urlCancellation: Bool) async {
        let store = CreditBalanceStore(isAuthenticated: { true }, loadAccount: {
            if urlCancellation { throw URLError(.cancelled) }
            throw CancellationError()
        })
        store.apply(snapshot.billing)
        await store.refresh()
        #expect(store.error == nil)
        #expect(store.availablePoints == 42)
        #expect(!store.isLoading)
    }

    @Test("A real connection failure remains visible and a later refresh recovers")
    func connectionFailureAndRecovery() async {
        var offline = true
        let store = CreditBalanceStore(isAuthenticated: { true }, loadAccount: {
            if offline { throw URLError(.cannotConnectToHost) }
            return snapshot
        })
        await store.refresh()
        #expect(store.error == URLError(.cannotConnectToHost).localizedDescription)
        #expect(!store.isLoading)
        offline = false
        await store.refresh()
        #expect(store.error == nil)
        #expect(store.availablePoints == 42)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Timed out waiting for the startup lifecycle")
    }
}

@MainActor
private final class StartupGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private final class CancellationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var value: Bool { lock.withLock { cancelled } }
    func record() { lock.withLock { cancelled = true } }
}

private struct StartupTestView: View {
    let visible: Bool
    let bootstrap: AppServiceBootstrap
    let operation: @MainActor () async -> Void
    let cancelled: CancellationRecorder
    var body: some View {
        Group {
            if visible {
                Text("Welcome")
                    .task {
                        await withTaskCancellationHandler {
                            await bootstrap.run(operation)
                        } onCancel: {
                            cancelled.record()
                        }
                    }
            } else {
                Text("Editor")
            }
        }
    }
}

private final class StartupBalanceURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "balance.bootstrap.test"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
