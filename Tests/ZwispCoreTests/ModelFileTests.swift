import Foundation
import Testing
@testable import ZwispCore

@Suite struct ModelFileTests {
    @Test func looksInZwispsFolderThenHomebirdsSharedStore() {
        let support = URL(fileURLWithPath: "/Users/me/Library/Application Support")
        let dirs = Configuration.Cleanup().modelFile.searchDirectories(applicationSupport: support).map(\.path)
        #expect(dirs == ["/Users/me/Library/Application Support/zwisp/models",
                         "/Users/me/Library/Application Support/homebird/models"])
    }
}
