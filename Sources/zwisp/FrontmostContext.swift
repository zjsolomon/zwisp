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

    /// The `NSScreen` displaying the frontmost app's focused window — the screen
    /// the user is dictating into, used to place the dictation overlay.
    ///
    /// Best-effort with the same silent-degradation contract as `capture()`: any
    /// Accessibility failure (permission absent, no focused window, missing
    /// position/size, or no intersecting screen) returns `nil`, never throws, and
    /// never triggers a permission prompt. The caller falls back to the mouse's
    /// screen / main screen.
    static func focusedWindowScreen() -> NSScreen? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        else { return nil }
        let appElement = AXUIElementCreateApplication(pid)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
            let windowRef else { return nil }
        let window = windowRef as! AXUIElement

        // Read the window's global position and size as AXValue-wrapped structs.
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, kAXPositionAttribute as CFString, &positionRef) == .success,
            let positionRef,
            AXUIElementCopyAttributeValue(
                window, kAXSizeAttribute as CFString, &sizeRef) == .success,
            let sizeRef else { return nil }

        var axPoint = CGPoint.zero
        var axSize = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &axPoint),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &axSize) else { return nil }

        // AX geometry is global, top-left-origin (y grows downward, measured from
        // the top of the primary display). Cocoa/NSScreen is bottom-left-origin.
        // Flip using the primary screen (`NSScreen.screens.first`, which owns the
        // global origin): a Cocoa y where the window's *bottom* edge sits at
        // `primary.maxY − (axY + axHeight)`.
        guard let primary = NSScreen.screens.first else { return nil }
        let cocoaY = primary.frame.maxY - (axPoint.y + axSize.height)
        let windowRect = CGRect(x: axPoint.x, y: cocoaY,
                                width: axSize.width, height: axSize.height)

        // Pick the screen sharing the largest intersection area with the window —
        // correct for windows straddling two displays, where center-containment
        // would guess wrong.
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let inter = screen.frame.intersection(windowRect)
            guard !inter.isNull else { continue }
            let area = inter.width * inter.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best
    }
}
