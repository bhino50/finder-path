import AppKit

// Shared modal prompt for renaming a terminal session. Used by both the menu
// (per-session submenu) and the panel tab strip (double-click) so renaming
// behaves identically wherever it is triggered.
enum TerminalRenamePrompt {
    /// Returns the trimmed new name, or nil when the user cancels or clears
    /// the field. The caller applies it through the store so persistence and
    /// change notifications happen in one place.
    @MainActor
    static func run(currentName: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Rename Terminal"
        alert.informativeText = "Enter a new name for this terminal session."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = currentName
        field.placeholderString = "Terminal name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
