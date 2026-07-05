import Foundation

/// One line of Ollama's `/api/pull` streaming response. Ollama emits a stream
/// of newline-delimited JSON objects while downloading a model: bare status
/// lines ("pulling manifest", "verifying sha256 digest", "success"), per-layer
/// byte progress lines (`digest` + `total` + `completed`), and — on trouble —
/// an `error` line. This is the parsed shape of one such object.
public struct OllamaPullEvent: Equatable {
    /// e.g. "pulling manifest", "pulling <digest>", "verifying…", "success".
    public var status: String?
    /// Layer identifier for byte-progress lines; groups `completed`/`total`.
    public var digest: String?
    /// Total bytes for this layer (absent on bare status lines).
    public var total: Int64?
    /// Bytes downloaded so far for this layer.
    public var completed: Int64?
    /// Present only when the server reports a failure.
    public var error: String?

    public init(status: String? = nil, digest: String? = nil,
                total: Int64? = nil, completed: Int64? = nil, error: String? = nil) {
        self.status = status
        self.digest = digest
        self.total = total
        self.completed = completed
        self.error = error
    }

    /// Parses one stream line into an event. Deliberately lenient: a blank line
    /// or anything that isn't a JSON object yields `nil` so the caller *skips*
    /// it — a stray keep-alive newline or a partial chunk must never fail an
    /// otherwise-healthy pull.
    public static func parse(line: String) -> OllamaPullEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any]
        else { return nil }
        return OllamaPullEvent(
            status: object["status"] as? String,
            digest: object["digest"] as? String,
            total: (object["total"] as? NSNumber)?.int64Value,
            completed: (object["completed"] as? NSNumber)?.int64Value,
            error: object["error"] as? String)
    }
}

/// Folds a stream of `OllamaPullEvent`s into an overall download fraction and a
/// terminal outcome. A pull downloads several layers concurrently, each
/// reporting its own byte counts, so the honest overall progress is
/// Σcompleted / Σtotal across every layer seen so far — tracked per-digest so
/// repeated updates for the same layer *replace* rather than double-count.
public struct OllamaPullProgress {
    /// What one applied event means for the UI.
    public enum Update: Equatable {
        /// Still going: a human-readable stage plus the overall fraction, or
        /// `nil` fraction while no byte totals are known yet (indeterminate).
        case progress(stage: String, fraction: Double?)
        /// The server reported the pull finished.
        case success
        /// The server reported an error — the message rides along.
        case failure(String)
    }

    /// Latest byte counts per layer digest.
    private var layers: [String: (completed: Int64, total: Int64)] = [:]
    /// The overall fraction never moves backwards, even if a freshly announced
    /// layer momentarily dilutes the ratio — a progress bar that jumps back
    /// reads as a bug to the user.
    private var highWaterMark: Double = 0

    public init() {}

    public mutating func apply(_ event: OllamaPullEvent) -> Update {
        if let error = event.error { return .failure(error) }
        if event.status == "success" { return .success }

        // Only byte-progress lines carry a total; update that layer in place.
        if let digest = event.digest, let total = event.total {
            layers[digest] = (completed: event.completed ?? 0, total: total)
        }

        return .progress(stage: event.status ?? "", fraction: overallFraction())
    }

    /// Σcompleted / Σtotal, clamped to the high-water mark and to 1.0. `nil`
    /// until at least one layer has reported a total (nothing to divide by).
    private mutating func overallFraction() -> Double? {
        let totalSum = layers.values.reduce(Int64(0)) { $0 + $1.total }
        guard totalSum > 0 else { return nil }
        let completedSum = layers.values.reduce(Int64(0)) { $0 + $1.completed }
        let raw = min(Double(completedSum) / Double(totalSum), 1.0)
        highWaterMark = max(highWaterMark, raw)
        return highWaterMark
    }
}
