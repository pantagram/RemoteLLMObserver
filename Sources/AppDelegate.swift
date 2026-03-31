import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let processMonitor = ProcessMonitor()
    private let sessionWatcher = SessionWatcher()
    private var sessions: [SessionInfo] = []
    private var refreshTimer: Timer?
    private var isImageColored = false
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

        // Image définie une seule fois — la recréer à chaque update perturbe le rendu du title
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

        let processCount   = processMonitor.count
        let waitingCount   = sessions.filter { $0.needsAttention }.count
        let activeCount    = sessions.filter { $0.isRecentlyActive }.count
        let sessionCount   = max(processCount, waitingCount + activeCount)

        // Priority: waiting > working > open
        let title: String
        if waitingCount > 0 {
            setIconColor(orange: true)
            title = " ?\(waitingCount)"
        } else if activeCount > 0 {
            setIconColor(orange: false)
            title = " ⚡\(activeCount)"
        } else if sessionCount > 0 {
            setIconColor(orange: false)
            title = " \(sessionCount)"
        } else {
            setIconColor(orange: false)
            title = ""
        }

        // Always sync title and imagePosition together — AppKit resets
        // imagePosition to .imageOnly when title is set to "" and doesn't
        // restore it automatically when a title is set again later.
        button.title = title
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeft
    }

    /// Only rebuilds the NSImage when the colour state actually changes.
    private func setIconColor(orange: Bool) {
        guard orange != isImageColored else { return }
        isImageColored = orange
        guard let button = statusItem.button else { return }

        if orange {
            let cfg = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
            button.image = NSImage(systemSymbolName: "terminal",
                                   accessibilityDescription: "Claude")?
                .withSymbolConfiguration(cfg)
        } else {
            let img = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Claude")
            img?.isTemplate = true
            button.image = img
        }
    }

    // MARK: - Monitors

    private func setupMonitors() {
        processMonitor.onCountChange = { [weak self] _ in
            self?.updateButton()
            self?.rebuildMenu()
        }
        sessionWatcher.onUpdate = { [weak self] updated in
            self?.sessions = updated
            self?.updateButton()
            self?.rebuildMenu()
        }
        processMonitor.start()
        sessionWatcher.start()

        // Rafraîchit le badge toutes les 5s pour expirer les ⚡ en temps voulu.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateButton()
        }
    }

    // MARK: - NSMenuDelegate — rebuild just before display

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

        let grandTotal = sessions.map { $0.totalUsage }.reduce(TokenCount(), +)
        let recentSessions = sessions
            .filter { $0.lastActivity > Date().addingTimeInterval(-86_400) }
            .sorted { a, b in
                // 1. waiting for attention  2. actively working  3. rest by date
                if a.needsAttention != b.needsAttention { return a.needsAttention }
                if a.isRecentlyActive != b.isRecentlyActive { return a.isRecentlyActive }
                return a.lastActivity > b.lastActivity
            }

        // ── Global total ──────────────────────────────────────────────────
        let processCount    = processMonitor.count
        let activeCount     = sessions.filter { $0.isRecentlyActive }.count
        let attentionCount  = sessions.filter { $0.needsAttention }.count
        let knownCount      = activeCount + attentionCount
        let idleCount       = max(0, processCount - knownCount)

        menu.addItem(header("Claude CLI Observer"))
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
                    status = session.waitingState.icon   // 💬 or 🔐
                } else {
                    status = "⏸"
                }
                let sessionTotal = session.totalUsage

                let sessionItem = NSMenuItem(
                    title: "\(status) \(session.projectName)  —  \(format(sessionTotal))",
                    action: nil, keyEquivalent: ""
                )
                sessionItem.isEnabled = false
                menu.addItem(sessionItem)

                // Agents
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
            let lines = [
                "processes (ps): \(processCount)",
                "sessions total: \(sessions.count)",
                "active (⚡): \(activeCount)",
                "attention (🟠): \(attentionCount)",
            ] + sessions.map { s in
                "  [\(s.sessionId.prefix(8))] \(s.projectName) | active=\(s.isRecentlyActive) | attn=\(s.needsAttention) | waiting=\(s.waitingState) | lastAct=\(Int(-s.lastActivity.timeIntervalSinceNow))s ago"
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

    /// Formats a TokenCount as a compact string, e.g. "142.3K tokens"
    private func format(_ count: TokenCount) -> String {
        formatInt(count.total)
    }

    private func format(_ n: Int) -> String { formatInt(n) }

    private func formatInt(_ n: Int) -> String {
        switch n {
        case 0:           return "0 tok"
        case ..<1_000:    return "\(n) tok"
        case ..<1_000_000: return String(format: "%.1fK tok", Double(n) / 1_000)
        default:           return String(format: "%.2fM tok", Double(n) / 1_000_000)
        }
    }
}
