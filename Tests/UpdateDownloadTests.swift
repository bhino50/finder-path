import Darwin
import Foundation

/// Records how much of a stubbed body was delivered and whether the client
/// stopped the transfer before the body was complete.
private final class StubDelivery: @unchecked Sendable {
    static let shared = StubDelivery()
    private let lock = NSLock()
    private var deliveredBytes = 0
    private var stopped = false

    var delivered: Int {
        lock.lock()
        defer { lock.unlock() }
        return deliveredBytes
    }

    var stoppedEarly: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func reset() {
        lock.lock()
        deliveredBytes = 0
        stopped = false
        lock.unlock()
    }

    func add(_ count: Int) {
        lock.lock()
        deliveredBytes += count
        lock.unlock()
    }

    func markStoppedEarly() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

/// Serves https://updates.invalid without a network. Large bodies stream in
/// 64 KiB pieces from a run-loop timer, so a client-side cancel shows up as a
/// short delivery count. Routes: /stream/<bytes> (no Content-Length),
/// /sized/<bytes>, /manifest, /missing (404), /empty and /redirect (to HTTP).
private final class StubUpdateServer: URLProtocol {
    static let host = "updates.invalid"
    private static let pieceSize = 64 * 1_024
    private var timer: Timer?
    private var sent = 0
    private var finished = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }
        let route = url.pathComponents.dropFirst()
        switch route.first {
        case "stream", "sized":
            stream(bytes: route.dropFirst().first.flatMap { Int($0) } ?? 0, declaresLength: route.first == "sized")
        case "manifest":
            respond(status: 200, body: Data(#"{"version":"99.0"}"#.utf8))
        case "empty":
            respond(status: 200, body: Data())
        case "redirect":
            let target = URL(string: "http://\(Self.host)/manifest")!
            let redirect = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString, "Content-Length": "0"]
            )!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: redirect)
            respond(status: 302, body: Data(), headers: ["Location": target.absoluteString])
        default:
            respond(status: 404, body: Data("not found".utf8))
        }
    }

    override func stopLoading() {
        if !finished { StubDelivery.shared.markStoppedEarly() }
        finished = true
        timer?.invalidate()
    }

    private func respond(status: Int, body: Data, headers: [String: String] = [:]) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers.merging(["Content-Length": String(body.count)]) { current, _ in current }
        )!
        finished = true
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func stream(bytes: Int, declaresLength: Bool) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: declaresLength ? ["Content-Length": String(bytes)] : [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let piece = Data(count: Self.pieceSize)
        let timer = Timer(timeInterval: 0.001, repeats: true) { [weak self] timer in
            guard let self, !self.finished else {
                timer.invalidate()
                return
            }
            let count = min(piece.count, bytes - self.sent)
            self.client?.urlProtocol(self, didLoad: piece.prefix(count))
            self.sent += count
            StubDelivery.shared.add(count)
            if self.sent >= bytes {
                self.finished = true
                timer.invalidate()
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        self.timer = timer
    }
}

/// Collects one asynchronous callback and counts how often it fired.
private final class CallbackBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let arrived = DispatchSemaphore(value: 0)
    private var storedValue: Value?
    private var storedCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }

    func store(_ value: Value) {
        lock.lock()
        storedValue = value
        storedCount += 1
        lock.unlock()
        arrived.signal()
    }

    func wait(seconds: TimeInterval = 20) -> Value? {
        guard arrived.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

@main
struct UpdateDownloadTests {
    static func main() {
        var failures: [String] = []
        var assertionCount = 0

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertionCount += 1
            if !condition() {
                failures.append(message)
            }
        }

        let oversizedBody = 16 * 1_024 * 1_024

        func stubConfiguration() -> URLSessionConfiguration {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubUpdateServer.self]
            return configuration
        }

        /// The stub learns about a cancel on its own thread, which can trail
        /// the client's completion slightly.
        func stubStoppedEarly() -> Bool {
            for _ in 0..<100 where !StubDelivery.shared.stoppedEarly {
                usleep(10_000)
            }
            return StubDelivery.shared.stoppedEarly
        }

        func checkManifest(at path: String) -> UpdateCheckResult? {
            StubDelivery.shared.reset()
            let box = CallbackBox<UpdateCheckResult>()
            UpdateChecker.check(
                manifestURL: "https://\(StubUpdateServer.host)\(path)",
                configuration: stubConfiguration()
            ) { box.store($0) }
            return box.wait()
        }

        func failureMessage(_ result: UpdateCheckResult?) -> String {
            if case .failed(let message) = result { return message }
            return ""
        }

        // Size limits must stop a transfer while bytes are still arriving,
        // whether or not the server declares the length up front.
        for path in ["/stream/\(oversizedBody)", "/sized/\(oversizedBody)"] {
            let result = checkManifest(at: path)
            expect(failureMessage(result).contains("1 MB safety limit"), "an oversized manifest is rejected by its size limit (\(path))")
            expect(stubStoppedEarly(), "an oversized manifest is cancelled mid-transfer (\(path))")
            expect(StubDelivery.shared.delivered < oversizedBody, "an oversized manifest is not downloaded in full (\(path))")
        }

        if case .updateAvailable(let manifest) = checkManifest(at: "/manifest") {
            expect(manifest.latestVersion == "99.0", "a valid manifest still parses after a streamed download")
        } else {
            expect(false, "a valid manifest reports the available update")
        }
        expect(!StubDelivery.shared.stoppedEarly, "a manifest within the limit is not cancelled")
        expect(failureMessage(checkManifest(at: "/redirect")).contains("unsafe location"), "a manifest redirect to HTTP is rejected")
        expect(failureMessage(checkManifest(at: "/missing")).contains("HTTP 404"), "a manifest HTTP error status is rejected")
        expect(failureMessage(checkManifest(at: "/empty")).contains("no data"), "an empty manifest body is rejected")

        // The archive download uses a small injected cap so the oversized case
        // stays fast; production passes the 256 MB limit.
        let archiveFixtures = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderPathDownloadTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: archiveFixtures) }
        do {
            try FileManager.default.createDirectory(at: archiveFixtures, withIntermediateDirectories: true)
        } catch {
            expect(false, "the archive download fixture directory can be created")
        }

        func downloadArchive(at path: String, maximumSize: Int64 = 1_024 * 1_024) -> (Result<URL, UpdateInstaller.InstallError>?, URL) {
            StubDelivery.shared.reset()
            let destination = archiveFixtures.appendingPathComponent("\(UUID().uuidString).zip")
            let box = CallbackBox<Result<URL, UpdateInstaller.InstallError>>()
            UpdateInstaller.downloadArchive(
                from: URL(string: "https://\(StubUpdateServer.host)\(path)")!,
                to: destination,
                maximumSize: maximumSize,
                configuration: stubConfiguration()
            ) { box.store($0) }
            return (box.wait(), destination)
        }

        func rejection(_ result: Result<URL, UpdateInstaller.InstallError>?) -> String {
            if case .failure(.downloadRejected(let detail)) = result { return detail }
            return ""
        }

        let (oversizedArchive, oversizedDestination) = downloadArchive(at: "/stream/\(oversizedBody)")
        expect(rejection(oversizedArchive).contains("1 MB safety limit"), "an oversized update package is rejected by its size limit")
        expect(stubStoppedEarly(), "an oversized update package is cancelled mid-transfer")
        expect(StubDelivery.shared.delivered < oversizedBody, "an oversized update package is not downloaded in full")
        expect(!FileManager.default.fileExists(atPath: oversizedDestination.path), "a rejected update package leaves no file behind")

        let packageSize = 512 * 1_024
        let (validArchive, validDestination) = downloadArchive(at: "/sized/\(packageSize)")
        if case .success(let archive) = validArchive {
            let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            expect(archive == validDestination && size == packageSize, "an update package within the limit arrives intact at its destination")
        } else {
            expect(false, "an update package within the limit downloads successfully")
        }
        expect(!StubDelivery.shared.stoppedEarly, "an update package within the limit is not cancelled")

        let (missingArchive, missingDestination) = downloadArchive(at: "/missing")
        expect(rejection(missingArchive).contains("HTTP 404"), "an update package HTTP error status is rejected")
        expect(!FileManager.default.fileExists(atPath: missingDestination.path), "an HTTP error body is removed from the destination")
        expect(rejection(downloadArchive(at: "/redirect").0).contains("unsafe location"), "an update package redirect to HTTP is rejected")
        expect(rejection(downloadArchive(at: "/empty").0).contains("empty"), "an empty update package is rejected")

        // Each transfer completes once and then releases its session delegate.
        // The pool drains references Foundation autoreleases on this thread.
        let lifecycleBox = CallbackBox<SizeLimitedDownload.Outcome>()
        weak let finishedDownload = autoreleasepool {
            SizeLimitedDownload.start(
                request: URLRequest(url: URL(string: "https://\(StubUpdateServer.host)/manifest")!),
                configuration: stubConfiguration(),
                maximumSize: 1_024,
                destination: archiveFixtures.appendingPathComponent("lifecycle.json")
            ) { lifecycleBox.store($0) }
        }
        expect(lifecycleBox.wait()?.fileURL != nil, "a delegate-only download delivers its file")
        for _ in 0..<100 where finishedDownload != nil {
            usleep(10_000)
        }
        expect(finishedDownload == nil, "a finished download releases its session delegate")
        expect(lifecycleBox.count == 1, "a download reports its outcome exactly once")

        if failures.isEmpty {
            print("UpdateDownloadTests passed (\(assertionCount) assertions)")
            return
        }

        for failure in failures {
            fputs("FAIL: \(failure)\n", stderr)
        }
        exit(EXIT_FAILURE)
    }
}
