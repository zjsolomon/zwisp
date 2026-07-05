import Foundation

/// Turns a stream of raw microphone RMS readings into the 0…1 bar heights the
/// dictation-wave overlay draws — deterministically, so every path is
/// unit-tested without a screen or a clock.
///
/// Two ideas make the wave feel "alive but calm":
///
/// 1. **Perceptual dB window** (`perceptualLevel`). Loudness is logarithmic, so
///    a linear RMS → height map spends almost all its range on sounds far louder
///    than speech and leaves normal dictation crammed near zero. Mapping decibels
///    across a fixed `[noiseFloorDb, ceilingDb]` window instead puts the
///    speaking range across the whole bar height, and clamps room tone (below
///    the floor) to a flat 0.
///
/// 2. **Attack/release asymmetry** (`update`). Smoothing uses a short time
///    constant while the level rises (bars snap up to a loud syllable) and a
///    longer one while it falls (bars ease back down between words instead of
///    flickering). The exponential step is computed from the *explicit* `dt` so
///    the same real-time behaviour holds at any redraw rate and the smoothing is
///    reproducible in tests.
///
/// The grid geometry (`columnHeights` / `litRows`) is a pure function of the
/// current level and an explicit animation `phase` — no wall-clock, no
/// randomness. The per-column wobble is *decorrelated* via golden-angle phase
/// offsets so the grid reads like an equalizer with independent bands rather
/// than a symmetric bloom, and every value is directly testable.
public struct WaveLevelMeter {
    /// The current smoothed level, 0…1.
    public private(set) var level: Double = 0

    private let config: Configuration.Overlay

    public init(config: Configuration.Overlay = .init()) {
        self.config = config
    }

    /// Advances the smoothed level toward the perceptual level of `rms`, using an
    /// exponential step sized by the elapsed `dt` and the attack/release time
    /// constant. Returns the new `level`.
    @discardableResult
    public mutating func update(rms: Float, dt: TimeInterval) -> Double {
        let raw = Self.perceptualLevel(rms: rms, config: config)
        // A rising level uses the (short) attack constant; a falling level uses
        // the (long) release constant.
        let tau = raw > level ? config.attackSeconds : config.releaseSeconds
        // `alpha = 1 − exp(−dt/tau)` is the fraction of the remaining gap closed
        // in this step: dt = 0 → alpha = 0 (no-op); dt ≫ tau → alpha → 1 (snap,
        // never overshoot). At dt == tau, alpha ≈ 0.632.
        let alpha = 1 - exp(-dt / tau)
        level += alpha * (raw - level)
        return level
    }

    /// Maps a raw RMS reading to a 0…1 loudness by placing it on a fixed decibel
    /// window: at/below `noiseFloorDb` → 0, at/above `ceilingDb` → 1, linear in
    /// between. `rms` is floored at 1e-9 before the log so digital silence maps
    /// to a very negative dB (clamped to 0) rather than −∞.
    public static func perceptualLevel(rms: Float, config: Configuration.Overlay) -> Double {
        let db = 20 * log10(Double(max(rms, 1e-9)))
        let raw = (db - config.noiseFloorDb) / (config.ceilingDb - config.noiseFloorDb)
        return min(max(raw, 0), 1)
    }

    /// Continuous per-column heights in 0…1. Columns are deliberately
    /// DECORRELATED (golden-angle phase offsets, not mirrored) so the grid
    /// reads like an equalizer with independent bands rather than a symmetric
    /// bloom. Deterministic: same (level, phase) → same output.
    public static func columnHeights(level: Double, phase: Double,
                                     config: Configuration.Overlay) -> [Double] {
        let n = config.barCount
        guard n > 0 else { return [] }
        let c = Double(n - 1) / 2                 // index of the centre
        return (0..<n).map { i in
            // Distance from centre, 0 (centre) … 1 (outermost). Guarded against
            // a divide-by-zero for a single-column pill.
            let d = c > 0 ? abs(Double(i) - c) / c : 0
            let weight = 1 - config.sideFalloff * d
            // Golden-angle (2.39996…) per-column phase offset decorrelates
            // neighbours so bands move independently.
            let wobble = 1 + config.wobbleAmount
                * sin(phase * 2 * Double.pi * config.wobbleHz + Double(i) * 2.39996323)
            let h = level * weight * wobble
            return min(max(h, 0), 1)
        }
    }

    /// Quantizes heights into lit LED counts, 1…rowCount (the bottom cell is
    /// always lit so the pill reads as a live meter even in silence).
    public static func litRows(level: Double, phase: Double,
                               config: Configuration.Overlay) -> [Int] {
        let rows = config.rowCount
        return columnHeights(level: level, phase: phase, config: config).map { h in
            let lit = Int((h * Double(rows)).rounded())
            return min(max(lit, 1), rows)
        }
    }
}
