import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let processMonitor  = ProcessMonitor()
    private let sessionWatcher  = SessionWatcher()
    private let codexWatcher    = CodexSessionWatcher()

    private var claudeSessions: [SessionInfo] = []
    private var codexSessions:  [SessionInfo] = []
    private var allSessions:    [SessionInfo] { claudeSessions + codexSessions }

    private var refreshTimer: Timer?
    private var debugMode = false

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMonitors()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        // Image set once — recreating it on every updateButton call breaks title rendering.
        let img = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Claude")
        img?.isTemplate = true
        button.image = img
        button.imagePosition = .imageLeft

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        updateButton()
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }

        let processCount  = processMonitor.count
        let waitingCount  = allSessions.filter { $0.needsAttention }.count
        let activeCount   = allSessions.filter { $0.isRecentlyActive }.count
        let sessionCount  = max(processCount, waitingCount + activeCount)

        let label: String
        let labelColor: NSColor
        if waitingCount > 0 {
            label = " ?\(waitingCount)"
            labelColor = .systemOrange
        } else if activeCount > 0 {
            label = " ⚡\(activeCount)"
            labelColor = .labelColor
        } else if sessionCount > 0 {
            label = " \(sessionCount)"
            labelColor = .labelColor
        } else {
            label = ""
            labelColor = .labelColor
        }

        if label.isEmpty {
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
        } else {
            let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: labelColor]
            button.attributedTitle = NSAttributedString(string: label, attributes: attrs)
            button.imagePosition = .imageLeft
        }
    }

    // MARK: - Monitors

    private func setupMonitors() {
        processMonitor.onCountChange = { [weak self] _ in
            self?.updateButton()
            self?.rebuildMenu()
        }
        sessionWatcher.onUpdate = { [weak self] updated in
            self?.claudeSessions = updated
            self?.updateButton()
            self?.rebuildMenu()
        }
        codexWatcher.onUpdate = { [weak self] updated in
            self?.codexSessions = updated
            self?.updateButton()
            self?.rebuildMenu()
        }

        processMonitor.start()
        sessionWatcher.start()
        codexWatcher.start()

        // Refresh badge every 5 s so ⚡ expires naturally.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateButton()
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(into: menu)
    }

    // MARK: - Menu construction

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        rebuildMenu(into: menu)
    }

    private func rebuildMenu(into menu: NSMenu) {
        menu.removeAllItems()

        let sessions = allSessions
        let grandTotal = sessions.map { $0.totalUsage }.reduce(TokenCount(), +)
        let recentSessions = sessions
            .filter { $0.lastActivity > Date().addingTimeInterval(-86_400) }
            .sorted { a, b in
                if a.needsAttention   != b.needsAttention   { return a.needsAttention }
                if a.isRecentlyActive != b.isRecentlyActive { return a.isRecentlyActive }
                return a.lastActivity > b.lastActivity
            }

        // ── Global status ─────────────────────────────────────────────────
        let processCount   = processMonitor.count
        let activeCount    = sessions.filter { $0.isRecentlyActive }.count
        let attentionCount = sessions.filter { $0.needsAttention }.count
        let knownCount     = activeCount + attentionCount
        let idleCount      = max(0, processCount - knownCount)

        menu.addItem(header("Claude & Codex Observer"))
        menu.addItem(NSMenuItem.separator())

        let procLabel: String
        if knownCount == 0 && processCount == 0 {
            procLabel = "No active process"
        } else {
            var parts: [String] = []
            if attentionCount > 0 { parts.append("🟠 \(attentionCount) waiting") }
            if activeCount > 0    { parts.append("⚡ \(activeCount) working") }
            if idleCount > 0      { parts.append("⏸ \(idleCount) idle") }
            procLabel = parts.isEmpty ? "⏸ \(processCount) open" : parts.joined(separator: "  ·  ")
        }
        let procItem = NSMenuItem(title: procLabel, action: nil, keyEquivalent: "")
        procItem.isEnabled = false
        menu.addItem(procItem)

        // Provider breakdown (only if both have running processes)
        if processMonitor.claudeCount > 0 || processMonitor.codexCount > 0 {
            let subLabel = "[C] \(processMonitor.claudeCount) claude  ·  [X] \(processMonitor.codexCount) codex"
            let subItem = NSMenuItem(title: "  \(subLabel)", action: nil, keyEquivalent: "")
            subItem.isEnabled = false
            menu.addItem(subItem)
        }

        menu.addItem(NSMenuItem.separator())

        let totalItem = NSMenuItem(title: "Total: \(format(grandTotal))", action: nil, keyEquivalent: "")
        totalItem.isEnabled = false
        menu.addItem(totalItem)

        let detailItem = NSMenuItem(
            title: "  ↳ in \(format(grandTotal.input + grandTotal.cacheCreation + grandTotal.cacheRead))  out \(format(grandTotal.output))",
            action: nil, keyEquivalent: ""
        )
        detailItem.isEnabled = false
        menu.addItem(detailItem)

        // ── Per-session ───────────────────────────────────────────────────
        if !recentSessions.isEmpty {
            menu.addItem(NSMenuItem.separator())

            for session in recentSessions.prefix(15) {
                let status: String
                if session.isRecentlyActive {
                    status = "⚡"
                } else if session.needsAttention && processMonitor.count > 0 {
                    status = session.waitingState.icon
                } else {
                    status = "⏸"
                }

                let sessionTotal = session.totalUsage
                let sessionItem = NSMenuItem(
                    title: "\(session.provider.prefix) \(status) \(session.projectName)  —  \(format(sessionTotal))",
                    action: nil, keyEquivalent: ""
                )
                sessionItem.isEnabled = false
                menu.addItem(sessionItem)

                // Sub-agents (Claude only)
                for (agentId, agentTokens) in session.agents.sorted(by: { $0.key < $1.key }) {
                    let shortId = String(agentId.prefix(8))
                    let agentItem = NSMenuItem(
                        title: "    Agent \(shortId)  \(format(agentTokens))",
                        action: nil, keyEquivalent: ""
                    )
                    agentItem.isEnabled = false
                    agentItem.indentationLevel = 1
                    menu.addItem(agentItem)
                }
            }
        }

        // ── Debug ─────────────────────────────────────────────────────────
        menu.addItem(NSMenuItem.separator())
        let debugTitle = debugMode ? "Hide Debug Info" : "Show Debug Info"
        let debugToggle = NSMenuItem(title: debugTitle, action: #selector(toggleDebug), keyEquivalent: "d")
        menu.addItem(debugToggle)

        if debugMode {
            let attentionNames = sessions.filter { $0.needsAttention }
                .map { "\($0.provider.prefix)\($0.projectName)" }.joined(separator: ", ")
            let lines = [
                "claude (pgrep): \(processMonitor.claudeCount)  codex: \(processMonitor.codexCount)",
                "sessions total: \(sessions.count)  (claude \(claudeSessions.count) / codex \(codexSessions.count))",
                "active (⚡): \(activeCount)",
                "attention (🟠): \(attentionCount)" + (attentionCount > 0 ? " → \(attentionNames)" : ""),
            ] + sessions.map { s in
                "  [\(s.sessionId.prefix(8))] \(s.provider.prefix)\(s.projectName) | active=\(s.isRecentlyActive) | attn=\(s.needsAttention) | waiting=\(s.waitingState) | lastAct=\(Int(-s.lastActivity.timeIntervalSinceNow))s ago"
            }
            for line in lines {
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        // ── Footer ────────────────────────────────────────────────────────
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleDebug() {
        debugMode.toggle()
        rebuildMenu()
    }

    // MARK: - Formatting helpers

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        ]
        item.attributedTitle = NSAttributedString(string: title, attributes: attrs)
        return item
    }

    private func format(_ count: TokenCount) -> String { formatInt(count.total) }
    private func format(_ n: Int) -> String { formatInt(n) }

    private func formatInt(_ n: Int) -> String {
        switch n {
        case 0:            return "0 tok"
        case ..<1_000:     return "\(n) tok"
        case ..<1_000_000: return String(format: "%.1fK tok", Double(n) / 1_000)
        default:           return String(format: "%.2fM tok", Double(n) / 1_000_000)
        }
    }
}
