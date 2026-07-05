import AppKit
import ZwispCore

/// Handles the "Add to zwisp Dictionary" macOS Service (registered under
/// `NSServices` in Info.plist): the user selects a correctly spelled name in
/// any app, right-clicks, and the selection lands here. This is the only way
/// third-party apps can extend other apps' context menus — macOS may show the
/// item nested under a "Services" submenu rather than top-level.
final class ServicesProvider: NSObject {
    private let dictionary: DictionaryStore
    /// Fired after the dictionary actually changed, with the stored entry —
    /// the app re-warms cleanup (the system prompt just changed) and logs.
    private let onChanged: (String) -> Void

    init(dictionary: DictionaryStore, onChanged: @escaping (String) -> Void) {
        self.dictionary = dictionary
        self.onChanged = onChanged
    }

    /// Signature dictated by the Services protocol; macOS resolves it from the
    /// `NSMessage` name in Info.plist. Setting `error` makes the system tell
    /// the user why nothing happened.
    @objc func addToDictionary(_ pboard: NSPasteboard, userData: String?,
                               error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let selection = pboard.string(forType: .string) else {
            error.pointee = "No text was selected."
            return
        }
        switch dictionary.add(selection) {
        case .added, .updated:
            onChanged(selection.trimmingCharacters(in: .whitespacesAndNewlines))
        case .duplicate:
            break  // already known — nothing to do, and not worth an error dialog
        case .rejected:
            error.pointee = "zwisp dictionary entries are short terms — a name or "
                + "phrase of at most a few words." as NSString
        }
    }
}
