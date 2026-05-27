import Foundation

enum TmuxFocus {
    @discardableResult
    static func focus(session: String?, target: String?, tty: String? = nil) -> Bool {
        Logger.log("TMUX_FOCUS session=\(session ?? "nil") target=\(target ?? "nil") tty=\(tty ?? "nil")")

        if let session = session, !session.isEmpty {
            let tmuxPath = resolveTmuxPath()

            // Resolve the exact pane target using the hook's tty (pane pty).
            // TMUX_TARGET from the hook can be stale if $TMUX was inherited from
            // a different pane, so prefer tty-based lookup when available.
            let rawTTY = tty.flatMap { $0.isEmpty || $0 == "??" ? nil : $0 }
            let dest = rawTTY.flatMap { paneTargetForTTY(tmuxPath: tmuxPath, tty: $0) }
                    ?? target.flatMap { $0.isEmpty ? nil : $0 }
                    ?? session

            let clientTTY = clientForSession(tmuxPath: tmuxPath, session: session)
                          ?? mostActiveClient(tmuxPath: tmuxPath)

            if let clientTTY = clientTTY {
                run(tmuxPath, ["select-window", "-t", dest])
                run(tmuxPath, ["select-pane",   "-t", dest])
                run(tmuxPath, ["switch-client", "-c", clientTTY, "-t", session])
                Logger.log("TMUX_FOCUS navigate client=\(clientTTY) dest=\(dest)")
                return focusByTTY(clientTTY)
            }

            activateTerminal()
            return false
        }

        // No tmux: use hook's tty to select the specific terminal tab.
        if let rawTTY = tty, !rawTTY.isEmpty, rawTTY != "??" {
            let dev = rawTTY.hasPrefix("/dev/") ? rawTTY : "/dev/\(rawTTY)"
            if focusByTTY(dev) { return true }
        }

        activateTerminal()
        return false
    }

    // MARK: - Private

    /// Finds the exact "session:window.pane" target by matching the pane's pty.
    private static func paneTargetForTTY(tmuxPath: String, tty: String) -> String? {
        let dev = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tmuxPath)
        proc.arguments = ["list-panes", "-a",
                          "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_tty}"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run(); proc.waitUntilExit() } catch { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[1] == dev else { continue }
            let result = String(parts[0])
            Logger.log("TMUX_FOCUS paneTargetForTTY tty=\(dev) → \(result)")
            return result
        }
        Logger.log("TMUX_FOCUS paneTargetForTTY tty=\(dev) → not found")
        return nil
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do { try proc.run(); proc.waitUntilExit() } catch {}
        Logger.log("TMUX_RUN \(args.joined(separator: " ")) status=\(proc.terminationStatus)")
        return proc.terminationStatus
    }

    private static func mostActiveClient(tmuxPath: String) -> String? {
        clientsRankedByActivity(tmuxPath: tmuxPath, filter: nil).first
    }

    private static func clientForSession(tmuxPath: String, session: String) -> String? {
        let result = clientsRankedByActivity(tmuxPath: tmuxPath, filter: session).first
        Logger.log("TMUX_FOCUS clientForSession=\(result ?? "nil")")
        return result
    }

    private static func clientsRankedByActivity(tmuxPath: String, filter session: String?) -> [String] {
        var args = ["list-clients", "-F", "#{client_activity} #{client_name}"]
        if let s = session { args += ["-t", s] }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tmuxPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run(); proc.waitUntilExit() } catch { return [] }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\n").compactMap { line -> (Int, String)? in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let ts = Int(parts[0]) else { return nil }
            return (ts, String(parts[1]))
        }.sorted { $0.0 > $1.0 }.map { $0.1 }
    }

    private static func focusByTTY(_ dev: String) -> Bool {
        // Reject any TTY path that contains characters outside the expected set
        // to prevent AppleScript injection via a crafted tty field in the event payload.
        guard dev.range(of: #"^/dev/[a-zA-Z0-9/]+$"#, options: .regularExpression) != nil else {
            Logger.log("TMUX_FOCUS tty_focus rejected invalid tty=\(dev)")
            return false
        }
        // Find the tab first, then activate — so the right window comes to front.
        // Calling activate before set-index can raise the wrong window.
        // Returns non-zero exit if no tab matches, so the caller can detect failure.
        let script = """
set found to false
tell application "Terminal"
    repeat with w in windows
        repeat with t in tabs of w
            if tty of t is "\(dev)" then
                set selected of t to true
                set index of w to 1
                set found to true
                exit repeat
            end if
        end repeat
        if found then exit repeat
    end repeat
    if found then
        activate
    else
        error "tty not found" number 1
    end if
end tell
"""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        do {
            try proc.run()
            proc.waitUntilExit()
            Logger.log("TMUX_FOCUS tty_focus tty=\(dev) status=\(proc.terminationStatus)")
            return proc.terminationStatus == 0
        } catch {
            Logger.log("TMUX_FOCUS tty_focus error=\(error)")
            return false
        }
    }

    private static func activateTerminal() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "tell application \"Terminal\" to activate"]
        try? proc.run()
        proc.waitUntilExit()
        Logger.log("TMUX_FOCUS terminal_activated status=\(proc.terminationStatus)")
    }

    private static func resolveTmuxPath() -> String {
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        for c in candidates where FileManager.default.fileExists(atPath: c) { return c }
        return "/opt/homebrew/bin/tmux"
    }
}
