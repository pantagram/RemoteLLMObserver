#!/bin/bash
# Claude & Codex Observer — status en ligne de commande
# Usage: ./status.sh [--watch]

set -u

WATCH_MODE=false
[[ "${1-}" == "--watch" ]] && WATCH_MODE=true

count_named_process() {
    local name="$1"
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -x "$name" 2>/dev/null | wc -l | tr -d ' '
    else
        ps -eo comm 2>/dev/null | grep -cE "(^|/)${name}$" || true
    fi
}

run_status() {
    local claude_count codex_count proc_count
    claude_count=$(count_named_process claude)
    codex_count=$(count_named_process codex)
    proc_count=$(( claude_count + codex_count ))

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " Claude & Codex Observer"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude/projects}" \
    CODEX_SESSIONS_DIR="${CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}" \
    CODEX_DB_PATH="${CODEX_DB_PATH:-$HOME/.codex/state_5.sqlite}" \
    PROC_COUNT="$proc_count" \
    CLAUDE_COUNT="$claude_count" \
    CODEX_COUNT="$codex_count" \
    python3 - <<'PYEOF'
import json
import os
import sqlite3
from pathlib import Path

now = int(__import__("time").time())
cutoff_24h = now - 86400
cutoff_active = now - 30
proc_count = int(os.environ.get("PROC_COUNT", "0"))
claude_count = int(os.environ.get("CLAUDE_COUNT", "0"))
codex_count = int(os.environ.get("CODEX_COUNT", "0"))
claude_dir = Path(os.environ.get("CLAUDE_DIR", str(Path.home() / ".claude/projects"))).expanduser()
codex_sessions_dir = Path(os.environ.get("CODEX_SESSIONS_DIR", str(Path.home() / ".codex/sessions"))).expanduser()
codex_db_path = Path(os.environ.get("CODEX_DB_PATH", str(Path.home() / ".codex/state_5.sqlite"))).expanduser()

def format_tokens(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.2f}M tok"
    if n >= 1_000:
        return f"{n / 1_000:.1f}K tok"
    return f"{n} tok"

def mtime(path: Path) -> int:
    try:
        return int(path.stat().st_mtime)
    except Exception:
        return 0

def parse_claude_jsonl(path: Path):
    tin = tout = tcc = tcr = 0
    last = None
    try:
        with path.open(errors="replace") as f:
            for raw in f:
                line = raw.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                last = obj
                usage = None
                t = obj.get("type")
                if t == "assistant":
                    usage = obj.get("message", {}).get("usage")
                elif t == "progress":
                    usage = obj.get("data", {}).get("message", {}).get("usage")
                if usage:
                    tin += int(usage.get("input_tokens", 0) or 0)
                    tout += int(usage.get("output_tokens", 0) or 0)
                    tcc += int(usage.get("cache_creation_input_tokens", 0) or 0)
                    tcr += int(usage.get("cache_read_input_tokens", 0) or 0)
    except Exception:
        return None

    state = "none"
    if isinstance(last, dict) and last.get("type") == "assistant":
        content = last.get("message", {}).get("content", [])
        if isinstance(content, list) and any(isinstance(c, dict) and c.get("type") == "tool_use" for c in content):
            state = "waiting_approval"
        else:
            state = "waiting_response"
    return {"input": tin, "output": tout, "cache_creation": tcc, "cache_read": tcr, "waiting_state": state}

def read_last_json(path: Path):
    last = None
    try:
        with path.open(errors="replace") as f:
            for raw in f:
                line = raw.strip()
                if not line:
                    continue
                try:
                    last = json.loads(line)
                except Exception:
                    continue
    except Exception:
        return None
    return last

def parse_codex_token_count(path: Path):
    try:
        size = path.stat().st_size
        if size <= 0:
            return None
        with path.open("rb") as f:
            chunk = min(size, 8192)
            f.seek(size - chunk)
            text = f.read().decode("utf-8", errors="replace")
    except Exception:
        return None

    for line in reversed(text.splitlines()):
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get("type") != "event_msg":
            continue
        payload = obj.get("payload", {})
        if payload.get("type") != "token_count":
            continue
        total = payload.get("info", {}).get("total_token_usage", {})
        return {
            "input": int(total.get("input_tokens", 0) or 0),
            "output": int(total.get("output_tokens", 0) or 0),
            "cache_creation": 0,
            "cache_read": int(total.get("cached_input_tokens", 0) or 0),
        }
    return None

def codex_waiting_state(path: Path):
    entry = read_last_json(path)
    if not isinstance(entry, dict) or entry.get("type") != "event_msg":
        return "none"
    payload = entry.get("payload", {})
    ptype = payload.get("type")
    if ptype in {"task_complete", "token_count"}:
        return "waiting_response"
    if ptype == "agent_message" and payload.get("phase") == "final_answer":
        return "waiting_response"
    return "none"

def project_name_from_claude_dir(name: str) -> str:
    parts = [p for p in name.split("-") if p]
    return parts[-1] if parts else name

def status_icon(waiting_state: str, last_activity: int):
    is_active = last_activity >= cutoff_active
    needs_attention = (not is_active) and waiting_state == "waiting_approval" and (now - last_activity) < 3600
    if is_active:
        return "⚡", True, needs_attention
    if needs_attention and proc_count > 0:
        return "🔐", False, True
    return "⏸", False, needs_attention

sessions = []
grand = {"input": 0, "output": 0, "cache_creation": 0, "cache_read": 0}

if claude_dir.is_dir():
    for project_dir in sorted(claude_dir.iterdir()):
        if not project_dir.is_dir():
            continue
        project_name = project_name_from_claude_dir(project_dir.name)
        for jsonl in sorted(project_dir.glob("*.jsonl")):
            mod_epoch = mtime(jsonl)
            if mod_epoch < cutoff_24h:
                continue
            usage = parse_claude_jsonl(jsonl)
            if not usage:
                continue
            total = usage["input"] + usage["output"] + usage["cache_creation"] + usage["cache_read"]
            if total == 0:
                continue

            session = {
                "provider": "[C]",
                "project": project_name,
                "session_id": jsonl.stem,
                "last_activity": mod_epoch,
                "usage": dict(usage),
                "agents": [],
            }

            subagent_dir = project_dir / jsonl.stem / "subagents"
            if subagent_dir.is_dir():
                for agent_dir in sorted(subagent_dir.glob("agent-*")):
                    if not agent_dir.is_dir():
                        continue
                    agent_name = agent_dir.name
                    agent_jsonl = agent_dir / f"{agent_name}.jsonl"
                    if not agent_jsonl.is_file():
                        continue
                    agent_usage = parse_claude_jsonl(agent_jsonl)
                    if not agent_usage:
                        continue
                    agent_total = agent_usage["input"] + agent_usage["output"] + agent_usage["cache_creation"] + agent_usage["cache_read"]
                    if agent_total == 0:
                        continue
                    session["agents"].append({
                        "agent_id": agent_name.removeprefix("agent-")[:8],
                        "total": agent_total,
                    })
                    for k in grand:
                        grand[k] += agent_usage[k]
                    session["usage"]["input"] += 0

            session_total = total + sum(a["total"] for a in session["agents"])
            icon, is_active, needs_attention = status_icon(session["usage"]["waiting_state"], session["last_activity"])
            session["icon"] = icon
            session["is_active"] = is_active
            session["needs_attention"] = needs_attention
            session["total"] = session_total
            sessions.append(session)

            for k in grand:
                grand[k] += usage[k]

if codex_db_path.is_file():
    try:
        conn = sqlite3.connect(str(codex_db_path))
        cur = conn.cursor()
        cur.execute(
            """
            SELECT id, rollout_path, cwd, tokens_used, updated_at
            FROM threads
            WHERE archived = 0 AND updated_at > ?
            ORDER BY updated_at DESC
            """,
            (cutoff_24h,),
        )
        rows = cur.fetchall()
        conn.close()
    except Exception:
        rows = []

    for thread_id, rollout_path, cwd, tokens_used, updated_at in rows:
        rollout = Path(rollout_path)
        usage = parse_codex_token_count(rollout) if rollout.is_file() else None
        if usage is None:
            usage = {
                "input": int(tokens_used or 0),
                "output": 0,
                "cache_creation": 0,
                "cache_read": 0,
            }
        total = usage["input"] + usage["output"] + usage["cache_creation"] + usage["cache_read"]
        if total == 0:
            continue
        waiting_state = codex_waiting_state(rollout) if rollout.is_file() else "none"
        icon, is_active, needs_attention = status_icon(waiting_state, int(updated_at))
        sessions.append({
            "provider": "[X]",
            "project": Path(cwd).name or cwd,
            "session_id": str(thread_id),
            "last_activity": int(updated_at),
            "usage": {**usage, "waiting_state": waiting_state},
            "agents": [],
            "icon": icon,
            "is_active": is_active,
            "needs_attention": needs_attention,
            "total": total,
        })
        for k in grand:
            grand[k] += usage[k]

sessions.sort(key=lambda s: (not s["needs_attention"], not s["is_active"], -s["last_activity"]))
recent_sessions = sessions[:15]
active_count = sum(1 for s in sessions if s["is_active"])
attention_count = sum(1 for s in sessions if s["needs_attention"])
known_count = active_count + attention_count
idle_count = max(0, proc_count - known_count)

if known_count == 0 and proc_count == 0:
    print(" Processes  : none")
else:
    parts = []
    if attention_count > 0:
        parts.append(f"🟠 {attention_count} waiting")
    if active_count > 0:
        parts.append(f"⚡ {active_count} working")
    if idle_count > 0:
        parts.append(f"⏸ {idle_count} idle")
    label = "  ·  ".join(parts) if parts else f"⏸ {proc_count} open"
    print(f" Processes  : {label}")

if claude_count > 0 or codex_count > 0:
    print(f"   ↳ [C] {claude_count} claude  ·  [X] {codex_count} codex")

grand_total = grand["input"] + grand["output"] + grand["cache_creation"] + grand["cache_read"]
print(f" Total      : {format_tokens(grand_total)}")
print(f"   ↳ in {format_tokens(grand['input'] + grand['cache_creation'] + grand['cache_read'])}  out {format_tokens(grand['output'])}")

if recent_sessions:
    print()
    print(" Sessions (dernières 24h) :")
    for s in recent_sessions:
        ts = __import__("datetime").datetime.fromtimestamp(s["last_activity"]).strftime("%H:%M:%S")
        short_id = s["session_id"][:8]
        print(f" {s['provider']} {s['icon']} {s['project']}  [{short_id}]  {format_tokens(s['total'])}  (last: {ts})")
        for agent in s["agents"]:
            print(f"    ↳ Agent {agent['agent_id']}  {format_tokens(agent['total'])}")
PYEOF

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

if $WATCH_MODE; then
    while true; do
        clear
        run_status
        echo ""
        echo " [--watch]  Rafraîchissement toutes les 5s  (Ctrl+C pour quitter)"
        sleep 5
    done
else
    run_status
fi
