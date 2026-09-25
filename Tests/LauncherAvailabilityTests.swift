import Foundation
import os

private nonisolated struct ProbeObservations {
    var requests: [AgentAvailabilityRequest] = []
    var ranOnMainThread = false
    var timedOut = false
}

@main
struct LauncherAvailabilityTests {
    @MainActor
    static func main() async throws {
        var failures = 0
        var assertions = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertions += 1
            if !condition() {
                failures += 1
                print("FAIL: \(message)")
            }
        }

        // A deliberately blocked resolver must leave the main actor available
        // to release it. The deadline prevents a regression from hanging CI.
        let observations = OSAllocatedUnfairLock(initialState: ProbeObservations())
        let releaseProbe = DispatchSemaphore(value: 0)
        let cache = AgentAvailabilityCache(maximumAge: 60, capacity: 2) { request in
            observations.withLock {
                $0.requests.append(request)
                $0.ranOnMainThread = $0.ranOnMainThread || Thread.isMainThread
            }
            if releaseProbe.wait(timeout: .now() + 5) == .timedOut {
                observations.withLock { $0.timedOut = true }
            }
            return AgentAvailability(executable: request.executable, resolvedPath: "/fixture/\(request.executable)")
        }
        let firstRequest = AgentAvailabilityRequest(executable: "first")
        let secondRequest = AgentAvailabilityRequest(executable: "second")
        let first = Task { await cache.availability(for: firstRequest) }
        for _ in 0..<200 {
            if observations.withLock({ !$0.requests.isEmpty }) { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        expect(observations.withLock { $0.requests.count } == 1, "the first request starts a background probe")
        expect(!observations.withLock { $0.ranOnMainThread }, "the resolver never runs on the main thread")
        expect(!observations.withLock { $0.timedOut }, "the main actor resumes while the resolver is still waiting")

        let duplicate = Task { await cache.availability(for: firstRequest) }
        let second = Task { await cache.availability(for: secondRequest) }
        for _ in 0..<200 {
            if observations.withLock({ $0.requests.count >= 2 }) { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        expect(observations.withLock { $0.requests.count } == 2, "duplicate requests join the same worker")
        let excess = await cache.availability(for: AgentAvailabilityRequest(executable: "over-capacity"))
        expect(!excess.isInstalled, "excess distinct requests fail unavailable while the worker cap is full")
        expect(observations.withLock { $0.requests.count } == 2, "the worker cap does not start another resolver")
        releaseProbe.signal()
        releaseProbe.signal()
        let firstResult = await first.value
        let duplicateResult = await duplicate.value
        let secondResult = await second.value
        expect(firstResult == duplicateResult, "joined callers receive the same completed result")
        expect(secondResult.resolvedPath == "/fixture/second", "independent requests keep their own result")
        let cachedResult = await cache.availability(for: firstRequest)
        expect(cachedResult == firstResult, "completed results are reused within the cache lifetime")
        expect(observations.withLock { $0.requests.count } == 2, "a cache hit does not probe again")

        // A negative lookup must expire so installing an executable is visible
        // without restarting FinderPath.
        let expiryCalls = OSAllocatedUnfairLock(initialState: 0)
        let expiringCache = AgentAvailabilityCache(maximumAge: 0.01) { request in
            let call = expiryCalls.withLock { value in value += 1; return value }
            return AgentAvailability(executable: request.executable, resolvedPath: call == 1 ? nil : "/fixture/installed")
        }
        let missing = await expiringCache.availability(for: firstRequest)
        expect(!missing.isInstalled, "a missing executable is initially unavailable")
        try await Task.sleep(nanoseconds: 30_000_000)
        let installed = await expiringCache.availability(for: firstRequest)
        expect(installed.resolvedPath == "/fixture/installed", "an expired missing result is checked again")

        // Apply two actual asynchronous completions in reverse order through
        // the same state used by the menu. The earlier executable setting must
        // not reappear after the replacement setting has already resolved.
        var state = LauncherAvailabilityState()
        let oldRequest = AgentAvailabilityRequest(executable: "old-command")
        let newRequest = AgentAvailabilityRequest(executable: "new-command")
        let oldGate = DispatchSemaphore(value: 0)
        let newGate = DispatchSemaphore(value: 0)
        let snapshotCache = AgentAvailabilityCache { request in
            let gate = request == oldRequest ? oldGate : newGate
            _ = gate.wait(timeout: .now() + 5)
            return AgentAvailability(executable: request.executable, resolvedPath: "/fixture/\(request.executable)")
        }
        let oldGeneration = state.begin(["Agent": oldRequest])
        let oldLookup = Task { await snapshotCache.availability(for: oldRequest) }
        let newGeneration = state.begin(["Agent": newRequest])
        let newLookup = Task { await snapshotCache.availability(for: newRequest) }
        expect(!state.availability(for: "Agent", request: newRequest).isInstalled, "a changed executable has no stale actionable result")
        newGate.signal()
        let newResult = await newLookup.value
        expect(state.complete(["Agent": newResult], generation: newGeneration), "the newest menu lookup is accepted")
        oldGate.signal()
        let oldResult = await oldLookup.value
        expect(!state.complete(["Agent": oldResult], generation: oldGeneration), "a late old menu lookup is rejected")
        expect(state.availability(for: "Agent", request: newRequest) == newResult, "late completion leaves the new executable actionable")
        expect(!state.availability(for: "Agent", request: oldRequest).isInstalled, "cached results never match a different requested executable")
        _ = state.begin(["Agent": newRequest])
        expect(state.availability(for: "Agent", request: newRequest) == newResult, "reopening with unchanged commands retains completed rows")

        // Exercise the production subprocess protocol against filesystem
        // fixtures, including shell metacharacters and embedded newlines.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FinderPathLauncherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("agent '\"$`\nname", isDirectory: false)
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let realExecutable = await AgentLauncher.checkAvailability(for: executable.path)
        expect(realExecutable.resolvedPath == executable.path, "the bounded probe preserves quoted and newline-containing executable paths")
        let directoryResult = await AgentLauncher.checkAvailability(for: directory.path)
        expect(!directoryResult.isInstalled, "a searchable directory never counts as an executable")
        let notExecutable = directory.appendingPathComponent("no-execute")
        try Data("fixture".utf8).write(to: notExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: notExecutable.path)
        let noExecuteResult = await AgentLauncher.checkAvailability(for: notExecutable.path)
        expect(!noExecuteResult.isInstalled, "a regular file needs the execute bit")
        let fallbackResult = await AgentLauncher.checkAvailability(
            for: "finderpath-missing-\(UUID().uuidString)", fallbackPaths: [executable.path]
        )
        expect(fallbackResult.resolvedPath == executable.path, "a bundled fallback participates in the same bounded probe")
        let shellResult = await AgentLauncher.checkAvailability(for: "sh")
        expect(shellResult.resolvedPath?.hasPrefix("/") == true, "PATH lookup returns an absolute executable for launch actions")

        // FinderPath never reads shell startup files, so a CLI in a version
        // manager's folder is found only by the full path Settings asks for.
        let managerBin = directory.appendingPathComponent(".nvm/versions/node/v0/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: managerBin, withIntermediateDirectories: true)
        let managedName = "finderpath-managed-\(UUID().uuidString)"
        let managedAgent = managerBin.appendingPathComponent(managedName, isDirectory: false)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: managedAgent)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: managedAgent.path)
        let bareManaged = await AgentLauncher.checkAvailability(for: managedName)
        expect(!bareManaged.isInstalled, "a bare name is never looked up outside the documented search folders")
        let fullManaged = await AgentLauncher.checkAvailability(for: managedAgent.path)
        expect(fullManaged.resolvedPath == managedAgent.path, "a full path finds a version-managed CLI")

        // Terminal types the agent launch line into the user's login shell,
        // which may be zsh, bash, fish, or tcsh. Take the line back out of the
        // AppleScript literal Terminal receives, run it in each shell with
        // hostile folder names, and check where a stub agent starts.
        guard let launchRootPath = realpath(directory.path, nil) else {
            expect(false, "the launch fixture directory resolves")
            exit(1)
        }
        let launchRoot = String(cString: launchRootPath)
        free(launchRootPath)
        let stubAgent = launchRoot + "/stub-agent"
        let stubLoginShell = launchRoot + "/stub-login-shell"
        try Data("#!/bin/sh\nexec /bin/pwd -P\n".utf8).write(to: URL(fileURLWithPath: stubAgent))
        try Data("#!/bin/sh\nprintf 'login shell %s\\n' \"$*\"\n".utf8).write(to: URL(fileURLWithPath: stubLoginShell))
        for stub in [stubAgent, stubLoginShell] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub)
        }
        let shellLimits = BoundedProcessRunner.Limits(
            timeout: 10, maximumStandardOutputBytes: 64 * 1_024, maximumStandardErrorBytes: 64 * 1_024
        )
        func typedCommand(executable: String, folder: String) -> String? {
            let command = TerminalBridge.agentLaunchCommand(
                displayName: "Claude", executable: executable, directoryPath: folder
            )
            let assignment = TerminalBridge.terminalLaunchScriptSource(command: command)
                .components(separatedBy: "\n")[0]
            let outcome = BoundedProcessRunner.run(
                executable: "/usr/bin/osascript",
                arguments: ["-e", assignment, "-e", "return launchCommand"],
                limits: shellLimits
            )
            guard case .exited(0, let output) = outcome else { return nil }
            let text = String(decoding: output.standardOutput, as: UTF8.self)
            return text.hasSuffix("\n") ? String(text.dropLast()) : text
        }
        func runTyped(_ command: String, in shell: String) -> String {
            let outcome = BoundedProcessRunner.run(
                executable: "/usr/bin/env",
                arguments: [
                    "-i", "HOME=\(launchRoot)", "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
                    "SHELL=\(stubLoginShell)", shell, "-c", command
                ],
                limits: shellLimits
            )
            guard case .exited(_, let output) = outcome else { return "<\(shell) did not exit>" }
            return String(decoding: output.standardOutput, as: UTF8.self)
        }

        var loginShells = ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/tcsh"]
            .filter { AgentLauncher.isExecutableRegularFile(atPath: $0) }
        // fish is not part of macOS; cover it wherever it is installed.
        if let fish = AgentLauncher.availability(for: "fish").resolvedPath {
            loginShells.append(fish)
        }
        let folderNames = [
            "it's a dir", "dq\"x", "back\\slash", "trail\\", "a\\'b", "dollar $HOME", "tick`x`",
            "bang!x", "semi;colon && x", "-leading dash", "caf\u{E9} \u{65E5}\u{672C} \u{1F600}", "new\nline"
        ]
        for name in folderNames {
            let folder = launchRoot + "/" + name
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
            guard let command = typedCommand(executable: stubAgent, folder: folder) else {
                expect(false, "the launch command survives the AppleScript string round trip for \(name.debugDescription)")
                continue
            }
            // tcsh cannot hold a newline inside quotes; macOS allows the name
            // but it is not worth a temporary script file per launch.
            for shell in loginShells where !(name.contains("\n") && shell.hasSuffix("csh")) {
                let output = runTyped(command, in: shell)
                expect(
                    output == folder + "\n",
                    "\(shell) starts the agent in \(name.debugDescription), got \(output.debugDescription)"
                )
            }
        }

        let missingAgent = launchRoot + "/missing-agent"
        if let missingCommand = typedCommand(executable: missingAgent, folder: launchRoot) {
            for shell in loginShells {
                let output = runTyped(missingCommand, in: shell)
                expect(
                    output.contains("CLI was not found") && output.hasSuffix("login shell -l\n"),
                    "\(shell) reports a missing agent and opens a login shell, got \(output.debugDescription)"
                )
            }
        } else {
            expect(false, "the missing-agent command survives the AppleScript string round trip")
        }
        if let movedCommand = typedCommand(executable: stubAgent, folder: launchRoot + "/deleted folder") {
            for shell in loginShells {
                let output = runTyped(movedCommand, in: shell)
                expect(
                    output == "login shell -l\n",
                    "\(shell) opens a login shell when the folder is gone, got \(output.debugDescription)"
                )
            }
        } else {
            expect(false, "the missing-folder command survives the AppleScript string round trip")
        }

        if failures > 0 {
            print("\(failures) of \(assertions) launcher availability assertions failed")
            exit(1)
        }
        print("\(assertions) launcher availability assertions passed")
    }
}
