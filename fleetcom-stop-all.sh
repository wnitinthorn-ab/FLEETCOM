#!/bin/bash
# FLEETCOM: stop all three stacks — AuditBoard, Cascade, and Midship (plus the
# Hatchet workers) — and tear down the log view.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/paths.sh"
DEVENV="$AB_DEVENV_DIR"
CASCADE="$CASCADE_DIR"

# Bail before stopping anything if we'd be killing our own log pane (see
# guard_not_in_log_session in paths.sh). Stands down under FLEETCOM_KEEP_LOGS,
# which is how fleetcom-start-claude.sh legitimately runs us in the claude pane.
guard_not_in_log_session 'fleetcom stop' || exit 1

say() { printf '\033[36m[stop-all]\033[0m %s\n' "$*"; }
kill_port() { # TERM whatever LISTENs on a port, then WAIT until it's actually
	# released, escalating to KILL — but NEVER Docker: on macOS,
	# docker-published ports are held by Docker Desktop's backend process, and
	# signalling it disrupts networking for every container.
	#
	# The wait is the fix for the Midship-API-down-after-restart race: uvicorn
	# --reload shuts down gracefully (up to --timeout-graceful-shutdown 15s), so
	# 8000 stays bound after `kill` returns. The old code returned immediately,
	# so the following start-all saw 8000 "already up" and skipped relaunching a
	# fresh API. Re-checking the port each round (instead of tracking the
	# original pids) also handles a supervisor that respawns its worker.
	local pids safe p i
	for i in $(seq 1 20); do
		pids=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null) || { [ "$i" -gt 1 ] && say "port $1 released"; return 0; }
		safe=""
		for p in $pids; do
			case "$(ps -p "$p" -o comm= 2>/dev/null)" in
				*[Dd]ocker*) [ "$i" = 1 ] && say "port $1 is docker-published — stop the container, not the proxy (skipping pid $p)" ;;
				*) safe="$safe $p" ;;
			esac
		done
		[ -n "${safe// /}" ] || return 0            # free, or only Docker holds it
		if [ "$i" -lt 8 ]; then
			[ "$i" = 1 ] && say "stopping port $1 (pid$safe)"
			kill $safe 2>/dev/null || true          # SIGTERM (graceful) for ~4s
		else
			[ "$i" = 8 ] && say "port $1 still draining after ~4s — sending SIGKILL (pid$safe)"
			kill -9 $safe 2>/dev/null || true
		fi
		sleep 0.5
	done
	say "WARNING: port $1 still held after ~10s of TERM/KILL attempts (pid$safe)"
	return 0
}
stop_containers_named() { # docker stop by name filter, quiet when none match
	local ids
	ids=$(docker ps -q --filter "name=$1" 2>/dev/null)
	[ -n "$ids" ] && docker stop $ids >/dev/null && say "stopped $1 container(s)"
}
stop_hatchet_workers() { # TERM the Midship Hatchet worker wrapper + workers, then
	# confirm they're gone (SIGKILL stragglers). Without this, fleetcom-start-all.sh
	# added the workers but nothing stopped them: after stop/restart they lingered,
	# orphaned from a torn-down Hatchet, and start-all's pgrep then saw them
	# "already running" and skipped relaunch. The authoritative check is the worker
	# module pattern (same one doctor + start-all use).
	local i
	pgrep -f 'midship\.heretic\.hatchet\.worker' >/dev/null 2>&1 || return 0
	pkill -f 'scripts/run-workers?\.sh' 2>/dev/null || true   # wrapper (its own kill 0 cascades within its group)
	pkill -f 'midship\.heretic\.hatchet\.worker' 2>/dev/null || true
	for i in $(seq 1 12); do   # ~6s graceful grace before escalating
		pgrep -f 'midship\.heretic\.hatchet\.worker' >/dev/null 2>&1 || { say "stopped hatchet workers"; return 0; }
		sleep 0.5
	done
	pkill -9 -f 'scripts/run-workers?\.sh' 2>/dev/null || true
	pkill -9 -f 'midship\.heretic\.hatchet\.worker' 2>/dev/null || true
	say "hatchet workers force-killed"
}

# Optional positional target: stop only one stack (default: all).
TARGET=all
for arg in "$@"; do case "$arg" in midship|auditboard|cascade|all) TARGET="$arg" ;; esac; done
want() { [ "$TARGET" = all ] || [ "$TARGET" = "$1" ]; }

# Supervisor self-protection: when a Claude session running INSIDE the
# fleetcom-logs tmux session invokes stop/restart, that session is Claude's own
# home — tearing it down would kill the supervising Claude mid-command. So
# auto-enable FLEETCOM_KEEP_LOGS whenever we detect we're inside it. (An
# explicit FLEETCOM_KEEP_LOGS from fleetcom-start-claude.sh still wins; this
# only fills it in when unset.) Same session-name detection as
# fleetcom-start-claude.sh's guard.
if [ -z "${FLEETCOM_KEEP_LOGS:-}" ] && [ -n "${TMUX:-}" ] \
	&& [ "$(tmux display-message -p '#S' 2>/dev/null)" = fleetcom-logs ]; then
	FLEETCOM_KEEP_LOGS=1
	say "supervisor session detected (inside fleetcom-logs) — keeping the log/claude session alive"
fi

if want cascade; then
say "cascade"
kill_port 8088                                     # parcel client
(cd "$CASCADE" && docker-compose -f docker-compose.yml -f docker-compose-build.yml \
	-f docker-compose.override.yml down 2>/dev/null)
fi

if want auditboard; then
say "auditboard"
stop_containers_named caddy                        # caddy runs in docker — 9002 is a proxied port
kill_port 9006; kill_port 9005                     # client + login vite (9005 orphans otherwise)
kill_port 9001; kill_port 9003                     # api v1/v2 (turbo children follow)
(cd "$DEVENV" && abc run stop-background)          # supplement services (+ ML in theory)
# upstream bug: machine-learning's bin/ml-stop never cds into its repo, so its
# 'docker compose stop' silently no-ops — stop the ML project ourselves
[ -d "$ML_DIR" ] && (cd "$ML_DIR" && docker compose stop 2>/dev/null) && say "machine-learning stopped"
# 'stop', not 'down': down would also remove the shared project network once
# nothing is running, leaving every stopped container pinned to a dead network
# ID — the next start-background then dies with "network ... not found"
(cd "$DEVENV" && direnv exec . docker compose -f docker-compose-supplement-dev.yml \
	-f "$HERE/devenv.override.yml" -f "$HERE/extract.override.yml" stop conductor integrations-extract 2>/dev/null) \
	|| (cd "$DEVENV" && direnv exec . docker compose -f docker-compose-supplement-dev.yml \
	-f "$HERE/devenv.override.yml" stop conductor 2>/dev/null) || true
brew services stop postgresql@17 >/dev/null 2>&1
brew services stop redis >/dev/null 2>&1
fi  # want auditboard

if want midship; then
if [ -d "$MIDSHIP_TURBO_BROCCOLI_DIR" ]; then
	say "midship"
	kill_port 8000; kill_port 5173
	stop_hatchet_workers                            # consumer processes start-all launches (not port-bound)
	(cd "$MIDSHIP_TURBO_BROCCOLI_DIR" && docker compose down)
	stop_containers_named hatchet-cli               # separate compose project; restarted by fleetcom-start-all.sh
fi
fi  # want midship

# The AB API runs in its own tmux session (fleetcom-ab-api) for the pty; it's
# rebuilt by fleetcom-start-all.sh, so close it whenever AB is in scope.
if want auditboard; then
	tmux kill-session -t fleetcom-ab-api 2>/dev/null && say "AB API tmux session closed" || true
fi

# Only a full-fleet stop manages the log view; a per-stack stop leaves it up.
if [ "$TARGET" = all ]; then
	# FLEETCOM_KEEP_LOGS: fleetcom-start-claude.sh runs the restart INSIDE the log
	# session's claude pane, and a supervisor Claude inside fleetcom-logs sets it
	# above — either way it stops us from tearing that session down mid-restart.
	# Normal `stop` from a plain terminal leaves it unset and closes the log view.
	if [ -n "${FLEETCOM_KEEP_LOGS:-}" ]; then
		say "keeping the log session (FLEETCOM_KEEP_LOGS set)"
	else
		"$HERE/fleetcom-logs.sh" --kill   # kills the logs tmux session and requests close on any spawned Terminal windows (may need a per-window click to confirm)
	fi
fi

if [ "$TARGET" = all ]; then say "done"; else say "done ($TARGET only)"; fi
