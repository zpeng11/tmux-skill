#!/bin/sh

PROGRAM_NAME=${0##*/}
MARK_OPTION='@tmux_skill_mark'
DISPATCH_STATE_OPTION='@tmux_skill_dispatch_state'

STATUS='error'
MESSAGE=''
MARK=''
PANE_ID=''
LOG_FILE=''
REQUEST_ID=''
INPUT_JSON=''
INPUT_JSON_COMPACT=''

show_help() {
  cat <<EOF
Usage:
  $PROGRAM_NAME < ensure.json

Read one ensure_tmux_skill_pane.sh JSON object from standard input and safely
reconcile the managed pane dispatch state.

Input JSON fields:
  mark      Managed pane mark.
  pane_id   Managed pane ID.
  log_file  Managed pane log file currently receiving pane output.

Output JSON fields:
  status      idle, recovered, busy, or error.
  mark        Managed pane mark from stdin.
  pane_id     Managed pane ID from stdin.
  log_file    Managed pane log file from stdin.
  request_id  Recovered or active managed request ID when known.
  message     Optional failure detail.

Behavior:
  - idle or empty dispatch state returns status=idle.
  - busy:REQUEST_ID is reconciled only if that request's end sentinel exists in
    the managed log file.
  - Legacy busy without a request ID is not safely recoverable.

Exit codes:
  0    Success. The pane is idle or was safely recovered.
  2    tmux is available, but the script is not running inside a tmux session.
  3    Invalid stdin JSON, or pane/mark mismatch.
  4    The pane still appears busy or is not safely recoverable.
  5    tmux recovery failed.
  6    Log parsing failed.
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

output_json() {
  printf '{'
  printf '"status":"%s",' "$(json_escape "$STATUS")"
  printf '"mark":'; json_string_or_null "$MARK"; printf ','
  printf '"pane_id":'; json_string_or_null "$PANE_ID"; printf ','
  printf '"log_file":'; json_string_or_null "$LOG_FILE"; printf ','
  printf '"request_id":'; json_string_or_null "$REQUEST_ID"; printf ','
  printf '"message":'; json_string_or_null "$MESSAGE"
  printf '}\n'
}

emit_and_exit() {
  exit_code=$1
  output_json
  exit "$exit_code"
}

fail_json() {
  exit_code=$1
  STATUS=$2
  MESSAGE=$3
  emit_and_exit "$exit_code"
}

extract_json_string() {
  key=$1
  printf '%s\n' "$INPUT_JSON_COMPACT" | sed -n "s/.*\"$key\":\"\\([^\"]*\\)\".*/\\1/p"
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

while [ "$#" -gt 0 ]; do
  case $1 in
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

CURRENT_STATE=$(tmux show-options -p -v -q -t "$PANE_ID" "$DISPATCH_STATE_OPTION" 2>/dev/null)
case $CURRENT_STATE in
  ''|idle)
    STATUS='idle'
    MESSAGE=''
    emit_and_exit 0
    ;;
  busy)
    STATUS='busy'
    MESSAGE='target pane uses a legacy busy state without a recoverable request id'
    emit_and_exit 4
    ;;
  busy:*)
    REQUEST_ID=${CURRENT_STATE#busy:}

    if request_has_end_sentinel "$LOG_FILE" "$REQUEST_ID"; then
      tmux set-option -p -q -t "$PANE_ID" "$DISPATCH_STATE_OPTION" 'idle' >/dev/null 2>&1 || fail_json 5 error 'failed to recover a stale busy managed pane'
      STATUS='recovered'
      MESSAGE=''
      emit_and_exit 0
    fi

    STATUS='busy'
    MESSAGE='request still appears active or is not safely recoverable'
    emit_and_exit 4
    ;;
  *)
    fail_json 5 error 'unexpected managed pane dispatch state'
    ;;
esac
