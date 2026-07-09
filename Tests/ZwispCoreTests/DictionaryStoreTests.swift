import Foundation
import Testing
@testable import ZwispCore

struct DictionaryStoreTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "zwispTests-\(UUID().uuidString)")!
    }

    @Test func startsWithTheDefaultSeed() {
        let store = DictionaryStore(defaults: freshDefaults())
        #expect(store.entries == DictionaryStore.defaultEntries)
        #expect(store.entries == ["zwisp"])
    }

    @Test func explicitlyEmptiedDictionaryStaysEmpty() {
        // Removing the seed is a choice, not a first run — respect it.
        let defaults = freshDefaults()
        let first = DictionaryStore(defaults: defaults)
        first.remove("zwisp")

        let second = DictionaryStore(defaults: defaults)
        #expect(second.isEmpty)
    }

    @Test func addTrimsWhitespaceAndStores() {
        let store = DictionaryStore(defaults: freshDefaults())
        #expect(store.add("  Ziedo \n") == .added)
        #expect(store.entries == ["zwisp", "Ziedo"])
    }

    @Test func addRejectsEmptyAndWhitespaceOnly() {
        let store = DictionaryStore(defaults: freshDefaults())
        #expect(store.add("") == .rejected)
        #expect(store.add("   \n\t") == .rejected)
        #expect(store.entries == ["zwisp"])
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
        #expect(store.entries == ["zwisp", "WhisperKit"])
    }

    @Test func reAddingWithDifferentCasingReplacesInPlace() {
        let store = DictionaryStore(defaults: freshDefaults())
        store.add("whisperkit")
        store.add("Ziedo")
        #expect(store.add("WhisperKit") == .updated)
        #expect(store.entries == ["zwisp", "WhisperKit", "Ziedo"])
    }

    @Test func removeDeletesOnlyTheExactEntry() {
        let store = DictionaryStore(defaults: freshDefaults())
        store.add("Ziedo")
        store.add("WhisperKit")
        store.remove("Ziedo")
        #expect(store.entries == ["zwisp", "WhisperKit"])
        store.remove("not present")
        #expect(store.entries == ["zwisp", "WhisperKit"])
    }

    @Test func changesPersistAcrossInstances() {
        let defaults = freshDefaults()
        let first = DictionaryStore(defaults: defaults)
        first.add("Ziedo")
        first.add("WhisperKit")
        first.remove("Ziedo")

        let second = DictionaryStore(defaults: defaults)
        #expect(second.entries == ["zwisp", "WhisperKit"])
    }

    @Test func sortedEntriesIgnoreCase() {
        let store = DictionaryStore(defaults: freshDefaults())
        store.add("zwisp")
        store.add("Anthropic")
        store.add("ollama")
        #expect(store.sortedEntries == ["Anthropic", "ollama", "zwisp"])
    }
}
