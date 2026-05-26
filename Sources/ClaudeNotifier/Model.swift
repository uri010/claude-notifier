import Foundation

/// Kind of notification event coming from a Claude Code hook.
enum EventKind: String, Codable {
    case permission      // PreToolUse simple yes/no/allow-session
    case question        // complex prompt: show summary, click -> focus tmux
    case stop            // task completed
    case notification    // generic notification
}

/// A request payload posted by the hook script.
struct EventRequest: Codable {
    var kind: EventKind
    var title: String
    var summary: String
    /// Description of the current task / context (session, folder).
    var context: String?
    /// Error message when the task failed.
    var error: String?
    /// tmux session name (for focus on click).
    var tmuxSession: String?
    /// tmux pane/window target for switch-client.
    var tmuxTarget: String?
    /// The tool being requested (for permission events).
    var tool: String?
    /// Working directory.
    var cwd: String?
    /// TTY of the terminal running the hook (e.g. "ttys003"), for tab focus fallback.
    var tty: String?
}

/// The user's response to a permission/question banner.
enum UserDecision: String, Codable {
    case allow            // yes (one time)
    case allowSession     // allow for the rest of session
    case deny             // no
    case dismiss          // X button / banner click with no explicit decision
    case timeout          // no response in time
    case focus            // user clicked to focus the tmux session
}

/// Stored response for a pending event, resolved when the user acts.
final class PendingResponse {
    let id: String
    var decision: UserDecision?
    let created: Date
    private let lock = NSCondition()

    init(id: String) {
        self.id = id
        self.created = Date()
    }

    func resolve(_ decision: UserDecision) {
        lock.lock()
        if self.decision == nil {
            self.decision = decision
        }
        lock.signal()
        lock.unlock()
    }

    /// Blocks up to `timeout` seconds waiting for a decision.
    func wait(timeout: TimeInterval) -> UserDecision? {
        lock.lock()
        defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while decision == nil {
            if !lock.wait(until: deadline) { break }
        }
        return decision
    }

    /// Non-blocking peek.
    func current() -> UserDecision? {
        lock.lock()
        defer { lock.unlock() }
        return decision
    }
}
