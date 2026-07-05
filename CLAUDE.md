# CLAUDE.md

Guidance for working in this repo. See `README.md` for the user-facing docs.

## What this is

zwisp is a **private, on-device push-to-talk dictation app for macOS** (menu-bar
accessory app, no Dock icon, no window). Hold a modifier key → record mic → release →
WhisperKit transcribes locally → text is typed into the focused app. Optional local-LLM
cleanup via Ollama. Nothing leaves the machine. Apple Silicon, macOS 14+, Swift 5.9+.

## Build & test

```bash
swift test              # FAST: runs ZwispCore unit tests only (no WhisperKit/CoreML). Do this first.
swift build             # Full app build; compiles WhisperKit — slow.
./build-app.sh [release|debug]   # Builds + wraps binary in zwisp.app + code-signs it.
./install.sh            # build-app.sh release, then copies to /Applications and launches.
```

- **Prefer `swift test` for iterating.** It only compiles `ZwispCore` + its tests, so it's
  fast and doesn't pull in WhisperKit/CoreML. CI (`.github/workflows/ci.yml`) runs `swift test`
  and a release `swift build` on every push/PR.
- Tests use the **Swift Testing** framework (`@Test`, `#expect`), which needs a Swift 6 /
  latest-stable toolchain.
- The app must run from a **signed `.app` bundle** (not the bare binary) for macOS to grant
  Microphone + Accessibility + Input Monitoring. That's why `build-app.sh` exists. Never run
  the raw `.build/*/zwisp` binary expecting permissions to work.

## Architecture: the core/app split matters

The codebase is deliberately split so pure logic is unit-tested without dragging in
WhisperKit/CoreML. **Keep this split when adding code.**

- **`Sources/ZwispCore/`** — pure domain logic, *zero external dependencies*. Unit-tested.
  Put testable logic here. Files: `Configuration.swift` (all tunable settings in one place),
  `MenuBarState.swift`, `OnboardingState.swift` (permission checklist model + copy),
  `Hotkey.swift`, `HotkeyStore.swift`, `CleanupService.swift` (Ollama cleanup),
  `StreamingTranscript.swift` (streaming confirmation state machine), `AudioPadding.swift`,
  `TextInjector.swift`, `TranscriptFormatter.swift`, `Logger.swift`.
- **`Sources/zwisp/`** — the executable: system-framework + WhisperKit glue on top of the
  core. Not unit-tested. Files: `main.swift`, `AppDelegate.swift` (wires everything, owns the
  status item), `HotkeyMonitor.swift` (global `CGEventTap`), `HotkeyCapturePanel.swift`,
  `AudioRecorder.swift` (`AVAudioEngine` → 16 kHz mono Float32), `Transcriber.swift`
  (WhisperKit wrapper; an actor that serializes all WhisperKit calls), `StreamingWorker.swift`
  (eager transcription loop while the key is held), `PermissionProbe.swift` (live permission
  status + Settings deep links), `OnboardingWindow.swift` (first-run permission checklist).
- **`Tests/ZwispCoreTests/`** — tests for the core library only.

**Rule (from README/Contributing): new logic goes in `ZwispCore` with a test** so it stays
covered by CI. The app layer should stay a thin glue layer.

## Gotchas

- **Three separate macOS permissions**, easy to confuse: **Microphone** (record), **Input
  Monitoring** (CGEventTap to *receive* the hotkey), **Accessibility** (to *type* text into
  other apps). **Launch no longer fires permission prompts** — they're user-initiated from
  the onboarding window (`OnboardingWindow.swift`, auto-shown while a hotkey permission is
  missing; reopenable via the menu's "Setup Guide…"), and the mic prompt fires on the first
  dictation attempt. Live status checks + deep links live in `PermissionProbe.swift`; the
  pure checklist model (`OnboardingState`, row copy, `needsSetup`) lives in core with tests.
- **Only modifier keys** (⌘ ⌥ ⌃ ⇧ Fn) can be hotkeys — held while talking, don't auto-repeat.
  Left/right modifiers are distinct. Default is Right ⌘ (`HotkeyStore.defaultHotkeys`).
- **Fn/Globe needs keycode filtering**: arrow, Home/End, and Page keys also set the Fn flag bit,
  so `Hotkey.held`/`newlyPressed` only honour an Fn transition when the event's keycode is the Fn
  key (`fnKeyCode = 63`). Without it, pressing an arrow starts/stops recording. Preserve the check.
- `AudioRecorder.samples` is written on the realtime audio thread and read on main — guarded by
  an `NSLock`. Preserve that when touching it.
- Text is injected via **synthetic Unicode key events** (`TextInjector.swift`), *not* the
  clipboard — never clobbers the user's pasteboard. Don't "simplify" it to a ⌘V paste.
- Injection is **gated and queued, not immediate**: a finished dictation waits (via
  `Configuration.InjectionGate` / `AppDelegate.waitUntilSafeToType`) until the keyboard has been
  quiet *and* no modifier is held — the hotkey is itself a modifier, and typing with ⌘ down fires
  the target app's shortcuts. A `maxInjectionWait` cap keeps a job from being starved. Jobs run
  **strictly serial and in order** (chained through `pipelineTail`) and each remembers the
  frontmost app's PID at record time — if focus moved, the result is dropped, not typed into the
  wrong app. Don't make injection fire synchronously on release.
- Ollama cleanup is **on by default but fail-safe**: enabled unless the user turns it off
  (`CleanupService.enabled`, persisted), with *two* fallbacks to the raw transcript — Ollama
  unreachable/errors, and output that fails the guardrails in `CleanupService.sanitize` (the
  conservation rule: a cleanup that drops too many of the speaker's words is discarded). Keep both
  fallbacks intact — dictation must always work. The cleanup model is user-selectable from the menu
  (`availableModels()` lists what Ollama has); the pick is persisted and overrides the config default.
  `CleanupService.status()` (off/unavailable/active) drives the menu-bar colour via `MenuBarState`
  (red = model loading, green = ready raw-only, blue = ready + cleanup); `AppDelegate` re-checks it
  on toggle/model change, after each dictation, and on a 30 s poll. **Cleanup is kept warm**: the
  cold start (model load + prefill of the long system prompt) costs seconds and can blow the 8 s
  timeout, so `keep_alive` is negative (never unload) and `AppDelegate` fires
  `CleanupService.warmUp()` whenever status transitions to active. Per-stage timings go to
  `~/Library/Logs/zwisp.log` (transcribe/cleanup seconds, plus Ollama's load/prefill/generate
  breakdown) — check there first when dictation "feels slow".
- WhisperKit downloads the model from Hugging Face on first use (internet once), then runs
  offline. Transcription is **streamed while the key is held**: `StreamingWorker` re-transcribes
  the growing buffer (~1 s cadence) with `clipTimestamps` skipping confirmed audio, and
  `StreamingTranscript` (core, tested) confirms segments that ended ≥ 2 s before the live edge —
  segment *count* is no signal, continuous speech decodes as 1–2 segments. On release only the
  unconfirmed tail is transcribed. The stream state is advisory: any error falls back to the
  batch path, and `Configuration.Streaming.enabled` is the kill switch. All WhisperKit calls go
  through the `Transcriber` actor's serial queue — never call WhisperKit concurrently.
- **WhisperKit silently returns nothing for clips under ~1 s** (`windowClipTime` stops decoding
  1 s before the clip end). Recordings are padded with trailing silence to
  `Configuration.Audio.minimumTranscribableSamples` (1.4 s) in `Transcriber` — don't remove the
  padding, or quick dictations like "short one" vanish again.
- Signing: `build-app.sh` prefers a stable self-signed identity (`setup-signing.sh`) so grants
  persist across rebuilds; falls back to ad-hoc, which may require re-granting Accessibility.

## Conventions

- Config lives in one place: `Sources/ZwispCore/Configuration.swift` (whisper model, audio,
  injection, cleanup). Change defaults there, not scattered constants.
- Run `swift test` before opening a PR.
