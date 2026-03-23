#!/bin/sh

PROGRAM_NAME=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=./tmux_skill_request_common.sh
. "$SCRIPT_DIR/tmux_skill_request_common.sh"

STATUS='error'
MESSAGE=''
REQUEST_ID=''
COMMAND=''
TMUX_SKILL_SEARCH_START_OFFSET=''

show_help() {
  cat <<EOF
Usage:
  $PROGRAM_NAME --cmd COMMAND < ensure.json

Read one ensure_tmux_skill_pane.sh JSON object from standard input, submit one
single-line shell command to the managed pane, and return immediately with a
request ticket.

Options:
  --cmd COMMAND   Single shell command string to run in the target pane.
                  Newlines are rejected.
  -h, --help      Show this help text and exit.

Output JSON fields:
  status               started, busy, or error.
  mark                 Managed pane mark from stdin.
  pane_id              Managed pane ID from stdin.
  log_file             Managed pane log file from stdin.
  request_id           Unique request ID when status=started.
  search_start_offset  Byte offset from which result search may begin when
                       status=started.
  message              Optional failure detail.

Exit codes:
  0    Request submitted.
  2    tmux is available, but the script is not running inside a tmux session.
  3    Invalid arguments, invalid stdin JSON, or pane/mark mismatch.
  4    The target pane is already running a managed request, or its shell is
       busy with an unmanaged command.
  5    tmux request submission failed.
  6    Log validation failed.
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
  printf '"search_start_offset":'; tmux_skill_json_number_or_null "$TMUX_SKILL_SEARCH_START_OFFSET"; printf ','
  printf '"message":'; tmux_skill_json_string_or_null "$MESSAGE"
  printf '}\n'
}

emit_and_exit() {
  exit_code=$1
  tmux_skill_cleanup
  output_json
  exit "$exit_code"
}

fail_json() {
  exit_code=$1
  STATUS=$2
  MESSAGE=$3
  emit_and_exit "$exit_code"
}

trap tmux_skill_cleanup EXIT HUP INT TERM

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
[ -n "$COMMAND" ] || fail_json 3 error 'missing required --cmd'

case $COMMAND in
  *'
'*|*'
'*)
    fail_json 3 error 'command must be a single shell string without newlines'
    ;;
esac

tmux_skill_require_tmux_session || fail_json "$TMUX_SKILL_ERROR_CODE" error "$TMUX_SKILL_ERROR_MESSAGE"
tmux_skill_load_ensure_json_from_stdin || fail_json "$TMUX_SKILL_ERROR_CODE" error "$TMUX_SKILL_ERROR_MESSAGE"
tmux_skill_lock_request || fail_json "$TMUX_SKILL_ERROR_CODE" error "$TMUX_SKILL_ERROR_MESSAGE"

tmux_skill_reconcile_request_state
reconcile_rc=$?

case $reconcile_rc in
  0)
    ;;
  1)
    STATUS='busy'
    if [ -n "$TMUX_SKILL_RECOVERY_MESSAGE" ]; then
      MESSAGE=$TMUX_SKILL_RECOVERY_MESSAGE
    else
      MESSAGE='target pane is already running a managed command'
    fi
    emit_and_exit 4
    ;;
  *)
    fail_json "$TMUX_SKILL_ERROR_CODE" error "$TMUX_SKILL_ERROR_MESSAGE"
    ;;
esac

CURRENT_SHELL_STATE=$(tmux_skill_current_shell_state)
if [ "$CURRENT_SHELL_STATE" != 'idle' ]; then
  STATUS='busy'
  if [ -z "$CURRENT_SHELL_STATE" ]; then
    MESSAGE='target pane shell state is not yet initialized'
  else
    MESSAGE='target pane shell is busy with an unmanaged command'
  fi
  emit_and_exit 4
fi

REQUEST_ID=$(printf '%s' "$(tmux_skill_generate_request_id)")
tmux_skill_send_managed_command "$REQUEST_ID" "$COMMAND" || fail_json "$TMUX_SKILL_ERROR_CODE" error "$TMUX_SKILL_ERROR_MESSAGE"

STATUS='started'
MESSAGE=''
emit_and_exit 0
