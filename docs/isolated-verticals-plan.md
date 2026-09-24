# Plan: isolated concurrent verticals on one Mac

Status: plan only, nothing implemented. Written 2026-09-23.

Goal: run two or more complete Midship stacks at the same time (frontend, API,
Forge, Hatchet workers, Hatchet server, database, Redis), each wired through
Optro/AuditBoard and Cascade, so that restarting, migrating or breaking one
never affects another.

Two plans:

- **Plan B: Midship only.** Changes land in midship-frontend,
  midship-turbo-broccoli and FLEETCOM, plus local gitignored override files.
  AuditBoard/Optro and Cascade stay one shared instance. This is the plan that
  can be executed today.
- **Plan A: full vertical.** Plan B plus changes in auditboard-backend,
  auditboard-dev-env and cascade, so each instance also gets its own
  AuditBoard and Cascade. It needs agreement from the teams owning those repos.

Container runtime: none of this depends on Docker vs Podman. On macOS both run a
Linux VM that publishes ports to host `localhost`. The blockers are processes
running on the host, hardcoded ports, and shared state. Evaluating the runtime
itself belongs to DEVTOOLS-187.

---

## What already exists (checked 2026-09-23)

Look up current state with `gh pr view <n> --repo soxhub/<repo>`.

| Repo / item | What it does | Relevance |
|---|---|---|
| midship-frontend #497 | Each worktree gets a slot in `~/.config/midship-dev/slots.json`. Ports shift by 5 × slot (FE 5173, API 8000, Forge FE 3434, Forge BE 8003). `.claude/scripts/setup_worktree.py:36`, `transform()` at `:307-323` | Base port allocator for both plans |
| midship-frontend #504 | Pairs a frontend worktree with a same-branch midship-turbo-broccoli worktree, symlinks `.env*`, installs dependencies | Reused as is |
| midship-frontend #506, #507, #511 | Settings symlink; dev servers outlive the Claude session; dev servers stop with their stack via per-stack pgid files (`dev-server.sh:58-98`); a preview never kills another process to take its port | The pgid mechanism is the model for FLEETCOM's process handling |
| midship-frontend #606 (open) | Honors a typed `http://` for a localhost Optro URL | Needed for local Optro sign-in (see Risks) |
| midship-turbo-broccoli #1458 | `DB_NAME` configurable (RDS code path) | Local path already has `LOCAL_DB_NAME` |
| midship-turbo-broccoli #1436 | Hatchet dev file watcher ignores Claude Code worktrees | Reused |
| auditboard-frontend #34273, #35597 | Vite and caddy pick free ports per worktree; `PORT_API_V1`/`PORT_API_V2` honored | Plan A: the AuditBoard frontend side is already done |
| ab-cli #191, #194 (open), DEVTOOLS-915 | `abc env` / `abc worktree`. DEVTOOLS-915 deliberately **dropped** per-worktree port/DB offsets in favour of a future "role-aware" model | Plan A works against this stated direction; talk to the DX team first |
| FLEETCOM uncommitted work in the main checkout | Hardens the single shared Midship stack: pins `-p midship-turbo-broccoli`, runs migrations on boot, adds Cascade→MinIO forwarders, orders the Hatchet stop | Touches the same files as Plan B's FLEETCOM work. Commit or merge it first |

No PR in any repo isolates the Midship database, Redis or Hatchet per stack.
PR #497 documents sharing them as deliberate for now.

---

## Design decisions (both plans)

**Instance 0 stays exactly as today.** It keeps the compose project
`midship-turbo-broccoli`, database `postgres`, ports 5173/8000, and the shared
database chosen on 2026-09-23 so that switching worktrees never lands on an
empty, unmigrated database. Isolation is opt-in for instances ≥ 1.

**One port allocator.** `slots.json` from midship-frontend is the source of
truth, and FLEETCOM reads it rather than keeping a second registry. Instance n = slot n.

| Group | Ports for instance n | n = 1 |
|---|---|---|
| Midship host processes | FE 5173+5n, API 8000+5n, Forge FE 3434+5n, Forge BE 8003+5n (existing scheme) | 5178, 8005, 3439, 8008 |
| Midship Redis (container) | 6379+100n | 6479 |
| Hatchet server (container) | dashboard 1337+100n, gRPC 7077+100n | 1437, 7177 |
| WOPI / Onyx (optional, off by default) | 8080+100n, 9980+100n | 8180, 10080 |
| Plan A only: AuditBoard, Cascade | base+100n per port | 9101…, 8110… |

Slot 2 puts the API on 8010 and Forge BE on 8013, but 8010/8011 belong to
Cascade. Today the allocator only skips ports that are *currently* busy, so
slot 2 is taken whenever Cascade happens to be down. Fix: a reserved-port list
in `setup_worktree.py` covering every fixed fleet port (8010, 8011, 8004, 8080,
8088, 9000-9006, 9980, 1337, 7077, 5432, 5433, 6379, 6382).

**Database: one Postgres server, one database per instance.** No new Postgres
container. `LOCAL_DB_NAME` is already read by the app
(`midship/app_container.py:301`), both alembic environments
(`alembic/main/env.py:254-256`, `alembic/forge/env.py:123`) and
`scripts/load_db_dump.py:27-31`.

- A dedicated golden database `midship_golden` is filled once with
  `pg_dump` of instance 0's database, which works while instance 0 is live.
  Nothing ever connects to `midship_golden` afterwards.
- A new instance gets `CREATE DATABASE midship_s<n> TEMPLATE midship_golden`.
  That statement fails if any session is connected to the template, which is
  why instance 0's live database can't be the template directly.
- The instance then runs `make migrate` and `make forge-migrate` for its own
  branch, so a branch's migrations never touch another instance.
- Refreshing the golden database is a separate, explicit verb.

**Redis: one container per instance, not a DB index.** Midship's broadcast
client uses Redis pub/sub (`app_container.py:245,321`), and pub/sub channels
are shared across all DB indexes. Only a separate server isolates them. That
needs a `REDIS_PORT` setting, since 6379 is hardcoded.

**Hatchet: one server per instance.** `hatchet server start` accepts
`--project-name`, `--profile`, `--dashboard-port` and `--grpc-port`. The CLI
cannot create tenants; tenants on one server are dashboard-only and untested.
Each instance gets its own profile in `~/.hatchet/profiles.yaml` and its own
token. Its API and workers read `HATCHET_CLIENT_TOKEN`,
`HATCHET_CLIENT_HOST_PORT` and `HATCHET_CLIENT_SERVER_URL` from the
environment, which `midship/config.py:105-110` lets override `config.ini`.

**Browser isolation by hostname.** Cookies ignore the port, so two frontends on
`localhost` share the Forge session cookie (`forge/api/auth/router.py:227`) and
the `OptroDomainDialog.tsx:94` cookie. Localhost-port-scoped localStorage
(`access_token`, `workspace_id`) is already separate. Instance n is served as
`http://s<n>.localhost:<port>`: Chrome resolves `*.localhost` to loopback with
no `/etc/hosts` edit. Every per-instance URL uses that hostname: `FRONTEND_URL`,
`FORGE_FRONTEND_URL`, `MIDSHIP_REDIRECT_URI`, `SSO_REDIRECT_URI` and the OAuth
redirect URI registered in AuditBoard. The fallback, if Vite or Forge rejects
the hostname, is a per-instance cookie name in Midship code.

**Process ownership by process group, never `pkill -f`.** Every API, worker and
frontend is launched in its own process group, and the group id goes to
`logs/<id>/<service>.pgid`. Stop kills that group only. macOS has no `setsid`
binary, so launch through the same mechanism `dev-server.sh` uses (or a
`python3 -c 'import os; os.setpgrp(); os.execvp(...)'` wrapper). Instance 0
moves to the same mechanism, which also fixes today's `pkill` patterns killing
PR #497 worktree stacks.

---

## Plan B: Midship only

### What is isolated and what is shared

| Component | Per instance | Shared |
|---|---|---|
| Midship FE, API, Forge FE/BE, Hatchet workers | ✅ own processes, ports, pgid files | |
| Midship database | ✅ `midship_s<n>` on the shared Postgres server | Postgres server (5432) |
| Midship Redis | ✅ own container | |
| Hatchet server, queue, token | ✅ own server | |
| Browser cookies | ✅ `s<n>.localhost` | |
| Logs, tmux session, doctor | ✅ `logs/<id>/`, `fleetcom-logs-<id>` | |
| WOPI / Onyx | optional per instance, off by default | or instance 0's |
| AuditBoard/Optro | | ✅ one instance, one `demo_data` |
| Cascade | | ✅ one instance |
| LaunchDarkly, AWS (KMS, Secrets Manager, S3) | | ✅ real, shared |

What "full vertical" means under Plan B: each Midship instance runs the complete
Midship → Optro → Cascade flow against the one shared AuditBoard and Cascade.
Midship state is isolated. Optro users, workspaces and Cascade workbooks are
shared. Since every instance talks to the same AuditBoard, the Optro base URL
stored per workspace in a cloned database stays valid, and no rebinding is needed.

### Work items (PR-sized, in order)

**0. FLEETCOM: land the in-progress work.** Commit and merge the uncommitted
changes to `fleetcom-start-all.sh`, `fleetcom-stop-all.sh`, `fleetcom-doctor.sh`,
`fleetcom-worktree.sh` and `fleetcom-onboard.sh` before starting item 5, since
item 5 rewrites the same lines.

**1. midship-turbo-broccoli: `REDIS_PORT` setting.** Small PR.
- Add `REDIS_PORT` (default 6379) to `midship/config.py`.
- Use it at `midship/app_container.py:655,660,970,975,1111,1116` and
  `midship/app/api/files/router.py:49,108`.
- Optional, same PR: a `DB_PORT` setting. `DB_HOST=127.0.0.1:5432` already
  works, since the URL is built as `...@{host}/{db}`
  (`packages/midship_core/midship_core/db/session.py:52`). Plan B doesn't need
  it because the Postgres server is shared.

**2. midship-turbo-broccoli: parameterize the compose file.** Small PR.
- Host ports from variables with today's defaults: `${MIDSHIP_PG_PORT:-5432}`,
  `${MIDSHIP_REDIS_PORT:-6379}`, `${MIDSHIP_WOPI_PORT:-8080}`,
  `${MIDSHIP_ONYX_PORT:-9980}` in `docker-compose.yml`.
- `scripts/load_db_dump.py:35-50`: target the container through
  `docker compose -p "$COMPOSE_PROJECT_NAME" exec postgres` in place of a fixed
  name.
- The project-name pin stays in the gitignored override, owned by FLEETCOM.
  Instances ≥ 1 pass `-p midship-s<n>` and run only `redis` (plus `wopi`/`onyx`
  when asked). Postgres stays in instance 0's project.

**3. midship-frontend: full per-instance environment.** Medium PR in
`.claude/scripts/setup_worktree.py`.
- Reserved-port list (see Design decisions) so slot 2 is never assigned.
- `transform()` and `ports.env` also write `MIDSHIP_REDIRECT_URI`,
  `SSO_REDIRECT_URI`, `MIDSHIP_PUBLIC_API_URL`, `LOCAL_DB_NAME`,
  `REDIS_PORT`, `HATCHET_CLIENT_TOKEN`, `HATCHET_CLIENT_HOST_PORT`,
  `HATCHET_CLIENT_SERVER_URL`, `COMPOSE_PROJECT_NAME` and the hostname. Today only
  `VITE_*URL`, `FORGE_FRONTEND_URL` and `FRONTEND_URL` shift.
- `launch.json`'s `hatchet-worker` entry uses `--profile s<n>`, not `local`.
- An `--isolated` flag. Without it the stack behaves exactly like PR #497
  (shared database, Redis and Hatchet), so nobody's current workflow changes.

**4. midship-frontend: instance data bootstrap.** Medium PR, a new script next
to `setup-worktree.sh`. Keeping it in this repo means Midship developers who
don't use FLEETCOM get the same isolation; FLEETCOM calls the same script.
- `up`: start `midship-s<n>` (Redis); `hatchet server start -p hatchet-s<n>
  --profile s<n> -d <port> -g <port>`; write the token into the instance env;
  `CREATE DATABASE … TEMPLATE midship_golden` if the database is missing; run
  both migrations.
- `down`: stop the compose project and Hatchet server; keep the data.
- `destroy`: also drop `midship_s<n>`, remove the Hatchet project and volumes
  and the profile, and free the slot.
- `golden-refresh`: `pg_dump` instance 0's database into `midship_golden`.

**5. FLEETCOM: instance support.** Largest item, 2-3 PRs.
- **`fleetcom-paths.sh`:** a `FLEETCOM_INSTANCE` variable (empty means
  instance 0, today's behaviour). When it is set:
  - read `instances/<id>.conf` in place of `worktrees.conf`, with the same
    precedence;
  - `LOGS=logs/<id>/`;
  - derive every port variable from the slot in `slots.json`;
  - name the sessions `fleetcom-logs-<id>` / `fleetcom-ab-api-<id>`, with the
    pane map at `logs/<id>/tmux-panes.md`.

  Every script already sources `fleetcom-paths.sh`.
- **Remove fixed values:** replace every hardcoded 8000/5173/6379/1337/7077 in
  `fleetcom-start-all.sh:102,187`, `fleetcom-stop-all.sh:132` and
  `fleetcom-doctor.sh:187-195,224` with the port variables.
- **Container lookups:** replace `docker ps --filter name=…` / `docker exec
  midship-turbo-broccoli-postgres-1` (`fleetcom-doctor.sh:124-142`,
  `fleetcom-start-all.sh:98-100,128`, `fleetcom-stop-all.sh:51-54,144-145`) with
  `docker compose -p "$PROJ" ps -q <service>`.
- **Process groups:** replace the `pkill -f` lines (`fleetcom-start-all.sh:148`,
  `fleetcom-stop-all.sh:63-78`, `fleetcom-doctor.sh:195`) with pgid files.
- **Verbs:**
  - New: `./fleetcom --instance <id> start|stop|restart|doctor|logs|claude|tell midship`.
  - New: `./fleetcom instance create <id> [--frontend <worktree>] [--backend <worktree>] [--wopi]`
    allocates a slot, writes the conf file, calls item 4's `up`, and registers
    the OAuth redirect URI (item 6).
  - New: `./fleetcom instance list | destroy <id> | golden-refresh`.
  - `--instance` with `auditboard` or `cascade` is refused under Plan B,
    naming the shared instance.
- **Doctor:** reports the instance's ports, Hatchet server, database existence,
  and migration state, reusing `check_midship_db_ready`.

**6. Optro sign-in per instance (AuditBoard data only, no AuditBoard code).**
- AuditBoard redirect URIs match exactly on scheme, host and port. Each instance's callback
  `http://s<n>.localhost:<fe>/auth/optrooauth/callback` has to be added to the
  `midship` OAuth client.
- Two client mechanisms exist in AuditBoard:
  - the config client (`MIDSHIP_OAUTH_REDIRECT_URIS`, `custom-environment-variables.mjs:82-102`);
    `config/local.mjs` currently pins it to `localhost:4000`;
  - the `midship_oauth_clients` row in `demo_data`, wiped on reseed.

  Local sign-in has been observed to use the table row (memory note "Midship
  Optro OAuth client missing"). Confirm which one is in use before writing item 5's
  registration step. `instance create` appends the URI and
  re-applies it after a reseed, the same way FLEETCOM already re-applies
  the ML port override.

### Cost per extra instance (Plan B)

Not measured, so it has to be checked on the first instance: one Redis container
(tens of MB), one Hatchet server (a Postgres plus hatchet-lite container),
uvicorn with reload, six Hatchet worker processes, and two Vite dev servers.
Expect roughly 2-3 GB. The Docker VM is allocated about 25 GB and runs 36
containers. The host has 128 GB, so raising the VM limit is cheap if needed.

### Acceptance test (Plan B)

1. `./fleetcom instance create s1 --frontend <worktree-A>` and `s2 --frontend
   <worktree-B>` on different branches, with instance 0 running.
2. `./fleetcom --instance s1 doctor` and `--instance s2 doctor` are green;
   plain `./fleetcom doctor` is unchanged.
3. Optro sign-in succeeds on `s1.localhost` and `s2.localhost` in the same
   browser profile without signing the other out.
4. A migration on s1's branch doesn't appear in s2's database or in instance 0's.
5. Start a Hatchet workflow on s1: only s1's workers pick it up (s2's Hatchet dashboard shows nothing).
6. `./fleetcom --instance s1 restart midship` leaves s2 and instance 0 running
   (compare process group ids before and after).
7. A Midship → Optro → Cascade hybrid run completes from s1 and from s2.
8. `./fleetcom instance destroy s1` frees the slot, database, containers and profile;
   s2 is untouched.

---

## Plan A: full vertical (adds AuditBoard and Cascade per instance)

Everything in Plan B, plus the items below. Each item is in a repo owned by
another team. DEVTOOLS-915 records the DX team's decision against per-worktree
port/database offsets in `abc`, so agree the approach with them before opening PRs.

### What changes from Plan B

| Component | Plan A |
|---|---|
| AuditBoard v1/v2/auth, login and client Vite, caddy | Per instance, ports base+100n |
| AuditBoard database | `demo_data_s<n>` on the shared host Postgres (5433), from `TEMPLATE` |
| AuditBoard Redis | Shared host Redis 6382, DB index `/n` (check that AuditBoard doesn't depend on pub/sub across instances) |
| Permissions service (9008/9009) | Decision needed: `PERMISSIONS_DATABASE_URL` is hardcoded to `demo_data` (`auditboard-dev-env/.envrc:231`) |
| Cascade web, ws, c3, its database and volumes | Per instance, own compose project |
| launchdevly, conductor, extract, ML, MinIO, Kafka, mailcatcher | Shared |
| Midship cloned database | Must rebind the workspace's Optro base URL to its own AuditBoard (`bind_workspace_optro_base_url`, `optro_oauth_router.py:419`) |

### Work items

**A1. auditboard-backend: port settings from environment variables.**
- v1 reads `hapi.port` (`config/default.mjs:13`), auth reads `config/default.mjs:17`,
  and v2 reads `common/routing-layer/config/default.json:4`. None has an
  environment mapping.
- Try `NODE_CONFIG='{"hapi":{"port":N}}'` first, since it may need no code.
  v2 has its own config directory, so check that `NODE_CONFIG` reaches it.
- Otherwise add mappings in both `custom-environment-variables.mjs` files. Small PR.

**A2. auditboard-dev-env: per-instance environment overlay.**
- The overlay sets `DATABASE_URL` (`demo_data_s<n>`), `REDIS_URL` /
  `DOCKER_REDIS_URL` (DB index), `BASE_URL`, `PORT_API_V1`/`V2`,
  `PORT_login`, `PORT_soxhub-client`, `MIDSHIP_OAUTH_*`, `CASCADE_API_URL` and
  `CASCADE_APP_URL`.
- `.envrc:2-5` re-sets `SOXHUB_*_DIR` whenever it loads. `bin/reset-db:29` honours
  an exported `SOXHUB_API_DIR` only when the dev-env `.envrc` isn't reloaded
  after it, so the overlay must load last.
- This could be a FLEETCOM-owned overlay with no dev-env PR, but it depends on
  A1 for the backend ports.

**A3. Permissions service.** Either share one permissions database, so all
instances see instance 0's permissions (simplest, and likely acceptable since
demo data is identical), or run a permissions container per instance. Decide
after checking what the service reads per request.

**A4. cascade: configurable frontend ports.** `client/src/js/core/host.ts:1-3`
hardcodes `localhost:8088`, 8010 and 8011, so a second Cascade frontend can't
reach its own API. Small PR: build-time environment values with those
defaults.

**A5. Cascade per instance (FLEETCOM, no Cascade PR).**
- A per-instance copy of `cascade-compose.override.yml` with `-p cascade-s<n>`
  and shifted ports (8010, 8011, 33060, 63790, 6010/6011, 8088, debugpy
  15678-82).
- Volumes are namespaced by project, so a new instance starts **empty**, the
  same trap as Midship. Seed from a dump, like the Midship golden database.
- `AB_DOMAINS` is comma-separated (`cascade/server/cascade/settings/default.py:341`)
  but `AB_LOGIN_URL` (`:342`) is a single URL, so each Cascade instance points
  at its own AuditBoard.
- The fixed `cascade_web` name used by `fleetcom-start-all.sh:366` becomes a
  compose-service lookup.

**A6. Midship rebind.** After cloning, `instance create` rebinds the workspace's
Optro base URL to the instance's own AuditBoard. The OAuth client (config client
per AuditBoard instance, set by environment, no SQL) carries that instance's
redirect URI.

### Cost per extra instance (Plan A)

About 3-5 GB on top of Plan B's cost, based on current measurements:
- AuditBoard v1 node is about 460 MB.
- The Cascade set is about 4 GB across 10 containers today, part of which
  (MinIO, shared services) is not duplicated.
- Boots add 1-4 minutes per AuditBoard.

Duplicating the whole dev-env per instance instead would repeat about 20 fixed
ports and about 4.6 GB, which is why it is not proposed.

### Acceptance test (Plan A)

Plan B's steps 1-8, plus:
- Each instance's Optro sign-in lands in its own AuditBoard.
- A hybrid run on s1 creates a workbook only in s1's Cascade.
- Resetting s1's AuditBoard database leaves s2 and instance 0 untouched.

---

## Risks and things to verify first

- **Local Optro sign-in is already fragile for instance 0.**
  `buildOptroBaseUrl` forces `https://` for localhost, while
  `auditboard-dev-env/.envrc` sets `BASE_URL=http://localhost:9001`, so the
  `private_key_jwt` audience never matches. Fix this for instance 0 first:
  either land midship-frontend #606 or set `BASE_URL=https://localhost:9002`.
  Otherwise acceptance step 3 fails for reasons unrelated to isolation.
- **Vite and `s<n>.localhost`.** Check that Vite's `allowedHosts` and Forge's
  CORS (`forge/main.py:83-85`, which allows only `FORGE_FRONTEND_URL`) accept
  the hostname.
- **Hatchet memory per server:** measure on the first instance.
- **Shared S3/KMS:** instances write into the same real buckets. Check that
  Midship object keys are unique per workspace or file id, so instances can't
  overwrite each other.
- **Two launchers for Midship:** both FLEETCOM (`scripts/run-workers.sh`) and
  midship-frontend's `launch.json` (`hatchet worker dev --profile local`)
  start workers. After item 3 both must read the same instance environment, or
  a worker ends up on the wrong Hatchet server.
- **Golden database drift:** a clone of an old golden database plus the
  branch's migrations is fine only while migrations stay forward-compatible.
  `golden-refresh` exists for when they aren't.

## Suggested order

0 → 1 → 2 (both midship-turbo-broccoli, independent, can be one PR) → 3 → 4 → 5
→ 6 → acceptance test. Plan A items start only after Plan B passes and the
DX team agrees; A1 and A4 are independent small PRs and can go first.
