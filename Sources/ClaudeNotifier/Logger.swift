import Foundation

/// Simple file + stderr logger for E2E verification.
enum Logger {
    static let logPath: String = {
        let dir = ("~/.claude-notifier" as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/notifier.log"
    }()

    private static let queue = DispatchQueue(label: "claude.notifier.log")

    static func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        queue.async {
            FileHandle.standardError.write(Data(line.utf8))
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
