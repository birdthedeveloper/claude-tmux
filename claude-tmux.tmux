#!/usr/bin/env bash
# TPM entrypoint: option defaults, the window icon format, tmux hooks and key bindings.
o=@bird_claude_tmux
dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Sets a global option unless the user already set it.
default() { [[ -n $(tmux show -gqv "$1") ]] || tmux set -g "$1" "$2"; }

# Nerd Font: nf-md-robot, nf-fa-hourglass_half, nf-fa-question_circle, nf-fa-check_circle.
default ${o}_icon_idle $'\xf3\xb0\x9a\xa9'
default ${o}_icon_working $'\xef\x89\x92'
default ${o}_icon_needs_input $'\xef\x81\x99'
default ${o}_icon_done $'\xef\x81\x98'
default ${o}_process claude
default ${o}_key A
default ${o}_sync_title on

# One word per Claude pane of the window: its state, or idle before any hook.
states="#{P:#{?#{==:#{pane_current_command},#{${o}_process}},#{?#{${o}_state},#{${o}_state},idle} ,}}"
branch() { printf '#{?#{m:*%s*,%s}, #{%s_icon_%s},' "$1" "$states" "$o" "${1/-/_}"; }
tmux set -g ${o}_window_icon "$(branch needs-input)$(branch 'done')$(branch working)$(branch idle)}}}}"

# Clears done on the pane that gets focus (decision 3); the fixed index makes reloads idempotent.
reset="if -F '#{==:#{${o}_state},done}' 'set -p ${o}_state idle'"
for h in pane-focus-in window-pane-changed session-window-changed client-session-changed; do
  tmux set-hook -g "${h}[4247]" "$reset"
done

# Name sync: an active Claude pane with a "<glyph> <topic>" title names its window, unless you renamed it (decision 4).
topic='#{s/^[^ -~]+ //:pane_title}'
claude_pane="#{&&:#{pane_active},#{&&:#{==:#{pane_current_command},#{${o}_process}},#{m/r:^[^ -~]+ .,#{pane_title}}}}"
owned="#{||:#{automatic-rename},#{==:#{window_name},#{${o}_synced_name}}}"
changed="#{&&:#{!=:$topic,#{window_name}},#{!=:$topic,Claude Code}}"
sync="if -F '#{&&:$claude_pane,#{&&:$owned,$changed}}' \"set -wF ${o}_synced_name '$topic' ; rename-window '$topic'\""
if [[ $(tmux show -gv ${o}_sync_title) == on ]]; then
  tmux set-hook -g 'pane-title-changed[4247]' "$sync" \; set-hook -g 'window-pane-changed[4248]' "$sync"
else
  tmux set-hook -gu 'pane-title-changed[4247]' \; set-hook -gu 'window-pane-changed[4248]'
fi

# Key table on prefix + @bird_claude_tmux_key; fork variants (decision 8).
tmux bind-key "$(tmux show -gv ${o}_key)" switch-client -T bird_claude_tmux
tmux bind-key -T bird_claude_tmux '|' run-shell -b "'$dir/scripts/fork.sh' split '#{pane_id}' '#{client_name}'"
tmux bind-key -T bird_claude_tmux c run-shell -b "'$dir/scripts/fork.sh' window '#{pane_id}' '#{client_name}'"
tmux bind-key -T bird_claude_tmux f run-shell -b "'$dir/scripts/fork.sh' float '#{pane_id}' '#{client_name}'"
