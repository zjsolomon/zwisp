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
    private var runLoopSource: CFRunLoopSource?
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
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Tears down the tap so a fresh one can be created (e.g. after the user
    /// grants Accessibility — a tap created while untrusted never gets events).
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handle(event: CGEvent) {
        // We only tap `.flagsChanged`, which fires solely for modifier keys
        // (Shift/Ctrl/Opt/Cmd/Fn/CapsLock) — never for arrows or letters. Of
        // those, only the Fn/Globe key sets `.maskSecondaryFn`, so this flag
        // check alone uniquely identifies the Fn key. (Note: on modern
        // MacBooks the Fn key's keycode field is unreliable — often 0 — so we
        // must not filter on keycode here.)
        let fnNow = event.flags.contains(.maskSecondaryFn)
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        Log.write("flagsChanged: flags=\(event.flags.rawValue) fn=\(fnNow) keycode=\(keycode)")
        if fnNow && !fnDown {
            fnDown = true
            DispatchQueue.main.async { self.onPress() }
        } else if !fnNow && fnDown {
            fnDown = false
            DispatchQueue.main.async { self.onRelease() }
        }
    }
}
