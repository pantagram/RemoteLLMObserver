#!/bin/bash
# Claude CLI Observer — status en ligne de commande
# Usage: ./status.sh [--watch]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

WATCH_MODE=false
[[ "$1" == "--watch" ]] && WATCH_MODE=true

run_status() {
    local now
    now=$(date +%s)
    local cutoff_24h=$(( now - 86400 ))
    local cutoff_active=$(( now - 30 ))     # cohérent avec l'app (30s)
    local cutoff_waiting=$(( now - 300 ))   # affiche 💬/🔐 si modifié dans les 5 min
    local cutoff_recent=$(( now - 600 ))    # sessions ayant consommé des tokens dans les 10 min

    # ── Processus ─────────────────────────────────────────────────────────
    local proc_count
    proc_count=$(count_processes)

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " Claude CLI Observer"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # ── Sessions (dernières 24h) ───────────────────────────────────────────
    local total_in=0 total_out=0 total_cc=0 total_cr=0
    local session_lines=()
    local active_count=0 waiting_r=0 waiting_a=0 recent_count=0

    for project_dir in "$CLAUDE_DIR"/*/; do
        [[ -d "$project_dir" ]] || continue
        local project_name
        project_name=$(basename "$project_dir" | awk -F'-' '{print $NF}')

        for jsonl in "$project_dir"*.jsonl; do
            [[ -f "$jsonl" ]] || continue

            local mod_epoch
            mod_epoch=$(stat -f %m "$jsonl" 2>/dev/null || echo 0)
            (( mod_epoch < cutoff_24h )) && continue

            # Tokens + wait state en un seul appel Python
            local s_in s_out s_cc s_cr s_state
            read -r s_in s_out s_cc s_cr s_state < <(parse_jsonl "$jsonl")

            local s_total=$(( s_in + s_out + s_cc + s_cr ))
            (( s_total == 0 )) && continue

            total_in=$(( total_in + s_in ))
            total_out=$(( total_out + s_out ))
            total_cc=$(( total_cc + s_cc ))
            total_cr=$(( total_cr + s_cr ))

            (( mod_epoch >= cutoff_recent )) && (( recent_count++ ))

            # Icône selon priorité : attente > travail > inactif
            # 💬/🔐 uniquement si un process tourne (proc_count > 0)
            local icon
            if [[ "$s_state" == "waiting_approval" && $mod_epoch -ge $cutoff_waiting && $proc_count -gt 0 ]]; then
                icon="🔐"; (( waiting_a++ ))
            elif [[ "$s_state" == "waiting_response" && $mod_epoch -ge $cutoff_waiting && $proc_count -gt 0 ]]; then
                icon="💬"; (( waiting_r++ ))
            elif (( mod_epoch >= cutoff_active )); then
                icon="⚡"; (( active_count++ ))
            else
                icon="⏸"
            fi

            local session_id short_id tok_str ts
            session_id=$(basename "$jsonl" .jsonl)
            short_id="${session_id:0:8}"
            tok_str=$(format_tokens "$s_total")
            ts=$(date -r "$mod_epoch" "+%H:%M:%S")

            session_lines+=(" $icon $project_name  [$short_id]  $tok_str  (last: $ts)")

            # Subagents
            local subagent_dir="$project_dir${session_id}/subagents"
            if [[ -d "$subagent_dir" ]]; then
                for agent_dir in "$subagent_dir"/agent-*/; do
                    [[ -d "$agent_dir" ]] || continue
                    local agent_name agent_jsonl
                    agent_name=$(basename "$agent_dir")
                    agent_jsonl="$agent_dir${agent_name}.jsonl"
                    [[ -f "$agent_jsonl" ]] || continue

                    local a_in a_out a_cc a_cr a_state
                    read -r a_in a_out a_cc a_cr a_state < <(parse_jsonl "$agent_jsonl")
                    local a_total=$(( a_in + a_out + a_cc + a_cr ))
                    (( a_total == 0 )) && continue

                    total_in=$(( total_in + a_in ))
                    total_out=$(( total_out + a_out ))
                    total_cc=$(( total_cc + a_cc ))
                    total_cr=$(( total_cr + a_cr ))

                    local agent_short a_tok
                    agent_short="${agent_name/agent-/}"
                    agent_short="${agent_short:0:8}"
                    a_tok=$(format_tokens "$a_total")
                    session_lines+=("    ↳ agent $agent_short  $a_tok")
                done
            fi
        done
    done

    # ── En-tête processus ─────────────────────────────────────────────────
    if (( proc_count == 0 )); then
        echo " Processes  : none"
    else
        local proc_label=" Processes  : $proc_count running"
        local waiting_parts=()
        (( waiting_a > 0 )) && waiting_parts+=("🔐 $waiting_a approval")
        (( waiting_r > 0 )) && waiting_parts+=("💬 $waiting_r reply")
        (( active_count > 0 )) && waiting_parts+=("⚡ $active_count working")
        if (( ${#waiting_parts[@]} > 0 )); then
            proc_label+="  ($(IFS='  ·  '; echo "${waiting_parts[*]}"))"
        fi
        echo "$proc_label"
    fi
    echo " Last 10 min: $recent_count active"

    # ── Totaux ────────────────────────────────────────────────────────────
    local grand_total=$(( total_in + total_out + total_cc + total_cr ))
    echo " Total      : $(format_tokens "$grand_total")"
    echo "   ↳ in $(format_tokens $(( total_in + total_cc + total_cr )))  out $(format_tokens "$total_out")"

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
