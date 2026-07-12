import AppKit
import ApplicationServices
import ServiceManagement
import ZwispCore

/// Orchestrates the whole flow and owns the menu-bar item.
///
/// `@MainActor`: everything here runs on the main thread (the status item, the
/// event-tap callbacks that hop to `DispatchQueue.main`, the SwiftUI windows,
/// the `@MainActor` installers). Isolating the whole class lets it call the
/// main-actor installers/setup window directly instead of sprinkling per-method
/// annotations, and matches how `NSApplicationDelegate` is already isolated.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config = Configuration.default
    private var statusItem: NSStatusItem!
    private lazy var recorder = AudioRecorder(config: config.audio)
    private lazy var injector = TextInjector(config: config.injection)
    /// Current localhost address of the bundled cleanup server, shared between
    /// the supervisor (which may slide ports) and the client's URL provider.
    /// (`Configuration.default` because stored-property initializers can't read
    /// `config` — they're the same value.)
    private let llamaAddress = LlamaServerAddress(
        port: Configuration.default.cleanup.server.port)
    /// The bundled llama-server child process. Started once the cleanup model
    /// is on disk; its state changes re-derive the menu-bar cleanup colour.
    @MainActor
    private lazy var llamaServer: LlamaServerSupervisor = {
        let supervisor = LlamaServerSupervisor(config: config.cleanup, address: llamaAddress)
        supervisor.onStateChange = { [weak self] in self?.refreshCleanupStatus() }
        return supervisor
    }()
    private lazy var cleanup = CleanupService(
        config: config.cleanup,
        engine: LlamaServerClient(config: config.cleanup, httpClient: URLSession.shared,
                                  baseURL: { [llamaAddress] in llamaAddress.url }))
    private var transcriber: Transcriber?
    private var hotkeyMonitor: HotkeyMonitor?
    /// Eagerly transcribes while the hotkey is held (one worker per recording),
    /// so release only pays for the unconfirmed tail. Nil when streaming is off.
    private var streamingWorker: StreamingWorker?

    private let hotkeyStore = HotkeyStore()
    private lazy var dictionaryStore = DictionaryStore(config: config.dictionary)
    private let styleRuleStore = StyleRuleStore()
    /// The writing style whose system prompt is currently prefilled in the
    /// engine's KV cache. Warm-ups only fire when the resolved style differs.
    private var lastWarmedStyle: WritingStyle = .standard
    /// Debounces app-switch/style-change re-warms so a flurry of activations
    /// prefills once, not per event.
    private var styleRewarmWork: DispatchWorkItem?
    private let probe = PermissionProbe()

    /// User preference for the on-screen dictation wave (absent → on).
    private lazy var overlayStore = OverlayStore()
    /// The dictation-wave overlay. Reads the live mic level straight off the
    /// recorder; the panel is built lazily on first show, so a disabled overlay
    /// costs nothing.
    private lazy var overlay = DictationOverlay(
        config: config.overlay,
        levelProvider: { [weak self] in self?.recorder.currentLevel() ?? 0 })

    /// Owns the WhisperKit model download (visible progress) + hands
    /// `Transcriber` a ready folder. `onPhaseChange` repaints the setup window
    /// and re-derives the menu-bar icon (`.loading` while the model isn't ready).
    @MainActor
    private lazy var speechInstaller: SpeechModelInstaller = {
        let installer = SpeechModelInstaller(variant: config.whisperModel, setup: config.setup)
        installer.onPhaseChange = { [weak self] in
            self?.mainWindow.refresh()
            self?.refreshState()
        }
        return installer
    }()

    /// Owns the optional cleanup-model download (the engine itself ships in the
    /// bundle, so the model file is the whole dependency).
    @MainActor
    private lazy var cleanupModelInstaller: CleanupModelInstaller = {
        let installer = CleanupModelInstaller(modelFile: config.cleanup.modelFile,
                                              setup: config.setup)
        installer.onPhaseChange = { [weak self] in
            self?.mainWindow.refresh()
            self?.refreshState()
        }
        return installer
    }()

    /// Local dictation stats for the Home dashboard — counts and durations
    /// only, never transcript text. Recorded post-inject in `finishJob`.
    private lazy var statsStore = StatsStore(config: config.stats)
    /// Phase bridge to the Home equalizer, mutated beside the overlay's
    /// show/think/hide seams (but never gated on `overlayStore.enabled` —
    /// that preference governs only the floating pill).
    private let waveFeed = WaveFeed()

    /// The unified main window (SwiftUI in an `NSHostingController`): sidebar
    /// navigation over Home, the guided Setup checklist, and every settings
    /// surface. Replaces the separate `SetupWindow`/`SettingsWindow` pair; the
    /// app layer drives it through the one frozen `Actions` API so the menu
    /// bar and the window share a single code path for every side effect.
    @MainActor
    private lazy var mainWindow = MainWindow(
        probe: probe, hotkeyStore: hotkeyStore,
        dictionaryStore: dictionaryStore, styleRuleStore: styleRuleStore,
        speechInstaller: speechInstaller, cleanupInstaller: cleanupModelInstaller,
        cleanup: cleanup, overlayStore: overlayStore,
        statsStore: statsStore, waveFeed: waveFeed,
        levelProvider: { [weak self] in self?.recorder.currentLevel() ?? 0 },
        config: config,
        actions: MainWindow.Actions(
            permissionTapped: { [weak self] permission in
                self?.handlePermissionTapped(permission)
            },
            permissionsGranted: { [weak self] in
                // Re-arm the tap the moment the last grant lands, instead of
                // waiting out the 2 s retry poll — so the window's "You're
                // ready" is true by the time the user reads it.
                self?.startHotkeyMonitor()
                self?.refreshState()
            },
            retrySpeechDownload: { [weak self] in self?.startSpeechModelSetup() },
            runCleanupSetup: { [weak self] in self?.startCleanupModelDownload() },
            addHotkey: { [weak self] in self?.presentAddHotkey() },
            removeHotkey: { [weak self] hotkey in self?.removeHotkey(hotkey) },
            cleanupSettingChanged: { [weak self] in self?.refreshCleanupStatus() },
            dictionaryChanged: { [weak self] in self?.rewarmCleanup() },
            stylesChanged: { [weak self] in self?.scheduleStyleRewarmIfNeeded() },
            toggleLaunchAtLogin: { [weak self] in self?.setLaunchAtLogin() ?? false }
        ))
    private let capturePanel = HotkeyCapturePanel()

    // Independent readiness signals; the menu-bar state is derived from them.
    private var monitorActive = false
    private var modelReady = false
    /// Last observed cleanup readiness (blue vs green icon). Re-derived at
    /// launch, on toggle/model change, after each dictation, and on a poll —
    /// `.off` and `.unavailable` render the same green, so the placeholder
    /// value never flashes a wrong colour while the first check runs.
    private var cleanupStatus = CleanupStatus.off
    private var cleanupPollTimer: Timer?
    // Recording (mic open) and processing (transcribe/clean/inject) are
    // deliberately SEPARATE state: a new dictation may start while previous
    // ones are still in the pipeline, so one shared "busy" flag corrupts both.
    private var isRecording = false
    private var jobsInFlight = 0
    /// Tail of the processing chain. Each finished recording awaits the
    /// previous job before running, so transcriptions never run concurrently
    /// on WhisperKit and results are typed in dictation order.
    private var pipelineTail: Task<Void, Never>?
    private var retryTimer: Timer?
    // The menu's two stateful items, re-synced by `menuWillOpen` so a change
    // made from the window shows checked/unchecked correctly here.
    private var cleanupToggleItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("=== launched; modelName=\(config.whisperModel) ===")
        setupMenuBar()

        // Personal dictionary: rendered into the cleanup system prompt (wired
        // before the first status refresh below, so the initial warm-up
        // prefills the dictionary-bearing prompt). Edited from the Dictionary
        // menu — a macOS Service was tried and abandoned: registration looked
        // correct in pbs but the item never surfaced in Services menus.
        cleanup.dictionaryProvider = { [weak self] in self?.dictionaryStore.entries ?? [] }
        Log.write("dictionary: \(dictionaryStore.entries.count) entries")

        // No permission prompts at launch — the setup window owns them,
        // one user-initiated prompt per row instead of a dialog pile-up.
        // (Three SEPARATE permissions: Microphone to record, Input Monitoring
        // for the CGEventTap to RECEIVE the hotkey, Accessibility to TYPE the
        // result into other apps.)
        let permissions = probe.state()
        Log.write("permissions: mic=\(permissions.microphone) "
            + "inputMonitoring=\(permissions.inputMonitoring) "
            + "accessibility=\(permissions.accessibility)")
        Log.write("hotkeys: \(hotkeyStore.hotkeys.map(\.name).joined(separator: ", "))")
        startHotkeyMonitor()
        refreshState()
        // Live status, not a "first run" flag: also rescues users whose grants
        // were invalidated (e.g. by a re-signed build). Mic alone doesn't force
        // the window — its own system prompt fires on the first dictation. The
        // speech model missing also forces it (the app is inert without it);
        // the cleanup model missing alone never does — it's optional-by-design.
        if permissions.needsSetup || speechInstaller.installedFolder() == nil {
            mainWindow.present(section: .setup)
        }
        // Cleanup is served by the llama-server bundled in the app. One-time
        // note for machines upgrading from the Ollama era (we never uninstall
        // the user's own Ollama — we just stop depending on it).
        if UserDefaults.standard.string(forKey: "cleanupModel") != nil {
            UserDefaults.standard.removeObject(forKey: "cleanupModel")
            Log.write("cleanup engine: now the bundled llama-server; Ollama is no longer used")
        }
        if let model = cleanupModelInstaller.installedFile() {
            llamaServer.start(modelPath: model)
        }
        refreshCleanupStatus()
        // Re-derive the cleanup status while we're idle (cheap localhost
        // health probe), so the blue/green icon doesn't go stale.
        cleanupPollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            // Scheduled-timer body runs on the main run loop; assert the
            // isolation so this `@Sendable` closure can touch the main-actor
            // `AppDelegate`.
            MainActor.assumeIsolated { self?.refreshCleanupStatus() }
        }

        // Pre-warm the cleanup prompt for the app the user switches into: if its
        // resolved writing style differs from what's prefilled, warm the new
        // one (debounced) so the next dictation's cleanup is already prepared.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeAppChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        // Get the speech model ready: load an already-downloaded copy, else
        // download it (with visible progress in the setup window) then load.
        startSpeechModelSetup()
    }

    /// Launching zwisp while it's already running (Finder double-click, `open`)
    /// presents the main window — an accessory app has no Dock icon to click,
    /// so this is the "open the program" gesture users reach for.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.present()
        return false
    }

    /// The bundled cleanup server holds ~3 GB resident; it must not outlive
    /// the app that owns it.
    func applicationWillTerminate(_ notification: Notification) {
        llamaServer.terminate()
    }

    /// Entry point for readying the speech model. Uses the on-disk copy if the
    /// installer reports a complete folder; otherwise kicks off a download whose
    /// progress the setup window shows, loading once it lands. Also the retry
    /// hook for the setup window's speech-model row.
    private func startSpeechModelSetup() {
        if let folder = speechInstaller.installedFolder() {
            speechInstaller.markInstalled()
            loadTranscriber(from: folder)
        } else {
            speechInstaller.startDownload(onReady: { [weak self] folder in
                self?.loadTranscriber(from: folder)
            })
        }
    }

    /// Compiles/loads WhisperKit from a ready model folder off the main thread,
    /// flipping `modelReady` and the installer's phase when it finishes.
    private func loadTranscriber(from folder: URL) {
        speechInstaller.markLoading()
        Task {
            do {
                let t = try await Transcriber(
                    modelFolder: folder,
                    minimumTranscribableSamples: config.audio.minimumTranscribableSamples)
                await MainActor.run {
                    self.transcriber = t
                    self.modelReady = true
                    self.speechInstaller.markInstalled()
                    Log.write("model loaded")
                    self.refreshState()
                }
            } catch {
                await MainActor.run {
                    self.speechInstaller.markFailed(error.localizedDescription)
                    Log.write("model load FAILED: \(error)")
                }
            }
        }
    }

    /// Request-then-deep-link dispatch for one setup permission row, copied
    /// verbatim from the old `OnboardingWindow.rowButtonClicked`: the mic's first
    /// tap fires the system prompt (Settings after), the other two request (to
    /// register zwisp in the list) then open the relevant Settings pane.
    private func handlePermissionTapped(_ permission: OnboardingPermission) {
        let status = probe.state().status(of: permission)
        switch permission {
        case .microphone:
            if status == .notGranted {
                probe.requestMicAccess()
            } else {
                probe.openMicrophoneSettings()
            }
        case .inputMonitoring:
            probe.requestInputMonitoring()
            probe.openInputMonitoringSettings()
        case .accessibility:
            probe.promptAccessibility()
            probe.openAccessibilitySettings()
        }
    }

    private func hasInputMonitoring() -> Bool {
        PermissionProbe.inputMonitoringGranted()
    }

    private func startHotkeyMonitor() {
        // The keyboard tap needs BOTH Input Monitoring (to receive events) and
        // Accessibility (to type out the result). A tap created without Input
        // Monitoring is created successfully but receives nothing, so gate on
        // both and (re)create the tap once both are granted.
        let inputOK = hasInputMonitoring()
        let axOK = AXIsProcessTrusted()
        let ready = inputOK && axOK

        if ready && !monitorActive {
            hotkeyMonitor?.stop()
            hotkeyMonitor = HotkeyMonitor(
                hotkeys: hotkeyStore.hotkeys,
                onPress: { [weak self] in self?.startRecording() },
                onRelease: { [weak self] in self?.stopAndTranscribe() }
            )
            monitorActive = (hotkeyMonitor?.start() == true)
            Log.write("permissions OK (input=\(inputOK) ax=\(axOK)); event tap active: \(monitorActive)")
        } else if !ready {
            monitorActive = false
        }

        if monitorActive {
            retryTimer?.invalidate()
            retryTimer = nil
        } else if retryTimer == nil {
            // Poll so that granting the missing permission while the app runs
            // takes effect without a manual relaunch.
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                // Scheduled-timer body runs on the main run loop; assert the
                // isolation so this `@Sendable` closure can touch the main-actor
                // `AppDelegate`.
                MainActor.assumeIsolated {
                    guard let self, !self.monitorActive else { return }
                    Log.write("polling: inputMonitoring=\(self.hasInputMonitoring()) accessibility=\(AXIsProcessTrusted())")
                    self.startHotkeyMonitor()
                    self.refreshState()
                }
            }
        }
    }

    // MARK: - Recording lifecycle

    private func startRecording() {
        Log.write("hotkey down (modelReady=\(modelReady))")
        guard modelReady, transcriber != nil, !isRecording else { return }
        // Mic permission is user-initiated, not prompted at launch: if it was
        // never asked (setup window closed early), ask now — recording
        // proceeds on the next attempt once granted. A denied mic would
        // "record" silence, so reopen the setup guide instead of failing mute.
        switch PermissionProbe.microphoneStatus() {
        case .notGranted:
            Log.write("microphone not yet requested; firing the system prompt")
            probe.requestMicAccess()
            return
        case .denied:
            Log.write("microphone access denied; showing setup guide")
            mainWindow.present(section: .setup)
            return
        case .granted:
            break
        }
        // Eager style warm: the frontmost window title may have changed (a
        // browser tab switch) without a `didActivateApplication` notification,
        // so re-resolve now and prefill the new style — this prefill races the
        // user's speech and is usually done before they release the key.
        let style = currentResolvedStyle()
        if style != lastWarmedStyle {
            lastWarmedStyle = style
            Task { await cleanup.warmUp(style: style) }
        }
        isRecording = true
        recorder.start()
        if config.streaming.enabled, let transcriber {
            let worker = StreamingWorker(recorder: recorder, transcriber: transcriber,
                                         sampleRate: config.audio.sampleRate,
                                         config: config.streaming)
            worker.start()
            streamingWorker = worker
        }
        // Show the wave now the mic is actually open (past the permission
        // guards): no pill for a denied mic, and this also flips a still-visible
        // thinking pill back to recording on a fast re-press. The Home feed is
        // NOT gated on the overlay preference — that governs only the pill.
        if overlayStore.enabled { overlay.showRecording() }
        waveFeed.phase = .recording
        refreshState()
    }

    private func stopAndTranscribe() {
        Log.write("hotkey up")
        guard isRecording, let transcriber else { Log.write("(not recording; ignoring)"); return }
        isRecording = false
        let samples = recorder.stop()
        let worker = streamingWorker
        streamingWorker = nil
        let seconds = Double(samples.count) / config.audio.sampleRate
        Log.write("captured \(samples.count) samples (\(String(format: "%.2f", seconds))s)")
        guard samples.count > config.audio.minimumSampleCount else {   // stray tap
            worker?.cancel()
            Log.write("too short; skipping")
            overlay.hide()   // no job to drain the pill, so hide it here
            waveFeed.phase = .idle
            refreshState()
            return
        }
        // Snapshot the frontmost app once, at record time: its PID (so a slow
        // cleanup can't type the result into whatever app the user switched to
        // in the meantime) and the writing style resolved from its bundle ID +
        // focused-window title. Resolving here freezes the style against a focus
        // change during transcription. (`resolve` returns `.standard` when there
        // are no rules / no match, so the default setup pays only a cheap AX
        // read and no style block is added.)
        let context = FrontmostContext.capture()
        let targetPID = context.pid
        let style = styleRuleStore.resolve(bundleID: context.bundleID,
                                           windowTitle: context.windowTitle)
        jobsInFlight += 1
        refreshState()
        overlay.beginThinking()   // recording done; pulse while the pipeline runs
        waveFeed.phase = .thinking

        // Chain onto the previous job: strictly serial, strictly in order.
        let previous = pipelineTail
        pipelineTail = Task { [weak self] in
            await previous?.value
            await self?.process(samples: samples, with: transcriber, targetPID: targetPID,
                                style: style, worker: worker)
        }
    }

    /// One dictation's trip through the pipeline: transcribe → clean → inject.
    private func process(samples: [Float], with transcriber: Transcriber,
                         targetPID: pid_t?, style: WritingStyle,
                         worker: StreamingWorker?) async {
        // Per-stage timings, so "dictation felt slow" is attributable from the
        // log to transcription vs cleanup (whose own breakdown the engine reports).
        let transcribeStart = Date()
        let result = await transcribe(samples: samples, with: transcriber, worker: worker)
        let raw = result.text
        let transcribeSeconds = Date().timeIntervalSince(transcribeStart)
        Log.write(String(format: "raw transcript (%.2fs%@): '%@'",
                         transcribeSeconds, result.streamed ? ", streamed" : "", raw))
        if style != .standard {
            Log.write("writing style: \(style.rawValue)")
        }
        let cleanupStart = Date()
        let text = await cleanup.clean(raw, style: style)
        let cleanupSeconds = Date().timeIntervalSince(cleanupStart)
        Log.write(String(format: "final text (%.2fs): '%@'", cleanupSeconds, text))
        // Deterministic dictionary pass, applied last so it covers every path
        // to the final text: batch, streamed, cleanup-off, and all the cleanup
        // fallbacks. Also enforces exact casing the LLM may normalize away.
        let corrected = TranscriptCorrector.correct(text, dictionary: dictionaryStore.entries,
                                                    config: config.dictionary)
        for correction in corrected.corrections {
            Log.write("dictionary corrected '\(correction.original)' → '\(correction.replacement)'")
        }
        await finishJob(injecting: corrected.text, targetPID: targetPID,
                        timings: DictationTimings(
                            transcribeSeconds: transcribeSeconds,
                            cleanupSeconds: cleanupSeconds,
                            // Spoken time, for the dashboard's words-per-minute.
                            audioSeconds: Double(samples.count) / config.audio.sampleRate))
    }

    /// Streamed transcription when the worker confirmed audio during the hold
    /// (release pays only for the unconfirmed tail); the plain batch pass
    /// otherwise — including whenever anything about streaming went wrong, so
    /// dictation reliability never depends on it.
    private func transcribe(samples: [Float], with transcriber: Transcriber,
                            worker: StreamingWorker?) async -> (text: String, streamed: Bool) {
        if let worker, let transcript = await worker.finish(), transcript.hasConfirmedAudio {
            do {
                let tail = try await transcriber.segments(
                    for: samples, fromSeconds: transcript.clipStartSeconds)
                return (transcript.finalText(finalPassSegments: tail), true)
            } catch {
                Log.write("final streaming pass failed (\(error)); using batch")
            }
        }
        return (await transcriber.transcribe(samples), false)
    }

    /// Waits for the user's hands to be still, checks focus hasn't moved, then
    /// types the result. Awaited by the pipeline so injections stay in order.
    @MainActor
    private func finishJob(injecting text: String, targetPID: pid_t?,
                           timings: DictationTimings) async {
        defer {
            jobsInFlight -= 1
            // Drain hook: hide the wave only once the LAST queued job finishes
            // (several may still be pulsing), and only if we're not recording —
            // a re-pressed hotkey's `showRecording()` now owns the panel, so we
            // must not yank it out from under a fresh take.
            if jobsInFlight == 0 && !isRecording {
                overlay.hide()
                waveFeed.phase = .idle
            }
            refreshState()
            // The dictation just exercised the engine; sync the blue/green icon.
            refreshCleanupStatus()
        }
        guard !text.isEmpty else {
            Log.write("empty result; nothing injected")
            return
        }
        let waited = await waitUntilSafeToType()
        if waited > 0.05 {
            Log.write("waited \(String(format: "%.1f", waited))s for quiet keyboard")
        }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard targetPID == nil || frontPID == targetPID else {
            Log.write("focus moved to another app; dictation NOT typed: '\(text)'")
            return
        }
        injector.inject(text)
        Log.write("injected \(text.count) chars")
        // Stats count only dictations that actually typed: empty results and
        // focus-moved drops return above. The word COUNT crosses the seam —
        // the text itself is never stored.
        statsStore.record(wordCount: StatsStore.wordCount(of: text), timings: timings)
        mainWindow.refreshHomeIfVisible()
    }

    /// Injecting while the user is typing interleaves synthetic and physical
    /// events — and a held modifier turns injected characters into app
    /// shortcuts. Poll until the keyboard has been quiet for a moment (or the
    /// cap expires), per `Configuration.InjectionGate`. Returns seconds waited.
    @MainActor
    private func waitUntilSafeToType() async -> TimeInterval {
        let start = Date()
        while true {
            let waited = Date().timeIntervalSince(start)
            let sinceKey = CGEventSource.secondsSinceLastEventType(
                .hidSystemState, eventType: .keyDown)
            let modifiers = CGEventSource.flagsState(.hidSystemState)
                .intersection([.maskCommand, .maskAlternate, .maskControl,
                               .maskShift, .maskSecondaryFn])
            if Configuration.InjectionGate.canInject(
                isRecording: isRecording,
                secondsSinceKeyEvent: sinceKey,
                modifiersDown: !modifiers.isEmpty,
                waited: waited,
                config: config.injection
            ) {
                return waited
            }
            // Poll tightly (20 ms): the gate typically opens the instant the
            // hotkey modifier is released, so a coarse cadence just adds latency
            // between "safe to type" and the injection actually firing.
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Derives the menu-bar state: recording wins, then pipeline activity,
    /// then the resting state from the two readiness signals.
    private func refreshState() {
        if isRecording {
            setState(.recording)
        } else if jobsInFlight > 0 {
            setState(.thinking)
        } else {
            // Probe only when the monitor is down — resting() ignores the
            // names otherwise, and the probe is three TCC round-trips on the
            // main thread in the middle of the dictation path.
            let missing = monitorActive ? [] : probe.state().missingHotkeyPermissionNames
            setState(.resting(monitorActive: monitorActive, modelReady: modelReady,
                              cleanup: cleanupStatus, missingPermissions: missing))
        }
    }

    /// Re-derives the cleanup status off the main thread and re-tints the icon
    /// if it changed.
    private func refreshCleanupStatus() {
        Task { [weak self] in
            guard let self else { return }
            let status = await self.cleanup.status()
            await MainActor.run {
                guard status != self.cleanupStatus else { return }
                self.cleanupStatus = status
                Log.write("cleanup status: \(status)")
                self.refreshState()
                // Cleanup just became ready (launch, toggle-on, the server
                // [re]started): prefill the system prompt now, so the next
                // dictation's cleanup is warm instead of paying a multi-second
                // cold start.
                if case .active = status {
                    Task { await self.cleanup.warmUp(style: self.lastWarmedStyle) }
                }
            }
        }
    }

    // MARK: - Writing styles

    /// The writing style for the current frontmost app. Short-circuits to
    /// `.standard` — with NO Accessibility/`FrontmostContext` call — when the
    /// user has no rules and the default is standard, so the default setup never
    /// pays for a window-title read on every app switch.
    private func currentResolvedStyle() -> WritingStyle {
        if styleRuleStore.rules.isEmpty, styleRuleStore.defaultStyle == .standard {
            return .standard
        }
        let context = FrontmostContext.capture()
        return styleRuleStore.resolve(bundleID: context.bundleID,
                                      windowTitle: context.windowTitle)
    }

    @objc private func activeAppChanged() {
        scheduleStyleRewarmIfNeeded()
    }

    /// Re-resolves the current style and, if it differs from what's prefilled,
    /// debounces (~1 s) a warm-up of the new style's system prompt. Fired on app
    /// switches and when the style rules change from Settings.
    private func scheduleStyleRewarmIfNeeded() {
        let style = currentResolvedStyle()
        guard style != lastWarmedStyle else { return }
        styleRewarmWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastWarmedStyle = style
            Task { await self.cleanup.warmUp(style: style) }
        }
        styleRewarmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // MARK: - Menu bar

    /// The menu is deliberately small: the window owns management and one-time
    /// setup, so only mid-flow actions stay here — toggling cleanup for the
    /// next dictation, and capturing a word you just saw misheard. The two
    /// stateful items are refreshed by `menuWillOpen` (which replaced the old
    /// three-submenu rebuild machinery).
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "zwisp", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        // The unified main window — everything else lives there. ⌘, keeps the
        // platform's "app settings" muscle memory pointed at it.
        menu.addItem(NSMenuItem(title: "Open zwisp…", action: #selector(openMainWindow),
                                keyEquivalent: ","))
        menu.addItem(.separator())

        cleanupToggleItem = NSMenuItem(title: "Clean Up Transcripts",
                                       action: #selector(toggleCleanup), keyEquivalent: "")
        cleanupToggleItem.state = cleanup.enabled ? .on : .off
        menu.addItem(cleanupToggleItem)
        menu.addItem(NSMenuItem(title: "Add Dictionary Word…",
                                action: #selector(addDictionaryWordClicked), keyEquivalent: ""))

        loginItem = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
    }

    /// A minimal modal prompt for a new dictionary entry. (A system-wide
    /// right-click Service was tried first and abandoned — see README.)
    @objc private func addDictionaryWordClicked() {
        NSApp.activate(ignoringOtherApps: true)  // accessory app: unfront alerts get lost
        let alert = NSAlert()
        alert.messageText = "Add to zwisp's dictionary"
        alert.informativeText = "Type a name or term exactly as it should be spelled "
            + "(up to \(config.dictionary.maxEntryWords) words). Dictations that sound "
            + "like it will use this spelling."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "e.g. WhisperKit"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        switch dictionaryStore.add(field.stringValue) {
        case .added, .updated:
            Log.write("dictionary: added '\(field.stringValue)' via menu")
            rewarmCleanup()
        case .duplicate:
            break  // already known — nothing to do
        case .rejected:
            let oops = NSAlert()
            oops.alertStyle = .warning
            oops.messageText = "Couldn't add that"
            oops.informativeText = "Dictionary entries are short terms: at most "
                + "\(config.dictionary.maxEntryWords) words and "
                + "\(config.dictionary.maxEntryLength) characters."
            oops.runModal()
        }
    }

    /// The personal dictionary *and* the writing-style block are both part of
    /// the cleanup system prompt, so any change to either invalidates the
    /// prefilled KV cache. Re-warm the last-warmed style immediately — going
    /// through `refreshCleanupStatus` wouldn't, since warm-up only fires there
    /// on a status *transition* and the status hasn't changed.
    private func rewarmCleanup() {
        Task { await cleanup.warmUp(style: lastWarmedStyle) }
    }

    /// The setup window's "Download <model>…" button. Once the file lands,
    /// start the bundled server against it — the supervisor's health poll then
    /// flips the status (and warms the prompt cache) via `onStateChange`.
    private func startCleanupModelDownload() {
        cleanupModelInstaller.startDownload(onReady: { [weak self] model in
            self?.llamaServer.start(modelPath: model)
        })
    }

    @objc private func toggleCleanup(_ sender: NSMenuItem) {
        cleanup.enabled.toggle()
        sender.state = cleanup.enabled ? .on : .off
        refreshCleanupStatus()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        sender.state = setLaunchAtLogin() ? .on : .off
    }

    /// Flips the Launch-at-Login registration and returns the resulting state.
    /// Shared by the menu item and the Settings toggle (the frozen
    /// `Actions.toggleLaunchAtLogin` contract) so both reflect the same result.
    @discardableResult
    private func setLaunchAtLogin() -> Bool {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                return false
            } else {
                try SMAppService.mainApp.register()
                return true
            }
        } catch {
            NSLog("zwisp: launch-at-login toggle failed: \(error)")
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nMake sure zwisp is in your Applications folder."
            alert.runModal()
            return SMAppService.mainApp.status == .enabled
        }
    }

    private func setState(_ state: MenuBarState) {
        let template = (state.tint == nil)
        let image = Self.makeIcon(tint: state.tint ?? .labelColor, template: template)
        statusItem.button?.image = image
        statusItem.button?.toolTip = "zwisp – \(state.label)"
    }

    /// Draws the menu-bar glyph: a microphone with a bold "Z" in its head.
    /// `template: true` makes macOS tint it automatically for light/dark menus.
    private static func makeIcon(tint: NSColor, template: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            tint.setStroke()
            tint.setFill()

            // Mic head — rounded-rect outline.
            let head = NSBezierPath(
                roundedRect: NSRect(x: 5.5, y: 7.5, width: 7, height: 8.5),
                xRadius: 3.5, yRadius: 3.5
            )
            head.lineWidth = 1.4
            head.lineJoinStyle = .round
            head.stroke()

            // Cradle — arc hugging the bottom of the head.
            let cradle = NSBezierPath()
            cradle.appendArc(withCenter: NSPoint(x: 9, y: 11.75), radius: 5.5,
                             startAngle: 210, endAngle: 330)
            cradle.lineWidth = 1.4
            cradle.lineCapStyle = .round
            cradle.stroke()

            // Stem + base.
            let stand = NSBezierPath()
            stand.move(to: NSPoint(x: 9, y: 6.25))
            stand.line(to: NSPoint(x: 9, y: 3.5))
            stand.move(to: NSPoint(x: 6, y: 3.5))
            stand.line(to: NSPoint(x: 12, y: 3.5))
            stand.lineWidth = 1.4
            stand.lineCapStyle = .round
            stand.stroke()

            // "Z" centered in the head.
            let font = NSFont.systemFont(ofSize: 7.5, weight: .heavy)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint]
            let z = "Z" as NSString
            let zSize = z.size(withAttributes: attrs)
            z.draw(at: NSPoint(x: 9 - zSize.width / 2, y: 11.75 - zSize.height / 2),
                   withAttributes: attrs)

            return true
        }
        image.isTemplate = template
        return image
    }

    @MainActor @objc private func openMainWindow() { mainWindow.present() }
}

// MARK: - Menu state

extension AppDelegate: NSMenuDelegate {
    /// Re-syncs the menu's two stateful items just before it opens, so a
    /// toggle flipped from the window (or by SMAppService itself) reads
    /// correctly here. Replaces the old per-submenu rebuild machinery.
    func menuWillOpen(_ menu: NSMenu) {
        cleanupToggleItem?.state = cleanup.enabled ? .on : .off
        loginItem?.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }
}

// MARK: - Hotkey management

extension AppDelegate {
    /// Shared hotkey-capture flow, reached through the main window
    /// (`Actions.addHotkey`).
    private func presentAddHotkey() {
        guard monitorActive, let monitor = hotkeyMonitor else {
            presentPermissionNeededAlert()
            return
        }
        capturePanel.present(onCancel: { [weak self] in
            self?.hotkeyMonitor?.cancelCapture()
            Log.write("hotkey capture cancelled")
        })
        monitor.beginCapture { [weak self] hotkey in
            guard let self else { return }
            self.capturePanel.dismiss()
            let added = self.hotkeyStore.add(hotkey)
            self.hotkeyMonitor?.update(hotkeys: self.hotkeyStore.hotkeys)
            Log.write("hotkey \(added ? "added" : "already set"): \(hotkey.name)")
            Task { @MainActor in self.mainWindow.refresh() }
        }
    }

    /// Removes a hotkey and re-arms the live monitor (`Actions.removeHotkey`).
    private func removeHotkey(_ hotkey: Hotkey) {
        hotkeyStore.remove(hotkey)
        hotkeyMonitor?.update(hotkeys: hotkeyStore.hotkeys)
        Log.write("hotkey removed: \(hotkey.name)")
    }

    private func presentPermissionNeededAlert() {
        let alert = NSAlert()
        alert.messageText = "Grant permissions first"
        alert.informativeText = "Adding a hotkey needs Accessibility and Input Monitoring "
            + "access so zwisp can detect the key. Enable zwisp in System Settings → "
            + "Privacy & Security, then try again."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
