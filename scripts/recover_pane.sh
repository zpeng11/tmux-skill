#!/bin/sh

PROGRAM_NAME=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=./common/request_common.sh
. "$SCRIPT_DIR/common/request_common.sh"

STATUS='error'
REQUEST_ID=''
MESSAGE=''

show_help() {
  cat <<EOF
Usage:
  $PROGRAM_NAME < ensure.json

Read one ensure_pane.sh JSON object from standard input and safely
reconcile the managed request state.

Input JSON fields:
  mark      Managed pane mark.
  pane_id   Managed pane ID.
  log_file  Managed pane log file currently receiving pane output.

Output JSON fields:
  status      idle, recovered, interrupted, busy, or error.
  mark        Managed pane mark from stdin.
  pane_id     Managed pane ID from stdin.
  log_file    Managed pane log file from stdin.
  request_id  Recovered or active managed request ID when known.
  message     Optional failure detail.

Behavior:
  - idle or empty request state returns status=idle.
  - busy:REQUEST_ID is reconciled only if that request's end sentinel exists in
    the managed log file.
  - busy:REQUEST_ID with no end sentinel is reconciled as interrupted once the
    pane has already returned to its shell prompt.
  - Legacy busy without a request ID is not safely recoverable.

Exit codes:
  0    Success. The pane is idle or was safely reconciled.
  2    tmux is available, but the script is not running inside a tmux session.
  3    Invalid stdin JSON, or pane/mark mismatch.
  4    The pane still appears busy or is not safely recoverable.
  5    tmux recovery failed.
  6    Log parsing failed.
  127  tmux is not installed or is not available in PATH.
EOF
}

output_json() {
  printf '{'
  printf '"status":"%s",' "$(json_escape "$STATUS")"
  printf '"mark":'; tmux_skill_json_string_or_null "$TMUX_SKILL_MARK"; printf ','
  printf '"pane_id":'; tmux_skill_json_string_or_null "$TMUX_SKILL_PANE_ID"; printf ','
  printf '"log_file":'; tmux_skill_json_string_or_null "$TMUX_SKILL_LOG_FILE"; printf ','
  printf '"request_id":'; tmux_skill_json_string_or_null "$REQUEST_ID"; printf ','
  printf '"message":'; tmux_skill_json_string_or_null "$MESSAGE"
  printf '}\n'
}

cleanup() {
  tmux_skill_cleanup
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

trap cleanup EXIT HUP INT TERM

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

tmux_skill_require_tmux_session || fail_json "$TMUX_SKILL_ERROR_CODE" error "$TMUX_SKILL_ERROR_MESSAGE"
tmux_skill_load_ensure_json_from_stdin || fail_json "$TMUX_SKILL_ERROR_CODE" error "$TMUX_SKILL_ERROR_MESSAGE"
tmux_skill_lock_request || fail_json "$TMUX_SKILL_ERROR_CODE" error "$TMUX_SKILL_ERROR_MESSAGE"

tmux_skill_reconcile_request_state
reconcile_rc=$?

case $reconcile_rc in
  0)
    REQUEST_ID=$TMUX_SKILL_RECOVERY_REQUEST_ID
    STATUS=$TMUX_SKILL_RECOVERY_STATUS
    MESSAGE=$TMUX_SKILL_RECOVERY_MESSAGE
    emit_and_exit 0
    ;;
  1)
    REQUEST_ID=$TMUX_SKILL_RECOVERY_REQUEST_ID
    STATUS=$TMUX_SKILL_RECOVERY_STATUS
    MESSAGE=$TMUX_SKILL_RECOVERY_MESSAGE
    emit_and_exit 4
    ;;
  *)
    fail_json "$TMUX_SKILL_ERROR_CODE" error "$TMUX_SKILL_ERROR_MESSAGE"
    ;;
esac
