#!/bin/sh

PROGRAM_NAME=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RUN_SCRIPT="$SCRIPT_DIR/run_in_pane.sh"

. "$SCRIPT_DIR/common/pane_common.sh"

fail_json() {
  message=$1
  printf '{'
  printf '"status":"error",'
  printf '"mark":null,'
  printf '"pane_id":null,'
  printf '"log_file":null,'
  printf '"request_id":null,'
  printf '"message":"%s"' "$(json_escape "$message")"
  printf '}\n'
  exit 3
}

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
      fail_json "unknown option: $1"
      ;;
    *)
      fail_json "unexpected argument: $1"
      ;;
  esac
done

[ "$#" -eq 0 ] || {
  fail_json "unexpected argument: $1"
}

exec "$RUN_SCRIPT" --recover-only
