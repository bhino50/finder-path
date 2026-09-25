import Foundation

/// Downloads one resource to a caller-chosen file and cancels it as soon as
/// more than `maximumSize` bytes arrive. The task is deliberately
/// delegate-only: URLSession never reports progress for a task created with a
/// completion handler, so an oversized body would otherwise be written to disk
/// in full before any size check could run.
nonisolated final class SizeLimitedDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Outcome {
        /// The received file, already moved to the requested destination.
        let fileURL: URL?
        let response: URLResponse?
        let error: Error?
        let exceededLimit: Bool
        let rejectedRedirect: Bool
    }

    private let maximumSize: Int64
    private let destination: URL
    private let completion: @Sendable (Outcome) -> Void
    private let lock = NSLock()
    private var exceeded = false
    private var rejectedRedirect = false
    private var movedFile: URL?
    private var moveError: Error?
    private var completed = false

    private init(
        maximumSize: Int64,
        destination: URL,
        completion: @escaping @Sendable (Outcome) -> Void
    ) {
        self.maximumSize = maximumSize
        self.destination = destination
        self.completion = completion
    }

    /// `destination` must not exist yet, and the caller removes it once
    /// `completion` has run. `completion` runs exactly once, on the session's
    /// serial delegate queue. The returned object lets a caller observe the
    /// transfer's lifetime; it is released when the transfer ends.
    @discardableResult
    static func start(
        request: URLRequest,
        configuration: URLSessionConfiguration,
        maximumSize: Int64,
        destination: URL,
        completion: @escaping @Sendable (Outcome) -> Void
    ) -> SizeLimitedDownload {
        let download = SizeLimitedDownload(
            maximumSize: maximumSize,
            destination: destination,
            completion: completion
        )
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
        session.downloadTask(with: request).resume()
        // A session retains its delegate until invalidated. This lets the
        // task finish, then releases the session and its delegate.
        session.finishTasksAndInvalidate()
        return download
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, UpdateChecker.isHTTPSWebURL(url) else {
            lock.lock()
            rejectedRedirect = true
            lock.unlock()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesWritten > maximumSize || totalBytesExpectedToWrite > maximumSize else { return }
        lock.lock()
        exceeded = true
        lock.unlock()
        downloadTask.cancel()
    }

    /// Runs before completion, and the system deletes `location` as soon as
    /// this returns, so the file has to be moved here.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !exceeded, !rejectedRedirect else { return }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            movedFile = destination
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let outcome = Outcome(
            fileURL: movedFile,
            response: task.response,
            error: error ?? moveError,
            exceededLimit: exceeded,
            rejectedRedirect: rejectedRedirect
        )
        lock.unlock()
        completion(outcome)
    }
}
