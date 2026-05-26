import SwiftUI
import AppKit

/// A non-activating floating panel that hosts one banner.
final class BannerPanel: NSPanel {
    override var canBecomeKey: Bool { false }   // never steal key-window focus
    override var canBecomeMain: Bool { false }
}

/// NSHostingView that accepts the first mouse click without requiring prior key-window activation.
/// Without this, clicking a non-key panel consumes the first click for activation,
/// requiring a second click to trigger SwiftUI tap gestures.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Manages the stack of banner panels in the top-right of the main screen.
@MainActor
final class PanelManager {
    static let shared = PanelManager()

    private var screenObserver: NSObjectProtocol?

    init() {
        // Re-layout whenever displays are connected or disconnected.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.layoutPanels() }
        }
    }

    deinit {
        if let obs = screenObserver { NotificationCenter.default.removeObserver(obs) }
    }

    /// The screen banners should appear on: external monitor preferred, main as fallback.
    private var targetScreen: NSScreen {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return NSScreen.main ?? screens[0] }

        // macOS 12+: localizedName contains "Built-in" for the internal display.
        if #available(macOS 12, *) {
            if let ext = screens.first(where: {
                !$0.localizedName.localizedCaseInsensitiveContains("built-in") &&
                !$0.localizedName.localizedCaseInsensitiveContains("내장")
            }) { return ext }
        }

        // Fallback: CoreGraphics built-in check (works on macOS 13+).
        for screen in screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let id = CGDirectDisplayID(num.uint32Value)
                if CGDisplayIsBuiltin(id) == 0 { return screen }
            }
        }

        return NSScreen.main ?? screens[0]
    }

    private struct Entry {
        let id: String
        let panel: BannerPanel
        let height: CGFloat
        let needsResponse: Bool   // false for informational (stop/notify) banners
        let event: EventRequest   // kept for focus decisions on info banners
    }

    private var entries: [Entry] = []
    private let topMargin: CGFloat    = 10   // matches macOS native notification top gap
    private let rightMargin: CGFloat  = 10   // matches macOS native notification right gap
    private let bannerWidth: CGFloat  = 340
    private let stackOffsetY: CGFloat = 6
    private let stackOffsetX: CGFloat = 2
    private let maxVisibleDepth: Int  = 4

    // MARK: - Show

    /// Blocking banner: waits for user decision (permission / question).
    func showBanner(id: String, event: EventRequest) {
        _show(id: id, event: event, needsResponse: true)
    }

    /// Informational banner: no response needed (stop / notify).
    func showInfoBanner(id: String, event: EventRequest) {
        _show(id: id, event: event, needsResponse: false)
    }

    private func _show(id: String, event: EventRequest, needsResponse: Bool) {
        let host = FirstMouseHostingView(rootView: BannerView(id: id, event: event) { [weak self] bid, decision in
            self?.handleDecision(id: bid, decision: decision, event: event, needsResponse: needsResponse)
        })
        host.layout()
        let fitting = host.fittingSize
        let width  = max(fitting.width, bannerWidth)
        let height = max(fitting.height, 60)
        let rect   = NSRect(x: 0, y: 0, width: width + 4, height: height + 4)
        host.frame = rect
        host.autoresizingMask = [.width, .height]

        let panel = BannerPanel(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel    = true
        panel.level              = .statusBar
        panel.backgroundColor   = .clear
        panel.isOpaque          = false
        panel.hasShadow         = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = host

        entries.append(Entry(id: id, panel: panel, height: height + 14,
                             needsResponse: needsResponse, event: event))
        layoutPanels()
        panel.orderFrontRegardless()
        Logger.log("BANNER_SHOWN id=\(id) kind=\(event.kind.rawValue) blocking=\(needsResponse) stack=\(entries.count)")
    }

    // MARK: - Decision

    func applyDecision(id: String, decision: UserDecision) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        handleDecision(id: id, decision: decision, event: entry.event,
                       needsResponse: entry.needsResponse)
    }

    private func handleDecision(id: String, decision: UserDecision,
                                event: EventRequest, needsResponse: Bool) {
        Logger.log("DECISION id=\(id) decision=\(decision.rawValue)")

        if decision == .focus {
            TmuxFocus.focus(session: event.tmuxSession, target: event.tmuxTarget, tty: event.tty)
        }

        if decision == .allowSession, let tool = event.tool, !tool.isEmpty {
            writeSessionCache(tool: tool, tmuxSession: event.tmuxSession)
        }

        if needsResponse {
            NotificationStore.shared.resolve(id: id, decision: decision)
            NotificationStore.shared.remove(id: id)
        }
        removeBanner(id: id)
    }

    // MARK: - Session Cache

    private func writeSessionCache(tool: String, tmuxSession: String?) {
        let key = (tmuxSession?.isEmpty == false ? tmuxSession! : "global")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let path = "/tmp/claude-notifier-allowed-\(key)"
        let line = tool + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path),
           let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        Logger.log("SESSION_CACHE written tool=\(tool) key=\(key)")
    }

    // MARK: - Remove / Clear

    func removeBanner(id: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: idx)
        entry.panel.orderOut(nil)
        entry.panel.close()
        layoutPanels()
        Logger.log("BANNER_REMOVED id=\(id) stack=\(entries.count)")
    }

    func clearAll() {
        for entry in entries {
            if entry.needsResponse {
                NotificationStore.shared.resolve(id: entry.id, decision: .dismiss)
                NotificationStore.shared.remove(id: entry.id)
            }
            entry.panel.orderOut(nil)
            entry.panel.close()
        }
        entries.removeAll()
        Logger.log("BANNER_CLEAR_ALL")
    }

    // MARK: - Layout (overlap stack)

    private func layoutPanels() {
        guard !entries.isEmpty else { return }
        let screen = targetScreen
        let vf     = screen.visibleFrame
        let count = entries.count
        let baseX = vf.maxX - rightMargin - (bannerWidth + 4)  // +4 = panel border
        // Anchor by TOP edge so taller banners extend downward, never upward.
        let topAnchor = vf.maxY - topMargin

        for (idx, entry) in entries.enumerated() {
            let depth  = (count - 1) - idx   // newest = 0, oldest = count-1
            let capped = min(depth, maxVisibleDepth - 1)

            let panelTop = topAnchor - CGFloat(capped) * stackOffsetY
            let x = baseX - CGFloat(capped) * stackOffsetX
            let y = panelTop - entry.panel.frame.height   // origin = top - height

            entry.panel.level = NSWindow.Level(
                rawValue: NSWindow.Level.statusBar.rawValue + idx)
            entry.panel.setFrameOrigin(NSPoint(x: x, y: y))
            if !entry.panel.isVisible { entry.panel.orderFrontRegardless() }
        }
    }
}
