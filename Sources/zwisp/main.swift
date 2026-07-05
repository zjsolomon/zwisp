import AppKit

// zwisp: hold your push-to-talk key (Right ⌘ by default), talk, and the
// transcribed text is typed into whatever app is focused. Transcription runs
// fully on-device via WhisperKit.

// Top-level code runs on the main thread at program entry, but isn't formally
// main-actor-isolated — assert it so we can build the now-`@MainActor`
// `AppDelegate`. `app.run()` never returns, so this spans the whole lifetime.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // .accessory = menu-bar app, no Dock icon, no main window.
    app.setActivationPolicy(.accessory)
    app.run()
}
