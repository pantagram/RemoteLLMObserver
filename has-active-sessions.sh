#!/bin/bash
# Retourne true (exit 0) si au moins un processus claude est en cours, false (exit 1) sinon.
# Usage : ./has-active-sessions.sh && echo "actif" || echo "inactif"

SCRIPT_DIR="/Users/lvi/Devs/Apps/RemoteLLMObserver"

proc_count=$(bash "$SCRIPT_DIR/status.sh" | grep "Processes" | grep -oE "[0-9]+" | head -1)

if [[ -n "$proc_count" && "$proc_count" -gt 0 ]]; then
    echo "true"
    exit 0
else
    echo "false"
    exit 1
fi
