import Foundation
import AppKit

/// Central store: holds pending responses, bridges HTTP server <-> UI.
final class NotificationStore {
    static let shared = NotificationStore()

    private var pending: [String: PendingResponse] = [:]
    private var events: [String: EventRequest] = [:]
    private let lock = NSLock()

    /// Called on the main thread to create a banner for an event.
    var onEvent: ((String, EventRequest) -> Void)?
    /// Called on the main thread to remove a banner that was resolved (e.g. by timeout / hook side).
    var onRemove: ((String) -> Void)?

    func createPending(for event: EventRequest) -> String {
        let id = UUID().uuidString
        let p = PendingResponse(id: id)
        lock.lock()
        pending[id] = p
        events[id] = event
        lock.unlock()
        // Drive UI on main thread.
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(id, event)
        }
        return id
    }

    func pendingResponse(for id: String) -> PendingResponse? {
        lock.lock(); defer { lock.unlock() }
        return pending[id]
    }

    func event(for id: String) -> EventRequest? {
        lock.lock(); defer { lock.unlock() }
        return events[id]
    }

    /// Resolve a pending decision (called by UI buttons).
    func resolve(id: String, decision: UserDecision) {
        lock.lock()
        let p = pending[id]
        lock.unlock()
        p?.resolve(decision)
    }

    /// Remove a finished pending entry.
    func remove(id: String) {
        lock.lock()
        pending.removeValue(forKey: id)
        events.removeValue(forKey: id)
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onRemove?(id)
        }
    }

    func pendingCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }
}
