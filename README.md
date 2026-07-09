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
  ("Ziedo", "zwisp", "WhisperKit"). Future dictations use your exact spelling.
- **Per-app writing styles** — cleanup can write formally in Mail and casually
  in Slack, chosen automatically from the app (and even the window title) you're
  dictating into.
- **Guided setup** — a first-run window walks through the permissions, downloads
  the speech model with visible progress, and can install Ollama and the cleanup
  model for you.
- **A dictation wave** — a small 8-bit equalizer floats on screen while you talk,
  so you can see the mic is hearing you. It never steals focus, and you can turn
  it off.
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
The first launch opens the guided setup (below). Once running, open **Settings…**
(⌘,) from the 🎙️ menu-bar icon and turn on **Launch at Login** if you'd like it
to start automatically on every boot.

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
  text is typed at your cursor. A small equalizer wave appears while you talk,
  and keeps pulsing while zwisp is still thinking.
- You can keep working while it thinks: dictations queue up and are typed in
  order. Injection politely waits until your hands are still (no keys for a
  moment, no modifier held), and if you've switched to a different app in the
  meantime it skips typing rather than dumping text into the wrong window
  (logged in `~/Library/Logs/zwisp.log`).
- **Settings…** (⌘, from the menu-bar icon) is where hotkeys, AI cleanup, the
  personal dictionary, and writing-style rules live. The menu itself keeps quick
  access to cleanup, the dictionary, permission shortcuts, the setup guide, and
  Quit.

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

**Settings… → General → Push-to-talk keys** (or the menu-bar **Hotkeys**
submenu):

- **Add** — choose **Add Hotkey…**, then press the modifier key you want. It's
  registered instantly.
- **Remove** — remove any listed key. The last one can't be removed.
- **Multiple keys** — add as many as you like; holding *any* of them records.

Only modifier keys (⌘ ⌥ ⌃ ⇧ and Fn 🌐) can be hotkeys — you hold one to talk, and
modifiers don't type characters or auto-repeat while held. Left and right
modifiers are distinct, so you can bind Right ⌘ without affecting Left ⌘.

### Personal dictionary

Whisper spells names it has never seen however it pleases. When a dictation
comes out with "zeedo" instead of "Ziedo":

- **Add a word** — **Settings… → Dictionary** (or the menu-bar **Dictionary** →
  **Add Word…**), and type the spelling you want (up to 4 words, e.g. a full
  name).
- **Review / remove** — both places list your words and let you remove one.

Dictionary words steer dictations two ways: the AI cleanup model is told your
exact spellings, and a deterministic corrector runs afterwards — even when
cleanup is off — fixing casing ("whisperkit" → "WhisperKit"), split words
("whisper kit" → "WhisperKit"), and close mishearings ("zeedo" → "Ziedo").

That corrector is deliberately timid, because a wrong "correction" is worse than
a missed one: short entries only get casing and split-word fixes, never fuzzy
ones (at four letters, a single edit turns "data" into "Dana"), and a word that
already spells another dictionary entry is never rewritten into a near
neighbour. Longer entries — a full name, say — tolerate more, so "zeddo solomon"
still lands on "Ziedo Solomon". Entries are short terms, at most 4 words, and
everything stays on your Mac.

### Per-app writing styles

Cleanup can adapt to where the text is going. In **Settings… → Writing Styles**
you set a default style and add per-app rules:

- **Standard** — the normal cleanup: your words, properly punctuated.
- **Formal (email)** — complete sentences and paragraph breaks, greetings and
  sign-offs on their own lines. It reshapes layout only; it never invents a
  greeting or a word you didn't say.
- **Casual (chat)** — relaxed lowercase, no trailing periods, contractions kept.

A rule matches on the app, optionally narrowed by a substring of the window
title (so a specific browser tab can differ from the rest of the browser); the
more specific rule wins. The style is decided when you *start* recording, so
switching apps mid-dictation can't apply the wrong one.

### The dictation wave

While you hold the key, an 8-bit LED equalizer floats near the bottom of the
screen and dances with your voice, then pulses while the transcript is being
prepared. It's a click-through, non-activating panel — it never takes keyboard
focus from the app you're dictating into. Turn it off in **Settings… → General →
Show wave while dictating**.

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
local. The **setup window's AI cleanup section installs it for you** — or set it
up by hand if you prefer:

```bash
brew install ollama        # or download from ollama.com
ollama serve               # start the local server (also runs as a login service)
ollama pull qwen3:4b-instruct    # ~2.5 GB, one time
```

Either way, zwisp finds Ollama by asking whether a server answers on the local
port — a Homebrew CLI install with no `Ollama.app` works fine. If it's installed
but not running, the menu shows **"Ollama isn't running — click to start"**,
which launches it for you.

Cleanup is on by default. Toggle it and pick which of your installed models to
use in **Settings… → Cleanup**, or from the menu-bar **AI Cleanup (Ollama)**
submenu.

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
  picked in Settings → Cleanup.
- **Hotkeys** — configured in the app (see
  [Changing hotkeys](#changing-hotkeys)); the default is defined by
  `HotkeyStore.defaultHotkeys`.
- **Streaming** — the `Streaming` struct tunes eager transcription while the key
  is held (and `enabled` is its kill switch).
- **Dictionary matching** — `PersonalDictionary` holds the corrector's
  conservative thresholds: how long an entry must be to fuzzy-match at all, and
  when a second edit is tolerated.
- **The wave** — the `Overlay` struct sizes and animates the dictation
  equalizer.
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
| `WritingStyle.swift` | The styles and the prompt block each contributes |
| `StyleRules.swift` | Per-app style rules: storage and resolution |
| `DictionaryStore.swift` | Persists the personal dictionary |
| `TranscriptCorrector.swift` | Deterministic dictionary post-pass over a transcript |
| `StreamingTranscript.swift` | Confirms stable segments during eager (streaming) transcription |
| `AudioPadding.swift` | Pads sub-second recordings past WhisperKit's decode floor |
| `TextInjector.swift` | Types transcribed text into the focused app |
| `TranscriptFormatter.swift` | Joins WhisperKit segments into text |
| `WaveLevelMeter.swift` | The dictation wave's maths (levels → lit LED rows) |
| `OverlayStore.swift` | Persists the show-the-wave preference |
| `OnboardingState.swift` | The permission checklist model and its copy |
| `SetupState.swift` | Composes the checklist with the setup window's install phases |
| `SpeechModelLayout.swift` | Where the speech model lives on disk, and whether it's complete |
| `OllamaPull.swift` | Parses Ollama's `/api/pull` progress stream |
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
| `DictationOverlay.swift` | The on-screen wave: a click-through, non-activating panel |
| `FrontmostContext.swift` | The frontmost app and window title, captured at record time |
| `PermissionProbe.swift` | Live permission status and System Settings deep links |
| `SpeechModelInstaller.swift` | Downloads the speech model with progress |
| `OllamaInstaller.swift` | Installs Ollama (signature-verified) and pulls the cleanup model |
| `SetupWindow/Model/View.swift` | The guided first-run setup |
| `SettingsWindow/Model/View.swift` | The Settings window |

## Limitations

- Transcription streams **while you hold the key** (audio is transcribed and
  confirmed in the background as you speak), but the text only appears after
  you release — the on-screen wave shows your voice, not the words.
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
