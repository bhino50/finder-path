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
    static func check(manifestURL: String, completion: @escaping (UpdateCheckResult) -> Void) {
        let trimmed = manifestURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), isHTTPSWebURL(url) else {
            completion(.failed(message: "The update manifest URL must be an HTTPS URL."))
            return
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        if url.host?.contains("api.github.com") == true {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("FinderPath/\(AppVersion.shortVersionString)", forHTTPHeaderField: "User-Agent")
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failed(message: "Could not reach the update server: \(error.localizedDescription)"))
                return
            }

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                completion(.failed(message: "Update server returned HTTP \(http.statusCode)."))
                return
            }

            guard let data else {
                completion(.failed(message: "Update server returned no data."))
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

    private static func parseManifest(_ data: Data) -> UpdateManifest? {
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
              !version.isEmpty else {
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

        guard !version.isEmpty else { return nil }

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
        let lhs = numericComponents(candidate)
        let rhs = numericComponents(installed)
        let length = max(lhs.count, rhs.count)

        for index in 0..<length {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l > r }
        }

        return false
    }

    static func versionsAreEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        guard isRecognizableVersion(lhs), isRecognizableVersion(rhs) else {
            return false
        }

        let left = numericComponents(lhs)
        let right = numericComponents(rhs)
        let length = max(left.count, right.count)

        return (0..<length).allSatisfy { index in
            let leftComponent = index < left.count ? left[index] : 0
            let rightComponent = index < right.count ? right[index] : 0
            return leftComponent == rightComponent
        }
    }

    private static func isRecognizableVersion(_ version: String) -> Bool {
        let cleaned = version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "v", with: "", options: [.caseInsensitive, .anchored])
        guard !cleaned.isEmpty else { return false }

        return cleaned.split(separator: ".").allSatisfy { component in
            component.first?.isNumber == true
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

    private static func isHTTPSWebURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
    }

    private static func numericComponents(_ version: String) -> [Int] {
        let cleaned = version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "v", with: "", options: .caseInsensitive)

        return cleaned
            .split(separator: ".")
            .map { component -> Int in
                let digits = component.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
    }
}
