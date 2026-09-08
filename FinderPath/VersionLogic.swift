import Foundation

enum AppVersion {
    static var current: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?) where short != build:
            return "\(short) (\(build))"
        case let (short?, _):
            return short
        case let (_, build?):
            return build
        default:
            return "unknown"
        }
    }

    static var shortVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}

struct UpdateManifest: Equatable {
    let latestVersion: String
    let downloadURL: URL?
    // Direct .zip or .dmg asset suitable for in-app install; nil falls back
    // to opening downloadURL in the browser.
    let archiveURL: URL?
    let releaseNotes: String?
}

enum UpdateCheckResult {
    case upToDate(latest: String)
    case updateAvailable(manifest: UpdateManifest)
    case failed(message: String)
}

enum UpdateChecker {
    private static let maximumManifestSize: Int64 = 1_024 * 1_024

    private final class ManifestSizeLimiter: NSObject, URLSessionDownloadDelegate {
        private let maximumSize: Int64
        private let lock = NSLock()
        private var exceeded = false
        private var rejectedRedirect = false

        init(maximumSize: Int64) {
            self.maximumSize = maximumSize
        }

        var didExceedLimit: Bool {
            lock.lock()
            defer { lock.unlock() }
            return exceeded
        }

        var didRejectRedirect: Bool {
            lock.lock()
            defer { lock.unlock() }
            return rejectedRedirect
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
            guard totalBytesWritten > maximumSize || totalBytesExpectedToWrite > maximumSize else {
                return
            }
            lock.lock()
            exceeded = true
            lock.unlock()
            downloadTask.cancel()
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {}
    }

    static func check(manifestURL: String, completion: @escaping (UpdateCheckResult) -> Void) {
        let trimmed = manifestURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), isHTTPSWebURL(url) else {
            completion(.failed(message: "The update manifest URL must be an HTTPS URL."))
            return
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        if url.host?.lowercased() == "api.github.com" {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("FinderPath/\(AppVersion.shortVersionString)", forHTTPHeaderField: "User-Agent")
        }

        // A fresh ephemeral session starts with no persisted Alt-Svc state, so
        // the request negotiates over TCP. The shared session's cached HTTP/3
        // mappings make it attempt QUIC, which stalls for the full timeout on
        // networks that silently drop UDP 443.
        let sizeLimiter = ManifestSizeLimiter(maximumSize: maximumManifestSize)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(
            configuration: configuration,
            delegate: sizeLimiter,
            delegateQueue: nil
        )
        session.downloadTask(with: request) { location, response, error in
            defer { session.finishTasksAndInvalidate() }
            if sizeLimiter.didRejectRedirect {
                completion(.failed(message: "The update manifest redirected to an unsafe location."))
                return
            }
            if let error {
                if sizeLimiter.didExceedLimit {
                    completion(.failed(message: "The update manifest exceeded the 1 MB safety limit."))
                    return
                }
                completion(.failed(message: "Could not reach the update server: \(error.localizedDescription)"))
                return
            }

            guard let http = response as? HTTPURLResponse else {
                completion(.failed(message: "The update server returned an invalid response."))
                return
            }
            guard (200...299).contains(http.statusCode) else {
                completion(.failed(message: "Update server returned HTTP \(http.statusCode)."))
                return
            }
            guard let finalURL = http.url, isHTTPSWebURL(finalURL) else {
                completion(.failed(message: "The update manifest redirected to a non-HTTPS location."))
                return
            }
            guard http.expectedContentLength <= maximumManifestSize else {
                completion(.failed(message: "The update manifest exceeded the 1 MB safety limit."))
                return
            }

            guard let location else {
                completion(.failed(message: "Update server returned no data."))
                return
            }

            let responseSize = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .map(Int64.init) ?? 0
            guard responseSize > 0 else {
                completion(.failed(message: "Update server returned no data."))
                return
            }
            guard responseSize <= maximumManifestSize else {
                completion(.failed(message: "The update manifest exceeded the 1 MB safety limit."))
                return
            }
            guard let data = try? Data(contentsOf: location, options: .mappedIfSafe) else {
                completion(.failed(message: "Could not read the update manifest."))
                return
            }

            guard let manifest = parseManifest(data) else {
                completion(.failed(message: "Could not parse the update manifest. Expected JSON with a version field."))
                return
            }

            let current = AppVersion.shortVersionString
            if compare(manifest.latestVersion, isNewerThan: current) {
                completion(.updateAvailable(manifest: manifest))
            } else {
                completion(.upToDate(latest: manifest.latestVersion))
            }
        }.resume()
    }

    static func parseManifest(_ data: Data) -> UpdateManifest? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let tag = json["tag_name"] as? String {
            return parseGitHubRelease(json: json, tag: tag)
        }

        let versionString = (json["version"] as? String)
            ?? (json["latest"] as? String)
            ?? (json["latestVersion"] as? String)

        guard let version = versionString?.trimmingCharacters(in: .whitespacesAndNewlines),
              parsedVersion(version) != nil else {
            return nil
        }

        let downloadString = (json["downloadURL"] as? String)
            ?? (json["url"] as? String)
            ?? (json["download_url"] as? String)
        let downloadURL = httpsURL(from: downloadString)
        let isDirectArchive = ["zip", "dmg"].contains(downloadURL?.pathExtension.lowercased() ?? "")

        let notes = (json["notes"] as? String)
            ?? (json["releaseNotes"] as? String)
            ?? (json["release_notes"] as? String)

        return UpdateManifest(
            latestVersion: version,
            downloadURL: downloadURL,
            archiveURL: isDirectArchive ? downloadURL : nil,
            releaseNotes: notes
        )
    }

    private static func parseGitHubRelease(json: [String: Any], tag: String) -> UpdateManifest? {
        let version = tag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "v", with: "", options: [.caseInsensitive, .anchored])

        guard parsedVersion(version) != nil else { return nil }

        let assets = (json["assets"] as? [[String: Any]]) ?? []
        let dmgURL = assets
            .first { (($0["name"] as? String) ?? "").hasSuffix(".dmg") }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap { httpsURL(from: $0) }
        let zipURL = assets
            .first { (($0["name"] as? String) ?? "").hasSuffix(".zip") }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap { httpsURL(from: $0) }
        let pageURL = httpsURL(from: json["html_url"] as? String)

        let notes = (json["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        return UpdateManifest(
            latestVersion: version,
            downloadURL: dmgURL ?? zipURL ?? pageURL,
            archiveURL: zipURL ?? dmgURL,
            releaseNotes: notes?.isEmpty == false ? notes : nil
        )
    }

    static func compare(_ candidate: String, isNewerThan installed: String) -> Bool {
        guard let candidate = parsedVersion(candidate),
              let installed = parsedVersion(installed) else { return false }
        let lhs = candidate.components
        let rhs = installed.components
        let length = max(lhs.count, rhs.count)

        for index in 0..<length {
            let l = index < lhs.count ? lhs[index] : "0"
            let r = index < rhs.count ? rhs[index] : "0"
            if l.count != r.count { return l.count > r.count }
            if l != r { return l > r }
        }

        return false
    }

    static func versionsAreEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        guard let lhs = parsedVersion(lhs), let rhs = parsedVersion(rhs) else {
            return false
        }

        // Verification must preserve the full suffix, while release ordering
        // compares only the dotted numeric core. Suffix numbers must never
        // become extra core components (for example, 1.9-rc.99 vs 1.9.1).
        guard lhs.suffix == rhs.suffix else { return false }

        let left = lhs.components
        let right = rhs.components
        let length = max(left.count, right.count)

        return (0..<length).allSatisfy { index in
            let leftComponent = index < left.count ? left[index] : "0"
            let rightComponent = index < right.count ? right[index] : "0"
            return leftComponent == rightComponent
        }
    }

    private static func httpsURL(from string: String?) -> URL? {
        guard let string,
              let url = URL(string: string),
              isHTTPSWebURL(url) else {
            return nil
        }

        return url
    }

    static func isHTTPSWebURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
            && url.user == nil && url.password == nil
    }

    private struct ParsedVersion {
        let components: [String]
        let suffix: String
    }

    /// Keep decimal components as normalized strings. Converting to Int used
    /// to turn an overflowing component into zero at the verification gate.
    private static func parsedVersion(_ version: String) -> ParsedVersion? {
        let cleaned = version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "v", with: "", options: [.caseInsensitive, .anchored])
        let numericPrefix = cleaned.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        let components = numericPrefix.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty }) else { return nil }

        let suffix = String(cleaned.dropFirst(numericPrefix.count)).lowercased()
        if !suffix.isEmpty {
            guard suffix.first == "-" || suffix.first == "+",
                  suffix.dropFirst().first?.isLetter == true || suffix.dropFirst().first?.isNumber == true,
                  suffix.utf8.allSatisfy({
                      (48...57).contains($0) || (97...122).contains($0)
                          || $0 == 45 || $0 == 46 || $0 == 43
                  }) else { return nil }
        }
        return ParsedVersion(
            components: components.map { component in
                let significantDigits = component.drop(while: { $0 == "0" })
                return significantDigits.isEmpty ? "0" : String(significantDigits)
            },
            suffix: suffix
        )
    }
}
