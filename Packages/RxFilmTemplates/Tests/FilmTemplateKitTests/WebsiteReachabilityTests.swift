import Foundation
import Testing
@testable import FilmTemplateKit

@Suite("Website reachability")
struct WebsiteReachabilityTests {
    private var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebsiteURLProtocol.self]
        return configuration
    }

    @Test("Only successful page responses are reachable", arguments: [200, 204, 403, 404, 500])
    func responseStatus(_ code: Int) async throws {
        let url = try #require(URL(string: "https://company.example/\(code)"))
        let reachable = try await WebsiteReachability.check(url, configuration: configuration)
        #expect(reachable == (200..<300).contains(code))
    }

    @Test("A page can be checked before its body finishes downloading")
    func streamingResponse() async throws {
        let url = try #require(URL(string: "https://company.example/stream"))
        let reachable = try await WebsiteReachability.check(url, configuration: configuration)
        #expect(reachable)
    }

    @Test("Connection failures are reported", arguments: ["offline", "timeout", "dns", "tls"])
    func connectionFailure(_ failure: String) async throws {
        let url = try #require(URL(string: "https://company.example/\(failure)"))
        await #expect(throws: URLError.self) {
            try await WebsiteReachability.check(url, configuration: configuration)
        }
    }

    @Test("Cancelling an obsolete check cancels the request")
    func cancellation() async throws {
        let url = try #require(URL(string: "https://company.example/pending"))
        let task = Task { try await WebsiteReachability.check(url, configuration: configuration) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("An obsolete check should not return a result")
        } catch {
            #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
    }
}

private final class WebsiteURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.lastPathComponent
        let failures: [String: URLError.Code] = [
            "offline": .notConnectedToInternet, "timeout": .timedOut,
            "dns": .cannotFindHost, "tls": .serverCertificateUntrusted,
        ]
        if let failure = failures[path] {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        if path == "pending" { return }
        let response = HTTPURLResponse(url: url, statusCode: Int(path) ?? 200,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path != "stream" { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {}
}
