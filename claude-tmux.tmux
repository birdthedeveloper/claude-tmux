#!/usr/bin/env bash
# TPM entrypoint: option defaults, the window icon format and the done reset.
o=@bird_claude_tmux

# Sets a global option unless the user already set it.
default() { [[ -n $(tmux show -gqv "$1") ]] || tmux set -g "$1" "$2"; }

# Nerd Font: nf-md-robot, nf-fa-hourglass_half, nf-fa-question_circle, nf-fa-check_circle.
default ${o}_icon_idle $'\xf3\xb0\x9a\xa9'
default ${o}_icon_working $'\xef\x89\x92'
default ${o}_icon_needs_input $'\xef\x81\x99'
default ${o}_icon_done $'\xef\x81\x98'
default ${o}_process claude

# One word per Claude pane of the window: its state, or idle before any hook.
states="#{P:#{?#{==:#{pane_current_command},#{${o}_process}},#{?#{${o}_state},#{${o}_state},idle} ,}}"
branch() { printf '#{?#{m:*%s*,%s}, #{%s_icon_%s},' "$1" "$states" "$o" "${1/-/_}"; }
tmux set -g ${o}_window_icon "$(branch needs-input)$(branch 'done')$(branch working)$(branch idle)}}}}"

# Clears done on the pane that gets focus (decision 3); the fixed index makes reloads idempotent.
reset="if -F '#{==:#{${o}_state},done}' 'set -p ${o}_state idle'"
for h in pane-focus-in window-pane-changed session-window-changed client-session-changed; do
  tmux set-hook -g "${h}[4247]" "$reset"
done
