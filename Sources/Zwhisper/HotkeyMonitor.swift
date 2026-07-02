import AppKit
import ZwhisperCore

/// Watches the global keyboard for the user's configured push-to-talk modifier
/// keys, using a passive `CGEventTap` on `.flagsChanged`. Holding *any*
/// configured key fires `onPress`; releasing the last held one fires
/// `onRelease`. Requires Accessibility + Input Monitoring permission.
///
/// Also supports a one-shot **capture mode** used by "Add Hotkey…": the next
/// modifier the user presses is reported to a completion handler instead of
/// triggering recording.
///
/// Note: we listen only (we don't swallow keys). To stop Fn from also opening
/// the emoji picker / switching input source, set System Settings → Keyboard →
/// "Press 🌐 key to" → "Do Nothing".
final class HotkeyMonitor {
    private let onPress: () -> Void
    private let onRelease: () -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var hotkeys: Set<Hotkey>
    /// Configured keys currently held down. Recording is active while non-empty.
    private var heldKeys: Set<Hotkey> = []
    /// Full modifier flags from the previous event, used to spot newly pressed
    /// keys during capture.
    private var previousFlags: UInt64 = 0
    private var captureCompletion: ((Hotkey) -> Void)?

    init(hotkeys: [Hotkey], onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.hotkeys = Set(hotkeys)
        self.onPress = onPress
        self.onRelease = onRelease
    }

    /// Returns true if the tap was created (i.e. permissions granted).
    @discardableResult
    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
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
    /// grants a permission — a tap created while untrusted never gets events).
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

    /// Replaces the set of keys that trigger recording. Safe to call at runtime.
    func update(hotkeys: [Hotkey]) {
        self.hotkeys = Set(hotkeys)
        heldKeys = []
    }

    /// Captures the next modifier the user presses (instead of recording) and
    /// reports it. Automatically ends after one capture.
    func beginCapture(_ completion: @escaping (Hotkey) -> Void) {
        captureCompletion = completion
    }

    func cancelCapture() {
        captureCompletion = nil
    }

    private func handle(event: CGEvent) {
        // `.flagsChanged` events identify modifiers by device-dependent flag
        // bits (left vs right ⌘ differ). The keycode matters for one case:
        // arrow/navigation keys also toggle the Fn flag bit, so Fn transitions
        // are only honoured when the keycode is the Fn key itself — see
        // `Hotkey.held(of:flags:keyCode:previouslyHeld:)`.
        let flags = event.flags.rawValue
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        defer { previousFlags = flags }

        if let capture = captureCompletion {
            if let pressed = Hotkey.newlyPressed(
                flags: flags, previousFlags: previousFlags, keyCode: keyCode
            ) {
                captureCompletion = nil
                DispatchQueue.main.async { capture(pressed) }
            }
            return
        }

        let wasActive = !heldKeys.isEmpty
        heldKeys = Hotkey.held(
            of: hotkeys, flags: flags, keyCode: keyCode, previouslyHeld: heldKeys)
        let isActive = !heldKeys.isEmpty

        if isActive && !wasActive {
            DispatchQueue.main.async { self.onPress() }
        } else if !isActive && wasActive {
            DispatchQueue.main.async { self.onRelease() }
        }
    }
}
