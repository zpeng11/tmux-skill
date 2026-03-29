#!/bin/sh

PROGRAM_NAME=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SUBMIT_SCRIPT="$SCRIPT_DIR/submit_request.sh"
WAIT_SCRIPT="$SCRIPT_DIR/wait_for_request.sh"
# shellcheck source=./common/request_common.sh
. "$SCRIPT_DIR/common/request_common.sh"

RECOVER_ONLY=0
STATUS='error'
MESSAGE=''
REQUEST_ID=''
TIMEOUT_SECONDS=''
COMMAND=''
RESULT_EXIT_CODE=''
CLEAN_START_OFFSET=''
CLEAN_END_OFFSET=''
ENSURE_FILE=''
RAW_ENSURE_JSON=''

show_help() {
  cat <<EOF
Usage:
  $PROGRAM_NAME --cmd COMMAND --timeout-seconds N < ensure.json
  $PROGRAM_NAME --recover-only < ensure.json

Read one ensure_pane.sh JSON object from standard input, send one
single-line shell command to the managed pane and wait for its result, or
safely reconcile the managed request state, and emit one JSON result.

Options:
  --cmd COMMAND         Single shell command string to run in the target pane.
                        Newlines are rejected.
  --timeout-seconds N   Required positive integer timeout for result polling.
  --recover-only        Reconcile the managed request state without
                        sending a command.
  -h, --help            Show this help text and exit.

Behavior:
  - The synchronous request path is implemented as submit + wait over the
    managed pane request protocol.
  - Commands must return control to the managed shell.
  - Commands that replace or terminate the managed shell, such as exec, exit,
    or logout, are unsupported.
  - Host timeout stops polling only; it does not clear a busy managed request.
  - If the pane returns to its shell prompt without emitting a completion
    sentinel, request mode returns interrupted.
  - --recover-only returns idle, recovered, interrupted, busy, or error.

Output JSON fields:
  Request mode:
    status             ok, busy, interrupted, timeout, or error.
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
    status             idle, recovered, interrupted, busy, or error.
    mark               Managed pane mark from stdin.
    pane_id            Managed pane ID from stdin.
    log_file           Managed pane log file from stdin.
    request_id         Recovered or active managed request ID when known.
    message            Optional failure detail.

Exit codes:
  0    Success. The command completed, the pane is idle, or recovery succeeded.
  130  The managed request returned to the shell without a completion
       sentinel.
  2    tmux is available, but the script is not running inside a tmux session.
  3    Invalid arguments, invalid stdin JSON, or pane/mark mismatch.
  4    Target pane is still busy or is not safely recoverable.
  5    tmux request handling failed.
  6    Log parsing failed.
  7    Timed out waiting for the command result.
  127  tmux is not installed or is not available in PATH.
EOF
}

output_json() {
  if [ "$RECOVER_ONLY" -eq 1 ]; then
    printf '{'
    printf '"status":"%s",' "$(json_escape "$STATUS")"
    printf '"mark":'; tmux_skill_json_string_or_null "$TMUX_SKILL_MARK"; printf ','
    printf '"pane_id":'; tmux_skill_json_string_or_null "$TMUX_SKILL_PANE_ID"; printf ','
    printf '"log_file":'; tmux_skill_json_string_or_null "$TMUX_SKILL_LOG_FILE"; printf ','
    printf '"request_id":'; tmux_skill_json_string_or_null "$REQUEST_ID"; printf ','
    printf '"message":'; tmux_skill_json_string_or_null "$MESSAGE"
    printf '}\n'
  else
    printf '{'
    printf '"status":"%s",' "$(json_escape "$STATUS")"
    printf '"mark":'; tmux_skill_json_string_or_null "$TMUX_SKILL_MARK"; printf ','
    printf '"pane_id":'; tmux_skill_json_string_or_null "$TMUX_SKILL_PANE_ID"; printf ','
    printf '"log_file":'; tmux_skill_json_string_or_null "$TMUX_SKILL_LOG_FILE"; printf ','
    printf '"request_id":'; tmux_skill_json_string_or_null "$REQUEST_ID"; printf ','
    printf '"timeout_seconds":'; tmux_skill_json_number_or_null "$TIMEOUT_SECONDS"; printf ','
    printf '"exit_code":'; tmux_skill_json_number_or_null "$RESULT_EXIT_CODE"; printf ','
    printf '"clean_start_offset":'; tmux_skill_json_number_or_null "$CLEAN_START_OFFSET"; printf ','
    printf '"clean_end_offset":'; tmux_skill_json_number_or_null "$CLEAN_END_OFFSET"; printf ','
    printf '"message":'; tmux_skill_json_string_or_null "$MESSAGE"
    printf '}\n'
  fi
}

cleanup() {
  tmux_skill_cleanup

  if [ -n "$ENSURE_FILE" ] && [ -f "$ENSURE_FILE" ]; then
    rm -f "$ENSURE_FILE"
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

extract_payload_string() {
  payload_compact=$1
  key=$2
  tmux_skill_extract_json_string_from_compact "$payload_compact" "$key"
}

extract_payload_number() {
  payload_compact=$1
  key=$2
  tmux_skill_extract_json_number_from_compact "$payload_compact" "$key"
}

load_child_payload() {
  payload=$1
  payload_compact=$(printf '%s' "$payload" | tr -d '\n')

  STATUS=$(extract_payload_string "$payload_compact" status)
  TMUX_SKILL_MARK=$(extract_payload_string "$payload_compact" mark)
  TMUX_SKILL_PANE_ID=$(extract_payload_string "$payload_compact" pane_id)
  TMUX_SKILL_LOG_FILE=$(extract_payload_string "$payload_compact" log_file)
  REQUEST_ID=$(extract_payload_string "$payload_compact" request_id)
  MESSAGE=$(extract_payload_string "$payload_compact" message)
  SEARCH_START_OFFSET=$(extract_payload_number "$payload_compact" search_start_offset)
  RESULT_EXIT_CODE=$(extract_payload_number "$payload_compact" exit_code)
  CLEAN_START_OFFSET=$(extract_payload_number "$payload_compact" clean_start_offset)
  CLEAN_END_OFFSET=$(extract_payload_number "$payload_compact" clean_end_offset)

  case $SEARCH_START_OFFSET in
    null)
      SEARCH_START_OFFSET=''
      ;;
  esac

  case $RESULT_EXIT_CODE in
    null)
      RESULT_EXIT_CODE=''
      ;;
  esac

  case $CLEAN_START_OFFSET in
    null)
      CLEAN_START_OFFSET=''
      ;;
  esac

  case $CLEAN_END_OFFSET in
    null)
      CLEAN_END_OFFSET=''
      ;;
  esac
}

run_recover_only() {
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
  run_recover_only
fi

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

RAW_ENSURE_JSON=$(cat)
[ -n "$RAW_ENSURE_JSON" ] || fail_json 3 error 'expected ensure JSON on stdin'

ENSURE_FILE=$(mktemp "${TMPDIR:-/tmp}/tmux-skill.run.XXXXXX.json") || fail_json 5 error 'failed to create a temporary request file'
printf '%s' "$RAW_ENSURE_JSON" > "$ENSURE_FILE" || fail_json 5 error 'failed to stage ensure JSON for child scripts'

SUBMIT_OUTPUT=$("$SUBMIT_SCRIPT" --cmd "$COMMAND" < "$ENSURE_FILE")
submit_rc=$?
load_child_payload "$SUBMIT_OUTPUT"

if [ "$submit_rc" -ne 0 ] || [ "$STATUS" != 'started' ]; then
  RESULT_EXIT_CODE=''
  CLEAN_START_OFFSET=''
  CLEAN_END_OFFSET=''
  emit_and_exit "$submit_rc"
fi

WAIT_OUTPUT=$("$WAIT_SCRIPT" --request-id "$REQUEST_ID" --search-start-offset "$SEARCH_START_OFFSET" --timeout-seconds "$TIMEOUT_SECONDS" < "$ENSURE_FILE")
wait_rc=$?
load_child_payload "$WAIT_OUTPUT"
emit_and_exit "$wait_rc"
