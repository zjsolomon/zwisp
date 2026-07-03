import Foundation

/// WhisperKit stops decoding `windowClipTime` (1 s) before the end of a clip
/// to prevent end-of-audio hallucinations — which means audio shorter than
/// ~1 s produces zero decode windows and silently transcribes to nothing.
/// Padding a short recording with trailing silence past that floor makes a
/// quick "short one" transcribable instead of vanishing.
public enum AudioPadding {
    /// Returns `samples` extended with trailing zeros to at least `minimum`
    /// samples; longer input is returned unchanged.
    public static func pad(_ samples: [Float], toAtLeast minimum: Int) -> [Float] {
        guard samples.count < minimum else { return samples }
        return samples + [Float](repeating: 0, count: minimum - samples.count)
    }
}
