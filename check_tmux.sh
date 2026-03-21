#!/bin/sh

# Exit codes:
# 0   tmux exists and current shell is inside a tmux session
# 2   tmux exists but current shell is not inside a tmux session
# 127 tmux is not installed or not in PATH

if ! command -v tmux >/dev/null 2>&1; then
  printf '%s\n' "tmux not found in PATH" >&2
  exit 127
fi

if [ -z "${TMUX:-}" ]; then
  printf '%s\n' "not running inside a tmux session" >&2
  exit 2
fi

exit 0
