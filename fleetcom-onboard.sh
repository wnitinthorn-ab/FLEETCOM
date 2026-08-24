#!/bin/bash
# FLEETCOM onboarding: apply all port-deconfliction + SSO config for
# running Midship, Cascade, and AuditBoard side-by-side. Idempotent — safe to
# re-run any time (e.g. after `bin/generate-config` regenerates .envrc, or
# after a machine-learning pull reverts its compose override).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/paths.sh"
MARKER="FLEETCOM"
# derive the Homebrew prefix — /opt/homebrew on Apple Silicon, /usr/local on Intel
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
PG_CONF="$BREW_PREFIX/var/postgresql@17/postgresql.conf"
REDIS_CONF="$BREW_PREFIX/etc/redis.conf"

say() { printf '\033[36m[onboard]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[onboard] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- repo locations ----------------------------------------------------------
# Prompt once (Enter accepts the default), persist to gitignored local.conf.
# Re-run with --reconfigure to change. Without a TTY, defaults are used as-is.
prompt_path() { # varname, description — read -e enables tab-completion
	local var=$1 desc=$2 val
	read -e -r -p "[onboard] $desc [${!var}]: " val || true
	val="${val:-${!var}}"
	val="${val/#\~/$HOME}"
	[ -d "$val" ] || say "note: $val does not exist (yet)"
	printf -v "$var" '%s' "$val"
}
if [ ! -f "$HERE/local.conf" ] || [ "${1:-}" = "--reconfigure" ]; then
	if [ -t 0 ]; then
		say "where does each repo live? (Enter accepts the default; tab-completion works)"
		prompt_path MIDSHIP_TURBO_BROCCOLI_DIR "midship-turbo-broccoli"
		prompt_path MIDSHIP_FRONTEND_DIR       "midship-frontend"
		prompt_path MIDSHIP_ONYX_DIR           "midship-onyx (source reference only)"
		prompt_path CASCADE_DIR                "cascade"
		prompt_path AB_BACKEND_DIR             "auditboard-backend"
		prompt_path AB_FRONTEND_DIR            "auditboard-frontend"
		prompt_path AB_DEVENV_DIR              "auditboard-dev-env"
		ML_DIR="$AB_DEVENV_DIR/machine-learning"
	else
		say "no TTY — using default/current repo paths"
	fi
	cat > "$HERE/local.conf" <<EOF
# FLEETCOM per-machine repo locations (gitignored).
# Regenerate with: ./fleetcom-onboard.sh --reconfigure
# Non-sibling layouts: hand-edit any path below — scripts read these variables
# verbatim; the parent-dir prompts are just a convenience.
MIDSHIP_TURBO_BROCCOLI_DIR="$MIDSHIP_TURBO_BROCCOLI_DIR"
MIDSHIP_FRONTEND_DIR="$MIDSHIP_FRONTEND_DIR"
MIDSHIP_ONYX_DIR="$MIDSHIP_ONYX_DIR"
CASCADE_DIR="$CASCADE_DIR"
AB_BACKEND_DIR="$AB_BACKEND_DIR"
AB_FRONTEND_DIR="$AB_FRONTEND_DIR"
AB_DEVENV_DIR="$AB_DEVENV_DIR"
EOF
	say "repo paths saved to local.conf — change any of them later by hand-editing"
	say "local.conf or re-running ./fleetcom-onboard.sh --reconfigure"
fi
# --- locate or clone any missing repos ----------------------------------------
# All repos live in the soxhub GitHub org; gh handles auth (no SSH keys needed).
CLONED=0
set_conf() { # varname, value — update the running shell AND local.conf
	local var=$1 val=$2
	printf -v "$var" '%s' "$val"
	if grep -q "^${var}=" "$HERE/local.conf" 2>/dev/null; then
		sed -i '' "s|^${var}=.*|${var}=\"${val}\"|" "$HERE/local.conf"
	else
		printf '%s="%s"\n' "$var" "$val" >> "$HERE/local.conf"
	fi
}
gh_clone() { # soxhub repo name, destination
	command -v gh >/dev/null || die "gh CLI required to clone (brew install gh && gh auth login)"
	gh repo clone "soxhub/$1" "$2"
	CLONED=1
}
ensure_repo() { # varname, soxhub repo name
	local var=$1 name=$2 path yn newpath
	path="${!var}"
	[ -d "$path/.git" ] && return 0
	if [ ! -t 0 ]; then
		say "WARNING: $name missing at $path — clone it, or re-run fleetcom-onboard.sh interactively"
		return 0
	fi
	while :; do
		say "$name is not at $path"
		read -r -p "[onboard]   [C]lone it there / [p]oint to a different path (existing checkout or clone target) / [s]kip: " yn || true
		case "$yn" in
			[Ss]*)
				say "skipped $name — set $var in local.conf when ready"
				return 0
			;;
			[Pp]*)
				read -e -r -p "[onboard]   path for $name: " newpath || true
				newpath="${newpath/#\~/$HOME}"
				[ -z "$newpath" ] && continue
				if [ -d "$newpath/.git" ]; then
					set_conf "$var" "$newpath"
					say "$name -> $newpath (saved to local.conf)"
					return 0
				elif [ -e "$newpath" ]; then
					say "$newpath exists but is not a git checkout — try again"
				else
					read -r -p "[onboard]   $newpath doesn't exist — clone $name there? [Y/n] " yn || true
					case "$yn" in
						[Nn]*) continue ;;
						*)
							gh_clone "$name" "$newpath"
							set_conf "$var" "$newpath"
							return 0
						;;
					esac
				fi
			;;
			*)
				gh_clone "$name" "$path"
				return 0
			;;
		esac
	done
}
ensure_repo MIDSHIP_TURBO_BROCCOLI_DIR midship-turbo-broccoli
ensure_repo MIDSHIP_FRONTEND_DIR       midship-frontend
ensure_repo MIDSHIP_ONYX_DIR           midship-onyx
ensure_repo CASCADE_DIR                cascade
ensure_repo AB_BACKEND_DIR             auditboard-backend
ensure_repo AB_FRONTEND_DIR            auditboard-frontend
ensure_repo AB_DEVENV_DIR              auditboard-dev-env

# aliases resolve AFTER ensure_repo, which may have re-pointed variables
DEVENV="$AB_DEVENV_DIR"
CASCADE="$CASCADE_DIR"
ML="$AB_DEVENV_DIR/machine-learning"
[ "$CLONED" = 1 ] && say "note: fresh clones get their dependency installs later in this run ('checking app dependencies' step)"

# --- prerequisites ---------------------------------------------------------
for cmd in brew docker direnv gh abc lsof poetry; do
	command -v "$cmd" >/dev/null || die "missing prerequisite: $cmd"
done
[ -e "$PG_CONF" ] || die "postgresql@17 not installed (no $PG_CONF) — brew install postgresql@17"
[ -e "$REDIS_CONF" ] || die "redis not installed (no $REDIS_CONF) — brew install redis"
gh auth status >/dev/null 2>&1 || say "WARNING: gh is not authenticated (run: gh auth login) — repo cloning will fail until you do"
# the docker BINARY existing doesn't mean the daemon is up (fresh machines
# often have Docker Desktop installed but not launched)
if ! docker info >/dev/null 2>&1; then
	say "docker daemon not reachable — launching Docker Desktop"
	open -a "Docker Desktop" 2>/dev/null || die "Docker Desktop not installed — install it, then re-run"
	say "waiting for the docker engine (up to ~90s)..."
	for _i in $(seq 1 30); do sleep 3; docker info >/dev/null 2>&1 && break; done
	docker info >/dev/null 2>&1 || die "docker engine did not come up — start Docker Desktop manually, then re-run"
	say "docker engine is up"
fi
docker compose version --short | awk -F. '{ exit !($1 > 2 || ($1 == 2 && $2 >= 24)) }' \
	|| die "docker compose >= 2.24 required (for !override port merging)"
[ -d "$DEVENV" ] || die "$DEVENV not found — re-run and accept the clone offer, or run 'abc init'"
[ -d "$CASCADE" ] || die "$CASCADE not found — re-run and accept the clone offer"
[ -f "$DEVENV/.envrc" ] || die "$DEVENV/.envrc missing — run CREATE_ENVRC=true bin/generate-config"

# --- 0. Docker Desktop resources: >=12G memory, >=120G disk -----------------
# Three stacks need ~50GB of images plus working space, and the AB + ML
# containers are memory-hungry. Requires a Docker Desktop restart to apply.
DOCKER_SETTINGS="$HOME/Library/Group Containers/group.com.docker/settings-store.json"
WANT_MEM_MIB=12288 WANT_DISK_MIB=122880

# Three outcomes, not two: provisioned / under-provisioned / UNREADABLE.
# ~/Library/Group Containers is TCC-protected on macOS, so a terminal without
# Full Disk Access gets EPERM here even though settings-store.json is itself
# world-readable. The old check treated any non-zero exit as "under-provisioned",
# so an unreadable file reported specific MiB numbers it had never read — and
# accepting the offer quit Docker Desktop (stopping every container), hit the
# same EPERM on the write, and restarted Docker having changed nothing.
# Exit codes: 0 ok, 1 too low, 2 unreadable (TCC), 3 missing/malformed.
docker_settings_state() {
	python3 - "$DOCKER_SETTINGS" "$WANT_MEM_MIB" "$WANT_DISK_MIB" 2>/dev/null <<'DOCKER_SETTINGS_PY'
import json, sys
try:
    s = json.load(open(sys.argv[1]))
except PermissionError:
    sys.exit(2)
except Exception:
    sys.exit(3)
sys.exit(0 if s.get("MemoryMiB", 0) >= int(sys.argv[2])
           and s.get("DiskSizeMiB", 0) >= int(sys.argv[3]) else 1)
DOCKER_SETTINGS_PY
}

say_docker_manual() { # the fallback that always works, whatever went wrong
	say "  Set them by hand instead: Docker Desktop > Settings > Resources >"
	say "  Memory >= $((WANT_MEM_MIB / 1024))GB, Disk >= $((WANT_DISK_MIB / 1024))GB, then Apply & Restart."
}

docker_settings_state; DOCKER_STATE=$?
case "$DOCKER_STATE" in
0)
	say "Docker Desktop resources already >= ${WANT_MEM_MIB}MiB memory / ${WANT_DISK_MIB}MiB disk"
	;;
2)
	say "WARNING: cannot READ Docker Desktop's settings — macOS blocked it (not a file-permission issue)."
	say "  '~/Library/Group Containers' is TCC-protected: your terminal needs Full Disk Access."
	say "  System Settings > Privacy & Security > Full Disk Access > + > your terminal app,"
	say "  then FULLY QUIT and reopen the terminal (a reload is not enough) and re-run this."
	say_docker_manual
	say "  Skipping the resource check — cannot verify or change it from here."
	;;
3)
	say "WARNING: Docker Desktop settings not found or unreadable at:"
	say "  $DOCKER_SETTINGS"
	say "  (Docker Desktop not installed yet, or a version that stores settings elsewhere.)"
	say_docker_manual
	;;
1)
	say "Docker Desktop is below ${WANT_MEM_MIB}MiB memory / ${WANT_DISK_MIB}MiB disk"
	yn=n
	[ -t 0 ] && { read -r -p "[onboard] Restart Docker Desktop now to apply? ALL running containers stop; re-run fleetcom-start-all.sh after. [y/N] " yn || true; }
	if [[ "$yn" =~ ^[Yy]$ ]]; then
		# Prove we can write BEFORE quitting Docker — otherwise a failure here
		# costs the user every running container in exchange for nothing.
		if ! python3 -c 'open(__import__("sys").argv[1], "a").close()' "$DOCKER_SETTINGS" 2>/dev/null; then
			say "ERROR: settings file is readable but NOT writable — leaving Docker Desktop running."
			say_docker_manual
		else
			osascript -e 'quit app "Docker Desktop"' 2>/dev/null || true
			sleep 10
			if python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["MemoryMiB"]=max(s.get("MemoryMiB",0),int(sys.argv[2])); s["DiskSizeMiB"]=max(s.get("DiskSizeMiB",0),int(sys.argv[3])); json.dump(s,open(p,"w"),indent=1)' "$DOCKER_SETTINGS" "$WANT_MEM_MIB" "$WANT_DISK_MIB" 2>/dev/null; then
				say "applied — Memory >= ${WANT_MEM_MIB}MiB, Disk >= ${WANT_DISK_MIB}MiB"
			else
				say "ERROR: could not write the settings — restarting Docker Desktop unchanged."
				say_docker_manual
			fi
			open -a "Docker Desktop"
			say "waiting for docker engine..."
			until docker info >/dev/null 2>&1; do sleep 3; done
			say "docker is back — remember: midship compose services do NOT auto-restart (run fleetcom-start-all.sh)"
		fi
	else
		say "skipped — set Memory >=12GB and Disk >=120GB in Docker Desktop > Settings > Resources"
	fi
	;;
esac

# --- 1. Homebrew Postgres -> 5433 -----------------------------------------
if grep -qE '^port = 5433' "$PG_CONF"; then
	say "postgres already on 5433"
else
	grep -qE '^#?port = ' "$PG_CONF" || die "no port line found in $PG_CONF"
	sed -i '' -E "s|^#?port = [0-9]+|port = 5433|" "$PG_CONF"
	say "postgres port set to 5433 (was 5432 default)"
fi
brew services start postgresql@17 >/dev/null 2>&1 || true
launchctl kickstart gui/$(id -u)/homebrew.mxcl.postgresql@17 2>/dev/null || true

# --- 2. Homebrew Redis -> 6382 (6380/6381 belong to ML redisearch) ---------
if grep -qE '^port 6382' "$REDIS_CONF"; then
	say "redis already on 6382"
else
	sed -i '' -E "s|^port [0-9]+|port 6382|" "$REDIS_CONF"
	say "redis port set to 6382"
fi
brew services start redis >/dev/null 2>&1 || true
launchctl kickstart -k gui/$(id -u)/homebrew.mxcl.redis 2>/dev/null || true

# --- 3. dev-env .envrc override block --------------------------------------
# A stale generated .envrc (predating current generate-config) breaks things
# in cascading ways — no ORKES_ACCESS_TOKEN means start-background refuses to
# run at all. Offer regeneration; keep a backup; preserve the SSO secret so
# cascade/.env stays in sync.
PRESERVED_SECRET=""
if ! grep -q "^export ORKES_ACCESS_TOKEN=" "$DEVENV/.envrc" && [ -t 0 ]; then
	say "your .envrc is STALE — it lacks ORKES_ACCESS_TOKEN, so AB background services (minio/poxa/ML/...) cannot start"
	read -r -p "[onboard] Regenerate .envrc via generate-config now? (backup kept; FLEETCOM settings re-applied automatically) [Y/n] " RYN || true
	case "$RYN" in
		[Nn]*) say "skipped — expect 'abc run start-background' to fail until regenerated" ;;
		*)
			PRESERVED_SECRET=$(grep "^export CASCADE_JWT_SECRET=" "$DEVENV/.envrc" | cut -d"'" -f2 || true)
			cp "$DEVENV/.envrc" "$DEVENV/.envrc.fleetcom-backup"
			say "backup saved: $DEVENV/.envrc.fleetcom-backup"
			(cd "$DEVENV" && CREATE_ENVRC=true abc run generate-config) \
				|| say "WARNING: generate-config failed — restore from .envrc.fleetcom-backup if needed"
		;;
	esac
fi
if grep -q "$MARKER" "$DEVENV/.envrc"; then
	say ".envrc override block already present"
	SECRET=$(grep "^export CASCADE_JWT_SECRET=" "$DEVENV/.envrc" | cut -d"'" -f2)
else
	SECRET=${PRESERVED_SECRET:-$(openssl rand -hex 32)}
	cat >> "$DEVENV/.envrc" <<EOF

# ============================================================================
# $MARKER overrides — keep this block LAST (last export wins).
# Re-run FLEETCOM/fleetcom-onboard.sh after bin/generate-config regenerates
# this file. Deconflicts ports with the Midship stack (which holds 5432,
# 6379, 8000, 8080) and wires local Cascade SSO.
# ============================================================================
export DATABASE_URL=postgres://\$DB_USER@localhost:5433/\$DB_NAME
export REDIS_URL='redis://localhost:6382'
export DOCKER_REDIS_URL='redis://host.docker.internal:6382'
export PERMISSIONS_DATABASE_URL='postgres://postgres@host.docker.internal:5433/demo_data'
export CONDUCTOR_SERVER_URL='http://localhost:18080/api'
export AB_MLSERVICE_LOCAL_SERVICE_PORT='8004'
export CASCADE_JWT_SECRET='${SECRET}'
EOF
	say ".envrc override block appended (new shared JWT secret generated)"
fi
# Older generated .envrc files predate the SOX-88587 key rotation and lack the
# credential-encryption keys — symptom: the AB Automations/Workflows page fails
# with "RangeError: Invalid key length". Backfill them from generate-config.
for key in SHARED_EXTERNAL_ENCRYPTION_KEY EXTERNAL_SECRET_ENCRYPTION_KEY; do
	if ! grep -q "^export $key=" "$DEVENV/.envrc"; then
		if grep -q "^export $key=" "$DEVENV/bin/generate-config"; then
			say "your .envrc predates current generate-config — backfilling $key from it"
			grep "^export $key=" "$DEVENV/bin/generate-config" | head -1 >> "$DEVENV/.envrc"
		else
			say "WARNING: $key missing from both .envrc and bin/generate-config — Automations credential decryption will fail (RangeError: Invalid key length)"
		fi
	fi
done
(cd "$DEVENV" && direnv allow)

# --- 4. Cascade docker-compose.override.yml ---------------------------------
cp "$(dirname "$0")/cascade-compose.override.yml" "$CASCADE/docker-compose.override.yml"
grep -qx "docker-compose.override.yml" "$CASCADE/.git/info/exclude" 2>/dev/null \
	|| echo "docker-compose.override.yml" >> "$CASCADE/.git/info/exclude"
say "cascade compose override installed (redis 63790, debugpy 15678+, local image tag)"

# --- 5. machine-learning override: ML local -> 8004 -------------------------
if [ -d "$ML" ]; then
	if grep -q '"8004:8000"' "$ML/docker-compose.override.yml" 2>/dev/null; then
		say "ML port override already present"
	elif grep -q "ab_mlservice_local:" "$ML/docker-compose.override.yml" 2>/dev/null; then
		# insert ports override under the service key (tracked file — shows as modified)
		awk '1; /^  ab_mlservice_local:$/ {
			print "    # FLEETCOM: host port moves off 8000 (held by Midship FastAPI)."
			print "    ports: !override"
			print "      - \"8004:8000\""
		}' "$ML/docker-compose.override.yml" > "$ML/docker-compose.override.yml.tmp" \
			&& mv "$ML/docker-compose.override.yml.tmp" "$ML/docker-compose.override.yml"
		say "ML port override inserted into existing docker-compose.override.yml"
	else
		printf 'services:\n  ab_mlservice_local:\n    # FLEETCOM: host port moves off 8000.\n    ports: !override\n      - "8004:8000"\n' \
			> "$ML/docker-compose.override.yml"
		say "ML docker-compose.override.yml created"
	fi
else
	say "machine-learning repo not found (start-background clones it) — re-run fleetcom-onboard.sh after first start"
fi

# --- 6. Cascade .env SSO block ----------------------------------------------
[ -f "$CASCADE/.env" ] || { [ -f "$CASCADE/.env.example" ] && cp "$CASCADE/.env.example" "$CASCADE/.env" && say "cascade .env created from .env.example — fill in SECRET_KEY/SALT_KEY/LaunchDarkly keys"; }
# dotenv semantics: the last occurrence of a key wins, so appending overrides.
for key in SECRET_KEY SALT_KEY; do
	if ! grep -qE "^${key}=.+" "$CASCADE/.env"; then
		printf '%s=%s\n' "$key" "$(openssl rand -hex 32)" >> "$CASCADE/.env"
		say "cascade .env: generated $key"
	fi
done
# LaunchDarkly keys are real secrets each dev must supply: prompted here and
# written ONLY to cascade/.env (gitignored in cascade). Get them from 1Password.
# dotenv semantics: last occurrence wins, so appending overrides empty values.
if ! { grep -qE '^LAUNCH_DARKLY_SDK_KEY=.+' "$CASCADE/.env" && grep -qE '^LAUNCH_DARKLY_CLIENT_ID=.+' "$CASCADE/.env"; }; then
	if [ -t 0 ]; then
		say "LaunchDarkly keys for cascade — 1Password > QE Team Vault > Cascade base env file (stored only in cascade/.env; Enter to skip)"
		read -r -p "[onboard]   LAUNCH_DARKLY_SDK_KEY (sdk-...): " LD_SDK || true
		read -r -p "[onboard]   LAUNCH_DARKLY_CLIENT_ID (hex): " LD_CID || true
		if [ -n "${LD_SDK:-}" ] && [ -n "${LD_CID:-}" ]; then
			printf '\nLAUNCH_DARKLY_SDK_KEY=%s\nLAUNCH_DARKLY_CLIENT_ID=%s\n' "$LD_SDK" "$LD_CID" >> "$CASCADE/.env"
			say "LaunchDarkly keys written to cascade/.env"
		else
			say "WARNING: skipped — the cascade client will crash fetching flags (and land on /404) until both are set in cascade/.env; re-run fleetcom-onboard.sh to be prompted again"
		fi
	else
		say "WARNING: LAUNCH_DARKLY_SDK_KEY / LAUNCH_DARKLY_CLIENT_ID missing from cascade/.env and no TTY to prompt — set them manually or re-run fleetcom-onboard.sh interactively"
	fi
fi
# Validate whatever LaunchDarkly credentials are CURRENTLY in cascade/.env —
# existence alone doesn't mean LaunchDarkly accepts them (e.g. the SDK key and
# client ID got swapped, or one was mistyped, just now or in a past run that
# onboarding's non-empty check can't tell apart from a good one). Runs
# unconditionally so a stale bad value from a prior run gets caught too, not
# just a value just typed above. Fails OPEN: only a definitive 401 is treated
# as invalid — a network hiccup or unexpected status reads as "couldn't
# verify", never forcing a needless fix for a value that was actually fine.
LD_SDK_VAL=$(grep -E '^LAUNCH_DARKLY_SDK_KEY=.+' "$CASCADE/.env" | tail -1 | cut -d= -f2-)
LD_CID_VAL=$(grep -E '^LAUNCH_DARKLY_CLIENT_ID=.+' "$CASCADE/.env" | tail -1 | cut -d= -f2-)
if [ -n "$LD_SDK_VAL" ] && [ -n "$LD_CID_VAL" ]; then
	SDK_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
		-H "Authorization: $LD_SDK_VAL" https://sdk.launchdarkly.com/sdk/latest-all 2>/dev/null)
	LD_CTX=$(printf '{"kind":"user","key":"fleetcom-onboard-check","anonymous":true}' | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
	CID_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
		"https://clientsdk.launchdarkly.com/sdk/evalx/$LD_CID_VAL/contexts/$LD_CTX" 2>/dev/null)
	if [ "$SDK_CODE" = "401" ] || [ "$CID_CODE" = "401" ]; then
		say "WARNING: LaunchDarkly rejected the credentials in cascade/.env (SDK key check: $SDK_CODE, Client ID check: $CID_CODE) — the cascade client will crash fetching flags (401) until fixed. Get fresh values from 1Password > QE Team Vault > Cascade base env file and hand-edit LAUNCH_DARKLY_SDK_KEY/LAUNCH_DARKLY_CLIENT_ID in cascade/.env — re-running onboarding won't catch a wrong value that's already non-empty"
	elif [ "$SDK_CODE" = "200" ] && [ "$CID_CODE" = "200" ]; then
		say "cascade/.env LaunchDarkly credentials verified OK"
	else
		say "note: couldn't verify cascade/.env LaunchDarkly credentials (LaunchDarkly unreachable or returned an unexpected status) — skipping"
	fi
fi
if grep -q "$MARKER" "$CASCADE/.env"; then
	say "cascade .env SSO block already present"
else
	cat >> "$CASCADE/.env" <<EOF

# ==== $MARKER SSO wiring (matches CASCADE_JWT_SECRET in auditboard-dev-env/.envrc)
JWT_AUTH_SHARED_SECRET=${SECRET}
JWT_AUTH_ISSUER=auditboard
AB_DOMAINS=localhost:9002
AB_LOGIN_URL=https://localhost:9002/login
EOF
	say "cascade .env SSO block appended"
fi
# Point cascade at the integrations-extract side service (Automations /
# "Import from Integrations"). Cascade's manager initializes its ExtractClient
# at container boot — fleetcom-start-all boots extract (AB background services)
# before cascade, and the .env change makes compose recreate cascade's
# containers on the next up, so the ordering is handled automatically.
if ! grep -qE '^EXTRACT_HOST=.+' "$CASCADE/.env"; then
	printf 'EXTRACT_HOST=host.docker.internal:3001\n' >> "$CASCADE/.env"
	say "cascade .env: EXTRACT_HOST -> host.docker.internal:3001 (integrations-extract)"
fi

# --- 6b. dependency installs (idempotent — heavy only on first run) ----------
say "checking app dependencies (a first run can take several minutes)"
if [ -d "$AB_FRONTEND_DIR" ]; then
	if command -v pnpm >/dev/null; then
		NEEDS_REFRESH=0
		if [ ! -d "$AB_FRONTEND_DIR/node_modules" ]; then
			NEEDS_REFRESH=1
		else
			# node_modules existing doesn't mean it's intact — an interrupted
			# install can leave a dangling pnpm virtual-store symlink under
			# .pnpm, which doesn't fail install but crashes dev servers later
			# with an ENOENT lstat. `-exec test -e {} \;` forks per symlink
			# (~9.5k of them here) and takes ~60s; a bash-builtin loop over
			# null-delimited find output does the same check in well under 1s.
			BROKEN_LINK=""
			while IFS= read -r -d '' link; do
				[ -e "$link" ] || { BROKEN_LINK="$link"; break; }
			done < <(find "$AB_FRONTEND_DIR/node_modules/.pnpm" -maxdepth 3 -type l -print0 2>/dev/null)
			if [ -n "$BROKEN_LINK" ]; then
				say "auditboard-frontend/node_modules has a broken pnpm store link (partial/interrupted install)"
				NEEDS_REFRESH=1
			fi
		fi
		if [ "$NEEDS_REFRESH" = 1 ]; then
			say "refreshing dependencies in auditboard-frontend (./refresh.sh)..."
			(cd "$AB_FRONTEND_DIR" && ./refresh.sh) || say "WARNING: ./refresh.sh failed in auditboard-frontend"
		else
			say "auditboard-frontend/node_modules OK"
		fi
	else
		say "WARNING: pnpm not found — skipping auditboard-frontend deps (install volta + pnpm, or run abc doctor --fix)"
	fi
fi
if [ -d "$MIDSHIP_TURBO_BROCCOLI_DIR" ] && ! (cd "$MIDSHIP_TURBO_BROCCOLI_DIR" && poetry run python -c '' >/dev/null 2>&1); then
	say "poetry install in midship-turbo-broccoli..."
	(cd "$MIDSHIP_TURBO_BROCCOLI_DIR" && poetry install) || say "WARNING: poetry install failed in midship-turbo-broccoli"
fi
if [ -d "$MIDSHIP_FRONTEND_DIR" ] && [ ! -d "$MIDSHIP_FRONTEND_DIR/node_modules" ]; then
	if command -v npm >/dev/null; then
		say "npm install in midship-frontend..."
		(cd "$MIDSHIP_FRONTEND_DIR" && npm install) || say "WARNING: npm install failed in midship-frontend"
	else
		say "WARNING: npm not found — skipping midship-frontend deps (install volta, then 'volta install node', then re-run)"
	fi
fi
if [ -d "$CASCADE/client" ] && [ ! -d "$CASCADE/client/node_modules" ]; then
	if command -v volta >/dev/null; then
		say "npm install in cascade/client (node from .nvmrc via volta)..."
		(cd "$CASCADE/client" && volta run --node "$(cat .nvmrc)" npm install) || say "WARNING: npm install failed in cascade/client"
	elif [ -s "$HOME/.nvm/nvm.sh" ]; then
		say "npm install in cascade/client (node from .nvmrc via nvm)..."
		(cd "$CASCADE/client" && bash -lc 'source ~/.nvm/nvm.sh && nvm install >/dev/null 2>&1 && nvm use >/dev/null && npm install') || say "WARNING: npm install failed in cascade/client"
	else
		say "WARNING: neither volta nor nvm found — skipping cascade/client deps (brew install volta, then re-run)"
	fi
fi

# --- 7. AB database seed (SQL dump import — DESTRUCTIVE, always confirmed) ---
# reset-db terminates active connections itself, so servers can stay up.
# Note workspace precedence is .dump > .sql.zip > .sql regardless of age; an
# explicitly entered path bypasses that via DATA_DUMP_FILE.
DEFAULT_DUMP=$(ls -1 "$DEVENV/workspace" 2>/dev/null | grep -E '\.dump$' | tail -n 1 || true)
[ -z "$DEFAULT_DUMP" ] && DEFAULT_DUMP=$(ls -1 "$DEVENV/workspace" 2>/dev/null | grep -E '\.sql(\.zip)?$' | tail -n 1 || true)
if [ -t 0 ]; then
	read -r -p "[onboard] AuditBoard: seed/reseed its database from a SQL dump? DROPS all local AB data — skip if unsure [y/N] " AB_SEED || true
	if [[ ! "${AB_SEED:-}" =~ ^[Yy]$ ]]; then
		say "AuditBoard seed skipped — later: re-run fleetcom-onboard.sh or: abc db reset"
	else
	while :; do
		read -e -r -p "[onboard] AuditBoard SQL dump to import — type a file path (tab-completion works), or Enter for the workspace default [${DEFAULT_DUMP:-none found}]: " DUMP_PATH || true
		DUMP_PATH="${DUMP_PATH/#\~/$HOME}"
		[ -z "$DUMP_PATH" ] && break
		if [ -f "$DUMP_PATH" ]; then
			# Keep a copy in the team-standard location. Do NOT rename: the
			# extension selects the import tool (.dump -> pg_restore, else psql).
			WS_COPY="$DEVENV/workspace/$(basename "$DUMP_PATH")"
			mkdir -p "$DEVENV/workspace"
			if [ ! -f "$WS_COPY" ]; then
				cp "$DUMP_PATH" "$WS_COPY"
				say "copied $(basename "$DUMP_PATH") into $DEVENV/workspace/"
				case "$DUMP_PATH" in *.dump) ;; *)
					say "note: workspace *default* resolution prefers .dump files over .sql — enter this path explicitly on future runs, or clear old .dump files from workspace/"
				;; esac
			fi
			DUMP_PATH="$WS_COPY"
			break
		fi
		say "not found: $DUMP_PATH — check for typos and try again, or press Enter to use the workspace default"
	done
	if [ -z "$DUMP_PATH" ] && [ -z "$DEFAULT_DUMP" ]; then
		say "no dump available — ask a teammate for the current platform dataset dump, then re-run fleetcom-onboard.sh or: abc db reset"
	else
		SEED_NAME=$([ -n "$DUMP_PATH" ] && basename "$DUMP_PATH" || echo "$DEFAULT_DUMP")
		read -r -p "[onboard] Type 'reset' to DROP the AuditBoard demo_data DB and import $SEED_NAME now (anything else skips): " CONFIRM || true
		if [ "$CONFIRM" = "reset" ]; then
			if [ -n "$DUMP_PATH" ]; then
				(cd "$DEVENV" && DATA_DUMP_FILE="$DUMP_PATH" direnv exec . abc db reset) || say "WARNING: abc db reset failed — see output above"
			else
				(cd "$DEVENV" && direnv exec . abc db reset) || say "WARNING: abc db reset failed — see output above"
			fi
			say "AB database seeded from $SEED_NAME (login: ops@soxhub.com / password)"
		else
			say "seed skipped — run later via fleetcom-onboard.sh or: abc db reset (see README 'Database seeding')"
		fi
	fi
	fi
elif [ -z "$DEFAULT_DUMP" ]; then
	say "WARNING: no SQL data dump in auditboard-dev-env/workspace/ and no TTY to prompt — ask a teammate for the current platform dataset dump, then run: abc db reset"
fi

# --- 8. Midship database seed (dev dump import — DESTRUCTIVE, confirmed) ----
# Midship's flow differs from AB's: dumps live in midship-turbo-broccoli/db/
# (gitignored), loaded by scripts/load_db_dump.py, which drops and recreates
# the local Docker Postgres DB. Dev dumps can carry the real dev DB password
# in a '\restrict' line — it is stripped during the copy below.
MTB="$MIDSHIP_TURBO_BROCCOLI_DIR"
if [ -d "$MTB" ] && [ -t 0 ]; then
	MS_DEFAULT=$(ls -1 "$MTB/db" 2>/dev/null | grep -E '^dev_dump_.*\.sql$' | tail -n 1 || true)
	read -r -p "[onboard] Midship: seed/reseed its database from a dev dump? DROPS all local Midship data — skip if unsure [y/N] " MS_SEED || true
	if [[ ! "${MS_SEED:-}" =~ ^[Yy]$ ]]; then
		say "Midship seed skipped — later: re-run fleetcom-onboard.sh"
	else
	while :; do
		read -e -r -p "[onboard] Midship dev dump to import — type a file path (tab-completion works), or Enter for the db/ default [${MS_DEFAULT:-none found}]: " MS_PATH || true
		MS_PATH="${MS_PATH/#\~/$HOME}"
		[ -z "$MS_PATH" ] && break
		if [ -f "$MS_PATH" ]; then
			MS_COPY="$MTB/db/$(basename "$MS_PATH")"
			mkdir -p "$MTB/db"
			# strip the \restrict password line while copying (never edit the original)
			sed '/^\\restrict/d' "$MS_PATH" > "$MS_COPY"
			say "copied $(basename "$MS_PATH") into $MTB/db/ (password \\restrict line stripped)"
			grep -qc '^\\restrict' "$MS_PATH" >/dev/null 2>&1 \
				&& say "note: the ORIGINAL at $MS_PATH still contains the dev DB password — consider deleting it"
			MS_DEFAULT="$(basename "$MS_COPY")"
			break
		fi
		say "not found: $MS_PATH — check for typos and try again, or press Enter to use the db/ default"
	done
	if [ -z "$MS_DEFAULT" ]; then
		say "no Midship dump available — generate one per midship-turbo-broccoli README ('Load a Full Dev Database Dump') or get one from a teammate"
	else
		read -r -p "[onboard] Type 'reset' to DROP the Midship DB and import $MS_DEFAULT now (anything else skips): " MS_CONFIRM || true
		if [ "$MS_CONFIRM" = "reset" ]; then
			if lsof -tiTCP:8000 -sTCP:LISTEN >/dev/null 2>&1; then
				say "stopping the Midship API on 8000 (load_db_dump.py can't drop the DB under active connections)"
				kill $(lsof -tiTCP:8000 -sTCP:LISTEN) 2>/dev/null || true
				sleep 2
			fi
			(cd "$MTB" && docker compose up -d postgres && poetry run python scripts/load_db_dump.py "db/$MS_DEFAULT")
			say "Midship DB seeded from $MS_DEFAULT — run ./fleetcom-start-all.sh to bring the API back"
		else
			say "Midship seed skipped — later: cd $MTB && poetry run python scripts/load_db_dump.py db/<dump>.sql"
		fi
	fi
	fi
fi

# --- 9. Midship Hatchet (workflow engine: dashboard 1337, gRPC 7077) --------
# 'hatchet server start' is idempotent: creates (or verifies) the hatchet-cli
# compose project (postgres + hatchet-lite) and a ~/.hatchet local profile.
if [ -d "$MIDSHIP_TURBO_BROCCOLI_DIR" ]; then
	if docker ps -aq --filter "name=hatchet-cli" 2>/dev/null | grep -q .; then
		say "hatchet containers exist (fleetcom-start-all restarts them when stopped)"
	elif [ -t 0 ]; then
		read -r -p "[onboard] Midship's Hatchet isn't set up — install the CLI (brew cask) and start the local server now? [Y/n] " HYN || true
		case "$HYN" in
			[Nn]*) say "skipped — Midship boots without it, but document-pipeline workers won't run (see README: Hatchet)" ;;
			*)
				if ! command -v hatchet >/dev/null; then
					say "installing hatchet CLI (from the hatchet-dev/hatchet tap)"
					brew tap hatchet-dev/hatchet >/dev/null 2>&1 || true
					brew trust hatchet-dev/hatchet >/dev/null 2>&1 || true  # newer brew requires trusting third-party taps
					brew install --cask hatchet-dev/hatchet/hatchet \
						|| die "hatchet install failed — try: brew tap hatchet-dev/hatchet && brew trust hatchet-dev/hatchet && brew install --cask hatchet-dev/hatchet/hatchet"
				fi
				say "starting local Hatchet server (postgres + hatchet-lite containers)"
				hatchet server start --dashboard-port 1337 || say "WARNING: hatchet server start failed — see output above"
			;;
		esac
	else
		say "WARNING: hatchet not set up and no TTY to prompt — run: brew install --cask hatchet && hatchet server start --dashboard-port 1337"
	fi
	# midship workers authenticate with HATCHET_CLIENT_TOKEN — copy it from the
	# CLI's local profile into midship's .env (never printed)
	if [ -f "$HOME/.hatchet/profiles.yaml" ] && [ -f "$MIDSHIP_TURBO_BROCCOLI_DIR/.env" ] && ! grep -q "^HATCHET_CLIENT_TOKEN=" "$MIDSHIP_TURBO_BROCCOLI_DIR/.env"; then
		HTOK=$(awk '/^    local:$/{f=1} f && /token:/{print $2; exit}' "$HOME/.hatchet/profiles.yaml" || true)
		if [ -n "$HTOK" ]; then
			printf '\n# FLEETCOM: local Hatchet server token (from ~/.hatchet/profiles.yaml)\nHATCHET_CLIENT_TOKEN=%s\n' "$HTOK" >> "$MIDSHIP_TURBO_BROCCOLI_DIR/.env"
			say "HATCHET_CLIENT_TOKEN appended to midship-turbo-broccoli/.env"
		fi
	fi
fi

# --- 10. put the `fleetcom` command on PATH (optional convenience) ----------
# Symlink FLEETCOM/fleetcom into Homebrew's bin (already on PATH and
# user-writable; every FLEETCOM machine has brew) so you can run
# `fleetcom start` from anywhere instead of `./fleetcom start`. Idempotent and
# non-destructive: never clobbers an existing non-FLEETCOM `fleetcom`.
FLEETCOM_BIN="$HERE/fleetcom"
LINK_DIR="$BREW_PREFIX/bin"
LINK="$LINK_DIR/fleetcom"
if [ -x "$FLEETCOM_BIN" ]; then
	if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$FLEETCOM_BIN" ]; then
		say "fleetcom command already on PATH -> $LINK"
	elif [ -e "$LINK" ]; then
		say "note: $LINK already exists and isn't FLEETCOM's symlink — leaving it alone (use ./fleetcom, or relink by hand)"
	elif [ ! -w "$LINK_DIR" ]; then
		say "note: to run 'fleetcom' from anywhere, symlink it onto your PATH: ln -s '$FLEETCOM_BIN' <a-dir-on-your-PATH>/fleetcom"
	elif [ -t 0 ]; then
		read -r -p "[onboard] Put the 'fleetcom' command on your PATH (symlink into $LINK_DIR)? [Y/n] " FYN || true
		case "$FYN" in
			[Nn]*) say "skipped — run ./fleetcom from the repo, or symlink later" ;;
			*)
				if ln -s "$FLEETCOM_BIN" "$LINK"; then
					say "linked: 'fleetcom' is now on your PATH (try: fleetcom help)"
				else
					say "WARNING: could not create $LINK"
				fi
			;;
		esac
	else
		say "note: no TTY to confirm — to add fleetcom to PATH: ln -s '$FLEETCOM_BIN' $LINK"
	fi
fi

say "done. Next: ./fleetcom start && ./fleetcom doctor  (or 'fleetcom …' if you linked it onto PATH) — see README.md"
