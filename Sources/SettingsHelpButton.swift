import AppKit

// A passive popover must not take editing focus or intercept the pointer above
// its anchor. This also keeps hover tracking stable near a screen edge.
@MainActor
private final class SettingsHelpContentView: NSView {
    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.ignoresMouseEvents = true
        (window as? NSPanel)?.becomesKeyOnlyIfNeeded = true
    }
}

@MainActor
final class SettingsHelpButton: NSButton {
    private let helpPopover = NSPopover()
    private var hoverArea: NSTrackingArea?
    private var hoverTask: Task<Void, Never>?
    private var pointerInside = false

    init(help: String) {
        super.init(frame: .zero)
        title = ""
        image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        contentTintColor = .secondaryLabelColor
        isBordered = false
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleHelp)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22)
        ])
        setAccessibilityLabel("设置说明")
        setAccessibilityHelp(help)

        let label = NSTextField(wrappingLabelWithString: help)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.isSelectable = false
        label.preferredMaxLayoutWidth = 286
        label.translatesAutoresizingMaskIntoConstraints = false
        let content = SettingsHelpContentView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            label.widthAnchor.constraint(equalToConstant: 286)
        ])
        let controller = NSViewController()
        controller.view = content
        helpPopover.contentViewController = controller
        helpPopover.contentSize = content.fittingSize
        helpPopover.animates = false
        helpPopover.behavior = .transient
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        hoverTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        dismissHelp()
        let center = NotificationCenter.default
        center.removeObserver(self)
        guard let window else { return }
        for name in [NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification,
                     NSWindow.didResignMainNotification] {
            center.addObserver(self, selector: #selector(environmentChanged), name: name, object: window)
        }
        center.addObserver(self, selector: #selector(environmentChanged),
                           name: NSApplication.didResignActiveNotification, object: NSApp)
        if let clipView = enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            center.addObserver(self, selector: #selector(environmentChanged),
                               name: NSView.boundsDidChangeNotification, object: clipView)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard window?.isKeyWindow == true else { return }
        pointerInside = true
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 350_000_000) }
            catch { return }
            guard let self, !Task.isCancelled, self.pointerInside else { return }
            self.showHelp()
        }
    }

    override func mouseExited(with event: NSEvent) { dismissHelp() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            dismissHelp()
        } else {
            super.keyDown(with: event)
        }
    }

    @objc private func toggleHelp() {
        hoverTask?.cancel()
        hoverTask = nil
        if helpPopover.isShown { dismissHelp() }
        else { showHelp() }
    }

    @objc private func environmentChanged(_ notification: Notification) { dismissHelp() }

    private func showHelp() {
        guard !helpPopover.isShown, let window, window.isVisible,
              !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else { return }
        // Preserve the original field editor on systems where showing an
        // NSPopover attempts to make its otherwise passive panel key.
        let keepKeyWindow = window.isKeyWindow
        let fieldEditor = window.firstResponder
        helpPopover.show(relativeTo: bounds, of: self, preferredEdge: .maxX)
        if keepKeyWindow && !window.isKeyWindow {
            window.makeKey()
            if let fieldEditor, window.firstResponder !== fieldEditor {
                window.makeFirstResponder(fieldEditor)
            }
        }
    }

    private func dismissHelp() {
        pointerInside = false
        hoverTask?.cancel()
        hoverTask = nil
        helpPopover.close()
    }
}
