import AppKit
import ApplicationServices
import IOKit.hid
import ServiceManagement

/// Orchestrates the whole flow and owns the menu-bar item.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = AudioRecorder()
    private let injector = TextInjector()
    private let cleanup = CleanupService()
    private var transcriber: Transcriber?
    private var fnMonitor: FnKeyMonitor?

    // Two independent readiness signals; the menu-bar state is derived from both.
    private var monitorActive = false
    private var modelReady = false
    private var isBusy = false            // recording/transcribing in progress
    private var retryTimer: Timer?

    private enum State {
        case loading      // model loading
        case idle         // ready, waiting for Fn
        case recording    // Fn held, capturing audio
        case thinking     // transcribing
        case noPermission // accessibility not granted

        var label: String {
            switch self {
            case .loading:      return "Loading model…"
            case .idle:         return "Ready — hold Fn to talk"
            case .recording:    return "Recording…"
            case .thinking:     return "Transcribing…"
            case .noPermission: return "Needs Accessibility permission"
            }
        }

        /// nil = template image (auto black/white to match the menu bar).
        var tint: NSColor? {
            switch self {
            case .idle:         return nil
            case .loading:      return .secondaryLabelColor
            case .recording:    return .systemRed
            case .thinking:     return .systemBlue
            case .noPermission: return .systemOrange
            }
        }
    }

    // The speech model to load (downloaded once from Hugging Face, then cached).
    // large-v3-turbo: near-large-v3 accuracy, fast on Apple Silicon — best for dictation.
    // Lighter/faster alternatives:
    //   "distil-whisper_distil-large-v3_turbo"  (smaller, English-leaning)
    //   "openai_whisper-small.en"               (much smaller, lower accuracy)
    //   "openai_whisper-base.en"                (tiny, fastest)
    private let modelName = "openai_whisper-large-v3-v20240930_turbo"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("=== launched; modelName=\(modelName) ===")
        setupMenuBar()

        // Trigger the microphone permission prompt early.
        recorder.requestPermission()

        // Two SEPARATE permissions are required:
        //  - Input Monitoring: for the CGEventTap to RECEIVE the Fn key events.
        //  - Accessibility:    for TYPING the transcribed text into other apps.
        // Prompt for both up front, then start listening (independent of model).
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        let inputAccess = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        Log.write("accessibility=\(trusted) inputMonitoringRequest=\(inputAccess) inputMonitoring=\(hasInputMonitoring())")
        startFnMonitor()
        refreshState()

        // Load the speech model off the main thread (separately).
        Task {
            do {
                let t = try await Transcriber(model: modelName)
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

    private func startFnMonitor() {
        // The keyboard tap needs BOTH Input Monitoring (to receive events) and
        // Accessibility (to type out the result). A tap created without Input
        // Monitoring is created successfully but receives nothing, so gate on
        // both and (re)create the tap once both are granted.
        let inputOK = hasInputMonitoring()
        let axOK = AXIsProcessTrusted()
        let ready = inputOK && axOK

        if ready && !monitorActive {
            fnMonitor?.stop()
            fnMonitor = FnKeyMonitor(
                onPress: { [weak self] in self?.startRecording() },
                onRelease: { [weak self] in self?.stopAndTranscribe() }
            )
            monitorActive = (fnMonitor?.start() == true)
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
                self.startFnMonitor()
                self.refreshState()
            }
        }
    }

    // MARK: - Recording lifecycle

    private func startRecording() {
        Log.write("Fn down (modelReady=\(modelReady))")
        guard modelReady, transcriber != nil else { return }
        isBusy = true
        recorder.start()
        setState(.recording)
    }

    private func stopAndTranscribe() {
        Log.write("Fn up")
        guard isBusy, let transcriber else { return }
        let samples = recorder.stop()
        guard !samples.isEmpty else { isBusy = false; refreshState(); return }
        setState(.thinking)
        Task {
            let raw = await transcriber.transcribe(samples)
            let text = await cleanup.clean(raw)
            await MainActor.run {
                if !text.isEmpty { self.injector.inject(text) }
                self.isBusy = false
                self.refreshState()
            }
        }
    }

    /// Derives the resting menu-bar state from the two readiness signals.
    private func refreshState() {
        guard !isBusy else { return }
        if !monitorActive {
            setState(.noPermission)
        } else if !modelReady {
            setState(.loading)
        } else {
            setState(.idle)
        }
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Zwhisper", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Accessibility Settings…",
                                action: #selector(openAccessibility), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Input Monitoring Settings…",
                                action: #selector(openInputMonitoring), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Microphone Settings…",
                                action: #selector(openMicrophone), keyEquivalent: ""))
        menu.addItem(.separator())
        let cleanupItem = NSMenuItem(title: "Clean up with AI (Ollama)",
                                     action: #selector(toggleCleanup), keyEquivalent: "")
        cleanupItem.state = cleanup.enabled ? .on : .off
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

    @objc private func toggleCleanup(_ sender: NSMenuItem) {
        cleanup.enabled.toggle()
        sender.state = cleanup.enabled ? .on : .off
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
            NSLog("Zwhisper: launch-at-login toggle failed: \(error)")
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nMake sure Zwhisper is in your Applications folder."
            alert.runModal()
        }
    }

    private func setState(_ state: State) {
        let template = (state.tint == nil)
        let image = Self.makeIcon(tint: state.tint ?? .labelColor, template: template)
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Zwhisper – \(state.label)"
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
