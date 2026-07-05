import Foundation
import Testing
@testable import ZwispCore

struct WaveLevelMeterTests {
    private let config = Configuration.Overlay()

    /// RMS for a given dBFS level, e.g. −30 dB → 0.0316…
    private func rms(forDb db: Double) -> Float {
        Float(pow(10.0, db / 20.0))
    }

    // MARK: - perceptualLevel dB mapping

    @Test func silenceMapsToZero() {
        #expect(WaveLevelMeter.perceptualLevel(rms: 0, config: config) == 0)
    }

    @Test func atOrBelowNoiseFloorMapsToZero() {
        // Exactly at the floor, and well below it, both clamp to 0.
        #expect(WaveLevelMeter.perceptualLevel(rms: rms(forDb: config.noiseFloorDb), config: config) == 0)
        #expect(WaveLevelMeter.perceptualLevel(rms: rms(forDb: config.noiseFloorDb - 20), config: config) == 0)
    }

    @Test func atOrAboveCeilingMapsToOne() {
        // At the ceiling the Float→dB roundtrip lands a hair short of 1; above it
        // the clamp pins it to exactly 1.
        #expect(abs(WaveLevelMeter.perceptualLevel(rms: rms(forDb: config.ceilingDb), config: config) - 1) < 1e-6)
        #expect(WaveLevelMeter.perceptualLevel(rms: rms(forDb: config.ceilingDb + 20), config: config) == 1)
    }

    @Test func midWindowMapsToHalf() {
        // −34 dB is the midpoint of the [−50, −18] window.
        let level = WaveLevelMeter.perceptualLevel(rms: rms(forDb: -34), config: config)
        #expect(abs(level - 0.5) < 0.01)
    }

    @Test func mappingIsMonotonicInRms() {
        var previous = -1.0
        for db in stride(from: -60.0, through: 0.0, by: 1.0) {
            let level = WaveLevelMeter.perceptualLevel(rms: rms(forDb: db), config: config)
            #expect(level >= previous)
            previous = level
        }
    }

    // MARK: - update() smoothing

    @Test func attackIsFasterThanRelease() {
        // From the same gap size, one rising step closes more of the gap than
        // one falling step of the same dt.
        var rising = WaveLevelMeter(config: config)
        let riseFraction = rising.update(rms: rms(forDb: 0), dt: 0.1)   // gap was 1

        var falling = WaveLevelMeter(config: config)
        falling.update(rms: rms(forDb: 0), dt: 100)                     // drive to ~1
        let after = falling.update(rms: 0, dt: 0.1)
        let fallFraction = 1 - after

        #expect(riseFraction > fallFraction)
    }

    @Test func attackTimeConstantClosesAbout632PercentInOneTau() {
        // dt == attackSeconds ⇒ alpha = 1 − e^-1 ≈ 0.632 of the gap (0 → 1).
        var meter = WaveLevelMeter(config: config)
        let level = meter.update(rms: rms(forDb: 0), dt: config.attackSeconds)
        #expect(abs(level - 0.632) < 0.02)
    }

    @Test func releaseTimeConstantLeavesAbout368PercentAfterOneTau() {
        // From ~1, one release tau drops the gap by 0.632, leaving ≈ 0.368.
        var meter = WaveLevelMeter(config: config)
        meter.update(rms: rms(forDb: 0), dt: 100)                       // level ≈ 1
        let level = meter.update(rms: 0, dt: config.releaseSeconds)
        #expect(abs(level - 0.368) < 0.02)
    }

    @Test func zeroDtIsANoOp() {
        var meter = WaveLevelMeter(config: config)
        meter.update(rms: rms(forDb: 0), dt: 100)                       // level ≈ 1
        let before = meter.level
        let after = meter.update(rms: 0, dt: 0)
        #expect(after == before)
    }

    @Test func largeDtConvergesWithoutOvershoot() {
        var meter = WaveLevelMeter(config: config)
        let level = meter.update(rms: rms(forDb: 0), dt: 10)
        #expect(level <= 1)
        #expect(abs(level - 1) < 0.001)
    }

    // MARK: - columnHeights geometry

    @Test func columnHeightsRespectsBarCount() {
        for n in [1, 2, 4, 9] {
            let cfg = Configuration.Overlay(barCount: n)
            #expect(WaveLevelMeter.columnHeights(level: 0.5, phase: 0.3, config: cfg).count == n)
        }
    }

    @Test func columnsAreDecorrelated() {
        // Golden-angle phase offsets mean neighbouring columns don't move in
        // lockstep: at a speaking level and some phase, at least two columns
        // have different heights.
        let h = WaveLevelMeter.columnHeights(level: 0.5, phase: 0.3, config: config)
        #expect(Set(h).count > 1)
    }

    // MARK: - litRows quantization

    @Test func litRowsAlwaysWithinBounds() {
        for level in stride(from: 0.0, through: 1.0, by: 0.1) {
            for phase in stride(from: 0.0, through: 2.0, by: 0.13) {
                let rows = WaveLevelMeter.litRows(level: level, phase: phase, config: config)
                for value in rows {
                    #expect(value >= 1)
                    #expect(value <= config.rowCount)
                }
            }
        }
    }

    @Test func silenceLightsExactlyOneRow() {
        for phase in stride(from: 0.0, through: 1.0, by: 0.2) {
            let rows = WaveLevelMeter.litRows(level: 0, phase: phase, config: config)
            for value in rows {
                #expect(value == 1)
            }
        }
    }

    @Test func fullLevelReachesTopRow() {
        var reachedTop = false
        for phase in stride(from: 0.0, through: 2.0, by: 0.05) {
            let rows = WaveLevelMeter.litRows(level: 1, phase: phase, config: config)
            if rows.contains(config.rowCount) { reachedTop = true; break }
        }
        #expect(reachedTop)
    }

    @Test func litRowsIsDeterministic() {
        let a = WaveLevelMeter.litRows(level: 0.6, phase: 0.42, config: config)
        let b = WaveLevelMeter.litRows(level: 0.6, phase: 0.42, config: config)
        #expect(a == b)
    }

    @Test func moreLevelNeverFewerAverageRows() {
        // Louder speech lights up more of the grid on average (same phase).
        let phase = 0.37
        let low = WaveLevelMeter.litRows(level: 0.3, phase: phase, config: config)
        let high = WaveLevelMeter.litRows(level: 0.9, phase: phase, config: config)
        let lowMean = Double(low.reduce(0, +)) / Double(low.count)
        let highMean = Double(high.reduce(0, +)) / Double(high.count)
        #expect(highMean >= lowMean)
    }
}
