#!/usr/bin/env bash
# Claude Code hook: writes the state of the Claude in $TMUX_PANE into pane options.
ts=${EPOCHREALTIME/[.,]/}
[[ -n ${TMUX_PANE:-} ]] || exit 0
exec >/dev/null 2>&1

o=@bird_claude_tmux
p=$TMUX_PANE

# Only the Claude on the pane's tty may write; a nested Claude has no tty.
tty=$(ps -o tty= -p "${CLAUDE_PID:-}")
tty=${tty//[^A-Za-z0-9\/]/}
[[ -n $tty ]] || exit 0

event='' source='' sid='' cwd='' tool='' ntype='' bg=''
eval "$(jq -r '@sh "event=\(.hook_event_name // "") source=\(.source // "") sid=\(.session_id // "") cwd=\(.cwd // "") tool=\(.tool_name // "") ntype=\(.notification_type // "") bg=\(any(.background_tasks[]?; .type == "subagent" or .type == "workflow"))"')"
sid=${sid//[^A-Za-z0-9-]/}
tool=${tool//[^A-Za-z0-9_-]/_}

# Quotes a value for the tmux command parser.
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# True if a focused client shows this pane (decision 10).
looking() {
  local pane flags
  while read -r pane flags; do
    [[ $pane == "$p" && $flags == *focused* ]] && return 0
  done < <(tmux list-clients -F '#{pane_id} #{client_flags}')
  return 1
}

# Decision 16: a status-line message when the pane starts to need input, unless you look at it.
notify() {
  looking && return
  printf "if -F -t %s '#{!=:#{%s_state},needs-input}' \"display-message -t %s -d 4000 'Claude needs input in #{session_name}:#{window_index} #{window_name}%s'\" ; " \
    "$p" "$o" "$p" "${tool:+ ($tool)}"
}

cond=1
case $event in
  SessionStart)
    cmd="set -p -t $p ${o}_cwd $(q "$cwd")"
    [[ $source == compact ]] || cmd+=" ; set -p -t $p ${o}_state idle ; set -pu -t $p ${o}_pending"
    ;;
  UserPromptSubmit)
    cmd="set -p -t $p ${o}_state working ; set -pu -t $p ${o}_pending"
    ;;
  PostToolUse | PostToolUseFailure | PermissionDenied)
    # While a tool waits for approval, only a result of that tool clears it (decision 13).
    cond="#{?#{${o}_pending},#{==:#{${o}_pending},$tool},1}"
    cmd="set -p -t $p ${o}_state working ; set -pu -t $p ${o}_pending"
    ;;
  PreToolUse | PermissionRequest)
    [[ -n $tool ]] || exit 0
    [[ $event == PermissionRequest || $tool == AskUserQuestion || $tool == ExitPlanMode ]] || exit 0
    cmd="$(notify)set -p -t $p ${o}_state needs-input ; set -p -t $p ${o}_pending $tool"
    ;;
  Notification)
    [[ $ntype == permission_prompt || $ntype == elicitation_dialog ]] || exit 0
    cmd="$(notify)set -p -t $p ${o}_state needs-input"
    ;;
  Stop | StopFailure)
    if [[ $event == Stop && $bg == true ]]; then
      state=working
    elif looking; then
      state=idle
    else
      state='done'
    fi
    cmd="set -p -t $p ${o}_state $state ; set -pu -t $p ${o}_pending"
    ;;
  SessionEnd)
    cmd="set -pu -t $p ${o}_state ; set -pu -t $p ${o}_session_id ; set -pu -t $p ${o}_cwd ; set -pu -t $p ${o}_pending"
    ;;
  *)
    exit 0
    ;;
esac
[[ -n $sid && $event != SessionEnd ]] && cmd+=" ; set -p -t $p ${o}_session_id $sid"

# Compare-and-set in the server: right tty, newer than the last write, pending rule.
tmux if -t "$p" -F "#{&&:#{==:#{pane_tty},/dev/$tty},#{&&:#{e|<:#{?#{${o}_ts},#{${o}_ts},0},$ts},$cond}}" \
  "set -p -t $p ${o}_ts $ts ; $cmd"
exit 0
