import SwiftUI
import AppKit
import Foundation

let kDefaultPort: UInt16 = 47823
let kHookTimeout: TimeInterval = 600   // server-side cap for long-poll

func resolvePort() -> UInt16 {
    if let env = ProcessInfo.processInfo.environment["CLAUDE_NOTIFIER_PORT"], let p = UInt16(env) {
        return p
    }
    return kDefaultPort
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var server: HTTPServer?
    let port = resolvePort()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory app: no Dock icon, no menu bar focus stealing.
        NSApp.setActivationPolicy(.accessory)

        // Wire store -> UI.
        NotificationStore.shared.onEvent = { id, event in
            PanelManager.shared.showBanner(id: id, event: event)
        }
        NotificationStore.shared.onRemove = { id in
            PanelManager.shared.removeBanner(id: id)
        }

        // Auto-dismiss banners when the user switches to a terminal app.
        // Use RunLoop.main with .common mode so the timer fires in all run-loop modes.
        Logger.log("WORKSPACE_CHECK frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")")
        let terminals: Set<String> = ["Terminal", "터미널", "iTerm2", "iTerm",
                                      "Alacritty", "Kitty", "WezTerm", "Hyper"]
        // prevWasTerminal is kept only for the transition log (not for the clear condition).
        // clearInfoBanners runs on every tick while in terminal, not only on the app-level
        // transition — this handles tmux pane/tab switches within the same Terminal.app window
        // (those don't trigger an app-level frontmost change, so the old isTerminal&&!prev
        // condition never fired when the user switched back to Claude's pane from another pane).
        var prevWasTerminal = false
        let focusTimer = Timer(timeInterval: 1.5, repeats: true) { _ in
            let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            let isTerminal = terminals.contains(name)
            if isTerminal && !prevWasTerminal {
                Logger.log("TERMINAL_FOCUSED app=\(name)")
            }
            if isTerminal {
                Task { @MainActor in
                    PanelManager.shared.clearInfoBanners()
                }
            }
            prevWasTerminal = isTerminal
        }
        RunLoop.main.add(focusTimer, forMode: .common)

        let server = HTTPServer(port: port)
        server.handler = { method, path, body in
            Self.route(method: method, path: path, body: body)
        }
        do {
            try server.start()
            self.server = server
            Logger.log("SERVER_STARTED port=\(port)")
        } catch {
            Logger.log("SERVER_FAILED error=\(error)")
            // Print to stderr and exit so the launcher knows.
            FileHandle.standardError.write(Data("Failed to start server on port \(port): \(error)\n".utf8))
            exit(2)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        Logger.log("SERVER_STOPPED")
    }

    // MARK: - Routing

    static func route(method: String, path: String, body: Data) -> (Int, String, Data) {
        // Strip query string.
        let cleanPath = path.components(separatedBy: "?").first ?? path

        if method == "GET" && cleanPath == "/health" {
            let payload: [String: Any] = [
                "status": "ok",
                "pending": NotificationStore.shared.pendingCount(),
                "version": "1.0"
            ]
            return jsonResponse(200, payload)
        }

        if method == "POST" && cleanPath == "/event" {
            guard let event = try? JSONDecoder().decode(EventRequest.self, from: body) else {
                Logger.log("EVENT_DECODE_ERROR body=\(String(data: body.prefix(200), encoding: .utf8) ?? "?")")
                return jsonResponse(400, ["error": "invalid event json"])
            }
            let id = NotificationStore.shared.createPending(for: event)
            Logger.log("EVENT_RECEIVED id=\(id.prefix(8))… kind=\(event.kind.rawValue)")
            return jsonResponse(200, ["id": id])
        }

        // POST /notify — fire-and-forget informational banner (stop / notify).
        // Does NOT create a pending response entry; banner is dismissed by user.
        if method == "POST" && cleanPath == "/notify" {
            guard let event = try? JSONDecoder().decode(EventRequest.self, from: body) else {
                return jsonResponse(400, ["error": "invalid event json"])
            }
            let id = UUID().uuidString
            Logger.log("NOTIFY_RECEIVED id=\(id.prefix(8))… kind=\(event.kind.rawValue)")
            DispatchQueue.main.async {
                PanelManager.shared.showInfoBanner(id: id, event: event)
            }
            return jsonResponse(200, ["id": id])
        }

        // POST /clear -> dismiss all banners (utility for cleanup/testing).
        if method == "POST" && cleanPath == "/clear" {
            DispatchQueue.main.async { PanelManager.shared.clearAll() }
            return jsonResponse(200, ["ok": true])
        }

        // POST /respond/{id}  body: {"decision":"allow|allowSession|deny|dismiss|focus"}
        // Resolves a pending decision externally (used by tests and CLI tooling).
        if method == "POST" && cleanPath.hasPrefix("/respond/") {
            let id = String(cleanPath.dropFirst("/respond/".count))
            guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let raw = obj["decision"] as? String,
                  let decision = UserDecision(rawValue: raw) else {
                return jsonResponse(400, ["error": "invalid decision"])
            }
            guard NotificationStore.shared.pendingResponse(for: id) != nil else {
                return jsonResponse(404, ["error": "unknown id"])
            }
            Logger.log("RESPOND_API id=\(id.prefix(8))… decision=\(decision.rawValue)")
            DispatchQueue.main.async { PanelManager.shared.applyDecision(id: id, decision: decision) }
            return jsonResponse(200, ["ok": true, "decision": decision.rawValue])
        }

        // GET /response/{id}?timeout=NN  -> long-poll for the decision.
        if method == "GET" && cleanPath.hasPrefix("/response/") {
            let id = String(cleanPath.dropFirst("/response/".count))
            guard let pending = NotificationStore.shared.pendingResponse(for: id) else {
                return jsonResponse(404, ["error": "unknown id", "decision": "timeout"])
            }
            // Parse timeout from query.
            var timeout: TimeInterval = 30
            if let q = path.components(separatedBy: "?").dropFirst().first {
                for kv in q.components(separatedBy: "&") {
                    let pair = kv.components(separatedBy: "=")
                    if pair.count == 2, pair[0] == "timeout", let t = TimeInterval(pair[1]) {
                        timeout = min(t, kHookTimeout)
                    }
                }
            }
            let decision = pending.wait(timeout: timeout)
            if let d = decision {
                NotificationStore.shared.remove(id: id)
                return jsonResponse(200, ["decision": d.rawValue, "id": id])
            } else {
                // Still pending; tell hook to poll again (long-poll continuation).
                return jsonResponse(200, ["decision": "pending", "id": id])
            }
        }

        return jsonResponse(404, ["error": "not found"])
    }

    static func jsonResponse(_ status: Int, _ obj: [String: Any]) -> (Int, String, Data) {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return (status, "application/json", data)
    }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
