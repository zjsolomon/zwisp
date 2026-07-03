import AppKit
import ZwispCore

/// First-run setup guide: a live checklist of the three permissions with one
/// action button per row. Rows flip to ✓ as the user grants each permission
/// (polled every second while the window is visible). It's guidance, not a
/// gate — closable at any time, reopenable via the menu's "Setup Guide…".
final class OnboardingWindow {
    private let probe: PermissionProbe
    private let hotkeyStore: HotkeyStore
    private let isModelReady: () -> Bool

    private var window: NSWindow?
    private var refreshTimer: Timer?
    private var rows: [(permission: OnboardingPermission, icon: NSImageView, button: NSButton)] = []
    private var footerStack: NSStackView!
    private var readyLabel: NSTextField!
    private var modelStatusLabel: NSTextField!

    init(probe: PermissionProbe, hotkeyStore: HotkeyStore,
         isModelReady: @escaping () -> Bool) {
        self.probe = probe
        self.hotkeyStore = hotkeyStore
        self.isModelReady = isModelReady
    }

    func present() {
        if window == nil {
            window = build()
            window?.center()
        }
        refresh()
        startRefreshTimer()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        stopRefreshTimer()
        window?.close()   // isReleasedWhenClosed = false; kept for reopening
    }

    // MARK: - Live refresh

    /// Cheap non-prompting checks, so a 1 s cadence is fine — and it's what
    /// makes rows flip to ✓ moments after the user grants in System Settings.
    private func startRefreshTimer() {
        stopRefreshTimer()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refresh() {
        let state = probe.state()
        for row in rows {
            let status = state.status(of: row.permission)
            let granted = (status == .granted)
            row.icon.image = NSImage(
                systemSymbolName: granted ? "checkmark.circle.fill" : "circle",
                accessibilityDescription: granted ? "granted" : "not granted")
            row.icon.contentTintColor = granted ? .systemGreen : .secondaryLabelColor
            row.button.title = row.permission.buttonTitle(for: status)
            row.button.isEnabled = !granted
        }

        footerStack.isHidden = !state.allGranted
        if state.allGranted {
            readyLabel.stringValue = readyMessage()
            modelStatusLabel.stringValue = isModelReady()
                ? "Speech model ready — go ahead."
                : "Speech model still loading… the menu-bar icon turns green when it's ready."
        }
    }

    private func readyMessage() -> String {
        let names = hotkeyStore.hotkeys.map(\.name)
        guard !names.isEmpty else {
            return "🎉 All set! Add a push-to-talk key via the menu-bar icon → Hotkeys."
        }
        return "🎉 You're ready! Hold \(names.joined(separator: " or ")), speak, release."
    }

    // MARK: - Row actions

    @objc private func rowButtonClicked(_ sender: NSButton) {
        guard sender.tag < rows.count else { return }
        let permission = rows[sender.tag].permission
        let status = probe.state().status(of: permission)
        switch permission {
        case .microphone:
            // First ask fires the system prompt; once burned, only Settings.
            if status == .notGranted {
                probe.requestMicAccess()
            } else {
                probe.openMicrophoneSettings()
            }
        case .inputMonitoring:
            // The request registers zwisp in the list the user is about to see.
            probe.requestInputMonitoring()
            probe.openInputMonitoringSettings()
        case .accessibility:
            probe.promptAccessibility()
            probe.openAccessibilitySettings()
        }
    }

    @objc private func doneClicked() {
        dismiss()
    }

    // MARK: - Construction

    private func build() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to zwisp"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = closeDelegate

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let title = NSTextField(labelWithString: "Welcome to zwisp")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Three quick permissions and you're dictating.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        let headerText = NSStackView(views: [title, subtitle])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 2
        let header = NSStackView(views: [icon, headerText])
        header.orientation = .horizontal
        header.spacing = 12
        header.alignment = .centerY

        rows = []
        let rowViews = OnboardingPermission.allCases.enumerated().map { index, permission in
            makeRow(for: permission, tag: index)
        }

        readyLabel = NSTextField(labelWithString: "")
        readyLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        modelStatusLabel = NSTextField(labelWithString: "")
        modelStatusLabel.font = .systemFont(ofSize: 11)
        modelStatusLabel.textColor = .secondaryLabelColor

        let done = NSButton(title: "Done", target: self, action: #selector(doneClicked))
        done.keyEquivalent = "\r"
        let doneRow = NSStackView()
        doneRow.orientation = .horizontal
        doneRow.addView(done, in: .trailing)   // flush right

        footerStack = NSStackView(views: [readyLabel, modelStatusLabel, doneRow])
        footerStack.orientation = .vertical
        footerStack.alignment = .leading
        footerStack.spacing = 6

        let stack = NSStackView(views: [header] + rowViews + [footerStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.setCustomSpacing(24, after: header)
        // Keep the footer's space reserved while it's hidden, so the window
        // doesn't jump when the last permission lands.
        stack.detachesHiddenViews = false
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate(
            [
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
                content.widthAnchor.constraint(equalToConstant: 480)
            ]
            // Rows and footer span the full width so buttons right-align.
            + (rowViews + [footerStack, doneRow]).map {
                $0.widthAnchor.constraint(equalTo: stack.widthAnchor)
            }
        )
        window.contentView = content
        window.setContentSize(content.fittingSize)
        return window
    }

    private func makeRow(for permission: OnboardingPermission, tag: Int) -> NSView {
        let icon = NSImageView()
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true

        let title = NSTextField(labelWithString: permission.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let explanation = NSTextField(labelWithString: permission.explanation)
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        let text = NSStackView(views: [title, explanation])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let button = NSButton(title: "", target: self, action: #selector(rowButtonClicked(_:)))
        button.tag = tag

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.addView(icon, in: .leading)
        row.addView(text, in: .leading)
        row.addView(button, in: .trailing)   // flush right, per the mockup

        rows.append((permission, icon, button))
        return row
    }

    // Closing via the red button must also stop the 1 s poll.
    private lazy var closeDelegate = CloseDelegate { [weak self] in self?.stopRefreshTimer() }

    private final class CloseDelegate: NSObject, NSWindowDelegate {
        private let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }
        func windowWillClose(_ notification: Notification) { onClose() }
    }
}
