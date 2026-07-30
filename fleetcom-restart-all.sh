#!/bin/bash
# FLEETCOM: bounce the stack — everything, or just one stack
# (midship | auditboard | cascade) — then start it fresh. The optional stack
# target and any options (--tmux / --windows / --no-logs) are forwarded to
# stop-all and start-all.
#
# Supervisor-safe: fleetcom-stop-all.sh auto-detects when it's running inside
# the fleetcom-logs tmux session (the supervising Claude's home) and keeps that
# session alive, so a restart triggered by the supervisor never tears Claude
# down — and the dev daemons start-all launches survive the launching process
# exiting. A per-stack restart is quick and fine to run synchronously; a
# full-fleet restart takes minutes, so the supervisor should run it in the
# background (and watch ./fleetcom-doctor.sh) to stay responsive.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/paths.sh"

# stop-all guards this too, but catching it here names the command the user
# actually typed ('fleetcom restart') and aborts before any teardown starts.
guard_not_in_log_session 'fleetcom restart' || exit 1

"$HERE/fleetcom-stop-all.sh" "$@"
"$HERE/fleetcom-start-all.sh" "$@"
