import AppKit

/// Types text into whatever app currently has keyboard focus by posting
/// synthetic keyboard events carrying Unicode strings. This does not touch the
/// clipboard. Requires Accessibility permission.
public final class TextInjector {
    private let config: Configuration.Injection

    public init(config: Configuration.Injection = Configuration.Injection()) {
        self.config = config
    }

    public func inject(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)

        for var chunk in Self.chunks(of: text, size: config.chunkSize) {
            // The virtual key code is ignored once a Unicode string is set.
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                keyDown.post(tap: .cghidEventTap)
            }
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                keyUp.post(tap: .cghidEventTap)
            }
            usleep(config.interKeystrokeDelayMicroseconds) // small gap so fast apps don't drop events
        }
    }

    /// Splits `text` into runs of at most `size` UTF-16 code units.
    /// `keyboardSetUnicodeString` is only reliable in small chunks. Pure so it
    /// can be unit-tested (chunk boundaries, multi-code-unit emoji, empty input).
    static func chunks(of text: String, size: Int) -> [[UInt16]] {
        precondition(size > 0, "chunk size must be positive")
        let units = Array(text.utf16)
        var result: [[UInt16]] = []
        var index = 0
        while index < units.count {
            let end = min(index + size, units.count)
            result.append(Array(units[index..<end]))
            index = end
        }
        return result
    }
}
