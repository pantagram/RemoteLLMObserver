#!/bin/bash
# Claude CLI Observer — status en ligne de commande
# Usage: ./status.sh [--watch]

CLAUDE_DIR="$HOME/.claude/projects"
WATCH_MODE=false
[[ "$1" == "--watch" ]] && WATCH_MODE=true

format_tokens() {
    local n=$1
    if   (( n >= 1000000 )); then printf "%.2fM tok" "$(echo "scale=2; $n/1000000" | bc)"
    elif (( n >= 1000 ));    then printf "%.1fK tok" "$(echo "scale=1; $n/1000" | bc)"
    else                          printf "%d tok" "$n"
    fi
}

run_status() {
    local now
    now=$(date +%s)
    local cutoff_24h=$(( now - 86400 ))
    local cutoff_active=$(( now - 10 ))

    # ── Processus ─────────────────────────────────────────────────────────
    local proc_count
    proc_count=$(ps -eo comm | grep -cE "^claude$|/claude$" || true)

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " Claude CLI Observer"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if (( proc_count == 0 )); then
        echo " Processes  : none"
    else
        echo " Processes  : $proc_count running"
    fi

    # ── Sessions (dernières 24h) ──────────────────────────────────────────
    local total_in=0 total_out=0 total_cache_c=0 total_cache_r=0
    local session_lines=()

    for project_dir in "$CLAUDE_DIR"/*/; do
        [[ -d "$project_dir" ]] || continue
        local project_name
        project_name=$(basename "$project_dir" | awk -F'-' '{print $NF}')

        for jsonl in "$project_dir"*.jsonl; do
            [[ -f "$jsonl" ]] || continue

            # Check age
            local mod_epoch
            mod_epoch=$(stat -f %m "$jsonl" 2>/dev/null || echo 0)
            (( mod_epoch < cutoff_24h )) && continue

            local active_flag=""
            (( mod_epoch >= cutoff_active )) && active_flag="⚡"

            # Count tokens with python3 (always available on macOS)
            read -r s_in s_out s_cc s_cr < <(python3 - "$jsonl" <<'EOF'
import json, sys
tin=tout=tcc=tcr=0
for line in open(sys.argv[1]):
    try:
        obj=json.loads(line)
    except:
        continue
    usage=None
    if obj.get("type")=="assistant":
        usage=obj.get("message",{}).get("usage")
    elif obj.get("type")=="progress":
        usage=obj.get("data",{}).get("message",{}).get("usage")
    if usage:
        tin  += usage.get("input_tokens",0)
        tout += usage.get("output_tokens",0)
        tcc  += usage.get("cache_creation_input_tokens",0)
        tcr  += usage.get("cache_read_input_tokens",0)
print(tin, tout, tcc, tcr)
EOF
)
            total_in=$(( total_in + s_in ))
            total_out=$(( total_out + s_out ))
            total_cache_c=$(( total_cache_c + s_cc ))
            total_cache_r=$(( total_cache_r + s_cr ))

            local s_total=$(( s_in + s_out + s_cc + s_cr ))
            (( s_total == 0 )) && continue

            local session_id
            session_id=$(basename "$jsonl" .jsonl)
            local short_id="${session_id:0:8}"
            local tok_str
            tok_str=$(format_tokens "$s_total")

            local ts
            ts=$(date -r "$mod_epoch" "+%H:%M:%S")

            session_lines+=(" ${active_flag:-⏸} $project_name  [$short_id]  $tok_str  (last: $ts)")

            # Subagents
            local subagent_dir="$project_dir${session_id}/subagents"
            if [[ -d "$subagent_dir" ]]; then
                for agent_dir in "$subagent_dir"/agent-*/; do
                    [[ -d "$agent_dir" ]] || continue
                    local agent_name
                    agent_name=$(basename "$agent_dir")
                    local agent_jsonl="$agent_dir${agent_name}.jsonl"
                    [[ -f "$agent_jsonl" ]] || continue

                    read -r a_in a_out a_cc a_cr < <(python3 - "$agent_jsonl" <<'EOF'
import json, sys
tin=tout=tcc=tcr=0
for line in open(sys.argv[1]):
    try:
        obj=json.loads(line)
    except:
        continue
    usage=None
    if obj.get("type")=="assistant":
        usage=obj.get("message",{}).get("usage")
    if usage:
        tin  += usage.get("input_tokens",0)
        tout += usage.get("output_tokens",0)
        tcc  += usage.get("cache_creation_input_tokens",0)
        tcr  += usage.get("cache_read_input_tokens",0)
print(tin, tout, tcc, tcr)
EOF
)
                    local a_total=$(( a_in + a_out + a_cc + a_cr ))
                    (( a_total == 0 )) && continue
                    total_in=$(( total_in + a_in ))
                    total_out=$(( total_out + a_out ))
                    total_cache_c=$(( total_cache_c + a_cc ))
                    total_cache_r=$(( total_cache_r + a_cr ))

                    local agent_short="${agent_name/agent-/}"
                    agent_short="${agent_short:0:8}"
                    local a_tok
                    a_tok=$(format_tokens "$a_total")
                    session_lines+=("    ↳ agent $agent_short  $a_tok")
                done
            fi
        done
    done

    # ── Totaux ────────────────────────────────────────────────────────────
    local grand_total=$(( total_in + total_out + total_cache_c + total_cache_r ))
    echo " Total      : $(format_tokens "$grand_total")"
    echo "   ↳ in $(format_tokens $(( total_in + total_cache_c + total_cache_r )))  out $(format_tokens "$total_out")"

    # ── Liste sessions ────────────────────────────────────────────────────
    if (( ${#session_lines[@]} > 0 )); then
        echo ""
        echo " Sessions (dernières 24h) :"
        for line in "${session_lines[@]}"; do
            echo "$line"
        done
    fi

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
