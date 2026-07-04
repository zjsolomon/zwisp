import Foundation
import Testing
@testable import ZwispCore

struct DictionaryStoreTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "zwispTests-\(UUID().uuidString)")!
    }

    @Test func startsEmpty() {
        let store = DictionaryStore(defaults: freshDefaults())
        #expect(store.entries.isEmpty)
        #expect(store.isEmpty)
    }

    @Test func addTrimsWhitespaceAndStores() {
        let store = DictionaryStore(defaults: freshDefaults())
        #expect(store.add("  Zied \n") == .added)
        #expect(store.entries == ["Zied"])
    }

    @Test func addRejectsEmptyAndWhitespaceOnly() {
        let store = DictionaryStore(defaults: freshDefaults())
        #expect(store.add("") == .rejected)
        #expect(store.add("   \n\t") == .rejected)
        #expect(store.isEmpty)
    }

    @Test func addRejectsOverlongText() {
        let store = DictionaryStore(defaults: freshDefaults())
        #expect(store.add(String(repeating: "a", count: 65)) == .rejected)
        #expect(store.add(String(repeating: "a", count: 64)) == .added)
    }

    @Test func addRejectsTooManyWords() {
        // A Services selection can be an arbitrary sentence; that's not a term.
        let store = DictionaryStore(defaults: freshDefaults())
        #expect(store.add("this is five whole words") == .rejected)
        #expect(store.add("Dr. Jan van Dam") == .added)
    }

    @Test func addReportsVerbatimDuplicatesWithoutStoringTwice() {
        let store = DictionaryStore(defaults: freshDefaults())
        #expect(store.add("WhisperKit") == .added)
        #expect(store.add("WhisperKit") == .duplicate)
        #expect(store.entries == ["WhisperKit"])
    }

    @Test func reAddingWithDifferentCasingReplacesInPlace() {
        let store = DictionaryStore(defaults: freshDefaults())
        store.add("whisperkit")
        store.add("Zied")
        #expect(store.add("WhisperKit") == .updated)
        #expect(store.entries == ["WhisperKit", "Zied"])
    }

    @Test func removeDeletesOnlyTheExactEntry() {
        let store = DictionaryStore(defaults: freshDefaults())
        store.add("Zied")
        store.add("WhisperKit")
        store.remove("Zied")
        #expect(store.entries == ["WhisperKit"])
        store.remove("not present")
        #expect(store.entries == ["WhisperKit"])
    }

    @Test func changesPersistAcrossInstances() {
        let defaults = freshDefaults()
        let first = DictionaryStore(defaults: defaults)
        first.add("Zied")
        first.add("WhisperKit")
        first.remove("Zied")

        let second = DictionaryStore(defaults: defaults)
        #expect(second.entries == ["WhisperKit"])
    }

    @Test func sortedEntriesIgnoreCase() {
        let store = DictionaryStore(defaults: freshDefaults())
        store.add("zwisp")
        store.add("Anthropic")
        store.add("ollama")
        #expect(store.sortedEntries == ["Anthropic", "ollama", "zwisp"])
    }
}
