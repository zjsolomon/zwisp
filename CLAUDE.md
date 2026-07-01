# CLAUDE.md

Guidance for working in this repo. See `README.md` for the user-facing docs.

## What this is

Zwhisper is a **private, on-device push-to-talk dictation app for macOS** (menu-bar
accessory app, no Dock icon, no window). Hold a modifier key → record mic → release →
WhisperKit transcribes locally → text is typed into the focused app. Optional local-LLM
cleanup via Ollama. Nothing leaves the machine. Apple Silicon, macOS 14+, Swift 5.9+.

## Build & test

```bash
swift test              # FAST: runs ZwhisperCore unit tests only (no WhisperKit/CoreML). Do this first.
swift build             # Full app build; compiles WhisperKit — slow.
./build-app.sh [release|debug]   # Builds + wraps binary in Zwhisper.app + code-signs it.
./install.sh            # build-app.sh release, then copies to /Applications and launches.
```

- **Prefer `swift test` for iterating.** It only compiles `ZwhisperCore` + its tests, so it's
  fast and doesn't pull in WhisperKit/CoreML. CI (`.github/workflows/ci.yml`) runs `swift test`
  and a release `swift build` on every push/PR.
- Tests use the **Swift Testing** framework (`@Test`, `#expect`), which needs a Swift 6 /
  latest-stable toolchain.
- The app must run from a **signed `.app` bundle** (not the bare binary) for macOS to grant
  Microphone + Accessibility + Input Monitoring. That's why `build-app.sh` exists. Never run
  the raw `.build/*/Zwhisper` binary expecting permissions to work.

## Architecture: the core/app split matters

The codebase is deliberately split so pure logic is unit-tested without dragging in
WhisperKit/CoreML. **Keep this split when adding code.**

- **`Sources/ZwhisperCore/`** — pure domain logic, *zero external dependencies*. Unit-tested.
  Put testable logic here. Files: `Configuration.swift` (all tunable settings in one place),
  `MenuBarState.swift`, `Hotkey.swift`, `HotkeyStore.swift`, `CleanupService.swift` (Ollama
  cleanup), `TextInjector.swift`, `TranscriptFormatter.swift`, `Logger.swift`.
- **`Sources/Zwhisper/`** — the executable: system-framework + WhisperKit glue on top of the
  core. Not unit-tested. Files: `main.swift`, `AppDelegate.swift` (wires everything, owns the
  status item), `HotkeyMonitor.swift` (global `CGEventTap`), `HotkeyCapturePanel.swift`,
  `AudioRecorder.swift` (`AVAudioEngine` → 16 kHz mono Float32), `Transcriber.swift`
  (WhisperKit wrapper).
- **`Tests/ZwhisperCoreTests/`** — tests for the core library only.

**Rule (from README/Contributing): new logic goes in `ZwhisperCore` with a test** so it stays
covered by CI. The app layer should stay a thin glue layer.

## Gotchas

- **Three separate macOS permissions**, easy to confuse: **Microphone** (record), **Input
  Monitoring** (CGEventTap to *receive* the hotkey), **Accessibility** (to *type* text into
  other apps). `AppDelegate` prompts for all three on launch.
- **Only modifier keys** (⌘ ⌥ ⌃ ⇧ Fn) can be hotkeys — held while talking, don't auto-repeat.
  Left/right modifiers are distinct. Default is Right ⌘ (`HotkeyStore.defaultHotkeys`).
- `AudioRecorder.samples` is written on the realtime audio thread and read on main — guarded by
  an `NSLock`. Preserve that when touching it.
- Text is injected via **synthetic Unicode key events** (`TextInjector.swift`), *not* the
  clipboard — never clobbers the user's pasteboard. Don't "simplify" it to a ⌘V paste.
- Ollama cleanup is **off-by-default-safe**: if Ollama isn't running or errors, it falls back to
  the raw transcript. Keep that fallback intact — dictation must always work.
- WhisperKit downloads the model from Hugging Face on first use (internet once), then runs
  offline. Transcription is **batch on release**, not live streaming.
- Signing: `build-app.sh` prefers a stable self-signed identity (`setup-signing.sh`) so grants
  persist across rebuilds; falls back to ad-hoc, which may require re-granting Accessibility.

## Conventions

- Config lives in one place: `Sources/ZwhisperCore/Configuration.swift` (whisper model, audio,
  injection, cleanup). Change defaults there, not scattered constants.
- Run `swift test` before opening a PR.
