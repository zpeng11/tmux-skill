#!/bin/sh

# Ensure that a marked tmux pane exists in the current session and pipe its
# output to a fresh temporary log file.
#
# Exit codes:
# 0   success
# 2   tmux exists but the script is not running inside a tmux session
# 3   invalid arguments or invalid tmux target selection
# 4   more than one pane in the current session matches the requested mark
# 5   pane creation failed
# 6   log file creation failed
# 7   pipe-pane setup failed
# 127 tmux is not installed or not in PATH

PROGRAM_NAME=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=./common/pane_common.sh
. "$SCRIPT_DIR/common/pane_common.sh"

show_help() {
  cat <<EOF
Usage:
  $PROGRAM_NAME [options]

Ensure that a tmux pane marked as ${MARK_PREFIX}X exists in the current tmux
session, where X is a non-negative integer. The script reuses one matching pane,
creates a new pane if none exists, and ensures that the managed pane has a
managed log file receiving pane output through tmux pipe-pane.

Successful output is always JSON.

Options:
  -i, --index N         Use pane mark ${MARK_PREFIX}N.
                        N must be a non-negative integer. If omitted, allocate
                        the smallest unused non-negative index
                        in the current session.
  -w, --new-window      Create the pane in a new window when a new pane is
                        needed. This is the default.
  -s, --split-window    Create the pane by splitting an existing pane when a
                        new pane is needed.
  -H, --horizontal      Create a horizontal split. Only valid with
                        --split-window.
  -V, --vertical        Create a vertical split. Only valid with
                        --split-window. This is the default split orientation.
  -p, --percent N       Split size percentage for new split panes. Only valid
                        with --split-window.
                        Valid range: 1 to 100. Default: $DEFAULT_PERCENT.
  -t, --target-pane ID  Split relative to pane ID ID. Only valid with
                        --split-window. The target pane must belong to the
                        current tmux session. Default: the current pane.
  -h, --help            Show this help text and exit.

Behavior:
  - The script only searches for managed panes in the current tmux session.
  - If exactly one pane already uses the requested mark, that pane is reused.
  - If no pane uses the requested mark, a detached new window is created by
    default.
  - If two or more panes use the requested mark, the script fails with exit 4.
  - Use --split-window to create the pane by splitting an existing pane.
  - Split options are ignored when reusing an existing pane.
  - Split options are only valid with --split-window.
  - Reusing a pane returns its existing managed log file when it is still valid.
  - A missing managed log file is recreated only when the pane is not busy.

Output:
  On success, the script writes one JSON object to standard output:
    {"mark":"TMUX_SKILL_PANE_N","pane_id":"%12","log_file":"/path/to/log"}

  Field details:
    mark      The managed pane mark that was reused or created.
    pane_id   The tmux pane ID of the managed pane.
    log_file  The managed pane log file currently receiving pane output through
              tmux pipe-pane. This path may be reused across repeated calls.

  Errors are written to standard error. No JSON is printed on failure.

Exit codes:
  0    Success. The pane exists and has a managed log file.
  2    tmux is available, but the script is not running inside a tmux session.
  3    Invalid arguments, invalid index or percent, or an invalid target pane.
  4    More than one pane in the current session uses the same requested mark.
  5    The script could not inspect panes or could not create the required pane.
  6    The managed log file could not be created.
  7    tmux pipe-pane setup failed, or the pane is busy while its managed log
       is unavailable.
  127  tmux is not installed or is not available in PATH.

Examples:
  $PROGRAM_NAME
  $PROGRAM_NAME --index 0
  $PROGRAM_NAME --index 3
  $PROGRAM_NAME --index 8 --new-window
  $PROGRAM_NAME --split-window --index 5 --horizontal --percent 40
  $PROGRAM_NAME --split-window --target-pane %12 --vertical --percent 25
EOF
}

die() {
  exit_code=$1
  shift
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit "$exit_code"
}

INDEX=''
CREATE_MODE='new-window'
CREATE_MODE_EXPLICIT=0
ORIENTATION='vertical'
PERCENT=$DEFAULT_PERCENT
TARGET_PANE=''
SPLIT_OPTION_USED=0

while [ "$#" -gt 0 ]; do
  case $1 in
    -i|--index)
      [ "$#" -ge 2 ] || die 3 "missing value for $1"
      INDEX=$2
      shift 2
      ;;
    --index=*)
      INDEX=${1#*=}
      shift
      ;;
    -w|--new-window)
      if [ "$CREATE_MODE_EXPLICIT" -eq 1 ] && [ "$CREATE_MODE" != 'new-window' ]; then
        die 3 'cannot combine --new-window with --split-window'
      fi
      CREATE_MODE='new-window'
      CREATE_MODE_EXPLICIT=1
      shift
      ;;
    -s|--split-window)
      if [ "$CREATE_MODE_EXPLICIT" -eq 1 ] && [ "$CREATE_MODE" != 'split-window' ]; then
        die 3 'cannot combine --split-window with --new-window'
      fi
      CREATE_MODE='split-window'
      CREATE_MODE_EXPLICIT=1
      shift
      ;;
    -H|--horizontal)
      ORIENTATION='horizontal'
      SPLIT_OPTION_USED=1
      shift
      ;;
    -V|--vertical)
      ORIENTATION='vertical'
      SPLIT_OPTION_USED=1
      shift
      ;;
    -p|--percent)
      [ "$#" -ge 2 ] || die 3 "missing value for $1"
      PERCENT=$2
      SPLIT_OPTION_USED=1
      shift 2
      ;;
    --percent=*)
      PERCENT=${1#*=}
      SPLIT_OPTION_USED=1
      shift
      ;;
    -t|--target-pane)
      [ "$#" -ge 2 ] || die 3 "missing value for $1"
      TARGET_PANE=$2
      SPLIT_OPTION_USED=1
      shift 2
      ;;
    --target-pane=*)
      TARGET_PANE=${1#*=}
      SPLIT_OPTION_USED=1
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

if ! command -v tmux >/dev/null 2>&1; then
  die 127 'tmux not found in PATH'
fi

if [ -z "${TMUX:-}" ]; then
  die 2 'not running inside a tmux session'
fi

CURRENT_SESSION_ID=$(tmux display-message -p '#{session_id}' 2>/dev/null) || die 2 'unable to determine the current tmux session'
if [ -n "$INDEX" ]; then
  is_non_negative_integer "$INDEX" || die 3 'index must be a non-negative integer'
  INDEX=$(normalize_non_negative_integer "$INDEX")
else
  INDEX=$(allocate_index) || die 5 'unable to inspect panes in the current tmux session'
fi

if [ "$CREATE_MODE" != 'split-window' ] && [ "$SPLIT_OPTION_USED" -eq 1 ]; then
  die 3 'split options require --split-window'
fi

if [ "$CREATE_MODE" = 'split-window' ]; then
  is_positive_integer "$PERCENT" || die 3 'percent must be an integer between 1 and 100'
  PERCENT=$(normalize_non_negative_integer "$PERCENT")
  [ "$PERCENT" -le 100 ] || die 3 'percent must be an integer between 1 and 100'

  if [ -n "$TARGET_PANE" ]; then
    pane_in_current_session "$TARGET_PANE" || die 3 'target pane must belong to the current tmux session'
  fi
fi

MARK="${MARK_PREFIX}${INDEX}"

find_matching_pane "$INDEX" || die 5 'unable to inspect panes in the current tmux session'

case $FOUND_MATCH_COUNT in
  0)
    if [ "$CREATE_MODE" = 'new-window' ]; then
      PANE_ID=$(tmux new-window -dP -F '#{pane_id}' -t "$CURRENT_SESSION_ID" -n "skill-$INDEX" -c "$PWD" 2>/dev/null) || die 5 "failed to create a new window for $MARK"
    else
      if [ -n "$TARGET_PANE" ]; then
        SPLIT_TARGET=$TARGET_PANE
      else
        SPLIT_TARGET=${TMUX_PANE:-}

        if [ -z "$SPLIT_TARGET" ]; then
          SPLIT_TARGET=$(tmux display-message -p '#{pane_id}' 2>/dev/null) || die 5 'unable to determine the current pane'
        fi
      fi

      pane_in_current_session "$SPLIT_TARGET" || die 3 'split target must belong to the current tmux session'

      if [ "$ORIENTATION" = 'horizontal' ]; then
        PANE_ID=$(tmux split-window -dP -F '#{pane_id}' -t "$SPLIT_TARGET" -h -l "${PERCENT}%" -c "$PWD" 2>/dev/null) || die 5 "failed to create a horizontal split for $MARK"
      else
        PANE_ID=$(tmux split-window -dP -F '#{pane_id}' -t "$SPLIT_TARGET" -v -l "${PERCENT}%" -c "$PWD" 2>/dev/null) || die 5 "failed to create a vertical split for $MARK"
      fi
    fi

    tmux set-option -p -q -t "$PANE_ID" "$MARK_OPTION" "$MARK" >/dev/null 2>&1 || die 5 "failed to store mark $MARK on pane $PANE_ID"
    tmux set-option -p -q -t "$PANE_ID" "$REQUEST_STATE_OPTION" 'idle' >/dev/null 2>&1 || die 5 "failed to initialize request state for pane $PANE_ID"

    INIT_CMD=$(build_init_cmd 1)

    tmux send-keys -l -t "$PANE_ID" "$INIT_CMD"
    tmux send-keys -t "$PANE_ID" C-m

    wait_for_shell_state "$PANE_ID" 'idle' 5 || die 5 "timed out waiting for pane $PANE_ID to become ready after initialization"
    ;;
  1)
    PANE_ID=$FOUND_PANE_ID
    ;;
  *)
    die 4 "found multiple panes with mark $MARK in the current session"
    ;;
esac

REQUEST_STATE=$(tmux show-options -p -v -q -t "$PANE_ID" "$REQUEST_STATE_OPTION" 2>/dev/null)
STORED_LOG_FILE=$(tmux show-options -p -v -q -t "$PANE_ID" "$LOG_FILE_OPTION" 2>/dev/null)

if [ -n "$STORED_LOG_FILE" ] && [ -f "$STORED_LOG_FILE" ] && [ -r "$STORED_LOG_FILE" ]; then
  LOG_FILE=$STORED_LOG_FILE
else
  case $REQUEST_STATE in
    busy|busy:*)
      die 7 "managed pane $PANE_ID is busy but its managed log file is unavailable"
      ;;
  esac

  LOG_FILE=$(create_log_file "$INDEX") || die 6 "failed to create a managed log file for $MARK"

  pipe_pane_to_log "$PANE_ID" "$LOG_FILE" || die 7 "failed to pipe pane $PANE_ID output to $LOG_FILE"
  tmux set-option -p -q -t "$PANE_ID" "$LOG_FILE_OPTION" "$LOG_FILE" >/dev/null 2>&1 || die 7 "failed to store managed log file $LOG_FILE on pane $PANE_ID"
fi

output_json
