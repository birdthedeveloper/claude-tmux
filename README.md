# claude-tmux

Shows what Claude Code is doing in every tmux window, and adds a few keys to
work with Claude panes.

- A status icon per window: idle, working, needs input, or done. If a window
  has several Claude panes, the most urgent state wins.
- A status-right segment for the current session, a round pill like
  catppuccin's modules: green while its Claude panes are fine, orange while one
  waits for you.
- A short status-line message when a Claude pane starts waiting for you.
- Fork the Claude session of a pane into a split, a new window, or a floating
  pane.
- The window name follows Claude's session title, until you rename the window
  yourself.
- Jump to the next pane that needs you, and a fuzzy picker of all Claude panes
  with a live preview.

It never types into a pane.

The repo has two halves: a tmux plugin (installed with TPM) and a Claude Code
plugin, which ships the hooks that report Claude's state. Install both.

## Requirements

- tmux 3.2 or newer (3.8 for the floating fork)
- bash 5 or newer, jq
- fzf for the picker (tested with 0.75)
- a Nerd Font for the default icons

## Install

tmux side, in `tmux.conf`:

```tmux
set -g @plugin 'birdthedeveloper/claude-tmux'
```

Then press `prefix I`. Put the icon into your window status, for example
right after the window name:

```tmux
set -g window-status-format " #I #{window_name}#{E:@bird_claude_tmux_window_icon} "
set -g window-status-current-format " #I #{window_name}#{E:@bird_claude_tmux_window_icon} "
```

With catppuccin, add it to `@catppuccin_window_text` and
`@catppuccin_window_current_text` instead, before catppuccin is loaded.

The session segment goes into `status-right`. It is empty when the session has
no Claude pane:

```tmux
set -ag status-right "#{E:@bird_claude_tmux_status}"
```

With catppuccin, you can take its colours:

```tmux
set -g @bird_claude_tmux_color_ok '#{@thm_green}'
set -g @bird_claude_tmux_color_wait '#{@thm_peach}'
set -g @bird_claude_tmux_color_icon '#{@thm_crust}'
```

Claude Code side:

```sh
claude plugin marketplace add birdthedeveloper/claude-tmux
claude plugin install bird-claude-tmux@bird-claude-tmux
```

Restart running Claude sessions to load the hooks. Update both halves
together: `prefix U` for tmux, and
`claude plugin update bird-claude-tmux@bird-claude-tmux` for Claude.

## Keys

| Key | Action |
|---|---|
| `prefix A` then `\|` | fork the pane's Claude session into a split on the right |
| `prefix A` then `c` | fork it into a new window next to the current one |
| `prefix A` then `f` | fork it into a floating pane |
| `prefix A` then `j` | jump to the next pane that needs you (needs input first, then done); press again for the next one |
| `prefix C` | picker of the Claude panes in the current session; `enter` switches, `ctrl-w` toggles the preview between the pane and its whole window |

A fork is named `<window>-fork`, and a fork of a fork keeps one `-fork`.

When a pane starts to wait for you (a permission dialog, a question, a plan to
approve), the status line shows `Claude needs input in <session>:<window>
<name>` for 4 seconds, unless you are looking at that pane. Nothing is shown
when Claude is done.

## Window names

While a window is unnamed, it takes the title of its active Claude pane (the
session's topic, or what you set with `/rename` or `claude -n`). Once you
rename the window yourself, it stays that way. To hand it back to Claude:
`prefix :` then `set -w automatic-rename on`.

## Options

| Option | Default |
|---|---|
| `@bird_claude_tmux_icon_idle` | `󰚩` (nf-md-robot) |
| `@bird_claude_tmux_icon_working` | `` (nf-fa-hourglass_half) |
| `@bird_claude_tmux_icon_needs_input` | `` (nf-fa-question_circle) |
| `@bird_claude_tmux_icon_done` | `` (nf-fa-check_circle) |
| `@bird_claude_tmux_key` | `A` |
| `@bird_claude_tmux_picker_key` | `C` |
| `@bird_claude_tmux_sync_title` | `on` |
| `@bird_claude_tmux_color_ok` | `green`, the session segment while nothing waits |
| `@bird_claude_tmux_color_wait` | `colour208` (orange), the session segment while a pane needs input |
| `@bird_claude_tmux_color_icon` | `black`, the icon on the session segment |
| `@bird_claude_tmux_process` | `claude`, the process name a Claude pane runs |

Set them before the plugin loads.

## Known limitations

- `done` clears when you focus the pane. If Claude finishes in the pane you are
  looking at, it goes straight to idle.
- After Esc, or after you deny a permission, the icon keeps working or needs
  input until your next prompt in that pane. Claude Code fires no hook for
  these.
- After you approve a permission, needs input stays until the tool finishes.

## Development

```sh
tests/run.sh                                   # private tmux server, fake Claude processes
claude --plugin-dir ~/path/to/claude-tmux      # load the hooks for one session
tmux run-shell ~/path/to/claude-tmux/claude-tmux.tmux
```
