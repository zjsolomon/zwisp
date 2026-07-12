import Foundation

/// One generation from the local cleanup LLM: the text it produced plus the
/// engine's timing report, when it supplied one.
public struct CleanupGeneration: Equatable {
    /// The engine's per-request timing breakdown, in the units the log wants.
    /// `draftTokens`/`draftAccepted` are only present when the engine ran
    /// speculative decoding for the request.
    public struct Timings: Equatable {
        public let prefillTokens: Int
        public let prefillSeconds: Double
        public let generatedTokens: Int
        public let generatedSeconds: Double
        public let draftTokens: Int?
        public let draftAccepted: Int?

        public init(prefillTokens: Int, prefillSeconds: Double,
                    generatedTokens: Int, generatedSeconds: Double,
                    draftTokens: Int? = nil, draftAccepted: Int? = nil) {
            self.prefillTokens = prefillTokens
            self.prefillSeconds = prefillSeconds
            self.generatedTokens = generatedTokens
            self.generatedSeconds = generatedSeconds
            self.draftTokens = draftTokens
            self.draftAccepted = draftAccepted
        }

        /// Observed generation throughput, or `nil` for a degenerate report.
        public var tokensPerSecond: Double? {
            guard generatedSeconds > 0, generatedTokens > 0 else { return nil }
            return Double(generatedTokens) / generatedSeconds
        }

        /// Compact rendering for ~/Library/Logs/zwisp.log, so "cleanup felt
        /// slow" splits into prefill vs generation (and how much speculation
        /// helped) straight from the log.
        public var logSummary: String {
            var summary = String(
                format: "prefill %dtk %.2fs, generate %dtk %.2fs",
                prefillTokens, prefillSeconds, generatedTokens, generatedSeconds)
            if let draftTokens, let draftAccepted, draftTokens > 0 {
                let percent = Int((Double(draftAccepted) / Double(draftTokens) * 100).rounded())
                summary += ", draft \(draftAccepted)/\(draftTokens) (\(percent)%)"
            }
            return summary
        }
    }

    public let text: String
    public let timings: Timings?

    public init(text: String, timings: Timings? = nil) {
        self.text = text
        self.timings = timings
    }
}

/// The serving seam under `CleanupService`: something that can run one
/// generation against the local cleanup model and say whether it's ready.
/// Mirrors the `HTTPClient` seam one level up — `CleanupService` keeps every
/// prompt, budget, and guardrail; the engine only moves tokens. The production
/// engine is `LlamaServerClient` (the bundled llama-server over localhost);
/// tests inject a fake.
public protocol CleanupEngine {
    /// Runs one generation. Throws when the engine is unreachable or answers
    /// with something unusable — the caller falls back to the raw transcript.
    func generate(system: String, prompt: String, maxTokens: Int,
                  timeout: TimeInterval) async throws -> CleanupGeneration
    /// One cheap health probe: is the engine up and able to serve?
    func isReady() async -> Bool
}
