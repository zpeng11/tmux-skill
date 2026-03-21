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
MARK_OPTION='@tmux_skill_mark'
MARK_PREFIX='TMUX_SKILL_PANE_'
DEFAULT_PERCENT=30

show_help() {
  cat <<EOF
Usage:
  $PROGRAM_NAME [options]

Ensure that a tmux pane marked as ${MARK_PREFIX}X exists in the current tmux
session, where X is a non-negative integer. The script reuses one matching pane,
creates a new pane if none exists, and always pipes pane output to a fresh
temporary log file.

Successful output is always JSON.

Options:
  -i, --index N         Use pane mark ${MARK_PREFIX}N.
                        N must be a non-negative integer. If omitted, allocate
                        the smallest unused non-negative index
                        in the current session.
  -w, --new-window      Create the pane in a new window instead of splitting an
                        existing pane.
  -H, --horizontal      Create a horizontal split when a new split pane is
                        needed.
  -V, --vertical        Create a vertical split when a new split pane is
                        needed. This is the default.
  -p, --percent N       Split size percentage for new split panes.
                        Valid range: 1 to 100. Default: $DEFAULT_PERCENT.
  -t, --target-pane ID  Split relative to pane ID ID when creating a new split
                        pane. The target pane must belong to the current tmux
                        session. Default: the current pane.
  -h, --help            Show this help text and exit.

Behavior:
  - The script only searches for managed panes in the current tmux session.
  - If exactly one pane already uses the requested mark, that pane is reused.
  - If no pane uses the requested mark, a new pane is created.
  - If two or more panes use the requested mark, the script fails with exit 4.
  - Split options are ignored when reusing an existing pane.
  - --target-pane is only used when a new split pane must be created.

Output:
  On success, the script writes one JSON object to standard output:
    {"mark":"TMUX_SKILL_PANE_N","log_file":"/path/to/log"}

  Field details:
    mark      The managed pane mark that was reused or created.
    log_file  The fresh temporary log file receiving pane output through
              tmux pipe-pane.

  Errors are written to standard error. No JSON is printed on failure.

Exit codes:
  0    Success. The pane exists and its output is piped to a fresh log file.
  2    tmux is available, but the script is not running inside a tmux session.
  3    Invalid arguments, invalid index or percent, or an invalid target pane.
  4    More than one pane in the current session uses the same requested mark.
  5    The script could not inspect panes or could not create the required pane.
  6    The temporary log file could not be created.
  7    tmux pipe-pane failed for the selected pane.
  127  tmux is not installed or is not available in PATH.

Examples:
  $PROGRAM_NAME
  $PROGRAM_NAME --index 0
  $PROGRAM_NAME --index 3
  $PROGRAM_NAME --index 5 --horizontal --percent 40
  $PROGRAM_NAME --index 8 --new-window
  $PROGRAM_NAME --target-pane %12 --vertical --percent 25
EOF
}

die() {
  exit_code=$1
  shift
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit "$exit_code"
}

normalize_non_negative_integer() {
  normalized=$(printf '%s' "$1" | sed 's/^0*//')

  if [ -z "$normalized" ]; then
    normalized=0
  fi

  printf '%s\n' "$normalized"
}

is_non_negative_integer() {
  case $1 in
    ''|*[!0-9]*)
      return 1
      ;;
  esac

  normalize_non_negative_integer "$1" >/dev/null
}

is_positive_integer() {
  is_non_negative_integer "$1" || return 1

  normalized=$(normalize_non_negative_integer "$1")
  [ "$normalized" -gt 0 ] 2>/dev/null
}

mark_to_index() {
  case $1 in
    "${MARK_PREFIX}"*)
      suffix=${1#"$MARK_PREFIX"}
      ;;
    *)
      return 1
      ;;
  esac

  is_non_negative_integer "$suffix" || return 1
  normalize_non_negative_integer "$suffix"
}

list_current_session_panes() {
  window_ids=$(tmux list-windows -t "$CURRENT_SESSION_ID" -F '#{window_id}') || return 1

  for window_id in $window_ids; do
    tmux list-panes -t "$window_id" -F '#{pane_id}' || return 1
  done
}

pane_in_current_session() {
  pane_session_id=$(tmux display-message -p -t "$1" '#{session_id}' 2>/dev/null) || return 1
  [ "$pane_session_id" = "$CURRENT_SESSION_ID" ]
}

find_matching_pane() {
  requested_index=$1
  FOUND_PANE_ID=''
  FOUND_MATCH_COUNT=0
  pane_ids=$(list_current_session_panes) || return 1

  for pane_id in $pane_ids; do
    pane_mark=$(tmux show-options -p -v -q -t "$pane_id" "$MARK_OPTION")
    pane_index=$(mark_to_index "$pane_mark" 2>/dev/null) || continue

    if [ "$pane_index" = "$requested_index" ]; then
      FOUND_MATCH_COUNT=$((FOUND_MATCH_COUNT + 1))
      FOUND_PANE_ID=$pane_id
    fi
  done
}

allocate_index() {
  used_indexes=' '
  pane_ids=$(list_current_session_panes) || return 1

  for pane_id in $pane_ids; do
    pane_mark=$(tmux show-options -p -v -q -t "$pane_id" "$MARK_OPTION")
    pane_index=$(mark_to_index "$pane_mark" 2>/dev/null) || continue

    case $used_indexes in
      *" $pane_index "*)
        ;;
      *)
        used_indexes="${used_indexes}${pane_index} "
        ;;
    esac
  done

  next_index=0
  while :; do
    case $used_indexes in
      *" $next_index "*)
        next_index=$((next_index + 1))
        ;;
      *)
        printf '%s\n' "$next_index"
        return 0
        ;;
    esac
  done
}

shell_single_quote() {
  escaped=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")
  printf "'%s'" "$escaped"
}

json_escape() {
  escaped=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '%s' "$escaped"
}

output_json() {
  printf '{'
  printf '"mark":"%s",' "$(json_escape "$MARK")"
  printf '"log_file":"%s"' "$(json_escape "$LOG_FILE")"
  printf '}\n'
}

INDEX=''
NEW_WINDOW=0
ORIENTATION='vertical'
PERCENT=$DEFAULT_PERCENT
TARGET_PANE=''

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
      NEW_WINDOW=1
      shift
      ;;
    -H|--horizontal)
      ORIENTATION='horizontal'
      shift
      ;;
    -V|--vertical)
      ORIENTATION='vertical'
      shift
      ;;
    -p|--percent)
      [ "$#" -ge 2 ] || die 3 "missing value for $1"
      PERCENT=$2
      shift 2
      ;;
    --percent=*)
      PERCENT=${1#*=}
      shift
      ;;
    -t|--target-pane)
      [ "$#" -ge 2 ] || die 3 "missing value for $1"
      TARGET_PANE=$2
      shift 2
      ;;
    --target-pane=*)
      TARGET_PANE=${1#*=}
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
CURRENT_SESSION_NAME=$(tmux display-message -p '#{session_name}' 2>/dev/null) || die 2 'unable to determine the current tmux session name'

if [ -n "$INDEX" ]; then
  is_non_negative_integer "$INDEX" || die 3 'index must be a non-negative integer'
  INDEX=$(normalize_non_negative_integer "$INDEX")
else
  INDEX=$(allocate_index) || die 5 'unable to inspect panes in the current tmux session'
fi

is_positive_integer "$PERCENT" || die 3 'percent must be an integer between 1 and 100'
PERCENT=$(normalize_non_negative_integer "$PERCENT")
[ "$PERCENT" -le 100 ] || die 3 'percent must be an integer between 1 and 100'

if [ -n "$TARGET_PANE" ]; then
  pane_in_current_session "$TARGET_PANE" || die 3 'target pane must belong to the current tmux session'
fi

MARK="${MARK_PREFIX}${INDEX}"

find_matching_pane "$INDEX" || die 5 'unable to inspect panes in the current tmux session'

case $FOUND_MATCH_COUNT in
  0)
    CREATED=1

    if [ "$NEW_WINDOW" -eq 1 ]; then
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

    INIT_CMD=" _mark_idle() { tmux set-option -p @pane_state 'idle' >/dev/null 2>&1; tmux wait-for -S ${MARK}_IDLE >/dev/null 2>&1; };"
    INIT_CMD="$INIT_CMD _mark_busy() { tmux set-option -p @pane_state 'busy' >/dev/null 2>&1; };"
    INIT_CMD="$INIT_CMD if [ -n \"\${ZSH_VERSION:-}\" ]; then"
    INIT_CMD="$INIT_CMD   autoload -Uz add-zsh-hook 2>/dev/null;"
    INIT_CMD="$INIT_CMD   add-zsh-hook precmd _mark_idle 2>/dev/null || precmd_functions+=(_mark_idle);"
    INIT_CMD="$INIT_CMD   add-zsh-hook preexec _mark_busy 2>/dev/null || preexec_functions+=(_mark_busy);"
    INIT_CMD="$INIT_CMD elif [ -n \"\${BASH_VERSION:-}\" ]; then"
    INIT_CMD="$INIT_CMD   PROMPT_COMMAND=\"_mark_idle;\${PROMPT_COMMAND:-}\";"
    INIT_CMD="$INIT_CMD   trap '_mark_busy' DEBUG;"
    INIT_CMD="$INIT_CMD fi;"
    INIT_CMD="$INIT_CMD _mark_idle; clear;"

    tmux send-keys -l -t "$PANE_ID" "$INIT_CMD"
    tmux send-keys -t "$PANE_ID" C-m
    ;;
  1)
    CREATED=0
    PANE_ID=$FOUND_PANE_ID
    ;;
  *)
    die 4 "found multiple panes with mark $MARK in the current session"
    ;;
esac

LOG_FILE=$(mktemp "${TMPDIR:-/tmp}/tmux-skill.${INDEX}.XXXXXX.log") || die 6 "failed to create a temporary log file for $MARK"
QUOTED_LOG_FILE=$(shell_single_quote "$LOG_FILE")

tmux pipe-pane -O -t "$PANE_ID" "exec cat >> $QUOTED_LOG_FILE" >/dev/null 2>&1 || die 7 "failed to pipe pane $PANE_ID output to $LOG_FILE"

output_json
