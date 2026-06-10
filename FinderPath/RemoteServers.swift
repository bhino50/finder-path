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
                guard !target.isEmpty else { continue }
                servers.append(RemoteServer(name: target, target: target))
                continue
            }

            let name = line[..<separatorIndex].trimmingCharacters(in: .whitespaces)
            let target = normalizedTarget(String(line[line.index(after: separatorIndex)...]))
            guard !target.isEmpty else { continue }

            servers.append(RemoteServer(name: name.isEmpty ? target : name, target: target))
        }

        return servers
    }

    static func serialize(_ servers: [RemoteServer]) -> String {
        servers.compactMap { server in
            let target = normalizedTarget(server.target)
            guard !target.isEmpty else { return nil }

            let name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(name.isEmpty ? target : name) = \(target)"
        }.joined(separator: "\n")
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

struct TailscaleDevice: Identifiable, Hashable, Sendable {
    let name: String
    let address: String
    let os: String
    let online: Bool

    var id: String { address.isEmpty ? name : address }
    var isLinux: Bool { os.lowercased() == "linux" }
}

nonisolated struct TailscaleStatus: Sendable {
    enum Backend: Sendable { case running, stopped, needsLogin, unavailable }

    let backend: Backend
    let selfAddress: String?
    let devices: [TailscaleDevice]

    static let unavailable = TailscaleStatus(backend: .unavailable, selfAddress: nil, devices: [])

    var isRunning: Bool { backend == .running }
}

nonisolated enum TailscaleBridge {
    static let appExecutablePath = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

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

    static func status() -> TailscaleStatus {
        guard let path = executablePath(),
              let data = run(path, arguments: ["status", "--json"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unavailable
        }

        let backend: TailscaleStatus.Backend
        switch json["BackendState"] as? String {
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

        return TailscaleStatus(backend: backend, selfAddress: selfAddress, devices: devices)
    }

    @discardableResult
    static func up() -> String? { runVoid(arguments: ["up"]) }

    @discardableResult
    static func down() -> String? { runVoid(arguments: ["down"]) }

    // Runs a tailscale subcommand for its side effect. Returns an error message on failure, nil on success.
    private static func runVoid(arguments: [String]) -> String? {
        guard let path = executablePath() else {
            return "Tailscale CLI was not found."
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let errorPipe = Pipe()
        task.standardOutput = Pipe()
        task.standardError = errorPipe

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return "Could not run tailscale: \(error.localizedDescription)"
        }

        if task.terminationStatus == 0 { return nil }

        let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message?.isEmpty == false ? message : "tailscale \(arguments.joined(separator: " ")) failed."
    }

    private static func run(_ path: String, arguments: [String]) -> Data? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return data.isEmpty ? nil : data
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
