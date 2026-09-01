import Darwin
import Foundation

/// Runs a child process without allowing its lifetime or captured output to
/// grow without bound. Expected process failures are represented explicitly so
/// callers cannot accidentally collapse a timeout or missing executable into a
/// generic empty response.
nonisolated enum BoundedProcessRunner {
    struct Limits: Equatable, Sendable {
        let timeout: TimeInterval
        let terminationGrace: TimeInterval
        let maximumStandardOutputBytes: Int
        let maximumStandardErrorBytes: Int

        init(
            timeout: TimeInterval,
            terminationGrace: TimeInterval = 1,
            maximumStandardOutputBytes: Int,
            maximumStandardErrorBytes: Int
        ) {
            self.timeout = max(timeout, 0)
            self.terminationGrace = max(terminationGrace, 0)
            self.maximumStandardOutputBytes = max(maximumStandardOutputBytes, 0)
            self.maximumStandardErrorBytes = max(maximumStandardErrorBytes, 0)
        }
    }

    struct CapturedOutput: Equatable, Sendable {
        let standardOutput: Data
        let standardError: Data
        let standardOutputWasTruncated: Bool
        let standardErrorWasTruncated: Bool
    }

    enum Outcome: Equatable, Sendable {
        case exited(status: Int32, output: CapturedOutput)
        case timedOut(output: CapturedOutput)
        case executableNotFound(path: String)
        case launchFailed(message: String)
    }

    private static let pipeDrainGrace: TimeInterval = 0.25
    private static let postKillObservationLimit: TimeInterval = 1
    private static let ownershipObservationInterval: TimeInterval = 0.025

    static func run(
        executable: String,
        arguments: [String] = [],
        limits: Limits
    ) -> Outcome {
        run(
            executable: executable,
            arguments: arguments,
            limits: limits,
            processSnapshotProvider: processSnapshot
        )
    }

    /// Deterministic seam for the process-table failure path. Keeping the
    /// injected failure scoped to one invocation avoids mutable global hooks
    /// in tests while production always uses the real process table.
    static func runWithUnavailableProcessEnumerationForTesting(
        executable: String,
        arguments: [String] = [],
        limits: Limits
    ) -> Outcome {
        run(
            executable: executable,
            arguments: arguments,
            limits: limits,
            processSnapshotProvider: { .unavailable }
        )
    }

    /// Exercises the same final identity predicate used immediately before a
    /// signal without exposing a signal-capable test hook.
    static func wouldSignalCapturedProcessForTesting(
        pid: pid_t,
        capturedStartSeconds: UInt64,
        capturedStartMicroseconds: UInt64,
        ledBy sessionLeader: pid_t,
        requiresOriginalSession: Bool
    ) -> Bool {
        isCurrent(
            CapturedProcess(
                pid: pid,
                identity: ProcessIdentity(
                    pid: pid,
                    startSeconds: capturedStartSeconds,
                    startMicroseconds: capturedStartMicroseconds
                ),
                requiresOriginalSession: requiresOriginalSession
            ),
            ledBy: sessionLeader
        )
    }

    private static func run(
        executable: String,
        arguments: [String],
        limits: Limits,
        processSnapshotProvider: () -> ProcessSnapshot
    ) -> Outcome {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return .executableNotFound(path: executable)
        }

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()

        let standardOutputReader = CappedPipeReader(
            handle: standardOutputPipe.fileHandleForReading,
            maximumBytes: limits.maximumStandardOutputBytes
        )
        let standardErrorReader = CappedPipeReader(
            handle: standardErrorPipe.fileHandleForReading,
            maximumBytes: limits.maximumStandardErrorBytes
        )
        standardOutputReader.start()
        standardErrorReader.start()

        let didExit = DispatchSemaphore(value: 0)
        let waitState = ChildWaitState()
        let processIdentifier: pid_t

        switch spawn(
            executable: executable,
            arguments: arguments,
            standardOutputPipe: standardOutputPipe,
            standardErrorPipe: standardErrorPipe
        ) {
        case .success(let spawnedPID):
            processIdentifier = spawnedPID
        case .failure(let failure):
            try? standardOutputPipe.fileHandleForWriting.close()
            try? standardErrorPipe.fileHandleForWriting.close()
            standardOutputReader.stop()
            standardErrorReader.stop()

            if !FileManager.default.isExecutableFile(atPath: executable) {
                return .executableNotFound(path: executable)
            }
            return .launchFailed(message: failure.message)
        }
        let leaderIdentity = currentIdentity(of: processIdentifier)

        // The child inherited its own write descriptors during spawn. Closing
        // the parent's copies ensures EOF is observable as soon as the child
        // exits, even though the Pipe objects remain alive while output drains.
        try? standardOutputPipe.fileHandleForWriting.close()
        try? standardErrorPipe.fileHandleForWriting.close()

        DispatchQueue.global(qos: .utility).async {
            var waitStatus: Int32 = 0
            var result: pid_t
            repeat {
                result = waitpid(processIdentifier, &waitStatus, 0)
            } while result == -1 && errno == EINTR
            waitState.store(result == processIdentifier ? waitStatus : nil)
            didExit.signal()
        }

        // Observe ownership while the original leader still exists. A direct
        // child can call setsid() and be reparented as soon as the leader exits;
        // preserving its stable identity here lets normal-exit cleanup remain
        // safe after that parent relationship disappears.
        var observedOwnedProcesses: [pid_t: CapturedProcess] = [:]
        let timeoutDeadline = Date().addingTimeInterval(limits.timeout)
        var exitResult: DispatchTimeoutResult = .timedOut
        repeat {
            if leaderIdentity != nil,
               isOriginalSessionLeader(processIdentifier, expectedIdentity: leaderIdentity) {
                captureOwnedProcesses(
                    from: processSnapshotProvider(),
                    ledBy: processIdentifier,
                    includeDirectChildren: true,
                    into: &observedOwnedProcesses
                )
            }
            let remaining = max(timeoutDeadline.timeIntervalSinceNow, 0)
            exitResult = didExit.wait(
                timeout: .now() + min(ownershipObservationInterval, remaining)
            )
        } while exitResult == .timedOut && Date() < timeoutDeadline

        let timedOut = exitResult == .timedOut
        let initialSnapshot = processSnapshotProvider()
        let leaderRemainsCurrent = leaderIdentity != nil
            && isOriginalSessionLeader(processIdentifier, expectedIdentity: leaderIdentity)
        captureOwnedProcesses(
            from: initialSnapshot,
            ledBy: processIdentifier,
            includeDirectChildren: leaderRemainsCurrent,
            into: &observedOwnedProcesses
        )
        if timedOut {
            terminateOwnedProcesses(
                ledBy: processIdentifier,
                expectedLeaderIdentity: leaderIdentity,
                initialSnapshot: initialSnapshot,
                initiallyCaptured: observedOwnedProcesses,
                grace: limits.terminationGrace,
                processSnapshotProvider: processSnapshotProvider
            )
            // Keep observation bounded: the runner must return even if the
            // kernel/reaper path unexpectedly fails to report the leader.
            _ = didExit.wait(timeout: .now() + postKillObservationLimit)
        } else if observedOwnedProcesses.values.contains(where: {
            isCurrent($0, ledBy: processIdentifier)
        }) {
            // A command can exit after daemonizing a background process that
            // still owns the output pipes. BoundedProcessRunner owns the whole
            // private session, not just its leader, so no descendant is allowed
            // to outlive an otherwise successful invocation.
            terminateOwnedProcesses(
                ledBy: processIdentifier,
                expectedLeaderIdentity: leaderIdentity,
                initialSnapshot: initialSnapshot,
                initiallyCaptured: observedOwnedProcesses,
                grace: limits.terminationGrace,
                processSnapshotProvider: processSnapshotProvider
            )
        }

        let output = CapturedOutput(
            standardOutput: standardOutputReader.finish(waitingUpTo: pipeDrainGrace).data,
            standardError: standardErrorReader.finish(waitingUpTo: pipeDrainGrace).data,
            standardOutputWasTruncated: standardOutputReader.wasTruncated,
            standardErrorWasTruncated: standardErrorReader.wasTruncated
        )

        if timedOut {
            return .timedOut(output: output)
        }
        return .exited(
            status: waitState.waitStatus.map(exitStatus(fromWaitStatus:)) ?? -1,
            output: output
        )
    }

    /// `Process` inherits FinderPath's process group, so terminating only its
    /// PID can orphan a helper that inherited a pipe or ignored SIGTERM. Spawn
    /// each command as a fresh POSIX session instead. That gives cleanup a
    /// kernel-enforced ownership boundary covering shell children and job
    /// process groups that remain in that session.
    private static func spawn(
        executable: String,
        arguments: [String],
        standardOutputPipe: Pipe,
        standardErrorPipe: Pipe
    ) -> Result<pid_t, SpawnFailure> {
        let stdoutRead = standardOutputPipe.fileHandleForReading.fileDescriptor
        let stdoutWrite = standardOutputPipe.fileHandleForWriting.fileDescriptor
        let stderrRead = standardErrorPipe.fileHandleForReading.fileDescriptor
        let stderrWrite = standardErrorPipe.fileHandleForWriting.fileDescriptor

        for descriptor in [stdoutRead, stdoutWrite, stderrRead, stderrWrite] {
            let flags = fcntl(descriptor, F_GETFD)
            guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
                return .failure(SpawnFailure(
                    message: "Could not protect process pipe descriptors: \(errnoMessage(errno))"
                ))
            }
        }

        var fileActions: posix_spawn_file_actions_t?
        var setupResult = posix_spawn_file_actions_init(&fileActions)
        guard setupResult == 0 else {
            return .failure(SpawnFailure(
                message: "Could not initialize process file actions: \(errnoMessage(setupResult))"
            ))
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        setupResult = posix_spawn_file_actions_adddup2(&fileActions, stdoutWrite, STDOUT_FILENO)
        guard setupResult == 0 else {
            return .failure(SpawnFailure(
                message: "Could not connect process standard output: \(errnoMessage(setupResult))"
            ))
        }
        setupResult = posix_spawn_file_actions_adddup2(&fileActions, stderrWrite, STDERR_FILENO)
        guard setupResult == 0 else {
            return .failure(SpawnFailure(
                message: "Could not connect process standard error: \(errnoMessage(setupResult))"
            ))
        }
        for descriptor in [stdoutRead, stdoutWrite, stderrRead, stderrWrite]
        where descriptor != STDOUT_FILENO && descriptor != STDERR_FILENO {
            setupResult = posix_spawn_file_actions_addclose(&fileActions, descriptor)
            guard setupResult == 0 else {
                return .failure(SpawnFailure(
                    message: "Could not isolate process pipe descriptors: \(errnoMessage(setupResult))"
                ))
            }
        }

        var attributes: posix_spawnattr_t?
        setupResult = posix_spawnattr_init(&attributes)
        guard setupResult == 0 else {
            return .failure(SpawnFailure(
                message: "Could not initialize process attributes: \(errnoMessage(setupResult))"
            ))
        }
        defer { posix_spawnattr_destroy(&attributes) }
        setupResult = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        guard setupResult == 0 else {
            return .failure(SpawnFailure(
                message: "Could not isolate the process session: \(errnoMessage(setupResult))"
            ))
        }

        var argv = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        var environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        environment.append(nil)
        defer {
            argv.forEach { free($0) }
            environment.forEach { free($0) }
        }

        var processIdentifier: pid_t = -1
        let spawnResult = posix_spawn(
            &processIdentifier,
            executable,
            &fileActions,
            &attributes,
            argv,
            environment
        )
        guard spawnResult == 0 else {
            return .failure(SpawnFailure(
                message: "Could not start \(executable): \(errnoMessage(spawnResult))"
            ))
        }
        return .success(processIdentifier)
    }

    /// Gracefully terminates the private session plus direct children observed
    /// while the original leader is still alive. Direct children are captured
    /// even after `setsid()`, then identified by PID and process start time so
    /// an escaped child's recycled numeric PID is never signalled later.
    ///
    /// Repeated snapshots catch ordinary late forks, but no PID-table strategy
    /// can prove ownership of a child that deliberately double-forks and is
    /// reparented before it is ever observed. FinderPath's callers execute
    /// fixed system tools rather than adversarial programs; this is bounded
    /// cleanup, not a macOS process-containment sandbox.
    private static func terminateOwnedProcesses(
        ledBy sessionLeader: pid_t,
        expectedLeaderIdentity: ProcessIdentity?,
        initialSnapshot: ProcessSnapshot,
        initiallyCaptured: [pid_t: CapturedProcess],
        grace: TimeInterval,
        processSnapshotProvider: () -> ProcessSnapshot
    ) {
        guard sessionLeader > 1 else { return }

        var captured = initiallyCaptured
        let leaderIsCurrent = isOriginalSessionLeader(
            sessionLeader,
            expectedIdentity: expectedLeaderIdentity
        )
        let canDiscoverDescendants = expectedLeaderIdentity != nil && leaderIsCurrent

        if leaderIsCurrent {
            captured[sessionLeader] = CapturedProcess(
                pid: sessionLeader,
                identity: expectedLeaderIdentity,
                requiresOriginalSession: true
            )
        }
        captureOwnedProcesses(
            from: initialSnapshot,
            ledBy: sessionLeader,
            includeDirectChildren: canDiscoverDescendants,
            into: &captured
        )

        // If full process enumeration failed, retain the one target whose
        // ownership the kernel can still prove: the known session leader.
        // Both TERM and KILL revalidate that it still leads this exact session.
        if case .unavailable = initialSnapshot, leaderIsCurrent {
            captured[sessionLeader] = CapturedProcess(
                pid: sessionLeader,
                identity: expectedLeaderIdentity,
                requiresOriginalSession: true
            )
        }

        signalCapturedProcesses(captured.values, ledBy: sessionLeader, signal: SIGTERM)
        let deadline = Date().addingTimeInterval(max(grace, 0))

        while Date() < deadline {
            let leaderRemainsCurrent = expectedLeaderIdentity != nil
                && isOriginalSessionLeader(
                    sessionLeader,
                    expectedIdentity: expectedLeaderIdentity
                )
            // Session membership remains a safe ownership proof after the
            // original leader exits. Only the broader direct-child match needs
            // the leader's stable identity to remain current.
            captureOwnedProcesses(
                from: processSnapshotProvider(),
                ledBy: sessionLeader,
                includeDirectChildren: leaderRemainsCurrent,
                into: &captured
            )
            var hasSurvivors = captured.values.contains(where: {
                isCurrent($0, ledBy: sessionLeader)
            })
            if !hasSurvivors {
                // The leader may have spawned a same-session TERM child and
                // exited between the prior snapshot and identity check. Take a
                // post-exit session snapshot before concluding cleanup is done.
                captureOwnedProcesses(
                    from: processSnapshotProvider(),
                    ledBy: sessionLeader,
                    includeDirectChildren: false,
                    into: &captured
                )
                hasSurvivors = captured.values.contains(where: {
                    isCurrent($0, ledBy: sessionLeader)
                })
            }
            guard hasSurvivors else { return }
            usleep(10_000)
        }

        let leaderRemainsCurrent = expectedLeaderIdentity != nil
            && isOriginalSessionLeader(
                sessionLeader,
                expectedIdentity: expectedLeaderIdentity
            )
        captureOwnedProcesses(
            from: processSnapshotProvider(),
            ledBy: sessionLeader,
            includeDirectChildren: leaderRemainsCurrent,
            into: &captured
        )
        // Non-leaders are signalled first so the leader cannot orphan them
        // between their final identity check and escalation.
        signalCapturedProcesses(captured.values, ledBy: sessionLeader, signal: SIGKILL)
    }

    private static func captureOwnedProcesses(
        from snapshot: ProcessSnapshot,
        ledBy sessionLeader: pid_t,
        includeDirectChildren: Bool,
        into captured: inout [pid_t: CapturedProcess]
    ) {
        guard case .available(let records) = snapshot else { return }
        for record in records where record.pid > 1 {
            let belongsToSession = record.sessionID == sessionLeader
            let isDirectChild = includeDirectChildren && record.parentPID == sessionLeader
            guard belongsToSession || isDirectChild else { continue }

            let requiresOriginalSession = record.pid == sessionLeader
            captured[record.pid] = CapturedProcess(
                pid: record.pid,
                identity: record.identity,
                requiresOriginalSession: requiresOriginalSession
            )
        }
    }

    private static func signalCapturedProcesses(
        _ processes: Dictionary<pid_t, CapturedProcess>.Values,
        ledBy sessionLeader: pid_t,
        signal: Int32
    ) {
        let ordered = processes.sorted { lhs, rhs in
            if lhs.pid == sessionLeader { return false }
            if rhs.pid == sessionLeader { return true }
            return lhs.pid > rhs.pid
        }
        for process in ordered where isCurrent(process, ledBy: sessionLeader) {
            Darwin.kill(process.pid, signal)
        }
    }

    private static func isCurrent(
        _ process: CapturedProcess,
        ledBy sessionLeader: pid_t
    ) -> Bool {
        guard process.pid > 1 else { return false }
        if let identity = process.identity,
           currentIdentity(of: process.pid) != identity {
            return false
        }
        if process.requiresOriginalSession,
           getsid(process.pid) != sessionLeader {
            return false
        }
        return process.identity != nil || process.requiresOriginalSession
    }

    private static func isOriginalSessionLeader(
        _ sessionLeader: pid_t,
        expectedIdentity: ProcessIdentity?
    ) -> Bool {
        guard sessionLeader > 1, getsid(sessionLeader) == sessionLeader else {
            return false
        }
        guard let expectedIdentity else {
            // Session identity is sufficient for the fail-safe leader signal,
            // but not for widening discovery onto other processes.
            return true
        }
        return currentIdentity(of: sessionLeader) == expectedIdentity
    }

    private static func currentIdentity(of processIdentifier: pid_t) -> ProcessIdentity? {
        guard processIdentifier > 1 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let copiedSize = proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize
        )
        guard copiedSize == expectedSize,
              pid_t(info.pbi_pid) == processIdentifier else { return nil }
        return ProcessIdentity(
            pid: processIdentifier,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec
        )
    }

    private static func processSnapshot() -> ProcessSnapshot {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride

        for _ in 0..<3 {
            var byteCount = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &byteCount, nil, 0) == 0,
                  byteCount > 0 else { break }
            byteCount += stride * 16
            var processes = [kinfo_proc](
                repeating: kinfo_proc(),
                count: max(byteCount / stride, 1)
            )
            var filledBytes = processes.count * stride
            let result = processes.withUnsafeMutableBytes { buffer in
                sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &filledBytes, nil, 0)
            }
            if result == -1, errno == ENOMEM { continue }
            guard result == 0 else { break }

            var records: [ProcessRecord] = []
            for process in processes.prefix(filledBytes / stride) {
                let candidate = process.kp_proc.p_pid
                let seconds = process.kp_proc.p_starttime.tv_sec
                let microseconds = process.kp_proc.p_starttime.tv_usec
                guard candidate > 1, seconds >= 0, microseconds >= 0 else { continue }
                let sessionID = getsid(candidate)
                records.append(ProcessRecord(
                    identity: ProcessIdentity(
                        pid: candidate,
                        startSeconds: UInt64(seconds),
                        startMicroseconds: UInt64(microseconds)
                    ),
                    parentPID: process.kp_eproc.e_ppid,
                    sessionID: sessionID >= 0 ? sessionID : nil
                ))
            }
            return .available(records)
        }
        return .unavailable
    }

    private struct ProcessIdentity: Equatable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    private struct ProcessRecord {
        let identity: ProcessIdentity
        let parentPID: pid_t
        let sessionID: pid_t?

        var pid: pid_t { identity.pid }
    }

    private struct CapturedProcess {
        let pid: pid_t
        let identity: ProcessIdentity?
        let requiresOriginalSession: Bool
    }

    private enum ProcessSnapshot {
        case available([ProcessRecord])
        case unavailable
    }

    private static func exitStatus(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7F
        guard signal == 0 else { return 128 + signal }
        return (status >> 8) & 0xFF
    }

    private static func errnoMessage(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    private struct SpawnFailure: Error {
        let message: String
    }

    private final class ChildWaitState: @unchecked Sendable {
        private let lock = NSLock()
        private var storedWaitStatus: Int32?

        var waitStatus: Int32? {
            lock.lock()
            defer { lock.unlock() }
            return storedWaitStatus
        }

        func store(_ waitStatus: Int32?) {
            lock.lock()
            storedWaitStatus = waitStatus
            lock.unlock()
        }
    }

    /// FileHandle's readability callback drains the pipe continuously even
    /// after the configured prefix is full. That prevents a child from blocking
    /// on a full pipe while keeping retained memory at the requested ceiling.
    private final class CappedPipeReader: @unchecked Sendable {
        private let handle: FileHandle
        private let maximumBytes: Int
        private let completion = DispatchSemaphore(value: 0)
        private let lock = NSLock()

        private var captured = Data()
        private var truncated = false
        private var finished = false

        init(handle: FileHandle, maximumBytes: Int) {
            self.handle = handle
            self.maximumBytes = maximumBytes
        }

        var wasTruncated: Bool {
            lock.lock()
            defer { lock.unlock() }
            return truncated
        }

        func start() {
            handle.readabilityHandler = { [weak self] readableHandle in
                guard let self else { return }
                let chunk = readableHandle.availableData
                guard !chunk.isEmpty else {
                    self.reachedEndOfFile()
                    return
                }
                self.append(chunk)
            }
        }

        func finish(waitingUpTo timeout: TimeInterval) -> (data: Data, completed: Bool) {
            lock.lock()
            let alreadyFinished = finished
            lock.unlock()

            if !alreadyFinished,
               completion.wait(timeout: .now() + max(timeout, 0)) == .timedOut {
                stop(markingTruncated: true)
            }

            lock.lock()
            defer { lock.unlock() }
            return (captured, finished)
        }

        func stop() {
            stop(markingTruncated: false)
        }

        private func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }

            let remaining = maximumBytes - captured.count
            if remaining > 0 {
                captured.append(chunk.prefix(remaining))
            }
            if chunk.count > remaining {
                truncated = true
            }
        }

        private func reachedEndOfFile() {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            lock.unlock()

            handle.readabilityHandler = nil
            completion.signal()
        }

        private func stop(markingTruncated: Bool) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            if markingTruncated {
                truncated = true
            }
            lock.unlock()

            handle.readabilityHandler = nil
            try? handle.close()
            completion.signal()
        }
    }
}

/// Action-time validation for current, recent, and restored terminal folders.
/// Kept beside the bounded runner because its key contract is liveness: no
/// caller should accidentally replace this with a main-thread filesystem probe.
nonisolated enum FinderPathDirectoryTarget {
    enum Validation: Equatable, Sendable {
        case available
        case unavailable
        case timedOut
        case failed(String)

        var isAvailable: Bool { self == .available }
    }

    private static let validationLimits = BoundedProcessRunner.Limits(
        timeout: 1.5,
        terminationGrace: 0.1,
        maximumStandardOutputBytes: 0,
        maximumStandardErrorBytes: 1_024
    )

    /// Checks a target without issuing a potentially blocking `stat` on the
    /// main actor. A disconnected SMB/NFS/autofs mount can stall filesystem
    /// calls for many seconds; `/bin/test` runs in a killable child instead.
    static func validate(_ path: String) async -> Validation {
        guard !path.isEmpty else { return .unavailable }
        return await Task.detached(priority: .userInitiated) {
            Self.validation(
                from: BoundedProcessRunner.run(
                    executable: "/bin/test",
                    arguments: ["-d", path],
                    limits: Self.validationLimits
                )
            )
        }.value
    }

    private static func validation(from outcome: BoundedProcessRunner.Outcome) -> Validation {
        switch outcome {
        case .exited(let status, let output):
            if status == 0 { return .available }
            if status == 1 { return .unavailable }
            let detail = String(decoding: output.standardError, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(detail.isEmpty ? "The folder check exited with status \(status)." : detail)
        case .timedOut:
            return .timedOut
        case .executableNotFound:
            return .failed("The system folder-check tool is unavailable.")
        case .launchFailed(let message):
            return .failed(message)
        }
    }
}
