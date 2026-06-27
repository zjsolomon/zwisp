import AppKit

/// Watches the global keyboard for the Fn (🌐) key being pressed and released,
/// using a passive CGEventTap on `.flagsChanged`. Requires Accessibility permission.
///
/// Note: we listen only (we don't swallow the key). To stop Fn from also opening
/// the emoji picker / switching input source, set
/// System Settings → Keyboard → "Press 🌐 key to" → "Do Nothing".
final class FnKeyMonitor {
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var eventTap: CFMachPort?
    private var fnDown = false

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
    }

    /// Returns true if the tap was created (i.e. Accessibility permission granted).
    @discardableResult
    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            // If the tap gets disabled by the system (timeout/user input), re-enable it.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            monitor.handle(event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Zwhisper: failed to create event tap (grant Accessibility permission)")
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(event: CGEvent) {
        // Only react to the physical Fn/Globe key (keycode 63). Other keys
        // (arrows, etc.) also carry the function flag, so without this guard
        // they would falsely start/stop recording.
        guard event.getIntegerValueField(.keyboardEventKeycode) == 63 else { return }

        // .maskSecondaryFn is the Fn/Globe modifier at the CGEvent level.
        let fnNow = event.flags.contains(.maskSecondaryFn)
        if fnNow && !fnDown {
            fnDown = true
            DispatchQueue.main.async { self.onPress() }
        } else if !fnNow && fnDown {
            fnDown = false
            DispatchQueue.main.async { self.onRelease() }
        }
    }
}
