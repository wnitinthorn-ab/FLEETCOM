# shellcheck shell=bash
# FLEETCOM/paths.sh — repo locations + shared helpers, sourced by every script.
# Defaults put every repo under ~/Development; local.conf (written by
# fleetcom-onboard.sh's prompt, gitignored, per-machine) overrides them.
# Re-run `fleetcom-onboard.sh --reconfigure` or hand-edit local.conf — every
# repo has its own variable and may live anywhere.
CASCADE_DIR="${CASCADE_DIR:-$HOME/Development/cascade}"
AB_BACKEND_DIR="${AB_BACKEND_DIR:-$HOME/Development/auditboard-backend}"
AB_FRONTEND_DIR="${AB_FRONTEND_DIR:-$HOME/Development/auditboard-frontend}"
AB_DEVENV_DIR="${AB_DEVENV_DIR:-$HOME/Development/auditboard-dev-env}"

_paths_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$_paths_dir/local.conf" ] && . "$_paths_dir/local.conf"

# midship repos — per-repo variables like everything else. MIDSHIP_DIR is
# honored only as a legacy parent fallback from older local.conf files.
_midship_parent="${MIDSHIP_DIR:-$HOME/Development}"
MIDSHIP_TURBO_BROCCOLI_DIR="${MIDSHIP_TURBO_BROCCOLI_DIR:-$_midship_parent/midship-turbo-broccoli}"
MIDSHIP_FRONTEND_DIR="${MIDSHIP_FRONTEND_DIR:-$_midship_parent/midship-frontend}"
MIDSHIP_ONYX_DIR="${MIDSHIP_ONYX_DIR:-$_midship_parent/midship-onyx}"

# machine-learning is cloned by start-background inside the dev-env checkout
ML_DIR="$AB_DEVENV_DIR/machine-learning"

# ---- shared helpers ---------------------------------------------------------
# ensure_tmux [purpose]: make tmux available, or report that it isn't. Returns
# 0 when tmux is on PATH — offering to `brew install tmux` first if it's missing
# and we're on an interactive terminal. Returns non-zero when tmux is absent and
# the user declined, the install failed, Homebrew is unavailable, or there's no
# TTY to ask at; callers use that to fall back to the separate-Terminal-windows
# log view. FLEETCOM_NONINTERACTIVE forces the no-prompt (fall-back) path.
# Always safe to call in a conditional (`ensure_tmux || fallback`), which also
# suspends the caller's set -e for the function body.
ensure_tmux() {
	command -v tmux >/dev/null 2>&1 && return 0
	local purpose="${1:-the tmux log view}" reply
	[ -n "${FLEETCOM_NONINTERACTIVE:-}" ] && return 1
	[ -t 0 ] || return 1
	if ! command -v brew >/dev/null 2>&1; then
		printf '[fleetcom] tmux is not installed, and Homebrew is not available to install it — using separate windows.\n' >&2
		return 1
	fi
	printf '[fleetcom] tmux is not installed (needed for %s).\n' "$purpose" >&2
	read -r -p "[fleetcom] Install it now with 'brew install tmux'? [Y/n] " reply || return 1
	case "$reply" in [Nn]*) return 1 ;; esac
	printf '[fleetcom] installing tmux via Homebrew...\n' >&2
	if brew install tmux >&2 && command -v tmux >/dev/null 2>&1; then
		printf '[fleetcom] tmux installed.\n' >&2
		return 0
	fi
	printf '[fleetcom] tmux install did not complete — using separate windows.\n' >&2
	return 1
}

# git_branch DIR: the branch checked out in DIR, for display in a pane/window
# title. Short SHA when detached. Empty when DIR isn't a git checkout (repo not
# cloned, path unset, or a plain directory) so callers can drop the parens
# entirely rather than render an empty pair.
git_branch() {
	local dir="${1:-}" b
	[ -n "$dir" ] || return 0
	[ -d "$dir" ] || return 0
	b="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)" || return 0
	if [ "$b" = "HEAD" ]; then                       # detached — show the commit
		b="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)" || return 0
	fi
	printf '%s' "$b"
}

# title_with_branch LABEL [DIR]: "label (branch)", or a bare "label" when DIR is
# empty or isn't a checkout. LABEL stays the leading token on purpose —
# fleetcom-start-claude.sh's reorder_backends matches pane titles by PREFIX
# (index($2,t)==1), so the suffix is free but the head of the string is not.
title_with_branch() {
	local b; b="$(git_branch "${2:-}")"
	if [ -n "$b" ]; then printf '%s (%s)' "$1" "$b"; else printf '%s' "$1"; fi
}

# The tmux log session built by fleetcom-logs.sh. (fleetcom-logs.sh and
# fleetcom-start-claude.sh still carry their own SESSION= copies of this name.)
FLEETCOM_LOG_SESSION="fleetcom-logs"

# guard_not_in_log_session PURPOSE: refuse to run a command that tears the log
# session down from inside that very session. `fleetcom stop`/`restart` end by
# running fleetcom-logs.sh --kill, so typing either one in a log pane kills the
# pane you typed it in, mid-teardown — which is how you end up with a rebuilt
# log grid and no claude pane (start-all reopens the logs, but nothing in that
# path re-adds claude).
#
# FLEETCOM_KEEP_LOGS is the sanctioned way to bounce the stacks from inside the
# session — fleetcom-start-claude.sh sets it to run the restart in the claude
# pane, and fleetcom-stop-all.sh then skips the --kill. So the guard stands down
# whenever it's set: with the teardown disabled there's no rug left to pull.
# Returns 1 (after explaining) when the caller should abort, else 0. Written as
# plain ifs, not an && chain, so it's safe under the callers' set -e.
guard_not_in_log_session() {
	local purpose="${1:-this command}"
	if [ -n "${FLEETCOM_KEEP_LOGS:-}" ]; then return 0; fi
	if [ -z "${TMUX:-}" ]; then return 0; fi
	if [ "$(tmux display-message -p '#S' 2>/dev/null)" != "$FLEETCOM_LOG_SESSION" ]; then return 0; fi
	printf "[fleetcom] ERROR: don't run %s from inside the '%s' tmux session — it tears\n" "$purpose" "$FLEETCOM_LOG_SESSION" >&2
	printf '[fleetcom]        that session down, killing the pane you typed this in.\n' >&2
	printf '[fleetcom]        Detach (Ctrl-b d) or open a separate terminal window, then re-run.\n' >&2
	printf '[fleetcom]        To bounce the stacks without losing this session, run instead:\n' >&2
	printf '[fleetcom]            FLEETCOM_KEEP_LOGS=1 fleetcom stop && fleetcom start --no-logs\n' >&2
	return 1
}
