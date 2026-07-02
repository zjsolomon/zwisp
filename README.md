<p align="center">
  <img src="Assets/logo.png" alt="Zwhisper logo" width="160" height="160">
</p>

<h1 align="center">Zwhisper</h1>

**Private, on-device dictation for macOS.** Hold your push-to-talk key
(Right ⌘ by default), talk, release — your speech is transcribed locally and
typed into whatever app is focused. Everything runs on your Mac; nothing is sent
to a server, and no account is required. The only network access is a one-time
download of the speech model.

[![CI](https://github.com/zjsolomon/Zwhisper/actions/workflows/ci.yml/badge.svg)](https://github.com/zjsolomon/Zwhisper/actions/workflows/ci.yml)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/swift-5.9%2B-orange)
![License](https://img.shields.io/badge/license-MIT-green)

Zwhisper is an open-source, local-first alternative to hosted dictation tools
such as Wispr Flow. It provides the same hold-a-key-anywhere workflow, but
transcription runs on-device instead of in the cloud.

```
key held  ──►  record mic (16 kHz)  ──►  release  ──►  WhisperKit (on-device)  ──►  types text
            menu bar:  🎙️ idle   🔴 recording   💭 thinking
```

## Features

- **Fully on-device** — transcription runs locally via
  [WhisperKit](https://github.com/argmaxinc/WhisperKit); your voice never
  touches a server.
- **Works everywhere** — types into any app that accepts keyboard input. It uses
  synthetic key events, so it never touches or clobbers your clipboard.
- **Push-to-talk** — hold your key, speak, release. No wake word, no window to
  click. Right ⌘ by default, and you can set your own — even several at once.
- **Optional AI cleanup** — pipe the raw transcript through a local LLM
  ([Ollama](https://ollama.com)) to remove filler words, apply self-corrections,
  and fix punctuation — still fully offline, with guardrails so a bad model
  response never replaces your words.
- **Lives in the menu bar** — no Dock icon and no windows. Can launch at login.
- **Small codebase** — a compact, dependency-light Swift project that is
  straightforward to read and audit.

## Requirements

- Apple Silicon Mac running macOS 14 (Sonoma) or later
- A Swift toolchain to build from source — Xcode, or the Command Line Tools
  (`xcode-select --install`)

There's no notarized download yet, so you build it once from source (a single
command). Everything below assumes you've cloned the repo:

```bash
git clone https://github.com/zjsolomon/Zwhisper.git
cd Zwhisper
```

## Installation

```bash
./install.sh          # builds the app, copies it to /Applications, and launches it
```

The first launch walks you through a one-time permission setup (below). Once
running, click the 🎙️ menu-bar icon → **Launch at Login** if you'd like it to
start automatically on every boot — you can toggle that off there any time.

> Prefer not to install into `/Applications`? Run `./build-app.sh` to produce
> `Zwhisper.app` in the project folder and `open Zwhisper.app` from there.

## First-run setup (one time)

macOS gates microphone access, global hotkeys, and synthetic typing behind
separate privacy permissions. Grant these once:

1. **Microphone** — macOS prompts on first launch. Click **Allow**.
2. **Input Monitoring** — System Settings → Privacy & Security → **Input
   Monitoring** → enable **Zwhisper**. Required to detect the `Fn` key globally.
3. **Accessibility** — System Settings → Privacy & Security → **Accessibility** →
   enable **Zwhisper**. Required to type the transcribed text into other apps.

The menu-bar icon turns orange until the hotkey permissions are granted. Zwhisper
watches for the grant and starts working within a couple of seconds — no relaunch
needed. The shortcuts in the menu jump you straight to each Settings pane.

On first use, Zwhisper downloads the speech model from Hugging Face (the default
`large-v3-turbo` is ~1.5 GB; lighter models are much smaller — see
[Configuration](#configuration)). That's the only time it needs the internet;
afterwards it runs fully offline.

## Usage

- Hold your **push-to-talk key** (Right ⌘ by default), speak, then release. The
  text is typed at your cursor.
- Click the menu-bar icon for hotkey settings, permission shortcuts, AI cleanup
  (on/off and model choice), Launch at Login, and Quit.

### Changing hotkeys

Click the menu-bar icon → **Hotkeys**:

- **Add** — choose **Add Hotkey…**, then press the modifier key you want. It's
  registered instantly.
- **Remove** — click any listed key to remove it.
- **Multiple keys** — add as many as you like; holding *any* of them records.

Only modifier keys (⌘ ⌥ ⌃ ⇧ and Fn 🌐) can be hotkeys — you hold one to talk, and
modifiers don't type characters or auto-repeat while held. Left and right
modifiers are distinct, so you can bind Right ⌘ without affecting Left ⌘.

## Optional: AI cleanup with Ollama

Raw speech-to-text is literal: it keeps filler words and false starts, and often
lacks punctuation. Zwhisper can optionally pass each transcript through a local
LLM that edits it into properly punctuated written text. This runs entirely on
your machine.

The cleanup follows a **conservation rule: what you said is what gets written.**
It never paraphrases, summarises, or "improves" your wording — discourse phrases
like "okay, let's see here" are your voice and stay in. It only:

- removes non-word fillers (um, uh, er) and stutters ("the the" → "the"),
- applies explicit self-corrections ("three no wait four" → "four"),
- converts spoken punctuation ("comma" → ","), quoting ("quote … end quote" →
  quotation marks), numbers and times ("five thirty pm" → "5:30 PM"), and
  dictated enumerations ("number one … number two …" → "1. … 2. …"),
- fixes capitalisation and sentence punctuation.

It uses [Ollama](https://ollama.com), which needs no API key and keeps everything
local:

```bash
brew install ollama        # or download from ollama.com
ollama serve               # start the local server (also runs as a login service)
ollama pull llama3.2:3b    # ~2 GB, one time
```

Then leave **AI Cleanup (Ollama) → Clean Up Transcripts** enabled in the menu
(it's on by default). The same submenu lists your installed Ollama models —
click one to use it for cleanup.

### Which model?

Benchmarked on Zwhisper's own cleanup battery (Apple Silicon, warm model,
median per-dictation latency):

| Model | Size | Median | Notes |
|---|---|---|---|
| `qwen3:4b-instruct` | 2.5 GB | ~0.7 s | **Recommended.** Best punctuation and fidelity; question marks and commas consistently right. |
| `llama3.2:3b` | 2.0 GB | ~0.5 s | Default. Fastest; occasional comma/question-mark slips. |
| `gemma3:4b` | 3.3 GB | ~2.5 s | Excellent fidelity, but noticeably slow, and outputs typographic (curly) quotes. |

Avoid `phi4-mini` (paraphrases the speaker) and thinking-mode models like
`deepseek-r1` (reasoning latency; Zwhisper suppresses thinking where the model
allows it, but non-thinking instruct models are the right tool).

Guardrails make the pass off-by-default-safe — dictation always works:

- If Ollama isn't running or errors, the raw transcript is used unchanged.
- The model is asked not to reason out loud (`think: false`), and any
  chain-of-thought that slips through (`<think>…</think>`) is stripped.
- Output is sanity-checked before it's typed: added preambles ("Here is the
  cleaned text:"), wrapping quotes, echoed delimiters, and stray end-tokens are
  stripped, and an output that balloons past the input (the model "answering"
  the dictation instead of cleaning it) is discarded in favour of the raw
  transcript.
- The conservation rule is enforced in code, not just prompted: if the model's
  output drops too many of the words you actually said, it's treated as a
  paraphrase and discarded — the raw transcript is typed instead.
- Generation is capped relative to input length, and the model is kept warm
  between dictations so cleanup stays fast.

## Configuration

All tunable settings live in one file:
[`Sources/ZwhisperCore/Configuration.swift`](Sources/ZwhisperCore/Configuration.swift).

- **Speech model** — `whisperModel`. Default `openai_whisper-large-v3-v20240930_turbo`
  (high accuracy, fast on Apple Silicon). Lighter alternatives:
  - `distil-whisper_distil-large-v3_turbo` — smaller, English-leaning
  - `openai_whisper-small.en` — much smaller, lower accuracy
  - `openai_whisper-base.en` — tiny and fastest
- **AI cleanup** — the `Cleanup` struct sets the default Ollama model, prompt,
  endpoint, timeout, keep-alive, and output-length budget. The active model is
  picked from the menu (AI Cleanup → model list).
- **Hotkeys** — configured from the menu bar (see
  [Changing hotkeys](#changing-hotkeys)); the default is defined by
  `HotkeyStore.defaultHotkeys`.
- **Paste instead of type** — `TextInjector.swift` types via synthetic Unicode
  key events. Swap it for a pasteboard + ⌘V approach if you prefer.

## Development

The code is split into a dependency-free core library and a thin app layer, so
the pure logic is unit-tested without pulling in WhisperKit / CoreML:

```bash
swift test           # fast: runs the ZwhisperCore test suite (Swift Testing)
swift build          # builds the full app (compiles WhisperKit; slower)
```

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs the tests and a
release build on every push and pull request.

### Architecture

**`ZwhisperCore`** — pure domain logic, no external dependencies:

| File | Responsibility |
|------|----------------|
| `Configuration.swift` | All tunable settings in one place |
| `MenuBarState.swift` | Menu-bar state + pure state derivation |
| `Hotkey.swift` | The push-to-talk modifier keys and their flag masks |
| `HotkeyStore.swift` | Persists the user's hotkeys (add/remove) |
| `CleanupService.swift` | Optional local LLM cleanup pass via Ollama |
| `TextInjector.swift` | Types transcribed text into the focused app |
| `TranscriptFormatter.swift` | Joins WhisperKit segments into text |
| `Logger.swift` | Append-to-file logger |

**`Zwhisper`** — the app: system-framework and WhisperKit glue on top of the core:

| File | Responsibility |
|------|----------------|
| `main.swift` | App entry, runs as a menu-bar (accessory) app |
| `AppDelegate.swift` | Wires everything together, owns the status item |
| `HotkeyMonitor.swift` | Global `CGEventTap` watching the configured modifiers |
| `HotkeyCapturePanel.swift` | "Press a key" panel for adding a hotkey |
| `AudioRecorder.swift` | `AVAudioEngine` capture, resampled to 16 kHz mono |
| `Transcriber.swift` | WhisperKit wrapper (on-device speech-to-text) |

## Limitations

- Transcription runs **after** you release `Fn` (batch, not live streaming).
  WhisperKit supports streaming if you'd like to add lower-latency output.
- The app is ad-hoc / self-signed, so permissions are tied to a specific build;
  rebuilding may occasionally require re-granting Accessibility. See
  [`setup-signing.sh`](setup-signing.sh) for a stable local signing identity that
  avoids this.

## Contributing

Issues and pull requests are welcome. Please run `swift test` before opening a
PR, and keep the core logic in `ZwhisperCore` (with a test) so it stays covered
by CI.

## Acknowledgements

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax for on-device
  Whisper inference.
- [Ollama](https://ollama.com) for running local LLMs.

## License

[MIT](LICENSE) © Ziedo Solomon
