import AppKit
import ApplicationServices

/// A snapshot of the frontmost application at a moment in time — its process
/// identifier, bundle identifier, and (best-effort) focused-window title — used
/// to resolve the per-app writing style for a dictation.
///
/// This lives in the app layer, not `ZwispCore`, on purpose: it depends on
/// AppKit (`NSWorkspace`) and ApplicationServices (the Accessibility API), which
/// core deliberately avoids so its logic stays pure and unit-testable. The pure
/// side of style resolution lives in core (`StyleResolver`); this type only
/// gathers the raw inputs it needs.
enum FrontmostContext {
    struct Snapshot {
        let pid: pid_t?
        let bundleID: String?
        let windowTitle: String?
    }

    /// Captures the current frontmost app. The pid and bundle ID come from
    /// `NSWorkspace`; the window title is read via the Accessibility API
    /// (`AXUIElementCreateApplication` → focused window → title).
    ///
    /// Any Accessibility failure — the permission being absent, no focused
    /// window, or a non-string title — degrades silently to `windowTitle = nil`.
    /// It never throws and never triggers a permission prompt: we already hold
    /// Accessibility for text injection, and if it's somehow missing we simply
    /// fall back to bundle-only style resolution rather than interrupting the
    /// user mid-dictation.
    static func capture() -> Snapshot {
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier
        let bundleID = app?.bundleIdentifier
        let windowTitle = pid.flatMap(focusedWindowTitle(pid:))
        return Snapshot(pid: pid, bundleID: bundleID, windowTitle: windowTitle)
    }

    /// Best-effort focused-window title for a process. Returns `nil` on any AX
    /// failure or when the title isn't a non-empty string.
    private static func focusedWindowTitle(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
            let windowRef else { return nil }
        // The focused-window attribute is itself an AXUIElement.
        let window = windowRef as! AXUIElement

        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, kAXTitleAttribute as CFString, &titleRef) == .success,
            let title = titleRef as? String, !title.isEmpty else { return nil }
        return title
    }
}
