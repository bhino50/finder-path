import Darwin
import Foundation

@main
struct BoundedProcessRunnerTests {
    static func main() {
        if CommandLine.arguments.count == 3,
           CommandLine.arguments[1] == "--setsid-child-fixture" {
            runSetsidChildFixture(
                pidFilePath: CommandLine.arguments[2],
                exitsNormally: false
            )
        }
        if CommandLine.arguments.count == 3,
           CommandLine.arguments[1] == "--setsid-normal-exit-fixture" {
            runSetsidChildFixture(
                pidFilePath: CommandLine.arguments[2],
                exitsNormally: true
            )
        }
        if CommandLine.arguments.count == 3,
           CommandLine.arguments[1] == "--late-setsid-child-fixture" {
            runLateSetsidChildFixture(pidFilePath: CommandLine.arguments[2])
        }
        if CommandLine.arguments.count == 3,
           CommandLine.arguments[1] == "--late-session-child-exit-fixture" {
            runLateSessionChildExitFixture(pidFilePath: CommandLine.arguments[2])
        }
        if CommandLine.arguments.count == 3,
           CommandLine.arguments[1] == "--setsid-child-worker",
           let readinessDescriptor = Int32(CommandLine.arguments[2]) {
            runSetsidChildWorker(readinessDescriptor: readinessDescriptor)
        }
        if CommandLine.arguments.count == 3,
           CommandLine.arguments[1] == "--same-session-child-worker",
           let readinessDescriptor = Int32(CommandLine.arguments[2]) {
            runSameSessionChildWorker(readinessDescriptor: readinessDescriptor)
        }

        var failures: [String] = []
        var assertionCount = 0

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertionCount += 1
            if !condition() {
                failures.append(message)
            }
        }

        func processDisappeared(_ pid: pid_t, attempts: Int = 200) -> Bool {
            for _ in 0..<attempts {
                if kill(pid, 0) == -1, errno == ESRCH {
                    return true
                }
                usleep(10_000)
            }
            return false
        }

        let normalLimits = BoundedProcessRunner.Limits(
            timeout: 2,
            terminationGrace: 0.1,
            maximumStandardOutputBytes: 1_024,
            maximumStandardErrorBytes: 1_024
        )

        let normal = BoundedProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'ready'; printf 'diagnostic' >&2"],
            limits: normalLimits
        )
        if case .exited(let status, let output) = normal {
            expect(status == 0, "a normal child exits successfully")
            expect(String(decoding: output.standardOutput, as: UTF8.self) == "ready", "stdout is captured")
            expect(String(decoding: output.standardError, as: UTF8.self) == "diagnostic", "stderr is captured")
            expect(!output.standardOutputWasTruncated, "small stdout is not marked truncated")
            expect(!output.standardErrorWasTruncated, "small stderr is not marked truncated")
        } else {
            expect(false, "a normal child returns an exited outcome")
        }

        let boundedScript = """
        i=0
        while [ "$i" -lt 512 ]; do
          printf '0123456789abcdef'
          printf 'fedcba9876543210' >&2
          i=$((i + 1))
        done
        """
        let bounded = BoundedProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", boundedScript],
            limits: .init(
                timeout: 2,
                terminationGrace: 0.1,
                maximumStandardOutputBytes: 128,
                maximumStandardErrorBytes: 96
            )
        )
        if case .exited(let status, let output) = bounded {
            expect(status == 0, "a verbose child still exits successfully")
            expect(output.standardOutput.count == 128, "stdout is retained only to its exact cap")
            expect(output.standardError.count == 96, "stderr is retained only to its exact cap")
            expect(output.standardOutputWasTruncated, "oversized stdout reports truncation")
            expect(output.standardErrorWasTruncated, "oversized stderr reports truncation")
        } else {
            expect(false, "a verbose child returns an exited outcome")
        }

        let nonzero = BoundedProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'nope' >&2; exit 7"],
            limits: normalLimits
        )
        if case .exited(let status, let output) = nonzero {
            expect(status == 7, "a nonzero exit status remains typed and intact")
            expect(String(decoding: output.standardError, as: UTF8.self) == "nope", "nonzero stderr is retained")
        } else {
            expect(false, "a nonzero child still returns an exited outcome")
        }

        let timeoutStart = Date()
        let timedOut = BoundedProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "exec /bin/sleep 5"],
            limits: .init(
                timeout: 0.15,
                terminationGrace: 0.1,
                maximumStandardOutputBytes: 1_024,
                maximumStandardErrorBytes: 1_024
            )
        )
        expect({ if case .timedOut = timedOut { return true }; return false }(), "a slow child returns timedOut")
        expect(Date().timeIntervalSince(timeoutStart) < 2, "timeout handling returns promptly")

        let resistantStart = Date()
        let termResistant = BoundedProcessRunner.run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "printf '%s\\n' \"$$\"; trap '' TERM; while :; do /bin/sleep 1; done",
            ],
            limits: .init(
                timeout: 0.15,
                terminationGrace: 0.1,
                maximumStandardOutputBytes: 1_024,
                maximumStandardErrorBytes: 1_024
            )
        )
        expect({ if case .timedOut = termResistant { return true }; return false }(), "a TERM-resistant child returns timedOut")
        expect(Date().timeIntervalSince(resistantStart) < 2, "SIGKILL escalation remains bounded")

        if case .timedOut(let output) = termResistant,
           let pidText = String(data: output.standardOutput, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = pid_t(pidText) {
            let expectedIdentity = fixtureProcessIdentity(for: pid)
            var disappeared = false
            for _ in 0..<100 {
                if kill(pid, 0) == -1, errno == ESRCH {
                    disappeared = true
                    break
                }
                usleep(10_000)
            }
            expect(disappeared, "SIGKILL removes a child that ignores SIGTERM")
            if !disappeared, let expectedIdentity {
                terminateProcessIfStillInSession(expectedIdentity, sessionLeader: pid)
            }
        } else {
            expect(false, "the TERM-resistant fixture reports its pid before timing out")
        }

        // A process-table read can fail independently of signalling the known
        // child. The fallback must still give the session leader a graceful
        // TERM opportunity, then escalate after revalidating its session.
        let enumerationFailure = BoundedProcessRunner
            .runWithUnavailableProcessEnumerationForTesting(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "printf '%s\\n' \"$$\"; trap 'printf term-observed >&2' TERM; while :; do :; done",
                ],
                limits: .init(
                    timeout: 0.15,
                    terminationGrace: 0.15,
                    maximumStandardOutputBytes: 1_024,
                    maximumStandardErrorBytes: 1_024
                )
            )
        expect(
            { if case .timedOut = enumerationFailure { return true }; return false }(),
            "unavailable process enumeration still returns timedOut"
        )
        if case .timedOut(let output) = enumerationFailure,
           let pidText = String(data: output.standardOutput, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = pid_t(pidText) {
            let expectedIdentity = fixtureProcessIdentity(for: pid)
            expect(
                String(decoding: output.standardError, as: UTF8.self).contains("term-observed"),
                "enumeration failure still sends SIGTERM before escalation"
            )
            let disappeared = processDisappeared(pid)
            expect(disappeared, "enumeration failure escalates SIGKILL for the known leader")
            if !disappeared, let expectedIdentity {
                terminateProcessIfStillInSession(expectedIdentity, sessionLeader: pid)
            }
        } else {
            expect(false, "the enumeration-failure fixture reports its leader pid")
        }

        // A shell can leave an independently running helper behind when only
        // the leader PID is terminated. The runner gives every command a
        // private session, repeatedly discovers its members, and escalates the
        // complete session so even a TERM-resistant background child cannot
        // keep running or retain the output pipes after timeout.
        let descendantTimeout = BoundedProcessRunner.run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "trap '' TERM; /bin/sh -c 'trap \"\" TERM; while :; do /bin/sleep 1; done' & worker=$!; printf '%s %s\\n' \"$$\" \"$worker\"; while :; do /bin/sleep 1; done",
            ],
            limits: .init(
                timeout: 0.15,
                terminationGrace: 0.15,
                maximumStandardOutputBytes: 1_024,
                maximumStandardErrorBytes: 1_024
            )
        )
        expect(
            { if case .timedOut = descendantTimeout { return true }; return false }(),
            "a shell with a persistent background child returns timedOut"
        )
        if case .timedOut(let output) = descendantTimeout {
            let processIDs = String(decoding: output.standardOutput, as: UTF8.self)
                .split(whereSeparator: \.isWhitespace)
                .compactMap { pid_t($0) }
            expect(processIDs.count == 2, "the descendant fixture reports both process identifiers")
            let expectedSessionLeader = processIDs.first ?? -1
            let expectedIdentities = Dictionary(
                uniqueKeysWithValues: processIDs.compactMap { processID in
                    fixtureProcessIdentity(for: processID).map { (processID, $0) }
                }
            )
            for processID in processIDs {
                let disappeared = processDisappeared(processID)
                expect(disappeared, "session cleanup removes persistent process \(processID)")
                if !disappeared, let expectedIdentity = expectedIdentities[processID] {
                    terminateProcessIfStillInSession(
                        expectedIdentity,
                        sessionLeader: expectedSessionLeader
                    )
                }
            }
        } else {
            expect(false, "the descendant fixture exposes output for cleanup verification")
        }

        // A direct child may leave the runner's private session with setsid().
        // The fixture records its PID only after that transition is complete;
        // cleanup retains the observed start-time identity across escalation.
        do {
            let pidFileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("finderpath-setsid-\(UUID().uuidString).pids")
            var fixtureIdentities: [FixtureProcessIdentity] = []
            defer {
                for identity in fixtureIdentities
                where !fixtureProcessDisappeared(identity, attempts: 10) {
                    terminateFixtureProcessIfCurrent(identity)
                }
                try? FileManager.default.removeItem(at: pidFileURL)
            }

            let escapedSession = BoundedProcessRunner.run(
                executable: CommandLine.arguments[0],
                arguments: ["--setsid-child-fixture", pidFileURL.path],
                limits: .init(
                    timeout: 0.3,
                    terminationGrace: 0.15,
                    maximumStandardOutputBytes: 1_024,
                    maximumStandardErrorBytes: 1_024
                )
            )
            expect(
                { if case .timedOut = escapedSession { return true }; return false }(),
                "a leader with a setsid child returns timedOut"
            )

            if let record = readFixtureRecord(from: pidFileURL),
               let child = record.child,
               let childSessionID = record.childSessionID {
                fixtureIdentities = record.identities
                expect(
                    childSessionID == child.pid && childSessionID != record.leader.pid,
                    "the controlled child left its parent's session before cleanup"
                )
                expect(
                    fixtureProcessDisappeared(record.leader),
                    "setsid fixture leader is cleaned up"
                )
                expect(
                    fixtureProcessDisappeared(child),
                    "a captured direct child is cleaned after leaving the original session"
                )
            } else {
                expect(false, "the setsid fixture records stable leader and child identities")
            }
        }

        // Ownership observed while the leader is alive must survive a normal
        // leader exit, after which an escaped child is already reparented and
        // can no longer be rediscovered from its former PPID.
        do {
            let pidFileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("finderpath-setsid-normal-\(UUID().uuidString).pids")
            var fixtureIdentities: [FixtureProcessIdentity] = []
            defer {
                for identity in fixtureIdentities
                where !fixtureProcessDisappeared(identity, attempts: 10) {
                    terminateFixtureProcessIfCurrent(identity)
                }
                try? FileManager.default.removeItem(at: pidFileURL)
            }

            let normalSetsidExit = BoundedProcessRunner.run(
                executable: CommandLine.arguments[0],
                arguments: ["--setsid-normal-exit-fixture", pidFileURL.path],
                limits: .init(
                    timeout: 2,
                    terminationGrace: 0.15,
                    maximumStandardOutputBytes: 1_024,
                    maximumStandardErrorBytes: 1_024
                )
            )
            if case .exited(let status, _) = normalSetsidExit {
                expect(status == 0, "the setsid fixture leader exits normally")
            } else {
                expect(false, "normal-exit setsid cleanup preserves an exited outcome")
            }

            if let record = readFixtureRecord(from: pidFileURL),
               let child = record.child,
               let childSessionID = record.childSessionID {
                fixtureIdentities = record.identities
                expect(
                    childSessionID == child.pid,
                    "the normal-exit fixture child created its own session"
                )
                expect(
                    fixtureProcessDisappeared(child),
                    "a previously observed setsid child is cleaned after normal leader exit"
                )
            } else {
                expect(false, "the normal-exit fixture records stable process identities")
            }
        }

        // This parent creates its escaped direct child only after receiving
        // SIGTERM. The child therefore has to be found by a grace-period or
        // final rescan rather than the initial timeout snapshot.
        do {
            let pidFileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("finderpath-late-setsid-\(UUID().uuidString).pids")
            var fixtureIdentities: [FixtureProcessIdentity] = []
            defer {
                for identity in fixtureIdentities
                where !fixtureProcessDisappeared(identity, attempts: 10) {
                    terminateFixtureProcessIfCurrent(identity)
                }
                try? FileManager.default.removeItem(at: pidFileURL)
            }

            let lateSetsidChild = BoundedProcessRunner.run(
                executable: CommandLine.arguments[0],
                arguments: ["--late-setsid-child-fixture", pidFileURL.path],
                limits: .init(
                    timeout: 0.2,
                    terminationGrace: 0.3,
                    maximumStandardOutputBytes: 1_024,
                    maximumStandardErrorBytes: 1_024
                )
            )
            expect(
                { if case .timedOut = lateSetsidChild { return true }; return false }(),
                "the TERM-triggered setsid fixture returns timedOut"
            )
            if let record = readFixtureRecord(from: pidFileURL) {
                fixtureIdentities = record.identities
                if let child = record.child,
                   let childSessionID = record.childSessionID {
                    expect(
                        childSessionID == child.pid,
                        "the late child left the original session after SIGTERM"
                    )
                    expect(
                        fixtureProcessDisappeared(child),
                        "grace-period discovery cleans the TERM-triggered setsid child"
                    )
                } else {
                    expect(false, "the TERM-triggered fixture records its escaped child")
                }
            } else {
                expect(false, "the TERM-triggered fixture records stable process identities")
            }
        }

        // A TERM handler can create a child in the original session and then
        // let the leader exit immediately. Session snapshots must continue
        // after that exit and run once more before the grace loop returns.
        do {
            let pidFileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("finderpath-late-session-\(UUID().uuidString).pids")
            var cleanupRecord: FixtureRecord?
            defer {
                if let record = cleanupRecord {
                    if !fixtureProcessDisappeared(record.leader, attempts: 10) {
                        terminateFixtureProcessIfCurrent(
                            record.leader,
                            sessionLeader: record.leader.pid
                        )
                    }
                    if let child = record.child,
                       let childSessionID = record.childSessionID,
                       !fixtureProcessDisappeared(child, attempts: 10) {
                        terminateFixtureProcessIfCurrent(
                            child,
                            sessionLeader: childSessionID
                        )
                    }
                }
                try? FileManager.default.removeItem(at: pidFileURL)
            }

            let lateSessionChild = BoundedProcessRunner.run(
                executable: CommandLine.arguments[0],
                arguments: ["--late-session-child-exit-fixture", pidFileURL.path],
                limits: .init(
                    timeout: 0.2,
                    terminationGrace: 0.3,
                    maximumStandardOutputBytes: 1_024,
                    maximumStandardErrorBytes: 1_024
                )
            )
            expect(
                { if case .timedOut = lateSessionChild { return true }; return false }(),
                "the TERM-spawn-and-exit fixture returns timedOut"
            )
            if let record = readFixtureRecord(from: pidFileURL) {
                cleanupRecord = record
                if let child = record.child,
                   let childSessionID = record.childSessionID {
                    expect(
                        childSessionID == record.leader.pid,
                        "the TERM-triggered child remains in the original session"
                    )
                    expect(
                        fixtureProcessDisappeared(child),
                        "post-leader-exit session discovery cleans the late child"
                    )
                } else {
                    expect(false, "the TERM-spawn-and-exit fixture records its child")
                }
            } else {
                expect(false, "the TERM-spawn-and-exit fixture records stable identities")
            }
        }

        // The final signal predicate must reject a PID whose captured start
        // identity differs from the live process, even when the numeric PID is
        // still valid.
        if let currentIdentity = fixtureProcessIdentity(for: getpid()) {
            expect(
                BoundedProcessRunner.wouldSignalCapturedProcessForTesting(
                    pid: currentIdentity.pid,
                    capturedStartSeconds: currentIdentity.startSeconds,
                    capturedStartMicroseconds: currentIdentity.startMicroseconds,
                    ledBy: getsid(0),
                    requiresOriginalSession: false
                ),
                "an exact captured process identity remains eligible for signalling"
            )
            expect(
                !BoundedProcessRunner.wouldSignalCapturedProcessForTesting(
                    pid: currentIdentity.pid,
                    capturedStartSeconds: currentIdentity.startSeconds,
                    capturedStartMicroseconds: currentIdentity.startMicroseconds ^ 1,
                    ledBy: getsid(0),
                    requiresOriginalSession: false
                ),
                "a changed process start identity is never eligible for signalling"
            )
        } else {
            expect(false, "the identity-guard fixture reads its own stable start time")
        }

        let daemonizingCommand = BoundedProcessRunner.run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "/bin/sh -c 'trap \"\" TERM; while :; do /bin/sleep 1; done' & worker=$!; printf '%s %s\\n' \"$$\" \"$worker\"; exit 0",
            ],
            limits: .init(
                timeout: 1,
                terminationGrace: 0.1,
                maximumStandardOutputBytes: 1_024,
                maximumStandardErrorBytes: 1_024
            )
        )
        if case .exited(let status, let output) = daemonizingCommand {
            let processIDs = String(decoding: output.standardOutput, as: UTF8.self)
                .split(whereSeparator: \.isWhitespace)
                .compactMap { pid_t($0) }
            expect(status == 0, "a leader that exits normally preserves its successful status")
            expect(processIDs.count == 2, "the daemonizing fixture reports leader and child pids")
            if processIDs.count == 2 {
                let leaderPID = processIDs[0]
                let childPID = processIDs[1]
                let expectedIdentity = fixtureProcessIdentity(for: childPID)
                let disappeared = processDisappeared(childPID)
                expect(disappeared, "normal leader exit still cleans up its daemonized session child")
                if !disappeared, let expectedIdentity {
                    terminateProcessIfStillInSession(
                        expectedIdentity,
                        sessionLeader: leaderPID
                    )
                }
            }
        } else {
            expect(false, "the daemonizing fixture returns an exited outcome")
        }

        let missing = BoundedProcessRunner.run(
            executable: "/finderpath/tests/definitely-missing",
            limits: normalLimits
        )
        expect(
            { if case .executableNotFound = missing { return true }; return false }(),
            "a missing executable has its own typed outcome"
        )

        if failures.isEmpty {
            print("BoundedProcessRunnerTests passed (\(assertionCount) assertions)")
            return
        }

        for failure in failures {
            fputs("FAIL: \(failure)\n", stderr)
        }
        exit(EXIT_FAILURE)
    }

    private struct FixtureProcessIdentity: Equatable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    private struct FixtureRecord {
        let leader: FixtureProcessIdentity
        let child: FixtureProcessIdentity?
        let childSessionID: pid_t?

        var identities: [FixtureProcessIdentity] {
            [leader] + (child.map { [$0] } ?? [])
        }
    }

    /// Runs only in a subprocess started by the tests above. A readiness pipe
    /// ensures the PID file is written after the direct child has successfully
    /// created its own session, so setup does not depend on sleeps.
    private static func runSetsidChildFixture(
        pidFilePath: String,
        exitsNormally: Bool
    ) -> Never {
        signal(SIGTERM, SIG_IGN)

        var readinessDescriptors: [Int32] = [0, 0]
        guard pipe(&readinessDescriptors) == 0 else { _exit(70) }
        let childPID = spawnFixtureWorker(
            readinessDescriptor: readinessDescriptors[1],
            createsSession: true
        )
        guard childPID > 1 else { _exit(71) }

        close(readinessDescriptors[1])
        var readiness: UInt8 = 0
        var readResult: Int
        repeat {
            readResult = withUnsafeMutablePointer(to: &readiness) {
                read(readinessDescriptors[0], $0, 1)
            }
        } while readResult == -1 && errno == EINTR
        close(readinessDescriptors[0])
        guard readResult == 1, readiness == 1 else {
            failSetsidFixture(childPID: childPID, status: 73)
        }
        guard writeFixtureRecord(pidFilePath: pidFilePath, childPID: childPID) else {
            failSetsidFixture(childPID: childPID, status: 74)
        }

        if exitsNormally {
            // The runner polls ownership much more frequently than this hold;
            // keeping the direct relationship observable makes the fixture
            // deterministic without a mutable production hook.
            usleep(250_000)
            _exit(0)
        }

        while true { pause() }
    }

    /// Blocks SIGTERM and creates the escaped child only after consuming that
    /// signal. This deterministically exercises grace-period rediscovery.
    private static func runLateSetsidChildFixture(pidFilePath: String) -> Never {
        var termSet = sigset_t()
        sigemptyset(&termSet)
        sigaddset(&termSet, SIGTERM)
        guard pthread_sigmask(SIG_BLOCK, &termSet, nil) == 0 else { _exit(77) }
        guard writeFixtureRecord(pidFilePath: pidFilePath, childPID: nil) else { _exit(78) }

        var receivedSignal: Int32 = 0
        guard sigwait(&termSet, &receivedSignal) == 0, receivedSignal == SIGTERM else {
            _exit(79)
        }

        var readinessDescriptors: [Int32] = [0, 0]
        guard pipe(&readinessDescriptors) == 0 else { _exit(80) }
        let childPID = spawnFixtureWorker(
            readinessDescriptor: readinessDescriptors[1],
            createsSession: true
        )
        guard childPID > 1 else { _exit(81) }

        close(readinessDescriptors[1])
        var readiness: UInt8 = 0
        var readResult: Int
        repeat {
            readResult = withUnsafeMutablePointer(to: &readiness) {
                read(readinessDescriptors[0], $0, 1)
            }
        } while readResult == -1 && errno == EINTR
        close(readinessDescriptors[0])
        guard readResult == 1, readiness == 1 else {
            failSetsidFixture(childPID: childPID, status: 82)
        }
        guard writeFixtureRecord(pidFilePath: pidFilePath, childPID: childPID) else {
            failSetsidFixture(childPID: childPID, status: 83)
        }

        while true { pause() }
    }

    private static func runLateSessionChildExitFixture(pidFilePath: String) -> Never {
        var termSet = sigset_t()
        sigemptyset(&termSet)
        sigaddset(&termSet, SIGTERM)
        guard pthread_sigmask(SIG_BLOCK, &termSet, nil) == 0 else { _exit(84) }
        guard writeFixtureRecord(pidFilePath: pidFilePath, childPID: nil) else { _exit(85) }

        var receivedSignal: Int32 = 0
        guard sigwait(&termSet, &receivedSignal) == 0, receivedSignal == SIGTERM else {
            _exit(86)
        }

        var readinessDescriptors: [Int32] = [0, 0]
        guard pipe(&readinessDescriptors) == 0 else { _exit(87) }
        let childPID = spawnFixtureWorker(
            readinessDescriptor: readinessDescriptors[1],
            createsSession: false
        )
        guard childPID > 1 else { _exit(88) }

        close(readinessDescriptors[1])
        var readiness: UInt8 = 0
        var readResult: Int
        repeat {
            readResult = withUnsafeMutablePointer(to: &readiness) {
                read(readinessDescriptors[0], $0, 1)
            }
        } while readResult == -1 && errno == EINTR
        close(readinessDescriptors[0])
        guard readResult == 1, readiness == 1 else {
            failSetsidFixture(childPID: childPID, status: 89)
        }
        guard writeFixtureRecord(pidFilePath: pidFilePath, childPID: childPID) else {
            failSetsidFixture(childPID: childPID, status: 90)
        }

        _exit(0)
    }

    /// Once spawned, the worker remains this fixture's unreaped direct child.
    /// Killing then waitpid'ing it is immune to numeric PID reuse and is used on
    /// every post-spawn setup failure.
    private static func failSetsidFixture(childPID: pid_t, status: Int32) -> Never {
        if childPID > 1 {
            kill(childPID, SIGKILL)
            var waitStatus: Int32 = 0
            var waitResult: pid_t
            repeat {
                waitResult = waitpid(childPID, &waitStatus, 0)
            } while waitResult == -1 && errno == EINTR
        }
        _exit(status)
    }

    private static func writeFixtureRecord(
        pidFilePath: String,
        childPID: pid_t?
    ) -> Bool {
        guard let leader = fixtureProcessIdentity(for: getpid()) else { return false }
        let child = childPID.flatMap(fixtureProcessIdentity(for:))
        if childPID != nil, child == nil { return false }

        let record = [
            String(leader.pid),
            String(leader.startSeconds),
            String(leader.startMicroseconds),
            String(child?.pid ?? 0),
            String(child?.startSeconds ?? 0),
            String(child?.startMicroseconds ?? 0),
            String(child.map { getsid($0.pid) } ?? 0),
        ].joined(separator: " ") + "\n"
        let descriptor = open(
            pidFilePath,
            O_WRONLY | O_CREAT | O_TRUNC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        return Array(record.utf8).withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            var totalWritten = 0
            while totalWritten < buffer.count {
                let result = write(
                    descriptor,
                    baseAddress.advanced(by: totalWritten),
                    buffer.count - totalWritten
                )
                if result == -1, errno == EINTR { continue }
                guard result > 0 else { return false }
                totalWritten += result
            }
            return true
        }
    }

    private static func readFixtureRecord(from url: URL) -> FixtureRecord? {
        guard let values = try? String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace),
              values.count == 7,
              let leaderPID = pid_t(values[0]),
              let leaderSeconds = UInt64(values[1]),
              let leaderMicroseconds = UInt64(values[2]),
              let childPID = pid_t(values[3]),
              let childSeconds = UInt64(values[4]),
              let childMicroseconds = UInt64(values[5]),
              let childSessionID = pid_t(values[6]) else { return nil }

        let leader = FixtureProcessIdentity(
            pid: leaderPID,
            startSeconds: leaderSeconds,
            startMicroseconds: leaderMicroseconds
        )
        guard childPID > 1 else {
            return FixtureRecord(leader: leader, child: nil, childSessionID: nil)
        }
        return FixtureRecord(
            leader: leader,
            child: FixtureProcessIdentity(
                pid: childPID,
                startSeconds: childSeconds,
                startMicroseconds: childMicroseconds
            ),
            childSessionID: childSessionID
        )
    }

    private static func fixtureProcessIdentity(for pid: pid_t) -> FixtureProcessIdentity? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let copiedSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
        guard copiedSize == expectedSize, pid_t(info.pbi_pid) == pid else { return nil }
        return FixtureProcessIdentity(
            pid: pid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec
        )
    }

    private static func fixtureProcessDisappeared(
        _ identity: FixtureProcessIdentity,
        attempts: Int = 200
    ) -> Bool {
        for _ in 0..<attempts {
            if fixtureProcessIdentity(for: identity.pid) != identity {
                return true
            }
            usleep(10_000)
        }
        return false
    }

    /// Best-effort cleanup for shell fixtures that report only numeric PIDs.
    /// The caller captures start identity before polling. Revalidate that exact
    /// identity and the runner-owned session immediately around SIGKILL so a
    /// recycled unrelated PID is not targeted.
    private static func terminateProcessIfStillInSession(
        _ expectedIdentity: FixtureProcessIdentity,
        sessionLeader: pid_t
    ) {
        guard expectedIdentity.pid > 1,
              sessionLeader > 1,
              getsid(expectedIdentity.pid) == sessionLeader,
              fixtureProcessIdentity(for: expectedIdentity.pid) == expectedIdentity,
              getsid(expectedIdentity.pid) == sessionLeader else { return }
        kill(expectedIdentity.pid, SIGKILL)
    }

    private static func terminateFixtureProcessIfCurrent(
        _ identity: FixtureProcessIdentity,
        sessionLeader: pid_t? = nil
    ) {
        let expectedSessionLeader = sessionLeader ?? identity.pid
        guard fixtureProcessIdentity(for: identity.pid) == identity,
              getsid(identity.pid) == expectedSessionLeader else { return }
        kill(identity.pid, SIGKILL)
    }

    private static func spawnFixtureWorker(
        readinessDescriptor: Int32,
        createsSession: Bool
    ) -> pid_t {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return -1 }
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = createsSession ? Int16(POSIX_SPAWN_SETSID) : 0
        guard posix_spawnattr_setflags(&attributes, flags) == 0 else {
            return -1
        }

        let executable = CommandLine.arguments[0]
        let argv = [
            strdup(executable),
            strdup(createsSession ? "--setsid-child-worker" : "--same-session-child-worker"),
            strdup(String(readinessDescriptor)),
            nil,
        ]
        var environment = ProcessInfo.processInfo.environment.map {
            strdup("\($0.key)=\($0.value)")
        }
        environment.append(nil)
        defer {
            argv.forEach { free($0) }
            environment.forEach { free($0) }
        }

        var childPID: pid_t = -1
        let result = posix_spawn(
            &childPID,
            executable,
            nil,
            &attributes,
            argv,
            environment
        )
        return result == 0 ? childPID : -1
    }

    private static func runSetsidChildWorker(readinessDescriptor: Int32) -> Never {
        signal(SIGTERM, SIG_IGN)
        var readiness: UInt8 = getsid(0) == getpid() ? 1 : 0
        _ = withUnsafePointer(to: &readiness) {
            write(readinessDescriptor, $0, 1)
        }
        close(readinessDescriptor)
        guard readiness == 1 else { _exit(76) }
        while true { pause() }
    }

    private static func runSameSessionChildWorker(readinessDescriptor: Int32) -> Never {
        signal(SIGTERM, SIG_IGN)
        var readiness: UInt8 = getsid(0) > 1 && getsid(0) != getpid() ? 1 : 0
        _ = withUnsafePointer(to: &readiness) {
            write(readinessDescriptor, $0, 1)
        }
        close(readinessDescriptor)
        guard readiness == 1 else { _exit(91) }
        while true { pause() }
    }
}
