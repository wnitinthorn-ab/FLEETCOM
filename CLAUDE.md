# CLAUDE.md — FLEETCOM

FLEETCOM runs three local dev stacks side-by-side on one Mac — **Midship**,
**Cascade**, and **AuditBoard** — via the `fleetcom-*.sh` scripts (front door:
`./fleetcom <command>`). `README.md` is the source of truth for ports,
services, and every known failure mode (its **Troubleshooting** and **Known
edge cases** sections). The `fleetcom-doctor` skill is the diagnose-and-self-heal
playbook — invoke it whenever something is unhealthy.

## Claude is the fleet supervisor

Claude operates and supervises this stack: reviews logs, diagnoses failures,
and starts/restarts individual stacks or the whole fleet. Two modes, decided by
**where you're running**:

```bash
# Am I the in-tmux supervisor, or an external session?
[ "${TMUX:+x}" ] && [ "$(tmux display-message -p '#S' 2>/dev/null)" = fleetcom-logs ] \
  && echo "SUPERVISOR (inside fleetcom-logs)" || echo "EXTERNAL"
```

### If you are the SUPERVISOR (inside the `fleetcom-logs` tmux session)

You share the `backends` window with the live log panes. `logs/tmux-panes.md`
maps which pane is which.

- **Review logs** — pull a snapshot on demand; never tail continuously (it
  bloats context): `tmux capture-pane -p -t <pane_id> -S -`. Log files also
  live in `logs/*.log`. Read `logs/tmux-panes.md` for the pane IDs.
- **Diagnose** — `./fleetcom doctor` for the port/health ground truth, then
  follow the `fleetcom-doctor` skill's self-heal loop against README.
- **Restart safely** — `./fleetcom restart [midship|auditboard|cascade]`.
  `./fleetcom stop`/`restart` auto-detect this session and **preserve it** —
  they will not tear you down — and the dev daemons `start-all` launches
  survive the command exiting. So a plain `./fleetcom restart` is safe here.
  A per-stack restart is quick (run it synchronously); a **full-fleet** restart
  takes minutes, so run it in the **background** (don't block yourself) and
  watch `./fleetcom doctor` for the stacks coming back. Do NOT hand-roll a
  `stop-all.sh --kill`-style teardown — use the verbs, which self-protect.
- **Per-stack** — pass `midship`, `auditboard`, or `cascade` to
  `start`/`stop`/`restart` to act on just that one; omit for all three.

### If you are EXTERNAL (a normal session; cwd in FLEETCOM or elsewhere)

You can drive the fleet directly and, if a supervisor is running, hand it work.

- **Operate the fleet** — every `./fleetcom` verb works from a plain terminal:
  `./fleetcom doctor`, `./fleetcom start|stop|restart [stack]`,
  `./fleetcom logs`. A restart from here is synchronous (no supervisor to
  protect), exactly as before.
- **Is a supervisor up?** — `tmux has-session -t fleetcom-logs 2>/dev/null`.
- **Talk to the supervisor** — `./fleetcom tell "<directive>"` types a message
  into its `claude` pane and submits it, so it acts (it reads every log pane and
  knows the session-preserving restart). e.g.
  `./fleetcom tell "cascade is wedged — restart just that stack and confirm it's healthy"`.
- **No supervisor yet?** — launch one beside the logs with `./fleetcom claude`
  (full restart + a Claude pane). Run it from a separate terminal, not from
  inside `fleetcom-logs`.

## Command reference

| Command | What |
|---|---|
| `./fleetcom doctor` | Port + health report (read-only ground truth) |
| `./fleetcom start [stack]` | Boot all, or one stack (skips what's already up) |
| `./fleetcom stop [stack]` | Stop all, or one stack (supervisor-safe from inside fleetcom-logs) |
| `./fleetcom restart [stack]` | Bounce all, or one stack (session auto-preserved when supervising) |
| `./fleetcom logs` | Live log panes + error alerts |
| `./fleetcom claude` | Full restart + a supervising Claude pane beside the logs |
| `./fleetcom tell "<msg>"` | Dispatch a directive to the supervising Claude |
| `./fleetcom worktree` | Boot a repo from a git worktree instead of its main checkout |
| `./fleetcom update [stack]` | Pull a checkout and make it runnable again (`--migrate` opt-in) |

`stack` ∈ `midship | auditboard | cascade` (omit = all three).

## Worktrees

Every repo here has many git worktrees (`git worktree list` in any of them),
and a session working on a branch is usually editing one of those rather than
the main checkout. FLEETCOM boots whichever path each repo resolves to, so
booting against the wrong one produces a green `doctor` that describes code
nobody is editing.

**Check first.** `./fleetcom doctor` now opens with a `== Checkouts ==` block
naming each repo's path, branch, and whether it is a worktree or the main
checkout. Read it before concluding anything from the rest of the report.

```
./fleetcom worktree status              # what will boot
./fleetcom worktree list midship-frontend   # every worktree; "*" marks the active one
./fleetcom worktree use midship-frontend ht-all-fe   # by branch, or by path
./fleetcom restart midship              # required for it to take effect
./fleetcom worktree reset               # back to local.conf for every repo
```

**`use` provisions the worktree.** A fresh worktree has only tracked files, so
the gitignored config a stack needs to boot is absent — and the resulting
failures name anything but the missing file (midship-turbo-broccoli dies at
import with `ValidationError: Token must be set`, because a Hatchet client is
built at module scope in `excel_screenshot.py` and reads its token from `.env`;
without `docker-compose.override.yml` the `wopi` service is built from source and
the boot fails inside its Dockerfile). So `use` symlinks each repo's gitignored
config from the checkout being left behind, and names any dependency install
still outstanding (`poetry install` / `pnpm install`) rather than running it.

Symlinks, not copies, so a rotated credential does not need updating in two
places. A real file already present in the target is never replaced — only
symlinks are refreshed. `--no-env` skips the whole step.

**Precedence is environment → `worktrees.conf` → `local.conf` → defaults.** So
`MIDSHIP_FRONTEND_DIR=/path ./fleetcom start` overrides both files for one run
without recording anything. Before this existed `local.conf` assigned
unconditionally and silently discarded exported values; `fleetcom-logs.sh` still
carries its own hand-rolled save/restore of `LOGS_VIEW` from that era.

`worktrees.conf` is gitignored and deliberately separate from `local.conf`, so
`fleetcom onboard --reconfigure` cannot discard the worktree a task is mid-way
through, and dropping every override is deleting one file.

A boot is refused outright when a repo resolves to a missing directory or
something that is not a git checkout — the shape a stale override leaves — since
otherwise it surfaces minutes in as an install error naming anything but the
cause.

Before non-trivial changes to this stack, read README's Troubleshooting/Known
edge cases and use the `fleetcom-doctor` skill — most failure modes are already
documented with a named cause and fix.

## Updating a checkout

`./fleetcom update [auditboard|cascade|midship|all] [--migrate] [--no-build]`

Encodes the steps that fail confusingly when skipped:

- **Not a fast-forward is reported, never merged.** It prints git's own error
  rather than guessing at a cause — an early version blamed "local commits" for
  what was actually `pull.rebase=true` refusing on a dirty `pnpm-lock.yaml`.
- **Already-current is detected before pulling**, not by attempting a pull, so a
  no-op update is not defeated by an unrelated dirty-tree precondition.
- **`dist/` is wiped before the AuditBoard rebuild.** It is gitignored, so a pull
  leaves orphaned compiled output and v1 dies at boot with `does not provide an
  export named X` — pointing at a file that is correct.
- **`pnpm install --config.confirm-modules-purge=false`**, because the prompt it
  otherwise shows hangs a backgrounded run with no indication why.
- **`pnpm -w ab build`**, never bare `ab build`.
- **Migrations are opt-in** (`--migrate`) and run through `direnv exec` so they
  reach the port FLEETCOM moved the database to (5433), not the default 5432
  where Midship's postgres lives.
- **Node version is checked and reported once**, naming both versions. AuditBoard
  pins `24.19.0` in `.nvmrc` and root `engines`; a mismatch otherwise surfaces as
  `WARN Unsupported engine` repeated across 64 workspaces and then a failure
  somewhere unrelated.

Stacks are not restarted — run `./fleetcom restart <stack>` afterwards.
