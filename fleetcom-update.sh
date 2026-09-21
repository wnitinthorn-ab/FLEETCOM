#!/bin/bash
# FLEETCOM update: bring a checkout up to date and rebuild it, in the order the
# repo actually needs — which is not obvious, and each step here exists because
# skipping it produces a failure that names something else.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/paths.sh"

say()  { printf '\033[36m[update]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[update]\033[0m %s\n' "$*" >&2; }

usage() {
	cat <<'EOF'
usage: fleetcom update [auditboard|cascade|midship|all] [--migrate] [--no-build]

  Pulls the repo's default branch, then does whatever that repo needs to be
  runnable again: dependency install, a clean rebuild, and (opt-in) database
  migrations.

  --migrate     Also run database migrations. NOT the default: migrations are
                the one step here that is hard to undo, and a large pull can
                carry a lot of them.
  --no-build    Pull and install only; skip the rebuild.

  Stacks are not restarted. Run "fleetcom restart <stack>" when it finishes.
EOF
}

TARGET=all
MIGRATE=0
BUILD=1
for arg in "$@"; do
	case "$arg" in
		auditboard|cascade|midship|all) TARGET="$arg" ;;
		--migrate)   MIGRATE=1 ;;
		--no-build)  BUILD=0 ;;
		-h|--help)   usage; exit 0 ;;
		*) warn "ignoring unrecognised argument: $arg" ;;
	esac
done
want() { [ "$TARGET" = all ] || [ "$TARGET" = "$1" ]; }

# `--ff-only`: a pull that would need a merge means the checkout has local
# commits, and quietly merging someone's work-in-progress is not an update.
# Reported and skipped instead, so the rest of the run still happens.
pull() { # dir, label
	local dir="$1" label="$2" branch before after
	if [ ! -d "$dir/.git" ]; then
		warn "$label: $dir is not a git checkout — skipping"
		return 1
	fi
	branch="$(git -C "$dir" branch --show-current 2>/dev/null)"
	if [ -z "$branch" ]; then
		warn "$label: detached HEAD — skipping (checkout a branch first)"
		return 1
	fi
	before="$(git -C "$dir" rev-parse --short HEAD)"
	say "$label: fetching origin/$branch"
	git -C "$dir" fetch origin "$branch" --quiet || { warn "$label: fetch failed"; return 1; }

	# Asked before pulling, not discovered by pulling. A checkout that is
	# already current needs no pull at all, and attempting one anyway fails on
	# preconditions that have nothing to do with being out of date — a dirty
	# pnpm-lock.yaml from the install this script itself just ran is enough,
	# because `pull.rebase=true` refuses on unstaged changes before `--ff-only`
	# is ever consulted.
	local behind
	behind="$(git -C "$dir" rev-list --count "HEAD..origin/$branch" 2>/dev/null || echo 0)"
	if [ "$behind" = "0" ]; then
		say "$label: already current at $before"
		return 2
	fi

	# `--no-rebase` alongside `--ff-only`: the two are not redundant. `--ff-only`
	# says what merge is acceptable; `--no-rebase` is what stops a configured
	# `pull.rebase=true` from applying its own dirty-tree precondition first.
	local out
	if ! out="$(git -C "$dir" pull --ff-only --no-rebase origin "$branch" 2>&1)"; then
		# Git's own words. The previous version reported every failure as "not a
		# fast-forward", which sent anyone reading it to look for local commits
		# that did not exist.
		warn "$label: pull failed, leaving the checkout at $before"
		printf '%s\n' "$out" | sed 's/^/    /' >&2
		return 1
	fi
	after="$(git -C "$dir" rev-parse --short HEAD)"
	say "$label: $before -> $after ($behind commits)"
	return 0
}

# A pnpm repo whose engines field has moved past the installed node produces
# warnings on every workspace and then fails somewhere unrelated. Surfaced here,
# once, naming both versions — a `WARN Unsupported engine` line repeated 64
# times is easy to scroll past and is the actual cause.
check_node() { # dir, label
	local dir="$1" label="$2" wanted current
	wanted="$(node -e 'try{const p=require("'"$dir"'/package.json");process.stdout.write((p.engines&&p.engines.node)||"")}catch(e){}' 2>/dev/null || true)"
	[ -n "$wanted" ] || return 0
	current="$(node -v 2>/dev/null || echo none)"
	case "$current" in
		v${wanted%%.*}.*) return 0 ;;
	esac
	warn "$label: wants node $wanted, this shell has $current."
	warn "$label: install it (e.g. 'nvm install ${wanted%%.*}' or 'fnm install ${wanted%%.*}') before running the stack."
	return 0
}

update_auditboard() {
	local rc=0
	pull "$AB_BACKEND_DIR" "auditboard-backend" || rc=$?
	# `if`, not `[ ] && return`: under set -e a false test is a failing command
	# at function scope, which ends the run rather than continuing past it.
	if [ "$rc" -eq 1 ]; then return 0; fi
	pull "$AB_FRONTEND_DIR" "auditboard-frontend" || true
	pull "$AB_DEVENV_DIR"   "auditboard-dev-env"  || true

	check_node "$AB_BACKEND_DIR" "auditboard-backend"

	say "auditboard: installing dependencies"
	# `confirm-modules-purge=false`: pnpm prompts before wiping node_modules when
	# the lockfile or engines moved, and a prompt in a backgrounded run hangs
	# forever with no indication why.
	(cd "$AB_BACKEND_DIR" && pnpm install --config.confirm-modules-purge=false) \
		|| { warn "auditboard: pnpm install failed"; return 1; }

	if [ "$BUILD" -eq 1 ]; then
		# `dist/` is gitignored, so a pull that moves files leaves orphaned
		# compiled output behind. v1 then dies at boot with
		# "does not provide an export named X" — which reads as a code bug in a
		# file that is correct. Wiping first is what makes the rebuild honest.
		say "auditboard: wiping stale dist/ before rebuild"
		find "$AB_BACKEND_DIR" -type d -name dist -not -path "*/node_modules/*" -maxdepth 4 -exec rm -rf {} + 2>/dev/null || true
		# `pnpm -w ab build`, never a bare `ab build`: the build tool needs
		# pnpm's workspace context and fails without it.
		say "auditboard: building"
		(cd "$AB_BACKEND_DIR" && pnpm -w ab build) || { warn "auditboard: build failed"; return 1; }
	fi

	if [ "$MIGRATE" -eq 1 ]; then
		# Through direnv: db:sync reads DATABASE_URL, which FLEETCOM's onboard
		# block in auditboard-dev-env/.envrc repoints to port 5433 so it does not
		# collide with Midship's postgres on 5432. Run without it, this migrates
		# whatever happens to be on the default port.
		say "auditboard: running migrations (db:sync)"
		(cd "$AB_BACKEND_DIR" && direnv exec "$AB_DEVENV_DIR" pnpm db:sync) \
			|| { warn "auditboard: db:sync failed"; return 1; }
	else
		say "auditboard: migrations NOT run — pass --migrate, or run 'pnpm db:sync' yourself"
	fi

	# The generated .envrc may have changed shape upstream; onboard is what
	# re-applies FLEETCOM's port-deconfliction and Cascade SSO block on top.
	say "auditboard: if bin/generate-config changed, re-run fleetcom-onboard.sh to re-apply the FLEETCOM block"
}

update_cascade() {
	local rc=0
	pull "$CASCADE_DIR" "cascade" || rc=$?
	if [ "$rc" -eq 1 ]; then return 0; fi
	say "cascade: runs from docker images; 'fleetcom restart cascade' rebuilds what changed"
}

update_midship() {
	local rc=0
	pull "$MIDSHIP_TURBO_BROCCOLI_DIR" "midship-turbo-broccoli" || rc=$?
	if [ "$rc" -ne 1 ] && [ "$BUILD" -eq 1 ]; then
		say "midship-turbo-broccoli: poetry install"
		(cd "$MIDSHIP_TURBO_BROCCOLI_DIR" && poetry install) || warn "midship: poetry install failed"
		if [ "$MIGRATE" -eq 1 ]; then
			say "midship-turbo-broccoli: make migrate"
			(cd "$MIDSHIP_TURBO_BROCCOLI_DIR" && make migrate) || warn "midship: migrate failed"
		fi
	fi
	rc=0
	pull "$MIDSHIP_FRONTEND_DIR" "midship-frontend" || rc=$?
	if [ "$rc" -ne 1 ] && [ "$BUILD" -eq 1 ]; then
		say "midship-frontend: npm install"
		(cd "$MIDSHIP_FRONTEND_DIR" && npm install) || warn "midship-frontend: npm install failed"
	fi
}

# `if`, not `want x && f || true`: that form swallows a genuine failure inside
# the update function as success, which is the one outcome this must not hide.
FAILED=""
if want auditboard; then update_auditboard || FAILED="$FAILED auditboard"; fi
if want cascade;    then update_cascade    || FAILED="$FAILED cascade"; fi
if want midship;    then update_midship    || FAILED="$FAILED midship"; fi

if [ -n "$FAILED" ]; then
	warn "incomplete:$FAILED — see the warnings above"
	exit 1
fi

say "done — 'fleetcom doctor' to see current state, 'fleetcom restart <stack>' to pick it up"
