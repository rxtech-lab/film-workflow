import Foundation

/// Downloads one file to a destination, reporting progress as it goes. A
/// download task rather than `bytes(for:)` so a 300 MB footage file streams
/// straight to disk without passing through Swift one byte at a time.
nonisolated final class MarketplaceDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveResult: Result<Void, Error>?

    private init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let delegate = MarketplaceDownloader(destination: destination, progress: progress)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 30 * 60
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is gone once this returns, so the move happens here, synchronously.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            moveResult = .failure(MarketplaceError.downloadFailed(http.statusCode))
            return
        }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
            moveResult = .success(())
        } catch {
            moveResult = .failure(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome: Result<Void, Error>
        if let error { outcome = .failure(error) } else { outcome = moveResult ?? .failure(MarketplaceError.downloadFailed(0)) }
        continuation?.resume(with: outcome)
        continuation = nil
    }
}
