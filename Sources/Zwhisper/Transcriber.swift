import Foundation
import WhisperKit
import ZwhisperCore

/// Thin wrapper around WhisperKit. The model is downloaded from Hugging Face on
/// first use (needs internet once), then cached locally and runs fully offline.
final class Transcriber {
    private let whisperKit: WhisperKit

    init(model: String) async throws {
        let config = WhisperKitConfig(model: model)
        whisperKit = try await WhisperKit(config)
    }

    func transcribe(_ samples: [Float]) async -> String {
        guard !samples.isEmpty else { return "" }
        do {
            let results = try await whisperKit.transcribe(audioArray: samples)
            return TranscriptFormatter.join(results.map { $0.text })
        } catch {
            NSLog("Zwhisper: transcription error: \(error)")
            return ""
        }
    }
}
