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
  `SetupState.swift` (composes the permission checklist with the three `InstallPhase`s +
  chain-button copy), `OllamaPull.swift` (tolerant `/api/pull` JSON-lines parser +
  monotonic progress accumulator), `SpeechModelLayout.swift` (WhisperKit's on-disk model
  path + completeness check), `Hotkey.swift`, `HotkeyStore.swift`, `CleanupService.swift`
  (Ollama cleanup; also the `pullModel` streaming seam), `DictionaryStore.swift` (personal
  dictionary persistence), `TranscriptCorrector.swift` (deterministic dictionary post-pass),
  `StreamingTranscript.swift` (streaming confirmation state machine), `AudioPadding.swift`,
  `TextInjector.swift`, `TranscriptFormatter.swift`, `Logger.swift`.
- **`Sources/zwisp/`** — the executable: system-framework + WhisperKit glue on top of the
  core. Not unit-tested. Files: `main.swift`, `AppDelegate.swift` (wires everything, owns the
  status item; `@MainActor`), `HotkeyMonitor.swift` (global `CGEventTap`),
  `HotkeyCapturePanel.swift`, `AudioRecorder.swift` (`AVAudioEngine` → 16 kHz mono Float32),
  `Transcriber.swift` (WhisperKit wrapper; an actor that serializes all WhisperKit calls —
  now takes a ready `modelFolder`, the installer owns the download), `StreamingWorker.swift`
  (eager transcription loop while the key is held), `PermissionProbe.swift` (live permission
  status + Settings deep links), `SpeechModelInstaller.swift` (downloads the WhisperKit model
  with progress), `OllamaInstaller.swift` (installs Ollama + pulls the cleanup model),
  `SetupWindow.swift`/`SetupModel.swift`/`SetupView.swift` (the SwiftUI first-run setup trio,
  replacing the old `OnboardingWindow`).
- **`Tests/ZwispCoreTests/`** — tests for the core library only.

**Rule (from README/Contributing): new logic goes in `ZwispCore` with a test** so it stays
covered by CI. The app layer should stay a thin glue layer.

## Gotchas

- **Three separate macOS permissions**, easy to confuse: **Microphone** (record), **Input
  Monitoring** (CGEventTap to *receive* the hotkey), **Accessibility** (to *type* text into
  other apps). **Launch no longer fires permission prompts** — they're user-initiated from
  the setup window (`SetupWindow`/`SetupModel`/`SetupView`, a SwiftUI trio; reopenable via the
  menu's "Setup Guide…"), and the mic prompt fires on the first dictation attempt. The setup
  window is now all-encompassing, not just a permission checklist: it also **downloads the
  speech model with visible progress** (`SpeechModelInstaller` → `WhisperKit.download`, then
  `Transcriber(modelFolder:)` — the app no longer relies on WhisperKit's invisible first-use
  fetch), and offers an **optional AI-cleanup chain** (`OllamaInstaller`): install Ollama from
  the official signed zip (`ditto -xk`, then `codesign --verify --deep --strict` + bundle-ID
  check *before* it's ever launched — never strip quarantine, never `spctl`), start its
  server, and pull the recommended cleanup model via `/api/pull` streaming
  (`CleanupService.pullModel` + core `OllamaPull`). **Auto-show gate = hotkey permissions
  missing OR the speech model isn't on disk** (`permissions.needsSetup ||
  speechInstaller.installedFolder() == nil`); Ollama/cleanup missing alone **never** auto-shows
  (it's optional — don't nag about a multi-GB download). Live status checks + deep links live
  in `PermissionProbe.swift`; the pure checklist model (`OnboardingState`, row copy,
  `needsSetup`) plus `SetupState`/`InstallPhase`/`SpeechModelLayout`/`OllamaPull` live in core
  with tests. `AppDelegate` is `@MainActor` (it owns the main-actor installers + setup window).
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
- **Personal dictionary lives in the cleanup *system* prompt** (rendered by
  `Configuration.Cleanup.systemPrompt(base:dictionary:style:)`) so `warmUp(style:)` prefills it
  once — and any dictionary *or writing-style* change invalidates that KV cache, so `AppDelegate`
  must re-fire `cleanup.warmUp(style:)` after it (`AppDelegate.rewarmCleanup()`, called after every
  dictionary add/remove and from the Settings `stylesChanged` action; `refreshCleanupStatus` won't:
  it only warms on a status *transition*). The deterministic `TranscriptCorrector` pass is applied at exactly one
  seam — after `cleanup.clean` in `AppDelegate.process` — which covers batch, streamed,
  cleanup-off, and every fallback path; don't add a second application site. Its thresholds
  are deliberately conservative (short entries never fuzzy-match) — a wrong "correction" is
  worse than a missed one. Words are added/removed from the menu-bar Dictionary menu
  (`rebuildDictionaryMenu` / `addDictionaryWordClicked` in `AppDelegate`). **A system-wide
  right-click macOS Service was tried and abandoned** (2026-07): registration looked correct
  in `pbs -dump_pboard`, but the item never surfaced in any app's Services menu even after
  `pbs -flush`, enabling it in `pbs NSServicesStatus`, and assigning shortcuts — don't
  re-attempt Services without new evidence (also beware: macOS Sequoia's window tiling
  claimed most ⌃⌥⌘ shortcut combos, and Services can't tell left/right modifiers apart).
- **Per-app writing styles** steer cleanup into `.standard`/`.formal`/`.casual` per frontmost app.
  All steering is in the cleanup *system* prompt: the style `promptBlock` is appended **LAST**
  (after the base prompt and the dictionary block) so Ollama's longest-common-prefix KV reuse
  reprefills only the short style suffix on a switch — keep that ordering in
  `Configuration.Cleanup.systemPrompt`. Style is `WritingStyle` + `StyleRuleStore`/`StyleResolver`
  (core, tested); rules match on bundle ID plus an optional window-title substring (a title rule
  beats a bare rule). The style is **resolved once at record time** in `AppDelegate.stopAndTranscribe`
  via `FrontmostContext.capture()` (app layer: `NSWorkspace` + the Accessibility API for the focused
  window title — any AX failure degrades to `windowTitle = nil`, never prompts) and threaded through
  `process(…style:)` → `cleanup.clean(_:style:)`, so a focus change mid-transcription can't apply the
  wrong style. To keep the prefill off the dictation's critical path, `AppDelegate` **warms the style
  ahead of time**: `scheduleStyleRewarmIfNeeded()` on `NSWorkspace.didActivateApplicationNotification`
  (debounced ~1 s) plus an eager warm at `startRecording` (covers browser-tab/title-rule changes the
  app-switch notification can't see). `currentResolvedStyle()` **short-circuits to `.standard` with no
  AX call** when there are no rules and the default is standard — the default setup pays nothing.
  `lastWarmedStyle` tracks what's prefilled; only a *changed* style triggers a warm.
- **Settings window** (`SettingsWindow`/`SettingsModel`/`SettingsView`) is the one place to manage
  hotkeys, cleanup, dictionary, and writing-style rules — SwiftUI in an `NSHostingController`, same
  accessory-app lifecycle as `OnboardingWindow`. It's `@MainActor`; `AppDelegate` holds it as a
  `@MainActor private lazy var` and talks to it only through the **frozen `SettingsWindow.Actions`
  API** (closures back into `AppDelegate` for the actual mutations, so menu and window share one code
  path — e.g. `presentAddHotkey`, `removeHotkey`, `setLaunchAtLogin`). Opened from the menu-bar
  "Settings…" item (⌘,). The old submenus still work.
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
