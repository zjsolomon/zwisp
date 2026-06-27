import AppKit
import ServiceManagement

/// Orchestrates the whole flow and owns the menu-bar item.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = AudioRecorder()
    private let injector = TextInjector()
    private var transcriber: Transcriber?
    private var fnMonitor: FnKeyMonitor?

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

    // The model to load. Swap for "small.en" (more accurate) or "tiny.en" (faster).
    // Multilingual variants: "base", "small", "large-v3".
    private let modelName = "base.en"

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setState(.loading)

        // Trigger the microphone permission prompt early.
        recorder.requestPermission()

        // Load the speech model off the main thread.
        Task {
            do {
                let t = try await Transcriber(model: modelName)
                await MainActor.run {
                    self.transcriber = t
                    self.startFnMonitor()
                }
            } catch {
                NSLog("Zwhisper: model load failed: \(error)")
                await MainActor.run { self.setState(.noPermission) }
            }
        }
    }

    private func startFnMonitor() {
        fnMonitor = FnKeyMonitor(
            onPress: { [weak self] in self?.startRecording() },
            onRelease: { [weak self] in self?.stopAndTranscribe() }
        )
        if fnMonitor?.start() == true {
            setState(.idle)
        } else {
            // Event tap could not be created -> missing Accessibility permission.
            setState(.noPermission)
        }
    }

    // MARK: - Recording lifecycle

    private func startRecording() {
        guard transcriber != nil else { return }
        recorder.start()
        setState(.recording)
    }

    private func stopAndTranscribe() {
        let samples = recorder.stop()
        guard !samples.isEmpty, let transcriber else { setState(.idle); return }
        setState(.thinking)
        Task {
            let text = await transcriber.transcribe(samples)
            await MainActor.run {
                if !text.isEmpty { self.injector.inject(text) }
                self.setState(.idle)
            }
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
        menu.addItem(NSMenuItem(title: "Open Microphone Settings…",
                                action: #selector(openMicrophone), keyEquivalent: ""))
        menu.addItem(.separator())
        let loginItem = NSMenuItem(title: "Launch at Login",
                                   action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
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

    @objc private func openMicrophone() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}
