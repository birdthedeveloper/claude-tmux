#!/usr/bin/env bash
# fzf picker of the Claude panes in the current session (decision 17); also called as rows <session>, preview <pane>, toggle.
o=@bird_claude_tmux
s=$'\x1f'

# One line per Claude pane of the session: the hidden pane id, a tab, then window.pane, state icon, window name and topic.
rows() {
  local idle working needs fin id loc state name topic icon
  IFS=$s read -r idle working needs fin < <(
    tmux display -p "#{${o}_icon_idle}$s#{${o}_icon_working}$s#{${o}_icon_needs_input}$s#{${o}_icon_done}"
  )
  while IFS=$s read -r id loc state name topic; do
    case $state in
      needs-input) icon=$needs ;;
      'done') icon=$fin ;;
      working) icon=$working ;;
      *) icon=$idle ;;
    esac
    printf '%s\t%-6s %s  %-24s %s\n' "$id" "$loc" "$icon" "$name" "$topic"
  done < <(tmux list-panes -s -t "$1" -f "#{==:#{pane_current_command},#{${o}_process}}" \
    -F "#{pane_id}$s#{window_index}.#{pane_index}$s#{${o}_state}$s#{window_name}$s#{s/^[^ -~]+ //:pane_title}")
}

# The pane's screen, or all panes of its window while the preview label says window.
preview() {
  local p
  if [[ ${FZF_PREVIEW_LABEL:-} == *window* ]]; then
    for p in $(tmux list-panes -t "$1" -F '#{pane_id}'); do
      tmux display -p -t "$p" '──── #{pane_index}: #{pane_current_command}  #{pane_title}'
      tmux capture-pane -ep -t "$p"
    done
  else
    tmux capture-pane -ep -t "$1"
  fi
}

# ctrl-w (decision 11): flips the preview label, which tells preview what to show.
toggle() {
  if [[ ${FZF_PREVIEW_LABEL:-} == *window* ]]; then
    echo 'change-preview-label( pane )+refresh-preview'
  else
    echo 'change-preview-label( window )+refresh-preview'
  fi
}

case ${1:-} in
  rows) rows "$2"; exit 0 ;;
  preview) preview "$2"; exit 0 ;;
  toggle) toggle; exit 0 ;;
esac

if ! command -v fzf >/dev/null; then
  tmux display-message "claude-tmux: the picker needs fzf"
  exit 0
fi
printf -v me %q "${BASH_SOURCE[0]}"
# Inside the popup this is the session of the client that opened it.
session=$(tmux display -p '#{session_id}')
pick=$(rows "$session" | fzf --delimiter '\t' --with-nth 2.. --with-shell 'bash -c' --reverse \
  --header 'enter: switch   ctrl-w: pane / window preview' \
  --preview "$me preview {1}" --preview-label ' pane ' --preview-window 'right,60%' \
  --bind "ctrl-w:transform:$me toggle")
[[ -n $pick ]] && tmux switch-client -t "${pick%%$'\t'*}"
exit 0
