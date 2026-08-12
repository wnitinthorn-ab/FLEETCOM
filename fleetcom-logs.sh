#!/bin/bash
# FLEETCOM: live backend logs — tmux 2x2 grid OR four separate Terminal windows.
#   fleetcom-logs.sh             open (first run asks which view you prefer)
#   fleetcom-logs.sh --tmux      switch to the tmux grid (persisted)
#   fleetcom-logs.sh --windows   switch to separate Terminal windows (persisted)
#   fleetcom-logs.sh --kill      tear the tmux session down (windows: close them)
# Streams: optro-api | midship-api | cascade (docker) | alerts (ERROR/WARN only).
# Auto-opened by fleetcom-start-all.sh (skip with --no-logs).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# Capture an explicit env LOGS_VIEW BEFORE sourcing paths.sh — paths.sh sources
# local.conf, which assigns LOGS_VIEW and would otherwise clobber a caller's
# `LOGS_VIEW=tmux fleetcom-logs.sh` override (fleetcom-start-claude.sh relies on
# this to force tmux without persisting the choice to local.conf).
_ENV_LOGS_VIEW="${LOGS_VIEW:-}"
. "$HERE/paths.sh"
LOGS="$HERE/logs"
SESSION="fleetcom-logs"
CASCADE_COMPOSE="docker-compose -f docker-compose.yml -f docker-compose-build.yml -f docker-compose.override.yml"

say() { printf '\033[36m[logs]\033[0m %s\n' "$*"; }

# Close any spawned Terminal.app windows: the tmux grid's outer window
# (titled "$SESSION") and/or the separate-window titles. Each arg is a
# window-name substring to match — the exact win-<name>.command filename
# Terminal shows for the running script, NOT the bare label ("cascade",
# "optro-api"), which could collide with an unrelated window/tab you named
# yourself.
#
# We loop and close each matching window individually so Terminal shows its
# own "terminate running processes?" confirmation once per window — the user
# clicks through each. (An earlier version added our own summary dialog first
# and then closed the whole set in one `close (every window whose ...)` call;
# that reliably prompted for only the first window and left the rest silently
# open, so the user didn't know they could close them. Terminal's per-window
# sheet can't be customized or auto-dismissed without Accessibility access,
# which this doesn't ask for.) Skip if Terminal.app isn't running.
close_terminal_windows() {
	# FLEETCOM_NONINTERACTIVE: automated callers (e.g. fleetcom-start-claude.sh's
	# full restart) set this to skip window-closing entirely — the tmux session
	# is already killed by the --kill path before this runs, so we just leave any
	# Terminal windows in place rather than firing close prompts no one's watching.
	[ -n "${FLEETCOM_NONINTERACTIVE:-}" ] && return 0
	pgrep -xq Terminal || return 0
	local filter="" t
	for t in "$@"; do
		filter="${filter:+$filter or }name contains \"$t\""
	done
	osascript -e "
tell application \"Terminal\"
	set winList to every window whose ($filter)
	repeat with w in winList
		close w
	end repeat
end tell" >/dev/null 2>&1 || true
}

save_mode() { # persist LOGS_VIEW in local.conf
	if grep -q "^LOGS_VIEW=" "$HERE/local.conf" 2>/dev/null; then
		sed -i '' "s|^LOGS_VIEW=.*|LOGS_VIEW=\"$1\"|" "$HERE/local.conf"
	else
		printf 'LOGS_VIEW="%s"\n' "$1" >> "$HERE/local.conf"
	fi
}

MODE="${_ENV_LOGS_VIEW:-${LOGS_VIEW:-}}"   # env override wins over local.conf's saved value
case "${1:-}" in
	--tmux)    MODE=tmux;    save_mode tmux;    say "log view set to tmux (saved to local.conf)" ;;
	--windows) MODE=windows; save_mode windows; say "log view set to separate windows (saved to local.conf)" ;;
	--kill)
		if tmux kill-session -t "$SESSION" 2>/dev/null; then say "tmux log session closed"; else say "no tmux log session running"; fi
		close_terminal_windows "$SESSION" win-optro-api.command win-midship-api.command win-cascade.command win-alerts.command win-doctor.command
		say "log window teardown done — click 'Terminate'/'Close' on each Terminal prompt if asked"
		exit 0
	;;
esac

# first run: ask which view the user prefers, remember the answer
if [ -z "$MODE" ]; then
	if [ -t 0 ]; then
		read -r -p "[logs] View backend logs in [t]mux panes (one window, 2x2 grid) or separate Terminal [w]indows? [T/w] " v || true
		case "${v:-}" in [Ww]*) MODE=windows ;; *) MODE=tmux ;; esac
		save_mode "$MODE"
		say "saved to local.conf — switch anytime: fleetcom-logs.sh --tmux | --windows"
	else
		MODE=tmux
	fi
fi

# tmux view without tmux installed -> offer to install it, else fall back to
# windows. ensure_tmux (paths.sh) does the prompt/install; a non-zero return
# (declined / no brew / no TTY) means "use windows". This one spot also covers
# `fleetcom start --tmux` / `restart --tmux`, which reach here via LOGS_VIEW=tmux.
if [ "$MODE" = "tmux" ] && ! ensure_tmux "the tmux log grid"; then
	say "using separate Terminal windows instead (brew install tmux for the 2x2 grid)"
	MODE=windows
fi

mkdir -p "$LOGS"
touch "$LOGS/ab-api.log" "$LOGS/midship-api.log"

# tail -F (capital) survives start-all truncating the logs on restart. Cascade
# has no host log file, so it streams from docker — but `docker-compose logs -f`
# EXITS when its containers are torn down (e.g. a restart), and unlike tail -F
# it won't re-attach on its own. So wrap the cascade stream in a re-follow loop:
# when the containers come back it reconnects, giving the pane the same
# restart-resilience as the tail -F panes. (The pane's Ctrl-C trap still wins —
# SIGINT breaks the loop and drops to a shell, per wrap().)
OPTRO_CMD="tail -n 80 -F '$LOGS/ab-api.log'"
MIDSHIP_CMD="tail -n 80 -F '$LOGS/midship-api.log'"
CASCADE_CMD="cd '$CASCADE_DIR' && while :; do $CASCADE_COMPOSE logs -f --tail 80 web ws c3 c3manager; echo '[cascade logs detached — containers restarting? re-following in 2s (Ctrl-C for a shell)]'; sleep 2; done"
ALERTS_CMD="{ tail -n 0 -F '$LOGS/ab-api.log' '$LOGS/midship-api.log' & { cd '$CASCADE_DIR' && while :; do $CASCADE_COMPOSE logs -f --tail 0 web ws c3 c3manager 2>&1; sleep 2; done; } & wait; } | grep --line-buffered -iE '(errors?|warn(ing)?|fatal|exceptions?|traceback)[: ]'"
# doctor: live port/health report, refreshed as services come up and down.
# `watch` isn't on macOS by default, so fall back to a clear+sleep loop (both
# preserve doctor's color). `|| true` so a non-zero doctor run (some check
# failing — the normal case while booting) doesn't stop the loop.
if command -v watch >/dev/null 2>&1; then
	DOCTOR_CMD="watch -c -n 10 '$HERE/fleetcom-doctor.sh'"
else
	DOCTOR_CMD="while :; do clear; '$HERE/fleetcom-doctor.sh' || true; printf '\n(doctor — refreshing every 10s; Ctrl-C to stop. brew install watch for a nicer view)\n'; sleep 10; done"
fi

# Wrap a stream command so the pane/window stays usable instead of dying:
#  - cd into the stream's repo first, so you land somewhere you can work
#  - trap INT so Ctrl-C stops the stream and drops into an interactive shell
#    in that repo, rather than killing the pane (a non-interactive shell
#    aborts its whole command list when its foreground child dies on SIGINT,
#    which is why an un-trapped pane closes on Ctrl-C)
#  - after the stream ends (or Ctrl-C), exec the user's interactive shell in
#    the repo dir; type `exit` there to actually close the pane/window
# The exec reconnects std{in,out,err} to /dev/tty: a piped stream (alerts)
# otherwise leaves the shell's stdout pointing at the dead pipe, so its
# prompt hooks (vcs_info/direnv) spew "broken pipe". $SHELL is resolved at
# runtime inside the pane (the user's login shell).
wrap() { # cmd, workdir
	local dir="${2:-$HOME}"
	printf "cd '%s' 2>/dev/null || true; trap 'exec \"\${SHELL:-/bin/bash}\" </dev/tty >/dev/tty 2>&1' INT; %s; echo; echo '[stream ended — shell in %s; type exit to close]'; exec \"\${SHELL:-/bin/bash}\" </dev/tty >/dev/tty 2>&1" "$dir" "$1" "$dir"
}

# ---------------------------------------------------------------- windows ---
if [ "$MODE" = "windows" ]; then
	# branch-dir (4th arg, optional) only enriches the DISPLAYED title. The
	# win-<name>.command filename keeps the bare name: --kill closes windows by
	# matching those exact filenames (see close_terminal_windows above), so
	# folding a branch into $1 would strand every window it opened.
	open_win() { # name, command, workdir, [branch-dir]
		local f="$LOGS/win-$1.command" title
		title="$(title_with_branch "$1" "${4:-}")"
		{
			printf '#!/bin/bash\n'
			printf 'printf "\\033]0;%s\\007"\n' "$title"   # window title
			printf 'clear\n'
			printf '%s\n' "$(wrap "$2" "$3")"
		} > "$f"
		chmod +x "$f"
		open "$f"
	}
	open_win optro-api   "$OPTRO_CMD"   "$AB_BACKEND_DIR"             "$AB_BACKEND_DIR"
	open_win midship-api "$MIDSHIP_CMD" "$MIDSHIP_TURBO_BROCCOLI_DIR" "$MIDSHIP_TURBO_BROCCOLI_DIR"
	open_win cascade     "$CASCADE_CMD" "$CASCADE_DIR"                "$CASCADE_DIR"
	open_win alerts      "$ALERTS_CMD"  "$HERE"
	open_win doctor      "$DOCTOR_CMD"  "$HERE"
	say "opened 5 Terminal windows (re-open any later from $LOGS/win-*.command; Ctrl-C drops to a shell in that repo, type exit to close)"
	exit 0
fi

# ------------------------------------------------------------------- tmux ---
# already running? just (re)attach
if tmux has-session -t "$SESSION" 2>/dev/null; then
	if [ ! -t 0 ]; then say "session already running — attach with ./fleetcom-logs.sh"; exit 0; fi
	if [ -n "${TMUX:-}" ]; then
		exec tmux switch-client -t "$SESSION"
	else
		printf '\033]0;%s\007' "$SESSION"   # outer window title, so --kill/stop-all can find and close it
		exec tmux attach -t "$SESSION"
	fi
fi

# capture stable pane IDs — splits renumber positional indexes, IDs never change
P_OPTRO=$(tmux new-session  -d -s "$SESSION" -n backends -P -F '#{pane_id}' "$(wrap "$OPTRO_CMD"   "$AB_BACKEND_DIR")")
P_MIDSHIP=$(tmux split-window -h -t "$P_OPTRO"   -P -F '#{pane_id}' "$(wrap "$MIDSHIP_CMD" "$MIDSHIP_TURBO_BROCCOLI_DIR")")
P_CASCADE=$(tmux split-window -v -t "$P_OPTRO"   -P -F '#{pane_id}' "$(wrap "$CASCADE_CMD" "$CASCADE_DIR")")
P_ALERTS=$(tmux split-window  -v -t "$P_MIDSHIP" -P -F '#{pane_id}' "$(wrap "$ALERTS_CMD"  "$HERE")")
P_DOCTOR=$(tmux split-window  -v -t "$P_CASCADE" -P -F '#{pane_id}' "$(wrap "$DOCTOR_CMD"  "$HERE")")
tmux select-layout -t "$SESSION:backends" tiled

# Repo-backed streams carry the branch they're running: "cascade (main)". Read
# once, here — a title is static, so it reflects the checkout as of session
# build; rebuild the view (fleetcom logs) after switching branches. alerts and
# doctor get no branch: they aren't a repo's stream (alerts spans all three,
# doctor is a health report), and "alerts (ERROR/WARN)" is already parenthesized.
tmux select-pane -t "$P_OPTRO"   -T "$(title_with_branch optro-api   "$AB_BACKEND_DIR")"
tmux select-pane -t "$P_MIDSHIP" -T "$(title_with_branch midship-api "$MIDSHIP_TURBO_BROCCOLI_DIR")"
tmux select-pane -t "$P_CASCADE" -T "$(title_with_branch cascade     "$CASCADE_DIR")"
tmux select-pane -t "$P_ALERTS"  -T "alerts (ERROR/WARN)"
tmux select-pane -t "$P_DOCTOR"  -T "doctor"
tmux set-option  -t "$SESSION" pane-border-status top
tmux set-option  -t "$SESSION" mouse on
tmux set-option  -t "$SESSION" status-right-length 60
tmux set-option  -t "$SESSION" status-right "Ctrl-b d = detach · fleetcom-logs.sh --kill = close"

if [ ! -t 0 ]; then
	say "log session created — attach with ./fleetcom-logs.sh"
	exit 0
fi
if [ -n "${TMUX:-}" ]; then exec tmux switch-client -t "$SESSION"; else exec tmux attach -t "$SESSION"; fi
