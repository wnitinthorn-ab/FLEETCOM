#!/bin/bash
# FLEETCOM: full bounce of everything — Midship included — then start fresh.
# Args (e.g. --tmux / --windows / --no-logs) are forwarded to start-all.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/paths.sh"

# stop-all guards this too, but catching it here names the command the user
# actually typed ('fleetcom restart') and aborts before any teardown starts.
guard_not_in_log_session 'fleetcom restart' || exit 1

"$HERE/fleetcom-stop-all.sh"
"$HERE/fleetcom-start-all.sh" "$@"
