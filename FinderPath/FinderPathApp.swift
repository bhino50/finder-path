import SwiftUI
import AppKit

@main
struct FinderPathApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var welcomeWindowController: WelcomeWindowController?
    private let actionRouter = FinderPathActionRouter()
    /// Holds URLs that AppKit delivers before `applicationDidFinishLaunching`
    /// has registered preference defaults and wired up `actionRouter`.
    private var pendingURLs = PendingURLQueue()
    private var isYieldingToExistingInstance = false
    private var forwardingApplicationURL: URL?
    private var forwardingApplication: NSRunningApplication?
    private var handoffURLs: [URL] = []
    private var handoffInFlight = false
    private var handoffGeneration = 0
    private var handoffTimeoutTask: Task<Void, Never>?
    private var handoffIdleExitTask: Task<Void, Never>?
    private var didCompleteLaunchSetup = false

    private static let handoffTimeoutNanoseconds: UInt64 = 5_000_000_000
    private static let handoffQuiescenceNanoseconds: UInt64 = 250_000_000

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launch Services normally reuses a running app, but development builds,
        // `open -n`, or stale FinderPathDev bundles can still start a second
        // process. Refuse every FinderPath-owned bundle before it creates another
        // status item or races the shared terminal-session metadata file.
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentIdentity = FinderPathInstanceIdentity.current(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            observedLaunchDate: NSRunningApplication.current.launchDate,
            processIdentifier: currentPID
        )
        let existingApplications = NSWorkspace.shared.runningApplications.filter { application in
            guard application.processIdentifier != currentPID else { return false }
            // Process names are not identities: never terminate an unrelated
            // app merely because its executable is also named FinderPath.
            return FinderPathInstanceIdentity.knownBundleIdentifiers.contains(
                application.bundleIdentifier ?? ""
            )
        }

        let rankedExistingApplications = existingApplications.map { application in
            (
                application: application,
                identity: FinderPathInstanceIdentity(
                    bundleIdentifier: application.bundleIdentifier,
                    launchDate: application.launchDate,
                    processIdentifier: application.processIdentifier
                )
            )
        }

        // Every contender computes the same winner: the already-running app
        // wins, then release identity and PID break an exact launch-time tie.
        // This prevents two simultaneous launches from both yielding or both
        // creating a status item, including a release launched after FinderPathDev.
        if let winner = rankedExistingApplications.min(by: {
            FinderPathInstanceIdentity.isPreferred($0.identity, over: $1.identity)
        }), FinderPathInstanceIdentity.isPreferred(winner.identity, over: currentIdentity) {
            // Launch Services can route a custom URL to a stale copy even when
            // the winning FinderPath instance is already running. Forward every
            // early URL before yielding so the user's action is handled exactly
            // once by the elected instance instead of dying with this process.
            let earlyURLs = pendingURLs.drain()
            let winnerURL = winner.application.bundleURL
                ?? winner.application.bundleIdentifier.flatMap {
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
                }
            if let winnerURL {
                beginHandoff(
                    earlyURLs,
                    to: winner.application,
                    applicationURL: winnerURL
                )
                return
            }

            if earlyURLs.isEmpty {
                winner.application.activate(options: [.activateIgnoringOtherApps])
                NSApp.terminate(nil)
                return
            }

            // An application without a resolvable bundle URL cannot be an
            // exact Launch Services target. Keep this process alive to handle
            // the user's URL instead of silently dropping it while yielding.
            NSLog(
                "FinderPath: could not resolve bundle URL for preferred process %d; retaining URL in this process",
                winner.application.processIdentifier
            )
            finishLaunchingAsWinner(recoveredURLs: earlyURLs)
            return
        }

        finishLaunchingAsWinner()
    }

    private func finishLaunchingAsWinner(recoveredURLs: [URL] = []) {
        guard !didCompleteLaunchSetup else { return }
        didCompleteLaunchSetup = true

        // Do not terminate another contender from the winning process. Each
        // loser owns its pending URL queue and exits itself only after every
        // Launch Services transfer is acknowledged. A winner-side timer cannot
        // know whether a later batch is still in flight and can lose that URL.

        FinderPathPreferences.registerDefaults()
        // Feed shell and scrollback preferences into every session the store
        // creates or restores. Resolved lazily so preference edits during the
        // session take effect on the next new terminal.
        TerminalSessionStore.shared.configurationProvider = {
            let override = FinderPathPreferences.terminalShellOverride.trimmingCharacters(in: .whitespaces)
            let usesOverride = !override.isEmpty && FileManager.default.isExecutableFile(atPath: override)
            return TerminalSessionConfiguration(
                shellPath: usesOverride ? override : PTYProcess.defaultShell(),
                scrollbackLimit: FinderPathPreferences.terminalScrollbackLimit
            )
        }
        // Restore stored terminal sessions (metadata only; shells relaunch
        // lazily) before the menu builds so the Terminals section is complete.
        TerminalSessionStore.shared.loadPersistedSessions()
        RecentPathsStore.shared.load()
        NSApp.setActivationPolicy(.accessory)
        statusItemController = StatusItemController()
        statusItemController?.onOpenWelcomeGuide = { [weak self] in
            self?.showWelcomeGuide()
        }
        if !FinderPathPreferences.completedWelcome {
            showWelcomeGuide()
        }
        actionRouter.onOpenConnectWindow = { [weak self] in
            self?.statusItemController?.openRemoteConnectionWindow()
        }

        // Everything the router depends on now exists, so replay any URL that
        // launched the app. AppKit hands the launch URL to application(_:open:)
        // during finishLaunching — before this method returns — so without this
        // replay a cold-launch finderpath:// action silently does nothing and
        // the user has to trigger it a second time.
        let launchURLs = pendingURLs.drain() + recoveredURLs
        for url in launchURLs.prefix(PendingURLQueue.capacity) {
            actionRouter.handle(url: url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        handoffTimeoutTask?.cancel()
        handoffIdleExitTask?.cancel()
        // Shells do not outlive the app; session metadata stays persisted.
        TerminalSessionStore.shared.terminateAll()
    }

    private func beginHandoff(
        _ urls: [URL],
        to application: NSRunningApplication,
        applicationURL: URL
    ) {
        isYieldingToExistingInstance = true
        forwardingApplication = application
        forwardingApplicationURL = applicationURL
        enqueueHandoffURLs(urls)
        application.activate(options: [.activateIgnoringOtherApps])
        startNextHandoffBatch()
    }

    private func enqueueHandoffURLs(_ urls: [URL]) {
        handoffIdleExitTask?.cancel()
        handoffIdleExitTask = nil
        let remainingCapacity = max(0, PendingURLQueue.capacity - handoffURLs.count)
        guard remainingCapacity > 0 else { return }
        handoffURLs.append(contentsOf: urls.prefix(remainingCapacity))
    }

    private func startNextHandoffBatch() {
        guard isYieldingToExistingInstance, !handoffInFlight else { return }
        guard !handoffURLs.isEmpty else {
            scheduleHandoffExitAfterQuiescence()
            return
        }
        guard let forwardingApplicationURL else {
            recoverFailedHandoff([], reason: "the elected application URL became unavailable")
            return
        }

        let batch = handoffURLs
        handoffURLs.removeAll(keepingCapacity: true)
        handoffInFlight = true
        handoffGeneration &+= 1
        let generation = handoffGeneration

        handoffTimeoutTask?.cancel()
        handoffTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.handoffTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            self?.completeHandoff(
                batch,
                generation: generation,
                failure: "Launch Services did not acknowledge the URL transfer within five seconds"
            )
        }

        guard let expectedProcessIdentifier = forwardingApplication?.processIdentifier else {
            recoverFailedHandoff(batch, reason: "the elected application process became unavailable")
            return
        }

        forwardToWinningInstance(
            batch,
            applicationURL: forwardingApplicationURL,
            expectedProcessIdentifier: expectedProcessIdentifier
        ) { [weak self] failure in
            self?.completeHandoff(batch, generation: generation, failure: failure)
        }
    }

    private func scheduleHandoffExitAfterQuiescence() {
        guard handoffIdleExitTask == nil else { return }
        handoffIdleExitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.handoffQuiescenceNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.handoffIdleExitTask = nil
            guard self.isYieldingToExistingInstance,
                  !self.handoffInFlight,
                  self.handoffURLs.isEmpty else {
                self.startNextHandoffBatch()
                return
            }
            self.forwardingApplication?.activate(options: [.activateIgnoringOtherApps])
            NSApp.terminate(nil)
        }
    }

    private func completeHandoff(_ batch: [URL], generation: Int, failure: String?) {
        guard isYieldingToExistingInstance,
              handoffInFlight,
              generation == handoffGeneration else { return }

        handoffTimeoutTask?.cancel()
        handoffTimeoutTask = nil
        handoffIdleExitTask?.cancel()
        handoffIdleExitTask = nil
        handoffInFlight = false

        if let failure {
            recoverFailedHandoff(batch, reason: failure)
        } else {
            // URLs can arrive while the first asynchronous open is in flight.
            // Drain every acknowledged batch before the sender exits.
            startNextHandoffBatch()
        }
    }

    private func recoverFailedHandoff(_ failedBatch: [URL], reason: String) {
        let recoveredURLs = Array(
            (failedBatch + handoffURLs).prefix(PendingURLQueue.capacity)
        )
        handoffTimeoutTask?.cancel()
        handoffTimeoutTask = nil
        handoffURLs.removeAll()
        handoffInFlight = false
        isYieldingToExistingInstance = false
        forwardingApplication = nil
        forwardingApplicationURL = nil

        NSLog("FinderPath: URL handoff failed; handling locally: %@", reason)
        // The preferred process is intentionally left alone. If Launch Services
        // cannot acknowledge delivery, preserving the user action is more
        // important than forcing another election from an uncertain state.
        finishLaunchingAsWinner(recoveredURLs: recoveredURLs)
    }

    private func forwardToWinningInstance(
        _ urls: [URL],
        applicationURL: URL,
        expectedProcessIdentifier: pid_t,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        guard !urls.isEmpty else {
            completion(nil)
            return
        }

        // Target the elected app through the ordinary AppKit URL-open path.
        // This is deliberately cross-version: every FinderPath release already
        // implements application(_:open:), whereas a private distributed
        // notification would be ignored by an older elected winner.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.open(
            Array(urls.prefix(PendingURLQueue.capacity)),
            withApplicationAt: applicationURL,
            configuration: configuration
        ) { application, error in
            let failure: String?
            if let error {
                failure = error.localizedDescription
            } else if application == nil {
                failure = "Launch Services returned no receiving application"
            } else if application?.processIdentifier != expectedProcessIdentifier {
                failure = "Launch Services selected a different FinderPath process"
            } else {
                failure = nil
            }
            Task { @MainActor in
                completion(failure)
            }
        }
    }

    /// Single entry point for every `finderpath://` URL, whether it launched
    /// the app or arrived while it was already running.
    ///
    /// This replaces a manual `kAEGetURL` handler that was registered at the
    /// end of `applicationDidFinishLaunching`. AppKit dispatches the launch URL
    /// before that line ran, so the handler was installed microseconds too late
    /// and every URL that started the app was dropped. AppKit's own GetURL
    /// handler is installed early and forwards here, so this sees both cases;
    /// URLs that arrive before the router is wired up are buffered and replayed
    /// at the end of `applicationDidFinishLaunching`.
    func application(_ application: NSApplication, open urls: [URL]) {
        if isYieldingToExistingInstance {
            enqueueHandoffURLs(urls)
            startNextHandoffBatch()
            return
        }
        for url in pendingURLs.accept(urls) {
            actionRouter.handle(url: url)
        }
    }

    func showWelcomeGuide() {
        if welcomeWindowController == nil {
            welcomeWindowController = WelcomeWindowController()
        }
        NSApp.activate(ignoringOtherApps: true)
        welcomeWindowController?.presentOnActiveScreen()
    }
}

@MainActor
final class FinderPathActionRouter {
    var onOpenConnectWindow: (() -> Void)?
    private var launchesInFlight: Set<String> = []
    private var lastLaunchAt: [String: Date] = [:]
    private static let minimumLaunchInterval: TimeInterval = 2

    func handle(url: URL) {
        guard url.scheme?.lowercased() == "finderpath" else { return }

        switch actionName(for: url) {
        case "connect", "connect-to-server":
            onOpenConnectWindow?()
        case "open-ghostty", "ghostty":
            let action = "ghostty"
            guard FinderPathPreferences.allowExternalLaunchURLs,
                  beginExternalLaunch(action) else { return }
            Task { @MainActor in
                let result = await FinderBridge.fetchCurrentPath()
                guard result.failure == nil,
                      !result.path.hasPrefix("Finder AppleScript error:") else {
                    self.finishExternalLaunch(action)
                    self.presentFailure(result.path, displayName: "Ghostty")
                    return
                }
                let validation = await FinderPathDirectoryTarget.validate(result.path)
                guard validation.isAvailable else {
                    self.finishExternalLaunch(action)
                    FinderPathAlertPresenter.presentUnavailableFolder(result.path, validation: validation)
                    return
                }

                TerminalBridge.openGhostty(at: result.path) { error in
                    Task { @MainActor in
                        self.finishExternalLaunch(action)
                        if let error {
                            self.presentFailure(error, displayName: "Ghostty")
                        }
                    }
                }
            }
        case "open-cmux", "cmux":
            let action = "cmux"
            guard FinderPathPreferences.allowExternalLaunchURLs,
                  beginExternalLaunch(action) else { return }
            Task { @MainActor in
                let result = await FinderBridge.fetchCurrentPath()
                guard result.failure == nil,
                      !result.path.hasPrefix("Finder AppleScript error:") else {
                    self.finishExternalLaunch(action)
                    self.presentFailure(result.path, displayName: "cmux")
                    return
                }
                let validation = await FinderPathDirectoryTarget.validate(result.path)
                guard validation.isAvailable else {
                    self.finishExternalLaunch(action)
                    FinderPathAlertPresenter.presentUnavailableFolder(result.path, validation: validation)
                    return
                }

                TerminalBridge.openCmux(at: result.path) { error in
                    Task { @MainActor in
                        self.finishExternalLaunch(action)
                        if let error {
                            self.presentFailure(error, displayName: "cmux")
                        }
                    }
                }
            }
        default:
            break
        }
    }

    private func beginExternalLaunch(_ action: String, now: Date = Date()) -> Bool {
        guard !launchesInFlight.contains(action) else { return false }
        if let previous = lastLaunchAt[action],
           now.timeIntervalSince(previous) < Self.minimumLaunchInterval {
            return false
        }
        launchesInFlight.insert(action)
        lastLaunchAt[action] = now
        return true
    }

    private func finishExternalLaunch(_ action: String) {
        launchesInFlight.remove(action)
    }

    private func actionName(for url: URL) -> String {
        if let host = url.host(percentEncoded: false), !host.isEmpty {
            return host.lowercased()
        }

        return url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    private func presentFailure(_ message: String, displayName: String) {
        FinderPathAlertPresenter.presentLaunchFailure(message, displayName: displayName)
    }
}

@MainActor
enum FinderPathAlertPresenter {
    static func presentLaunchFailure(_ message: String, displayName: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "FinderPath could not open \(displayName)."
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func presentUnavailableFolder(
        _ path: String,
        validation: FinderPathDirectoryTarget.Validation = .unavailable
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch validation {
        case .available:
            return
        case .unavailable:
            alert.messageText = "Folder is no longer available."
            alert.informativeText = "FinderPath could not find this folder:\n\n\(path)\n\nIt may have been moved, renamed, deleted, or disconnected."
        case .timedOut:
            alert.messageText = "Folder is not responding."
            alert.informativeText = "FinderPath stopped waiting for this folder so the app would stay responsive:\n\n\(path)\n\nReconnect the volume and try again."
        case .failed(let detail):
            alert.messageText = "Folder could not be checked."
            alert.informativeText = "FinderPath could not safely verify this folder:\n\n\(path)\n\n\(detail)"
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

@MainActor
final class FinderPathState {
    private var refreshState = FinderPathRefreshState()

    var currentPath: String { refreshState.currentPath }
    var isRefreshing: Bool { refreshState.isRefreshing }

    /// Fetches the Finder path off the main thread and reports back on the
    /// main actor, so a stalled Finder can never beachball the app. Stale
    /// completions from an earlier refresh are dropped.
    func refresh(onChange: (() -> Void)? = nil) {
        let generation = refreshState.begin()
        Task { @MainActor [weak self] in
            let result = await FinderBridge.fetchCurrentPath()
            guard let self, self.refreshState.complete(result, generation: generation) else { return }
            // Only folders that were genuinely open in a Finder window are worth
            // remembering. The desktop substitution would otherwise dominate the
            // history, because opening the menu to reach Settings or a terminal
            // returns it every time.
            if !result.isFallback, self.hasCopyablePath {
                RecentPathsStore.shared.record(result.path)
            }
            onChange?()
        }
    }

    func copyCurrentPath(at path: String? = nil, onSuccess: (() -> Void)? = nil) {
        withResolvedActionTarget(path) { [weak self] target in
            self?.copyToPasteboard(target)
            onSuccess?()
        }
    }

    func copyChangeDirectoryCommand(at path: String? = nil, onSuccess: (() -> Void)? = nil) {
        withResolvedActionTarget(path) { [weak self] target in
            self?.copyToPasteboard(
                "cd \(ShellCommand.argument(target, quoteStyle: FinderPathPreferences.cdQuoteStyle))"
            )
            onSuccess?()
        }
    }

    func openInTerminal(at path: String? = nil) {
        withResolvedActionTarget(path) { [weak self] target in
            TerminalBridge.open(at: target) { error in
                self?.presentLaunchFailure(error, displayName: "Terminal")
            }
        }
    }

    func openInGhostty(at path: String? = nil) {
        withResolvedActionTarget(path) { [weak self] target in
            TerminalBridge.openGhostty(at: target) { error in
                self?.presentLaunchFailure(error, displayName: "Ghostty")
            }
        }
    }

    func openInCmux(at path: String? = nil) {
        withResolvedActionTarget(path) { [weak self] target in
            TerminalBridge.openCmux(at: target) { error in
                self?.presentLaunchFailure(error, displayName: "cmux")
            }
        }
    }

    /// Opens the folder in Finder. Passing nil for the file selects nothing and
    /// simply reveals the folder itself.
    func revealInFinder(at path: String? = nil) {
        withResolvedActionTarget(path) { target in
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: target)
        }
    }

    /// One launcher for all three agents: the three previous methods differed
    /// only in which preference they read and which name they reported.
    func openWithAgent(named name: String, executable: String, at path: String? = nil) {
        withResolvedActionTarget(path) { [weak self] target in
            let resolvedExecutable = AgentLauncher.availability(for: executable).resolvedPath ?? executable

            TerminalBridge.openAgent(
                displayName: name,
                executable: resolvedExecutable,
                at: target
            ) { error in
                self?.presentLaunchFailure(error, displayName: name)
            }
        }
    }

    func checkForUpdates(userInitiated: Bool) {
        let currentVersion = AppVersion.current
        UpdateChecker.check(manifestURL: FinderPathPreferences.updateManifestURL) { result in
            Task { @MainActor in
                UpdatePrompt.present(
                    result: result,
                    currentVersion: currentVersion,
                    userInitiated: userInitiated
                )
            }
        }
    }

    var hasCopyablePath: Bool {
        refreshState.result?.failure == nil
            && !currentPath.isEmpty
            && !currentPath.hasPrefix("Finder AppleScript error:")
    }

    /// Recent-path rows pass an explicit folder; every other caller acts on the
    /// live Finder path. A nil argument therefore means "whatever Finder is
    /// showing", and yields nil when there is nothing usable to act on.
    func actionTargetCandidate(_ path: String? = nil) -> String? {
        let target: String?
        if let path, !path.isEmpty {
            target = path
        } else {
            target = hasCopyablePath ? currentPath : nil
        }
        return target
    }

    /// Resolves and validates a path without allowing a disconnected network
    /// mount to block the main actor. Every action reaches its external surface
    /// only after the bounded validation completes successfully.
    func withResolvedActionTarget(
        _ path: String? = nil,
        perform action: @escaping (String) -> Void
    ) {
        Task { @MainActor in
            guard let target = await validatedActionTarget(path) else { return }
            guard !Task.isCancelled else { return }
            action(target)
        }
    }

    func validatedActionTarget(_ path: String? = nil) async -> String? {
        guard let target = actionTargetCandidate(path) else { return nil }
        guard !Task.isCancelled else { return nil }
        let validation = await FinderPathDirectoryTarget.validate(target)
        // Cancellation is a user intent boundary: a panel dismissed while a
        // network mount is being checked must not surface a stale alert or
        // persist a session after that bounded check eventually completes.
        guard !Task.isCancelled else { return nil }
        guard validation.isAvailable else {
            FinderPathAlertPresenter.presentUnavailableFolder(target, validation: validation)
            return nil
        }
        return target
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func presentLaunchFailure(_ message: String?, displayName: String) {
        guard let message else { return }

        Task { @MainActor in
            FinderPathAlertPresenter.presentLaunchFailure(message, displayName: displayName)
        }
    }
}
