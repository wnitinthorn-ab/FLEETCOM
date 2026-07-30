---
name: fleetcom-doctor
description: Diagnose and self-heal a local FLEETCOM dev environment (Midship + Cascade + AuditBoard) by actually running the fleetcom-*.sh scripts and reacting to their real output — not just reading docs. Use when someone is setting up FLEETCOM for the first time, when ./fleetcom-doctor.sh reports anything NOT LISTENING or unhealthy, when a fleetcom-managed log (logs/*.log) shows a crash, or when a browser/console error mentions a port in FLEETCOM's port map (9001-9006, 8000, 8010, 8011, 5173, 8088, etc.).
---

# FLEETCOM doctor — setup & self-heal playbook

## Background

FLEETCOM installs and runs three stacks side-by-side on one Mac — Midship,
Cascade, and AuditBoard — via `fleetcom-onboard.sh` (one-time setup),
`fleetcom-start-all.sh` (boot everything), `fleetcom-doctor.sh` (port/health
report), `fleetcom-logs.sh`, `fleetcom-restart-all.sh`, and
`fleetcom-stop-all.sh`. `README.md` is the single source of truth for what
each port/service is and the known ways this stack breaks — read its
**Troubleshooting** and **Known edge cases** sections before assuming
something is new.

This skill's job is to actually *run* these scripts and react to their real
output — re-run, inspect logs, fix, re-run again — rather than just reading
about the stack. You have direct Bash access to the same machine the person
asking for help is using, so use it.

## Hard rules

- **Free to do without asking**: re-run any `fleetcom-*.sh` script (all are
  documented idempotent / safe to re-run any time), restart or recreate
  individual Docker containers, edit gitignored local config
  (`local.conf`, `cascade/.env`, `auditboard-dev-env/.envrc`) to correct a
  known-bad value, run `./refresh.sh` in `auditboard-frontend`, do read-only
  credential validation (e.g. curl LaunchDarkly to check a key), tail logs.
- **Always confirm with the human first**: DB resets/reseeding (both AB's
  and Midship's seed flows require a human to literally type `reset` —
  never fabricate that confirmation on someone's behalf), deleting a real
  SQL dump, any `docker compose down` that removes volumes, anything that
  touches git history.
- **Never print or paste secret values** (LaunchDarkly keys, JWT secrets, DB
  passwords) into chat, logs, or anywhere outside their designated gitignored
  file. Validate credentials by checking HTTP status codes, not by echoing
  them.
- **A clean exit code does not mean setup is complete.** Bash-tool stdin is
  EOF, not a TTY, so `fleetcom-onboard.sh`'s interactive `read` prompts
  degrade safely instead of hanging — but that means real gaps get silently
  skipped in that mode: a missing repo isn't auto-cloned (only warned
  about), DB-seed prompts default to skip, LaunchDarkly-key prompts warn
  and skip. After running onboarding non-interactively, check
  `local.conf` / `cascade/.env` / the actual repo directories directly to
  see what didn't get filled in, and close those gaps yourself: `gh repo
  clone soxhub/<repo> <path>`, write `local.conf` paths directly, ask the
  human for 1Password-sourced values when one is genuinely needed.
- **Cascade env var changes require recreating containers, not restarting
  them.** `cascade/.env` values are baked into `web`/`ws` at container
  *creation* via Compose's variable substitution — `docker-compose restart
  web` will NOT pick up an edited value. Use `docker-compose up -d
  --force-recreate web ws` (or just `docker-compose up -d`, which Compose
  auto-recreates once it detects the config changed).

## Running the scripts

| Situation | Command |
|---|---|
| First-time setup on this machine | `./fleetcom-onboard.sh` |
| Repo paths changed / re-onboarding | `./fleetcom-onboard.sh --reconfigure` |
| Boot everything (skips what's already up) | `./fleetcom-start-all.sh` |
| Boot / stop / bounce ONE stack | `./fleetcom start\|stop\|restart <midship\|auditboard\|cascade>` |
| Check port/health status | `./fleetcom-doctor.sh` |
| Watch backend logs | `./fleetcom-logs.sh` |
| Full bounce of all three stacks | `./fleetcom-restart-all.sh` |
| Stop all three stacks | `./fleetcom-stop-all.sh` |
| Hand a directive to a running supervisor Claude | `./fleetcom tell "<msg>"` |

## Supervisor mode (Claude orchestrating the fleet)

Claude is the fleet's supervisor. If you're running **inside the
`fleetcom-logs` tmux session** (check:
`[ "$(tmux display-message -p '#S' 2>/dev/null)" = fleetcom-logs ]`), that
session is your own home. The lifecycle verbs auto-protect it:

- `./fleetcom stop`/`restart` detect this session and **keep it alive** (they
  skip the log-view teardown), so they won't tear you down mid-command. The dev
  daemons `start-all` launches also survive the command exiting — so a plain
  `./fleetcom restart [stack]` is safe here.
- A **per-stack** bounce (`restart cascade`) is quick — run it synchronously.
  A **full-fleet** restart takes minutes, so run it in the **background** to
  stay responsive, then watch `./fleetcom doctor` for the stacks coming back.
  Prefer a single-stack bounce when only one stack is broken (lower blast
  radius).

An **external** Claude (not in the tmux) drives the fleet the same way with
synchronous restarts, and can hand work to a running supervisor with
`./fleetcom tell "<directive>"` (or launch one with `./fleetcom claude`). Full
role: `CLAUDE.md` in the repo root.

## The self-heal loop

1. Run `./fleetcom-doctor.sh` for a full port/health report — this is the
   ground truth, not assumptions.
2. For every `✗` (down) or `?` (unexpected holder) line, cross-reference
   against `README.md`'s **Troubleshooting** and **Known edge cases**
   sections. Most failure modes this stack has ever hit are already
   documented there with a named cause and fix.
3. Apply the matching fix, respecting the hard rules above.
4. Re-run `./fleetcom-doctor.sh`. Repeat until clean, or until a fix stops
   making progress.
5. If a failure doesn't match anything in README: pull concrete evidence —
   the relevant tail of `logs/*.log`, or `docker logs <container> --tail
   50` for a containerized service — before reporting back. Hand the human
   a specific finding ("auditboard-frontend's login app is crashing with
   `<exact error>`"), never a vague "something's wrong."

## Diagnosis index

A quick map from what `fleetcom-doctor.sh` / a crash actually shows to where
the fix lives in `README.md` — read the full entry there before acting, this
is just the index:

| Symptom | README section |
|---|---|
| AB login page stalls, DevTools shows `api/v1/config` → 400 | Troubleshooting → "AB app stalls at 'Loading appears to be stalled'" (stale `g_state` cookie from Midship's Google Sign-In) |
| `EADDRINUSE :9004` after editing auditboard-backend | Troubleshooting → "AB API v2 serves stale code" |
| **9002 and 9006 both NOT LISTENING together** | Troubleshooting → "AB Caddy (9002) and client Vite (9006) both go down together" — one turbo process group; check `logs/ab-client.log` for the real crash (often a pnpm store corruption `fleetcom-onboard.sh` already auto-repairs) |
| AB Workflows/Automations page looks unconfigured | Troubleshooting → "Workflows page is empty" (Analytics feature toggle, app-state not env-state — re-check after every reseed) |
| Automations: "RangeError: Invalid key length" | Troubleshooting → decrypt key rotation entry — re-run `fleetcom-onboard.sh`, restart AB API + integrations-extract |
| Hatchet (1337/7077) NOT LISTENING | Troubleshooting → re-run `fleetcom-onboard.sh` |
| `start-background`: "network … not found" | Troubleshooting → network-churn self-heal (start-all already retries this automatically) |
| Browser: `Unhandled Rejection (LaunchDarklyFlagFetchError)... 401` | Known edge cases → LD credentials present but wrong/swapped — hand-edit `cascade/.env`, then **recreate** (not restart) `web`/`ws` |
| Cascade client crashes fetching flags, lands on `/404` | Known edge cases → LD credentials **missing** from `cascade/.env` |
| Cascade→AB Automations calls 401 | Known edge cases → JWT audience mismatch, `BASE_URL` override |
| Anything not listed here | Fall back to step 5 of the self-heal loop above |

## Reference

`fleetcom-doctor.sh` and `fleetcom-start-all.sh` are the executable source of
truth for exact commands and current port map — read them directly if this
skill or README.md seem stale relative to what's actually in the repo.
