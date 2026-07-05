<p align="center">
  <img src="Assets/banner.png" alt="zwisp" width="620">
</p>

**Private, on-device dictation for macOS.** Hold your push-to-talk key
(Right ⌘ by default), talk, release — your speech is transcribed locally and
typed into whatever app is focused. An open-source, local-first alternative to
hosted dictation tools like Wispr Flow: the same hold-a-key-anywhere workflow,
but nothing leaves your Mac, and no account is required. The only network
access is a one-time download of the speech model.

[![CI](https://github.com/zjsolomon/zwisp/actions/workflows/ci.yml/badge.svg)](https://github.com/zjsolomon/zwisp/actions/workflows/ci.yml)
![Status](https://img.shields.io/badge/status-beta-yellow)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/swift-5.9%2B-orange)
![License](https://img.shields.io/badge/license-MIT-green)

> **Beta.** zwisp works for day-to-day dictation, but it's young: expect
> rough edges, and defaults or behaviour may still change between versions.
> [Bug reports](https://github.com/zjsolomon/zwisp/issues) are very welcome.

## Quick start

```bash
git clone https://github.com/zjsolomon/zwisp.git
cd zwisp && ./install.sh    # builds, installs to /Applications, launches
```

Needs an Apple Silicon Mac on macOS 14+ and a Swift toolchain
(`xcode-select --install`). macOS will then ask for a few one-time
permissions — see [First-run setup](#first-run-setup-one-time).

```
key held  ──►  record mic (16 kHz)  ──►  release  ──►  WhisperKit (on-device)  ──►  types text
       menu bar:  🔴 warming up   🟢 ready   🔵 ready + AI cleanup
```

## Features

- **Works everywhere** — types into any app that accepts keyboard input, via
  synthetic key events, so it never touches or clobbers your clipboard.
- **Your keys** — Right ⌘ by default; bind any modifier key you like, even
  several at once.
- **Optional AI cleanup** — pipe the raw transcript through a local LLM
  ([Ollama](https://ollama.com)) to remove filler words, apply self-corrections,
  and fix punctuation — still fully offline, with guardrails so a bad model
  response never replaces your words.
- **Personal dictionary** — teach zwisp names and terms it keeps mishearing
  ("Ziedo", "zwisp", "Ollama") via the menu-bar **Dictionary** menu. Future
  dictations use your exact spelling.
- **Lives in the menu bar** — no Dock icon and no windows. Can launch at login.
- **Small codebase** — a compact, dependency-light Swift project that is
  straightforward to read and audit.

## Installation

There's no notarized download yet, so you build it once from source — the two
commands in [Quick start](#quick-start) are the whole install. You'll need:

- an Apple Silicon Mac running macOS 14 (Sonoma) or later,
- a Swift toolchain — Xcode, or the Command Line Tools
  (`xcode-select --install`).

`./install.sh` builds the app, copies it to `/Applications`, and launches it.
The first launch walks you through a one-time permission setup (below). Once
running, click the 🎙️ menu-bar icon → **Launch at Login** if you'd like it to
start automatically on every boot — you can toggle that off there any time.

> Prefer not to install into `/Applications`? Run `./build-app.sh` to produce
> `zwisp.app` in the project folder and `open zwisp.app` from there.

## First-run setup (one time)

macOS gates microphone access, global hotkeys, and synthetic typing behind
separate privacy permissions, and zwisp also needs to fetch its speech model.
**zwisp opens a guided setup on first launch** that walks through all of it: one
button per permission (each row flips to ✓ as you grant it), a live-progress
download of the speech model, and — optionally — a one-click install of Ollama
plus the recommended cleanup model. The guide tells you when you're ready to
dictate. Closed it early? Reopen it any time via the menu-bar icon → **Setup
Guide…**.

For reference, the three permissions it walks you through:

1. **Microphone** — records your voice while you hold the key. Click **Allow…**
   in the guide (or macOS prompts on your first dictation).
2. **Input Monitoring** — System Settings → Privacy & Security → **Input
   Monitoring** → enable **zwisp**. Required to detect your push-to-talk key
   globally.
3. **Accessibility** — System Settings → Privacy & Security → **Accessibility** →
   enable **zwisp**. Required to type the transcribed text into other apps.

The menu-bar icon turns orange until the hotkey permissions are granted — hover
it to see which one is still missing. zwisp watches for the grant and starts
working within a couple of seconds — no relaunch needed. The shortcuts in the
menu jump you straight to each Settings pane.

The setup window downloads the speech model from Hugging Face for you (the
default `large-v3-turbo` is ~1.5 GB; lighter models are much smaller — see
[Configuration](#configuration)), showing progress as it goes. That's the only
download dictation needs; afterwards it runs fully offline. Want AI cleanup too?
The setup window's optional **AI cleanup** section installs Ollama (from the
official signed build, signature-verified before it's trusted) and pulls the
recommended model — or you can bring your own Ollama and pick a different model
later from Settings → Cleanup.

## Usage

- Hold your **push-to-talk key** (Right ⌘ by default), speak, then release. The
  text is typed at your cursor.
- You can keep working while it thinks: dictations queue up and are typed in
  order. Injection politely waits until your hands are still (no keys for a
  moment, no modifier held), and if you've switched to a different app in the
  meantime it skips typing rather than dumping text into the wrong window
  (logged in `~/Library/Logs/zwisp.log`).
- Click the menu-bar icon for hotkey settings, permission shortcuts, AI cleanup
  (on/off and model choice), Launch at Login, and Quit.

### What the icon colours mean

| Icon | Meaning |
|---|---|
| 🔴 Red | Warming up — the speech model is still loading (a few seconds after launch). Dictation is ignored until this clears. |
| 🟢 Green | Ready to dictate. AI cleanup is off or unavailable, so you get the raw transcript. |
| 🔵 Blue | Ready to dictate, and AI cleanup is active — transcripts get cleaned up by your Ollama model. |
| ⚪ Grey | Transcribing a dictation you just finished. |
| 🟠 Orange | Permissions missing — hover the icon to see which, and use the menu's **Setup Guide…**. See [First-run setup](#first-run-setup-one-time). |

While you're recording, zwisp's own icon doesn't change: macOS shows its
orange microphone indicator in the menu bar whenever the mic is live, and
that's the recording signal. Hovering the zwisp icon shows the current state
in words.

### Changing hotkeys

Click the menu-bar icon → **Hotkeys**:

- **Add** — choose **Add Hotkey…**, then press the modifier key you want. It's
  registered instantly.
- **Remove** — click any listed key to remove it.
- **Multiple keys** — add as many as you like; holding *any* of them records.

Only modifier keys (⌘ ⌥ ⌃ ⇧ and Fn 🌐) can be hotkeys — you hold one to talk, and
modifiers don't type characters or auto-repeat while held. Left and right
modifiers are distinct, so you can bind Right ⌘ without affecting Left ⌘.

### Personal dictionary

Whisper spells names it has never seen however it pleases. When a dictation
comes out with "zeddo" instead of "Ziedo":

- **Add a word** — menu-bar icon → **Dictionary** → **Add Word…**, and type
  the spelling you want (up to 4 words, e.g. a full name).
- **Review / remove** — the same **Dictionary** menu lists your words; click
  one to remove it.

Dictionary words steer dictations two ways: the AI cleanup model is told your
exact spellings, and a built-in corrector fixes close mishearings ("zeddo" →
"Ziedo", "oh llama" → "Ollama") even when cleanup is off. Entries are
short terms — a name or phrase of at most 4 words — and everything stays on
your Mac, like the rest of zwisp.

## Optional: AI cleanup with Ollama

Raw speech-to-text is literal: it keeps filler words and false starts, and often
lacks punctuation. zwisp can optionally pass each transcript through a local
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
ollama pull qwen3:4b-instruct    # ~2.5 GB, one time
```

If Ollama is installed but not running, the menu shows **"Ollama isn't running —
click to start"**, which launches it for you (the Ollama app if you have it,
otherwise `ollama serve`).

Then leave **AI Cleanup (Ollama) → Clean Up Transcripts** enabled in the menu
(it's on by default). The same submenu lists your installed Ollama models —
click one to use it for cleanup.

### Which model?

Benchmarked on zwisp's own cleanup battery (Apple Silicon, warm model,
median per-dictation latency):

| Model | Size | Median | Notes |
|---|---|---|---|
| `qwen3:4b-instruct` | 2.5 GB | ~0.7 s | **Default.** Best punctuation and fidelity; question marks and commas consistently right. |
| `llama3.2:3b` | 2.0 GB | ~0.5 s | Fastest; occasional comma/question-mark slips. |
| `gemma3:4b` | 3.3 GB | ~2.5 s | Excellent fidelity, but noticeably slow, and outputs typographic (curly) quotes. |

Avoid `phi4-mini` (paraphrases the speaker) and thinking-mode models like
`deepseek-r1` (reasoning latency; zwisp suppresses thinking where the model
allows it, but non-thinking instruct models are the right tool).

Guardrails make cleanup fail-safe — dictation always works, and a bad model
response never replaces your words.

<details>
<summary>How the guardrails work</summary>

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

</details>

## Configuration

All tunable settings live in one file:
[`Sources/ZwispCore/Configuration.swift`](Sources/ZwispCore/Configuration.swift).

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
swift test           # fast: runs the ZwispCore test suite (Swift Testing)
swift build          # builds the full app (compiles WhisperKit; slower)
```

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs the tests and a
release build on every push and pull request.

### Architecture

**`ZwispCore`** — pure domain logic, no external dependencies:

| File | Responsibility |
|------|----------------|
| `Configuration.swift` | All tunable settings in one place |
| `MenuBarState.swift` | Menu-bar state + pure state derivation |
| `Hotkey.swift` | The push-to-talk modifier keys and their flag masks |
| `HotkeyStore.swift` | Persists the user's hotkeys (add/remove) |
| `CleanupService.swift` | Optional local LLM cleanup pass via Ollama |
| `StreamingTranscript.swift` | Confirms stable segments during eager (streaming) transcription |
| `AudioPadding.swift` | Pads sub-second recordings past WhisperKit's decode floor |
| `TextInjector.swift` | Types transcribed text into the focused app |
| `TranscriptFormatter.swift` | Joins WhisperKit segments into text |
| `Logger.swift` | Append-to-file logger |

**`zwisp`** — the app: system-framework and WhisperKit glue on top of the core:

| File | Responsibility |
|------|----------------|
| `main.swift` | App entry, runs as a menu-bar (accessory) app |
| `AppDelegate.swift` | Wires everything together, owns the status item |
| `HotkeyMonitor.swift` | Global `CGEventTap` watching the configured modifiers |
| `HotkeyCapturePanel.swift` | "Press a key" panel for adding a hotkey |
| `AudioRecorder.swift` | `AVAudioEngine` capture, resampled to 16 kHz mono |
| `Transcriber.swift` | WhisperKit wrapper (on-device speech-to-text), serialized |
| `StreamingWorker.swift` | Eagerly transcribes the growing buffer while the key is held |

## Limitations

- Transcription streams **while you hold the key** (audio is transcribed and
  confirmed in the background as you speak), but the text only appears after
  you release — there's no live-preview overlay yet.
- The app is ad-hoc / self-signed, so permissions are tied to a specific build;
  rebuilding may occasionally require re-granting Accessibility. See
  [`setup-signing.sh`](setup-signing.sh) for a stable local signing identity that
  avoids this.

## Contributing

Issues and pull requests are welcome. Please run `swift test` before opening a
PR, and keep the core logic in `ZwispCore` (with a test) so it stays covered
by CI.

## Acknowledgements

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax for on-device
  Whisper inference.
- [Ollama](https://ollama.com) for running local LLMs.

## License

[MIT](LICENSE) © Ziedo Solomon
