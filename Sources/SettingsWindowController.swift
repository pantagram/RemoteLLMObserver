import AppKit

/// Preferences window for RemoteLLMObserver.
/// All controls are built programmatically — no NIB.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    /// Called after the user clicks Save.
    /// `pathsChanged` is true when any watched path was modified → watchers must restart.
    var onSave: ((_ pathsChanged: Bool) -> Void)?

    // MARK: - Controls
    private var iconPopup:          NSPopUpButton!
    private var claudePathField:    NSTextField!
    private var codexSessionsField: NSTextField!
    private var codexDBField:       NSTextField!
    private var debugCheckbox:      NSButton!
    private var hideIdleCheckbox:   NSButton!

    // Original values (to detect path changes)
    private var originalClaudePath:    String = ""
    private var originalCodexSessions: String = ""
    private var originalCodexDB:       String = ""

    // MARK: - Init

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 455),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Preferences"
        win.isReleasedWhenClosed = false
        win.center()
        self.init(window: win)
        win.delegate = self
        buildUI()
    }

    override init(window: NSWindow?) { super.init(window: window) }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public

    func showWindow() {
        loadCurrentValues()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Load current settings into controls

    private func loadCurrentValues() {
        let s = Settings.shared

        // Icon popup
        let idx = Settings.iconOptions.firstIndex(where: { $0.symbol == s.iconSymbol }) ?? 0
        iconPopup.selectItem(at: idx)

        // Paths
        claudePathField.stringValue    = s.claudeProjectsPath
        codexSessionsField.stringValue = s.codexSessionsPath
        codexDBField.stringValue       = s.codexDBPath

        // Debug
        debugCheckbox.state = s.debugMode ? .on : .off

        // Hide idle processes
        hideIdleCheckbox.state = s.hideIdleProcesses ? .on : .off

        // Snapshot originals
        originalClaudePath    = s.claudeProjectsPath
        originalCodexSessions = s.codexSessionsPath
        originalCodexDB       = s.codexDBPath
    }

    // MARK: - UI construction

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        // ── Appearance ────────────────────────────────────────────────────
        stack.addArrangedSubview(sectionLabel("Appearance"))

        iconPopup = buildIconPopup()
        stack.addArrangedSubview(iconRow())

        // ── Claude CLI ────────────────────────────────────────────────────
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionLabel("Claude CLI"))

        claudePathField = pathField()
        stack.addArrangedSubview(
            pathRow(label: "Projects path:", field: claudePathField,
                    defaultValue: Settings.defaultClaudeProjectsPath,
                    browseDir: true, tag: 0)
        )

        // ── Codex CLI ─────────────────────────────────────────────────────
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionLabel("Codex CLI"))

        codexSessionsField = pathField()
        stack.addArrangedSubview(
            pathRow(label: "Sessions dir:", field: codexSessionsField,
                    defaultValue: Settings.defaultCodexSessionsPath,
                    browseDir: true, tag: 1)
        )

        codexDBField = pathField()
        stack.addArrangedSubview(
            pathRow(label: "Database path:", field: codexDBField,
                    defaultValue: Settings.defaultCodexDBPath,
                    browseDir: false, tag: 2)
        )

        // ── Advanced ──────────────────────────────────────────────────────
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionLabel("Advanced"))

        debugCheckbox = NSButton(checkboxWithTitle: "Enable debug info in menu", target: nil, action: nil)
        stack.addArrangedSubview(debugCheckbox)

        hideIdleCheckbox = NSButton(checkboxWithTitle: "Hide idle processes", target: nil, action: nil)
        stack.addArrangedSubview(hideIdleCheckbox)

        // Elastic spacer
        let spacer = NSView()
        spacer.setContentHuggingPriority(.fittingSizeCompression, for: .vertical)
        stack.addArrangedSubview(spacer)

        // ── Footer ────────────────────────────────────────────────────────
        stack.addArrangedSubview(footerRow())
        stack.setCustomSpacing(16, after: spacer)
    }

    // MARK: - Section header

    private func sectionLabel(_ text: String) -> NSTextField {
        let tf = NSTextField(labelWithString: text)
        tf.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        tf.textColor = .secondaryLabelColor
        return tf
    }

    // MARK: - Separator

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        // Make separator fill the full width
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(box)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: wrapper.topAnchor),
            box.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            box.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            wrapper.heightAnchor.constraint(equalToConstant: 10),
        ])
        return wrapper
    }

    // MARK: - Icon row

    private func buildIconPopup() -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.removeAllItems()
        for option in Settings.iconOptions {
            let item = NSMenuItem(title: option.label, action: nil, keyEquivalent: "")
            if let img = NSImage(systemSymbolName: option.symbol, accessibilityDescription: nil) {
                img.isTemplate = false   // show in colour in menu
                item.image = img
            }
            popup.menu?.addItem(item)
        }
        return popup
    }

    private func iconRow() -> NSView {
        let row = hStack()
        row.addArrangedSubview(rowLabel("Icon:"))
        row.addArrangedSubview(iconPopup)
        row.addArrangedSubview(NSView())   // spacer
        return row
    }

    // MARK: - Path rows

    private func pathField() -> NSTextField {
        let tf = NSTextField()
        tf.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tf.placeholderString = "Enter path or Browse…"
        tf.lineBreakMode = .byTruncatingMiddle
        return tf
    }

    private func pathRow(label: String, field: NSTextField,
                         defaultValue: String, browseDir: Bool, tag: Int) -> NSView {
        let row = hStack()

        row.addArrangedSubview(rowLabel(label))
        row.addArrangedSubview(field)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let browseBtn = smallButton("Browse…", action: #selector(handleBrowse(_:)), tag: tag)
        row.addArrangedSubview(browseBtn)

        let resetBtn = smallButton("↩ Default", action: #selector(handleReset(_:)), tag: tag)
        row.addArrangedSubview(resetBtn)

        return row
    }

    // MARK: - Footer

    private func footerRow() -> NSView {
        let row = hStack()

        let resetAllBtn = NSButton(title: "Reset All", target: self, action: #selector(resetAll))
        resetAllBtn.bezelStyle = .rounded
        row.addArrangedSubview(resetAllBtn)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)

        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1B}"   // Escape
        row.addArrangedSubview(cancelBtn)

        let saveBtn = NSButton(title: "Save", target: self, action: #selector(save))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"          // Return
        row.addArrangedSubview(saveBtn)

        return row
    }

    // MARK: - Primitive helpers

    private func hStack() -> NSStackView {
        let s = NSStackView()
        s.orientation = .horizontal
        s.spacing = 8
        s.alignment = .centerY
        return s
    }

    private func rowLabel(_ text: String) -> NSTextField {
        let tf = NSTextField(labelWithString: text)
        tf.alignment = .right
        tf.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        tf.widthAnchor.constraint(equalToConstant: 110).isActive = true
        return tf
    }

    private func smallButton(_ title: String, action: Selector, tag: Int) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .rounded
        btn.controlSize = .small
        btn.tag = tag
        return btn
    }

    // MARK: - Actions

    @objc private func handleBrowse(_ sender: NSButton) {
        let field: NSTextField
        let forDir: Bool
        switch sender.tag {
        case 0: field = claudePathField;    forDir = true
        case 1: field = codexSessionsField; forDir = true
        case 2: field = codexDBField;       forDir = false
        default: return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles       = !forDir
        panel.canChooseDirectories = forDir
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = forDir

        let expanded = NSString(string: field.stringValue).expandingTildeInPath
        let base = URL(fileURLWithPath: expanded)
        panel.directoryURL = forDir ? base : base.deletingLastPathComponent()

        panel.begin { [weak field] result in
            guard result == .OK, let url = panel.url, let field else { return }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var path = url.path
            if path.hasPrefix(home) {
                path = "~" + path.dropFirst(home.count)
            }
            field.stringValue = path
        }
    }

    @objc private func handleReset(_ sender: NSButton) {
        switch sender.tag {
        case 0: claudePathField.stringValue    = Settings.defaultClaudeProjectsPath
        case 1: codexSessionsField.stringValue = Settings.defaultCodexSessionsPath
        case 2: codexDBField.stringValue       = Settings.defaultCodexDBPath
        default: break
        }
    }

    @objc private func resetAll() {
        let defaultIdx = Settings.iconOptions.firstIndex(where: { $0.symbol == Settings.defaultIconSymbol }) ?? 0
        iconPopup.selectItem(at: defaultIdx)
        claudePathField.stringValue    = Settings.defaultClaudeProjectsPath
        codexSessionsField.stringValue = Settings.defaultCodexSessionsPath
        codexDBField.stringValue       = Settings.defaultCodexDBPath
        debugCheckbox.state = .off
        hideIdleCheckbox.state = .off
    }

    @objc private func cancel() {
        window?.close()
    }

    @objc private func save() {
        let pathsChanged = claudePathField.stringValue    != originalClaudePath
                        || codexSessionsField.stringValue != originalCodexSessions
                        || codexDBField.stringValue       != originalCodexDB

        let s = Settings.shared
        s.iconSymbol         = Settings.iconOptions[safe: iconPopup.indexOfSelectedItem]?.symbol ?? Settings.defaultIconSymbol
        s.claudeProjectsPath = claudePathField.stringValue
        s.codexSessionsPath  = codexSessionsField.stringValue
        s.codexDBPath        = codexDBField.stringValue
        s.debugMode          = debugCheckbox.state == .on
        s.hideIdleProcesses  = hideIdleCheckbox.state == .on

        window?.close()
        onSave?(pathsChanged)
    }
}

// MARK: - Safe array subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
