import Foundation

/// Pure formatting of WhisperKit's per-segment output into a single string.
/// Separated from the WhisperKit wrapper so it can be tested without the model.
public enum TranscriptFormatter {
    /// Joins transcription segments with single spaces and trims surrounding
    /// whitespace/newlines.
    public static func join(_ segments: [String]) -> String {
        segments
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
