#!/usr/bin/env bash
# Jumps to the next Claude pane that needs attention, needs-input before done; usage: jump.sh <pane> [client]
cur=$1 client=${2:-}
o=@bird_claude_tmux
c=()
[[ -n $client ]] && c=(-c "$client")

need=() fin=()
while read -r state id; do
  if [[ $state == needs-input ]]; then need+=("$id"); else fin+=("$id"); fi
done < <(tmux list-panes -a -F "#{${o}_state} #{pane_id}" \
  -f "#{&&:#{==:#{pane_current_command},#{${o}_process}},#{m/r:^(needs-input|done)\$,#{${o}_state}}}")
list=("${need[@]}" "${fin[@]}")
if ((${#list[@]} == 0)); then
  tmux display-message "${c[@]}" "no Claude pane needs attention"
  exit 0
fi

# Pressing again moves on: the entry after the current pane, else the first one.
next=${list[0]}
for i in "${!list[@]}"; do
  [[ ${list[i]} == "$cur" ]] && next=${list[(i + 1) % ${#list[@]}]}
done
tmux switch-client "${c[@]}" -t "$next"
