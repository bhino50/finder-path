import AppKit

/// Which agent a recent-path row launches, and where. Carried on the item's
/// representedObject so two selectors cover all three agents rather than six
/// near-identical ones.
final class RecentPathAgentTarget: NSObject {
    let path: String
    let name: String
    let executable: String

    init(path: String, name: String, executable: String) {
        self.path = path
        self.name = name
        self.executable = executable
        super.init()
    }
}

/// One agent the menu may offer. Availability is resolved once per menu rebuild
/// and passed in, because resolving it stats every directory on PATH.
struct RecentPathAgentOption {
    let name: String
    let executable: String
    let availability: AgentAvailability
    let isEnabled: Bool
}

/// Launcher installation checks, resolved once per rebuild for the same reason.
struct RecentPathLauncherAvailability {
    let isCmuxInstalled: Bool
    let isGhosttyInstalled: Bool
}

/// Selectors the rows send back to the status item controller. Non-agent rows
/// carry their folder as a String representedObject; agent rows carry a
/// RecentPathAgentTarget.
struct RecentPathActions {
    let copyPath: Selector
    let copyCDCommand: Selector
    let openInCmux: Selector
    let openInGhostty: Selector
    let openInTerminal: Selector
    let openWithAgent: Selector
    let openAgentInTerminal: Selector
    let newTerminal: Selector
    let revealInFinder: Selector
    let clear: Selector
}

/// Builds the Recent Paths submenu tree. Kept out of StatusItemController for
/// the reason StatusMenuViews records: that file stays the menu controller.
@MainActor
enum RecentPathsMenu {
    /// Returns nil when there is nothing to show, so the caller can skip the
    /// separator as well as the row.
    static func makeMenu(
        paths: [RecentPath],
        launchers: RecentPathLauncherAvailability,
        agents: [RecentPathAgentOption],
        hideUnavailableAgents: Bool,
        optionHeld: Bool,
        target: AnyObject,
        actions: RecentPathActions,
        registerAgentItem: (NSMenuItem, RecentPathAgentOption) -> Void
    ) -> NSMenu? {
        guard !paths.isEmpty else { return nil }

        let menu = NSMenu()
        menu.autoenablesItems = false

        for (entry, title) in zip(paths, RecentPathsLogic.menuTitles(for: paths)) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.toolTip = entry.path
            item.submenu = makeEntryMenu(
                path: entry.path,
                launchers: launchers,
                agents: agents,
                hideUnavailableAgents: hideUnavailableAgents,
                optionHeld: optionHeld,
                target: target,
                actions: actions,
                registerAgentItem: registerAgentItem
            )
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let clearItem = NSMenuItem(title: "Clear Recent Paths", action: actions.clear, keyEquivalent: "")
        clearItem.target = target
        menu.addItem(clearItem)

        return menu
    }

    /// The action set mirrors the main menu, honoring the same visibility
    /// preferences and install checks, so a recent folder is never offered an
    /// action the current folder would not be.
    private static func makeEntryMenu(
        path: String,
        launchers: RecentPathLauncherAvailability,
        agents: [RecentPathAgentOption],
        hideUnavailableAgents: Bool,
        optionHeld: Bool,
        target: AnyObject,
        actions: RecentPathActions,
        registerAgentItem: (NSMenuItem, RecentPathAgentOption) -> Void
    ) -> NSMenu {
        func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = path
            return item
        }

        var launcherItems: [NSMenuItem] = []
        if FinderPathPreferences.showOpenCmuxItem, launchers.isCmuxInstalled {
            launcherItems.append(makeItem("Open in cmux", actions.openInCmux))
        }
        if FinderPathPreferences.showOpenGhosttyItem, launchers.isGhosttyInstalled {
            launcherItems.append(makeItem("Open in Ghostty", actions.openInGhostty))
        }
        if FinderPathPreferences.showOpenTerminalItem {
            launcherItems.append(makeItem("Open in Terminal", actions.openInTerminal))
        }

        var agentItems: [NSMenuItem] = []
        for agent in agents where agent.isEnabled {
            guard agent.availability.isInstalled else {
                guard !hideUnavailableAgents else { continue }
                let item = NSMenuItem(title: "\(agent.name) Not Installed", action: nil, keyEquivalent: "")
                item.isEnabled = false
                agentItems.append(item)
                continue
            }

            let presentation = AgentLauncher.menuPresentation(name: agent.name, optionHeld: optionHeld)
            let item = NSMenuItem(
                title: presentation.title,
                action: presentation.usesBuiltInTerminal ? actions.openAgentInTerminal : actions.openWithAgent,
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = RecentPathAgentTarget(
                path: path,
                name: agent.name,
                executable: agent.executable
            )
            agentItems.append(item)
            // Registering with the controller lets its modifier poll re-title
            // and re-target this row live while the menu is already open.
            registerAgentItem(item, agent)
        }

        let groups: [[NSMenuItem]] = [
            [
                makeItem("Copy Path", actions.copyPath),
                makeItem("Copy cd Command", actions.copyCDCommand)
            ],
            launcherItems,
            agentItems,
            [
                makeItem("New Terminal Here", actions.newTerminal),
                makeItem("Reveal in Finder", actions.revealInFinder)
            ]
        ]

        let menu = NSMenu()
        menu.autoenablesItems = false
        for group in groups where !group.isEmpty {
            if menu.numberOfItems > 0 {
                menu.addItem(.separator())
            }
            group.forEach { menu.addItem($0) }
        }
        return menu
    }
}
