# claude-tmux

tmux plugin (TPM) that shows Claude Code state per window. Plan: `PLAN.md`.

## Rules

- Never type into a terminal automatically. No `tmux send-keys`, no
  `paste-buffer`, no writing to a pane's tty, and no other way of injecting
  input into an existing pane. That input can merge with text the user has
  half-typed, be misread by vim mode, or trigger actions in Claude. Starting a
  new pane or window with a command (`split-window "claude ..."`) is fine.
