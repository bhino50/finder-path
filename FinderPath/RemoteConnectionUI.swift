import SwiftUI
import AppKit

@MainActor
final class RemoteConnectionWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 580),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Connect to Server"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = NSHostingController(rootView: RemoteConnectionView())

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

struct RemoteConnectionView: View {
    @AppStorage(FinderPathPreferences.remoteServersKey) private var remoteServersText = ""
    @AppStorage(FinderPathPreferences.remoteConnectionTerminalKey) private var remoteConnectionTerminal = "ghostty"

    @State private var selection: String?
    @State private var selectedTarget = ""
    @State private var user = ""
    @State private var tailscale = TailscaleStatus.unavailable
    @State private var showAllDevices = false
    @State private var isLoadingTailscale = false
    @State private var isTogglingVPN = false
    @State private var isAddingServer = false
    @State private var newServerName = ""
    @State private var newServerTarget = ""
    @State private var errorMessage: String?

    private var servers: [RemoteServer] {
        RemoteServers.parse(remoteServersText)
    }

    private var visibleDevices: [TailscaleDevice] {
        tailscale.devices.filter { device in
            guard !device.address.isEmpty else { return false }
            return showAllDevices || device.isLinux
        }
    }

    private var selectedServerIndex: Int? {
        guard let selection, selection.hasPrefix("srv:") else { return nil }
        return Int(selection.dropFirst(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            tailscaleHeader

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    deviceSection
                    serverSection
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: .infinity)

            Divider()

            footer
        }
        .padding(20)
        .frame(width: 460, height: 580)
        .onAppear { Task { await refreshTailscale() } }
        .alert("Connection problem", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $isAddingServer) { addServerSheet }
    }

    private var tailscaleHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.title3)
                .foregroundStyle(tailscale.isRunning ? Color.green : Color.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text("Tailscale").font(.headline)
                Text(tailscaleStatusText).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if isLoadingTailscale && tailscale.backend == .unavailable {
                // First load: the window paints right away while the CLI check
                // runs in the background.
                ProgressView()
                    .controlSize(.small)
            } else if tailscale.backend == .unavailable {
                Text("Not installed").font(.caption).foregroundStyle(.secondary)
            } else {
                Button(tailscale.isRunning ? "Disconnect" : "Connect") { toggleVPN() }
                    .disabled(isTogglingVPN || tailscale.backend == .needsLogin)
            }
        }
    }

    private var tailscaleStatusText: String {
        switch tailscale.backend {
        case .running:
            return tailscale.selfAddress.map { "Connected · \($0)" } ?? "Connected"
        case .stopped:
            return "Disconnected"
        case .needsLogin:
            return "Needs login — open the Tailscale app"
        case .unavailable:
            return isLoadingTailscale ? "Checking Tailscale status…" : "Tailscale CLI not found"
        }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tailscale Devices").font(.subheadline.weight(.semibold))
                Spacer()
                Toggle("Show all", isOn: $showAllDevices)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Button {
                    Task { await refreshTailscale(forceRefresh: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isLoadingTailscale)
            }

            if visibleDevices.isEmpty {
                Text(deviceEmptyText).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(visibleDevices) { device in
                    connectionRow(
                        id: "ts:\(device.id)",
                        title: device.name,
                        subtitle: "\(device.address) · \(device.os)",
                        online: device.online,
                        target: device.name.isEmpty ? device.address : device.name
                    )
                }
            }
        }
    }

    private var deviceEmptyText: String {
        if tailscale.backend == .unavailable { return "Tailscale is not installed." }
        if isLoadingTailscale { return "Loading devices…" }
        return showAllDevices ? "No devices online." : "No Linux devices online. Enable \"Show all\" to see every device."
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("My Servers").font(.subheadline.weight(.semibold))
                Spacer()
                Button { beginAddServer() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                Button { removeSelectedServer() } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                    .disabled(selectedServerIndex == nil)
            }

            if servers.isEmpty {
                Text("No servers yet. Click + to add one (e.g. Dev Server = dev.example.com).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(servers.enumerated()), id: \.offset) { index, server in
                    connectionRow(
                        id: "srv:\(index)",
                        title: server.name,
                        subtitle: server.target,
                        online: nil,
                        target: server.target
                    )
                }
            }
        }
    }

    private func connectionRow(id: String, title: String, subtitle: String, online: Bool?, target: String) -> some View {
        HStack(spacing: 8) {
            if let online {
                Circle()
                    .fill(online ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
            } else {
                Image(systemName: "server.rack")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 8)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selection == id ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            select(id: id, target: target)
            connect()
        }
        .onTapGesture {
            select(id: id, target: target)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("User").frame(width: 48, alignment: .leading)
                TextField("optional (e.g. admin)", text: $user)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("Open in").frame(width: 48, alignment: .leading)
                Picker("", selection: $remoteConnectionTerminal) {
                    Text("Ghostty").tag("ghostty")
                    Text("macOS Terminal").tag("terminal")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack {
                Spacer()
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
    }

    private var addServerSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Server").font(.headline)
            TextField("Name (e.g. Dev Server)", text: $newServerName)
                .textFieldStyle(.roundedBorder)
            TextField("SSH target (e.g. dev.example.com or user@host)", text: $newServerTarget)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { isAddingServer = false }
                Button("Add") { commitAddServer() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newServerTarget.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func select(id: String, target: String) {
        selection = id
        selectedTarget = target
    }

    private func beginAddServer() {
        newServerName = ""
        newServerTarget = ""
        isAddingServer = true
    }

    private func commitAddServer() {
        let name = newServerName.trimmingCharacters(in: .whitespaces)
        let target = RemoteServers.normalizedTarget(newServerTarget)
        guard !target.isEmpty else { return }

        var current = servers
        current.append(RemoteServer(name: name.isEmpty ? target : name, target: target))
        remoteServersText = RemoteServers.serialize(current)
        isAddingServer = false
    }

    private func removeSelectedServer() {
        guard let index = selectedServerIndex else { return }

        var current = servers
        guard current.indices.contains(index) else { return }
        current.remove(at: index)
        remoteServersText = RemoteServers.serialize(current)
        selection = nil
    }

    private func connect() {
        guard !selectedTarget.isEmpty else { return }

        let target = RemoteServers.normalizedTarget(selectedTarget)
        guard !target.isEmpty else { return }

        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = (!trimmedUser.isEmpty && !target.contains("@"))
            ? "\(trimmedUser)@\(target)"
            : target

        let terminal = TerminalBridge.RemoteTerminal(rawValue: remoteConnectionTerminal) ?? .ghostty
        TerminalBridge.openSSH(host: host, using: terminal) { error in
            guard let error else { return }
            Task { @MainActor in errorMessage = error }
        }
    }

    private func toggleVPN() {
        isTogglingVPN = true
        let goingUp = !tailscale.isRunning
        Task {
            let error = goingUp ? await TailscaleBridge.up() : await TailscaleBridge.down()
            isTogglingVPN = false
            if let error { errorMessage = error }
            await refreshTailscale(forceRefresh: true)
        }
    }

    private func refreshTailscale(forceRefresh: Bool = false) async {
        isLoadingTailscale = true
        tailscale = await TailscaleBridge.status(forceRefresh: forceRefresh)
        isLoadingTailscale = false
    }
}
