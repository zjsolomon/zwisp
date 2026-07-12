import Foundation

/// Local dictation statistics: how much you dictate and how fast it runs.
///
/// **No transcript text is ever stored** — only counts (dictations, words) and
/// durations (transcribe/cleanup seconds). Individual events aren't kept either;
/// each dictation is folded immediately into a per-day and a lifetime aggregate,
/// so the file's size is bounded by the retention window, not by usage.
///
/// The store is deliberately tolerant: a missing
/// or corrupt file loads as empty and no public method ever throws. Stats are
/// best-effort telemetry — a disk error must never interrupt a dictation.

/// One dictation's per-stage timing, as measured by the pipeline.
public struct DictationTimings: Equatable, Sendable {
    public var transcribeSeconds: Double
    public var cleanupSeconds: Double
    /// End-to-end wall time attributed to this dictation.
    public var totalSeconds: Double { transcribeSeconds + cleanupSeconds }

    public init(transcribeSeconds: Double, cleanupSeconds: Double) {
        self.transcribeSeconds = transcribeSeconds
        self.cleanupSeconds = cleanupSeconds
    }
}

/// Running totals over some window (a single day, or lifetime).
public struct StatsAggregate: Codable, Equatable, Sendable {
    public var dictations: Int
    public var words: Int
    public var transcribeSeconds: Double
    public var cleanupSeconds: Double
    /// Mean end-to-end (transcribe + cleanup) seconds per dictation; 0 when
    /// `dictations == 0`. Stored rather than derived so a decoded snapshot is
    /// display-ready without recomputation.
    public var averageTotalSeconds: Double

    /// Memberwise, all-zero by default — so `StatsAggregate()` is the empty value.
    public init(dictations: Int = 0, words: Int = 0,
                transcribeSeconds: Double = 0, cleanupSeconds: Double = 0,
                averageTotalSeconds: Double = 0) {
        self.dictations = dictations
        self.words = words
        self.transcribeSeconds = transcribeSeconds
        self.cleanupSeconds = cleanupSeconds
        self.averageTotalSeconds = averageTotalSeconds
    }

    /// Folds one dictation into the totals, keeping `averageTotalSeconds` in
    /// step. The running totals *are* the record — no event is stored.
    mutating func fold(wordCount: Int, timings: DictationTimings) {
        dictations += 1
        words += wordCount
        transcribeSeconds += timings.transcribeSeconds
        cleanupSeconds += timings.cleanupSeconds
        averageTotalSeconds = (transcribeSeconds + cleanupSeconds) / Double(dictations)
    }
}

public final class StatsStore {
    /// On-disk shape. `version` lets a future format migrate rather than reset.
    private struct Snapshot: Codable {
        var version: Int = 1
        /// Keyed by "yyyy-MM-dd" (see `dayFormatter`).
        var days: [String: StatsAggregate] = [:]
        var lifetime: StatsAggregate = StatsAggregate()
    }

    private let config: Configuration.Stats
    private let fileURL: URL
    private let calendar: Calendar
    /// Locale-stable day keys: a fixed `en_US_POSIX` locale with the injected
    /// calendar's own time zone, so a key means the same day regardless of the
    /// user's locale or a device that roamed time zones.
    private let dayFormatter: DateFormatter
    private var snapshot: Snapshot

    /// `fileURL == nil` → `~/Library/Application Support/zwisp/stats.json`.
    public init(config: Configuration.Stats = .init(),
                fileURL: URL? = nil,
                calendar: Calendar = .current) {
        self.config = config
        self.calendar = calendar
        self.fileURL = fileURL ?? Self.defaultFileURL()

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        self.dayFormatter = formatter

        self.snapshot = Self.load(from: self.fileURL)
    }

    /// Folds one finished dictation into today's row and the lifetime total,
    /// prunes rows past the retention window, and persists — all best-effort.
    public func record(wordCount: Int, timings: DictationTimings, now: Date = Date()) {
        let key = dayFormatter.string(from: now)
        var day = snapshot.days[key] ?? StatsAggregate()
        day.fold(wordCount: wordCount, timings: timings)
        snapshot.days[key] = day
        snapshot.lifetime.fold(wordCount: wordCount, timings: timings)
        prune(now: now)
        persist()
    }

    /// Today's row (empty if nothing was dictated today).
    public func today(now: Date = Date()) -> StatsAggregate {
        snapshot.days[dayFormatter.string(from: now)] ?? StatsAggregate()
    }

    /// The all-time total, which survives day-row pruning.
    public var lifetime: StatsAggregate { snapshot.lifetime }

    /// Words in `text`: runs of non-whitespace, empties dropped. Whitespace
    /// covers spaces, tabs, and newlines.
    public static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    // MARK: Internals

    /// Drops day rows older than `retainedDays` relative to `now`. Because day
    /// keys are zero-padded "yyyy-MM-dd", lexical order is chronological order,
    /// so a string comparison against the cutoff key suffices. Lifetime is
    /// untouched.
    private func prune(now: Date) {
        guard let cutoff = calendar.date(byAdding: .day, value: -config.retainedDays, to: now)
        else { return }
        let cutoffKey = dayFormatter.string(from: cutoff)
        snapshot.days = snapshot.days.filter { $0.key >= cutoffKey }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort: a write failure must never surface to the caller.
        }
    }

    private static func load(from url: URL) -> Snapshot {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return Snapshot() }   // missing or corrupt → start empty
        return decoded
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("zwisp", isDirectory: true)
            .appendingPathComponent("stats.json")
    }
}
