#!/usr/bin/env bash
# Forks the Claude session of a pane; usage: fork.sh split|window|float <pane> [client]
mode=$1 pane=$2 client=${3:-}
o=@bird_claude_tmux
s=$'\x1f'

IFS=$s read -r cmd proc sid cwd path wid shell name < <(
  tmux display -p -t "$pane" "#{pane_current_command}$s#{${o}_process}$s#{${o}_session_id}$s#{${o}_cwd}$s#{pane_current_path}$s#{window_id}$s#{default-shell}$s#{window_name}"
)
if [[ -z ${cmd:-} || $cmd != "$proc" || -z $sid ]]; then
  msg=(display-message)
  [[ -n $client ]] && msg+=(-c "$client")
  tmux "${msg[@]}" "no Claude session in this pane"
  exit 0
fi

# Decision 9: one -fork suffix, however often you fork.
name="${name%-fork}-fork"
shell=${shell:-${SHELL:-/bin/sh}}
# Interactive shell: loads your rc files, gives claude its own process group, stays after exit.
# shellcheck disable=SC2016
run=("$shell" -ic 'claude --resume "$1" --fork-session -n "$2"; exec "$0"' "$shell" "$sid" "$name")

case $mode in
  split) tmux split-window -h -t "$pane" -c "${cwd:-$path}" "${run[@]}" ;;
  window) tmux new-window -a -t "$wid" -c "${cwd:-$path}" "${run[@]}" ;;
  float) tmux new-pane -t "$pane" -x 60% -y 60% -c "${cwd:-$path}" "${run[@]}" ;;
esac
