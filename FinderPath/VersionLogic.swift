import Foundation

// Update checks and installs finish on URLSession's background delegate
// queue, so this logic is pure and free of main-actor isolation.
nonisolated enum AppVersion {
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

nonisolated struct UpdateManifest: Equatable, Sendable {
    let latestVersion: String
    let downloadURL: URL?
    // Direct .zip or .dmg asset suitable for in-app install; nil falls back
    // to opening downloadURL in the browser.
    let archiveURL: URL?
    let releaseNotes: String?
}

nonisolated enum UpdateCheckResult: Sendable {
    case upToDate(latest: String)
    case updateAvailable(manifest: UpdateManifest)
    case failed(message: String)
}

nonisolated enum UpdateChecker {
    private static let maximumManifestSize: Int64 = 1_024 * 1_024

    static func check(
        manifestURL: String,
        configuration: URLSessionConfiguration? = nil,
        completion: @escaping @Sendable (UpdateCheckResult) -> Void
    ) {
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
        let configuration = configuration ?? URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderPathManifest-\(UUID().uuidString).json")
        SizeLimitedDownload.start(
            request: request,
            configuration: configuration,
            maximumSize: maximumManifestSize,
            destination: destination
        ) { outcome in
            defer { try? FileManager.default.removeItem(at: destination) }
            completion(checkResult(from: outcome))
        }
    }

    private static func checkResult(from outcome: SizeLimitedDownload.Outcome) -> UpdateCheckResult {
        let sizeLimitMessage = "The update manifest exceeded the 1 MB safety limit."
        if outcome.rejectedRedirect {
            return .failed(message: "The update manifest redirected to an unsafe location.")
        }
        // Cancelling an oversized transfer also reports an error; the limit
        // is the cause worth showing.
        if outcome.exceededLimit {
            return .failed(message: sizeLimitMessage)
        }
        if let error = outcome.error {
            return .failed(message: "Could not reach the update server: \(error.localizedDescription)")
        }

        guard let http = outcome.response as? HTTPURLResponse else {
            return .failed(message: "The update server returned an invalid response.")
        }
        guard (200...299).contains(http.statusCode) else {
            return .failed(message: "Update server returned HTTP \(http.statusCode).")
        }
        guard let finalURL = http.url, isHTTPSWebURL(finalURL) else {
            return .failed(message: "The update manifest redirected to a non-HTTPS location.")
        }
        guard http.expectedContentLength <= maximumManifestSize else {
            return .failed(message: sizeLimitMessage)
        }

        guard let location = outcome.fileURL else {
            return .failed(message: "Update server returned no data.")
        }

        let responseSize = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init) ?? 0
        guard responseSize > 0 else {
            return .failed(message: "Update server returned no data.")
        }
        guard responseSize <= maximumManifestSize else {
            return .failed(message: sizeLimitMessage)
        }
        guard let data = try? Data(contentsOf: location, options: .mappedIfSafe) else {
            return .failed(message: "Could not read the update manifest.")
        }

        guard let manifest = parseManifest(data) else {
            return .failed(message: "Could not parse the update manifest. Expected JSON with a version field.")
        }

        let current = AppVersion.shortVersionString
        if compare(manifest.latestVersion, isNewerThan: current) {
            return .updateAvailable(manifest: manifest)
        }
        return .upToDate(latest: manifest.latestVersion)
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

    /// Release ordering follows SemVer 2.0.0 precedence: the dotted numeric
    /// core decides first; with an equal core a release outranks each of its
    /// prereleases, and build metadata ("+...") never affects ordering.
    static func compare(_ candidate: String, isNewerThan installed: String) -> Bool {
        guard let candidate = parsedVersion(candidate),
              let installed = parsedVersion(installed) else { return false }
        let coreOrder = compareCores(candidate.components, installed.components)
        if coreOrder != .orderedSame { return coreOrder == .orderedDescending }
        return comparePrereleases(candidate.prereleaseIdentifiers, installed.prereleaseIdentifiers)
            == .orderedDescending
    }

    /// Compares normalized decimal strings without converting to Int, so an
    /// oversized component keeps its numeric order.
    private static func compareDecimal(_ lhs: Substring, _ rhs: Substring) -> ComparisonResult {
        if lhs.count != rhs.count { return lhs.count > rhs.count ? .orderedDescending : .orderedAscending }
        if lhs == rhs { return .orderedSame }
        return lhs > rhs ? .orderedDescending : .orderedAscending
    }

    private static func compareCores(_ lhs: [String], _ rhs: [String]) -> ComparisonResult {
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : "0"
            let r = index < rhs.count ? rhs[index] : "0"
            let order = compareDecimal(Substring(l), Substring(r))
            if order != .orderedSame { return order }
        }
        return .orderedSame
    }

    private static func comparePrereleases(_ lhs: [Substring], _ rhs: [Substring]) -> ComparisonResult {
        switch (lhs.isEmpty, rhs.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false): break
        }
        for (l, r) in zip(lhs, rhs) {
            let order: ComparisonResult
            switch (isNumericIdentifier(l), isNumericIdentifier(r)) {
            case (true, true):
                order = compareDecimal(l.drop { $0 == "0" }, r.drop { $0 == "0" })
            case (true, false):
                order = .orderedAscending
            case (false, true):
                order = .orderedDescending
            case (false, false):
                order = l == r ? .orderedSame : (l > r ? .orderedDescending : .orderedAscending)
            }
            if order != .orderedSame { return order }
        }
        if lhs.count == rhs.count { return .orderedSame }
        return lhs.count > rhs.count ? .orderedDescending : .orderedAscending
    }

    private static func isNumericIdentifier(_ identifier: Substring) -> Bool {
        !identifier.isEmpty && identifier.utf8.allSatisfy { (48...57).contains($0) }
    }

    static func versionsAreEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        guard let lhs = parsedVersion(lhs), let rhs = parsedVersion(rhs) else {
            return false
        }

        // Verification must preserve the full suffix, while release ordering
        // uses the suffix only to break a tie between equal numeric cores.
        // Suffix numbers must never become extra core components (for
        // example, 1.9-rc.99 vs 1.9.1).
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

        /// Dot-separated identifiers between a leading "-" and the first "+";
        /// empty for a release and for a suffix that is only build metadata.
        var prereleaseIdentifiers: [Substring] {
            guard suffix.first == "-" else { return [] }
            return suffix.dropFirst()
                .prefix { $0 != "+" }
                .split(separator: ".", omittingEmptySubsequences: false)
        }
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
