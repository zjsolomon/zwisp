import Foundation
import Testing
@testable import ZwispCore

@Suite struct NeuralEngineNoteTests {
    @Test func encodesTheShapeHomebirdReads() throws {
        let note = NeuralEngineNote(pid: 42, models: ["/m/turbo"])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(note)) as? [String: Any]
        #expect(json?["pid"] as? Int == 42)
        #expect(json?["models"] as? [String] == ["/m/turbo"])
    }

    @Test func livesInHomebirdsSupportFolderByBundleID() {
        let url = NeuralEngineNote.url(bundleID: "com.local.zwisp", home: URL(fileURLWithPath: "/Users/me"))
        #expect(url.path == "/Users/me/Library/Application Support/homebird/neural-engine/com.local.zwisp.json")
    }
}
