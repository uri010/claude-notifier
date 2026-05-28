import Foundation

/// Simple file + stderr logger for E2E verification.
enum Logger {
    static let logPath: String = {
        let fm = FileManager.default
        let dir = ("~/.claude-notifier" as NSString).expandingTildeInPath
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700 as NSNumber])
        // Tighten permissions on the dir itself in case it pre-existed with 0755.
        try? fm.setAttributes([.posixPermissions: 0o700 as NSNumber], ofItemAtPath: dir)
        let path = dir + "/notifier.log"
        // Fix permissions on an existing log file that pre-dates this change.
        if fm.fileExists(atPath: path) {
            try? fm.setAttributes([.posixPermissions: 0o600 as NSNumber], ofItemAtPath: path)
        }
        return path
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
                FileManager.default.createFile(atPath: logPath, contents: Data(line.utf8),
                    attributes: [.posixPermissions: 0o600 as NSNumber])
            }
        }
    }
}
