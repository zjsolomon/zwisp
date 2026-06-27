# Zwhisper

A tiny, local "Wispr Flow"-style dictation tool for macOS.

**Hold the `Fn` (🌐) key, talk, release.** Your speech is transcribed
on-device with [WhisperKit](https://github.com/argmaxinc/WhisperKit) and typed
into whatever app is focused. No cloud, no account, no clipboard clobbering.

```
Fn held  ──►  record mic (16 kHz)  ──►  release  ──►  WhisperKit (on-device)  ──►  types text
            menu bar:  🎙️ idle   🔴 recording   💭 thinking
```

## Requirements

- Apple Silicon Mac, macOS 14+
- Swift toolchain (Xcode or Command Line Tools — `xcode-select --install`)

## Install (recommended)

```bash
./install.sh          # builds, copies to /Applications, launches
```

Then click the 🎙️ icon in the **menu bar** (top-right of the screen, by the
battery/clock) → **Launch at Login** to have it start automatically on every
boot. Toggle it off there any time.

## Build only (for development)

```bash
./build-app.sh        # produces Zwhisper.app in this folder
open Zwhisper.app
```

(For quick iteration you can also `swift build && swift run`, but microphone,
menu-bar, and launch-at-login behavior work best from the installed `.app`.)

## First-run setup (one time)

1. **Microphone** — macOS prompts on first launch. Allow it.
2. **Accessibility** — System Settings → Privacy & Security → **Accessibility** →
   enable **Zwhisper**. This is required both to detect the Fn key and to type
   text into other apps. The menu-bar icon shows ⚠️ until this is granted; quit
   and relaunch after granting.
3. **Free up the Fn key (recommended)** — System Settings → Keyboard →
   "Press 🌐 key to" → **Do Nothing**. Otherwise Fn may also open the emoji
   picker or switch input source.
4. **First transcription** downloads the model (~150 MB for `base.en`) from
   Hugging Face — needs internet *once*. After that it runs fully offline.

## Usage

- Hold **Fn**, speak, release. The text is typed at your cursor.
- Click the menu-bar icon for settings shortcuts and Quit.

## AI cleanup (optional, fully local)

Raw speech-to-text is literal — it keeps "um"s, false starts, and missing
punctuation. Zwhisper can pipe the transcript through a local LLM that rewrites
it into clean written text (this is the main thing that makes commercial tools
like Wispr Flow feel polished).

This runs **locally and offline** via [Ollama](https://ollama.com) — no API key,
nothing leaves your machine. Setup:

```bash
brew install ollama        # or download from ollama.com
ollama serve               # starts the local server (also runs as a login service)
ollama pull llama3.2:3b    # ~2GB, one time
```

Then enable **"Clean up with AI (Ollama)"** in the menu (on by default). If
Ollama isn't running, Zwhisper silently falls back to the raw transcript, so
dictation always works. Change the model in `CleanupService.swift` (`model`).

## Customizing

Tunable knobs live in one place: `Sources/ZwhisperCore/Configuration.swift`.

- **Model** — `whisperModel` in `Configuration.default`. Default is
  `openai_whisper-large-v3-v20240930_turbo` (high accuracy, fast). Lighter options:
  - `distil-whisper_distil-large-v3_turbo` — smaller, English-leaning
  - `openai_whisper-small.en` — much smaller, lower accuracy
  - `openai_whisper-base.en` — tiny, fastest
- **Cleanup model / prompt / endpoint** — the `Cleanup` struct in the same file.
- **Hotkey** — Fn is detected in `FnKeyMonitor.swift` via the
  `.maskSecondaryFn` flag. To use a different modifier, change the flag check
  there.
- **Paste instead of type** — `TextInjector.swift` types via synthetic Unicode
  key events. Swap for a pasteboard + ⌘V approach if you prefer.

## Development

The code is split into a dependency-free core library and a thin app on top,
so the pure logic is unit-tested without pulling in WhisperKit/CoreML:

```bash
swift test           # runs the ZwhisperCore test suite (Swift Testing)
swift build          # builds the app (compiles WhisperKit; slower)
```

CI (`.github/workflows/ci.yml`) runs both on every push and pull request.

## How it works

`ZwhisperCore` (pure domain logic, no external dependencies):

| File | Responsibility |
|------|----------------|
| `Configuration.swift` | All tunable settings in one place |
| `MenuBarState.swift` | Menu-bar state + pure state derivation |
| `CleanupService.swift` | Optional local LLM cleanup pass via Ollama |
| `TextInjector.swift` | Types transcribed text into the focused app |
| `TranscriptFormatter.swift` | Joins WhisperKit segments into text |
| `Logger.swift` | Append-to-file logger |

`Zwhisper` (the app — system-framework and WhisperKit glue):

| File | Responsibility |
|------|----------------|
| `main.swift` | App entry, runs as a menu-bar (accessory) app |
| `AppDelegate.swift` | Wires everything together, owns the status item |
| `FnKeyMonitor.swift` | Global `CGEventTap` watching the Fn modifier |
| `AudioRecorder.swift` | `AVAudioEngine` capture, resampled to 16 kHz mono |
| `Transcriber.swift` | WhisperKit wrapper (on-device speech-to-text) |

## Notes / limitations

- Transcription happens **after** you release Fn (batch, not live streaming).
  WhisperKit also supports streaming if you want lower latency later.
- Ad-hoc code signing means permissions are tied to this exact build;
  rebuilding may occasionally require re-granting Accessibility.

## License

[MIT](LICENSE) © Ziedo Solomon
