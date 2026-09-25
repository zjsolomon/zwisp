import Foundation

/// Tells Homebird which Core ML models zwisp has loaded onto the Neural Engine,
/// so its Active page can count that memory. macOS attributes Neural Engine
/// memory to no process, and Core ML doesn't keep the files open once they're
/// loaded, so there's no other way to see it; the models' size on disk is what
/// they take up (measured: 1563 MiB on disk, ~1590 MiB wired for Whisper turbo).
///
/// A local file, written after each load and removed on quit. Nothing leaves
/// the machine. `pid` lets Homebird ignore a note left behind by a crash.
/// The same format is decoded by Homebird's `NeuralEngineNote`; keep them in step.
public struct NeuralEngineNote: Codable, Equatable {
    public var pid: Int32
    /// Absolute paths of the loaded model files or folders.
    public var models: [String]

    public init(pid: Int32, models: [String]) {
        self.pid = pid
        self.models = models
    }

    /// `~/Library/Application Support/homebird/neural-engine/<bundle ID>.json`.
    public static func url(bundleID: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/homebird/neural-engine", isDirectory: true)
            .appendingPathComponent(bundleID + ".json")
    }
}
