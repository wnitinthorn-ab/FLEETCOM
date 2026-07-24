#!/bin/bash
# FLEETCOM: full bounce of everything — Midship included — then start fresh.
# Args (e.g. --tmux / --windows / --no-logs) are forwarded to start-all.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

"$HERE/fleetcom-stop-all.sh"
"$HERE/fleetcom-start-all.sh" "$@"
