# Plan: isolated concurrent verticals on one Mac

Status: plan only, nothing implemented. Written 2026-09-23.

Goal: run two or more complete Midship stacks at the same time (frontend, API,
Forge, Hatchet workers, Hatchet server, database, Redis), each wired through
Optro/AuditBoard and Cascade, so that restarting, migrating or breaking one
never affects another.

Scope: Midship only. Changes land in midship-frontend,
midship-turbo-broccoli and FLEETCOM, plus local gitignored override files.
AuditBoard/Optro and Cascade stay one shared instance. This is the plan that
can be executed today.

Container runtime: none of this depends on Docker vs Podman. On macOS both run a
Linux VM that publishes ports to host `localhost`. The blockers are processes
running on the host, hardcoded ports, and shared state. Evaluating the runtime
itself belongs to DEVTOOLS-187.

---

## What already exists (checked 2026-09-23)

Look up current state with `gh pr view <n> --repo soxhub/<repo>`.

| Repo / item | What it does | Relevance |
|---|---|---|
| midship-frontend #497 | Each worktree gets a slot in `~/.config/midship-dev/slots.json`. Ports shift by 5 × slot (FE 5173, API 8000, Forge FE 3434, Forge BE 8003). `.claude/scripts/setup_worktree.py:36`, `transform()` at `:307-323` | Base port allocator |
| midship-frontend #504 | Pairs a frontend worktree with a same-branch midship-turbo-broccoli worktree, symlinks `.env*`, installs dependencies | Reused as is |
| midship-frontend #506, #507, #511 | Settings symlink; dev servers outlive the Claude session; dev servers stop with their stack via per-stack pgid files (`dev-server.sh:58-98`); a preview never kills another process to take its port | The pgid mechanism is the model for FLEETCOM's process handling |
| midship-frontend #606 (open) | Honors a typed `http://` for a localhost Optro URL | Needed for local Optro sign-in (see Risks) |
| midship-turbo-broccoli #1458 | `DB_NAME` configurable (RDS code path) | Local path already has `LOCAL_DB_NAME` |
| midship-turbo-broccoli #1436 | Hatchet dev file watcher ignores Claude Code worktrees | Reused |
| FLEETCOM uncommitted work in the main checkout | Hardens the single shared Midship stack: pins `-p midship-turbo-broccoli`, runs migrations on boot, adds Cascade→MinIO forwarders, orders the Hatchet stop | Touches the same files as this plan's FLEETCOM work. Commit or merge it first |

No PR in any repo isolates the Midship database, Redis or Hatchet per stack.
PR #497 documents sharing them as deliberate for now.

---

## Design decisions

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

Slot 2 puts the API on 8010 and Forge BE on 8013, but 8010/8011 belong to
Cascade. Today the allocator only skips ports that are *currently* busy, so
slot 2 is taken whenever Cascade happens to be down. Fix: a reserved-port list
in `setup_worktree.py` covering every fixed fleet port (8010, 8011, 8004, 8080,
8088, 9000-9006, 9980, 1337, 7077, 5432, 5433, 6379, 6382). The list applies
only to **new** allocations. A worktree already registered on slot 2 keeps it,
and setup prints a warning suggesting it be re-slotted, so nobody's ports
change underneath them.

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

**Seeded, identical starting state in every instance.** Every instance must
start with instance 0's users, workspaces, Optro workspace binding, OAuth and
JIT-provisioned users, and Forge data. Signing in then works the same way in
every worktree, and none of the setup steps an empty database needs are
repeated. The failure an empty database causes (unmigrated main schema, then
an unmigrated `forge` schema, then Optro sign-in failing because the workspace
and just-in-time provisioning weren't set up) is exactly why instance 0 uses
one shared database.

- **Source of the golden database:**
  - Default: a snapshot of instance 0's live database. It carries your
    current seeded, logged-in state.
  - Alternative, for a clean baseline: the repo's seed dump
    (`/Users/wnitinthorn/Development/midship-turbo-broccoli/db/dev_dump_*.sql`,
    the one `fleetcom-onboard.sh` loads through `scripts/load_db_dump.py`),
    plus the same fix-ups onboarding applies afterwards.
  - Chosen with `golden-refresh --from instance0|dump`.
- **Both schemas are copied.** `public` and `forge` (with both
  `alembic_version` tables) live in the same database, so one `TEMPLATE`
  clone carries both.
- **User IDs are identical in every clone.** Anything keyed by user or
  workspace ID behaves the same in every instance: LaunchDarkly targeting,
  Optro bindings, access tokens signed with the shared secret from `.env`.
- **Keeping instances current:**
  - `./fleetcom instance reseed <id>` drops the instance's database,
    re-clones it from the golden database and re-runs the branch's
    migrations. The slot, hostname and Hatchet server are kept.
  - `doctor --instance <id>` warns when the golden database is behind instance
    0's `alembic_version` or older than 7 days. Refreshing is never automatic,
    so an instance's data is never replaced without asking.
- **Files in S3 stay shared.** Cloned rows point at the same objects in the
  real, shared S3 buckets, so file contents appear in every instance. Deleting
  a file in one instance deletes the object that the other instances' rows
  still reference. Treat deletions as shared.

**LaunchDarkly, AWS and other local configuration: the same everywhere.**
Every instance's API and worker launches get the same variables instance 0 gets:
- `LAUNCHDARKLY_LOCAL_ONLINE` (default `true`, or
  `MIDSHIP_LAUNCHDARKLY_LOCAL_ONLINE`);
- `AWS_PROFILE` from `MIDSHIP_AWS_PROFILE`, for KMS, Secrets Manager and the
  LaunchDarkly key;
- `ENV=local_db`.

The injection moves into one function in `fleetcom-paths.sh`, used by every
launch, so an instance can't drift from instance 0.

`.env` / `.env.local`, which hold the Optro client id, the `private_key_jwt`
private key and the signing secrets, stay symlinked from the main checkout,
as `/Users/wnitinthorn/Development/FLEETCOM/fleetcom-worktree.sh` and
[midship-frontend#504](https://github.com/soxhub/midship-frontend/pull/504)
already do. A rotated credential is therefore updated once. Only the
per-instance values from `instances/<id>.conf` and `ports.env` override them:
ports, `LOCAL_DB_NAME`, `REDIS_PORT`, `HATCHET_*` and URLs.

**Local state survives restarts.**
- An instance's slot number, and so its ports and `s<n>.localhost` hostname,
  never changes once assigned. The browser keeps the instance's
  `access_token`/`workspace_id` in localStorage and its cookies, so sign-in
  survives `stop`/`start` and reboots.
- A new instance still needs one sign-in, because browsers keep storage per
  origin. The sign-in is immediate because the user and workspace already
  exist in the cloned database.
- `down` and `stop` never remove volumes, the database, the Hatchet profile or
  the conf file. Only `destroy` and `reseed` touch data, and both ask for
  confirmation.
- Redis contents and Hatchet run history are not copied into new instances.
  They start empty, like after a Redis restart today.

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
PR #497 worktree stacks. When a pgid file is missing, stop falls back to
today's pattern, limited to instance 0's checkout (compatibility rule 6).

---

## Backwards compatibility (applies to every work item)

The requirement: someone who never creates an instance, never edits a config
file, and never re-runs onboarding sees exactly today's behaviour. This includes
anyone pulling only some of these PRs, or running an old branch in a worktree.

**Rules**

1. **Every new setting defaults to today's value.**
   - `REDIS_PORT` defaults to 6379.
   - Compose ports are `${VAR:-<today's port>}`.
   - `LOCAL_DB_NAME` still defaults to `postgres`.
   - Hatchet still uses the `local` profile.
   - Hostnames stay `localhost`.
   - AuditBoard and Cascade ports keep their current defaults.

   An unset variable must never be an error.
2. **Isolation is opt-in, never inferred.**
   - Nothing becomes isolated because a file is present or absent, or a port
     happens to be free.
   - Only an explicit `--instance <id>` / `instance create`, or
     midship-frontend's `--isolated` flag, turns it on.
   - PR #497 worktree stacks keep sharing the database, Redis and Hatchet
     unless `--isolated` is passed.
3. **Instance 0 keeps every name and path.** The following don't change when
   `FLEETCOM_INSTANCE` is unset:
   - ports;
   - compose project `midship-turbo-broccoli` and container names;
   - database `postgres`;
   - log files in `logs/` (not `logs/0/`);
   - tmux sessions `fleetcom-logs` / `fleetcom-ab-api`;
   - `logs/tmux-panes.md`;
   - `worktrees.conf` and `local.conf` handling;
   - `./fleetcom doctor` output.

   Scripts and people that grep these keep working.
4. **Files are only added to.**
   - `ports.env` and `launch.json` gain keys; existing keys keep their meaning
     and values.
   - `slots.json` entries are never renumbered.
   - OAuth redirect URIs are appended, never replaced.
   - No existing file changes format.
5. **No new required setup step.**
   - `onboard` doesn't gain a mandatory step.
   - `midship_golden`, per-instance Hatchet profiles and conf files are created
     lazily by `instance create`.
   - `update` and `doctor` never require them.
6. **Stopping still works on processes started by the old scripts.**
   - A process with no pgid file (launched before the upgrade, or by hand)
     is stopped the way it is today.
   - The old `pkill -f` patterns remain the fallback for instance 0 only.
   - The fallback is limited to processes whose working directory is instance
     0's checkout, so it can't hit an instance's processes.
7. **Mixed versions fail loudly, never silently share.**
   - `instance create` checks that the checked-out midship-turbo-broccoli branch
     supports `REDIS_PORT`. The check is a grep for the setting in
     `midship/config.py`.
   - It also checks that the midship-frontend branch supports `--isolated`.
   - If either check fails, it refuses and names the missing change, rather
     than starting an instance that quietly uses instance 0's Redis or Hatchet.
   - Instance 0 never runs these checks. An old branch runs exactly as today.
8. **No renamed or removed verbs, flags or environment variables.**
   - Existing `./fleetcom` verbs keep their arguments and output.
   - `--instance` is a new, optional flag.
   - `MIDSHIP_FRONTEND_DIR`-style environment overrides keep their precedence.

**Regression test, run on every PR before merge**

1. Starting point: today's `local.conf` and `worktrees.conf`, no `instances/`
   directory, and no new environment variables set.
2. Run `./fleetcom start`, then `doctor`, then `restart midship`, then `stop`.
3. Compare against a run on `main`. All of these must be identical:
   - the listening ports (`lsof -iTCP -sTCP:LISTEN`);
   - `docker ps --format '{{.Names}}'`;
   - the set of log file paths;
   - tmux session names;
   - `doctor` output, apart from timestamps.
4. The same check with a PR #497 worktree stack running beside instance 0,
   without `--isolated`: it still shares the database, and a FLEETCOM restart no
   longer kills it (the one intended change).
5. Leave an old midship-turbo-broccoli branch without `REDIS_PORT` checked out:
   - instance 0 boots and works;
   - `instance create` refuses and names the missing change.
6. Start the stack with the *old* FLEETCOM, upgrade FLEETCOM, then run
   `./fleetcom stop`: every old process and container stops.

---

## Midship only

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

What "full vertical" means here: each Midship instance runs the complete
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
  (`packages/midship_core/midship_core/db/session.py:52`). Not needed here
  because the Postgres server is shared.
- Compatibility:
  - With `REDIS_PORT` unset, every connection is byte-for-byte today's.
  - A `DB_PORT` setting, if added, must not break an existing
    `DB_HOST=host:port`. When both are set, `DB_HOST`'s port wins, with a
    warning.
  - Staging and production don't set it, so their behaviour is unchanged.

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
- Compatibility:
  - A plain `docker compose up`, with no variables set and no override, must
    publish the same ports and create the same volume names as today.
  - `load_db_dump.py` falls back to today's container name when
    `COMPOSE_PROJECT_NAME` is unset.
  - The volume `midship-turbo-broccoli_midship-pgdata` is never renamed, so
    existing data stays attached.

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
- Compatibility:
  - Without `--isolated`, the new keys either aren't written or are written
    with today's values, and `launch.json` is unchanged.
  - The main checkout's no-op path (slot 0) stays a no-op.
  - Existing `slots.json` entries keep their slot numbers. The registry format
    only gains optional fields, which older script versions ignore.
  - `test-setup-worktree.sh` gains cases asserting all of this.

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
- `golden-refresh [--from instance0|dump]`:
  - `instance0` (the default) pipes a `pg_dump` of instance 0's live database
    into a freshly recreated `midship_golden`.
  - `dump` loads the newest `db/dev_dump_*.sql` through
    `scripts/load_db_dump.py`, then applies onboarding's post-seed fix-ups.
- `reseed <id>`: drop the instance's database, re-clone it from
  `midship_golden`, and migrate. Keeps the slot, Hatchet server and conf file.
- Compatibility:
  - The script is new and runs only when invoked.
  - It never touches instance 0's database, compose project or `local` Hatchet
    profile.
  - `destroy` refuses instance 0.

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
  - New: `./fleetcom instance list | destroy <id> | reseed <id> | golden-refresh [--from instance0|dump]`.
    `destroy` and `reseed` ask for confirmation.
  - `instance create` runs `golden-refresh` automatically the first time, when
    `midship_golden` doesn't exist yet.
- **Shared launch environment:** one function in `fleetcom-paths.sh` builds the
  environment for API and worker launches (`ENV=local_db`, `AWS_PROFILE`,
  `LAUNCHDARKLY_LOCAL_ONLINE`) for every instance, instance 0 included. It
  replaces the per-launch copies in `fleetcom-start-all.sh`.
  - `--instance` with `auditboard` or `cascade` is refused,
    naming the shared instance.
- **Doctor:** reports the instance's ports, Hatchet server, database existence,
  and migration state, reusing `check_midship_db_ready`.
- Compatibility:
  - With `FLEETCOM_INSTANCE` unset, every derived variable equals today's
    literal. The PRs replace literals with variables whose defaults are those
    literals.
  - The regression test (above) proves it.
  - `doctor` without `--instance` prints the same report. It gets at most one
    extra line listing other running instances, and only when some exist.

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
- Compatibility:
  - The existing `localhost:5173` redirect URI is never removed or edited.
  - Appending is idempotent.
  - `instance destroy` removes only its own URI.

### Cost per extra instance

Not measured, so it has to be checked on the first instance: one Redis container
(tens of MB), one Hatchet server (a Postgres plus hatchet-lite container),
uvicorn with reload, six Hatchet worker processes, and two Vite dev servers.
Expect roughly 2-3 GB. The Docker VM is allocated about 25 GB and runs 36
containers. The host has 128 GB, so raising the VM limit is cheap if needed.

### Acceptance test

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
9. Seeded state:
   - Signing in to s1 and s2 with instance 0's user lands in the same
     workspaces, with the same Optro binding.
   - No onboarding, migration or just-in-time setup step is needed beyond the
     one sign-in per new hostname.
10. The same LaunchDarkly flag evaluates the same way in instance 0, s1 and s2.
    Check a flag targeted at that user or workspace.
11. `./fleetcom --instance s1 stop`, then `start`: the browser on
    `s1.localhost` is still signed in, and s1's data is intact.
12. `./fleetcom instance reseed s2` brings s2 back to the golden state; s1 and
    instance 0 are unchanged.

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
→ 6 → acceptance test.
