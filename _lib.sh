#!/bin/bash
# Bibliothèque partagée — sourcée par status.sh et has-active-sessions.sh

CLAUDE_DIR="$HOME/.claude/projects"

# ── Formatage ──────────────────────────────────────────────────────────────
format_tokens() {
    local n=$1
    if   (( n >= 1000000 )); then printf "%.2fM tok" "$(echo "scale=2; $n/1000000" | bc)"
    elif (( n >= 1000 ));    then printf "%.1fK tok"  "$(echo "scale=1; $n/1000"    | bc)"
    else                          printf "%d tok" "$n"
    fi
}

# ── Processus ──────────────────────────────────────────────────────────────
count_processes() {
    ps -eo comm | grep -cE "^claude$|/claude$" || true
}

# ── Parsing JSONL ──────────────────────────────────────────────────────────
# Usage : read -r in out cc cr state < <(parse_jsonl "/path/to/file.jsonl")
# Retourne : <input> <output> <cache_creation> <cache_read> <wait_state>
# wait_state : working | waiting_response | waiting_approval | idle
parse_jsonl() {
    python3 - "$1" <<'PYEOF'
import json, sys

tin = tout = tcc = tcr = 0
lines = [l.strip() for l in open(sys.argv[1], errors="replace") if l.strip()]

for line in lines:
    try:
        obj = json.loads(line)
    except Exception:
        continue
    usage = None
    t = obj.get("type")
    if t == "assistant":
        usage = obj.get("message", {}).get("usage")
    elif t == "progress":
        usage = obj.get("data", {}).get("message", {}).get("usage")
    if usage:
        tin  += usage.get("input_tokens", 0)
        tout += usage.get("output_tokens", 0)
        tcc  += usage.get("cache_creation_input_tokens", 0)
        tcr  += usage.get("cache_read_input_tokens", 0)

# Determine wait state from last entry
state = "idle"
if lines:
    try:
        last = json.loads(lines[-1])
        if last.get("type") == "assistant":
            content = last.get("message", {}).get("content", [])
            if isinstance(content, list) and any(c.get("type") == "tool_use" for c in content):
                state = "waiting_approval"
            else:
                state = "waiting_response"
        else:
            state = "working"
    except Exception:
        state = "idle"

print(tin, tout, tcc, tcr, state)
PYEOF
}
