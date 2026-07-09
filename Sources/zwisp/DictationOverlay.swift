import AppKit
import Observation
import SwiftUI
import ZwispCore

/// The on-screen dictation wave: a small translucent pill, bottom-center of the
/// screen being dictated into, that fades in when recording starts, drives a
/// quantized 8-bit LED equalizer (columns of discrete lit cells) from the live
/// mic level, switches to a gentle opacity pulse while the pipeline processes,
/// and fades out when the last job's text lands.
///
/// This is the app-layer glue: an inactive borderless `NSPanel` that must never
/// steal focus or activate zwisp (an `.accessory` app), a 30 Hz redraw timer,
/// and the SwiftUI view. All the wave *math* is in `ZwispCore.WaveLevelMeter`
/// (deterministic, unit-tested); this file only drives it with a real clock and
/// the live level, and owns the AppKit window plumbing.

// MARK: - Panel

/// A non-activating panel that additionally refuses key and main status. The
/// `.nonactivatingPanel` style alone stops the *app* from activating, but the
/// panel could still become the key window and swallow keyboard events — fatal
/// here, since the hotkey is a live modifier and the user is typing into another
/// app. Overriding these to `false` is the hard guarantee it never does.
private final class ClickThroughPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Model

enum OverlayPhase {
    case recording
    case thinking
}

/// Observable state the SwiftUI `OverlayView` renders. `@MainActor` because it is
/// only ever mutated from the main-thread redraw timer and AppKit callbacks.
@MainActor
@Observable
final class OverlayModel {
    /// Recording (grid tracks the mic) vs thinking (grid idle, opacity pulses).
    var phase: OverlayPhase = .recording
    /// Lit-cell count per column, 1…rowCount. Seeded to all-1s so the pill reads
    /// as a live meter the instant it appears, before the first tick lands.
    var litRows: [Int]
    /// Snapshot of the system Reduce Motion preference, taken at show time.
    var reduceMotion: Bool = false

    init(config: Configuration.Overlay) {
        litRows = Array(repeating: 1, count: config.barCount)
    }
}

// MARK: - View

struct OverlayView: View {
    let model: OverlayModel
    let config: Configuration.Overlay

    /// Drives the thinking-phase opacity pulse. Toggled inside a
    /// `repeatForever` animation when the phase becomes `.thinking`.
    @State private var pulse = false

    /// Inner vertical padding above and below the grid inside the pill.
    private static let verticalPadding: CGFloat = 9

    /// Height of one LED cell, derived from the pill geometry so the grid fills
    /// the pill: usable = pillHeight − 2·padding; cellHeight =
    /// (usable − (rowCount−1)·rowGap) / rowCount.
    private var cellHeight: CGFloat {
        let usable = CGFloat(config.pillHeight) - 2 * Self.verticalPadding
        let gaps = CGFloat(config.rowCount - 1) * CGFloat(config.rowGap)
        return max((usable - gaps) / CGFloat(config.rowCount), 0)
    }

    var body: some View {
        HStack(spacing: CGFloat(config.barSpacing)) {
            ForEach(0..<config.barCount, id: \.self) { i in
                VStack(spacing: CGFloat(config.rowGap)) {
                    // Cells top-to-bottom: visual row r (0 = top) is lit once it
                    // falls within the top `litRows[i]` cells of the column.
                    ForEach(0..<config.rowCount, id: \.self) { r in
                        Rectangle()   // sharp corners — the pixel look
                            .fill(Color.white)   // fallback: switch to Color.primary if light-mode washes out
                            .blendMode(.normal)
                            .frame(width: CGFloat(config.barWidth), height: cellHeight)
                            .opacity(cellOpacity(isLit: isLit(column: i, visualRow: r)))
                    }
                }
            }
        }
        // Only the lit/unlit opacity flips animate — LED height steps are
        // instant (that IS the 8-bit aesthetic).
        .animation(.linear(duration: 0.06), value: model.litRows)
        // Pill container — slightly squarer than a capsule for the retro look.
        .frame(width: CGFloat(config.pillWidth), height: CGFloat(config.pillHeight))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        .onChange(of: model.phase) { _, newPhase in
            updatePulse(for: newPhase)
        }
    }

    /// A cell at visual row `r` (0 = top) is lit when it is among the top
    /// `litRows[i]` of the column's `rowCount` cells (meter fills from the base).
    private func isLit(column i: Int, visualRow r: Int) -> Bool {
        guard i >= 0, i < model.litRows.count else { return false }
        return r >= config.rowCount - model.litRows[i]
    }

    /// Cell opacity: lit cells are near-solid while recording, and pulse while
    /// thinking (static 0.6 under Reduce Motion); unlit ghost cells stay faintly
    /// visible so the grid always reads as a live meter (classic EQ).
    private func cellOpacity(isLit: Bool) -> Double {
        guard isLit else { return 0.16 }   // ghost cell
        switch model.phase {
        case .recording:
            return 0.92
        case .thinking:
            if model.reduceMotion { return 0.6 }
            return pulse ? 0.9 : 0.35
        }
    }

    private func updatePulse(for phase: OverlayPhase) {
        switch phase {
        case .thinking where !model.reduceMotion:
            pulse = false
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        default:
            // Cancel the repeating animation; `barsOpacity` ignores `pulse`
            // outside the thinking phase, so the exact value doesn't matter.
            withAnimation(.linear(duration: 0)) { pulse = false }
        }
    }
}

// MARK: - Controller

/// Owns the overlay panel, the redraw timer, and the fade lifecycle. Every public
/// method is idempotent and safe to call from the dictation lifecycle seams in
/// `AppDelegate`.
@MainActor
final class DictationOverlay {
    private let config: Configuration.Overlay
    private let levelProvider: () -> Float
    private let model: OverlayModel

    private var panel: ClickThroughPanel?
    private var timer: Timer?
    private var meter: WaveLevelMeter

    /// Whether the panel is currently meant to be on screen (shown or fading in).
    /// `false` once `hide()` starts its fade-out.
    private var shown = false
    /// Monotonic phase-clock origin for the wobble (seconds).
    private var shownAt: TimeInterval = 0
    /// Timestamp of the previous tick, for the meter's explicit `dt`.
    private var lastTick: TimeInterval = 0
    /// Bumped on every show and hide so a stale fade-out completion can't
    /// `orderOut` a panel that a newer `showRecording()` has since revived.
    private var generation = 0

    init(config: Configuration.Overlay, levelProvider: @escaping () -> Float) {
        self.config = config
        self.levelProvider = levelProvider
        self.model = OverlayModel(config: config)
        self.meter = WaveLevelMeter(config: config)

        // Re-place on display (dis)connect / resolution change so the pill stays
        // bottom-center of a still-existing screen instead of stranded offscreen.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersChanged() }
        }
    }

    // MARK: Public lifecycle

    /// Show the pill in recording mode (or flip a still-visible thinking pill back
    /// to recording without re-fading). No-op if the feature is compiled off.
    func showRecording() {
        guard config.enabled else { return }
        let panel = ensurePanel()

        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        place(panel)

        // Fresh level history and phase clock for a new take.
        meter = WaveLevelMeter(config: config)
        let now = CFAbsoluteTimeGetCurrent()
        shownAt = now
        lastTick = now
        model.phase = .recording
        model.litRows = Array(repeating: 1, count: config.barCount)
        startTimer()

        // Already on screen (thinking → new recording): just repositioned and
        // flipped the phase above; do NOT re-fade.
        guard !shown else { return }

        shown = true
        generation += 1
        panel.alphaValue = 0
        panel.orderFrontRegardless()   // the only reliable order-front for an inactive .accessory app
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = config.fadeInSeconds
            panel.animator().alphaValue = 1
        }
    }

    /// Switch the (visible) pill to the thinking pulse. No-op if not shown.
    func beginThinking() {
        guard config.enabled, shown else { return }
        model.phase = .thinking
        model.litRows = Array(repeating: 1, count: config.barCount)
        // The pulse is a pure SwiftUI `repeatForever` animation; no live level to
        // drive, so the redraw timer can stop.
        stopTimer()
    }

    /// Fade the pill out and remove it. No-op if not shown.
    func hide() {
        guard let panel, shown else { return }
        shown = false
        stopTimer()

        generation += 1
        let thisGen = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = config.fadeOutSeconds
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == thisGen else { return }
                panel.orderOut(nil)
            }
        })
    }

    // MARK: Internals

    private func ensurePanel() -> ClickThroughPanel {
        if let panel { return panel }

        let rect = NSRect(x: 0, y: 0, width: config.pillWidth, height: config.pillHeight)
        let panel = ClickThroughPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true                 // floats above the owning app's windows
        panel.level = .statusBar                      // above normal windows, below system HUDs
        panel.collectionBehavior = [.canJoinAllSpaces, // visible on every Space
                                    .fullScreenAuxiliary, // and over full-screen apps
                                    .ignoresCycle]     // never in ⌘` window cycling
        panel.ignoresMouseEvents = true               // clicks pass through to the app beneath
        panel.isOpaque = false                        // let the material's translucency show
        panel.backgroundColor = .clear                // no window chrome behind the pill
        panel.hasShadow = true                        // system traces the shadow from the pill's alpha
        panel.hidesOnDeactivate = false               // stay put when zwisp isn't active (it never is)
        panel.isReleasedWhenClosed = false            // reuse the panel across dictations
        panel.animationBehavior = .none               // we own the fade animations
        panel.isMovableByWindowBackground = false     // not draggable

        let hosting = NSHostingView(rootView: OverlayView(model: model, config: config))
        hosting.frame = rect
        panel.contentView = hosting

        self.panel = panel
        return panel
    }

    /// Position the pill bottom-center of the screen being dictated into.
    private func place(_ panel: NSPanel) {
        guard let screen = targetScreen() else { return }
        let vf = screen.visibleFrame
        let x = vf.midX - CGFloat(config.pillWidth) / 2
        let y = vf.minY + CGFloat(config.bottomOffset)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Screen fallback chain: the focused window's screen, else the screen under
    /// the mouse, else the main screen, else any screen.
    private func targetScreen() -> NSScreen? {
        FrontmostContext.focusedWindowScreen()
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func screenParametersChanged() {
        guard shown, let panel else { return }
        place(panel)
    }

    // MARK: Redraw timer

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: config.pollInterval, repeats: true) { [weak self] _ in
            // Scheduled on RunLoop.main below, so the body always runs on the
            // main actor — assert it so touching main-actor state from this
            // @Sendable closure is sound (repo idiom, see MainWindow.swift).
            MainActor.assumeIsolated { self?.tick() }
        }
        // `.common` mode so the wave keeps animating during menu tracking, which
        // the default mode would suspend.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard model.phase == .recording else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let dt = now - lastTick
        lastTick = now
        meter.update(rms: levelProvider(), dt: dt)
        let phase = model.reduceMotion ? 0 : now - shownAt
        model.litRows = WaveLevelMeter.litRows(level: meter.level, phase: phase, config: config)
    }
}
