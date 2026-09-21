#!/bin/bash
# FLEETCOM worktree: point a stack at a git worktree instead of its main
# checkout, so a branch can be booted without disturbing the primary clone.
#
# Nothing in the start/stop scripts needs to know about this. They cd into a
# path and run pnpm/poetry/docker there, and a linked worktree is an ordinary
# directory — so the whole feature is deciding which path each repo resolves to.
# That decision is recorded in worktrees.conf and applied by paths.sh, which
# ranks it above local.conf and below the environment.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/paths.sh"

CONF="$FLEETCOM_WORKTREES_CONF"

usage() {
	cat <<'EOF'
usage: fleetcom worktree <subcommand>

  status                  What each repo currently resolves to
  list [repo]             Every git worktree of each repo, or of one repo
  use <repo> <ref|path>   Point a repo at one of its worktrees
      --no-env            Do not link gitignored config into the worktree
  reset [repo]            Drop the override for one repo, or all of them

  <repo> is a short name as printed by "status", e.g. midship-frontend.
  <ref|path> is a branch name to look up among that repo's worktrees, or a
  path to use directly.

  "use" also symlinks the gitignored config a fresh worktree lacks (.env and
  friends) from the checkout being left behind, and names any dependency
  install still needed. An existing real file in the target is never replaced.
EOF
}

# Every worktree of the repo whose *current* resolution is DIR. Asking git from
# inside any one worktree lists them all, so this works whether the repo is
# presently pointed at its main checkout or at a worktree.
worktrees_of() { # dir -> lines of "path<TAB>branch"
	local dir="$1"
	[ -d "$dir" ] || return 0
	git -C "$dir" worktree list --porcelain 2>/dev/null | awk '
		/^worktree /  { path = substr($0, 10) }
		/^branch /    { br = substr($0, 8); sub(/^refs\/heads\//, "", br);
		                printf "%s\t%s\n", path, br; path=""; br="" }
		/^detached/   { printf "%s\t(detached)\n", path; path="" }
	'
}

# Rewrite CONF with VAR set to DIR, or with VAR removed when DIR is empty.
# Written whole each time rather than appended to, so repeated `use` calls for
# one repo leave one line rather than a pile of shadowed ones.
write_override() { # var, dir-or-empty
	local var="$1" dir="${2:-}" tmp
	tmp="$(mktemp)"
	{
		printf '# FLEETCOM worktree overrides (gitignored, per-machine).\n'
		printf '# Written by "fleetcom worktree use"; drop with "fleetcom worktree reset".\n'
		printf '# Ranked above local.conf and below the environment — see paths.sh.\n'
		# Carry forward every other repo's existing override.
		if [ -f "$CONF" ]; then
			grep -E '^[A-Z_]+_DIR=' "$CONF" 2>/dev/null | grep -v "^$var=" || true
		fi
		[ -n "$dir" ] && printf '%s=%s\n' "$var" "$(printf '%q' "$dir")"
	} > "$tmp"
	mv "$tmp" "$CONF"
}

# A fresh git worktree carries only tracked files, so the gitignored config a
# stack needs to boot is simply absent — and every resulting failure names
# something other than the missing file. In midship-turbo-broccoli the suite and
# the API both die at import with `ValidationError: Token must be set`, because a
# Hatchet client is constructed at module scope in
# midship/heretic/hatchet/workflows/excel_screenshot.py and reads its token from
# .env. Cascade and auditboard-dev-env fail comparably on their own env files.
#
# **Symlinked, not copied.** A copy is a second place a rotated credential has to
# be updated and a second place it can leak from; a link means the worktree reads
# whatever the main checkout currently has. The same choice midship-frontend's
# own .claude/scripts/setup-worktree.sh makes for its paired worktrees.
#
# Per-repo, because what counts as "the env" differs: a file for most, a
# directory-local compose override for midship, an .envrc for auditboard-dev-env.
env_names_for_repo() {
	case "$1" in
		midship-turbo-broccoli)
			# docker-compose.override.yml is not configuration in the usual sense
			# but is gitignored and load-bearing: without it plain compose BUILDS
			# the wopi service from source and the midship boot fails at an
			# ssh-keyscan in its Dockerfile.
			printf '.env .env.local docker-compose.override.yml\n' ;;
		midship-frontend)   printf '.env .env.local .env.development.local\n' ;;
		cascade)            printf '.env .env.local\n' ;;
		auditboard-backend) printf '.env .envrc config/local.mjs\n' ;;
		auditboard-dev-env) printf '.env .envrc\n' ;;
		*)                  printf '.env .env.local\n' ;;
	esac
}

# link_env SOURCE_DIR TARGET_DIR REPO: link each gitignored config file the repo
# needs from the checkout that has it into the one that does not.
#
# Never overwrites a real file already in the target — a worktree someone has
# already configured by hand is theirs, and silently replacing its .env with a
# link to another checkout's is a change they did not ask for and cannot see.
# An existing symlink is refreshed, since that is this function's own output.
#
# Sets FLEETCOM_LAST_LINKED_ENVRC=1 when this call actually created/refreshed
# an .envrc symlink (as opposed to a repo whose env_names don't include one,
# or a target that already had a REAL .envrc and was left alone) — cmd_use
# reads that flag to decide whether the new worktree also needs `direnv
# allow`, which only a genuinely-linked .envrc does. See the comment there.
link_env() {
	local src="$1" dst="$2" repo="$3" name linked=0 skipped=0
	FLEETCOM_LAST_LINKED_ENVRC=0
	[ -d "$src" ] || return 0
	[ -d "$dst" ] || return 0
	[ "$src" = "$dst" ] && return 0
	for name in $(env_names_for_repo "$repo"); do
		[ -e "$src/$name" ] || continue
		# A path with a directory part (config/local.mjs) needs its parent.
		case "$name" in */*) mkdir -p "$dst/$(dirname "$name")" ;; esac
		if [ -e "$dst/$name" ] && [ ! -L "$dst/$name" ]; then
			printf '  kept existing %s (not a link; leaving it alone)\n' "$name"
			skipped=$((skipped + 1))
			continue
		fi
		ln -sfn "$src/$name" "$dst/$name"
		printf '  linked %s -> %s\n' "$name" "$src/$name"
		linked=$((linked + 1))
		[ "$name" = ".envrc" ] && FLEETCOM_LAST_LINKED_ENVRC=1
	done
	if [ "$linked" -eq 0 ] && [ "$skipped" -eq 0 ]; then
		printf '  no gitignored config found in %s to link\n' "$src"
	fi
}

# What the worktree still needs before it can serve, reported rather than run.
# Installing dependencies can take minutes and writes into the developer's tree;
# `worktree use` records a path and should not turn into that without being
# asked. Naming the command is the useful half.
report_deps() {
	local dir="$1" repo="$2"
	case "$repo" in
		midship-turbo-broccoli)
			# poetry.toml puts the venv in-project, so a worktree has none until
			# it is installed — and nothing else will say so.
			[ -d "$dir/.venv" ] || printf '  next: (cd %s && poetry install)\n' "$dir" ;;
		midship-frontend|auditboard-backend|auditboard-frontend)
			[ -d "$dir/node_modules" ] || printf '  next: (cd %s && pnpm install)\n' "$dir" ;;
		cascade)
			[ -d "$dir/node_modules" ] || printf '  next: (cd %s && pnpm install)  # plus its docker images\n' "$dir" ;;
	esac
}

cmd_status() {
	printf '== Checkouts FLEETCOM will boot ==\n'
	fleetcom_print_checkouts
	if [ -f "$CONF" ] && grep -qE '^[A-Z_]+_DIR=' "$CONF" 2>/dev/null; then
		printf '\nOverrides recorded in %s\n' "$CONF"
	else
		printf '\nNo worktree overrides recorded; every repo is at its configured checkout.\n'
	fi
}

cmd_list() {
	local only="${1:-}" var dir repo active
	for var in $FLEETCOM_REPO_VARS; do
		repo="$(fleetcom_repo_for_var "$var")"
		[ -n "$only" ] && [ "$only" != "$repo" ] && continue
		eval "dir=\$$var"
		printf '%s\n' "$repo"
		if [ ! -d "$dir" ]; then
			printf '  (resolves to %s, which is not there)\n' "$dir"
			continue
		fi
		local found=0
		while IFS="$(printf '\t')" read -r path branch; do
			[ -n "$path" ] || continue
			found=1
			# Marked against the resolved path so the line answers "is this the
			# one that will boot", which is the question being asked.
			if [ "$path" = "$dir" ]; then active="*"; else active=" "; fi
			printf '  %s %-22s %s\n' "$active" "$branch" "$path"
		done <<EOF
$(worktrees_of "$dir")
EOF
		[ "$found" -eq 0 ] && printf '  (no worktrees listed; not a git checkout?)\n'
		printf '\n'
	done
}

cmd_use() {
	local repo="" ref="" var dir target="" skip_env=0 a
	for a in "$@"; do
		case "$a" in
			--no-env) skip_env=1 ;;
			*) if [ -z "$repo" ]; then repo="$a"; elif [ -z "$ref" ]; then ref="$a"; fi ;;
		esac
	done
	if [ -z "$repo" ] || [ -z "$ref" ]; then usage >&2; exit 2; fi
	var="$(fleetcom_var_for_repo "$repo")" || {
		printf 'fleetcom worktree: unknown repo "%s"\n' "$repo" >&2
		printf 'known: %s\n' "$(printf '%s ' $FLEETCOM_REPO_NAMES)" >&2
		exit 2
	}
	eval "dir=\$$var"

	# A path is taken at face value; anything else is looked up as a branch
	# among that repo's worktrees. Checked in that order so a directory named
	# like a branch still resolves to the directory.
	if [ -d "$ref" ]; then
		target="$(cd "$ref" && pwd)"
	else
		while IFS="$(printf '\t')" read -r path branch; do
			[ "$branch" = "$ref" ] && target="$path" && break
		done <<EOF
$(worktrees_of "$dir")
EOF
	fi

	if [ -z "$target" ]; then
		printf 'fleetcom worktree: no worktree of %s is on "%s", and it is not a path.\n' "$repo" "$ref" >&2
		printf 'Existing worktrees:\n' >&2
		cmd_list "$repo" >&2
		# Offered only for something that could be a branch name. A ref holding a
		# slash-led path would otherwise be spliced into the suggested directory
		# name, printing a command that cannot work.
		case "$ref" in
			/*|*/*|.*|"")
				printf 'Give an existing branch from the list above, or a path to a checkout.\n' >&2
				;;
			*)
				printf 'Create one first, e.g.:\n  git -C %s worktree add ../%s-%s %s\n' "$dir" "$repo" "$ref" "$ref" >&2
				;;
		esac
		exit 1
	fi

	# Refused rather than recorded: an override pointing at something that is
	# not a checkout fails minutes into a boot, inside an install or build step,
	# where the message names anything but the real cause.
	local kind
	kind="$(fleetcom_checkout_kind "$target")"
	case "$kind" in
		missing|not-a-repo)
			printf 'fleetcom worktree: %s is %s — not recording it.\n' "$target" \
				"$([ "$kind" = missing ] && printf 'not there' || printf 'not a git checkout')" >&2
			exit 1
			;;
	esac

	write_override "$var" "$target"
	printf '%s -> %s (%s, %s)\n' "$repo" "$target" "$kind" "$(fleetcom_checkout_branch "$target")"

	# Provisioned from the checkout being left behind — `dir` still holds the
	# previous resolution at this point, which is the one that has been booting
	# and therefore the one whose gitignored config is known good.
	if [ "$skip_env" -eq 0 ]; then
		link_env "$dir" "$target" "$repo"
		# direnv trusts a config file by its own absolute path plus a content
		# hash, not by what a symlink points to — so the .envrc link_env just
		# created at this brand-new worktree PATH is untrusted even though it
		# points at an already-approved checkout's .envrc. Left alone, every
		# `direnv exec` against this worktree silently loads nothing from it:
		# no error, just MIDSHIP_OAUTH_CLIENT_ID/MIDSHIP_OAUTH_REDIRECT_URIS/
		# MIDSHIP_WORKSPACE_ID/BASE_URL (auditboard-backend) or the dev-env
		# equivalents simply absent from the environment. This is the same
		# gotcha CLAUDE.md documents for a hand-edited .envrc ("requires
		# direnv allow again, or every direnv exec fails") — a fresh worktree
		# is just a second way to trigger it, one `worktree use` used to leave
		# unhandled.
		if [ "$FLEETCOM_LAST_LINKED_ENVRC" -eq 1 ]; then
			if command -v direnv >/dev/null 2>&1; then
				if (cd "$target" && direnv allow .); then
					printf '  direnv allow: %s now trusted\n' "$target"
				else
					printf '  WARNING: "direnv allow" failed in %s — run it by hand or direnv exec there will silently miss its vars\n' "$target"
				fi
			else
				printf '  WARNING: direnv not installed — %s/.envrc is linked but untrusted; direnv exec there will silently miss its vars until "direnv allow" runs\n' "$target"
			fi
		fi
		report_deps "$target" "$repo"
	fi

	printf 'Restart that stack for it to take effect: fleetcom restart %s\n' "$(stack_of "$repo")"
}

# Which `fleetcom restart <stack>` argument covers a repo. Printed as advice
# only; a wrong guess here costs a word in a message, not a behaviour.
stack_of() {
	case "$1" in
		midship-*)     printf 'midship' ;;
		cascade)       printf 'cascade' ;;
		auditboard-*)  printf 'auditboard' ;;
		*)             printf '' ;;
	esac
}

cmd_reset() {
	local repo="${1:-}" var
	if [ -z "$repo" ]; then
		rm -f "$CONF"
		printf 'All worktree overrides dropped; every repo falls back to local.conf.\n'
		return 0
	fi
	var="$(fleetcom_var_for_repo "$repo")" || {
		printf 'fleetcom worktree: unknown repo "%s"\n' "$repo" >&2
		exit 2
	}
	write_override "$var" ""
	printf '%s override dropped.\n' "$repo"
}

sub="${1:-status}"
[ $# -ge 1 ] && shift || true
case "$sub" in
	status)        cmd_status ;;
	list)          cmd_list "${1:-}" ;;
	use)           cmd_use "$@" ;;
	reset)         cmd_reset "${1:-}" ;;
	-h|--help)     usage ;;
	*)             printf 'fleetcom worktree: unknown subcommand "%s"\n\n' "$sub" >&2; usage >&2; exit 2 ;;
esac
