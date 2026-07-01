import Foundation

/// Minimal append-to-file logger. Unified-log (NSLog) output is unreliable to
/// retrieve for an ad-hoc app, so we also write to ~/Library/Logs/Zwhisper.log.
public enum Log {
    private static let url: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Zwhisper.log")

    public static func write(_ message: String) {
        NSLog("Zwhisper: \(message)")
        let line = "\(Date()) \(message)\n"
        let data = Data(line.utf8)
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: url)
        }
    }
}
