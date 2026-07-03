import AppKit

/// A small floating window shown while the user presses a key to bind a new
/// hotkey. The actual key capture happens in `HotkeyMonitor`; this is just the
/// prompt + a Cancel affordance.
final class HotkeyCapturePanel {
    private var window: NSWindow?
    private var onCancel: (() -> Void)?

    /// Shows the panel. `onCancel` runs if the user dismisses it without picking
    /// a key.
    func present(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Add Hotkey"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = windowDelegate

        let prompt = NSTextField(wrappingLabelWithString:
            "Press the modifier key you want to use as a push-to-talk key.\n\n"
            + "⌘ Command · ⌥ Option · ⌃ Control · ⇧ Shift · Fn 🌐")
        prompt.alignment = .center
        prompt.font = .systemFont(ofSize: 13)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}" // Esc

        let stack = NSStackView(views: [prompt, cancel])
        stack.orientation = .vertical
        stack.spacing = 18
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24)
        ])
        window.contentView = content
        window.center()

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    /// Closes the panel without invoking `onCancel` (used once a key is captured).
    func dismiss() {
        onCancel = nil
        let closing = window
        window = nil            // nil first so windowWillClose doesn't re-enter close()
        closing?.close()
    }

    @objc private func cancelClicked() {
        let cancel = onCancel
        dismiss()
        cancel?()
    }

    // Treat closing the window (red button) the same as Cancel.
    private lazy var windowDelegate = WindowCloseDelegate { [weak self] in self?.cancelClicked() }
}
