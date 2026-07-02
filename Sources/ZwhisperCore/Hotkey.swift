import Foundation

/// A push-to-talk key.
///
/// Only *modifier* keys are supported: you hold one to record and release it to
/// transcribe, and modifiers (unlike letters) don't type characters or
/// auto-repeat while held. Each case's raw value is the **device-dependent**
/// modifier flag bit reported in a `flagsChanged` event, which is what lets us
/// tell Left ⌘ apart from Right ⌘ (the general `.maskCommand` bit can't).
public enum Hotkey: UInt64, CaseIterable, Sendable {
    case leftControl  = 0x0000_0001  // NX_DEVICELCTLKEYMASK
    case leftShift    = 0x0000_0002  // NX_DEVICELSHIFTKEYMASK
    case rightShift   = 0x0000_0004  // NX_DEVICERSHIFTKEYMASK
    case leftCommand  = 0x0000_0008  // NX_DEVICELCMDKEYMASK
    case rightCommand = 0x0000_0010  // NX_DEVICERCMDKEYMASK
    case leftOption   = 0x0000_0020  // NX_DEVICELALTKEYMASK
    case rightOption  = 0x0000_0040  // NX_DEVICERALTKEYMASK
    case rightControl = 0x0000_2000  // NX_DEVICERCTLKEYMASK
    case fn           = 0x0080_0000  // kCGEventFlagMaskSecondaryFn (Globe / 🌐)

    /// The flag bit to test against a `flagsChanged` event's `flags.rawValue`.
    public var mask: UInt64 { rawValue }

    /// kVK_Function — the keycode a *genuine* Fn/Globe key press carries in its
    /// `flagsChanged` event.
    public static let fnKeyCode: Int64 = 63

    /// Which configured hotkeys are held after a `flagsChanged` event.
    ///
    /// The Fn bit needs special care: macOS also sets it for arrow keys, Home/
    /// End, and Page Up/Down (they are "function-sensitive" keys), so pressing
    /// an arrow emits a `flagsChanged` with the Fn bit that is indistinguishable
    /// from the Globe key *by flags alone*. Those phantom events carry the
    /// navigation key's own keycode though — so an Fn *transition* is only
    /// honoured when the event's keycode is the Fn key itself. Without this,
    /// pressing an arrow key starts/stops recording.
    public static func held(
        of hotkeys: Set<Hotkey>, flags: UInt64, keyCode: Int64, previouslyHeld: Set<Hotkey>
    ) -> Set<Hotkey> {
        var held = hotkeys.filter { (flags & $0.mask) != 0 }
        if hotkeys.contains(.fn), keyCode != Self.fnKeyCode {
            // Not the Fn key: whatever the bit says, Fn's held-state is unchanged.
            if previouslyHeld.contains(.fn) { held.insert(.fn) } else { held.remove(.fn) }
        }
        return held
    }

    /// The hotkey newly pressed by this `flagsChanged` event, for capture mode.
    /// Applies the same phantom-Fn filtering as `held(of:flags:keyCode:previouslyHeld:)`.
    public static func newlyPressed(
        flags: UInt64, previousFlags: UInt64, keyCode: Int64
    ) -> Hotkey? {
        let pressed = allCases.first {
            (flags & $0.mask) != 0 && (previousFlags & $0.mask) == 0
        }
        if pressed == .fn, keyCode != Self.fnKeyCode { return nil }
        return pressed
    }

    /// Human-readable label shown in the menu.
    public var name: String {
        switch self {
        case .leftControl:  return "Left ⌃ Control"
        case .leftShift:    return "Left ⇧ Shift"
        case .rightShift:   return "Right ⇧ Shift"
        case .leftCommand:  return "Left ⌘ Command"
        case .rightCommand: return "Right ⌘ Command"
        case .leftOption:   return "Left ⌥ Option"
        case .rightOption:  return "Right ⌥ Option"
        case .rightControl: return "Right ⌃ Control"
        case .fn:           return "Fn 🌐 (Globe)"
        }
    }
}
