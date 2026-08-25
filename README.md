# FLEETCOM

Install and run the **Midship**, **Cascade**, and **AuditBoard** stacks side-by-side on one
Mac, with local SSO from AuditBoard into Cascade.

Midship's ports are treated as fixed; everything else is deconflicted around
them.

**Repo locations are configurable**: on first run, `fleetcom-onboard.sh` asks
for each repo's path, one at a time (Enter accepts the default —
`~/Development/<repo>`; tab-completion works). Answers persist to a gitignored
`local.conf` that every script reads; change them later by re-running
`./fleetcom-onboard.sh --reconfigure` or hand-editing `local.conf`. **Repos
you don't have yet are offered for cloning** (from the `soxhub` org via `gh`)
into whatever paths you chose — or point the offer at an existing checkout.
The default layout:

```
~/Development/midship-turbo-broccoli  # MIDSHIP_TURBO_BROCCOLI_DIR
~/Development/midship-frontend        # MIDSHIP_FRONTEND_DIR
~/Development/midship-onyx            # MIDSHIP_ONYX_DIR (source reference only)
~/Development/cascade                 # CASCADE_DIR
~/Development/auditboard-backend      # AB_BACKEND_DIR
~/Development/auditboard-frontend     # AB_FRONTEND_DIR
~/Development/auditboard-dev-env      # AB_DEVENV_DIR (machine-learning stays nested inside)
```

midship-onyx is cloned for source reference only — see the runtime note below.

Two repos are special at runtime: **machine-learning** is auto-cloned into
`auditboard-dev-env/` by `start-background` itself and its services start on
every AB boot (ML local :8004, global :8001). **midship-onyx** (the Collabora
fork) runs locally as the prebuilt `docviewer` ECR image via
midship-turbo-broccoli's compose (:9980) — the checkout is for source
reference/branding work; don't build it from source on macOS.

Dependency setup is automatic: `fleetcom-onboard.sh` runs `./refresh.sh`
(auditboard-frontend), `poetry install` (midship-turbo-broccoli), and
`npm install` (midship-frontend, cascade/client) whenever they're missing —
first run takes a while. For auditboard-frontend it also detects a broken
pnpm store link left by an interrupted install (existence of `node_modules`
alone doesn't mean it's intact) and re-runs `./refresh.sh` to repair it. It
also offers to regenerate a stale `auditboard-dev-env/.envrc` (backup kept,
FLEETCOM settings re-applied). **Midship's Hatchet (workflow engine, ports 1337/7077) is
handled by `fleetcom-onboard.sh`** — it offers to install the hatchet CLI
(brew cask), starts the local server (`hatchet server start --dashboard-port
1337`), and copies the worker token into midship-turbo-broccoli's `.env`.

## Recommended start

New to this, or setup went sideways? Two commands — and the second one puts
Claude right next to your logs to help you fix whatever broke:

```bash
./fleetcom onboard    # one-time, idempotent setup (repos, ports, SSO, deps)
./fleetcom claude     # full restart + a Claude Code pane beside the live logs
```

`fleetcom claude` bounces the whole stack clean and opens Claude Code alongside
the log streams and the live doctor report, with the `fleetcom-doctor`
self-heal playbook auto-loaded — so if a port won't come up or a service
crashes on boot, Claude can read the panes and walk you through the fix.
Requires the `claude` CLI and tmux (`brew install tmux`). Prefer to just boot
the stack without Claude? Use `./fleetcom start` — see **Commands** below.

## Prefer separate Terminal windows? (no tmux)

```bash
./fleetcom start --windows
```

Same boot, but the five log streams (optro-api, midship-api, cascade, alerts,
doctor) open as separate Terminal windows instead of the tmux grid, for that
run only (`./fleetcom restart --windows` works the same way). To make windows
the saved default for every plain `./fleetcom start`, run
`./fleetcom logs --windows` once; it persists `LOGS_VIEW` in `local.conf`, and
`./fleetcom logs --tmux` switches back. Details in **Watching logs** below.
The one exception is `./fleetcom claude`: it forces the tmux layout whenever
tmux is installed (the Claude pane needs it), and only without tmux does it
fall back to separate log windows, with Claude launched in your current
terminal reading the log files.

## Commands

Everything runs through one command — `./fleetcom <command>` — with built-in
man-style help (`./fleetcom help`, and `./fleetcom <command> --help`):

```bash
./fleetcom onboard        # one-time, idempotent — applies all port/SSO config
                          # first time? seed the AB database too — see "Database seeding"
./fleetcom onboard --reconfigure   # change repo locations later
./fleetcom start          # boots everything in dependency order (skips what's already up)
./fleetcom doctor         # port + health report
./fleetcom logs           # live backend log panes + error alerts (auto-opens after start)
./fleetcom restart        # full bounce of all three stacks
./fleetcom stop           # stops all three stacks + tears down the log view
./fleetcom claude         # full restart + a Claude Code pane beside the logs (see below)
./fleetcom help           # man-style overview of every command
```

Each subcommand maps to a `fleetcom-<name>.sh` script that still works when run
directly — e.g. `./fleetcom doctor` is exactly `./fleetcom-doctor.sh`. The
`fleetcom` wrapper is just the friendly front door (and where `--help` lives);
the scripts remain the implementation and call each other by name.

`fleetcom-onboard.sh` offers to symlink `fleetcom` into Homebrew's `bin` (on
your PATH), so after onboarding you can drop the `./` and run `fleetcom start`
from anywhere. Until then, use `./fleetcom <command>` from the repo.

Then log into AuditBoard at **https://localhost:9002** (`ops@soxhub.com` /
`password`) and test SSO into Cascade via
**https://localhost:9002/sh/auditboardanalytics/auth** → should land on
**http://127.0.0.1:8088** authenticated. Use **Chrome** — Safari refuses the
`secure` cookie Cascade sets on plain-http 127.0.0.1.

## Watching logs

`fleetcom start` ends by opening the five log streams — the first run
asks whether you prefer a **tmux** session (one window, tiled grid) or
**separate Terminal windows**; the answer persists in `local.conf`
(`LOGS_VIEW`) and can be switched anytime with `fleetcom logs --tmux` /
`--windows`. To pick the view for a single run without changing the saved
default, pass `--tmux` / `--windows` straight to `fleetcom start` (or
`fleetcom restart`). Reopen with `fleetcom logs`; skip the auto-open with
`fleetcom start --no-logs`. The streams:

| | |
|---|---|
| **optro-api** — AB backend (`logs/ab-api.log`) | **midship-api** (`logs/midship-api.log`) |
| **cascade** — docker logs (web/ws/c3) | **alerts** — ERROR/WARN merged from all three |
| **doctor** — live `fleetcom-doctor.sh`, refreshed every 10s | |

The **doctor** stream re-runs the port/health report on a loop so you watch
services flip ✓/✗ as they come up and down (a pass takes ~10s, so it repaints
roughly every 20s). It deliberately does NOT use `watch` even when installed:
watch draws on the alternate screen, which clips a report taller than the
pane, breaks tmux mouse scrolling, and only repaints changed cells, so the
pane looks frozen. Like the others, it's torn down by `fleetcom-stop-all.sh`.

tmux basics: `Ctrl-b d` detaches (servers keep running), `./fleetcom-logs.sh`
reattaches, `./fleetcom-logs.sh --kill` closes the panes; mouse scrolling is
enabled; `fleetcom-stop-all.sh` closes the session automatically. Windows
mode: each stream opens as an Apple Terminal window (generated
`logs/win-*.command` files — double-click to re-open one); closing a window
stops its tail. Windows mode is also the fallback when tmux isn't installed —
asking for a tmux view (`--tmux`, or `fleetcom claude`) first offers to
`brew install tmux`, and only falls back to windows if you decline. The client logs (`ab-client.log`, `midship-frontend.log`,
`cascade-client.log`) also live in `FLEETCOM/logs/` for manual tailing.
Ctrl-C in any pane stops that stream and drops you into a shell already `cd`'d
into that stack's repo (optro-api → auditboard-backend, midship-api →
midship-turbo-broccoli, cascade → cascade, alerts → FLEETCOM); `exit` closes
the pane.

## Debugging with Claude beside the logs

`./fleetcom claude` (aka `./fleetcom-start-claude.sh`) does a full restart
(`stop` then `start`) and then adds a **Claude Code pane** to the tmux log
window — Claude on the left (~70% width), the log streams tiled in a strip on
the right, all in one window. It writes `logs/tmux-panes.md` (a map of which pane shows what) and
launches Claude pointed at it, so Claude reads log output **on demand** with
`tmux capture-pane` rather than tailing continuously (which would bloat its
context). Pair it with the `fleetcom-doctor` skill — that Claude session, run
inside this repo, auto-loads the skill's diagnose-and-self-heal playbook.

- Requires the **`claude` CLI** on `PATH`. **tmux** is preferred (it's what
  tiles Claude beside the panes); if it's missing you're offered a
  `brew install tmux`, and declining falls back to a plain restart with the
  logs in **separate Terminal windows** and Claude launched in the current
  terminal (reading the log files on demand instead of tmux panes).
- With tmux, always uses the tmux log view for this run (it needs a pane for
  Claude); your saved `LOGS_VIEW` in `local.conf` is left untouched.
- `--no-restart` skips the stop/start and just adds the Claude pane to a
  running (or freshly built) log session — use it when the stack is already up.
- **Run it from a separate terminal window**, not from inside the
  `fleetcom-logs` tmux session — the restart tears that session down, and the
  script refuses to run from within it.

## Using your own start commands (start-all is optional)

Onboarding changes *machine state* — ports, env files, secrets, dependencies —
not how you launch things. After `fleetcom-onboard.sh` you can run every stack
the way its own README describes, and `fleetcom-doctor.sh` / `fleetcom-logs.sh`
/ `fleetcom-stop-all.sh` still work (they operate on ports and containers, not
on how services were started). Two caveats:

- **Conductor (AB)**: native `abc run start-background` starts it on **8080**,
  which collides with Midship's WOPI and mismatches `.envrc`'s
  `CONDUCTOR_SERVER_URL` (18080). Native-compatible form:
  `abc run start-background -- -s conductor`, then
  `docker compose -f docker-compose-supplement-dev.yml -f ../FLEETCOM/devenv.override.yml up -d conductor`.
- **Cascade's server image**: the compose override pins locally-built
  `local_test_web:latest`, so build it once
  (`docker-compose -f docker-compose.yml -f docker-compose-build.yml build`)
  before a purely native `docker-compose up`. The port overrides themselves
  need nothing special — plain `docker-compose up` auto-loads
  `docker-compose.override.yml`.

Also fine to mix: e.g. run the AB API in your own terminal (better turbo TUI
experience) while FLEETCOM manages everything else — the log pane will note
that its output isn't captured.

## Database seeding

Two stacks have dump-based seeding, with **different conventions** — don't mix
the files up:

| | AuditBoard | Midship |
|---|---|---|
| Dump location | `<auditboard-dev-env>/workspace/` | `<midship>/midship-turbo-broccoli/db/` |
| File types | `.dump` (pg_restore) / `.sql` (psql) | plain `.sql` (`dev_dump_YYYY_MM_DD.sql`) |
| Import command | `abc db reset` | `poetry run python scripts/load_db_dump.py db/<file>` |
| Target DB | native Postgres :5433 (`demo_data`) | Docker Postgres :5432 |
| ⚠ Gotcha | `.dump` beats `.sql` in default resolution | dumps may embed the dev DB password in a `\restrict` line — strip it |

`fleetcom-onboard.sh` prompts for both, each gated by an up-front
`seed/reseed? [y/N]` question (default **No** — pressing Enter skips the whole
thing safely). Answering yes gets a dump-path prompt (tab-completion, retry on
typos, workspace/db default) and a final type-`reset` confirmation before the
destructive import. Midship `\restrict` password-stripping is automatic. The
import is a **one-time seed / occasional refresh** — daily boots only run
migrations on top.

### AuditBoard details

The AB demo data comes from a **SQL data dump imported once** — it is *not*
part of the daily boot. Regular starts (`fleetcom-start-all.sh` → `bin/start-api`) only
run migrations on top of whatever is already in the database.

- `fleetcom-onboard.sh` handles this: it prompts for a dump path (e.g. one you
  downloaded to `~/Downloads`), defaulting to what's in
  `<auditboard-dev-env>/workspace/`. A mistyped path re-prompts (Enter falls
  back to the default); a valid path is copied into `workspace/` for future
  use. It then asks you to type `reset` before importing — because the import
  is **destructive**: it drops and replaces the whole `demo_data` DB,
  including any local AB state. Seed login afterwards: `ops@soxhub.com` /
  `password`. Keep the file's original extension — it selects the import tool
  (`.dump` → `pg_restore`, `.sql` → `psql`); renaming a `.sql` to `.dump`
  breaks the import.
- Workspace precedence (when several dumps exist): the alphabetically-last
  `.dump` wins over `.sql.zip` over `.sql`, regardless of age — an explicitly
  entered path bypasses this. No dump anywhere? Ask a teammate for the current
  platform dataset — without one, `reset-db` falls back to a minimal empty seed.
- Manual alternative: `abc db reset` from `auditboard-dev-env`
  (`DATA_DUMP_FILE=/path/to/dump.sql` to pick a specific file).
- When to run: first-time setup, or whenever you want to refresh to the
  canonical dataset. Cascade's DB is separate and unaffected — it seeds via
  its own `migrate` + `bootstrap`, and SSO users auto-provision on first login.

### Midship details

- Dumps come from the dev RDS instance (see midship-turbo-broccoli README →
  "Load a Full Dev Database Dump" for the bastion/pg_dump recipe) and are
  named `dev_dump_YYYY_MM_DD.sql`. They're gitignored in `db/` — real data,
  ~30-40MB.
- **Security**: fresh dumps can contain the dev DB password in a `\restrict`
  line. `fleetcom-onboard.sh` strips it while copying into `db/`; if you handle a dump
  manually, run `sed -i '' '/^\\restrict/d' <file>` first and delete the
  unsanitized original.
- The import (`scripts/load_db_dump.py`) drops the DB and can't do so under
  active connections — `fleetcom-onboard.sh` stops the Midship API first; bring it back
  afterwards with `./fleetcom-start-all.sh`.

## Automations / Analytics (Cascade) in AuditBoard

The AB Automations module (workspace → Automations) is powered by Cascade plus
the `integrations-extract` side service. FLEETCOM handles the plumbing:

- `fleetcom-onboard.sh` backfills the credential-encryption keys into
  `.envrc` when it predates the key rotation (see Troubleshooting: "Invalid
  key length"), and sets `EXTRACT_HOST` in `cascade/.env` so Cascade can reach
  integrations-extract.
- `fleetcom-start-all.sh` already boots in the required order — extract (with
  the AB background services) **before** Cascade — so Cascade's manager can
  initialize its ExtractClient. After onboard adds `EXTRACT_HOST`, the next
  start-all recreates Cascade's containers with it automatically.

**One-time manual step — app state, not env config**: log into AB → Settings →
Site Configuration → **Features** (Superuser group) → scroll to the
**Automation** heading → enable **Analytics** (the older Coda guide says
Insider Access → "Auditboard Analytics"; that toggle has moved to Features).
This lives in the AB *database*, so re-check it after every `demo_data` reseed
(dumps may or may not include it). It cannot be scripted safely from outside
the app.

**Optional — Merge.dev connectors** (Paylocity etc.): `MERGE_API_KEY`
(1Password) in `.envrc`, plus LaunchDarkly flags `merge-dev-integrations`,
`integrations-extract-service-enabled`, and `show-all-integrations` — served
locally by LaunchDevly (:8765). Extract's API docs: `localhost:3001/docs`.

## Port map

| Stack | Service | Port | Notes |
|---|---|---|---|
| Midship | Vite frontend | 5173 | fixed |
| Midship | FastAPI API | 8000 | fixed |
| Midship | Forge API | 8003 | fixed, situational |
| Midship | WOPI | 8080 | fixed (Docker) |
| Midship | Collabora/Onyx | 9980 | fixed (Docker) |
| Midship | Postgres | 5432 | fixed (Docker) |
| Midship | Redis | 6379 | fixed (Docker) |
| Midship | Hatchet | 1337, 7077 | fixed (Docker) — set up separately per midship-turbo-broccoli README; FLEETCOM restarts existing containers but cannot create them |
| Midship | debugpy (opt-in) | 5678–5681, 8090 | fixed |
| AuditBoard | API v1 (Hapi) | 9001 | unchanged — Cascade hardcodes it |
| AuditBoard | Caddy HTTPS entry | 9002 | unchanged |
| AuditBoard | API v2 (Hono) + metrics | 9003, 9004 | unchanged |
| AuditBoard | login app / client Vite | 9005 / 9006 | unchanged |
| AuditBoard | **native Postgres** | **5433** | moved off 5432 (`postgresql.conf`) |
| AuditBoard | **native Redis** | **6382** | moved off 6379; 6380/6381 belong to ML redisearch |
| AuditBoard | **Conductor API** | **18080** | moved off 8080 (`devenv.override.yml`); UI stays 3000 |
| AuditBoard | **ML local service** | **8004** | moved off 8000 (`machine-learning/docker-compose.override.yml`) |
| AuditBoard | ML global / redisearch | 8001, 6380, 6381 | unchanged ML defaults |
| AuditBoard | minio, poxa, launchdevly, … | 9000/10000, 3008, 8765, 3020, 3022, 5001, 3100, 80/443, 4040, 8050, 8081–8083, 9092/9101, 9008/9009, 3001 | unchanged |
| Cascade | Django API / Daphne WS | 8010 / 8011 | unchanged — hardcoded in client `host.ts` |
| Cascade | Parcel client | 8088 | unchanged — hardcoded |
| Cascade | Postgres / MinIO | 33060 / 6010, 6011 | unchanged |
| Cascade | **Redis host publish** | **63790** | moved off 6379 (`docker-compose.override.yml`) |
| Cascade | **debugpy** | **15678–15682** | moved off 5678–5682; update attach configs |

## Where the configuration lives

| File | What | Committed? |
|---|---|---|
| `/opt/homebrew/var/postgresql@17/postgresql.conf` | `port = 5433` | system config |
| `/opt/homebrew/etc/redis.conf` | `port 6382` | system config |
| `auditboard-dev-env/.envrc` (tail block) | `DATABASE_URL`, `REDIS_URL`, `DOCKER_REDIS_URL`, `PERMISSIONS_DATABASE_URL`, `CONDUCTOR_SERVER_URL`, `AB_MLSERVICE_LOCAL_SERVICE_PORT`, `CASCADE_JWT_SECRET` | no (gitignored/generated) — **re-run `fleetcom-onboard.sh` after `bin/generate-config`** |
| `cascade/docker-compose.override.yml` | redis + debugpy remaps | no (`.git/info/exclude`) |
| `auditboard-dev-env/machine-learning/docker-compose.override.yml` | ML local → 8004 | ⚠ tracked file, shows as locally modified — re-apply after pulls (fleetcom-onboard.sh does) |
| `cascade/.env` (tail block) | `JWT_AUTH_SHARED_SECRET`, `JWT_AUTH_ISSUER`, `AB_DOMAINS`, `AB_LOGIN_URL`, `LAUNCH_DARKLY_SDK_KEY`, `LAUNCH_DARKLY_CLIENT_ID` (prompted by fleetcom-onboard.sh, get from 1Password > QE Team Vault > Cascade base env file) | no (gitignored) |
| `FLEETCOM/local.conf` | per-machine repo paths (from fleetcom-onboard.sh prompts) | no (gitignored) |
| `FLEETCOM/devenv.override.yml` | Conductor → 18080; integrations-extract `NODE_OPTIONS=--max-old-space-size=8192` | yes (this repo) |
| Docker Desktop `settings-store.json` | Memory ≥ 12GB, disk ≥ 120GB (fleetcom-onboard.sh offers to apply; needs Docker restart) | system config |

## SSO in one paragraph

AuditBoard's `/api/v1/analytics/auth` signs an HS256 JWT with
`CASCADE_JWT_SECRET` and redirects to Cascade's `/auth/jwt`. Cascade verifies
it with `JWT_AUTH_SHARED_SECRET` (same value), issuer `auditboard`, audience
`http://127.0.0.1:8010/api/` (the default on both sides — do **not** set
`CASCADE_API_URL`/`CASCADE_APP_URL`, and keep `ENV_NAME=local`). Users are
auto-provisioned on first login; no Cascade seeding required.

## Troubleshooting

### `fleetcom onboard`: PermissionError on Docker's settings-store.json

**Symptoms**: on a fresh machine, `./fleetcom onboard` prints a raw Python
traceback ending in `PermissionError: [Errno 1] Operation not permitted:
'/Users/<you>/Library/Group Containers/group.com.docker/settings-store.json'`,
immediately followed by `[onboard] Docker Desktop is below 12288MiB memory /
122880MiB disk`. Answering `y` to the restart prompt quits Docker Desktop,
throws the same traceback again, and brings Docker back with nothing changed.

**Cause**: macOS **TCC** (privacy protection), *not* file permissions.
`~/Library/Group Containers` is `drwx------` and TCC-protected, so a terminal
without **Full Disk Access** gets `EPERM` opening anything inside it — even
though `settings-store.json` is itself world-readable (`-rw-r--r--`). This is
why it works on one machine and not another: the difference is whether that
terminal app was ever granted Full Disk Access.

Note the "below 12288MiB" line is a **false report** — onboard could not read
the file, so it never saw your actual values. (Onboard now separates
"unreadable" from "under-provisioned"; on an older checkout you will still see
the misleading version.)

**Fix**: grant your terminal Full Disk Access — System Settings > Privacy &
Security > Full Disk Access > **+** > your terminal app (Terminal, iTerm,
Ghostty, …) — then **fully quit and reopen the terminal**. A new tab or window
is not enough; the grant is picked up when the app launches. Then re-run.

Prefer not to grant it? Skip the automation entirely and set the two values by
hand in Docker Desktop > Settings > Resources: **Memory >= 12GB**, **Disk >=
120GB**, then Apply & Restart. That is the only thing the check was doing.

Either way, check those two values yourself — the warning that sent you here
was not based on having read them.

### AB app stalls at "Loading appears to be stalled" / blank login page

**Symptoms**: `https://localhost:9002` never finishes booting (or the login
page renders only the logo). DevTools console shows `api/v1/config` → **400**,
often followed by `Cannot read properties of undefined (reading
'session.termination.browserClosed')` and a failed Vite HMR websocket.

**Cause**: the `g_state` cookie that **Midship's own Google Sign-In** plants on
`localhost` (GIS One-Tap state, a JSON blob; see midship-frontend
`SignIn.tsx`). Cookies ignore ports, so signing into Midship at `:5173` puts
it on every localhost app — and Hapi's strict cookie parsing 400s **every**
AB API request over one bad cookie: `{"message":"Invalid cookie value"}`.
AB-only developers never see this; it's inherent to running Midship + AB in
one browser profile.

**Fix**: on the `localhost:9002` tab, run this in the DevTools console, then
reload:

```js
['g_state', 'intercom-device-id-m7mk7nxe'].forEach(n => {
  document.cookie = `${n}=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/`;
  document.cookie = `${n}=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/; domain=localhost`;
});
```

Don't "Clear all site data" — localhost cookies are shared across ports, so a
full wipe also logs you out of Midship (5173) and drops Cascade's SSO cookie
(8088). This recurs whenever another localhost project re-plants the cookie; a
dedicated browser profile for AB work avoids it entirely. (Root-cause fix
belongs in auditboard-backend: Hapi `state.failAction: 'log'` — mention it in
#eng-dx.)

### AB API v2 serves stale code after editing backend files (EADDRINUSE :9004)

**Symptoms**: you edit `auditboard-backend`, packages rebuild, but changes
don't take effect on `/api/v2/*`; the alerts pane / `logs/ab-api.log` shows
`Error: listen EADDRINUSE: address already in use :::9004`.

**Cause**: turbo watch only kills the old `api:v2` process on rebuild-restart
when the API has a **controlling terminal**. FLEETCOM originally launched it
detached (`nohup`), so the old process leaked, the rebuilt v2 lost the port
race and died, and the stale process kept serving pre-edit code. (Verified by
A/B experiment: identical edits restart cleanly under a pty, leak without one.)

**Fix (already in place)**: `fleetcom-start-all.sh` runs the API inside a
detached tmux session (`fleetcom-ab-api`), which provides the pty — restarts
are clean. `tmux attach -t fleetcom-ab-api` shows the raw process if you ever
want it. If you see this error anyway, the API was probably started by hand
with `nohup`/backgrounding — bounce it: kill whatever holds 9001/9003 and
re-run `./fleetcom-start-all.sh`.

### AB API (9001/9003) crash-loops on @soxhub/consts: "does not provide an export named 'default'"

**Symptoms**: 9001/9003 never come up — doctor keeps reporting them NOT
LISTENING while `logs/ab-api.log` (and the alerts pane) repeats a module error
along the lines of `The requested module '@soxhub/consts' does not provide an
export named 'default'`. Rebuilding by hand appears to fix it, and then the
next `bin/start-api` brings it straight back.

**Cause**: turbo has a **bad cached build artifact** for `utils/core`
(`@soxhub/utils-core`). `bin/start-api` builds workspace dependencies through
turbo on every start, so each start restores that poisoned artifact from cache
— silently undoing the rebuild you just did. That's the trap: the plain
rebuild really does fix the running process, so it looks solved, and the fix
is reverted the next time you boot rather than at the moment you look.

**Fix**: force a cache-bypassing rebuild of the poisoned package, from
**auditboard-backend** (not the frontend repo — `@soxhub/utils-core` is a
backend workspace, `utils/core/`):

```bash
cd "$AB_BACKEND_DIR" && pnpm ab turbo _:build --filter=@soxhub/utils-core --force
```

`--force` is the load-bearing part — without it turbo hands back the same bad
artifact from cache and nothing changes. Then restart the API (`./fleetcom
restart`, or just the AB stack). Because the symptom is a crash-loop on
startup, the AB API ports staying NOT LISTENING across a restart — with the
module error in the log rather than a port conflict — is what distinguishes
this from the stale-code/EADDRINUSE case above.

### Workflows page is empty / shows "Install and configure services from the new Integrations module"

The Analytics service isn't enabled for this AB site. Enable it in the app:
Settings → Site Configuration → **Features** (Superuser group) → **Automation**
heading → enable **Analytics** (details in the "Automations / Analytics"
section above; older docs point at Insider Access — the toggle moved). This is stored in the AB database — it can silently disappear
after a `demo_data` reseed, so re-check it there first whenever the
Automations module looks unconfigured.

### Automations page: "an error occurred while decrypting: RangeError: Invalid key length"

**Cause**: your generated `.envrc` predates the credential-encryption key
rotation (SOX-88587) and lacks `SHARED_EXTERNAL_ENCRYPTION_KEY` /
`EXTERNAL_SECRET_ENCRYPTION_KEY` — the backend decrypts stored automation
credentials with an empty key. **Fix**: re-run `./fleetcom-onboard.sh` (it
backfills both from `bin/generate-config`), then restart the AB API and
recreate `integrations-extract` so both pick up the keys. If a *different*
decrypt error appears afterwards ("bad decrypt"), the seeded credentials were
encrypted with a non-standard key — delete those automation-credential rows
and recreate them in the UI.

### doctor shows Hatchet (1337 / 7077) NOT LISTENING

Hatchet is Midship's self-hosted workflow engine (compose project
`hatchet-cli`). Re-run `./fleetcom-onboard.sh` — it installs the hatchet CLI,
starts the local server on the right ports, and copies the worker token into
midship's `.env`. Midship boots fine without it, but the document-processing
pipeline (Hatchet workers) won't run until it's up.

### doctor shows Hatchet workers NOT RUNNING / document uploads hang or 500

The Hatchet server (1337/7077) is only the queue — the API dispatches
document-processing workflows onto it, but a separate worker process
(`midship-turbo-broccoli/scripts/run-workers.sh`, three subprocesses:
document/procedure/screenshot) has to actually consume them.
`fleetcom-start-all.sh` launches this automatically -> `logs/midship-workers.log`.
If it's still not running: `cd midship-turbo-broccoli && ENV=local_db bash
scripts/run-workers.sh`. Without it, uploads either dispatch fine and then sit
queued forever with no visible error (nothing ever parses the document), or —
if the Hatchet client token in `.env` is *also* stale (see above; regenerates
whenever the Hatchet containers are recreated, e.g. after a Docker outage) —
fail immediately with `grpc_status:16 invalid auth token` on upload.

### start-background: "failed to set up container networking: network … not found"

Stopped containers are pinned to a Docker network that no longer exists
(network churn from Docker restarts, prunes, or a partial `compose down`).
`fleetcom-start-all.sh` detects this and self-heals (force-recreates the
supplement containers on the live network, then retries). Manual fix, from
`auditboard-dev-env`: `direnv exec . docker compose -f
docker-compose-supplement-dev.yml -f ../FLEETCOM/devenv.override.yml -f
../FLEETCOM/extract.override.yml up -d --force-recreate`. (Historical cause:
fleetcom-stop-all used `down` for conductor/extract, which removed the shared
network once everything else was stopped — fixed to `stop`.)

### AB Caddy (9002) and client Vite (9006) both go down together

**Symptoms**: `fleetcom-doctor.sh` shows both 9002 (Caddy HTTPS entrypoint)
and 9006 (client Vite) as `NOT LISTENING` at the same time, even though only
one thing actually broke.

**Cause**: auditboard-frontend's dev orchestrator
(`tools/monorepo/src/tasks/dev.ts`, driven by `pnpm start` → `ope dev`) runs
Caddy (9002), the login app (9005), and the client (9006) as **one turbo
process group** (`_:start`, persistent) — a crash in any one of them takes the
whole group down together. A common trigger: the login app hitting an
`ENOENT` lstat crash from a corrupted pnpm store under `node_modules/.pnpm`.
Caddy also proxies all three under `https://localhost:9002`
(`tools/caddy/src/Caddyfile`), so a login-app-only crash reads as "the whole
AB frontend is down."

**Fix**: check `logs/ab-client.log` for the actual crash, not just the ports.
If it's an `ENOENT` under `node_modules/.pnpm`, that's the pnpm store
corruption `fleetcom-onboard.sh` now detects and repairs automatically (see
"Dependency setup is automatic" above) — `cd auditboard-frontend &&
./refresh.sh`, then re-run `./fleetcom-start-all.sh`.

## Known edge cases
- **Cascade client crashes with LaunchDarklyFlagFetchError and lands on /404
  after SSO**: `LAUNCH_DARKLY_SDK_KEY` / `LAUNCH_DARKLY_CLIENT_ID` are missing
  from `cascade/.env` (get them from 1Password > QE Team Vault > Cascade base
  env file, then recreate the web containers and restart Parcel — or just
  re-run `fleetcom-onboard.sh`, which prompts for them). The SSO/JWT auth itself works
  without them. If they're already present but the browser console shows
  `Unhandled Rejection (LaunchDarklyFlagFetchError): Error fetching flag
  settings: 401` instead, the values are present but **wrong** — most often
  the SDK key and client ID got swapped when entered, or a stale/rotated
  1Password value. `fleetcom-onboard.sh` now pings LaunchDarkly's real API
  with whatever's in `cascade/.env` and warns on a 401, but re-running
  onboarding alone won't fix a wrong value that's already non-empty — hand-edit
  `cascade/.env` with fresh values, then **recreate** (not just restart) the
  `web`/`ws` containers (`docker-compose up -d --force-recreate web ws`):
  these env vars are baked in at container creation, not read live.

- Cascade Playwright E2E starts a wiremock on host 9001 → collides with the AB
  API. Only matters when running Cascade E2E; stop the AB API first or remap
  wiremock for that run.
- `AB_MINIO_REVERSE_PROXY` (Cascade) proxies to `localhost:9000`, which is
  AuditBoard's MinIO — leave it unset locally.
- Cascade→AB reverse calls (Automations) 401 out of the box: Cascade sends JWT
  audience `http://localhost:9001` but AB expects `v1.soxhub.url`
  (`https://localhost`). Export `BASE_URL=http://localhost:9001` in the
  `.envrc` block if you need Automations; verify login redirects still work.
- `machine-learning/.envrc` comes from AWS Secrets Manager (`bin/setup_envrc`)
  and pins `REDIS_SERVICE_PORT=6380` — that's the ML redisearch container, not
  the AB Redis (6382). Don't "fix" it.
- Midship's opt-in debuggers (5678–5681) stay free because Cascade's debugpy
  moved to 15678+. Cascade `.claude/launch.json` attach configs still mention
  5678 — attach to 15678 instead.
