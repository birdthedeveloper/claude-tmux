#!/usr/bin/env bash
# Tests on a private tmux server with fake Claude processes; usage: tests/run.sh
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
sock=bird_claude_tmux_test
tmp=$(mktemp -d)
fails=0
py=''
sockpath=/nonexistent

tm() { env -u TMUX -u TMUX_PANE tmux -L "$sock" -f /dev/null "$@"; }

# Waits for the old server to exit, or a new client may connect to it while it dies.
kill_server() {
  local pid
  pid=$(tm display -p '#{pid}' 2>/dev/null) || return 0
  tm kill-server
  while kill -0 "$pid" 2>/dev/null; do sleep 0.01; done
}
cleanup() { detach; kill_server; rm -rf "${tmp:?}"; }
trap cleanup EXIT

# A fake claude must be a binary, or pane_current_command shows the interpreter.
ln -s "$(command -v sleep)" "$tmp/claude"
claude="$tmp/claude 1000"
plain="$(command -v sleep) 1000"

fail() { echo "FAIL $*"; fails=$((fails + 1)); }
assert() { local name=$1; shift; if "$@"; then echo "ok   $name"; else fail "$name"; fi; }

# Waits up to 1 s for the window icon to match, since tmux hooks run async.
expect() {
  local name=$1 target=$2 want=$3 got
  for _ in {1..50}; do
    got=$(tm display -p -t "$target" '#{E:@bird_claude_tmux_window_icon}')
    [[ $got == "$want" ]] && { echo "ok   $name"; return; }
    sleep 0.02
  done
  fail "$name: want [$want] got [$got]"
}

# Fresh server: window t:0 with one Claude pane %0, ASCII icons, plugin loaded.
setup() {
  detach
  kill_server
  tm new-session -d -s t -x 120 -y 40 "$claude"
  sockpath=$(tm display -p '#{socket_path}')
  # An empty socket path in $TMUX makes tmux fall back to the live server.
  [[ $sockpath == */"$sock" ]] || { echo "ABORT: test server didn't start"; exit 1; }
  tm set -g focus-events on
  [[ ${1:-} == glyphs ]] || tm set -g @bird_claude_tmux_icon_idle I \; set -g @bird_claude_tmux_icon_working W \
    \; set -g @bird_claude_tmux_icon_needs_input N \; set -g @bird_claude_tmux_icon_done D
  load
}
load() { env -u TMUX_PANE TMUX="$sockpath,0,0" bash "$root/claude-tmux.tmux"; }

# Runs hook.sh as the Claude of that pane would (or as process $3); it must print nothing.
hook() {
  local pane=$1 json=$2 pid out
  pid=${3:-$(tm display -p -t "$pane" '#{pane_pid}')}
  out=$(TMUX="$sockpath,0,0" TMUX_PANE=$pane CLAUDE_PID=$pid bash "$root/scripts/hook.sh" <<<"$json" 2>&1)
  [[ -z $out ]] || fail "hook.sh printed: $out"
}
ev() { hook "$1" "{\"hook_event_name\":\"$2\",\"session_id\":\"s-1\",\"cwd\":\"/tmp\"${3:+,$3}}" "${4:-}"; }
popt() { tm show -pv -t "$1" "@bird_claude_tmux_$2" 2>/dev/null; }

# Attaches a client through a pty, as a terminal would; it starts focused.
attach() {
  python3 - "$sock" <<'PY' &
import fcntl, os, pty, struct, sys, termios
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
    for k in ('TMUX', 'TMUX_PANE'):
        os.environ.pop(k, None)
    os.environ['TERM'] = 'xterm-256color'
    os.execvp('tmux', ['tmux', '-L', sys.argv[1], 'attach', '-t', 't'])
try:
    while os.read(fd, 65536):
        pass
except OSError:
    pass
PY
  py=$!
  for _ in {1..100}; do
    [[ -n $(tm list-clients) ]] && return
    sleep 0.02
  done
  fail "client did not attach"
}
detach() {
  [[ -n $py ]] || return 0
  kill "$py" 2>/dev/null
  wait "$py" 2>/dev/null
  py=''
}

echo "# states"
setup
tm new-window -d -t t:1 "$plain"
expect "no Claude pane shows nothing" t:1 ""
expect "Claude before any hook is idle" t:0 " I"
ev %0 UserPromptSubmit
expect "UserPromptSubmit gives working" t:0 " W"
ev %0 PermissionRequest '"tool_name":"Bash"'
expect "PermissionRequest gives needs-input" t:0 " N"
ev %0 Stop
expect "Stop without a client gives done" t:0 " D"
ev %0 SessionStart '"source":"startup"'
expect "SessionStart gives idle" t:0 " I"
ev %0 Notification '"notification_type":"permission_prompt"'
expect "permission_prompt gives needs-input" t:0 " N"
ev %0 UserPromptSubmit
ev %0 Notification '"notification_type":"idle_prompt"'
expect "idle_prompt is ignored" t:0 " W"
ev %0 PreToolUse '"tool_name":"Bash"'
expect "PreToolUse of a plain tool is ignored" t:0 " W"
ev %0 StopFailure
expect "StopFailure gives done" t:0 " D"

echo "# priority across panes"
setup
tm split-window -t t:0 "$claude"
ev %0 Stop
ev %1 PermissionRequest '"tool_name":"Bash"'
expect "done + needs-input gives needs-input" t:0 " N"
ev %1 UserPromptSubmit
expect "done + working gives done" t:0 " D"
ev %0 SessionStart '"source":"startup"'
expect "idle + working gives working" t:0 " W"

echo "# crashed Claude"
setup
tm split-window -t t:0 "bash --norc --noprofile -ic '$claude; exec $plain'"
ev %1 PermissionRequest '"tool_name":"Bash"'
expect "before the crash" t:0 " N"
pkill -9 -P "$(tm display -p -t %1 '#{pane_pid}')" -f "$tmp/claude"
expect "a killed Claude drops out" t:0 " I"

echo "# join-pane"
setup
tm new-window -d -t t:1 "$claude"
tm split-window -d -t t:1 "$plain"
ev %1 PermissionRequest '"tool_name":"Bash"'
ev %0 UserPromptSubmit
tm join-pane -d -s %1 -t t:0
expect "the joined pane counts in its new window" t:0 " N"
expect "the old window drops it" t:1 ""

echo "# done reset on focus"
setup
tm split-window -t t:0 "$claude"
ev %0 Stop
expect "done in the inactive pane" t:0 " D"
tm select-pane -t %0
expect "selecting the pane clears done" t:0 " I"
tm new-window -d -t t:1 "$claude"
ev %2 Stop
tm select-window -t t:1
expect "selecting the window clears done" t:1 " I"

echo "# Stop while you look at the pane"
setup
tm new-window -d -t t:1 "$claude"
attach
ev %0 Stop
expect "Stop in the focused pane gives idle" t:0 " I"
ev %1 Stop
expect "Stop in a pane you don't look at gives done" t:1 " D"
detach

echo "# ordering"
setup
ev %0 UserPromptSubmit
tm set -p -t %0 @bird_claude_tmux_ts 9999999999999999
ev %0 Stop
expect "a hook older than the last write is dropped" t:0 " W"

echo "# compaction"
setup
ev %0 UserPromptSubmit
ev %0 SessionStart '"source":"compact"'
expect "SessionStart compact keeps working" t:0 " W"
ev %0 SessionStart '"source":"resume"'
expect "SessionStart resume gives idle" t:0 " I"

echo "# pending approval"
setup
ev %0 PermissionRequest '"tool_name":"Bash"'
ev %0 PostToolUse '"tool_name":"Read"'
expect "another tool's result keeps needs-input" t:0 " N"
ev %0 PostToolUse '"tool_name":"Bash"'
expect "the same tool's result clears it" t:0 " W"
ev %0 PreToolUse '"tool_name":"AskUserQuestion"'
expect "AskUserQuestion gives needs-input" t:0 " N"
ev %0 PostToolUseFailure '"tool_name":"Bash"'
expect "another tool's failure keeps needs-input" t:0 " N"
ev %0 PostToolUse '"tool_name":"AskUserQuestion"'
expect "the answer clears it" t:0 " W"
ev %0 Notification '"notification_type":"elicitation_dialog"'
ev %0 PostToolUse '"tool_name":"Read"'
expect "with nothing pending any result clears needs-input" t:0 " W"

echo "# background tasks"
setup
ev %0 UserPromptSubmit
ev %0 Stop '"background_tasks":[{"type":"shell"},{"type":"subagent"}]'
expect "Stop with a subagent keeps working" t:0 " W"
ev %0 Stop '"background_tasks":[{"type":"workflow"}]'
expect "Stop with a workflow keeps working" t:0 " W"
ev %0 Stop '"background_tasks":[{"type":"shell"}]'
expect "Stop with only a shell gives done" t:0 " D"

echo "# owner check"
setup
tm new-window -d -t t:1 "$claude"
ev %0 UserPromptSubmit
ev %0 Stop '' "$(tm display -p -t %1 '#{pane_pid}')"
expect "a Claude on another tty can't write" t:0 " W"
setsid sleep 30 &
notty=$!
ev %0 Stop '' "$notty"
expect "a Claude without a tty can't write" t:0 " W"
kill "$notty"

echo "# session data"
setup
weird="/tmp/a b/it's \$HOME #{pane_id} ; x"
hook %0 "$(jq -nc --arg cwd "$weird" '{hook_event_name: "SessionStart", source: "startup", session_id: "abc-1", cwd: $cwd}')"
assert "SessionStart stores the session id" test "$(popt %0 session_id)" = abc-1
assert "cwd survives quoting" test "$(popt %0 cwd)" = "$weird"
hook %0 '{"hook_event_name":"UserPromptSubmit","session_id":"def-2"}'
assert "every event refreshes the session id" test "$(popt %0 session_id)" = def-2
hook %0 '{"hook_event_name":"SessionEnd","session_id":"def-2"}'
expect "SessionEnd leaves a plain Claude pane" t:0 " I"
assert "SessionEnd unsets state, session id and cwd" test -z "$(popt %0 state)$(popt %0 session_id)$(popt %0 cwd)"
assert "SessionEnd keeps the timestamp" test -n "$(popt %0 ts)"
out=$(TMUX="$sockpath,0,0" TMUX_PANE='' bash "$root/scripts/hook.sh" <<<'{"hook_event_name":"Stop"}' 2>&1)
assert "outside tmux it exits 0 silently" test "$?:$out" = "0:"

echo "# plugin load"
setup glyphs
assert "default idle icon is nf-md-robot" test "$(tm show -gv @bird_claude_tmux_icon_idle)" = $'\xf3\xb0\x9a\xa9'
assert "default done icon is nf-fa-check_circle" test "$(tm show -gv @bird_claude_tmux_icon_done)" = $'\xef\x81\x98'
tm set -g @bird_claude_tmux_icon_idle X
load
expect "a reload keeps user icons" t:0 " X"
assert "a reload doesn't stack hooks" test "$( (tm show-hooks -g; tm show-hooks -gw) | grep -c bird_claude_tmux)" = 6

echo "# fork"
# Stand-ins for the user's shell and claude: the stub logs its cwd and args, the real one never runs.
mkdir -p "$tmp/bin" "$tmp/proj"
printf '%s\n' '#!/usr/bin/env bash' "printf '%s\n' \"\$PWD\" \"\$@\" >\"$tmp/fork-\$TMUX_PANE.log\"" 'exec sleep 1000' >"$tmp/bin/claude"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' '[[ $1 == -ic ]] || exec /bin/sh "$@"' "PATH=\"$tmp/bin:\$PATH\" exec bash -c \"\${@:2}\"" >"$tmp/shell"
chmod +x "$tmp/bin/claude" "$tmp/shell"
forksetup() {
  setup
  rm -f "${tmp:?}"/fork-*.log
  tm set -g default-shell "$tmp/shell"
  tm rename-window -t t:0 "$1"
  tm set -p -t %0 @bird_claude_tmux_session_id s-1 \; set -p -t %0 @bird_claude_tmux_cwd "$tmp/proj"
}
fork() { env -u TMUX_PANE TMUX="$sockpath,0,0" bash "$root/scripts/fork.sh" "$@"; }
newest() { tm list-panes -a -F '#{pane_id}' | tr -d % | sort -n | tail -1 | sed 's/^/%/'; }
forklog() {
  for _ in {1..100}; do
    [[ -s $tmp/fork-$1.log ]] && { cat "$tmp/fork-$1.log"; return; }
    sleep 0.02
  done
}
forksetup x
fork split %0
p=$(newest)
assert "split: claude gets --resume, --fork-session and the name x-fork" \
  test "$(forklog "$p")" = "$(printf '%s\n' "$tmp/proj" --resume s-1 --fork-session -n x-fork)"
assert "split: the fork sits right of the original" test "$(tm display -p -t "$p" '#{window_index} #{pane_floating_flag} #{e|>:#{pane_left},0}')" = "0 0 1"
forksetup x-fork
tm new-window -d -t t:5 "$plain"
fork window %0
p=$(newest)
assert "window: a fork of x-fork is named x-fork" test "$(forklog "$p" | tail -1)" = x-fork
assert "window: right after the current one, automatic-rename on" test "$(tm display -p -t "$p" '#{window_index} #{automatic-rename}')" = "1 1"
forksetup x
fork float %0
p=$(newest)
assert "float: a floating pane in the same window" test "$(tm display -p -t "$p" '#{window_index} #{pane_floating_flag}')" = "0 1"
assert "float: it runs in the session's cwd" test "$(forklog "$p" | head -1)" = "$tmp/proj"
forksetup "a'b \"c\" \$d"
tm set -pu -t %0 @bird_claude_tmux_cwd
fork split %0
p=$(newest)
assert "a window name with quotes and \$ survives" test "$(forklog "$p" | tail -1)" = "a'b \"c\" \$d-fork"
assert "without a stored cwd it uses the pane's path" test "$(forklog "$p" | head -1)" = "$(tm display -p -t %0 '#{pane_current_path}')"
forksetup x
tm set -pu -t %0 @bird_claude_tmux_session_id
tm split-window -d -t t:0 "$plain"
tm set -p -t %1 @bird_claude_tmux_session_id s-2
n=$(tm list-panes -a | wc -l)
fork split %0 2>/dev/null
fork split %1 2>/dev/null
assert "no fork without a session id, or from a pane without Claude" test "$(tm list-panes -a | wc -l)" = "$n"
assert "prefix A opens the key table" grep -q 'switch-client -T bird_claude_tmux' <<<"$(tm list-keys -T prefix A)"
assert "the table has | c f" test "$(tm list-keys -T bird_claude_tmux | grep -c "fork.sh' \(split\|window\|float\)")" = 3

echo "# name sync"
setup
title() { tm select-pane -t "$1" -T "$2"; }
# Waits up to 1 s for a window name; hooks run async.
name_is() {
  local name=$1 target=$2 want=$3 got
  for _ in {1..50}; do
    got=$(tm display -p -t "$target" '#{window_name}')
    [[ $got == "$want" ]] && { echo "ok   $name"; return; }
    sleep 0.02
  done
  fail "$name: want [$want] got [$got]"
}
# Waits until a new pane's process is claude, as Claude sets its title only after startup.
runs_claude() {
  for _ in {1..50}; do
    [[ $(tm display -p -t "$1" '#{pane_current_command}') == claude ]] && return
    sleep 0.02
  done
}
# For checks that nothing happens: gives async hooks time to run first.
settle() { sleep 0.2; }
title %0 '✳ First topic'
name_is "the window follows Claude's title" t:0 "First topic"
title %0 '⠂ Second topic'
name_is "any leading glyph is stripped" t:0 "Second topic"
title %0 '✳ Claude Code'
settle
name_is "the placeholder title is ignored" t:0 "Second topic"
title %0 'myhost'
settle
name_is "a title without a glyph is ignored" t:0 "Second topic"
tm rename-window -t t:0 mine
title %0 '✳ Third topic'
settle
name_is "a manual rename locks the window" t:0 mine
tm set -w -t t:0 automatic-rename on
title %0 '✳ Fourth topic'
name_is "automatic-rename on unlocks it" t:0 "Fourth topic"
tm new-window -d -t t:1 -n named "$claude"
runs_claude %1
title %1 '✳ Topic'
settle
name_is "a window named before Claude started stays locked" t:1 named
tm split-window -t t:0 "$claude"
runs_claude %2
title %2 '✳ Other pane'
name_is "a new active Claude pane names the window" t:0 "Other pane"
tm select-pane -t %0
name_is "focus on another Claude pane takes its title" t:0 "Fourth topic"
title %2 '✳ Inactive pane'
settle
name_is "an inactive pane's title is ignored" t:0 "Fourth topic"
tm new-window -d -t t:2 -n plain "$plain"
tm set -w -t t:2 automatic-rename on
title %3 '✳ Not Claude'
settle
assert "a pane without Claude never names its window" test "$(tm display -p -t t:2 '#{window_name}')" != "Not Claude"
tm set -g @bird_claude_tmux_sync_title off
load
title %0 '✳ Fifth topic'
settle
name_is "@bird_claude_tmux_sync_title off stops it" t:0 "Fourth topic"

echo
if ((fails)); then echo "$fails failed"; exit 1; fi
echo "all passed"
