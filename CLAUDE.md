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

`stack` ∈ `midship | auditboard | cascade` (omit = all three).

Before non-trivial changes to this stack, read README's Troubleshooting/Known
edge cases and use the `fleetcom-doctor` skill — most failure modes are already
documented with a named cause and fix.
