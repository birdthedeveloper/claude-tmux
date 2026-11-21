# claude-tmux: plan

A TPM-installable tmux plugin that shows the state of Claude Code per window,
plus fork helpers and one-way name sync (Claude → window). The same repo is
also a Claude Code plugin that ships the hooks.

Status: decisions made (see below). Next step: Phase 0.

## Context: what I found in your setup

- tmux 3.8. TPM is loaded from `~/.tmux/plugins/tpm`; plugins live in
  `~/.config/tmux/plugins/` (TPM picks the XDG path because your config is
  `~/.config/tmux/tmux.conf`). There is also a second, unused copy of TPM in
  `~/.config/tmux/plugins/tpm`.
- catppuccin v2.1.0 builds `window-status-format` with `set -gF`, copying
  `@catppuccin_window_text` in verbatim. Any `#{...}` you put in that option is
  evaluated at render time, so a dynamic icon can go there (checked in
  `catppuccin_tmux.conf:181-191`).
- `focus-events on`, `automatic-rename on`, `allow-rename off`.
- Why tmux-agent-indicator never worked: `~/.claude/settings.json` has no hooks.
  TPM only clones and sources the plugin, so its `install.sh` (the part that
  writes the Claude hooks) never ran. Its hook template also defaults to
  `~/.tmux/plugins/tmux-agent-indicator`, which does not exist on your machine.
  Its tmux hooks (`after-select-pane`, `after-select-window`, `pane-focus-in`,
  `client-session-changed`) are still registered in your running server.
- Claude Code 2.1.323:
  - sets the pane title to `✳ <session title>` (seen:
    `✳ Claude Code tmux notification plugin`)
  - has `-n/--name`, `/rename`, and `--resume <id> --fork-session`
  - hook events include `PermissionRequest`, `PermissionDenied`,
    `StopFailure`, `SessionStart` (sources incl. `fork`), `SessionEnd`, and
    `Notification` with types `permission_prompt` (about 6 s wait),
    `idle_prompt` (60 s after finishing) and `elicitation_dialog`
  - `Stop` does not fire on user interrupt (Esc)
  - command hooks support `async`
  - plugins can install from a GitHub repo that is its own marketplace
    (`claude plugin marketplace add`, `claude plugin install`,
    `claude plugin validate`). `--plugin-dir <path>` loads a local plugin for
    one session, which is handy for development.
- Verified in tmux 3.8: the format loops `#{P:}`, `#{W:}`, `#{S:}` and the
  `#{s/re/repl/:var}` substitution work. These keys are free under the prefix:
  `A F G S V W Y u v y` (`g` and `@` are taken by 3.8 defaults).
- The repo's remote is `github.com/birdthedeveloper/claude-tmux`.

## Decisions

1. Four states: `idle`, `working`, `needs-input`, `done`. Each gets its own
   icon.
2. Priority when panes in a window differ: needs-input, then done, then
   working, then idle.
3. `done` is cleared when that pane gets focus.
4. The window name follows Claude's automatic topic title. Once you rename
   the window by hand (`prefix ,`), that name is locked. The plugin never
   overwrites it again, even if the Claude session is renamed.
5. Hooks ship as a Claude Code plugin from this same repo.
6. The repo will be public. TPM and Claude Code both install from GitHub.
   The key table is on `prefix A` for now (you may change it later).
7. Icons are Nerd Font glyphs.
8. Fork variants: split right, new window, and a floating pane. No split
   below and no popup for now.
9. Forks are named `<window>-fork`.
10. If Claude finishes in the pane you are looking at, the state goes
    straight to `idle` and skips `done`.
11. The picker is on `prefix C`.

## Goals and non-goals

Goals: per-window Claude state icon, fork keybindings, Claude → window name
sync with a manual lock, jump-to-attention, a picker of Claude panes, install
from GitHub (TPM plus Claude plugin).

Non-goals: never send keystrokes or paste text into a Claude pane (no
`send-keys`, no `paste-buffer`); this rule is in `CLAUDE.md`. So there is
no window → Claude rename.

Non-goals (YAGNI): other agents (codex, opencode), animation (your
`status-interval` is 60), pane background colors, usage limits (your Claude
statusline already shows them), persisting state across tmux server restarts.

## Design

### State model

State is stored per pane in tmux user options. No files and no daemon.

- `@claude_state`: `idle` | `working` | `needs-input` | `done`
- `@claude_session_id`: from the hook payload, refreshed on every event
  (it changes on `/clear`, resume and fork)
- `@claude_cwd`: the session's `cwd` from `SessionStart`, used by fork

These three option names are the only contract between the Claude plugin
(writes them) and the tmux plugin (reads them). Keep them stable.

### Claude Code hooks → state

One dispatcher, `scripts/hook.sh`, is registered for all events. It reads
`hook_event_name` and related fields from stdin with one `jq` call, then makes
one `tmux set -p -t "$TMUX_PANE"` call.

| Event (matcher) | New state |
|---|---|
| `SessionStart` | `idle`, store session id and cwd |
| `UserPromptSubmit` | `working` |
| `PostToolUse`, `PostToolUseFailure`, `PermissionDenied` | `working` |
| `PreToolUse` (`AskUserQuestion\|ExitPlanMode`) | `needs-input` |
| `PermissionRequest` | `needs-input` |
| `Notification` (`permission_prompt\|elicitation_dialog`) | `needs-input` |
| `Notification` (`idle_prompt`) | `idle`, only if still `working` (recovers from Esc) |
| `Stop`, `StopFailure` | `done`, or `idle` if you are looking at the pane (decision 10) |
| `SessionEnd` | unset all `@claude_*` |

Rules for `hook.sh`:

- Exit at once when `TMUX_PANE` is empty, so sessions outside tmux are
  unaffected.
- Always exit 0 and print nothing. Exit 2 would block tools, and stdout on
  `SessionStart` or `UserPromptSubmit` gets injected into Claude's context.
- Hooks run synchronously, about 10 ms each, which keeps events ordered
  (`PostToolUse` always lands before `Stop`). Switch to `async` only if the
  delay is noticeable, and add ordering protection then.
- After setting the state, refresh the status line of every attached client,
  in the same tmux call.
- "Looking at the pane" on `Stop`: some client from
  `list-clients -F '#{pane_id} #{client_flags}'` has this pane as its current
  pane and has `focused` in its flags. That is one extra tmux call, made only
  on `Stop`. If you switched to another app, the client is not focused, so
  you still get `done`.

### Hook delivery: Claude Code plugin

- `.claude-plugin/plugin.json` is the plugin manifest.
  `.claude-plugin/marketplace.json` makes the repo its own marketplace, with
  one plugin whose source is `./`.
- `hooks/hooks.json` registers `${CLAUDE_PLUGIN_ROOT}/scripts/hook.sh` for
  every event in the table.
- Claude Code copies the plugin into its own cache, so the hook path is always
  correct and nothing in `~/.claude/settings.json` is edited by hand. This
  avoids both bugs that broke agent-indicator.
- The cost: two copies of the repo exist (the TPM clone and the Claude plugin
  cache). Each copy only uses its own half (tmux side or hooks side), and the
  pane option contract above links them.

### Window aggregation: pure tmux formats

The plugin defines a global option `@claude_tmux_window_icon` that holds a
format. You embed it with `#{E:@claude_tmux_window_icon}` in the catppuccin
window text. At render time, `#{P:...}` loops over the window's panes:

- It considers only panes whose `pane_current_command` is `claude`. A
  `kill -9`'d or crashed Claude therefore drops out with no cleanup code.
- A claude pane with no `@claude_state` counts as `idle`. So "Claude present"
  works even before hooks fire, for example in sessions started before the
  install.
- The result is a nested `#{?#{m:*needs-input*,...},...}` that follows the
  priority from decision 2.

This needs no recompute script, and `join-pane`, `break-pane` and `kill-pane`
(your `prefix M`) are handled for free.

Default icons are Nerd Font glyphs and can be changed:

| State | Glyph | Nerd Font name | Codepoint |
|---|---|---|---|
| idle | `󰚩` | `nf-md-robot` | U+F06A9 |
| working | `` | `nf-fa-hourglass_half` | U+F252 |
| needs-input | `` | `nf-fa-question_circle` | U+F059 |
| done | `` | `nf-fa-check_circle` | U+F058 |

Phase 1 checks that they render in Alacritty with your font.

### tmux side (`claude-tmux.tmux`)

- Set option defaults and `@claude_tmux_window_icon`.
- Clear `done` (decision 3): on `pane-focus-in`, `window-pane-changed`,
  `session-window-changed` and `client-session-changed`, run the tmux-native
  command `if -F '#{==:#{@claude_state},done}' 'set -p @claude_state idle'`.
  No shell fork.
- Name-sync hooks on `pane-title-changed` and `window-pane-changed` (below).
- Register hooks idempotently: strip earlier copies that match our path first,
  so `prefix r` reloads don't stack them (the same trick agent-indicator uses).
- Add the key table (below).

### User options

| Option | Default |
|---|---|
| `@claude-tmux-icon-idle` / `-working` / `-needs-input` / `-done` | see above |
| `@claude-tmux-key` | `A` |
| `@claude-tmux-picker-key` | `C` |
| `@claude-tmux-sync-title` | `on` |
| `@claude-tmux-process` | `claude` |

## Name sync: Claude → tmux window, with a manual lock

- Claude writes its session title into the pane title (`✳ <title>`; the glyph
  becomes a spinner while it works). The title is Claude's automatic topic, or
  a name set with `/rename` or `-n`.
- The plugin records the last name it set in a window option,
  `@claude_tmux_synced_name`.
- A window is Claude-owned while either of these holds:
  - `automatic-rename` is still on, so nobody has named the window yet
  - `window_name` equals `@claude_tmux_synced_name`, so the last rename was ours
- A tmux-native check runs on `pane-title-changed` and on
  `window-pane-changed`. It renames only when all of these hold:
  - the pane is the active pane and runs claude
  - the window is Claude-owned
  - the title, with the leading glyph stripped, differs from `window_name`
  - the title is not the placeholder `Claude Code`

  When it renames, it runs `rename-window` and updates
  `@claude_tmux_synced_name`.
- Manual lock (decision 4): after you rename with `prefix ,` (or any other
  way), `automatic-rename` is off and `window_name` no longer matches
  `@claude_tmux_synced_name`. From then on the plugin leaves the window alone,
  even after a `/rename` in Claude.
  - A window you named before starting Claude counts as locked too.
  - This needs no rebinding of `prefix ,` and no extra state per rename.
- To hand a locked window back to Claude: `prefix :` then
  `set -w automatic-rename on`.
- The title changes on every spinner frame, but the comparison guard means a
  real rename happens only when the text changes. The check runs inside tmux,
  with no fork.
- When focus moves to another Claude pane in the same window, an unlocked
  window takes that pane's title ("window name = focused Claude").
- The opposite direction (window → Claude) is out. Claude Code has no
  inbound rename API, and typing `/rename` into the pane is forbidden (see
  `CLAUDE.md`).

## Fork keybindings

- Every hook refreshes `@claude_session_id` on the pane, so the fork command is
  simply `claude --resume <id> --fork-session -n "<window>-fork"`. The `-n` is
  a command-line argument, not typed input.
- It runs in `@claude_cwd`: resume looks the session up by project directory,
  so the right cwd matters.
- The pane runs `claude ...; exec $SHELL`, so a shell stays after Claude exits,
  the same as your normal panes.
- Forking while the original is working is fine. The fork gets the transcript
  up to that moment.
- The new Claude fires `SessionStart` with source `fork` in its own pane, and
  the indicator picks it up automatically.
- Variants in the `prefix A` table (decision 8):
  - `|`: fork into a split to the right
  - `c`: fork into a new window placed next to the current one (your "move to
    another window" variant). It creates the window without `-n`, so
    `automatic-rename` stays on and the window remains Claude-owned for name
    sync.
  - `f`: fork into a floating pane (new in tmux 3.8). Your default `prefix @`
    toggles floating with `break-pane -W`; Phase 0 finds the flags to create
    one directly.
- If the pane has no Claude session, show `display-message "no Claude session
  in this pane"`.

## Extra features

1. `prefix A j`: jump to the next pane that needs attention, across all
   sessions. Panes in `needs-input` come first, then `done`. Pressing it
   again moves on to the next one. Implemented as `scripts/jump.sh`
   (one `list-panes -a` call, then switch client, window and pane).
2. `prefix C` (decision 11, set by `@claude-tmux-picker-key`): picker of all
   Claude panes with state icon and title. It is a `choose-tree -Zs` filtered
   on the claude process, with a custom `-F`. No script needed. It replaces
   your current `bind C choose-tree ...`.

Rejected:

- Window → Claude rename and pasting a selection into a Claude pane: both
  type into the terminal (see `CLAUDE.md`).
- Polling Claude's internal `~/.claude/sessions/<pid>.json` (it has `status`
  and the tmux pane): it is undocumented and needs a fast status interval.
- tmux `display-message` notifications: they vanish before you see them.

## Repo layout

```
claude-tmux.tmux                 TPM entrypoint (tmux side)
.claude-plugin/plugin.json       Claude Code plugin manifest
.claude-plugin/marketplace.json  makes the repo its own marketplace
hooks/hooks.json                 Claude hooks, all pointing to hook.sh
scripts/hook.sh                  hook dispatcher, writes pane options
scripts/fork.sh                  fork into split / window / floating pane
scripts/jump.sh                  jump to next attention pane
tests/run.sh                     tests on a private tmux server
README.md
CLAUDE.md
```

Requirements: tmux 3.2 or newer (format loops), bash, jq.

## Implementation phases

Development loop, needing no install: `claude --plugin-dir ~/r/b/claude-tmux`
for the hooks, and `tmux run-shell ~/r/b/claude-tmux/claude-tmux.tmux` for the
tmux side.

### Phase 0: verify the assumptions (spike, about 30 min)

Write a throwaway hook that logs stdin and env to the scratchpad, load it with
`--plugin-dir`, and confirm:

1. Plugin hook processes inherit `TMUX_PANE`.
2. Whether `AskUserQuestion` and `ExitPlanMode` fire `PermissionRequest`, or
   only `PreToolUse`.
3. Whether any event fires right after a permission is approved. If none does,
   `needs-input` stays until the tool finishes (see Risks).
4. Whether `idle_prompt` fires after an Esc interrupt.
5. Whether `/rename` and `-n` change the pane title at once.
6. Whether `#{@claude_state}` inside `#{P:}` resolves per pane, and whether
   setting a pane option needs an explicit status refresh.
7. The tmux 3.8 flags that create a floating pane directly, with a command.
8. Whether `client_flags` contains `focused` for the client you are typing in,
   and drops it when Alacritty loses focus.

### Phase 1: status indicator (MVP)

- `hook.sh`, `.claude-plugin/` manifests, `hooks/hooks.json`, and
  `claude-tmux.tmux` (options, focus reset, window icon format).
- Tests: a private server (`tmux -L claude-tmux-test -f /dev/null`), a fake
  `claude` process (a symlink to `sleep`), and fixture JSON piped into
  `hook.sh`. Each test asserts `display -p '#{E:@claude_tmux_window_icon}'`.
  Cases:
  - each state
  - mixed priority across panes
  - a crashed Claude
  - `join-pane` between windows
  - done reset on focus
  - `Stop` in the focused pane gives `idle`, not `done`
- Checks: shellcheck on all scripts, `claude plugin validate .`, and that the
  Nerd Font icons render in your terminal.
- Done when: your example (one pane done plus one needing input gives "needs
  input") passes as a test and works live.

### Phase 2: fork bindings

`fork.sh` and the `prefix A` key table (`|`, `c`, `f`).

### Phase 3: name sync

- The `pane-title-changed` and `window-pane-changed` hooks with the manual
  lock.
- Tests:
  - the window follows a title change
  - `rename-window` locks it, and later title changes are ignored
  - a window named before Claude starts stays locked
  - `set -w automatic-rename on` unlocks it
  - the placeholder title is ignored

### Phase 4: jump and picker

`jump.sh` and the picker binding on `prefix C`.

### Phase 5: publish and switch your config

Push, make the repo public, then follow "Install in your setup".

## Install in your setup

The repo must be public: TPM clones over https without credentials.

1. In `~/.config/tmux/tmux.conf`:
   - remove `set -g @plugin 'accessd/tmux-agent-indicator'` and the five
     `@agent-indicator-*` lines
   - add `set -g @plugin 'birdthedeveloper/claude-tmux'`
   - add the icon to both catppuccin text lines (they must stay before `run`):
     `set -g @catppuccin_window_text " #{window_name}#{E:@claude_tmux_window_icon}#{?window_zoomed_flag, [Z],}"`
     and the same for `@catppuccin_window_current_text`
   - drop `bind-key C choose-tree ...` (the plugin binds `prefix C` to the
     picker)
2. Remove the agent-indicator hooks from the running server (or restart
   tmux):
   `tmux set-hook -gu after-select-pane \; set-hook -gu after-select-window \; set-hook -gu pane-focus-in \; set-hook -gu client-session-changed`,
   then `rm -rf ~/.config/tmux/plugins/tmux-agent-indicator` (or TPM clean,
   `prefix + alt-u`).
3. Reload with `prefix r`, then install with `prefix I`. TPM clones from
   GitHub.
4. Install the Claude plugin, then restart your running Claude sessions:
   `claude plugin marketplace add birdthedeveloper/claude-tmux`, then
   `claude plugin install claude-tmux@claude-tmux` (or use `/plugin` inside
   Claude).
5. Check: start Claude in a pane, send a prompt, and watch the window icon go
   from working to done.
6. Updates: `prefix U` for the tmux side, and
   `claude plugin update claude-tmux@claude-tmux` for the hooks. Update both
   together.

## Risks and known limitations

- After Esc, the icon can show `working` for up to about 60 s, until
  `idle_prompt` fires or you send the next prompt.
- After you approve a permission, `needs-input` may stay until that tool
  finishes, unless Phase 0 finds an event that fires on approval.
- Undocumented behavior we rely on (Phase 0 checks it): `TMUX_PANE` reaching
  hooks, and the `✳ <title>` pane title format. A title format change breaks
  name sync only, not the status icon.
- The TPM copy and the Claude plugin copy can drift if you update only one.
  The shared contract is just three pane option names, which keeps the risk
  small.
- Launching Claude through a wrapper (`node`, `npx`) changes
  `pane_current_command`. That is what `@claude-tmux-process` is for.
- About 10 ms of synchronous hook time per tool call.
