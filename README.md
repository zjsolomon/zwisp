<p align="center">
  <img src="Assets/banner.png" alt="zwisp" width="620">
</p>

**Private, on-device dictation for macOS.** Hold your push-to-talk key
(Right ⌘ by default), talk, release — your speech is transcribed locally and
typed into whatever app is focused. An open-source, local-first alternative to
hosted dictation tools like Wispr Flow: the same hold-a-key-anywhere workflow,
but nothing leaves your Mac, and no account is required. The only network
access is a one-time download of the models.

[![CI](https://github.com/zjsolomon/zwisp/actions/workflows/ci.yml/badge.svg)](https://github.com/zjsolomon/zwisp/actions/workflows/ci.yml)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/swift-5.9%2B-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Quick start

```bash
git clone https://github.com/zjsolomon/zwisp.git
cd zwisp && ./install.sh    # builds, installs to /Applications, launches
```

Needs an Apple Silicon Mac on macOS 14+ and a Swift toolchain
(`xcode-select --install`). There's no notarized download yet — building from
source is the whole install. macOS will then ask for a few one-time
permissions — see [First-run setup](#first-run-setup-one-time). Once running,
toggle **Launch at Login** from the menu-bar icon if you'd like it on every
boot.

> Prefer not to install into `/Applications`? `./build-app.sh` produces
> `zwisp.app` in the project folder — `open` it from there.

```
key held  ──►  record mic  ──►  release  ──►  WhisperKit (on-device)  ──►  AI cleanup (local, optional)  ──►  types text
       menu bar:  🔴 warming up   🟢 ready   🔵 ready + AI cleanup
```

## Features

- **Works everywhere** — types into any app that accepts keyboard input, via
  synthetic key events, so it never touches or clobbers your clipboard.
- **Your keys** — Right ⌘ by default; bind any modifier key you like, even
  several at once.
- **Optional AI cleanup** — a local LLM removes filler words, applies
  self-corrections, and fixes punctuation — still fully offline, with guardrails
  so a bad model response never replaces your words. The engine ships inside
  the app; there's nothing else to install.
- **Personal dictionary** — teach zwisp names and terms it keeps mishearing
  ("Ziedo", "zwisp", "WhisperKit"). Future dictations use your exact spelling.
- **Per-app writing styles** — cleanup can write formally in Mail and casually
  in Slack, chosen automatically from the app (and even the window title) you're
  dictating into.
- **A dictation wave** — a small 8-bit equalizer floats on screen while you talk,
  so you can see the mic is hearing you. It never steals focus, and you can turn
  it off.
- **One window for everything** — a dark, keyboard-friendly app window with a
  Home dashboard (live wave, pipeline status, local dictation stats), guided
  setup, and every setting. zwisp counts your dictations and words; it never
  stores what you said.
- **Guided setup** — the Setup section walks through the permissions and
  downloads the speech model (and, if you want cleanup, the cleanup model) with
  visible progress.
- **Stays out of the way** — lives in the menu bar with no Dock icon; the window
  opens when you want it and closes without a trace. Can launch at login.
- **Small codebase** — a compact, dependency-light Swift project that is
  straightforward to read and audit.

## First-run setup (one time)

macOS gates microphone access, global hotkeys, and synthetic typing behind
separate privacy permissions, and zwisp also needs to fetch its models.
**zwisp opens its window on the Setup section at first launch** and walks
through all of it — one button per step, each row's LED lighting as it
completes — then tells you when you're ready to dictate. Closed it early? Open
the window any time via the menu-bar icon → **Open zwisp…** (the Setup row
carries a dot until everything's in place).

For reference, the three permissions it walks you through:

1. **Microphone** — records your voice while you hold the key. Click **Allow…**
   in the guide (or macOS prompts on your first dictation).
2. **Input Monitoring** — System Settings → Privacy & Security → **Input
   Monitoring** → enable **zwisp**. Required to detect your push-to-talk key
   globally.
3. **Accessibility** — System Settings → Privacy & Security → **Accessibility** →
   enable **zwisp**. Required to type the transcribed text into other apps.

Each row deep-links straight to the right System Settings pane, and zwisp
notices a grant within a couple of seconds — no relaunch needed.

Setup also downloads the models: the speech model (~1.5 GB; lighter options in
[Configuration](#configuration)) is the only download dictation needs —
afterwards everything runs offline. The optional **AI cleanup** step adds its
model (~2.5 GB, checksum-verified); the engine itself already ships inside the
app.

## Usage

- Hold your **push-to-talk key** (Right ⌘ by default), speak, then release. The
  text is typed at your cursor. A small equalizer wave appears while you talk,
  and keeps pulsing while zwisp is still thinking.
- You can keep working while it thinks: dictations queue up and are typed in
  order. Injection politely waits until your hands are still (no keys for a
  moment, no modifier held), and if you've switched to a different app in the
  meantime it skips typing rather than dumping text into the wrong window
  (logged in `~/Library/Logs/zwisp.log`).
- **Open zwisp…** (⌘, from the menu-bar icon, or just launch the app again) is
  the whole app in one window: a Home dashboard with the live wave and your
  dictation stats, plus Setup, Dictation (hotkeys), AI Cleanup, Dictionary, and
  Writing Styles. The menu itself keeps only the mid-flow shortcuts — toggling
  cleanup, adding a dictionary word, Launch at Login, and Quit.

### What the icon colours mean

| Icon | Meaning |
|---|---|
| 🔴 Red | Warming up — the speech model is still loading (a few seconds after launch). Dictation is ignored until this clears. |
| 🟢 Green | Ready to dictate. AI cleanup is off or unavailable, so you get the raw transcript. |
| 🔵 Blue | Ready to dictate, and AI cleanup is active — transcripts get cleaned up by the local model. |
| ⚪ Grey | Transcribing a dictation you just finished. |
| 🟠 Orange | Permissions missing — hover the icon to see which, then **Open zwisp…** → Setup. See [First-run setup](#first-run-setup-one-time). |

While you're recording, zwisp's own icon doesn't change — macOS's orange
microphone indicator is the recording signal. Hover the icon to see the current
state in words.

### Changing hotkeys

In the zwisp window → **Dictation**:

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

- **Add a word** — the window's **Dictionary** section, or the menu bar's quick
  **Add Dictionary Word…** right when you spot the mishearing. Type the spelling
  you want (up to 4 words, e.g. a full name).
- **Review / remove** — the Dictionary section lists your words.

Dictionary words steer dictations two ways: the AI cleanup model is told your
exact spellings, and a deterministic corrector runs afterwards — even when
cleanup is off — fixing casing ("whisperkit" → "WhisperKit"), split words
("whisper kit" → "WhisperKit"), and close mishearings ("zeedo" → "Ziedo").

That corrector is deliberately timid, because a wrong "correction" is worse than
a missed one: short entries never fuzzy-match (at four letters, a single edit
turns "data" into "Dana"), while longer ones — a full name, say — tolerate more,
so "zeddo solomon" still lands on "Ziedo Solomon". Everything stays on your Mac.

### Per-app writing styles

Cleanup can adapt to where the text is going. In the window's **Writing
Styles** section you set a default style and add per-app rules:

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
focus from the app you're dictating into. Turn it off in the window's
**Dictation** section (**Show wave while dictating**); the big equalizer on the
Home dashboard keeps dancing either way.

## Optional: AI cleanup

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

### The engine

zwisp bundles its own inference engine — a pinned
[llama.cpp](https://github.com/ggml-org/llama.cpp) server that runs as a
private localhost subprocess, owned by the app and gone when the app quits.
There is nothing to install and no third-party app to manage: the Setup section
downloads the one model zwisp serves (**Qwen3 4B**, ~2.5 GB, checksum-verified),
and cleanup is live.

Two things make it fast on ordinary Apple Silicon:

- **Speculative decoding tuned for transcript editing.** Cleanup output is
  mostly your own words in order, so the engine drafts tokens straight from the
  transcript already sitting in the prompt and verifies them in batches —
  measurably 2–3× faster than conventional serving, with bit-identical output.
- **A resident model with a prefilled prompt.** The model never unloads while
  zwisp runs, and the instruction prompt (with your dictionary and writing
  style) is prefilled ahead of time, so a dictation pays only for its own words.

Cleanup is on by default; the menu bar keeps a quick **Clean Up Transcripts**
toggle for turning it off mid-flow, and dictations that would predictably take
too long to clean are typed raw immediately instead of making you wait.

Guardrails make cleanup fail-safe — dictation always works, and a bad model
response never replaces your words.

<details>
<summary>How the guardrails work</summary>

- If the engine isn't running or errors, the raw transcript is used unchanged.
- Any chain-of-thought the model emits (`<think>…</think>`) is stripped.
- Output is sanity-checked before it's typed: added preambles ("Here is the
  cleaned text:"), wrapping quotes, echoed delimiters, and stray end-tokens are
  stripped, and an output that balloons past the input (the model "answering"
  the dictation instead of cleaning it) is discarded in favour of the raw
  transcript.
- The conservation rule is enforced in code, not just prompted: if the model's
  output drops too many of the words you actually said, it's treated as a
  paraphrase and discarded — the raw transcript is typed instead.
- Generation is capped relative to input length, and a cleanup that can't
  plausibly finish fast (predicted from the engine's measured speed) is skipped
  up front rather than timed out.

</details>

## Configuration

All tunable settings live in one file:
[`Sources/ZwispCore/Configuration.swift`](Sources/ZwispCore/Configuration.swift).

- **Speech model** — `whisperModel`. Default `openai_whisper-large-v3-v20240930_turbo`
  (high accuracy, fast on Apple Silicon). Lighter alternatives:
  - `distil-whisper_distil-large-v3_turbo` — smaller, English-leaning
  - `openai_whisper-small.en` — much smaller, lower accuracy
  - `openai_whisper-base.en` — tiny and fastest
- **AI cleanup** — the `Cleanup` struct sets the prompt, timeout, output-length
  budget, the bundled server's launch flags (port, context size, speculation
  tuning) and the pinned model file (name, URL, checksum).
- **Hotkeys** — configured in the app (see
  [Changing hotkeys](#changing-hotkeys)); the default is defined by
  `HotkeyStore.defaultHotkeys`.
- **Streaming** — the `Streaming` struct tunes eager transcription while the key
  is held (and `enabled` is its kill switch).
- **Dictionary matching** — `PersonalDictionary` holds the corrector's
  conservative thresholds: how long an entry must be to fuzzy-match at all, and
  when a second edit is tolerated.
- **The wave** — the `Overlay` struct sizes and animates the floating dictation
  equalizer; `homeWave` is the Home dashboard's bigger grid. `Stats.retainedDays`
  bounds how long daily dictation counts are kept.
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
| `CleanupService.swift` | Optional local LLM cleanup pass: prompts, budgets, guardrails |
| `CleanupEngine.swift` | The serving seam under `CleanupService` (protocol + timings) |
| `LlamaServerClient.swift` | Talks to the bundled llama-server over localhost |
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
| `StatsStore.swift` | Local dictation stats — counts and durations only, never text |
| `MainNav.swift` | The window's sections and the setup-attention gate |
| `OnboardingState.swift` | The permission checklist model and its copy |
| `SetupState.swift` | Composes the checklist with the Setup section's install phases |
| `SpeechModelLayout.swift` | Where the speech model lives on disk, and whether it's complete |
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
| `CleanupModelInstaller.swift` | Downloads the cleanup model with progress (checksum-verified) |
| `LlamaServerSupervisor.swift` | Runs the bundled llama-server: spawn, health, restart, teardown |
| `MainWindow/` | The app window: sidebar navigation, dark theme, Home dashboard, setup + settings sections |

## Limitations

- Transcription streams **while you hold the key** (audio is transcribed and
  confirmed in the background as you speak), but the text only appears after
  you release — the on-screen wave shows your voice, not the words.
- The app is ad-hoc / self-signed, so permissions are tied to a specific build;
  rebuilding may occasionally require re-granting Accessibility. See
  [`setup-signing.sh`](setup-signing.sh) for a stable local signing identity that
  avoids this.

## About this project

zwisp is a personal tool: I built it because I wanted dictation that works
everywhere, keeps up with how I actually speak, and never sends a word off my
machine — and then I kept refining it because I use it all day. The source is
public because a complete local dictation pipeline — streaming Whisper,
LLM cleanup with enforced guardrails, synthetic-event injection — fits in a
small, readable Swift codebase, and that seemed worth sharing. Read it, fork
it, build it, make it yours. It follows my needs rather than a roadmap, so I'm
not taking issues or pull requests.

## Acknowledgements

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax for on-device
  Whisper inference.
- [llama.cpp](https://github.com/ggml-org/llama.cpp) by Georgi Gerganov and
  contributors for the bundled cleanup engine.

## License

[MIT](LICENSE) © Ziedo Solomon
