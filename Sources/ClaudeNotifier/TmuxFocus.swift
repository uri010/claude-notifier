import Foundation

/// Focuses a tmux session: activate Terminal.app then switch the tmux client.
enum TmuxFocus {
    @discardableResult
    static func focus(session: String?, target: String?, tty: String? = nil) -> Bool {
        Logger.log("TMUX_FOCUS session=\(session ?? "nil") target=\(target ?? "nil") tty=\(tty ?? "nil")")

        // 1. Try tmux switch-client when session info is available.
        if let session = session, !session.isEmpty {
            let tmuxPath = resolveTmuxPath()
            let client = mostRecentClient(tmuxPath: tmuxPath)
            let dest = (target?.isEmpty == false) ? target! : session

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: tmuxPath)
            if let client = client, !client.isEmpty {
                proc.arguments = ["switch-client", "-c", client, "-t", dest]
            } else {
                proc.arguments = ["switch-client", "-t", dest]
            }
            do {
                try proc.run()
                proc.waitUntilExit()
                Logger.log("TMUX_FOCUS switch-client args=\(proc.arguments ?? []) status=\(proc.terminationStatus)")
                if proc.terminationStatus == 0 {
                    activateTerminal()
                    return true
                }
            } catch {
                Logger.log("TMUX_FOCUS switch-client error=\(error)")
            }
        }

        // 2. Fallback: focus the specific Terminal.app tab by TTY.
        if let tty = tty, !tty.isEmpty {
            Logger.log("TMUX_FOCUS tty_fallback tty=\(tty)")
            return focusByTTY(tty)
        }

        // 3. Last resort: just activate Terminal.app.
        activateTerminal()
        return false
    }

    private static func activateTerminal() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "tell application \"Terminal\" to activate"]
        try? proc.run()
        proc.waitUntilExit()
        Logger.log("TMUX_FOCUS terminal_activated status=\(proc.terminationStatus)")
    }

    private static func focusByTTY(_ tty: String) -> Bool {
        let dev = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        let script = """
tell application "Terminal"
    activate
    repeat with w in windows
        repeat with t in tabs of w
            if tty of t is "\(dev)" then
                set selected of t to true
                set index of w to 1
                return
            end if
        end repeat
    end repeat
end tell
"""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        do {
            try proc.run()
            proc.waitUntilExit()
            Logger.log("TMUX_FOCUS tty_focus status=\(proc.terminationStatus)")
            return proc.terminationStatus == 0
        } catch {
            Logger.log("TMUX_FOCUS tty_focus error=\(error)")
            return false
        }
    }

    /// Returns the name of the most-recently-active attached tmux client, if any.
    private static func mostRecentClient(tmuxPath: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tmuxPath)
        proc.arguments = ["list-clients", "-F", "#{client_activity} #{client_name}"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        // Pick the line with the highest activity timestamp.
        var best: (Int, String)? = nil
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let activity = Int(parts[0]) else { continue }
            let name = String(parts[1])
            if best == nil || activity > best!.0 {
                best = (activity, name)
            }
        }
        return best?.1
    }

    private static func resolveTmuxPath() -> String {
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return c
        }
        return "/opt/homebrew/bin/tmux"
    }
}
