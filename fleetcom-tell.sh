#!/bin/bash
# FLEETCOM: send a directive to the supervising Claude — the 'claude' pane in
# the fleetcom-logs tmux session. Lets a human, or another Claude session
# running OUTSIDE the tmux, hand a task to the in-tmux supervisor (which can see
# every log pane and knows the session-preserving restart) without switching to
# its pane.
#   fleetcom tell "cascade is wedged — restart just that stack and confirm"
#   fleetcom tell            # no message: just report whether a supervisor is up
set -euo pipefail

SESSION=fleetcom-logs
say() { printf '\033[36m[tell]\033[0m %s\n' "$*"; }

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
	say "no supervisor session ('$SESSION') is running."
	say "launch one with:  fleetcom claude   (adds a supervising Claude beside the live logs)"
	exit 1
fi

# Find the supervisor's Claude pane. The pane TITLE is unreliable — Claude Code
# overwrites the "claude" title fleetcom-start-claude.sh sets with a live
# activity string (OSC sequences) — so match on pane_current_command (the
# `claude`/`node` process), which is stable and unique here (every log pane runs
# zsh). Fall back to the title only if some setup keeps it. Never fall through to
# a log pane: if nothing matches, there's no supervisor to talk to.
PANE=$(tmux list-panes -t "$SESSION:backends" -F '#{pane_id}|#{pane_title}|#{pane_current_command}' 2>/dev/null \
	| awk -F'|' '$3=="claude"||$3=="node"{print $1; exit}')
[ -z "$PANE" ] && PANE=$(tmux list-panes -t "$SESSION:backends" -F '#{pane_id}|#{pane_title}' 2>/dev/null \
	| awk -F'|' '$2=="claude"{print $1; exit}')
if [ -z "$PANE" ]; then
	say "the '$SESSION' session is up but has no Claude pane (nothing running 'claude')."
	say "add one with:  fleetcom claude --no-restart"
	exit 1
fi

MSG="$*"
if [ -z "$MSG" ]; then
	say "supervisor is up (claude pane: $PANE)."
	say "pass a message to send it, e.g.:  fleetcom tell \"restart cascade and confirm it's healthy\""
	exit 0
fi

# Type the directive into the supervisor's prompt, then submit. -l sends the
# text literally (no key-name interpretation); a separate Enter submits it.
# Claude Code queues the input if it's mid-response.
tmux send-keys -t "$PANE" -l -- "$MSG"
tmux send-keys -t "$PANE" Enter
say "sent to supervisor (pane $PANE)."
