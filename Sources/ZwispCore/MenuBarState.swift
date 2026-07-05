import AppKit

/// The menu-bar item's visible state. Kept separate from `AppDelegate` so the
/// state-derivation logic can be unit-tested without spinning up an app.
///
/// Colour scheme: red = warming up (don't dictate yet), green = ready with
/// cleanup inactive, blue = ready with cleanup active, orange = permissions
/// missing. Recording deliberately has no colour of its own — macOS shows its
/// own microphone-in-use indicator, which is the honest signal for "mic open".
public enum MenuBarState: Equatable {
    case loading                       // speech model loading — dictation not ready
    case ready(cleanup: CleanupStatus) // waiting for the hotkey
    case recording                     // hotkey held, capturing audio
    case thinking                      // transcribing / cleaning / queued
    case noPermission                  // accessibility / input monitoring not granted

    /// Derives the resting state from the independent readiness signals.
    /// Only meaningful when no recording/transcription is in progress.
    public static func resting(monitorActive: Bool, modelReady: Bool,
                               cleanup: CleanupStatus) -> MenuBarState {
        if !monitorActive { return .noPermission }
        if !modelReady { return .loading }
        return .ready(cleanup: cleanup)
    }

    public var label: String {
        switch self {
        case .loading:
            return "Warming up — speech model loading, don't dictate yet"
        case .ready(.active(let model)):
            return "Ready — AI cleanup via \(model)"
        case .ready(.unavailable):
            return "Ready — AI cleanup unavailable (is Ollama running?)"
        case .ready(.off):
            return "Ready — AI cleanup off"
        case .recording:
            return "Recording…"
        case .thinking:
            return "Transcribing…"
        case .noPermission:
            return "Needs Accessibility permission"
        }
    }

    /// nil = template image (auto black/white to match the menu bar).
    public var tint: NSColor? {
        switch self {
        case .loading:                           return .systemRed
        case .ready(.active):                    return .systemBlue
        case .ready(.unavailable), .ready(.off): return .systemGreen
        case .recording:                         return nil
        case .thinking:                          return .secondaryLabelColor
        case .noPermission:                      return .systemOrange
        }
    }
}
