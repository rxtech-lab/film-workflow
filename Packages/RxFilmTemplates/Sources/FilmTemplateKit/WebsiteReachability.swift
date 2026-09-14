import Foundation

/// Checks the actual page, following redirects, without downloading its body.
public enum WebsiteReachability {
    public static func check(_ url: URL) async throws -> Bool {
        try await check(url, configuration: .ephemeral)
    }

    static func check(_ url: URL, configuration: URLSessionConfiguration) async throws -> Bool {
        guard IntakeSubmission.normalizedURL(url.absoluteString) != nil else { return false }
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        // Stop the body stream as soon as we have the response headers, and
        // cancel any pending connection when the view's task is cancelled.
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        let (_, response) = try await session.bytes(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse,
              let finalURL = response.url,
              IntakeSubmission.normalizedURL(finalURL.absoluteString) != nil
        else { return false }
        return (200..<300).contains(response.statusCode)
    }
}
