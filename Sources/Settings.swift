import Foundation

/// Persistent app settings stored in UserDefaults.
final class Settings {
    static let shared = Settings()
    private init() {}

    // MARK: - Available icons (SF Symbols)

    static let iconOptions: [(label: String, symbol: String)] = [
        ("Terminal",         "terminal"),
        ("CPU",              "cpu"),
        ("Eye",              "eye"),
        ("Lightning",        "bolt"),
        ("Network",          "network"),
        ("Server rack",      "server.rack"),
        ("Antenna",          "antenna.radiowaves.left.and.right"),
        ("Radio waves",      "dot.radiowaves.left.and.right"),
        ("Cloud",            "cloud"),
        ("Desktop",          "desktopcomputer"),
        ("Memory chip",      "memorychip"),
        ("Chart",            "chart.bar"),
        ("Waveform",         "waveform"),
        ("Sparkles",         "sparkles"),
        ("Infinity",         "infinity"),
        ("List",             "list.bullet"),
        ("Grid",             "square.grid.2x2"),
        ("Gear",             "gearshape"),
        ("Tray",             "tray"),
        ("Person wave",      "person.wave.2"),
        ("Chat bubbles",     "bubble.left.and.bubble.right"),
        ("Scope",            "scope"),
        ("Brain",            "brain"),
        ("Loop",             "arrow.triangle.2.circlepath"),
    ]

    // MARK: - Defaults

    static let defaultIconSymbol        = "terminal"
    static let defaultClaudeProjectsPath = "~/.claude/projects"
    static let defaultCodexSessionsPath  = "~/.codex/sessions"
    static let defaultCodexDBPath        = "~/.codex/state_5.sqlite"

    // MARK: - Keys

    private enum Key: String {
        case iconSymbol          = "iconSymbol"
        case claudeProjectsPath  = "claudeProjectsPath"
        case codexSessionsPath   = "codexSessionsPath"
        case codexDBPath         = "codexDBPath"
        case debugMode           = "debugMode"
    }

    // MARK: - Stored properties

    var iconSymbol: String {
        get { UserDefaults.standard.string(forKey: Key.iconSymbol.rawValue) ?? Self.defaultIconSymbol }
        set { UserDefaults.standard.set(newValue, forKey: Key.iconSymbol.rawValue) }
    }

    var claudeProjectsPath: String {
        get { UserDefaults.standard.string(forKey: Key.claudeProjectsPath.rawValue) ?? Self.defaultClaudeProjectsPath }
        set { UserDefaults.standard.set(newValue, forKey: Key.claudeProjectsPath.rawValue) }
    }

    var codexSessionsPath: String {
        get { UserDefaults.standard.string(forKey: Key.codexSessionsPath.rawValue) ?? Self.defaultCodexSessionsPath }
        set { UserDefaults.standard.set(newValue, forKey: Key.codexSessionsPath.rawValue) }
    }

    var codexDBPath: String {
        get { UserDefaults.standard.string(forKey: Key.codexDBPath.rawValue) ?? Self.defaultCodexDBPath }
        set { UserDefaults.standard.set(newValue, forKey: Key.codexDBPath.rawValue) }
    }

    var debugMode: Bool {
        get { UserDefaults.standard.bool(forKey: Key.debugMode.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.debugMode.rawValue) }
    }

    // MARK: - Resolved URLs (tilde expanded)

    var claudeProjectsURL: URL { resolved(claudeProjectsPath) }
    var codexSessionsURL:  URL { resolved(codexSessionsPath) }
    var codexDBURL:        URL { resolved(codexDBPath) }

    private func resolved(_ path: String) -> URL {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }

    // MARK: - Reset

    func resetToDefaults() {
        iconSymbol          = Self.defaultIconSymbol
        claudeProjectsPath  = Self.defaultClaudeProjectsPath
        codexSessionsPath   = Self.defaultCodexSessionsPath
        codexDBPath         = Self.defaultCodexDBPath
        debugMode           = false
    }
}
