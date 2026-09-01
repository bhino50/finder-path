import Foundation

struct RemoteServer: Equatable {
    let name: String
    let target: String
}

enum RemoteServers {
    // Parses the user's curated server list (stored as plain text in preferences).
    // One server per line, in the form `Name = ssh-target`, for example:
    //   Dev Server = dev.example.com
    // The target can be a ~/.ssh/config alias or a `user@host` string. A line with
    // no `=` is used as both the display name and the target. Pasted commands like
    // `ssh user@host` are normalized to `user@host`. Blank lines and lines starting
    // with `#` are ignored.
    static func parse(_ text: String) -> [RemoteServer] {
        var servers: [RemoteServer] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            guard let separatorIndex = line.firstIndex(of: "=") else {
                let target = normalizedTarget(line)
                guard !target.isEmpty, isValidTarget(target) else { continue }
                servers.append(RemoteServer(name: target, target: target))
                continue
            }

            let name = line[..<separatorIndex].trimmingCharacters(in: .whitespaces)
            let target = normalizedTarget(String(line[line.index(after: separatorIndex)...]))
            guard !target.isEmpty, isValidTarget(target) else { continue }

            servers.append(RemoteServer(name: name.isEmpty ? target : name, target: target))
        }

        return servers
    }

    static func serialize(_ servers: [RemoteServer]) -> String {
        servers.compactMap { server in
            let target = normalizedTarget(server.target)
            guard !target.isEmpty, isValidTarget(target) else { return nil }

            let name = sanitizedName(server.name)
            return "\(name.isEmpty ? target : name) = \(target)"
        }.joined(separator: "\n")
    }

    /// The storage format is line-oriented `Name = target` text, so a display
    /// name is not free-form. An unsanitized name containing the separator, a
    /// newline, or a leading comment marker did not survive the round trip:
    /// `parse` splits on the FIRST '=', so "Dev = Prod" produced a line whose
    /// target failed validation and the server the user had just added
    /// silently vanished — or, with a newline, came back as a second phantom
    /// entry pointing at a different host.
    static func sanitizedName(_ rawName: String) -> String {
        let flattened = rawName
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .replacingOccurrences(of: "=", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading '#' would make `parse` treat the whole line as a comment.
        guard flattened.hasPrefix("#") else { return flattened }
        return String(flattened.drop(while: { $0 == "#" }))
            .trimmingCharacters(in: .whitespaces)
    }

    // Saved SSH targets are limited to hostname / user@host / ssh-config alias
    // shapes so an entry can never smuggle whitespace, shell syntax, or ssh
    // option flags into the connect command.
    private static let validTargetPattern = "^[A-Za-z0-9._@:-]+$"
    private static let alphanumericPattern = "[A-Za-z0-9]"

    static func isValidTarget(_ target: String) -> Bool {
        let atSignCount = target.reduce(into: 0) { count, character in
            if character == "@" { count += 1 }
        }

        return !target.isEmpty
            && !target.hasPrefix("-")
            && !target.hasPrefix("@")
            && !target.hasSuffix("@")
            && atSignCount <= 1
            && target.range(of: validTargetPattern, options: .regularExpression) != nil
            && target.range(of: alphanumericPattern, options: .regularExpression) != nil
    }

    static func normalizedTarget(_ rawTarget: String) -> String {
        let trimmedTarget = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmedTarget.split(whereSeparator: { $0 == " " || $0 == "\t" })

        guard parts.first?.lowercased() == "ssh" else {
            return strippedMatchingQuotes(trimmedTarget)
        }

        let argumentParts = Array(parts.dropFirst())
        let hostParts = argumentParts.first == "--" ? Array(argumentParts.dropFirst()) : argumentParts

        guard hostParts.count == 1 else {
            return trimmedTarget
        }

        return strippedMatchingQuotes(String(hostParts[0]))
    }

    private static func strippedMatchingQuotes(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              first == last,
              first == "\"" || first == "'" else {
            return value
        }

        return String(value.dropFirst().dropLast())
    }
}

nonisolated struct TailscaleDevice: Identifiable, Hashable, Sendable {
    let name: String
    let address: String
    let os: String
    let online: Bool

    var id: String { address.isEmpty ? name : address }
    var isLinux: Bool { os.lowercased() == "linux" }
}

nonisolated enum TailscaleFailure: Equatable, Sendable {
    case executableNotFound
    case timedOut(command: String)
    case commandFailed(command: String, exitStatus: Int32, detail: String?)
    case launchFailed(command: String, detail: String)
    case malformedStatus
    case outputLimitExceeded(command: String)

    var userMessage: String {
        switch self {
        case .executableNotFound:
            return "Tailscale CLI was not found."
        case .timedOut(let command):
            let hint = command.hasSuffix(" up")
                ? " If this node needs to sign in again, open the Tailscale app."
                : ""
            return "\(command) timed out.\(hint)"
        case .commandFailed(let command, let exitStatus, let detail):
            let prefix = "\(command) failed with exit status \(exitStatus)."
            guard let detail, !detail.isEmpty else { return prefix }
            return "\(prefix) \(detail)"
        case .launchFailed(let command, let detail):
            return "Could not run \(command): \(detail)"
        case .malformedStatus:
            return "Tailscale returned malformed status JSON."
        case .outputLimitExceeded(let command):
            return "\(command) returned more data than FinderPath can safely process."
        }
    }
}

nonisolated enum TailscaleCommandOutcome: Equatable, Sendable {
    case success
    case failure(TailscaleFailure)
}

nonisolated struct TailscaleStatus: Equatable, Sendable {
    enum Backend: Equatable, Sendable { case running, stopped, needsLogin, unavailable }

    let backend: Backend
    let selfAddress: String?
    let devices: [TailscaleDevice]
    let failure: TailscaleFailure?

    static let unavailable = TailscaleStatus(
        backend: .unavailable,
        selfAddress: nil,
        devices: [],
        failure: nil
    )

    static func failed(_ failure: TailscaleFailure) -> TailscaleStatus {
        TailscaleStatus(
            backend: .unavailable,
            selfAddress: nil,
            devices: [],
            failure: failure
        )
    }

    var isRunning: Bool { backend == .running }
}

nonisolated enum TailscaleBridge {
    static let appExecutablePath = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    static let statusCommand = "tailscale status --json"

    // How long a fetched status stays fresh. Reopening the Connect to Server
    // window within this interval reuses the cached result instead of
    // respawning the tailscale CLI.
    private static let statusCacheMaxAge: TimeInterval = 8
    private static let statusProcessLimits = BoundedProcessRunner.Limits(
        timeout: 10,
        terminationGrace: 1,
        maximumStandardOutputBytes: 2 * 1_024 * 1_024,
        maximumStandardErrorBytes: 64 * 1_024
    )
    private static let commandProcessLimits = BoundedProcessRunner.Limits(
        timeout: 20,
        terminationGrace: 1,
        maximumStandardOutputBytes: 64 * 1_024,
        maximumStandardErrorBytes: 64 * 1_024
    )

    private static let statusCache = TailscaleStatusCache {
        TailscaleBridge.fetchStatus()
    }

    static func executablePath() -> String? {
        if let resolved = AgentLauncher.availability(for: "tailscale", defaultExecutable: "tailscale").resolvedPath {
            return resolved
        }

        for candidate in ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", appExecutablePath] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    static var isInstalled: Bool { executablePath() != nil }

    // Async API for UI code. The blocking CLI work runs on a background
    // thread, and recent results are cached so the Connect to Server window
    // paints immediately. Pass forceRefresh for the manual refresh control.
    static func status(forceRefresh: Bool = false) async -> TailscaleStatus {
        await statusCache.status(forceRefresh: forceRefresh, maxAge: statusCacheMaxAge)
    }

    static func up() async -> TailscaleCommandOutcome {
        await Task.detached(priority: .userInitiated) {
            runCommand(arguments: ["up"])
        }.value
    }

    static func down() async -> TailscaleCommandOutcome {
        await Task.detached(priority: .userInitiated) {
            runCommand(arguments: ["down"])
        }.value
    }

    // Blocking status fetch. Spawns the tailscale CLI and waits for it to
    // exit, so only call this off the main thread (the cache actor does).
    fileprivate static func fetchStatus() -> TailscaleStatus {
        guard let path = executablePath() else {
            return .failed(.executableNotFound)
        }

        let outcome = BoundedProcessRunner.run(
            executable: path,
            arguments: ["status", "--json"],
            limits: statusProcessLimits
        )
        return status(from: outcome, command: statusCommand)
    }

    /// Converts the process layer's fully typed result into user-visible
    /// Tailscale state. Keeping this boundary pure makes every failure and
    /// output-cap path deterministic rather than requiring a locally installed
    /// and authenticated Tailscale daemon in the test suite.
    static func status(
        from outcome: BoundedProcessRunner.Outcome,
        command: String = statusCommand
    ) -> TailscaleStatus {
        let output: BoundedProcessRunner.CapturedOutput
        switch outcome {
        case .executableNotFound:
            return .failed(.executableNotFound)
        case .launchFailed(let message):
            return .failed(.launchFailed(command: command, detail: message))
        case .timedOut:
            return .failed(.timedOut(command: command))
        case .exited(let status, let captured):
            guard status == 0 else {
                return .failed(.commandFailed(
                    command: command,
                    exitStatus: status,
                    detail: commandDetail(from: captured)
                ))
            }
            output = captured
        }

        guard !output.standardOutputWasTruncated else {
            return .failed(.outputLimitExceeded(command: command))
        }
        return decodeStatus(output.standardOutput)
    }

    /// Decodes only the documented fields FinderPath consumes and supplies
    /// stable defaults for optional peer metadata. A missing BackendState is a
    /// malformed response because the UI cannot safely infer daemon state.
    static func decodeStatus(_ data: Data) -> TailscaleStatus {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let backendState = json["BackendState"] as? String else {
            return .failed(.malformedStatus)
        }

        let backend: TailscaleStatus.Backend
        switch backendState {
        case "Running": backend = .running
        case "NeedsLogin", "NoState": backend = .needsLogin
        default: backend = .stopped
        }

        let selfNode = json["Self"] as? [String: Any]
        let selfAddress = (selfNode?["TailscaleIPs"] as? [String])?.first

        var devices: [TailscaleDevice] = []
        if let peers = json["Peer"] as? [String: [String: Any]] {
            for peer in peers.values {
                // Prefer the MagicDNS short name (first label of DNSName): it resolves over
                // the tailnet and matches ~/.ssh/config aliases, so `ssh <name>` uses the
                // right user/key. The raw HostName can be uppercased or differ from the
                // alias, so it often resolves to neither.
                let shortName = (peer["DNSName"] as? String)
                    .flatMap { $0.split(separator: ".").first }
                    .map(String.init)
                let name = shortName ?? (peer["HostName"] as? String) ?? "unknown"
                let address = (peer["TailscaleIPs"] as? [String])?.first ?? ""
                let os = (peer["OS"] as? String) ?? ""
                let online = (peer["Online"] as? Bool) ?? false
                devices.append(TailscaleDevice(name: name, address: address, os: os, online: online))
            }
        }

        devices.sort { lhs, rhs in
            if lhs.online != rhs.online { return lhs.online && !rhs.online }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return TailscaleStatus(
            backend: backend,
            selfAddress: selfAddress,
            devices: devices,
            failure: nil
        )
    }

    // Runs a tailscale subcommand for its side effect and waits for it to
    // exit, so only call this off the main thread (the async wrappers do).
    private static func runCommand(arguments: [String]) -> TailscaleCommandOutcome {
        guard let path = executablePath() else {
            return .failure(.executableNotFound)
        }

        let command = "tailscale \(arguments.joined(separator: " "))"
        return commandOutcome(from: BoundedProcessRunner.run(
            executable: path,
            arguments: arguments,
            limits: commandProcessLimits
        ), command: command)
    }

    static func commandOutcome(
        from outcome: BoundedProcessRunner.Outcome,
        command: String
    ) -> TailscaleCommandOutcome {
        switch outcome {
        case .executableNotFound:
            return .failure(.executableNotFound)
        case .launchFailed(let message):
            return .failure(.launchFailed(command: command, detail: message))
        case .timedOut:
            return .failure(.timedOut(command: command))
        case .exited(let status, let output):
            guard status == 0 else {
                return .failure(.commandFailed(
                    command: command,
                    exitStatus: status,
                    detail: commandDetail(from: output)
                ))
            }
            return .success
        }
    }

    private static func commandDetail(
        from output: BoundedProcessRunner.CapturedOutput
    ) -> String? {
        let source: Data
        let sourceWasTruncated: Bool
        if !output.standardError.isEmpty {
            source = output.standardError
            sourceWasTruncated = output.standardErrorWasTruncated
        } else {
            source = output.standardOutput
            sourceWasTruncated = output.standardOutputWasTruncated
        }

        guard var text = String(data: source, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }

        let maximumCharacters = 500
        let shortened = text.count > maximumCharacters || sourceWasTruncated
        text = String(text.prefix(maximumCharacters))
        return shortened ? text + "…" : text
    }
}

// Serializes Tailscale status fetches and briefly caches the latest result so
// repeated lookups within a few seconds do not respawn the CLI. A forced
// refresh supersedes every older request: callers awaiting an older result are
// redirected to the newest generation so stale UI tasks cannot overwrite a
// manually refreshed status after it appears.
actor TailscaleStatusCache {
    typealias Fetcher = @Sendable () async -> TailscaleStatus

    private struct InFlightRequest {
        let generation: UInt64
        let task: Task<TailscaleStatus, Never>
    }

    private let fetcher: Fetcher
    private var cachedStatus: TailscaleStatus?
    private var fetchedAt = Date.distantPast
    private var generation: UInt64 = 0
    private var inFlightRequest: InFlightRequest?

    init(fetcher: @escaping Fetcher) {
        self.fetcher = fetcher
    }

    func status(forceRefresh: Bool, maxAge: TimeInterval) async -> TailscaleStatus {
        if !forceRefresh, let request = inFlightRequest {
            let status = await request.task.value
            return await resolve(status, for: request.generation)
        }

        if !forceRefresh,
           let cachedStatus,
           Date().timeIntervalSince(fetchedAt) < maxAge {
            return cachedStatus
        }

        generation &+= 1
        let requestGeneration = generation
        let fetcher = self.fetcher
        let task = Task.detached(priority: .userInitiated) {
            await fetcher()
        }
        inFlightRequest = InFlightRequest(generation: requestGeneration, task: task)

        let fresh = await task.value
        return await resolve(fresh, for: requestGeneration)
    }

    private func resolve(
        _ status: TailscaleStatus,
        for requestGeneration: UInt64
    ) async -> TailscaleStatus {
        guard requestGeneration == generation else {
            if let newestRequest = inFlightRequest {
                let newestStatus = await newestRequest.task.value
                return await resolve(newestStatus, for: newestRequest.generation)
            }
            // The newer generation already committed while this task was
            // resuming on the actor. Never leak the obsolete result back out.
            return cachedStatus ?? status
        }

        cachedStatus = status
        fetchedAt = Date()
        if inFlightRequest?.generation == requestGeneration {
            inFlightRequest = nil
        }
        return status
    }
}

nonisolated enum ShellCommand {
    static func argument(_ value: String, quoteStyle: String = "single") -> String {
        switch quoteStyle {
        case "double":
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "$", with: "\\$")
                .replacingOccurrences(of: "`", with: "\\`")

            return "\"\(escaped)\""
        default:
            return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
    }
}
