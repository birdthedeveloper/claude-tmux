# Phase 0 keyboard tests: cookbook

Subplan of `PLAN.md`. It answers the open Phase 0 items 3, 4, 11 and the second
half of 8. Takes about 7 minutes.

- You do the typing, because `CLAUDE.md` forbids Claude to type into a terminal.
- Everything is logged to `~/.cache/bird-spike`. The tmux options and
  `~/.claude/settings.json` stay untouched.
- Run the tests in order, in your normal tmux.

## 1. Setup

Paste this once. It creates a throwaway plugin that only logs hook events.

```sh
mkdir -p ~/.cache/bird-spike/.claude-plugin ~/.cache/bird-spike/hooks

cat > ~/.cache/bird-spike/.claude-plugin/plugin.json <<'E'
{"name":"bird-spike","description":"throwaway hook logger"}
E

cat > ~/.cache/bird-spike/log.sh <<'E'
ts=${EPOCHREALTIME/[.,]/}
tty=$(ps -o tty= -p "${CLAUDE_PID:-0}")
jq -c --arg ts "$ts" --arg pane "${TMUX_PANE-}" --arg tty "${tty// /}" \
  '{ts:$ts,pane:$pane,tty:$tty,in:.}' >> ~/.cache/bird-spike/user.log
exit 0
E

cat > ~/.cache/bird-spike/show.sh <<'E'
jq -rs '.[0].ts as $t0 | .[]
  | [ ((((.ts|tonumber)-($t0|tonumber))/1000|round)/1000|tostring)+"s",
      .in.hook_event_name, (.in.notification_type//""), (.in.tool_name//""),
      (if .in.duration_ms then "took \(.in.duration_ms)ms" else "" end),
      ((.in.tool_input.command//.in.prompt//"")|tostring|.[0:60]) ]
  | map(select(. != "")) | join("  ")' ~/.cache/bird-spike/user.log
E

cat > ~/.cache/bird-spike/focus.sh <<'E'
last=
for i in {1..150}; do
  now=$(tmux list-clients -F '#{client_name} #{pane_id} #{client_flags}')
  if [ "$now" = "$last" ]; then sleep 0.2; continue; fi
  printf '%s\n%s\n' "$(date +%T.%1N)" "$now" | tee -a ~/.cache/bird-spike/focus.log
  last=$now; sleep 0.2
done
echo finished
E

jq -n '"PreToolUse PostToolUse PostToolUseFailure PostToolBatch Notification UserPromptSubmit UserPromptExpansion SessionStart SessionEnd Stop StopFailure SubagentStart SubagentStop PreCompact PostCompact PermissionRequest PermissionDenied TaskCreated TaskCompleted Elicitation ElicitationResult"
  | split(" ")
  | map({(.): [{hooks: [{type: "command", command: "bash \"${CLAUDE_PLUGIN_ROOT}/log.sh\"", async: (. != "SessionEnd")}]}]})
  | add | {hooks: .}' > ~/.cache/bird-spike/hooks/hooks.json
```

Check: `claude plugin validate ~/.cache/bird-spike` ends with `Validation passed
with warnings`. Complaints about a missing README, license or icon are fine.

## 2. Test A: focus (item 8)

1. Run `bash ~/.cache/bird-spike/focus.sh` in any pane. It logs for 30 s.
2. After about 5 s, switch to another app (not another Alacritty window).
3. Stay there about 5 s, then come back.
4. Wait for `finished`.

## 3. Start the logged Claude

In a new tmux window:

```sh
cd ~/r/b/claude-tmux && claude --plugin-dir ~/.cache/bird-spike --model haiku --permission-mode default -n spike-user
```

Use this one session for tests B to E. "Hands off" below means no typing in it.

## 4. Test B: approve (item 3)

1. Send: `Run this Bash command: mkdir -p ~/.cache/bird-spike/work/a && sleep 8`
2. When the dialog shows, wait 10 s.
3. Choose plain **Yes** (not "don't ask again").
4. Wait until Claude is done.

## 5. Test C: deny (item 11)

1. Send: `Run this Bash command: mkdir -p ~/.cache/bird-spike/work/b`
2. When the dialog shows, wait 10 s.
3. Choose **No**.
4. Hands off for 75 s.

## 6. Test D: Esc at the dialog (items 4 and 11)

1. Send: `Run this Bash command: mkdir -p ~/.cache/bird-spike/work/c`
2. When the dialog shows, wait 10 s.
3. Press **Esc**.
4. Hands off for 75 s.

## 7. Test E: Esc while working (item 4)

1. Send: `Write a 500 word story`
2. Press **Esc** after about 3 s.
3. Hands off for 75 s.

## 8. Finish

1. Type `/exit`.
2. Look at the results with `bash ~/.cache/bird-spike/show.sh` and
   `cat ~/.cache/bird-spike/focus.log`.
3. Tell Claude "keyboard tests done". Claude reads both logs and writes the
   results into `PLAN.md`.

## How to read the results

Prompts appear in the log as `UserPromptSubmit`, so they mark where each test
starts. The 10 s waits are there so the `permission_prompt` notification (about
6 s) is logged before you act.

| Test | Look for | If yes | If no |
|---|---|---|---|
| A | `focused` is missing from the flags while you are in the other app | Decision 10 works as planned | `Stop` gives `idle` even when you are in another app |
| B | an event after your Yes and before `PostToolUse` (your Yes was at the `PostToolUse` time minus `took`) | It can clear `needs-input` at once | `needs-input` stays until the tool finishes (already in Risks) |
| C | an event right after your No | It can clear `needs-input` | `needs-input` stays until `Stop` or your next prompt |
| C, D | `Notification idle_prompt` about 60 s later | It may reset `needs-input` too | Only your next prompt resets it |
| E | `Notification idle_prompt` about 60 s later | The Esc recovery works as planned | `working` stays until your next prompt |

## Cleanup

Only after the results are in `PLAN.md`:

1. `rm -r ~/.cache/bird-spike`
2. Delete this file.
3. The session `spike-user` stays in your `/resume` list until its transcript is
   deleted.
