import Foundation
import Testing
@testable import ZwispCore

struct StatsStoreTests {
    /// A fresh temp file per store, so tests never share state on disk.
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("zwispStatsTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("stats.json")
    }

    /// A UTC calendar so day boundaries are deterministic regardless of where
    /// the test runs.
    private func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func timings(_ t: Double, _ c: Double) -> DictationTimings {
        DictationTimings(transcribeSeconds: t, cleanupSeconds: c)
    }

    @Test func freshStoreIsEmpty() {
        let store = StatsStore(fileURL: tempURL())
        #expect(store.today() == StatsAggregate())
        #expect(store.lifetime == StatsAggregate())
        #expect(store.lifetime.averageTotalSeconds == 0)
    }

    @Test func recordAccumulatesAndMergesSameDay() {
        let cal = utcCalendar()
        let day = date(2026, 7, 9, cal: cal)
        let store = StatsStore(fileURL: tempURL(), calendar: cal)

        store.record(wordCount: 10, timings: timings(1.0, 0.5), now: day)
        store.record(wordCount: 6, timings: timings(2.0, 1.5), now: day)

        let today = store.today(now: day)
        #expect(today.dictations == 2)
        #expect(today.words == 16)
        #expect(today.transcribeSeconds == 3.0)
        #expect(today.cleanupSeconds == 2.0)
        // (3.0 + 2.0) / 2 dictations.
        #expect(today.averageTotalSeconds == 2.5)
        #expect(store.lifetime == today)
    }

    @Test func differentDaysSplitTodayButShareLifetime() {
        let cal = utcCalendar()
        let d1 = date(2026, 7, 8, cal: cal)
        let d2 = date(2026, 7, 9, cal: cal)
        let store = StatsStore(fileURL: tempURL(), calendar: cal)

        store.record(wordCount: 5, timings: timings(1.0, 0.0), now: d1)
        store.record(wordCount: 7, timings: timings(2.0, 0.0), now: d2)

        // today(now:) reflects only the queried day.
        #expect(store.today(now: d1).words == 5)
        #expect(store.today(now: d2).words == 7)
        // Lifetime spans both.
        #expect(store.lifetime.dictations == 2)
        #expect(store.lifetime.words == 12)
        #expect(store.lifetime.transcribeSeconds == 3.0)
    }

    @Test func oldDaysArePrunedButLifetimeSurvives() {
        let cal = utcCalendar()
        let store = StatsStore(config: .init(retainedDays: 7),
                               fileURL: tempURL(), calendar: cal)
        let old = date(2026, 6, 1, cal: cal)
        let now = date(2026, 7, 9, cal: cal)   // well over 7 days later

        store.record(wordCount: 4, timings: timings(1.0, 0.0), now: old)
        // Recording now prunes the stale row.
        store.record(wordCount: 9, timings: timings(2.0, 0.0), now: now)

        #expect(store.today(now: old) == StatsAggregate())   // pruned
        #expect(store.today(now: now).words == 9)
        // Lifetime still counts the pruned dictation.
        #expect(store.lifetime.dictations == 2)
        #expect(store.lifetime.words == 13)
    }

    @Test func persistsAcrossInstances() {
        let cal = utcCalendar()
        let url = tempURL()
        let day = date(2026, 7, 9, cal: cal)

        let first = StatsStore(fileURL: url, calendar: cal)
        first.record(wordCount: 12, timings: timings(1.5, 0.5), now: day)

        let second = StatsStore(fileURL: url, calendar: cal)
        #expect(second.today(now: day).words == 12)
        #expect(second.today(now: day).dictations == 1)
        #expect(second.lifetime.words == 12)
        #expect(second.lifetime.transcribeSeconds == 1.5)
    }

    @Test func corruptFileLoadsEmptyThenRecordsFine() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: url)

        let store = StatsStore(fileURL: url)   // must not crash or throw
        #expect(store.lifetime == StatsAggregate())

        store.record(wordCount: 3, timings: timings(1.0, 0.0))
        #expect(store.lifetime.dictations == 1)
        #expect(store.lifetime.words == 3)
    }

    @Test func wordCountHandlesWhitespaceForms() {
        #expect(StatsStore.wordCount(of: "") == 0)
        #expect(StatsStore.wordCount(of: "   ") == 0)
        #expect(StatsStore.wordCount(of: "hello") == 1)
        #expect(StatsStore.wordCount(of: "the quick brown fox") == 4)
        #expect(StatsStore.wordCount(of: "many   spaces    here") == 3)
        #expect(StatsStore.wordCount(of: "tabs\tand\nnewlines\r\nhere") == 4)
        #expect(StatsStore.wordCount(of: "  leading and trailing  ") == 3)
    }

    @Test func averageIsZeroWithNoDictationsAndCorrectOtherwise() {
        #expect(StatsAggregate().averageTotalSeconds == 0)

        let store = StatsStore(fileURL: tempURL())
        store.record(wordCount: 1, timings: timings(2.0, 2.0))
        #expect(store.lifetime.averageTotalSeconds == 4.0)
    }
}
