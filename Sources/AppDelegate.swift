import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let processMonitor = ProcessMonitor()
    private let sessionWatcher = SessionWatcher()
    private var sessions: [SessionInfo] = []
    private var refreshTimer: Timer?

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

        let activeCount  = sessions.filter { $0.isRecentlyActive }.count
        let processCount = processMonitor.count

        if processCount == 0 {
            button.title = ""
        } else if activeCount > 0 {
            button.title = " ⚡\(activeCount)"
        } else {
            button.title = " \(processCount)"
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
                if a.isRecentlyActive != b.isRecentlyActive { return a.isRecentlyActive }
                return a.lastActivity > b.lastActivity
            }

        // ── Global total ──────────────────────────────────────────────────
        let activeCount  = sessions.filter { $0.isRecentlyActive }.count
        let processCount = processMonitor.count
        let waitingCount = max(0, processCount - activeCount)

        menu.addItem(header("Claude CLI Observer"))
        menu.addItem(NSMenuItem.separator())

        let procLabel: String
        if processCount == 0 {
            procLabel = "No active process"
        } else {
            var parts: [String] = []
            if activeCount > 0  { parts.append("⚡ \(activeCount) working") }
            if waitingCount > 0 { parts.append("⏸ \(waitingCount) waiting") }
            procLabel = parts.joined(separator: "  ·  ")
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
                let status = session.isRecentlyActive ? "⚡" : "⏸"
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

        // ── Footer ────────────────────────────────────────────────────────
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
