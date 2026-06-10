import SwiftUI
import AppKit
import ServiceManagement

@MainActor
final class SettingsWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "FinderPath Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = NSHostingController(rootView: SettingsView())

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

struct SettingsView: View {
    @AppStorage(FinderPathPreferences.showPathHeaderKey) private var showPathHeader = true
    @AppStorage(FinderPathPreferences.showRefreshItemKey) private var showRefreshItem = true
    @AppStorage(FinderPathPreferences.showCopyPathItemKey) private var showCopyPathItem = true
    @AppStorage(FinderPathPreferences.showCopyCDItemKey) private var showCopyCDItem = true
    @AppStorage(FinderPathPreferences.showOpenTerminalItemKey) private var showOpenTerminalItem = true
    @AppStorage(FinderPathPreferences.showOpenGhosttyItemKey) private var showOpenGhosttyItem = true
    @AppStorage(FinderPathPreferences.showOpenWithCodexItemKey) private var showOpenWithCodexItem = true
    @AppStorage(FinderPathPreferences.showOpenWithClaudeItemKey) private var showOpenWithClaudeItem = true
    @AppStorage(FinderPathPreferences.showOpenWithHermesItemKey) private var showOpenWithHermesItem = true
    @AppStorage(FinderPathPreferences.showOpenCmuxItemKey) private var showOpenCmuxItem = true
    @AppStorage(FinderPathPreferences.showConnectToServerItemKey) private var showConnectToServerItem = true
    @AppStorage(FinderPathPreferences.showCheckForUpdatesItemKey) private var showCheckForUpdatesItem = true
    @AppStorage(FinderPathPreferences.showQuitItemKey) private var showQuitItem = true
    @AppStorage(FinderPathPreferences.pathDisplayStyleKey) private var pathDisplayStyle = "full"
    @AppStorage(FinderPathPreferences.menuHeaderTitleKey) private var menuHeaderTitle = "Current Finder Path"
    @AppStorage(FinderPathPreferences.menuHeaderWidthKey) private var menuHeaderWidth = 380.0
    @AppStorage(FinderPathPreferences.pathLineBreakKey) private var pathLineBreak = "middle"
    @AppStorage(FinderPathPreferences.pathFontSizeKey) private var pathFontSize = 12.0
    @AppStorage(FinderPathPreferences.statusIconKey) private var statusIcon = "folder"
    @AppStorage(FinderPathPreferences.showStatusTitleKey) private var showStatusTitle = false
    @AppStorage(FinderPathPreferences.statusTitleKey) private var statusTitle = "FP"
    @AppStorage(FinderPathPreferences.cdQuoteStyleKey) private var cdQuoteStyle = "double"
    @AppStorage(FinderPathPreferences.remoteConnectionTerminalKey) private var remoteConnectionTerminal = "ghostty"
    @AppStorage(FinderPathPreferences.codexExecutableKey) private var codexExecutable = "codex"
    @AppStorage(FinderPathPreferences.claudeExecutableKey) private var claudeExecutable = "claude"
    @AppStorage(FinderPathPreferences.hermesExecutableKey) private var hermesExecutable = "hermes"
    @AppStorage(FinderPathPreferences.hideUnavailableAgentItemsKey) private var hideUnavailableAgentItems = true
    @AppStorage(FinderPathPreferences.updateManifestURLKey) private var updateManifestURL = FinderPathPreferences.defaultUpdateManifestURL
    @State private var codexAvailability = AgentAvailability.unknown(executable: "codex")
    @State private var claudeAvailability = AgentAvailability.unknown(executable: "claude")
    @State private var hermesAvailability = AgentAvailability.unknown(executable: "hermes")
    @State private var isCheckingForUpdates = false
    @State private var agentAvailabilityCheckTask: Task<Void, Never>?
    @State private var launchAtLogin = false
    @State private var launchAtLoginError: String?

    // Wait for a pause in typing before probing the shell so editing the
    // executable fields does not spawn a zsh process per keystroke.
    private static let agentCheckDebounceNanoseconds: UInt64 = 300_000_000

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch FinderPath at login", isOn: $launchAtLogin)

                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Menu Items") {
                Toggle("Show current path header", isOn: $showPathHeader)
                Toggle("Show Refresh", isOn: $showRefreshItem)
                Toggle("Show Copy Path", isOn: $showCopyPathItem)
                Toggle("Show Copy cd Command", isOn: $showCopyCDItem)
                Toggle("Show Open in cmux", isOn: $showOpenCmuxItem)
                Toggle("Show Open in Ghostty", isOn: $showOpenGhosttyItem)
                Toggle("Show Open in Terminal", isOn: $showOpenTerminalItem)
                Toggle("Show Open with Codex", isOn: $showOpenWithCodexItem)
                Toggle("Show Open with Claude", isOn: $showOpenWithClaudeItem)
                Toggle("Show Open with Hermes", isOn: $showOpenWithHermesItem)
                Toggle("Show Connect to Server", isOn: $showConnectToServerItem)
                Toggle("Show Check for Updates", isOn: $showCheckForUpdatesItem)
                Toggle("Show Quit", isOn: $showQuitItem)
            }

            Section("Path Header") {
                TextField("Header title", text: $menuHeaderTitle)

                Picker("Path display", selection: $pathDisplayStyle) {
                    Text("Full").tag("full")
                    Text("Home as ~").tag("home")
                    Text("Compact").tag("compact")
                }
                .pickerStyle(.segmented)

                Picker("Long path truncation", selection: $pathLineBreak) {
                    Text("Start").tag("head")
                    Text("Middle").tag("middle")
                    Text("End").tag("tail")
                }
                .pickerStyle(.segmented)

                LabeledContent("Header width") {
                    HStack {
                        Slider(value: $menuHeaderWidth, in: 300...560, step: 20)
                        Text("\(Int(menuHeaderWidth)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 54, alignment: .trailing)
                    }
                }

                LabeledContent("Path font size") {
                    HStack {
                        Slider(value: $pathFontSize, in: 10...15, step: 1)
                        Text("\(Int(pathFontSize)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section("Menu Bar Icon") {
                Picker("Icon", selection: $statusIcon) {
                    Label("Folder", systemImage: "folder").tag("folder")
                    Label("Folder Badge", systemImage: "folder.badge.gearshape").tag("folder.badge.gearshape")
                    Label("Terminal", systemImage: "terminal").tag("terminal")
                    Label("Path", systemImage: "point.topleft.down.curvedto.point.bottomright.up").tag("point.topleft.down.curvedto.point.bottomright.up")
                }
                .pickerStyle(.menu)

                Toggle("Show short title", isOn: $showStatusTitle)

                if showStatusTitle {
                    TextField("Short title", text: $statusTitle)
                }
            }

            Section("Terminal") {
                Picker("cd quoting", selection: $cdQuoteStyle) {
                    Text("Double quotes").tag("double")
                    Text("Single quotes").tag("single")
                }
                .pickerStyle(.segmented)
            }

            Section("Remote Connections") {
                Picker("Run SSH connections in", selection: $remoteConnectionTerminal) {
                    Text("Ghostty").tag("ghostty")
                    Text("macOS Terminal").tag("terminal")
                }
                .pickerStyle(.segmented)

                Text("Add servers and connect from the \"Connect to Server\" window (menu bar → Connect to Server…). Your Tailscale devices appear there automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Agent Launchers") {
                TextField("Codex command or path", text: $codexExecutable)
                TextField("Claude command or path", text: $claudeExecutable)
                TextField("Hermes command or path", text: $hermesExecutable)
                Toggle("Hide unavailable agent actions", isOn: $hideUnavailableAgentItems)

                AgentStatusRow(name: "Codex", availability: codexAvailability)
                AgentStatusRow(name: "Claude", availability: claudeAvailability)
                AgentStatusRow(name: "Hermes", availability: hermesAvailability)

                HStack {
                    Button("Check Again") { scheduleAgentAvailabilityCheck() }
                    Spacer()
                }

                Text("Codex, Claude, and Hermes are optional. If a CLI is not installed, FinderPath can hide that menu action. Use a full executable path if your command is installed outside the normal shell PATH.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                LabeledContent("Installed version", value: AppVersion.current)

                TextField("Update manifest URL", text: $updateManifestURL)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button(isCheckingForUpdates ? "Checking..." : "Check for Updates Now", action: checkForUpdatesFromSettings)
                        .disabled(isCheckingForUpdates)
                    Spacer()
                }

                Text("FinderPath checks GitHub Releases for the latest tagged version and compares it to the one installed. Defaults to bhino50/finder-path; point this at any GitHub Releases API URL or a plain `{ version, downloadURL, notes }` JSON manifest.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Menu Bar") {
                LabeledContent("Click", value: "Path menu")
                LabeledContent("Right-click", value: "Path menu")
            }

            Section {
                Button("Reset to Defaults", action: resetDefaults)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 560, height: 700)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            scheduleAgentAvailabilityCheck()
        }
        .onChange(of: launchAtLogin) { isEnabled in
            setLaunchAtLogin(isEnabled)
        }
        .onChange(of: codexExecutable) { _ in
            scheduleAgentAvailabilityCheck(debounce: true)
        }
        .onChange(of: claudeExecutable) { _ in
            scheduleAgentAvailabilityCheck(debounce: true)
        }
        .onChange(of: hermesExecutable) { _ in
            scheduleAgentAvailabilityCheck(debounce: true)
        }
    }

    // Registers or unregisters the app as a login item, keeping the toggle in
    // sync with the real SMAppService status when the system rejects a change.
    private func setLaunchAtLogin(_ isEnabled: Bool) {
        let service = SMAppService.mainApp
        guard isEnabled != (service.status == .enabled) else { return }

        do {
            if isEnabled {
                try service.register()
            } else {
                try service.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Could not \(isEnabled ? "enable" : "disable") launch at login: \(error.localizedDescription)"
            launchAtLogin = service.status == .enabled
        }
    }

    private func resetDefaults() {
        showPathHeader = true
        showRefreshItem = true
        showCopyPathItem = true
        showCopyCDItem = true
        showOpenTerminalItem = true
        showOpenGhosttyItem = true
        showOpenWithCodexItem = true
        showOpenWithClaudeItem = true
        showOpenWithHermesItem = true
        showOpenCmuxItem = true
        showConnectToServerItem = true
        showCheckForUpdatesItem = true
        showQuitItem = true
        pathDisplayStyle = "full"
        menuHeaderTitle = "Current Finder Path"
        menuHeaderWidth = 380
        pathLineBreak = "middle"
        pathFontSize = 12
        statusIcon = "folder"
        showStatusTitle = false
        statusTitle = "FP"
        cdQuoteStyle = "double"
        remoteConnectionTerminal = "ghostty"
        codexExecutable = "codex"
        claudeExecutable = "claude"
        hermesExecutable = "hermes"
        hideUnavailableAgentItems = true
        updateManifestURL = FinderPathPreferences.defaultUpdateManifestURL
        scheduleAgentAvailabilityCheck()
    }

    // Probes the configured executables off the main thread, replacing any
    // check that is still pending. With debounce, waits for typing to pause
    // first so text-field edits do not spawn a process per keystroke.
    private func scheduleAgentAvailabilityCheck(debounce: Bool = false) {
        agentAvailabilityCheckTask?.cancel()
        let codexCommand = codexExecutable
        let claudeCommand = claudeExecutable
        let hermesCommand = hermesExecutable

        agentAvailabilityCheckTask = Task {
            if debounce {
                try? await Task.sleep(nanoseconds: Self.agentCheckDebounceNanoseconds)
                guard !Task.isCancelled else { return }
            }

            async let codex = AgentLauncher.checkAvailability(for: codexCommand, defaultExecutable: "codex")
            async let claude = AgentLauncher.checkAvailability(for: claudeCommand, defaultExecutable: "claude")
            async let hermes = AgentLauncher.checkAvailability(for: hermesCommand, defaultExecutable: "hermes")
            let (codexResult, claudeResult, hermesResult) = await (codex, claude, hermes)

            guard !Task.isCancelled else { return }
            codexAvailability = codexResult
            claudeAvailability = claudeResult
            hermesAvailability = hermesResult
        }
    }

    private func checkForUpdatesFromSettings() {
        isCheckingForUpdates = true
        let currentVersion = AppVersion.current
        UpdateChecker.check(manifestURL: FinderPathPreferences.updateManifestURL) { result in
            Task { @MainActor in
                isCheckingForUpdates = false
                UpdatePrompt.present(
                    result: result,
                    currentVersion: currentVersion,
                    userInitiated: true
                )
            }
        }
    }
}

struct AgentStatusRow: View {
    let name: String
    let availability: AgentAvailability

    var body: some View {
        LabeledContent("\(name) status") {
            VStack(alignment: .trailing, spacing: 2) {
                Label(
                    availability.isInstalled ? "Installed" : "Not Found",
                    systemImage: availability.isInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(availability.isInstalled ? Color.green : Color.secondary)

                Text(availability.resolvedPath ?? availability.executable)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }
}

@MainActor
final class WelcomeWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = "Welcome to FinderPath"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = NSHostingController(rootView: WelcomeView())

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

struct WelcomeView: View {
    @AppStorage(FinderPathPreferences.completedWelcomeKey) private var completedWelcome = false
    @State private var finderPath = ""
    @State private var isCheckingFinder = false

    private var finderAccessGranted: Bool {
        !finderPath.isEmpty && !finderPath.hasPrefix("Finder AppleScript error:")
    }

    private var finderAccessDenied: Bool {
        FinderBridge.isPermissionDenied(finderPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to FinderPath").font(.title).bold()
                    Text("Your Finder path in the menu bar.")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            stepRow(
                index: 1,
                title: "Look for the menu bar icon",
                detail: "FinderPath has no Dock icon. Click the folder icon near the clock to open the menu.")

            stepRow(
                index: 2,
                title: "Allow Finder access",
                detail: "FinderPath needs permission to read the frontmost Finder folder path.")

            HStack {
                Button {
                    requestFinderAccess()
                } label: {
                    Label("Grant Finder Access", systemImage: "hand.raised")
                }
                .controlSize(.large)
                .disabled(isCheckingFinder)

                Spacer()
                statusBadge
            }

            if finderAccessDenied {
                VStack(alignment: .leading, spacing: 6) {
                    Text("macOS is blocking FinderPath from reading the Finder path. Turn on Finder for FinderPath under Automation, then try again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Automation Settings…") {
                        FinderBridge.openAutomationSettings()
                    }
                }
            } else if !finderPath.isEmpty && !finderAccessGranted {
                Text(finderPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("If macOS blocked the first launch, see Install First — Read Me.txt in the download DMG for the one-time Gatekeeper steps.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(finderAccessGranted ? "Get Started" : "Skip for Now") {
                    completedWelcome = true
                    NSApp.keyWindow?.close()
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            refreshFinderAccess()
        }
    }

    private func stepRow(index: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(.tint.opacity(0.15)).frame(width: 28, height: 28)
                Text("\(index)").font(.headline).foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if finderAccessGranted {
            Label("Finder access on", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        } else if finderAccessDenied {
            Label("Finder access denied", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        } else {
            Label("Waiting for permission…", systemImage: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func requestFinderAccess() {
        isCheckingFinder = true
        refreshFinderAccess()
        isCheckingFinder = false
    }

    private func refreshFinderAccess() {
        finderPath = FinderBridge.currentPath()
    }
}

@MainActor
enum UpdatePrompt {
    static func present(result: UpdateCheckResult, currentVersion: String, userInitiated: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .informational

        switch result {
        case .upToDate(let latest):
            alert.messageText = "FinderPath is up to date."
            alert.informativeText = "You are running version \(currentVersion). Latest available is \(latest)."
            alert.addButton(withTitle: "OK")

        case .updateAvailable(let manifest):
            alert.messageText = "A new version of FinderPath is available."
            var detail = "Installed: \(currentVersion)\nLatest: \(manifest.latestVersion)"
            if let notes = manifest.releaseNotes, !notes.isEmpty {
                detail += "\n\n\(notes)"
            }
            alert.informativeText = detail
            if manifest.archiveURL != nil {
                alert.addButton(withTitle: "Install and Relaunch")
            } else {
                alert.addButton(withTitle: manifest.downloadURL == nil ? "OK" : "Download")
            }
            alert.addButton(withTitle: "Later")

        case .failed(let message):
            guard userInitiated else { return }
            alert.alertStyle = .warning
            alert.messageText = "Could not check for updates."
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        guard case .updateAvailable(let manifest) = result,
              response == .alertFirstButtonReturn else { return }

        if manifest.archiveURL != nil {
            beginInstall(manifest: manifest)
        } else if let url = manifest.downloadURL {
            NSWorkspace.shared.open(url)
        }
    }

    private static func beginInstall(manifest: UpdateManifest) {
        UpdateInstaller.install(manifest: manifest) { result in
            switch result {
            case .success:
                // The relaunch helper waits for this process to exit, then
                // reopens the freshly installed copy.
                NSApp.terminate(nil)
            case .failure(let error):
                presentInstallFailure(error, manifest: manifest)
            }
        }
    }

    private static func presentInstallFailure(_ error: UpdateInstaller.InstallError, manifest: UpdateManifest) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The update could not be installed."
        alert.informativeText = error.localizedDescription
        if manifest.downloadURL != nil {
            alert.addButton(withTitle: "Download in Browser")
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.addButton(withTitle: "OK")
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn, let url = manifest.downloadURL {
            NSWorkspace.shared.open(url)
        }
    }
}
