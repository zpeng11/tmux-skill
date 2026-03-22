#!/bin/sh

PROGRAM_NAME=${0##*/}
MARK_OPTION='@tmux_skill_mark'
DISPATCH_STATE_OPTION='@tmux_skill_dispatch_state'
LOCK_PREFIX='tmux-skill-dispatch:'
RECOVER_ONLY=0

STATUS='error'
MESSAGE=''
MARK=''
PANE_ID=''
LOG_FILE=''
REQUEST_ID=''
HOST_SESSION_ID=''
RESULT_EXIT_CODE=''
CLEAN_START_OFFSET=''
CLEAN_END_OFFSET=''
TIMEOUT_SECONDS=''
LOCK_CHANNEL=''
LOCK_HELD=0
COMMAND=''
INPUT_JSON=''
INPUT_JSON_COMPACT=''
RECOVERY_STATUS=''
RECOVERY_MESSAGE=''
RECOVERY_REQUEST_ID=''

show_help() {
  cat <<EOF
Usage:
  $PROGRAM_NAME --cmd COMMAND --timeout-seconds N < ensure.json
  $PROGRAM_NAME --recover-only < ensure.json

Read one ensure_tmux_skill_pane.sh JSON object from standard input, send one
single-line shell command to the managed pane, or safely reconcile its managed
dispatch state, and emit one JSON result.

Options:
  --cmd COMMAND         Single shell command string to run in the target pane.
                        Newlines are rejected.
  --timeout-seconds N   Required positive integer timeout for result polling.
  --recover-only        Reconcile the managed pane dispatch state without
                        sending a command.
  -h, --help            Show this help text and exit.

Input JSON fields:
  mark      Managed pane mark.
  pane_id   Managed pane ID.
  log_file  Managed pane log file currently receiving pane output.

Behavior:
  - Commands must return control to the managed shell.
  - Commands that replace or terminate the managed shell, such as exec, exit,
    or logout, are unsupported.
  - Host timeout stops polling only; it does not clear a busy managed pane.
  - --recover-only returns idle, recovered, busy, or error.

Output JSON fields:
  Dispatch mode:
    status             ok, busy, timeout, or error.
    mark               Managed pane mark from stdin.
    pane_id            Managed pane ID from stdin.
    log_file           Managed pane log file from stdin.
    request_id         Unique request ID for this invocation.
    timeout_seconds    Requested timeout value.
    exit_code          Command exit code when status=ok, otherwise null.
    clean_start_offset Byte offset immediately after the start sentinel.
    clean_end_offset   Byte offset of the end sentinel prefix.
    message            Optional failure detail.
  Recover mode:
    status             idle, recovered, busy, or error.
    mark               Managed pane mark from stdin.
    pane_id            Managed pane ID from stdin.
    log_file           Managed pane log file from stdin.
    request_id         Recovered or active managed request ID when known.
    message            Optional failure detail.

Exit codes:
  0    Success. The command completed, the pane is idle, or recovery succeeded.
  2    tmux is available, but the script is not running inside a tmux session.
  3    Invalid arguments, invalid stdin JSON, or pane/mark mismatch.
  4    Target pane is still busy or is not safely recoverable.
  5    tmux dispatch failed.
  6    Log parsing failed.
  7    Timed out waiting for the command result.
  127  tmux is not installed or is not available in PATH.
EOF
}

json_escape() {
  escaped=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '%s' "$escaped"
}

json_string_or_null() {
  if [ -n "$1" ]; then
    printf '"%s"' "$(json_escape "$1")"
  else
    printf 'null'
  fi
}

json_number_or_null() {
  if [ -n "$1" ]; then
    printf '%s' "$1"
  else
    printf 'null'
  fi
}

output_json() {
  if [ "$RECOVER_ONLY" -eq 1 ]; then
    printf '{'
    printf '"status":"%s",' "$(json_escape "$STATUS")"
    printf '"mark":'; json_string_or_null "$MARK"; printf ','
    printf '"pane_id":'; json_string_or_null "$PANE_ID"; printf ','
    printf '"log_file":'; json_string_or_null "$LOG_FILE"; printf ','
    printf '"request_id":'; json_string_or_null "$REQUEST_ID"; printf ','
    printf '"message":'; json_string_or_null "$MESSAGE"
    printf '}\n'
  else
    printf '{'
    printf '"status":"%s",' "$(json_escape "$STATUS")"
    printf '"mark":'; json_string_or_null "$MARK"; printf ','
    printf '"pane_id":'; json_string_or_null "$PANE_ID"; printf ','
    printf '"log_file":'; json_string_or_null "$LOG_FILE"; printf ','
    printf '"request_id":'; json_string_or_null "$REQUEST_ID"; printf ','
    printf '"timeout_seconds":'; json_number_or_null "$TIMEOUT_SECONDS"; printf ','
    printf '"exit_code":'; json_number_or_null "$RESULT_EXIT_CODE"; printf ','
    printf '"clean_start_offset":'; json_number_or_null "$CLEAN_START_OFFSET"; printf ','
    printf '"clean_end_offset":'; json_number_or_null "$CLEAN_END_OFFSET"; printf ','
    printf '"message":'; json_string_or_null "$MESSAGE"
    printf '}\n'
  fi
}

cleanup() {
  if [ "$LOCK_HELD" -eq 1 ] && [ -n "$LOCK_CHANNEL" ]; then
    tmux wait-for -U "$LOCK_CHANNEL" >/dev/null 2>&1 || true
    LOCK_HELD=0
  fi
}

emit_and_exit() {
  exit_code=$1
  cleanup
  output_json
  exit "$exit_code"
}

fail_json() {
  exit_code=$1
  STATUS=$2
  MESSAGE=$3
  emit_and_exit "$exit_code"
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

shell_single_quote() {
  escaped=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")
  printf "'%s'" "$escaped"
}

extract_json_string() {
  key=$1
  printf '%s\n' "$INPUT_JSON_COMPACT" | sed -n "s/.*\"$key\":\"\\([^\"]*\\)\".*/\\1/p"
}

byte_count() {
  wc -c < "$1" | tr -d ' '
}

byte_length() {
  printf '%s' "$1" | wc -c | tr -d ' '
}

find_fixed_offset_after() {
  search_file=$1
  pattern=$2
  min_offset=$3
  LC_ALL=C grep -aboF -- "$pattern" "$search_file" 2>/dev/null |
    awk -F: -v min="$min_offset" '$1 >= min { print $1; exit }'
}

parse_exit_code_between() {
  parse_file=$1
  start_offset=$2
  end_offset=$3
  length=$((end_offset - start_offset))

  if [ "$length" -lt 0 ]; then
    return 1
  fi

  dd if="$parse_file" bs=1 skip="$start_offset" count="$length" 2>/dev/null
}

request_has_end_sentinel() {
  request_log_file=$1
  request_id=$2
  request_end_prefix="__TMUX_SKILL_RC_BEGIN__${request_id}__"
  request_end_prefix_length=$(byte_length "$request_end_prefix")
  request_end_prefix_offset=$(find_fixed_offset_after "$request_log_file" "$request_end_prefix" 0)

  [ -n "$request_end_prefix_offset" ] || return 1

  request_end_suffix="__TMUX_SKILL_RC_END__${request_id}__"
  request_end_suffix_search_start=$((request_end_prefix_offset + request_end_prefix_length))
  request_end_suffix_offset=$(find_fixed_offset_after "$request_log_file" "$request_end_suffix" "$request_end_suffix_search_start")
  [ -n "$request_end_suffix_offset" ]
}

reconcile_dispatch_state() {
  CURRENT_STATE=$(tmux show-options -p -v -q -t "$PANE_ID" "$DISPATCH_STATE_OPTION" 2>/dev/null)
  case $CURRENT_STATE in
    ''|idle)
      RECOVERY_STATUS='idle'
      RECOVERY_MESSAGE=''
      RECOVERY_REQUEST_ID=''
      return 0
      ;;
    busy)
      RECOVERY_STATUS='busy'
      RECOVERY_MESSAGE='target pane uses a legacy busy state without a recoverable request id'
      RECOVERY_REQUEST_ID=''
      return 1
      ;;
    busy:*)
      RECOVERY_REQUEST_ID=${CURRENT_STATE#busy:}

      if request_has_end_sentinel "$LOG_FILE" "$RECOVERY_REQUEST_ID"; then
        tmux set-option -p -q -t "$PANE_ID" "$DISPATCH_STATE_OPTION" 'idle' >/dev/null 2>&1 || fail_json 5 error 'failed to recover a stale busy managed pane'
        RECOVERY_STATUS='recovered'
        RECOVERY_MESSAGE=''
        return 0
      fi

      RECOVERY_STATUS='busy'
      RECOVERY_MESSAGE='request still appears active or is not safely recoverable'
      return 1
      ;;
    *)
      fail_json 5 error 'unexpected managed pane dispatch state'
      ;;
  esac
}

trap cleanup EXIT HUP INT TERM

while [ "$#" -gt 0 ]; do
  case $1 in
    --cmd)
      [ "$#" -ge 2 ] || fail_json 3 error "missing value for $1"
      COMMAND=$2
      shift 2
      ;;
    --cmd=*)
      COMMAND=${1#*=}
      shift
      ;;
    --timeout-seconds)
      [ "$#" -ge 2 ] || fail_json 3 error "missing value for $1"
      TIMEOUT_SECONDS=$2
      shift 2
      ;;
    --timeout-seconds=*)
      TIMEOUT_SECONDS=${1#*=}
      shift
      ;;
    --recover-only)
      RECOVER_ONLY=1
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
      fail_json 3 error "unknown option: $1"
      ;;
    *)
      fail_json 3 error "unexpected argument: $1"
      ;;
  esac
done

[ "$#" -eq 0 ] || fail_json 3 error "unexpected argument: $1"
if [ "$RECOVER_ONLY" -eq 1 ]; then
  [ -z "$COMMAND" ] || fail_json 3 error '--cmd is not supported with --recover-only'
  [ -z "$TIMEOUT_SECONDS" ] || fail_json 3 error '--timeout-seconds is not supported with --recover-only'
else
  [ -n "$COMMAND" ] || fail_json 3 error 'missing required --cmd'
  [ -n "$TIMEOUT_SECONDS" ] || fail_json 3 error 'missing required --timeout-seconds'
  is_positive_integer "$TIMEOUT_SECONDS" || fail_json 3 error 'timeout must be a positive integer'
  TIMEOUT_SECONDS=$(normalize_non_negative_integer "$TIMEOUT_SECONDS")

  case $COMMAND in
    *'
'*|*'
'*)
      fail_json 3 error 'command must be a single shell string without newlines'
      ;;
  esac
fi

if ! command -v tmux >/dev/null 2>&1; then
  printf '%s: %s\n' "$PROGRAM_NAME" 'tmux not found in PATH' >&2
  exit 127
fi

if [ -z "${TMUX:-}" ]; then
  STATUS='error'
  MESSAGE='not running inside a tmux session'
  emit_and_exit 2
fi

HOST_SESSION_ID=$(tmux display-message -p '#{session_id}' 2>/dev/null) || fail_json 2 error 'unable to determine the current tmux session'

INPUT_JSON=$(cat)
[ -n "$INPUT_JSON" ] || fail_json 3 error 'expected ensure JSON on stdin'
INPUT_JSON_COMPACT=$(printf '%s' "$INPUT_JSON" | tr -d '\n')

MARK=$(extract_json_string mark)
PANE_ID=$(extract_json_string pane_id)
LOG_FILE=$(extract_json_string log_file)

[ -n "$MARK" ] || fail_json 3 error 'stdin JSON is missing mark'
[ -n "$PANE_ID" ] || fail_json 3 error 'stdin JSON is missing pane_id'
[ -n "$LOG_FILE" ] || fail_json 3 error 'stdin JSON is missing log_file'
[ -f "$LOG_FILE" ] || fail_json 6 error 'log_file does not exist'
[ -r "$LOG_FILE" ] || fail_json 6 error 'log_file is not readable'

CURRENT_PANE_SESSION_ID=$(tmux display-message -p -t "$PANE_ID" '#{session_id}' 2>/dev/null) || fail_json 3 error 'pane_id is not a live tmux pane'
[ "$CURRENT_PANE_SESSION_ID" = "$HOST_SESSION_ID" ] || fail_json 3 error 'pane_id does not belong to the current tmux session'

CURRENT_MARK=$(tmux show-options -p -v -q -t "$PANE_ID" "$MARK_OPTION" 2>/dev/null)
[ "$CURRENT_MARK" = "$MARK" ] || fail_json 3 error 'pane_id mark does not match stdin JSON'

LOCK_CHANNEL="${LOCK_PREFIX}${PANE_ID}"

tmux wait-for -L "$LOCK_CHANNEL" >/dev/null 2>&1 || fail_json 5 error 'failed to acquire dispatch lock'
LOCK_HELD=1

if ! reconcile_dispatch_state; then
  if [ "$RECOVER_ONLY" -eq 1 ]; then
    REQUEST_ID=$RECOVERY_REQUEST_ID
    STATUS=$RECOVERY_STATUS
    MESSAGE=$RECOVERY_MESSAGE
  else
    STATUS='busy'
    MESSAGE='target pane is already running a managed command'
  fi
  emit_and_exit 4
fi

if [ "$RECOVER_ONLY" -eq 1 ]; then
  REQUEST_ID=$RECOVERY_REQUEST_ID
  STATUS=$RECOVERY_STATUS
  MESSAGE=$RECOVERY_MESSAGE
  emit_and_exit 0
fi

REQUEST_ID="$(date +%s)-$$"

tmux set-option -p -q -t "$PANE_ID" "$DISPATCH_STATE_OPTION" "busy:$REQUEST_ID" >/dev/null 2>&1 || fail_json 5 error 'failed to mark target pane as busy'

LOG_START_OFFSET=$(byte_count "$LOG_FILE")
START_SENTINEL="__TMUX_SKILL_BEGIN__${REQUEST_ID}__"
END_SENTINEL_PREFIX="__TMUX_SKILL_RC_BEGIN__${REQUEST_ID}__"
END_SENTINEL_SUFFIX="__TMUX_SKILL_RC_END__${REQUEST_ID}__"
QUOTED_REQUEST_ID=$(shell_single_quote "$REQUEST_ID")
QUOTED_COMMAND=$(shell_single_quote "$COMMAND")
QUOTED_DISPATCH_STATE_OPTION=$(shell_single_quote "$DISPATCH_STATE_OPTION")
QUOTED_TARGET_PANE=$(shell_single_quote "$PANE_ID")
WRAPPED_COMMAND="__tmux_skill_req=$QUOTED_REQUEST_ID; __tmux_skill_target=$QUOTED_TARGET_PANE; __tmux_skill_dispatch_option=$QUOTED_DISPATCH_STATE_OPTION; __tmux_skill_cmd=$QUOTED_COMMAND; printf '%s%s%s' '__TMUX_SKILL_BEGIN__' \"\$__tmux_skill_req\" '__'; eval \"\$__tmux_skill_cmd\"; __tmux_skill_rc=\$?; printf '%s%s%s%s%s' '__TMUX_SKILL_RC_BEGIN__' \"\$__tmux_skill_req\" '__' \"\$__tmux_skill_rc\" '__TMUX_SKILL_RC_END__'; printf '%s%s' \"\$__tmux_skill_req\" '__'; tmux set-option -p -t \"\$__tmux_skill_target\" \"\$__tmux_skill_dispatch_option\" idle >/dev/null 2>&1"

if ! tmux send-keys -l -t "$PANE_ID" "$WRAPPED_COMMAND" >/dev/null 2>&1; then
  tmux set-option -p -q -t "$PANE_ID" "$DISPATCH_STATE_OPTION" 'idle' >/dev/null 2>&1 || true
  fail_json 5 error 'failed to send command to target pane'
fi

if ! tmux send-keys -t "$PANE_ID" C-m >/dev/null 2>&1; then
  tmux set-option -p -q -t "$PANE_ID" "$DISPATCH_STATE_OPTION" 'idle' >/dev/null 2>&1 || true
  fail_json 5 error 'failed to execute command in target pane'
fi

cleanup

START_SENTINEL_LENGTH=$(byte_length "$START_SENTINEL")
END_SENTINEL_PREFIX_LENGTH=$(byte_length "$END_SENTINEL_PREFIX")
DEADLINE=$(( $(date +%s) + TIMEOUT_SECONDS ))

while :; do
  START_SENTINEL_OFFSET=$(find_fixed_offset_after "$LOG_FILE" "$START_SENTINEL" "$LOG_START_OFFSET")
  END_SENTINEL_PREFIX_OFFSET=$(find_fixed_offset_after "$LOG_FILE" "$END_SENTINEL_PREFIX" "$LOG_START_OFFSET")

  if [ -n "$END_SENTINEL_PREFIX_OFFSET" ]; then
    END_SENTINEL_SUFFIX_SEARCH_START=$((END_SENTINEL_PREFIX_OFFSET + END_SENTINEL_PREFIX_LENGTH))
    END_SENTINEL_SUFFIX_OFFSET=$(find_fixed_offset_after "$LOG_FILE" "$END_SENTINEL_SUFFIX" "$END_SENTINEL_SUFFIX_SEARCH_START")

    if [ -n "$END_SENTINEL_SUFFIX_OFFSET" ]; then
      if [ -n "$START_SENTINEL_OFFSET" ]; then
        CLEAN_START_OFFSET=$((START_SENTINEL_OFFSET + START_SENTINEL_LENGTH))
      fi

      CLEAN_END_OFFSET=$END_SENTINEL_PREFIX_OFFSET
      EXIT_CODE_START_OFFSET=$((END_SENTINEL_PREFIX_OFFSET + END_SENTINEL_PREFIX_LENGTH))
      RESULT_EXIT_CODE=$(parse_exit_code_between "$LOG_FILE" "$EXIT_CODE_START_OFFSET" "$END_SENTINEL_SUFFIX_OFFSET")

      case $RESULT_EXIT_CODE in
        ''|*[!0-9]*)
          fail_json 6 error 'failed to parse command exit code from log'
          ;;
      esac

      if [ -z "$CLEAN_START_OFFSET" ]; then
        fail_json 6 error 'start sentinel was not found in the log'
      fi

      STATUS='ok'
      MESSAGE=''
      emit_and_exit 0
    fi
  fi

  now=$(date +%s)
  if [ "$now" -ge "$DEADLINE" ]; then
    if [ -n "$START_SENTINEL_OFFSET" ]; then
      CLEAN_START_OFFSET=$((START_SENTINEL_OFFSET + START_SENTINEL_LENGTH))
    fi

    STATUS='timeout'
    MESSAGE='timed out waiting for the command result'
    emit_and_exit 7
  fi

  sleep 1
done
