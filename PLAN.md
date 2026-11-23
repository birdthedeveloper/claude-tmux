# claude-tmux: plan

A TPM-installable tmux plugin that shows the state of Claude Code per window,
plus fork helpers and one-way name sync (Claude → window). The same repo is
also a Claude Code plugin that ships the hooks.

Status: decisions made (see below), Phases 0 to 4 done. Next step: Phase 5.
New session: read [Handoff](#handoff) at the end first.

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
   overwrites it again, even if the Claude session is renamed. This needs no
   wrapper around `claude`, so it stays: a plain `claude` process sets its own
   pane title (seen live in your panes) and tmux reads it.
5. Hooks ship as a Claude Code plugin from this same repo.
6. The repo is public (checked: anonymous `git ls-remote` works). TPM and
   Claude Code both install from it, from the default branch (`master`). The
   Claude plugin is named `bird-claude-tmux`, because Claude Code reserves
   names starting with `claude-`. The key table is on `prefix A` for now (you
   may change it later).
7. Icons are Nerd Font glyphs.
8. Fork variants: split right, new window, and a floating pane. No split
   below and no popup for now.
9. Forks are named `<window>-fork`. An existing `-fork` suffix is stripped
   first, so a fork of a fork keeps one suffix.
10. If Claude finishes in the pane you are looking at, the state goes
    straight to `idle` and skips `done`.
11. The picker is on `prefix C`: fzf in a popup, one row per Claude pane, with
    a live preview. `ctrl-w` switches the preview between that pane and all
    panes of its window.
12. Every tmux option, key table and test socket name starts with
    `bird_claude_tmux`. The repo and `claude-tmux.tmux` keep their names.
13. While a tool waits for your approval, only a result of a tool with the same
    name clears `needs-input`.
14. If Claude stops while background subagents or workflows still run, the state
    stays `working`. Background shells (e.g. a dev server) don't count.
15. A status segment for `status-right`, `#{E:@bird_claude_tmux_status}`, covers
    the current session. It is hidden without a Claude pane there. Otherwise it
    shows the idle icon in green, or the needs-input icon in orange while any
    Claude pane of the session needs input (`done` stays green). Icon only, on
    a round pill like catppuccin's modules (round caps U+E0B6 and U+E0B4).
16. When a pane changes into `needs-input` and you are not looking at it, a
    status-line message shows for 4 s: `Claude needs input in
    <session>:<window> <name> (<tool>)`. Never for `done`.
17. The picker lists the Claude panes of the current session only (changes
    decision 11).

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

- `@bird_claude_tmux_state`: `idle` | `working` | `needs-input` | `done`
- `@bird_claude_tmux_session_id`: from the hook payload, refreshed on every
  event (it changes on `/clear`, resume and fork)
- `@bird_claude_tmux_cwd`: the session's `cwd` from `SessionStart`, used by fork
- `@bird_claude_tmux_ts`: start time of the last hook that was applied, for
  ordering (private to `hook.sh`)
- `@bird_claude_tmux_pending`: name of the tool that waits for your approval
  (decision 13, private to `hook.sh`)

The first three names are the only contract between the Claude plugin (writes
them) and the tmux plugin (reads them). Keep them stable.

### Claude Code hooks → state

One dispatcher, `scripts/hook.sh`, is registered for all events (agreed). It
reads `hook_event_name` and related fields from stdin with one `jq` call, then
makes one `tmux` call that targets `$TMUX_PANE`.

| Event (matcher) | New state |
|---|---|
| `SessionStart` (source `compact`) | unchanged, refresh session id and cwd |
| `SessionStart` (other sources) | `idle`, clear pending, store session id and cwd |
| `UserPromptSubmit` | `working`, clear pending |
| `PostToolUse`, `PostToolUseFailure`, `PermissionDenied` | `working` and clear pending, but only if nothing is pending or the tool name matches |
| `PreToolUse` (`AskUserQuestion\|ExitPlanMode`) | `needs-input`, pending = tool name |
| `PermissionRequest` | `needs-input`, pending = tool name |
| `Notification` (`permission_prompt\|elicitation_dialog`) | `needs-input` |
| `Stop` with a `subagent` or `workflow` in `background_tasks` | `working`, clear pending (decision 14) |
| `Stop` (otherwise), `StopFailure` | `done`, or `idle` if you are looking at the pane (decision 10); clear pending |
| `SessionEnd` | unset state, session id, cwd and pending (keep `_ts`) |

Rules for `hook.sh`:

- Exit at once when `TMUX_PANE` is empty, so sessions outside tmux are
  unaffected.
- Always exit 0 and print nothing. JSON on stdout can reach Claude's context
  on the next turn, and the synchronous `SessionEnd` must not report errors.
- All hooks are `"async": true`: Claude starts them and does not wait, so the
  delay per tool call is only the process spawn. The exception is
  `SessionEnd`. It runs once per session, and Claude may exit before an async
  hook finishes.
- Ordering protection, because async hooks can finish out of order:
  - The first line takes a timestamp: `ts=${EPOCHREALTIME/[.,]/}`
    (microseconds; the separator is a comma in some locales).
  - The write is a compare-and-set inside the tmux server:
    `if -F '#{e|<:<stored ts or 0>,<ts>}' 'set -p ..._ts <ts> ; set -p ..._state <state>'`.
    A hook that started earlier but lands later is dropped.
  - Tested in tmux 3.8: 5 rounds of 60 concurrent writes in random order, the
    newest one always won.
- The pending check is part of the same compare-and-set condition, so it needs
  no extra tmux call.
- Owner check (Phase 0, item 10), also part of that condition: the tty of the
  Claude that fired the hook must be the pane's tty:
  `#{==:#{pane_tty},/dev/<tty>}` with `<tty>` from
  `ps -o tty= -p "$CLAUDE_PID"` (about 3 ms). A Claude started by Claude's Bash
  tool has no tty, so it can neither set nor unset the pane's state.
- Automatic compaction fires `SessionStart` in the middle of work, which is why
  source `compact` leaves the state alone.
- No explicit status refresh: `set -p` redraws attached clients by itself, even
  with `status-interval 0` (Phase 0, item 6).
- "Looking at the pane" on `Stop`: some client from
  `list-clients -F '#{pane_id} #{client_flags}'` has this pane as its current
  pane and has `focused` in its flags. That is one extra tmux call, made only
  on `Stop`. If you switched to another app, the client is not focused, so
  you still get `done`.

### Hook delivery: Claude Code plugin

- `.claude-plugin/plugin.json` is the plugin manifest.
  `.claude-plugin/marketplace.json` makes the repo its own marketplace, with
  one plugin whose source is `./`. Anyone can install it from the public repo:
  `claude plugin marketplace add birdthedeveloper/claude-tmux`, then
  `claude plugin install bird-claude-tmux@bird-claude-tmux`.
- Plugin and marketplace are both named `bird-claude-tmux`. `claude-tmux` fails
  `claude plugin validate` (reserved). A manifest with the new name and source
  `./` passed validation and installed from a local folder, in an isolated
  config directory. The spelling has hyphens because the claude.ai marketplace
  sync requires kebab-case.
- Both manifests leave `version` out, so every push to `master` counts as an
  update.
- `hooks/hooks.json` registers `${CLAUDE_PLUGIN_ROOT}/scripts/hook.sh` for
  every event in the table.
- Claude Code copies the plugin into its own cache, so the hook path is always
  correct and nothing in `~/.claude/settings.json` is edited by hand. This
  avoids both bugs that broke agent-indicator.
- The cost: two copies of the repo exist (the TPM clone and the Claude plugin
  cache). Each copy only uses its own half (tmux side or hooks side), and the
  pane option contract above links them.

### Window aggregation: pure tmux formats

The plugin defines a global option `@bird_claude_tmux_window_icon` that holds a
format. You embed it with `#{E:@bird_claude_tmux_window_icon}` in the catppuccin
window text. At render time, `#{P:...}` loops over the window's panes:

- It considers only panes whose `pane_current_command` is `claude`. A
  `kill -9`'d or crashed Claude therefore drops out with no cleanup code.
- A claude pane with no `@bird_claude_tmux_state` counts as `idle`. So "Claude
  present" works even before hooks fire, for example in sessions started
  before the install.
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

- Set option defaults and `@bird_claude_tmux_window_icon`.
- Clear `done` (decision 3): on `pane-focus-in`, `window-pane-changed`,
  `session-window-changed` and `client-session-changed`, run the tmux-native
  command `if -F '#{==:#{@bird_claude_tmux_state},done}' 'set -p @bird_claude_tmux_state idle'`.
  No shell fork.
- Name-sync hooks on `pane-title-changed` and `window-pane-changed` (below).
- Register hooks idempotently at the fixed array index `[4247]`, so a
  `prefix r` reload overwrites them instead of stacking them.
- Add the key table `bird_claude_tmux` (below).

### User options

| Option | Default |
|---|---|
| `@bird_claude_tmux_icon_idle` / `_working` / `_needs_input` / `_done` | see above |
| `@bird_claude_tmux_key` | `A` |
| `@bird_claude_tmux_picker_key` | `C` |
| `@bird_claude_tmux_sync_title` | `on` |
| `@bird_claude_tmux_process` | `claude` |
| `@bird_claude_tmux_color_ok` / `_color_wait` / `_color_icon` | `green` / `colour208` / `black` |

## Name sync: Claude → tmux window, with a manual lock

- Claude writes its session title into the pane title (`✳ <title>`; the glyph
  becomes a spinner while it works). The title is Claude's automatic topic, or
  a name set with `/rename` or `-n`.
- The plugin records the last name it set in a window option,
  `@bird_claude_tmux_synced_name`.
- A window is Claude-owned while either of these holds:
  - `automatic-rename` is still on, so nobody has named the window yet
  - `window_name` equals `@bird_claude_tmux_synced_name`, so the last rename was ours
- A tmux-native check runs on `pane-title-changed` and on
  `window-pane-changed`. It renames only when all of these hold:
  - the pane is the active pane and runs claude
  - the window is Claude-owned
  - the title, with the leading glyph stripped, differs from `window_name`
  - the title is not the placeholder `Claude Code`

  When it renames, it runs `rename-window` and updates
  `@bird_claude_tmux_synced_name`.
- Manual lock (decision 4): after you rename with `prefix ,` (or any other
  way), `automatic-rename` is off and `window_name` no longer matches
  `@bird_claude_tmux_synced_name`. From then on the plugin leaves the window alone,
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

- Every hook refreshes `@bird_claude_tmux_session_id` on the pane, so the fork command is
  simply `claude --resume <id> --fork-session -n "<window>-fork"`. The `-n` is
  a command-line argument, not typed input. The name is
  `"${window%-fork}-fork"` (decision 9).
- It runs in `@bird_claude_tmux_cwd`: resume looks the session up by project
  directory, so the right cwd matters.
- Claude runs inside an interactive shell (tmux's `default-shell`, zsh for
  you), passed to tmux as separate arguments:
  `<shell> -ic 'claude --resume "$1" --fork-session -n "$2"; exec "$0"' <shell> <id> <name>`
  - The shell stays after Claude exits, the same as your normal panes.
  - Your `.zshrc` is loaded, so `PATH` and aliases work.
  - It is also required: with a plain `claude ...; exec $SHELL` string, tmux
    reports `pane_current_command` as `zsh`, so the icon, jump, picker and name
    sync would not see the fork. With `-ic` it is `claude` (both tested).
  - Positional arguments need no quoting, so a window name with quotes or `$`
    is safe (tested).
  - Works with zsh and bash. Fish has no `$1`.
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
- If the pane does not run claude or has no session id, show
  `display-message "no Claude session in this pane"`.

## Extra features

1. `prefix A j`: jump to the next pane that needs attention, across all
   sessions. Panes in `needs-input` come first, then `done`. Pressing it
   again moves on to the next one. Implemented as `scripts/jump.sh`
   (one `list-panes -a` call, then switch client, window and pane).
2. `prefix C` (decisions 11 and 17, set by `@bird_claude_tmux_picker_key`):
   picker of the Claude panes in the current session, `scripts/picker.sh` run
   by `display-popup -E`. It replaces your current `bind C choose-tree ...`.
   - Rows: one `list-panes -s -f` call for the popup client's session,
     filtered on the claude process. Each row shows `window.pane`, state icon,
     window name and Claude title. The pane id is a hidden field.
   - Search: fzf fuzzy match over the whole visible row, so window name and
     Claude title both match.
   - Preview: the pane's screen (`tmux capture-pane -ep`). `ctrl-w` (fzf's
     delete-word by default) switches to all panes of the window, stacked with
     a header each, and back.
   - Enter runs `tmux switch-client -t <pane id>` (tested from an fzf popup: it
     switches the right client, window and pane). Esc closes the popup.
   - It only reads from panes, so the rule in `CLAUDE.md` holds.
3. Status segment (decision 15): a format built like the window icon, with a
   `#{W:}` loop around the `#{P:}` loop. Colours: `@bird_claude_tmux_color_ok`
   and `@bird_claude_tmux_color_wait`.
4. Needs-input message (decision 16): `hook.sh` adds a nested
   `if -F '#{!=:<state>,needs-input}' 'display-message ...'` before the state
   write, so the three events of one wait (`PreToolUse`, `PermissionRequest`,
   the 6 s notification) show it once. It goes to the most recently active
   client and is skipped when a focused client shows the pane.

Rejected:

- Window → Claude rename and pasting a selection into a Claude pane: both
  type into the terminal (see `CLAUDE.md`).
- Polling Claude's internal `~/.claude/sessions/<pid>.json` (it has `status`
  and the tmux pane): it is undocumented and needs a fast status interval.
- tmux's own pickers for `prefix C`: `switch-mode` (3.8) is fuzzy but lists only
  sessions or windows, with no filter and no preview. `choose-tree` has a
  preview but no fuzzy search.

## Repo layout

```
claude-tmux.tmux                 TPM entrypoint (tmux side)
.claude-plugin/plugin.json       Claude Code plugin manifest
.claude-plugin/marketplace.json  makes the repo its own marketplace
hooks/hooks.json                 Claude hooks, all pointing to hook.sh
scripts/hook.sh                  hook dispatcher, writes pane options
scripts/fork.sh                  fork into split / window / floating pane
scripts/jump.sh                  jump to next attention pane
scripts/picker.sh                fzf picker with pane / window preview
tests/run.sh                     tests on a private tmux server
README.md
CLAUDE.md
```

Requirements: tmux 3.2 or newer (3.8 for the floating fork), bash 5 or newer
(`EPOCHREALTIME`), jq, and fzf for the picker.

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
6. Whether `#{@bird_claude_tmux_state}` inside `#{P:}` resolves per pane, and whether
   setting a pane option needs an explicit status refresh.
7. The tmux 3.8 flags that create a floating pane directly, with a command.
8. Whether `client_flags` contains `focused` for the client you are typing in,
   and drops it when Alacritty loses focus.
9. Whether async hooks start in event order, including parallel tool calls
   (log the timestamps).
10. How `hook.sh` can tell a nested or background Claude from the one in the
    pane (see Handoff, open design gap).
11. Which event fires when you deny a permission with "No". If none does,
    `needs-input` stays until `Stop` or your next prompt. Then check whether
    `idle_prompt` may reset it too.

### Phase 1: status indicator (MVP)

- `hook.sh`, `.claude-plugin/` manifests, `hooks/hooks.json`, and
  `claude-tmux.tmux` (options, focus reset, window icon format).
- Tests: a private server (`tmux -L bird_claude_tmux_test -f /dev/null`), a fake
  `claude` process (a symlink to `sleep`), and fixture JSON piped into
  `hook.sh`. Each test asserts `display -p '#{E:@bird_claude_tmux_window_icon}'`.
  Cases:
  - each state
  - mixed priority across panes
  - a crashed Claude
  - `join-pane` between windows
  - done reset on focus
  - `Stop` in the focused pane gives `idle`, not `done`
  - a late hook with an older timestamp is dropped
  - `SessionStart` with source `compact` keeps `working`
  - while a permission is pending, a result of another tool keeps
    `needs-input`, and a result of the same tool clears it
  - `Stop` with a running subagent keeps `working`, with only a background
    shell it gives `done`
- Checks: shellcheck on all scripts, `claude plugin validate .`, and that the
  Nerd Font icons render in your terminal. The validator also notes that the
  official plugin directory would refuse the name; we don't submit there.
- Done when: your example (one pane done plus one needing input gives "needs
  input") passes as a test and works live.

### Phase 2: fork bindings

`fork.sh` and the `prefix A` key table (`|`, `c`, `f`). Test: forking from a
window named `x-fork` names the fork `x-fork`.

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

`jump.sh`, `picker.sh` and the picker binding on `prefix C`.

### Phase 5: publish and switch your config

Merge to `master` and push (the repo is already public), then follow "Install
in your setup".

## Install in your setup

The repo is public, so TPM and Claude Code clone it without credentials.

`~/.config/tmux/tmux.conf` and `~/.claude/settings.json` are symlinks into the
`linux-distro-settings` repo. Step 1 edits that repo, and `claude plugin` writes
to the tracked settings file, so commit both changes there. Check afterwards
that `settings.json` is still a symlink.

1. In `~/.config/tmux/tmux.conf`:
   - remove `set -g @plugin 'accessd/tmux-agent-indicator'` and the five
     `@agent-indicator-*` lines
   - add `set -g @plugin 'birdthedeveloper/claude-tmux'`
   - add the icon to both catppuccin text lines (they must stay before `run`):
     `set -g @catppuccin_window_text " #{window_name}#{E:@bird_claude_tmux_window_icon}#{?window_zoomed_flag, [Z],}"`
     and the same for `@catppuccin_window_current_text`
   - add the status segment to `status-right` (decision 15), with catppuccin
     colours: `set -g @bird_claude_tmux_color_ok '#{@thm_green}'`,
     `set -g @bird_claude_tmux_color_wait '#{@thm_peach}'`,
     `set -g @bird_claude_tmux_color_icon '#{@thm_crust}'`, and
     `#{E:@bird_claude_tmux_status}` in `status-right`
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
   `claude plugin install bird-claude-tmux@bird-claude-tmux` (or use `/plugin` inside
   Claude).
5. Check: start Claude in a pane, send a prompt, and watch the window icon go
   from working to done.
6. Updates: `prefix U` for the tmux side, and
   `claude plugin update bird-claude-tmux@bird-claude-tmux` for the hooks. Update both
   together.

## Risks and known limitations

- After Esc, No, or Esc at a permission dialog, the icon keeps `working` or
  `needs-input` until your next prompt in that pane. No hook fires on an
  interrupt, and `idle_prompt` doesn't either. While it lasts, `prefix A j`
  can jump back to that pane.
- After you approve a permission, `needs-input` stays until that tool
  finishes. No hook fires on approval.
- Undocumented behavior we rely on (Phase 0 checks it): `TMUX_PANE` reaching
  hooks, and the `✳ <title>` pane title format. A title format change breaks
  name sync only, not the status icon.
- The TPM copy and the Claude plugin copy can drift if you update only one.
  The shared contract is just three pane option names, which keeps the risk
  small.
- Launching Claude through a wrapper (`node`, `npx`) changes
  `pane_current_command`. That is what `@bird_claude_tmux_process` is for.
- Async hooks do not delay Claude, but each still costs a short background
  process (about 5 ms measured for bash, jq and tmux).
- The ordering guard compares hook start times. Two events within about a
  millisecond of each other could still swap.
- Two parallel calls of the same tool: the one that finishes clears
  `needs-input` while the other still waits for approval (accepted with
  decision 13).
- Ctrl-Z in a forked pane: the shell moves on to `exec`, so the stopped Claude
  cannot be brought back with `fg`.

# Handoff

Written 2026-11-22 for the next Claude session, updated 2026-11-23.

## Where things stand

- Work happens on branch `implement`. `master` has just the initial commit.
- Decisions 1 to 14 are final, don't reopen them. All review comments are
  resolved and the user has no open questions.
- Phase 0 is done, all items answered.
- Phase 1 is done: `tests/run.sh` passes, and the user confirmed the icons and
  the live check. The live server still has the plugin loaded (6 options, 4
  hooks at `[4247]`, icon added to both window status formats); `prefix r`
  restores the formats.
- Phase 2 is done: `fork.sh` and the `prefix A` table (`|`, `c`, `f`), tested
  with a stub shell and claude. Not tried live yet.
- Phase 3 is done: name sync hooks at `pane-title-changed[4247]` and
  `window-pane-changed[4248]`. Not tried live yet.
- Phase 4 is done: `jump.sh` (`prefix A j`) and `picker.sh` (`prefix C`). The
  picker is tested through `rows`, `preview` and `toggle`, and with the real
  fzf via `FZF_DEFAULT_OPTS=--filter=...`.
- The user tried Phases 2 to 4 live. Fork of a fork can only be checked after
  `claude plugin install`, because a fork started under `--plugin-dir` has no
  hooks. PR #1 (`implement` into `master`) is open.
- Decisions 15 to 17 (session segment, needs-input message, picker per session)
  were added after that and are implemented with tests. The message test reads
  what tmux draws to a pty client. Not tried live yet. Next: Phase 5.

## Design gap: closed (Phase 0, item 10)

Another Claude could write to the wrong pane, because subprocesses of Claude
inherit `TMUX_PANE`. Fixed by the owner check in the rules for `hook.sh`.

## Phase 0 results

Run on Claude Code 2.1.323 and tmux 3.8, on a private tmux server.

| Item | Result |
|---|---|
| 1 | Yes, hooks inherit `TMUX_PANE`. |
| 2 | Both tools fire `PreToolUse` and, about 25 ms later, `PermissionRequest`, each with its tool name. Tested in modes `default` and `plan`. |
| 3 | No. Nothing fires between your Yes and `PostToolUse`. |
| 4 | No. Esc while working fires no hook, and no `idle_prompt` came within 109 s. After a normal `Stop`, `idle_prompt` comes 60 s later. |
| 5 | Yes, both at once. `/rename` was tested as a start prompt. The glyph stayed `✳` while working, no spinner was seen. |
| 6 | Yes, per pane. No explicit refresh needed. |
| 7 | `new-pane -x 60% -y 60% -c <cwd> <shell> -ic ...` works, including separate arguments. |
| 8 | Yes. `focused` is there for the active client, drops when Alacritty loses focus and comes back with it. |
| 9 | Yes, in event order, including three parallel Bash calls. |
| 10 | `CLAUDE_CODE_CHILD_SESSION` is `1` in every hook, so it is useless here. The tty works: the pane's Claude has the pane's tty, a nested `claude -p` has none. A `/fork` copy has its own tty and an empty `TMUX_PANE`. |
| 11 | None. No and Esc at the dialog both act as an interrupt ("What should Claude do instead?"): no `PermissionDenied`, no `Stop`, and no `idle_prompt` within 2 min. |

Also found:

- `background_tasks[].type` is `subagent` or `shell` (decision 14 works).
  `workflow` was not tested.
- Hooks have no controlling tty, so reading `/dev/tty` is no shortcut for the
  owner check.
- A finished background task fires `UserPromptSubmit`, so the state goes back to
  `working` until the next `Stop`.
- `idle_prompt` fires only after a completed turn, when the state is already
  `done` or `idle`, so the hook table ignores it. Its delay is the undocumented
  `messageIdleNotifThresholdMs` in `~/.claude.json` (default 60000).
- Claude sends an internal `SubagentStop` (empty `agent_type`) about 1 s after
  each `Stop`. The hook table ignores `SubagentStop`.
- Claude emits OSC 9;4 progress (tmux 3.8 `pane_pb_state`) only for Ghostty,
  iTerm2 and ConEmu, so it's no working signal inside tmux.

Items 3, 4, 11 and the second half of 8 were run by the user at the keyboard,
with a throwaway hook logger.

## How to work

1. Create branch `implement` from `plan`.
2. Run Phase 0 and write the results into this plan, including the fix for the
   gap.
3. Do Phases 1 to 5 in order, each with its tests passing.
4. After every phase, including Phase 0: make one local commit, then stop and
   wait for the user's go-ahead.

- Don't push or merge unless the user asks. Phase 5 is publishing, so it needs
  an explicit go-ahead.
- Don't touch `tmux.conf`, `~/.claude/settings.json` or the live tmux server's
  options before Phase 5. The development loop changes the live server, so ask
  before running it.
- ShellCheck 0.11.0 is installed.

## Gotchas found while testing

- In Claude's Bash tool `tmux` is a zsh alias that fails with exit code 127 and
  no message. Use `command tmux`, or put the commands in a bash script.
- The Bash tool runs inside the live tmux. Tests must use
  `env -u TMUX -u TMUX_PANE tmux -L bird_claude_tmux_test ...`, and kill that
  server at the end.
- A `TMUX` value with an empty socket path (`TMUX=,0,0`) makes tmux use the
  live server. `tests/run.sh` aborts unless the test socket path is known. It
  also waits for a killed test server to exit before starting the next one.
- Call a fake `claude` by absolute path. A stub placed first in `PATH` was not
  picked up by `zsh -ic`, and the real Claude started.
- A fake `claude` must be a binary (a symlink to `sleep`). A bash script shows
  up as `bash` in `pane_current_command`.
- Tests that need an attached client (popup, focus) work with python's
  `pty.fork()` plus `tmux -L ... attach`. Using `script` with redirected stdin
  did not attach.
- Pass `-t` to the inner `set -p` commands of `if -F` too. All tests did that.
- tmux keeps pane hooks apart: `pane-focus-in` is listed by `show-hooks -gw`,
  `client-session-changed` by `show-hooks -g`. The idempotent cleanup must look
  in both.
- Test plugin installs with `CLAUDE_CONFIG_DIR=<temp dir>`, so the real
  settings stay untouched.
