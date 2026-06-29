import AppKit

// Zwhisper: hold the Fn (🌐) key, talk, and the transcribed text is typed
// into whatever app is focused. Transcription runs fully on-device via WhisperKit.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .accessory = menu-bar app, no Dock icon, no main window.
app.setActivationPolicy(.accessory)
app.run()
