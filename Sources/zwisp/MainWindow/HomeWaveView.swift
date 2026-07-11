import SwiftUI
import ZwispCore

/// The Home dashboard's big LED equalizer. Reuses the tested `WaveLevelMeter`
/// math on the larger `Configuration.homeWave` grid, with its own meter
/// instance — the floating `DictationOverlay` keeps its meter, timer, and
/// panel untouched.
///
/// Rendering follows the overlay's 8-bit rules: sharp-cornered cells, instant
/// LED steps, only opacity animating. Per `WaveFeed.phase`:
///   - `.recording` — live mic levels; each column's top lit cell takes the
///     logo's pastel tip colour (the one place the full tip cycle appears).
///   - `.thinking` — rows frozen at 1, lit opacity pulsing like the overlay.
///   - `.idle` — a slow ambient shimmer at a whisper of a level, so the grid
///     reads as alive without demanding attention.
/// Reduce Motion pins idle/recording to the banner's static equalizer pose and
/// thinking to a steady mid opacity.
///
/// Driven by `TimelineView`, which SwiftUI suspends whenever the view leaves
/// the hierarchy (other section selected, window closed/miniaturized) — a
/// hidden Home costs nothing.
struct HomeWaveView: View {
    let feed: WaveFeed
    let levelProvider: () -> Float
    let config: Configuration.Overlay

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var meter: WaveLevelMeter
    /// Wall-clock origin for the wobble phase; reset per appearance is fine —
    /// the wobble is decorative.
    @State private var startedAt = Date()
    @State private var lastTick: Date?
    /// Drives the thinking-phase opacity pulse (the overlay's cadence).
    @State private var pulse = false

    /// The banner's reference equalizer pose, tiled to the configured column
    /// count — the static fallback under Reduce Motion.
    private static let bannerHeights = [2, 4, 3, 5, 4, 5, 3, 4, 2]

    init(feed: WaveFeed, levelProvider: @escaping () -> Float,
         config: Configuration.Overlay) {
        self.feed = feed
        self.levelProvider = levelProvider
        self.config = config
        self._meter = State(initialValue: WaveLevelMeter(config: config))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: config.pollInterval)) { context in
            grid(litRows: litRows(at: context.date))
        }
        .onChange(of: isThinking) { _, thinking in updatePulse(thinking: thinking) }
        .onAppear { updatePulse(thinking: isThinking) }
    }

    private var isThinking: Bool { feed.phase == .thinking }

    // MARK: - Rows

    private func litRows(at date: Date) -> [Int] {
        if reduceMotion || feed.phase == .thinking {
            // Thinking freezes the meter at the baseline (the pulse carries the
            // motion); Reduce Motion holds the banner pose in every phase.
            return reduceMotion && feed.phase != .thinking
                ? staticBannerRows()
                : Array(repeating: 1, count: config.barCount)
        }
        let dt = lastTick.map { date.timeIntervalSince($0) } ?? config.pollInterval
        // TimelineView re-evaluates only this closure; stashing the clock in
        // @State from here is the sanctioned escape hatch for integrators.
        Task { @MainActor in lastTick = date }
        let phase = date.timeIntervalSince(startedAt)
        switch feed.phase {
        case .recording:
            var m = meter
            let level = m.update(rms: levelProvider(), dt: dt)
            Task { @MainActor in meter = m }
            return WaveLevelMeter.litRows(level: level, phase: phase, config: config)
        case .idle:
            // A barely-breathing shimmer: fixed whisper level, slowed wobble.
            return WaveLevelMeter.litRows(level: 0.12, phase: phase * 0.25,
                                          config: config)
        case .thinking:
            return Array(repeating: 1, count: config.barCount)
        }
    }

    private func staticBannerRows() -> [Int] {
        (0..<config.barCount).map { Self.bannerHeights[$0 % Self.bannerHeights.count] }
    }

    // MARK: - Grid

    private func grid(litRows: [Int]) -> some View {
        GeometryReader { geo in
            let columns = config.barCount
            let rows = config.rowCount
            let spacing: CGFloat = 6
            let rowGap: CGFloat = 3
            let cellWidth = (geo.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let cellHeight = (geo.size.height - rowGap * CGFloat(rows - 1)) / CGFloat(rows)

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<columns, id: \.self) { column in
                    VStack(spacing: rowGap) {
                        ForEach(0..<rows, id: \.self) { row in
                            cell(column: column, visualRow: row, litRows: litRows)
                                .frame(width: max(cellWidth, 1), height: max(cellHeight, 1))
                        }
                    }
                }
            }
        }
        .animation(.linear(duration: 0.06), value: litRows)
    }

    /// One LED. Lit when the visual row (0 = top) falls within the column's lit
    /// count (the meter fills from the base). The top lit cell wears the tip
    /// colour; the rest are LED-white.
    private func cell(column: Int, visualRow: Int, litRows: [Int]) -> some View {
        let lit = visualRow >= config.rowCount - (litRows.indices.contains(column) ? litRows[column] : 1)
        let isTip = lit && visualRow == config.rowCount - litRows[column]
        return Rectangle()
            .fill(isTip ? Theme.tipCycle[column % Theme.tipCycle.count] : Theme.textPrimary)
            .opacity(lit ? litOpacity : 0.16)
    }

    private var litOpacity: Double {
        guard isThinking else { return 0.92 }
        guard !reduceMotion else { return 0.6 }
        return pulse ? 0.9 : 0.35
    }

    private func updatePulse(thinking: Bool) {
        guard thinking, !reduceMotion else {
            withAnimation(.linear(duration: 0)) { pulse = false }
            return
        }
        pulse = false
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}
