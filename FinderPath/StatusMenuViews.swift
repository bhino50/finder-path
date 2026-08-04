import AppKit

/// Custom views hosted inside the status menu and the hover quick-pick.
/// Kept out of StatusItemController so that file stays the menu controller,
/// and because TerminalHoverPickerController builds the same rows.

/// A terminal row in the status menu: explicit Open and Close buttons inside
/// an accessibility group. Highlights on hover like a normal menu item.
final class TerminalMenuRowView: NSView {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    private let openButton = NSButton()
    private let closeButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private let name: String

    private var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            updateOpenButtonTitle()
            closeButton.contentTintColor = isHighlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
            needsDisplay = true
        }
    }

    init(name: String) {
        self.name = name
        super.init(frame: NSRect(x: 0, y: 0, width: FinderPathPreferences.menuHeaderWidth, height: 22))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Terminal \(name)")

        openButton.isBordered = false
        openButton.setButtonType(.momentaryChange)
        openButton.alignment = .left
        openButton.lineBreakMode = .byTruncatingTail
        openButton.target = self
        openButton.action = #selector(openClicked)
        openButton.toolTip = "Open this terminal"
        openButton.setAccessibilityLabel("Open terminal \(name)")
        openButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(openButton)
        updateOpenButtonTitle()

        closeButton.isBordered = false
        closeButton.setButtonType(.momentaryChange)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close terminal")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close this terminal"
        closeButton.setAccessibilityLabel("Close terminal \(name)")
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            openButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            openButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 13),
            closeButton.heightAnchor.constraint(equalToConstant: 13),
            openButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHighlighted = true }
    override func mouseExited(with event: NSEvent) { isHighlighted = false }

    private func updateOpenButtonTitle() {
        openButton.attributedTitle = NSAttributedString(
            string: name,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: isHighlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor,
            ]
        )
    }

    @objc private func openClicked() {
        onOpen?()
    }

    @objc private func closeClicked() {
        onClose?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        bounds.fill()
    }
}

final class PathMenuHeaderView: NSView {
    init(path: String, isError: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: FinderPathPreferences.menuHeaderWidth, height: 54))

        let titleLabel = NSTextField(labelWithString: FinderPathPreferences.menuHeaderTitle)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let pathLabel = NSTextField(labelWithString: path.isEmpty ? "Fetching Finder path..." : path)
        pathLabel.font = .monospacedSystemFont(ofSize: FinderPathPreferences.pathFontSize, weight: .regular)
        pathLabel.textColor = isError ? .systemRed : .labelColor
        pathLabel.lineBreakMode = FinderPathPreferences.pathLineBreakMode
        pathLabel.maximumNumberOfLines = 1
        pathLabel.toolTip = path
        pathLabel.setAccessibilityLabel(FinderPathPreferences.menuHeaderTitle)
        pathLabel.setAccessibilityValue(path)
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(pathLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            pathLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            pathLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            pathLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}
