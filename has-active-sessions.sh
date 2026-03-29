#!/bin/bash
# Retourne true (exit 0) si au moins un processus claude est en cours, false (exit 1) sinon.
# Usage : ./has-active-sessions.sh && echo "actif" || echo "inactif"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

proc_count=$(count_processes)

if [[ -n "$proc_count" && "$proc_count" -gt 0 ]]; then
    echo "true"
    exit 0
else
    echo "false"
    exit 1
fi
