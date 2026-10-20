#!/bin/bash
# Retourne true (exit 0) si au moins une session claude a consommé des tokens
# dans les 10 dernières minutes, false (exit 1) sinon.
# Usage : ./has-active-sessions.sh && echo "actif" || echo "inactif"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

recent_count=$(count_recent_sessions)

if [[ -n "$recent_count" && "$recent_count" -gt 0 ]]; then
    echo "true"
    exit 0
else
    echo "false"
    exit 1
fi
