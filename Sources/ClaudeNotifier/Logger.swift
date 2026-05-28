import Foundation

/// Simple file + stderr logger for E2E verification.
enum Logger {
    static let logPath: String = {
        let dir = ("~/.claude-notifier" as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/notifier.log"
    }()

    private static let queue = DispatchQueue(label: "claude.notifier.log")
    private static let formatter: ISO8601DateFormatter = ISO8601DateFormatter()

    static func log(_ message: String) {
        let ts = formatter.string(from: Date())
        let line = "[\(ts)] \(message)\n"
        queue.async {
            // Write only to the log file. LaunchAgent redirects stderr to the
            // same file, so writing to both would produce duplicate entries.
            if let h = FileHandle(forWritingAtPath: logPath) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? line.write(toFile: logPath, atomically: false, encoding: .utf8)
            }
        }
    }
}
