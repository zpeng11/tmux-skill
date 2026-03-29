#!/bin/sh

PROGRAM_NAME=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=./common/pane_common.sh
. "$SCRIPT_DIR/common/pane_common.sh"

BOOTSTRAP_TIMEOUT_SECONDS=5
PANE_ID=''
INDEX=''

show_help() {
  cat <<EOF
Usage:
  $PROGRAM_NAME --pane-id ID [--index N]

Adopt one existing tmux pane in the current session and configure it as a
managed tmux-skill pane.

Successful output is always JSON and matches ensure_pane.sh.

Options:
  --pane-id ID         Existing pane ID to adopt. Required.
  -i, --index N        Use pane mark ${MARK_PREFIX}N.
                       N must be a non-negative integer. If omitted, the script
                       reuses the pane's current managed index when possible,
                       otherwise allocates the smallest unused non-negative
                       index in the current session.
  -h, --help           Show this help text and exit.

Behavior:
  - The target pane must belong to the current tmux session.
  - First-time adoption requires the pane's current foreground command to be
    bash or zsh.
  - The script may replace an existing tmux pipe-pane on the target pane.
  - If the target pane is already managed under the same mark, the script is
    idempotent and reuses the existing managed log file when it is still valid.
  - If the target pane is already managed under a different mark, the script
    fails.
  - If another pane already uses the requested mark, the script fails.

Output:
  On success, the script writes one JSON object to standard output:
    {"mark":"TMUX_SKILL_PANE_N","pane_id":"%12","log_file":"/path/to/log"}

Exit codes:
  0    Success. The pane is now managed or was already managed.
  2    tmux is available, but the script is not running inside a tmux session.
  3    Invalid arguments, invalid index, invalid target pane, or unsupported
       target shell state.
  4    The target pane is already managed by a different mark, or the requested
       mark is already used by another pane.
  5    Pane inspection or pane bootstrap failed.
  6    The managed log file could not be created.
  7    tmux pipe-pane setup failed, or the pane is busy while its managed log
       is unavailable.
  127  tmux is not installed or is not available in PATH.
EOF
}

die() {
  exit_code=$1
  shift
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit "$exit_code"
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --pane-id)
      [ "$#" -ge 2 ] || die 3 "missing value for $1"
      PANE_ID=$2
      shift 2
      ;;
    --pane-id=*)
      PANE_ID=${1#*=}
      shift
      ;;
    -i|--index)
      [ "$#" -ge 2 ] || die 3 "missing value for $1"
      INDEX=$2
      shift 2
      ;;
    --index=*)
      INDEX=${1#*=}
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die 3 "unknown option: $1"
      ;;
    *)
      die 3 "unexpected argument: $1"
      ;;
  esac
done

[ "$#" -eq 0 ] || die 3 "unexpected argument: $1"
[ -n "$PANE_ID" ] || die 3 'missing required --pane-id'

if ! command -v tmux >/dev/null 2>&1; then
  die 127 'tmux not found in PATH'
fi

if [ -z "${TMUX:-}" ]; then
  die 2 'not running inside a tmux session'
fi

CURRENT_SESSION_ID=$(tmux display-message -p '#{session_id}' 2>/dev/null) || die 2 'unable to determine the current tmux session'
pane_in_current_session "$PANE_ID" || die 3 'target pane must belong to the current tmux session'

if pane_is_dead "$PANE_ID"; then
  die 5 "target pane $PANE_ID is dead"
fi

TARGET_MARK=$(tmux show-options -p -v -q -t "$PANE_ID" "$MARK_OPTION" 2>/dev/null)
TARGET_INDEX=$(mark_to_index "$TARGET_MARK" 2>/dev/null) || TARGET_INDEX=''

if [ -n "$INDEX" ]; then
  is_non_negative_integer "$INDEX" || die 3 'index must be a non-negative integer'
  INDEX=$(normalize_non_negative_integer "$INDEX")
elif [ -n "$TARGET_INDEX" ]; then
  INDEX=$TARGET_INDEX
else
  INDEX=$(allocate_index) || die 5 'unable to inspect panes in the current tmux session'
fi

MARK="${MARK_PREFIX}${INDEX}"

if [ -n "$TARGET_INDEX" ] && [ "$TARGET_INDEX" != "$INDEX" ]; then
  die 4 "target pane $PANE_ID is already managed as ${MARK_PREFIX}${TARGET_INDEX}"
fi

find_matching_pane "$INDEX" || die 5 'unable to inspect panes in the current tmux session'

case $FOUND_MATCH_COUNT in
  0)
    TARGET_ALREADY_MANAGED=0
    ;;
  1)
    if [ "$FOUND_PANE_ID" = "$PANE_ID" ]; then
      TARGET_ALREADY_MANAGED=1
    else
      die 4 "mark $MARK is already used by pane $FOUND_PANE_ID"
    fi
    ;;
  *)
    die 4 "found multiple panes with mark $MARK in the current session"
    ;;
esac

REQUEST_STATE=$(tmux show-options -p -v -q -t "$PANE_ID" "$REQUEST_STATE_OPTION" 2>/dev/null)
STORED_LOG_FILE=$(tmux show-options -p -v -q -t "$PANE_ID" "$LOG_FILE_OPTION" 2>/dev/null)

if [ "$TARGET_ALREADY_MANAGED" -eq 1 ]; then
  if [ -n "$STORED_LOG_FILE" ] && [ -f "$STORED_LOG_FILE" ] && [ -r "$STORED_LOG_FILE" ]; then
    LOG_FILE=$STORED_LOG_FILE
    output_json
    exit 0
  fi

  case $REQUEST_STATE in
    busy|busy:*)
      die 7 "managed pane $PANE_ID is busy but its managed log file is unavailable"
      ;;
  esac

  LOG_FILE=$(create_log_file "$INDEX") || die 6 "failed to create a managed log file for $MARK"
  pipe_pane_to_log "$PANE_ID" "$LOG_FILE" || die 7 "failed to pipe pane $PANE_ID output to $LOG_FILE"
  tmux set-option -p -q -t "$PANE_ID" "$LOG_FILE_OPTION" "$LOG_FILE" >/dev/null 2>&1 || die 7 "failed to store managed log file $LOG_FILE on pane $PANE_ID"
  output_json
  exit 0
fi

if pane_in_mode "$PANE_ID"; then
  die 5 "target pane $PANE_ID is in a tmux mode and cannot be adopted"
fi

CURRENT_COMMAND=$(current_pane_command "$PANE_ID")
[ -n "$CURRENT_COMMAND" ] || die 5 "unable to inspect target pane $PANE_ID"

case $CURRENT_COMMAND in
  bash|zsh)
    ;;
  *)
    die 3 "target pane $PANE_ID must currently be at a bash or zsh prompt"
    ;;
esac

tmux set-option -p -q -t "$PANE_ID" "$SHELL_STATE_OPTION" '' >/dev/null 2>&1 || die 5 "failed to reset shell state for pane $PANE_ID"
INIT_CMD=$(build_init_cmd 0)

tmux send-keys -l -t "$PANE_ID" "$INIT_CMD" >/dev/null 2>&1 || die 5 "failed to send initialization to pane $PANE_ID"
tmux send-keys -t "$PANE_ID" C-m >/dev/null 2>&1 || die 5 "failed to execute initialization in pane $PANE_ID"
wait_for_shell_state "$PANE_ID" 'idle' "$BOOTSTRAP_TIMEOUT_SECONDS" || die 5 "timed out waiting for pane $PANE_ID to become ready"

LOG_FILE=$(create_log_file "$INDEX") || die 6 "failed to create a managed log file for $MARK"
pipe_pane_to_log "$PANE_ID" "$LOG_FILE" || die 7 "failed to pipe pane $PANE_ID output to $LOG_FILE"

tmux set-option -p -q -t "$PANE_ID" "$MARK_OPTION" "$MARK" >/dev/null 2>&1 || die 5 "failed to store mark $MARK on pane $PANE_ID"
tmux set-option -p -q -t "$PANE_ID" "$REQUEST_STATE_OPTION" 'idle' >/dev/null 2>&1 || die 5 "failed to initialize request state for pane $PANE_ID"
tmux set-option -p -q -t "$PANE_ID" "$LOG_FILE_OPTION" "$LOG_FILE" >/dev/null 2>&1 || die 7 "failed to store managed log file $LOG_FILE on pane $PANE_ID"

output_json
