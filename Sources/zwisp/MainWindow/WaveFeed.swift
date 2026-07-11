import Observation

/// What the Home equalizer should be doing right now. `AppDelegate` mutates
/// this alongside the dictation overlay's show/think/hide seams — but
/// unconditionally, NOT gated on `OverlayStore.enabled`: that preference
/// governs only the floating pill, while the Home wave is part of the window
/// the user deliberately opened.
enum HomeWavePhase {
    case idle, recording, thinking
}

/// A one-field observable bridge from the dictation pipeline to the Home
/// equalizer. The view reads `phase` and drives its own `WaveLevelMeter` from
/// the recorder's O(1) `currentLevel()`; the dictation overlay keeps its own
/// independent meter and panel.
@MainActor
@Observable
final class WaveFeed {
    var phase: HomeWavePhase = .idle
}
