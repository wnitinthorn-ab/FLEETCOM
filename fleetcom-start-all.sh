#!/bin/bash
# FLEETCOM: boot Midship, AuditBoard, and Cascade in dependency order.
# Skips anything already running (checks the port first). Long-running dev
# servers are nohup'd with logs in ./logs/.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/paths.sh"
DEVENV="$AB_DEVENV_DIR"
CASCADE="$CASCADE_DIR"
LOGS="$HERE/logs"
mkdir -p "$LOGS"

say() { printf '\033[36m[start-all]\033[0m %s\n' "$*"; }
up()  { lsof -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

# args (recognized anywhere; unknown ones — e.g. --midship forwarded by
# fleetcom-start-claude.sh — are ignored, not errors):
#   --no-logs             don't auto-open the log view at the end
#   --tmux | --windows    force that log view for this run only (not persisted)
OPEN_LOGS=1
LOGS_VIEW_OVERRIDE=""
for arg in "$@"; do
	case "$arg" in
		--no-logs) OPEN_LOGS=0 ;;
		--tmux)    LOGS_VIEW_OVERRIDE=tmux ;;
		--windows) LOGS_VIEW_OVERRIDE=windows ;;
	esac
done

# nearly everything below needs the docker daemon; launch it if it's down
if ! docker info >/dev/null 2>&1; then
	say "docker daemon not reachable — launching Docker Desktop"
	open -a "Docker Desktop" 2>/dev/null || { say "ERROR: Docker Desktop not installed"; exit 1; }
	say "waiting for the docker engine (up to ~90s)..."
	for _i in $(seq 1 30); do sleep 3; docker info >/dev/null 2>&1 && break; done
	docker info >/dev/null 2>&1 || { say "ERROR: docker engine did not come up — start Docker Desktop manually"; exit 1; }
	say "docker engine is up"
fi

# --- Midship (fixed ports; owns 5432/6379/8080/9980/8000/5173) --------------
if [ -d "$MIDSHIP_TURBO_BROCCOLI_DIR" ]; then
	say "midship: docker services"
	(cd "$MIDSHIP_TURBO_BROCCOLI_DIR" && docker compose up -d)
	# wopi sometimes exits while its sibling onyx keeps running — surface why
	WOPI_ID=$(docker ps -aq --filter "name=wopi" 2>/dev/null | head -1)
	if [ -n "$WOPI_ID" ] && [ -z "$(docker ps -q --filter 'name=wopi' 2>/dev/null)" ]; then
		say "WARNING: wopi container is not running — last log lines, then attempting restart:"
		docker logs --tail 5 "$WOPI_ID" 2>&1 | sed 's/^/    [wopi] /' || true
		docker start "$WOPI_ID" >/dev/null 2>&1 || true
	fi
	# hatchet lives in its own compose project (hatchet-cli); restart its
	# containers if fleetcom-stop-all.sh --midship (or a reboot) stopped them
	HATCHET_STOPPED=$(docker ps -aq --filter "name=hatchet-cli" --filter "status=exited" 2>/dev/null || true)
	[ -n "$HATCHET_STOPPED" ] && docker start $HATCHET_STOPPED >/dev/null && say "restarted hatchet containers"
	docker ps -aq --filter "name=hatchet-cli" 2>/dev/null | grep -q . \
		|| say "note: hatchet not set up — run ./fleetcom-onboard.sh to install/start it (Midship's doc-pipeline workers need it)"
	if up 8000; then
		say "midship API already on 8000"
		echo "[fleetcom $(date '+%H:%M:%S')] Midship API already running on 8000 — launched outside FLEETCOM, so its output is NOT captured here. To capture: stop it, then re-run fleetcom-start-all.sh" >> "$LOGS/midship-api.log"
	else
		if ! command -v poetry >/dev/null; then
			say "WARNING: poetry not installed — SKIPPING the Midship API (install poetry, run 'poetry install' in midship-turbo-broccoli, re-run)"
		elif ! (cd "$MIDSHIP_TURBO_BROCCOLI_DIR" && poetry run python -c '' >/dev/null 2>&1); then
			say "WARNING: midship-turbo-broccoli's poetry env isn't set up — SKIPPING the Midship API (run 'poetry install' there, then re-run)"
		else
			say "midship API -> logs/midship-api.log"
			# --timeout-graceful-shutdown: uvicorn --reload hangs forever "waiting for
			# background tasks" when a file change triggers a reload; cap the wait so
			# reloads recover instead of wedging the API (port bound, nothing answering)
			(cd "$MIDSHIP_TURBO_BROCCOLI_DIR" && ENV=local_db nohup poetry run uvicorn midship.app.main:app --reload --timeout-graceful-shutdown 15 > "$LOGS/midship-api.log" 2>&1 &)
		fi
	fi
	# Hatchet workers (document/procedure/screenshot) are separate consumer
	# processes — the API only dispatches workflows onto Hatchet's queue.
	# Without these running, dispatched uploads sit queued forever with no
	# visible error (see README: Hatchet).
	if pgrep -f "midship.heretic.hatchet.worker" >/dev/null 2>&1; then
		say "midship hatchet workers already running"
	elif ! (cd "$MIDSHIP_TURBO_BROCCOLI_DIR" && poetry run python -c '' >/dev/null 2>&1); then
		say "WARNING: midship-turbo-broccoli's poetry env isn't set up — SKIPPING hatchet workers"
	else
		say "midship hatchet workers -> logs/midship-workers.log"
		# Isolate the worker process group (set -m enables job control, so the
		# backgrounded job gets its OWN pgid). run-workers.sh traps EXIT/INT/TERM
		# and runs `kill 0`; without its own group that would signal start-all's
		# entire group — the Midship API/frontend included — if the workers exit
		# (e.g. all three fail on a stale Hatchet token). With its own group the
		# kill 0 stays contained to the workers. fleetcom-stop-all.sh --midship
		# tears them down (matched by the same 'run-workers?.sh' / worker pattern).
		( cd "$MIDSHIP_TURBO_BROCCOLI_DIR" || exit 0; set -m; ENV=local_db nohup bash scripts/run-workers.sh > "$LOGS/midship-workers.log" 2>&1 & )
	fi
	if up 5173; then say "midship frontend already on 5173"; else
		if [ ! -d "$MIDSHIP_FRONTEND_DIR/node_modules" ]; then
			say "WARNING: midship-frontend has no node_modules — SKIPPING the Midship frontend (run 'npm install' there, then re-run)"
		else
			say "midship frontend -> logs/midship-frontend.log"
			(cd "$MIDSHIP_FRONTEND_DIR" && nohup npm run dev > "$LOGS/midship-frontend.log" 2>&1 &)
		fi
	fi
else
	say "WARNING: midship-turbo-broccoli not found at $MIDSHIP_TURBO_BROCCOLI_DIR — SKIPPING ALL OF MIDSHIP"
	say "WARNING: fix the MIDSHIP_*_DIR paths in local.conf (or re-run fleetcom-onboard.sh and use [p] at the clone offer)"
fi

# --- AuditBoard --------------------------------------------------------------
say "AB native databases (postgres 5433, redis 6382)"
ensure_native() { # port, brew service name
	up "$1" && return 0
	# brew services start both loads the LaunchAgent and starts it — required on
	# machines where the service was never started (bare launchctl kickstart
	# fails there with "Could not find service ... 502")
	brew services start "$2" >/dev/null 2>&1 || true
	launchctl kickstart "gui/$(id -u)/homebrew.mxcl.$2" 2>/dev/null || true
	local i; for i in 1 2 3 4 5; do sleep 2; up "$1" && return 0; done
	say "WARNING: $2 is not listening on port $1 — is it installed and configured?"
	say "         brew install $2   then re-run ./fleetcom-onboard.sh (it moves the port), then this script"
}
ensure_native 5433 postgresql@17
ensure_native 6382 redis

# integrations-extract only exists in newer dev-env checkouts — referencing an
# undefined service invalidates the whole compose project, so detect it first
SKIP="conductor"; UP_SERVICES=(conductor); UP_FILES=(-f docker-compose-supplement-dev.yml -f "$HERE/devenv.override.yml")
if (cd "$DEVENV" && direnv exec . docker compose -f docker-compose-supplement-dev.yml config --services 2>/dev/null | grep -qx integrations-extract); then
	SKIP="conductor,integrations-extract"
	UP_SERVICES+=(integrations-extract)
	UP_FILES+=(-f "$HERE/extract.override.yml")
else
	say "WARNING: no integrations-extract service in auditboard-dev-env — checkout outdated? (git -C $DEVENV pull, then abc run start-background)"
fi
say "AB background services ($SKIP start separately with local overrides)"
SB_LOG=$(mktemp)
if ! (cd "$DEVENV" && abc run start-background -- -s "$SKIP") 2>&1 | tee "$SB_LOG"; then
	if grep -qE "network [a-f0-9]+ not found" "$SB_LOG"; then
		# stopped containers pinned to a removed docker network (churn from
		# docker restarts / compose down) — recreate them on the live network
		say "stale docker network references detected — force-recreating the supplement containers"
		(cd "$DEVENV" && direnv exec . docker compose "${UP_FILES[@]}" up -d --force-recreate) \
			|| say "WARNING: force-recreate failed — see output above"
		(cd "$DEVENV" && abc run start-background -- -s "$SKIP") \
			|| say "WARNING: start-background still failing after network recovery — run it manually in $DEVENV to investigate"
	else
		say "WARNING: start-background FAILED — minio/poxa/ML/pdf/excelio may be down. Run 'abc run start-background' in $DEVENV to see why (common: ORKES_ACCESS_TOKEN missing from a stale .envrc — regenerate with CREATE_ENVRC=true bin/generate-config, then re-run fleetcom-onboard.sh)"
	fi
fi
rm -f "$SB_LOG"
(cd "$DEVENV" && direnv exec . docker compose "${UP_FILES[@]}" up -d "${UP_SERVICES[@]}") \
	|| say "WARNING: conductor/extract startup failed (see above) — continuing with the rest of the boot"

# machine-learning is cloned by start-background itself, so on a machine
# onboarded before its first boot the ML port override doesn't exist yet —
# without it ML grabs 8000 and collides with the Midship API
if [ -d "$ML_DIR" ] && ! grep -q '"8004:8000"' "$ML_DIR/docker-compose.override.yml" 2>/dev/null; then
	say "applying ML port override (host 8004) — machine-learning was cloned after onboarding"
	if grep -q "ab_mlservice_local:" "$ML_DIR/docker-compose.override.yml" 2>/dev/null; then
		awk '1; /^  ab_mlservice_local:$/ {
			print "    # FLEETCOM: host port moves off 8000 (held by Midship FastAPI)."
			print "    ports: !override"
			print "      - \"8004:8000\""
		}' "$ML_DIR/docker-compose.override.yml" > "$ML_DIR/docker-compose.override.yml.tmp" \
			&& mv "$ML_DIR/docker-compose.override.yml.tmp" "$ML_DIR/docker-compose.override.yml"
	else
		printf 'services:\n  ab_mlservice_local:\n    # FLEETCOM: host port moves off 8000.\n    ports: !override\n      - "8004:8000"\n' \
			> "$ML_DIR/docker-compose.override.yml"
	fi
	(cd "$ML_DIR" && docker compose up -d ab_mlservice_local) || say "WARNING: could not recreate ab_mlservice_local with the new port"
fi

if up 9001; then
	say "AB API already on 9001"
	echo "[fleetcom $(date '+%H:%M:%S')] AB API already running on 9001 — if it was launched outside FLEETCOM its output is NOT captured here. To capture: stop it, then re-run fleetcom-start-all.sh" >> "$LOGS/ab-api.log"
else
	# The API must run under a pty: turbo watch only kills the old api:v2
	# process on rebuild-restart when it has a controlling terminal. A nohup
	# launch leaks the old process -> EADDRINUSE -> v2 serves stale code.
	if command -v tmux >/dev/null; then
		say "AB API -> tmux session fleetcom-ab-api + logs/ab-api.log (migrations + api/worker/cron; takes a few minutes)"
		tmux kill-session -t fleetcom-ab-api 2>/dev/null || true
		tmux new-session -d -s fleetcom-ab-api "cd '$AB_BACKEND_DIR' && direnv exec . bin/start-api 2>&1 | tee '$LOGS/ab-api.log'"
	else
		say "WARNING: tmux missing — nohup fallback; edits to backend packages will NOT hot-swap api:v2 (see README). brew install tmux to fix"
		(cd "$AB_BACKEND_DIR" && nohup direnv exec . bin/start-api > "$LOGS/ab-api.log" 2>&1 &)
	fi
fi

# Probe Vite (9006), not Caddy (9002): the caddy docker container outlives a
# dead Vite process, so 9002 alone gives a false "already running".
if up 9006; then say "AB client already on 9006"; else
	if ! command -v pnpm >/dev/null; then
		say "WARNING: pnpm not found — SKIPPING the AB client (install volta + pnpm, or ask abc doctor; then re-run)"
	elif [ ! -d "$AB_FRONTEND_DIR/node_modules" ]; then
		say "WARNING: auditboard-frontend has no node_modules — SKIPPING the AB client (run 'pnpm install' there, then re-run)"
	else
		say "AB client -> logs/ab-client.log (ope dev from monorepo root; --reuse-last avoids the TTY prompt)"
		(cd "$AB_FRONTEND_DIR" && nohup direnv exec "$DEVENV" pnpm start --reuse-last > "$LOGS/ab-client.log" 2>&1 &)
	fi
fi

# --- Cascade -----------------------------------------------------------------
say "cascade: docker services (local image build; staged startup — parallel first-time"
say "  layer extraction of the 2.6GB server image can transiently fill the Docker VM disk)"
(cd "$CASCADE" \
	&& { docker image inspect local_test_web:latest >/dev/null 2>&1 \
		|| docker-compose -f docker-compose.yml -f docker-compose-build.yml -f docker-compose.override.yml build; } \
	&& docker-compose -f docker-compose.yml -f docker-compose-build.yml -f docker-compose.override.yml up -d db redis store \
	&& docker-compose -f docker-compose.yml -f docker-compose-build.yml -f docker-compose.override.yml up -d web \
	&& docker-compose -f docker-compose.yml -f docker-compose-build.yml -f docker-compose.override.yml up -d)
say "cascade: migrations"
docker exec cascade_web python manage.py migrate --no-input || say "migrate failed — is web still starting? retry: docker exec cascade_web python manage.py migrate"

if up 8088; then say "cascade client already on 8088"; else
	if [ ! -d "$CASCADE/client/node_modules" ]; then
		say "WARNING: cascade/client has no node_modules — SKIPPING the cascade client (cd cascade/client && npm install, then re-run)"
	elif command -v volta >/dev/null; then
		say "cascade client -> logs/cascade-client.log (node pinned from .nvmrc via volta)"
		(cd "$CASCADE/client" && nohup volta run --node "$(cat .nvmrc)" npm start > "$LOGS/cascade-client.log" 2>&1 &)
	elif [ -s "$HOME/.nvm/nvm.sh" ]; then
		say "cascade client -> logs/cascade-client.log (node pinned from .nvmrc via nvm)"
		(cd "$CASCADE/client" && nohup bash -lc 'source ~/.nvm/nvm.sh && nvm install && nvm use && npm start' > "$LOGS/cascade-client.log" 2>&1 &)
	else
		say "WARNING: neither volta nor nvm found — SKIPPING the cascade client (install volta, then re-run)"
	fi
fi

say "done — run ./fleetcom-doctor.sh to verify. AB: https://localhost:9002  Cascade: http://localhost:8088"

if [ "$OPEN_LOGS" = 1 ] && [ -t 0 ]; then
	say "opening backend logs (./fleetcom-logs.sh reopens later; --no-logs skips this; --tmux/--windows switches view)"
	# --tmux/--windows here is a one-run override via the LOGS_VIEW env (which
	# fleetcom-logs.sh honors over local.conf); it does NOT persist. Without it,
	# fleetcom-logs.sh uses your saved LOGS_VIEW as before.
	if [ -n "$LOGS_VIEW_OVERRIDE" ]; then
		LOGS_VIEW="$LOGS_VIEW_OVERRIDE" "$HERE/fleetcom-logs.sh"
	else
		"$HERE/fleetcom-logs.sh"
	fi
else
	say "backend logs + alerts: ./fleetcom-logs.sh"
fi
