import AppKit
import ApplicationServices
import IOKit.hid
import ServiceManagement
import ZwispCore

/// Orchestrates the whole flow and owns the menu-bar item.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config = Configuration.default
    private var statusItem: NSStatusItem!
    private lazy var recorder = AudioRecorder(config: config.audio)
    private lazy var injector = TextInjector(config: config.injection)
    private lazy var cleanup = CleanupService(config: config.cleanup)
    private var transcriber: Transcriber?
    private var hotkeyMonitor: HotkeyMonitor?

    private let hotkeyStore = HotkeyStore()
    private let capturePanel = HotkeyCapturePanel()
    private let hotkeysMenu = NSMenu(title: "Hotkeys")
    private let cleanupMenu = NSMenu(title: "AI Cleanup")

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
    private var cleanupMenuGeneration = 0 // invalidates in-flight model fetches

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("=== launched; modelName=\(config.whisperModel) ===")
        setupMenuBar()

        // Trigger the microphone permission prompt early.
        recorder.requestPermission()

        // Two SEPARATE permissions are required:
        //  - Input Monitoring: for the CGEventTap to RECEIVE the hotkey events.
        //  - Accessibility:    for TYPING the transcribed text into other apps.
        // Prompt for both up front, then start listening (independent of model).
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        let inputAccess = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        Log.write("accessibility=\(trusted) inputMonitoringRequest=\(inputAccess) inputMonitoring=\(hasInputMonitoring())")
        Log.write("hotkeys: \(hotkeyStore.hotkeys.map(\.name).joined(separator: ", "))")
        startHotkeyMonitor()
        refreshState()
        refreshCleanupStatus()
        // Track Ollama coming and going while we're idle (cheap localhost
        // call), so the blue/green icon doesn't go stale.
        cleanupPollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshCleanupStatus()
        }

        // Load the speech model off the main thread (separately).
        Task {
            do {
                let t = try await Transcriber(model: config.whisperModel)
                await MainActor.run {
                    self.transcriber = t
                    self.modelReady = true
                    Log.write("model loaded")
                    self.refreshState()
                }
            } catch {
                await MainActor.run { Log.write("model load FAILED: \(error)") }
            }
        }
    }

    private func hasInputMonitoring() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
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
                guard let self, !self.monitorActive else { return }
                Log.write("polling: inputMonitoring=\(self.hasInputMonitoring()) accessibility=\(AXIsProcessTrusted())")
                self.startHotkeyMonitor()
                self.refreshState()
            }
        }
    }

    // MARK: - Recording lifecycle

    private func startRecording() {
        Log.write("hotkey down (modelReady=\(modelReady))")
        guard modelReady, transcriber != nil, !isRecording else { return }
        isRecording = true
        recorder.start()
        refreshState()
    }

    private func stopAndTranscribe() {
        Log.write("hotkey up")
        guard isRecording, let transcriber else { Log.write("(not recording; ignoring)"); return }
        isRecording = false
        let samples = recorder.stop()
        let seconds = Double(samples.count) / config.audio.sampleRate
        Log.write("captured \(samples.count) samples (\(String(format: "%.2f", seconds))s)")
        guard samples.count > config.audio.minimumSampleCount else {   // stray tap
            Log.write("too short; skipping")
            refreshState()
            return
        }
        // Remember where the user dictated, so a slow cleanup can't type the
        // result into whatever app they switched to in the meantime.
        let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        jobsInFlight += 1
        refreshState()

        // Chain onto the previous job: strictly serial, strictly in order.
        let previous = pipelineTail
        pipelineTail = Task { [weak self] in
            await previous?.value
            await self?.process(samples: samples, with: transcriber, targetPID: targetPID)
        }
    }

    /// One dictation's trip through the pipeline: transcribe → clean → inject.
    private func process(samples: [Float], with transcriber: Transcriber,
                         targetPID: pid_t?) async {
        let raw = await transcriber.transcribe(samples)
        Log.write("raw transcript: '\(raw)'")
        let text = await cleanup.clean(raw)
        Log.write("final text: '\(text)'")
        await finishJob(injecting: text, targetPID: targetPID)
    }

    /// Waits for the user's hands to be still, checks focus hasn't moved, then
    /// types the result. Awaited by the pipeline so injections stay in order.
    @MainActor
    private func finishJob(injecting text: String, targetPID: pid_t?) async {
        defer {
            jobsInFlight -= 1
            refreshState()
            // The dictation just exercised Ollama; sync the blue/green icon.
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
            try? await Task.sleep(nanoseconds: 100_000_000)
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
            setState(.resting(monitorActive: monitorActive, modelReady: modelReady,
                              cleanup: cleanupStatus))
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
            }
        }
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "zwisp", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        // Hotkeys submenu — rebuilt each time it opens (see menuNeedsUpdate).
        hotkeysMenu.delegate = self
        let hotkeysItem = NSMenuItem(title: "Hotkeys", action: nil, keyEquivalent: "")
        hotkeysItem.submenu = hotkeysMenu
        menu.addItem(hotkeysItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Open Accessibility Settings…",
                                action: #selector(openAccessibility), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Input Monitoring Settings…",
                                action: #selector(openInputMonitoring), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Microphone Settings…",
                                action: #selector(openMicrophone), keyEquivalent: ""))
        menu.addItem(.separator())

        // AI Cleanup submenu — rebuilt each time it opens (see menuNeedsUpdate).
        cleanupMenu.delegate = self
        let cleanupItem = NSMenuItem(title: "AI Cleanup (Ollama)", action: nil, keyEquivalent: "")
        cleanupItem.submenu = cleanupMenu
        menu.addItem(cleanupItem)

        let loginItem = NSMenuItem(title: "Launch at Login",
                                   action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// Populates the AI Cleanup submenu: the on/off toggle immediately, then the
    /// installed-model list once Ollama answers (the menu updates in place).
    private func rebuildCleanupMenu() {
        cleanupMenu.removeAllItems()

        let toggle = NSMenuItem(title: "Clean Up Transcripts",
                                action: #selector(toggleCleanup), keyEquivalent: "")
        toggle.target = self
        toggle.state = cleanup.enabled ? .on : .off
        cleanupMenu.addItem(toggle)
        cleanupMenu.addItem(.separator())

        let header = NSMenuItem(title: "Model (via Ollama):", action: nil, keyEquivalent: "")
        header.isEnabled = false
        cleanupMenu.addItem(header)
        let placeholder = NSMenuItem(title: "Checking Ollama…", action: nil, keyEquivalent: "")
        placeholder.isEnabled = false
        cleanupMenu.addItem(placeholder)

        // Generation token instead of capturing the placeholder item: NSMenuItem
        // isn't Sendable, and a stale fetch must not touch a rebuilt menu.
        cleanupMenuGeneration += 1
        let generation = cleanupMenuGeneration
        Task { [weak self] in
            guard let self else { return }
            let models = await self.cleanup.availableModels()
            await MainActor.run { self.showCleanupModels(models, ifCurrent: generation) }
        }
    }

    /// Swaps the "Checking Ollama…" placeholder (the menu's last item) for the
    /// model list (current pick checked) or a "not running" notice. No-op if the
    /// menu was rebuilt since the fetch started.
    private func showCleanupModels(_ models: [String]?, ifCurrent generation: Int) {
        guard generation == cleanupMenuGeneration, cleanupMenu.numberOfItems > 0 else { return }
        let index = cleanupMenu.numberOfItems - 1
        cleanupMenu.removeItem(at: index)

        guard let models, !models.isEmpty else {
            if models == nil {
                // Not reachable — offer to start it right from the menu.
                let item = NSMenuItem(title: "Ollama isn't running — click to start",
                                      action: #selector(startOllama), keyEquivalent: "")
                item.target = self
                cleanupMenu.insertItem(item, at: index)
            } else {
                let item = NSMenuItem(title: "No models installed (ollama pull …)",
                                      action: nil, keyEquivalent: "")
                item.isEnabled = false
                cleanupMenu.insertItem(item, at: index)
            }
            return
        }

        // If the saved model was removed from Ollama, still list it (unchecked
        // models can be picked; the saved one keeps working as a name).
        var names = models
        if !names.contains(cleanup.model) { names.append(cleanup.model) }
        for (offset, name) in names.enumerated() {
            let item = NSMenuItem(title: name, action: #selector(selectCleanupModel(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.state = (name == cleanup.model) ? .on : .off
            cleanupMenu.insertItem(item, at: index + offset)
        }
    }

    @objc private func selectCleanupModel(_ sender: NSMenuItem) {
        cleanup.model = sender.title
        Log.write("cleanup model set to \(sender.title)")
        refreshCleanupStatus()
    }

    /// User clicked "Ollama isn't running — click to start". Try, in order:
    /// the Ollama.app bundle (menu-bar app; also registers itself at login),
    /// the CLI (`ollama serve`, detached so it outlives zwisp), and finally
    /// the download page for people who don't have Ollama at all.
    @objc private func startOllama() {
        // The server takes a moment to boot; re-check the icon soon after
        // instead of waiting for the 30 s poll.
        for delay in [3.0, 8.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshCleanupStatus()
            }
        }
        let appURL = ["com.ollama.ollama", "com.electron.ollama"]
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
            ?? Self.existingURL("/Applications/Ollama.app")
        if let appURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false   // background server app; keep focus
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            Log.write("launched Ollama.app at \(appURL.path)")
            return
        }

        if let cli = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            // Detach fully so the server isn't tied to zwisp's lifetime.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "nohup \(cli) serve >/dev/null 2>&1 &"]
            do {
                try process.run()
                Log.write("started '\(cli) serve' (detached)")
            } catch {
                Log.write("failed to start ollama serve: \(error)")
            }
            return
        }

        NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
        Log.write("Ollama not found; opened download page")
    }

    private static func existingURL(_ path: String) -> URL? {
        FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    @objc private func toggleCleanup(_ sender: NSMenuItem) {
        cleanup.enabled.toggle()
        sender.state = cleanup.enabled ? .on : .off
        refreshCleanupStatus()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            NSLog("zwisp: launch-at-login toggle failed: \(error)")
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nMake sure zwisp is in your Applications folder."
            alert.runModal()
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

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openInputMonitoring() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc private func openMicrophone() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}

// MARK: - Hotkey management

extension AppDelegate: NSMenuDelegate {
    /// Rebuilds the Hotkeys / AI Cleanup submenus each time they open so they
    /// reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu == cleanupMenu {
            rebuildCleanupMenu()
            return
        }
        guard menu == hotkeysMenu else { return }
        menu.removeAllItems()

        if hotkeyStore.hotkeys.isEmpty {
            let empty = NSMenuItem(title: "No hotkeys set", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let header = NSMenuItem(title: "Push-to-talk keys (click to remove):",
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for hotkey in hotkeyStore.hotkeys {
                let item = NSMenuItem(title: hotkey.name,
                                      action: #selector(removeHotkeyClicked(_:)), keyEquivalent: "")
                item.target = self
                item.state = .on
                item.representedObject = NSNumber(value: hotkey.rawValue)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let add = NSMenuItem(title: "Add Hotkey…", action: #selector(addHotkeyClicked), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
    }

    @objc private func addHotkeyClicked() {
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
        }
    }

    @objc private func removeHotkeyClicked(_ sender: NSMenuItem) {
        guard let raw = (sender.representedObject as? NSNumber)?.uint64Value,
              let hotkey = Hotkey(rawValue: raw) else { return }
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
