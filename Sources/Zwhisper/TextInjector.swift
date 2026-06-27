import AppKit

/// Types text into whatever app currently has keyboard focus by posting
/// synthetic keyboard events carrying Unicode strings. This does not touch the
/// clipboard. Requires Accessibility permission.
final class TextInjector {
    func inject(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)

        // keyboardSetUnicodeString is reliable in small chunks, so split the
        // text into runs of UTF-16 code units.
        let units = Array(text.utf16)
        let chunkSize = 16
        var index = 0

        while index < units.count {
            let end = min(index + chunkSize, units.count)
            var chunk = Array(units[index..<end])

            // The virtual key code is ignored once a Unicode string is set.
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                keyDown.post(tap: .cghidEventTap)
            }
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                keyUp.post(tap: .cghidEventTap)
            }

            index = end
            usleep(2000) // small gap so fast apps don't drop events
        }
    }
}
