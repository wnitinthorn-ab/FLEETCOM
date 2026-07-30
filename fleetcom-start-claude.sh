#!/bin/bash
# FLEETCOM: full restart (fleetcom-stop-all.sh then fleetcom-start-all.sh),
# plus a large Claude Code pane added to the tmux 'backends' window, alongside
# (not hidden behind) the 4 log panes — Claude gets ~70% width, logs are
# squeezed into a strip on the right. Claude pulls logs on demand
# (tmux capture-pane) rather than tailing continuously.
#   fleetcom-start-claude.sh              stop + boot + add claude pane
#   fleetcom-start-claude.sh --no-restart  skip stop/start; just add the claude
#                                          pane to a running (or freshly built)
#                                          tmux log session
# Requires the claude CLI. tmux is preferred (Claude tiled beside the log
# panes); if it's missing you're offered a `brew install tmux`, and declining
# falls back to a plain restart with the logs in separate Terminal windows and
# Claude launched in this terminal (reading the log FILES instead of panes).
# With tmux it always uses the tmux log view regardless of the LOGS_VIEW saved
# in local.conf — forced via an env override (fleetcom-logs.sh honors an
# explicit LOGS_VIEW env over local.conf) and NOT persisted.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/paths.sh"
LOGS="$HERE/logs"
SESSION="fleetcom-logs"
MAP="$LOGS/tmux-panes.md"

say() { printf '\033[36m[start-claude]\033[0m %s\n' "$*"; }

# Reorder the right-hand log column (top→bottom) after main-vertical. main-vertical
# stacks the non-main panes by internal order, which the earlier splits + swap
# leave in an arbitrary sequence; a selection sort with swap-pane (which
# physically moves a pane's position) puts them where we want, no re-layout
# needed. Titles are matched by prefix so "alerts (ERROR/WARN)" matches "alerts".
reorder_backends() { # window
	local win="$1" i want slot want_id
	local -a order=(doctor midship-api optro-api cascade alerts)
	for i in "${!order[@]}"; do
		want="${order[$i]}"
		slot=$(tmux list-panes -t "$win" -F '#{pane_top}|#{pane_id}|#{pane_title}' \
			| grep -v '|claude$' | sort -n -t'|' -k1,1 | awk -F'|' -v n="$i" 'NR==n+1{print $2}') || true
		want_id=$(tmux list-panes -t "$win" -F '#{pane_id}|#{pane_title}' \
			| awk -F'|' -v t="$want" 'index($2,t)==1{print $1; exit}') || true
		# Use a real if, NOT `A && B && C && swap`: under the caller's `set -e`, an
		# `&&` chain whose final test is false makes this the loop's last command
		# with a non-zero status, so the function returns non-zero and aborts the
		# whole script right here (which is exactly what happened — reorder ran but
		# nothing after it did). The if always leaves the function returning 0.
		if [ -n "$slot" ] && [ -n "$want_id" ] && [ "$slot" != "$want_id" ]; then
			tmux swap-pane -s "$want_id" -t "$slot"
		fi
	done
	return 0
}

command -v claude >/dev/null || { say "ERROR: claude CLI not found on PATH"; exit 1; }
# tmux gives the Claude-beside-logs layout (Claude in one pane, log streams
# tiled beside it). If it's missing, ensure_tmux (paths.sh) offers to install
# it; if that's declined or unavailable we fall back below to a plain restart
# with the logs in separate Terminal windows and Claude launched in this
# terminal instead. The claude CLI itself has no fallback — it's required.
HAVE_TMUX=1
ensure_tmux "the Claude-beside-logs layout" || HAVE_TMUX=0

# Don't run from inside the log session we're about to tear down: the restart
# kills the 'fleetcom-logs' tmux session, which would pull the rug out from
# under this very script (dead pty -> writes fail under set -e). Run it from a
# separate terminal window instead. (This is cleaner than trapping SIGHUP and
# hoping subsequent output still lands somewhere.)
if [ -n "${TMUX:-}" ] && [ "$(tmux display-message -p '#S' 2>/dev/null)" = "$SESSION" ]; then
	say "ERROR: don't run this from inside the '$SESSION' tmux session — it gets torn down during the restart."
	say "       Detach (Ctrl-b d) or open a separate terminal window, then re-run."
	exit 1
fi

# --- arg parsing: --no-restart is ours; everything else forwards to stop/start
RESTART=1
FWD=()
for a in "$@"; do
	case "$a" in
		--no-restart) RESTART=0 ;;
		*) FWD+=("$a") ;;
	esac
done
FWD_STR=""
[ ${#FWD[@]} -gt 0 ] && FWD_STR=" ${FWD[*]}"

# --- windows fallback: no tmux, so no "beside the logs" pane ----------------
# Can't tile Claude next to the logs without tmux, so degrade gracefully: run
# the restart normally (logs open as separate Terminal windows via start-all
# --windows), write a log-FILES map (no tmux panes to capture), then launch
# Claude in THIS terminal pointed at those files. Claude still helps — it just
# reads files rather than capturing panes.
if [ "$HAVE_TMUX" = 0 ]; then
	say "no tmux — restarting with logs in separate Terminal windows, then launching Claude here"
	if [ "$RESTART" = 1 ]; then
		"$HERE/fleetcom-stop-all.sh" ${FWD[@]+"${FWD[@]}"}
		"$HERE/fleetcom-start-all.sh" --windows ${FWD[@]+"${FWD[@]}"}
	fi
	{
		printf '# FLEETCOM log map (generated %s) — no tmux this run\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
		printf 'Read these log FILES on demand (do not tail continuously):\n\n'
		printf -- '- %s/ab-api.log            optro / AB API\n' "$LOGS"
		printf -- '- %s/midship-api.log       Midship API\n' "$LOGS"
		printf -- '- %s/midship-frontend.log  Midship frontend\n' "$LOGS"
		printf -- '- %s/ab-client.log         AB client (Caddy/login/client turbo group)\n' "$LOGS"
		printf -- '- %s/cascade-client.log    Cascade client\n' "$LOGS"
		printf '\nCascade backend has no log file — read it with:\n'
		printf '  cd %s && docker compose -f docker-compose.yml -f docker-compose-build.yml -f docker-compose.override.yml logs --tail 200 web ws c3 c3manager\n' "$CASCADE_DIR"
		printf '\nHealth report: %s/fleetcom-doctor.sh\n' "$HERE"
	} > "$MAP"
	say "log map -> $MAP"
	CLAUDE_PROMPT="Read $MAP for where the FLEETCOM logs live (no tmux this run — read the log files on demand instead of tailing continuously)."
	if [ -t 0 ]; then
		cd "$HERE" && exec claude "$CLAUDE_PROMPT"
	fi
	say "restart done — no TTY to launch Claude; run 'claude' in $HERE (see $MAP)"
	exit 0
fi

# Attach-first: build the tmux log session (+ claude pane) BEFORE the restart,
# then run the restart INSIDE the claude pane. The panes come up immediately and
# you watch the boot happen in them, instead of staring at a blank terminal
# while a slow (or wedged) start-all blocks — the old flow only attached after
# start-all returned, so a hung boot left you with no panes at all. On a restart
# we rebuild the session fresh; on --no-restart we reuse any existing one.
if [ "$RESTART" = 1 ]; then
	# Converge on a single fresh view: kill any existing log session AND close
	# its Terminal window(s) via --kill, so a previous grid attached in another
	# window isn't left orphaned when we build the new one. (A bare kill-session
	# would drop that window's attach but leave it dead-but-open.) Safe: this
	# runs before the current terminal attaches, so it won't close us.
	"$HERE/fleetcom-logs.sh" --kill
fi
if tmux has-session -t "$SESSION" 2>/dev/null; then
	say "reusing existing tmux log session"
else
	say "building tmux log session"
	LOGS_VIEW=tmux "$HERE/fleetcom-logs.sh" < /dev/null
fi

# --- claude pane -----------------------------------------------------------
# Lives in the same window as the 4 log panes (not a separate window you have
# to switch to). main-vertical layout: pane index 0 is the big "main" pane on
# the left (claude, 70% width), the rest tile in a strip on the right.
WINDOW="$SESSION:backends"
# Detect an existing claude pane by its title, not by pane count — the log
# window's pane count varies (4 log streams + a doctor pane, and more could be
# added later), so a count threshold is brittle.
CLAUDE_PANE=$(tmux list-panes -t "$WINDOW" -F '#{pane_id}:#{pane_title}' 2>/dev/null | awk -F: '$2=="claude"{print $1; exit}')
CLAUDE_PANE_IS_NEW=false
if [ -z "$CLAUDE_PANE" ]; then
	say "adding claude pane -> $WINDOW"
	CLAUDE_PANE=$(tmux split-window -t "$WINDOW" -c "$HERE" -P -F '#{pane_id}')
	FIRST_PANE=$(tmux list-panes -t "$WINDOW" -F '#{pane_id}' | head -1)
	# swap-pane moves the pane_id (and its content) together, not content-in-place —
	# so CLAUDE_PANE still identifies the claude pane after this, unchanged.
	if [ "$CLAUDE_PANE" != "$FIRST_PANE" ]; then
		tmux swap-pane -s "$CLAUDE_PANE" -t "$FIRST_PANE"
	fi
	tmux select-pane -t "$CLAUDE_PANE" -T "claude"
	tmux set-window-option -t "$WINDOW" main-pane-width 70%
	tmux select-layout -t "$WINDOW" main-vertical
	reorder_backends "$WINDOW"   # right column top→bottom: doctor, midship, optro, cascade, alerts
	CLAUDE_PANE_IS_NEW=true
else
	say "claude pane already present — reusing it (not re-launching claude)"
fi

# --- pane map: what each tmux pane exposes, for claude to read on startup ---
{
	printf '# FLEETCOM tmux pane map (generated %s)\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
	printf 'You are the FLEETCOM supervisor (running inside the fleetcom-logs tmux\n'
	printf 'session). ./fleetcom stop|restart [midship|auditboard|cascade] auto-\n'
	printf 'preserve this session, so you can restart the whole fleet or a single\n'
	printf 'stack without killing yourself (run a full-fleet restart in the\n'
	printf 'background; watch ./fleetcom doctor). See CLAUDE.md for the full role.\n\n'
	printf 'Pull a pane snapshot on demand — do not tail continuously:\n'
	printf '  tmux capture-pane -p -t <pane_id> -S -   (full scrollback)\n'
	printf '  tmux capture-pane -p -t <pane_id>        (visible screen only)\n\n'
	printf '## session: %s, window: backends (shares this window with the claude pane)\n' "$SESSION"
	tmux list-panes -t "$WINDOW" -F '- #{pane_id}  #{pane_title}' 2>/dev/null | grep -v '  claude$' || true
	printf '\n'
	if tmux has-session -t fleetcom-ab-api 2>/dev/null; then
		printf '## session: fleetcom-ab-api\n'
		tmux list-panes -t fleetcom-ab-api -F '- #{pane_id}  AB API (migrations + api/worker/cron)' 2>/dev/null || true
		printf '\n'
	fi
	printf '## log files (read directly, no tmux needed)\n'
	printf -- '- %s/ab-api.log\n' "$LOGS"
	printf -- '- %s/midship-api.log\n' "$LOGS"
	printf -- '- %s/midship-frontend.log\n' "$LOGS"
	printf -- '- %s/ab-client.log\n' "$LOGS"
	printf -- '- %s/cascade-client.log\n' "$LOGS"
	printf '\n(cascade web/ws/c3/c3manager have no log file — read via the "cascade" pane above,\nor: docker compose -f docker-compose.yml -f docker-compose-build.yml -f docker-compose.override.yml logs --tail 200 web)\n'
} > "$MAP"
say "pane map -> $MAP"

if [ "$CLAUDE_PANE_IS_NEW" = true ]; then
	CLAUDE_PROMPT="You are the FLEETCOM supervisor. Read $MAP for the tmux session/pane layout and CLAUDE.md for your role. Pull pane output on demand with tmux capture-pane -p -t <pane_id> instead of tailing continuously; restart the fleet or a single stack with ./fleetcom restart [stack] (auto-preserves this session; run a full-fleet restart in the background)."
	# On a restart, run stop+start IN the claude pane first (visible, with the log
	# panes showing the boot), then launch Claude. FLEETCOM_KEEP_LOGS keeps the log
	# session we're attached to alive through stop-all (it would otherwise kill it).
	# ';' not '&&' so a non-zero stop still proceeds to start, matching old behavior.
	PANE_CMD=""
	if [ "$RESTART" = 1 ]; then
		PANE_CMD="FLEETCOM_KEEP_LOGS=1 '$HERE/fleetcom-stop-all.sh'$FWD_STR; '$HERE/fleetcom-start-all.sh' --no-logs$FWD_STR; "
	fi
	PANE_CMD="${PANE_CMD}cd '$HERE' && claude \"$CLAUDE_PROMPT\""
	tmux send-keys -t "$CLAUDE_PANE" "$PANE_CMD" C-m
fi

say "done — attaching now; the restart (if any) runs live in the claude pane. Reattach later: tmux attach -t $SESSION"
if [ -t 0 ]; then
	printf '\033]0;%s\007' "$SESSION"   # window title, so a later fleetcom-stop-all can find/close it
	if [ -n "${TMUX:-}" ]; then tmux switch-client -t "$WINDOW"; else exec tmux attach -t "$WINDOW"; fi
fi
