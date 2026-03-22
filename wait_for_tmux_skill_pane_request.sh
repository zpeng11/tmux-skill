#!/bin/sh

PROGRAM_NAME=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=./tmux_skill_request_common.sh
. "$SCRIPT_DIR/tmux_skill_request_common.sh"

STATUS='error'
MESSAGE=''
REQUEST_ID=''
TIMEOUT_SECONDS=''
QUERY_ONLY=0
SEARCH_START_OFFSET=0

show_help() {
  cat <<EOF
Usage:
  $PROGRAM_NAME --request-id ID --timeout-seconds N [--search-start-offset M] < ensure.json
  $PROGRAM_NAME --request-id ID --query-only [--search-start-offset M] < ensure.json

Read one ensure_tmux_skill_pane.sh JSON object from standard input, then wait
for or query one managed request result.

Options:
  --request-id ID        Managed request ID to observe.
  --timeout-seconds N    Positive integer timeout for polling.
  --query-only           Check once without blocking.
  --search-start-offset  Optional non-negative byte offset from which to start
                         searching the managed log. Default: 0.
  -h, --help             Show this help text and exit.

Output JSON fields:
  status              ok, pending, timeout, or error.
  mark                Managed pane mark from stdin.
  pane_id             Managed pane ID from stdin.
  log_file            Managed pane log file from stdin.
  request_id          Requested managed request ID.
  exit_code           Command exit code when status=ok, otherwise null.
  clean_start_offset  Byte offset immediately after the start sentinel when it
                      has been observed, otherwise null.
  clean_end_offset    Byte offset of the end sentinel prefix when status=ok,
                      otherwise null.
  message             Optional failure detail.

Exit codes:
  0    The managed request completed.
  2    tmux is available, but the script is not running inside a tmux session.
  3    Invalid arguments, invalid stdin JSON, or pane/mark mismatch.
  4    The managed request is still pending in query-only mode.
  5    The requested result is not active and no matching completion was found.
  6    Log parsing failed.
  7    Timed out waiting for the managed request result.
  127  tmux is not installed or is not available in PATH.
EOF
}

output_json() {
  printf '{'
  printf '"status":"%s",' "$(tmux_skill_json_escape "$STATUS")"
  printf '"mark":'; tmux_skill_json_string_or_null "$TMUX_SKILL_MARK"; printf ','
  printf '"pane_id":'; tmux_skill_json_string_or_null "$TMUX_SKILL_PANE_ID"; printf ','
  printf '"log_file":'; tmux_skill_json_string_or_null "$TMUX_SKILL_LOG_FILE"; printf ','
  printf '"request_id":'; tmux_skill_json_string_or_null "$REQUEST_ID"; printf ','
  printf '"exit_code":'; tmux_skill_json_number_or_null "$TMUX_SKILL_RESULT_EXIT_CODE"; printf ','
  printf '"clean_start_offset":'; tmux_skill_json_number_or_null "$TMUX_SKILL_CLEAN_START_OFFSET"; printf ','
  printf '"clean_end_offset":'; tmux_skill_json_number_or_null "$TMUX_SKILL_CLEAN_END_OFFSET"; printf ','
  printf '"message":'; tmux_skill_json_string_or_null "$MESSAGE"
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

while [ "$#" -gt 0 ]; do
  case $1 in
    --request-id)
      [ "$#" -ge 2 ] || fail_json 3 error "missing value for $1"
      REQUEST_ID=$2
      shift 2
      ;;
    --request-id=*)
      REQUEST_ID=${1#*=}
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
    --search-start-offset)
      [ "$#" -ge 2 ] || fail_json 3 error "missing value for $1"
      SEARCH_START_OFFSET=$2
      shift 2
      ;;
    --search-start-offset=*)
      SEARCH_START_OFFSET=${1#*=}
      shift
      ;;
    --query-only)
      QUERY_ONLY=1
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
[ -n "$REQUEST_ID" ] || fail_json 3 error 'missing required --request-id'

if [ "$QUERY_ONLY" -eq 1 ]; then
  [ -z "$TIMEOUT_SECONDS" ] || fail_json 3 error '--timeout-seconds is not supported with --query-only'
else
  [ -n "$TIMEOUT_SECONDS" ] || fail_json 3 error 'missing required --timeout-seconds'
  tmux_skill_is_positive_integer "$TIMEOUT_SECONDS" || fail_json 3 error 'timeout must be a positive integer'
  TIMEOUT_SECONDS=$(tmux_skill_normalize_non_negative_integer "$TIMEOUT_SECONDS")
fi

tmux_skill_is_non_negative_integer "$SEARCH_START_OFFSET" || fail_json 3 error 'search-start-offset must be a non-negative integer'
SEARCH_START_OFFSET=$(tmux_skill_normalize_non_negative_integer "$SEARCH_START_OFFSET")

tmux_skill_require_tmux_session || fail_json "$TMUX_SKILL_ERROR_CODE" error "$TMUX_SKILL_ERROR_MESSAGE"
tmux_skill_load_ensure_json_from_stdin || fail_json "$TMUX_SKILL_ERROR_CODE" error "$TMUX_SKILL_ERROR_MESSAGE"

if [ "$QUERY_ONLY" -eq 0 ]; then
  DEADLINE=$(( $(date +%s) + TIMEOUT_SECONDS ))
fi

while :; do
  tmux_skill_find_request_result "$REQUEST_ID" "$SEARCH_START_OFFSET"
  find_rc=$?

  case $find_rc in
    0)
      STATUS='ok'
      MESSAGE=''
      emit_and_exit 0
      ;;
    1)
      ;;
    *)
      fail_json "$TMUX_SKILL_ERROR_CODE" error "$TMUX_SKILL_ERROR_MESSAGE"
      ;;
  esac

  CURRENT_STATE=$(tmux_skill_current_request_state)

  if [ "$CURRENT_STATE" = "busy:$REQUEST_ID" ]; then
    if [ "$QUERY_ONLY" -eq 1 ]; then
      STATUS='pending'
      MESSAGE='request still appears active'
      emit_and_exit 4
    fi

    now=$(date +%s)
    if [ "$now" -ge "$DEADLINE" ]; then
      STATUS='timeout'
      MESSAGE='timed out waiting for the command result'
      emit_and_exit 7
    fi

    sleep 1
    continue
  fi

  STATUS='error'
  MESSAGE='request is not active and no matching completion was found in the log'
  emit_and_exit 5
done
