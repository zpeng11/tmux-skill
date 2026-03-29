#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
ENSURE_SCRIPT="$ROOT_DIR/ensure_pane.sh"
RUN_SCRIPT="$ROOT_DIR/run_in_pane.sh"
WAIT_SCRIPT="$ROOT_DIR/wait_for_request.sh"
RECOVER_SCRIPT="$ROOT_DIR/recover_pane.sh"
SUBMIT_SCRIPT="$ROOT_DIR/submit_request.sh"

ENSURE_FILE=''
WINDOW_ID=''
PANE_ID=''
INDEX=${TMUX_SKILL_TEST_INDEX:-$((900000 + ($$ % 10000)))}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

json_string_field() {
  json_input=$1
  key=$2
  printf '%s\n' "$json_input" | sed -n "s/.*\"$key\":\"\\([^\"]*\\)\".*/\\1/p"
}

json_number_or_null_field() {
  json_input=$1
  key=$2
  printf '%s\n' "$json_input" | sed -n "s/.*\"$key\":\\([0-9][0-9]*\\|null\\).*/\\1/p"
}

assert_equals() {
  expected=$1
  actual=$2
  label=$3

  if [ "$expected" != "$actual" ]; then
    fail "$label: expected '$expected', got '$actual'"
  fi
}

assert_non_empty() {
  value=$1
  label=$2

  if [ -z "$value" ]; then
    fail "$label: expected a non-empty value"
  fi
}

wait_for_shell_state() {
  expected_state=$1
  deadline=$(( $(date +%s) + 10 ))

  while :; do
    current_state=$(tmux show-options -p -v -q -t "$PANE_ID" '@tmux_skill_shell_state' 2>/dev/null || true)

    if [ "$current_state" = "$expected_state" ]; then
      return 0
    fi

    if [ "$(date +%s)" -ge "$deadline" ]; then
      fail "timed out waiting for shell state $expected_state"
    fi

    sleep 1
  done
}

cleanup() {
  if [ -n "$WINDOW_ID" ]; then
    tmux kill-window -t "$WINDOW_ID" >/dev/null 2>&1 || true
  fi

  if [ -n "$ENSURE_FILE" ] && [ -f "$ENSURE_FILE" ]; then
    rm -f "$ENSURE_FILE"
  fi
}

trap cleanup EXIT HUP INT TERM

[ -n "${TMUX:-}" ] || fail 'this test must run inside tmux'

ENSURE_JSON=$("$ENSURE_SCRIPT" --index "$INDEX" --new-window)
PANE_ID=$(json_string_field "$ENSURE_JSON" pane_id)
assert_non_empty "$PANE_ID" 'pane_id'

WINDOW_ID=$(tmux display-message -p -t "$PANE_ID" '#{window_id}' 2>/dev/null || true)
assert_non_empty "$WINDOW_ID" 'window_id'

ENSURE_FILE=$(mktemp "${TMPDIR:-/tmp}/tmux-skill.test.XXXXXX.json") || fail 'failed to create ensure temp file'
printf '%s' "$ENSURE_JSON" > "$ENSURE_FILE" || fail 'failed to stage ensure json'

normal_output=$("$RUN_SCRIPT" --cmd 'printf normal-output' --timeout-seconds 5 < "$ENSURE_FILE")
assert_equals 'ok' "$(json_string_field "$normal_output" status)" 'normal status'
assert_equals '0' "$(json_number_or_null_field "$normal_output" exit_code)" 'normal exit_code'

set +e
( sleep 2; tmux send-keys -t "$PANE_ID" C-c >/dev/null 2>&1 ) &
INTERRUPTER_PID=$!
interrupt_output=$("$RUN_SCRIPT" --cmd 'sleep 30' --timeout-seconds 10 < "$ENSURE_FILE")
interrupt_rc=$?
set -e
wait "$INTERRUPTER_PID" || true

assert_equals '130' "$interrupt_rc" 'interrupt run exit code'
assert_equals 'interrupted' "$(json_string_field "$interrupt_output" status)" 'interrupt status'
assert_equals 'null' "$(json_number_or_null_field "$interrupt_output" exit_code)" 'interrupt exit_code'

interrupt_request_id=$(json_string_field "$interrupt_output" request_id)
assert_non_empty "$interrupt_request_id" 'interrupt request_id'

set +e
query_output=$("$WAIT_SCRIPT" --request-id "$interrupt_request_id" --query-only < "$ENSURE_FILE")
query_rc=$?
set -e

assert_equals '130' "$query_rc" 'interrupt query exit code'
assert_equals 'interrupted' "$(json_string_field "$query_output" status)" 'interrupt query status'

recover_output=$("$RECOVER_SCRIPT" < "$ENSURE_FILE")
assert_equals 'interrupted' "$(json_string_field "$recover_output" status)" 'recover status'
assert_equals "$interrupt_request_id" "$(json_string_field "$recover_output" request_id)" 'recover request_id'

request_state=$(tmux show-options -p -v -q -t "$PANE_ID" '@tmux_skill_request_state' 2>/dev/null || true)
assert_equals 'idle' "$request_state" 'request state after recover'

post_recover_output=$("$RUN_SCRIPT" --cmd 'printf post-recover' --timeout-seconds 5 < "$ENSURE_FILE")
assert_equals 'ok' "$(json_string_field "$post_recover_output" status)" 'post-recover status'
assert_equals '0' "$(json_number_or_null_field "$post_recover_output" exit_code)" 'post-recover exit_code'

tmux send-keys -t "$PANE_ID" 'sleep 30' C-m >/dev/null 2>&1 || fail 'failed to send unmanaged sleep'
wait_for_shell_state 'busy'

set +e
busy_submit_output=$("$SUBMIT_SCRIPT" --cmd 'printf should-not-run' < "$ENSURE_FILE")
busy_submit_rc=$?
set -e

assert_equals '4' "$busy_submit_rc" 'busy submit exit code'
assert_equals 'busy' "$(json_string_field "$busy_submit_output" status)" 'busy submit status'
assert_equals 'target pane shell is busy with an unmanaged command' "$(json_string_field "$busy_submit_output" message)" 'busy submit message'

tmux send-keys -t "$PANE_ID" C-c >/dev/null 2>&1 || fail 'failed to interrupt unmanaged sleep'
wait_for_shell_state 'idle'

printf 'request_flow.sh: ok\n'
