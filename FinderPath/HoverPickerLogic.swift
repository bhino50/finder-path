import Foundation

/// Pure decision logic for the status-item hover quick-pick, kept free of
/// AppKit so the logic test binary can cover it.
nonisolated enum HoverPickerLogic {
    /// The picker only appears when the user enabled it, at least one terminal
    /// session exists to pick, and no other FinderPath surface (status menu,
    /// terminal panel) already owns the interaction.
    static func shouldPresent(
        enabled: Bool,
        sessionCount: Int,
        isMenuTracking: Bool,
        isPanelVisible: Bool
    ) -> Bool {
        enabled && sessionCount > 0 && !isMenuTracking && !isPanelVisible
    }
}
