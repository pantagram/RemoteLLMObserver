# RemoteLLMObserver

A lightweight macOS menu bar app that monitors active [Claude CLI](https://github.com/anthropics/claude-code) and [Codex CLI](https://github.com/openai/codex) sessions in real time, tracking process state and token consumption.

## Features

- **Live session count** — shows the number of open Claude and Codex sessions directly in the menu bar
- **Active work indicator** — a ⚡ badge with a count appears when one or more sessions are actively processing
- **Token usage** — click the icon to see total token consumption (input / output / cache) broken down per session and per sub-agent
- **24-hour history** — sessions from the last 24 hours are listed even after they finish
- **Shell utilities** — companion scripts for CLI access and Bartender integration (Claude only)

## How it works

| Mechanism | Provider | Purpose |
|-----------|----------|---------|
| `pgrep -x claude/codex` (every 5s) | Both | Counts running processes |
| FSEvents on `~/.claude/projects/` | Claude | Detects file writes in real time (zero CPU when idle) |
| Incremental JSONL parsing | Claude | Reads only new bytes on each FSEvents notification |
| FSEvents on `~/.codex/sessions/` | Codex | Detects JSONL updates from active sessions |
| SQLite read on `~/.codex/state_5.sqlite` | Codex | Loads thread metadata and token totals |
| 5s refresh timer | Both | Expires the ⚡ badge when activity stops |

**CPU impact is negligible** — FSEvents is fully event-driven; the only polling is a lightweight `pgrep` call every 5 seconds.

## Menu bar states

| Display | Meaning |
|---------|---------|
| Icon only | No Claude or Codex processes running |
| Icon + number | N sessions open, none currently processing |
| Icon + ⚡N | N sessions actively writing output |

## Requirements

- macOS 12.0+
- Xcode Command Line Tools

```bash
xcode-select --install
```

## Build & install

### 1. Clone the repo

```bash
git clone https://github.com/pantagram/RemoteLLMObserver.git
cd RemoteLLMObserver
```

### 2. Build

```bash
bash build.sh
```

This compiles all Swift sources with `swiftc` and assembles the `.app` bundle under `.build/RemoteLLMObserver.app`. No Xcode project or package manager required.

### 3. Run or install

```bash
# Run directly from the build directory
open .build/RemoteLLMObserver.app

# Or install to ~/Applications
cp -r .build/RemoteLLMObserver.app ~/Applications/
open ~/Applications/RemoteLLMObserver.app
```

The app runs as a menu bar agent (no Dock icon). To quit, click the icon in the menu bar and select **Quit**.

## Shell utilities

These scripts cover Claude CLI sessions only.

### `status.sh`
Prints a full status report in the terminal:
```bash
bash status.sh
```

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Claude CLI Observer
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Processes  : 3 running
 Total      : 12.4M tok
   ↳ in 11.9M tok  out 512.3K tok

 Sessions (dernières 24h) :
 ⚡ MyProject  [a1b2c3d4]  8.2M tok  (last: 14:32:01)
 ⏸ OtherApp   [e5f6g7h8]  4.2M tok  (last: 13:10:44)
```

### `has-active-sessions.sh`
Returns `true` / `exit 0` if at least one Claude session consumed tokens in the last 10 minutes (same as « Last 10 min » in `status.sh`) — designed for [Bartender](https://www.macbartender.com/) trigger scripts:
```bash
bash has-active-sessions.sh && echo "active" || echo "idle"
```

## Project structure

```
Sources/
  main.swift                — NSApplication entry point
  AppDelegate.swift         — NSStatusItem, menu construction, badge logic
  Models.swift              — SessionInfo, TokenCount data structures
  ProcessMonitor.swift      — Claude and Codex process detection via pgrep
  SessionWatcher.swift      — FSEvents watcher + incremental JSONL parsing (Claude)
  CodexSessionWatcher.swift — SQLite + FSEvents watcher (Codex)
  TokenParser.swift         — JSONL token extraction
  Settings.swift            — User preferences (paths, icon, debug mode)
  SettingsWindowController.swift — Preferences panel
Resources/
  Info.plist           — LSUIElement (no Dock icon), bundle metadata
build.sh               — Compiles and assembles the .app bundle
status.sh              — CLI status report (Claude)
has-active-sessions.sh — Bartender trigger script (Claude)
```

## Token fields tracked

**Claude** — each JSONL `assistant` message contributes:
- `input_tokens`
- `output_tokens`
- `cache_creation_input_tokens`
- `cache_read_input_tokens`

Sub-agent sessions (under `{sessionId}/subagents/`) are parsed separately and listed under their parent session.

**Codex** — token totals come from `token_count` events in session JSONL files, falling back to the `tokens_used` field in the SQLite database.
