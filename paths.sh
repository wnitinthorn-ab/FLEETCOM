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

# MIDSHIP_AWS_PROFILE (see "Midship AWS profile" below) gets the identical
# save-before/restore-after treatment, just not folded into the loop above:
# FLEETCOM_REPO_VARS also drives the worktree machinery's positional pairing
# with FLEETCOM_REPO_NAMES (fleetcom_var_for_repo etc., further down), and
# this isn't a repo path — folding it in would quietly extend that pairing to
# a variable it was never meant to describe.
_fleetcom_env_MIDSHIP_AWS_PROFILE="${MIDSHIP_AWS_PROFILE:-}"

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
[ -n "$_fleetcom_env_MIDSHIP_AWS_PROFILE" ] && MIDSHIP_AWS_PROFILE="$_fleetcom_env_MIDSHIP_AWS_PROFILE"
unset _v _fleetcom_saved _fleetcom_env_MIDSHIP_AWS_PROFILE

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

# ---- Midship AWS profile (KMS + Secrets Manager) ---------------------------
#
# Midship's FastAPI process (midship-turbo-broccoli) needs real AWS credentials
# for two different things at runtime, via two different code paths:
# midship/client/secrets.py's AWSSecretsManager hardcodes profile_name="dev"
# for local envs, but midship/app_container.py's several
# `Resource(aioboto3.Session, region_name=...)` DI resources — used for KMS
# generate_data_key (Optro OAuth token encryption, on every "Sign in with
# Optro" callback) and S3 blob access — name no profile at all and fall back
# to the ambient/default AWS credential chain. FLEETCOM never exported
# AWS_PROFILE for the midship launch, so on a machine whose [default] profile
# carries no credentials (just a region), those KMS calls die with
# botocore.exceptions.NoCredentialsError — reproduced live as a 500 inside
# persist_optro_tokens -> credential_encryption.encrypt -> kms.generate_data_key.
#
# Hardcoding a profile NAME (as both the app code above and a one-off
# `AWS_PROFILE=dev` manual workaround do) only works because it happens to
# match a profile literally named "dev" on this machine. Profile names are
# per-developer/per-machine — this one also has "midship-dev" and
# "Midship_SystemAdministrator-637423606355" pointing at the exact same
# account/role — so FLEETCOM instead resolves by AWS ACCOUNT ID, which is the
# one identifier that doesn't change between checkouts of ~/.aws/config. It
# also means an ambient `AWS_PROFILE=Testing` (AuditBoard's own SSO profile,
# needed for its boot) can no longer silently hand Midship the wrong account
# by inheritance — the account-ID match structurally cannot select
# "Testing" (015096527731) or "midship-prod" (654654430428) for this.
#
# 637423606355 is Midship's AWS account — the one whose KMS keys and Secrets
# Manager entries the local FastAPI process needs to reach. It is a fixed
# property of the Midship account itself, not a per-machine path, so it gets
# a plain `:-` default rather than local.conf/worktrees.conf treatment — a
# developer who genuinely needs a different account can still override it via
# environment, same as any other `${VAR:-default}` line in this file.
MIDSHIP_AWS_ACCOUNT_ID="${MIDSHIP_AWS_ACCOUNT_ID:-637423606355}"

# fleetcom_resolve_aws_profile ACCOUNT_ID: prints the name of a profile in
# ~/.aws/config — or $AWS_CONFIG_FILE, the same override point the AWS CLI
# itself honors — whose `sso_account_id` matches ACCOUNT_ID. Prints nothing
# and returns 1, with an actionable message on stderr, when none do: a silent
# empty MIDSHIP_AWS_PROFILE is exactly the failure mode this whole mechanism
# exists to replace with a named cause.
#
# Multiple matches are resolved deterministically rather than by whatever
# order `~/.aws/config` happens to be in on a given machine: prefer a profile
# whose sso_role_name contains "Administrator" (case-insensitive), else the
# first match encountered in file order. In practice, on the machine this was
# written against, all three profiles matching Midship's account share the
# exact same role name (Midship_SystemAdministrator) — so the Administrator
# preference does no work there and file order is what actually picks `dev`.
# It stays as the primary rule anyway for a config where the matches disagree
# on role. A developer who wants a specific one of several matches sets
# MIDSHIP_AWS_PROFILE explicitly (below), which always wins over this.
fleetcom_resolve_aws_profile() {
	local want="$1" cfg line cur_name="" cur_account="" cur_role="" first_name="" admin_name=""
	cfg="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
	if [ ! -f "$cfg" ]; then
		printf '[fleetcom] no AWS config at %s — cannot resolve a profile for account %s\n' "$cfg" "$want" >&2
		return 1
	fi

	# Deliberately no bash arrays: this file is sourced under callers' `set -u`
	# (fleetcom-start-all.sh, fleetcom-doctor.sh), and on macOS's stock
	# /bin/bash (3.2) expanding an empty array under `set -u` is itself an
	# "unbound variable" error — the zero-matches case this function most
	# needs to handle cleanly. Plain string variables sidestep that entirely.
	#
	# The synthetic trailing "[__end__]" section lets the same "a new section
	# started, so score the block that just ended" branch below handle the
	# file's last profile too, instead of duplicating the scoring logic once
	# more after the loop.
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
			'['*)
				if [ -n "$cur_name" ] && [ "$cur_account" = "$want" ]; then
					[ -z "$first_name" ] && first_name="$cur_name"
					case "$cur_role" in *[Aa]dministrator*) [ -z "$admin_name" ] && admin_name="$cur_name" ;; esac
				fi
				case "$line" in
					'[profile '*) cur_name="${line#\[profile }"; cur_name="${cur_name%%]*}" ;;
					*)            cur_name="" ;;
				esac
				cur_account=""; cur_role=""
				;;
			*sso_account_id*=*) cur_account="$(printf '%s\n' "$line" | sed 's/^[^=]*=[[:space:]]*//')" ;;
			*sso_role_name*=*)  cur_role="$(printf '%s\n' "$line" | sed 's/^[^=]*=[[:space:]]*//')" ;;
		esac
	done < <(cat "$cfg"; printf '\n[__end__]\n')

	if [ -z "$first_name" ]; then
		printf '[fleetcom] no profile in %s has sso_account_id = %s — log into one (aws sso login --profile <name>) or configure one, then set MIDSHIP_AWS_PROFILE to name it explicitly\n' "$cfg" "$want" >&2
		return 1
	fi
	printf '%s\n' "${admin_name:-$first_name}"
}

# The actual default: auto-resolve unless env, worktrees.conf, or local.conf
# already set MIDSHIP_AWS_PROFILE (the save/restore dance above, plus
# local.conf/worktrees.conf being ordinary sourced bash, already gives this
# variable the same env > worktrees.conf > local.conf precedence every repo
# path gets — this is just the last link: what fills it in when none of the
# three named anything). A resolution failure is left as an empty string, not
# a hard error, so a shell that sources paths.sh for unrelated reasons (e.g.
# `fleetcom doctor` when only working on AuditBoard) doesn't die over it —
# callers that actually need it (fleetcom-start-all.sh) check for empty and
# say so themselves.
if [ -z "${MIDSHIP_AWS_PROFILE:-}" ]; then
	MIDSHIP_AWS_PROFILE="$(fleetcom_resolve_aws_profile "$MIDSHIP_AWS_ACCOUNT_ID" 2>/dev/null)" || MIDSHIP_AWS_PROFILE=""
fi

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

# ---- per-repo node version ---------------------------------------------------
#
# Each repo pins its own node, and they do not agree: auditboard-backend wants
# 24.19.0 while auditboard-frontend wants 24.12.0. A start launched from an
# arbitrary shell gets whatever that shell had, and the failure is reported by
# the package manager as an engines mismatch on a line buried in a build log —
# the AB client silently not listening on 9006, with the cause several hundred
# lines up.
#
# Resolved per repo, not globally, because no single version satisfies both.

# fleetcom_node_version DIR: the version DIR pins, from .nvmrc or package.json
# engines.node, or empty when it pins none.
fleetcom_node_version() {
	local dir="$1" version=""
	if [ -f "$dir/.nvmrc" ]; then
		version="$(tr -d '[:space:]v' < "$dir/.nvmrc" 2>/dev/null)"
	fi
	if [ -z "$version" ] && [ -f "$dir/package.json" ] && command -v node >/dev/null 2>&1; then
		version="$(node -e 'try{const p=require(process.argv[1]+"/package.json");const e=(p.engines&&p.engines.node)||"";process.stdout.write(e.replace(/[^0-9.]/g,""))}catch(_){}' "$dir" 2>/dev/null)"
	fi
	printf '%s\n' "$version"
}

# fleetcom_node_path_cmd DIR: a `PATH=… ` assignment to prefix a command with so
# it runs under DIR's pinned toolchain, or empty when nothing needs doing.
#
# **Volta is the mechanism here, not nvm.** Both AuditBoard repos declare a
# `volta` field in package.json — backend `node 24.19.0 / pnpm 10.34.5`,
# frontend `node 24.12.0 / pnpm 11.20.0` — and volta's shims do the per-project
# switch automatically *when they are the ones being invoked*. On this machine
# nvm also installs a node into PATH ahead of volta's shims, so `node` resolves
# to whatever nvm last selected and volta never gets to choose. That is why the
# frontend failed with `Expected version: 24.12.0 / Got: v20.19.4` while both
# versions were installed.
#
# So the fix is to put volta's bin FIRST, not to name a version: volta then
# reads the repo's own pin and picks correctly, including the pinned pnpm.
#
# **Must be applied inside `direnv exec`, not before it.** direnv re-evaluates
# the .envrc and rebuilds PATH, discarding anything set ahead of it — an earlier
# version of this prefixed the outer command and was silently overridden. The
# emitted string keeps `$PATH` unexpanded so the inner shell expands it after
# direnv has finished.
#
# Falls back to an nvm version directory for a repo that pins via .nvmrc or
# engines with no volta field. Empty when neither applies, when the toolchain
# manager is absent, or when nothing is pinned — a start that runs on the wrong
# node and says so beats one that does not start.
fleetcom_node_path_cmd() {
	local dir="$1" volta_pin volta_bin want bin
	[ -f "$dir/package.json" ] || return 0

	if command -v node >/dev/null 2>&1; then
		volta_pin="$(node -e 'try{const p=require(process.argv[1]+"/package.json");process.stdout.write(p.volta?"1":"")}catch(_){}' "$dir" 2>/dev/null)"
	fi
	if [ -n "$volta_pin" ]; then
		volta_bin="${VOLTA_HOME:-$HOME/.volta}/bin"
		if [ -d "$volta_bin" ]; then
			printf 'PATH=%s:$PATH ' "$(printf '%q' "$volta_bin")"
			return 0
		fi
		printf '[fleetcom] %s pins its toolchain with volta, which is not installed — starting on the ambient node\n' \
			"$(basename "$dir")" >&2
		return 0
	fi

	want="$(fleetcom_node_version "$dir")"
	[ -n "$want" ] || return 0
	[ "$(node -v 2>/dev/null | tr -d 'v')" = "$want" ] && return 0
	bin="${NVM_DIR:-$HOME/.nvm}/versions/node/v$want/bin"
	if [ ! -x "$bin/node" ]; then
		printf '[fleetcom] %s pins node %s, which is not installed (nvm install %s)\n' \
			"$(basename "$dir")" "$want" "$want" >&2
		return 0
	fi
	printf 'PATH=%s:$PATH ' "$(printf '%q' "$bin")"
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
