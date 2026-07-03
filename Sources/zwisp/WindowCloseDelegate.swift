import AppKit

/// Reusable NSWindowDelegate that runs a closure when the window closes.
/// Shared by the floating panels (hotkey capture, onboarding) so close-button
/// handling lives in one place. Hold it strongly — `NSWindow.delegate` is weak.
final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}
