# shellcheck shell=bash
# FLEETCOM/paths.sh — repo locations + shared helpers, sourced by every script.
# Defaults put every repo under ~/Development; local.conf (written by
# fleetcom-onboard.sh's prompt, gitignored, per-machine) overrides them.
# Re-run `fleetcom-onboard.sh --reconfigure` or hand-edit local.conf — every
# repo has its own variable and may live anywhere.
_paths_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Every repo location variable, in one list, so precedence and the worktree
# commands below iterate the same set instead of each naming its own copy.
FLEETCOM_REPO_VARS="CASCADE_DIR AB_BACKEND_DIR AB_FRONTEND_DIR AB_DEVENV_DIR
MIDSHIP_TURBO_BROCCOLI_DIR MIDSHIP_FRONTEND_DIR MIDSHIP_ONYX_DIR"

# Short names for the same repos, positionally matched to FLEETCOM_REPO_VARS.
# What `fleetcom worktree use <repo>` accepts and what doctor prints.
FLEETCOM_REPO_NAMES="cascade auditboard-backend auditboard-frontend auditboard-dev-env
midship-turbo-broccoli midship-frontend midship-onyx"

# ---- precedence: env > worktrees.conf > local.conf > defaults ---------------
#
# local.conf assigns **unconditionally** (fleetcom-onboard.sh writes plain
# `VAR="/path"` lines), so sourcing it on top of a `${VAR:-default}` chain
# silently discards anything the caller exported. That was already known for one
# variable — fleetcom-logs.sh saves LOGS_VIEW across the source by hand — and
# this generalises the same fix to every repo path, which is what makes
# `MIDSHIP_FRONTEND_DIR=… fleetcom start` mean anything.
#
# Saved before either file is read and restored after both, so an exported value
# wins; worktrees.conf is read second so a recorded worktree beats the permanent
# checkout in local.conf.
for _v in $FLEETCOM_REPO_VARS; do
	eval "_fleetcom_env_$_v=\${$_v:-}"
done

[ -f "$_paths_dir/local.conf" ] && . "$_paths_dir/local.conf"

# Per-machine worktree overrides, written by `fleetcom worktree use` and
# gitignored alongside local.conf. Kept in its own file rather than merged into
# local.conf so that dropping every override is deleting one file, and so a
# `fleetcom onboard --reconfigure` rewrite of local.conf cannot silently discard
# the worktree a developer is mid-task on.
FLEETCOM_WORKTREES_CONF="$_paths_dir/worktrees.conf"
[ -f "$FLEETCOM_WORKTREES_CONF" ] && . "$FLEETCOM_WORKTREES_CONF"

for _v in $FLEETCOM_REPO_VARS; do
	eval "_fleetcom_saved=\$_fleetcom_env_$_v"
	[ -n "$_fleetcom_saved" ] && eval "$_v=\$_fleetcom_saved"
done
unset _v _fleetcom_saved

# Defaults for anything none of the three sources named. MIDSHIP_DIR is honored
# only as a legacy parent fallback from older local.conf files.
_midship_parent="${MIDSHIP_DIR:-$HOME/Development}"
CASCADE_DIR="${CASCADE_DIR:-$HOME/Development/cascade}"
AB_BACKEND_DIR="${AB_BACKEND_DIR:-$HOME/Development/auditboard-backend}"
AB_FRONTEND_DIR="${AB_FRONTEND_DIR:-$HOME/Development/auditboard-frontend}"
AB_DEVENV_DIR="${AB_DEVENV_DIR:-$HOME/Development/auditboard-dev-env}"
MIDSHIP_TURBO_BROCCOLI_DIR="${MIDSHIP_TURBO_BROCCOLI_DIR:-$_midship_parent/midship-turbo-broccoli}"
MIDSHIP_FRONTEND_DIR="${MIDSHIP_FRONTEND_DIR:-$_midship_parent/midship-frontend}"
MIDSHIP_ONYX_DIR="${MIDSHIP_ONYX_DIR:-$_midship_parent/midship-onyx}"

# machine-learning is cloned by start-background inside the dev-env checkout
ML_DIR="$AB_DEVENV_DIR/machine-learning"

# ---- worktree-aware checkout resolution -------------------------------------
#
# A git worktree is an ordinary directory as far as every start script is
# concerned: they cd into a path and run pnpm/poetry/docker there. So pointing
# FLEETCOM at one needs no change to those scripts — only a way to say which
# path a repo resolves to, and a way to see what that path actually is. Both
# live here so `fleetcom worktree` and `fleetcom doctor` agree.

# fleetcom_var_for_repo NAME: the path variable a short repo name selects, or
# empty for a name that is not one of ours. Printed, not returned, so callers
# can test it with [ -z ].
fleetcom_var_for_repo() {
	local want="$1" name var
	# `set --` over the two lists in step: positional matching keeps the pair in
	# one place rather than repeating a case statement that can drift from it.
	set -- $FLEETCOM_REPO_NAMES
	for var in $FLEETCOM_REPO_VARS; do
		name="$1"; shift
		if [ "$name" = "$want" ]; then printf '%s\n' "$var"; return 0; fi
	done
	return 1
}

# fleetcom_repo_for_var VAR: the inverse, for printing.
fleetcom_repo_for_var() {
	local want="$1" name var
	set -- $FLEETCOM_REPO_NAMES
	for var in $FLEETCOM_REPO_VARS; do
		name="$1"; shift
		if [ "$var" = "$want" ]; then printf '%s\n' "$name"; return 0; fi
	done
	return 1
}

# fleetcom_checkout_kind DIR: one word describing what DIR is.
#   missing      — the path does not exist. A start would fail here, loudly or
#                  otherwise, so it is worth saying before the boot.
#   not-a-repo   — exists but is not inside a git checkout.
#   worktree     — a linked worktree (its .git is a file pointing at the main
#                  checkout's gitdir), i.e. what this feature exists for.
#   main         — the repo's own primary checkout.
fleetcom_checkout_kind() {
	local dir="$1"
	[ -d "$dir" ] || { printf 'missing\n'; return 0; }
	git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || { printf 'not-a-repo\n'; return 0; }
	# `--git-common-dir` is the main checkout's .git for every worktree of a
	# repo; it differs from `--git-dir` exactly in a linked worktree.
	local gd cd_
	gd="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)"
	cd_="$(cd "$dir" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" && pwd)"
	if [ -n "$gd" ] && [ -n "$cd_" ] && [ "$gd" != "$cd_" ]; then
		printf 'worktree\n'
	else
		printf 'main\n'
	fi
}

# fleetcom_checkout_branch DIR: the checked-out branch, "(detached)" for a
# detached HEAD, or empty when DIR is not a checkout at all.
fleetcom_checkout_branch() {
	local dir="$1" branch
	[ -d "$dir" ] || return 0
	branch="$(git -C "$dir" branch --show-current 2>/dev/null)" || return 0
	[ -n "$branch" ] || branch="(detached)"
	printf '%s\n' "$branch"
}

# fleetcom_print_checkouts: one line per repo — name, kind, branch, path.
# Read-only. Called by doctor and by `fleetcom worktree status`, so the two
# cannot disagree about what is about to be booted.
fleetcom_print_checkouts() {
	local var dir kind branch repo marker
	for var in $FLEETCOM_REPO_VARS; do
		eval "dir=\$$var"
		repo="$(fleetcom_repo_for_var "$var")"
		kind="$(fleetcom_checkout_kind "$dir")"
		branch="$(fleetcom_checkout_branch "$dir")"
		case "$kind" in
			worktree)   marker="worktree" ;;
			missing)    marker="MISSING" ;;
			not-a-repo) marker="NOT A GIT CHECKOUT" ;;
			*)          marker="main" ;;
		esac
		printf '  %-24s %-20s %-22s %s\n' "$repo" "$marker" "${branch:--}" "$dir"
	done
}

# fleetcom_check_checkouts: refuse to boot against a path that cannot work.
# Returns non-zero when any repo resolves to a missing directory or something
# that is not a git checkout — which is the failure a stale worktree override
# produces, and which otherwise surfaces as an unrelated install or build error
# several minutes into a boot.
# Given no arguments it checks every repo; given path-variable names it checks
# only those, so a per-stack start is not refused over a checkout it never
# touches.
fleetcom_check_checkouts() {
	local var dir kind repo bad=0 vars
	if [ "$#" -gt 0 ]; then vars="$*"; else vars="$FLEETCOM_REPO_VARS"; fi
	for var in $vars; do
		eval "dir=\$$var"
		kind="$(fleetcom_checkout_kind "$dir")"
		case "$kind" in
			missing|not-a-repo)
				repo="$(fleetcom_repo_for_var "$var")"
				printf '[fleetcom] %s resolves to %s, which is %s.\n' "$repo" "$dir" \
					"$([ "$kind" = missing ] && printf 'not there' || printf 'not a git checkout')" >&2
				bad=1
				;;
		esac
	done
	if [ "$bad" -ne 0 ]; then
		printf '[fleetcom] Fix with "fleetcom worktree reset [repo]" or by editing local.conf.\n' >&2
		return 1
	fi
	return 0
}

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
