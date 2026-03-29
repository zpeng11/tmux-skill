#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/test_lib.sh"

ENSURE_SCRIPT="$TEST_ROOT_DIR/ensure_pane.sh"
SUBMIT_SCRIPT="$TEST_ROOT_DIR/submit_request.sh"
WAIT_SCRIPT="$TEST_ROOT_DIR/wait_for_request.sh"
RUN_SCRIPT="$TEST_ROOT_DIR/run_in_pane.sh"
RECOVER_SCRIPT="$TEST_ROOT_DIR/recover_pane.sh"

SUITE_INDEX=${TMUX_SKILL_TEST_INDEX:-$((930000 + ($$ % 10000)))}

trap cleanup_test_resources EXIT HUP INT TERM

require_tmux_session

ensure_fixture_file() {
  mark=$1
  pane_id=$2
  log_file=$3
  write_temp_file "${TMPDIR:-/tmp}/tmux-skill.ensure-fixture.XXXXXX.json" "{\"mark\":\"$mark\",\"pane_id\":\"$pane_id\",\"log_file\":\"$log_file\"}"
}

printf 'request_protocol: provisioning managed pane ... '

ensure_output=$("$ENSURE_SCRIPT" --index "$SUITE_INDEX" --new-window)
mark=$(json_string_field "$ensure_output" mark)
pane_id=$(json_string_field "$ensure_output" pane_id)
log_file=$(json_string_field "$ensure_output" log_file)
assert_non_empty "$mark" 'ensure mark'
assert_non_empty "$pane_id" 'ensure pane'
assert_file_exists "$log_file" 'ensure log'
register_window_for_pane "$pane_id"
ensure_file=$(write_temp_file "${TMPDIR:-/tmp}/tmux-skill.request.XXXXXX.json" "$ensure_output")
wait_for_shell_state "$pane_id" 'idle' 10

printf 'ok\n'

printf 'request_protocol: submit + wait covers pending, timeout, and eventual success ... '

pending_submit=$("$SUBMIT_SCRIPT" --cmd 'sleep 4' < "$ensure_file")
assert_equals 'started' "$(json_string_field "$pending_submit" status)" 'pending submit status'
pending_request_id=$(json_string_field "$pending_submit" request_id)
assert_non_empty "$pending_request_id" 'pending request id'

set +e
pending_query_output=$("$WAIT_SCRIPT" --request-id "$pending_request_id" --query-only < "$ensure_file")
pending_query_rc=$?
pending_timeout_output=$("$WAIT_SCRIPT" --request-id "$pending_request_id" --timeout-seconds 1 < "$ensure_file")
pending_timeout_rc=$?
set -e

assert_equals '4' "$pending_query_rc" 'pending query rc'
assert_equals 'pending' "$(json_string_field "$pending_query_output" status)" 'pending query status'
assert_equals '7' "$pending_timeout_rc" 'pending timeout rc'
assert_equals 'timeout' "$(json_string_field "$pending_timeout_output" status)" 'pending timeout status'

pending_final_output=$("$WAIT_SCRIPT" --request-id "$pending_request_id" --timeout-seconds 10 < "$ensure_file")
assert_equals 'ok' "$(json_string_field "$pending_final_output" status)" 'pending final status'
assert_equals '0' "$(json_number_or_null_field "$pending_final_output" exit_code)" 'pending final exit code'

printf 'ok\n'

printf 'request_protocol: run_in propagates timeout and keeps request recoverable ... '

set +e
run_timeout_output=$("$RUN_SCRIPT" --cmd 'sleep 4' --timeout-seconds 1 < "$ensure_file")
run_timeout_rc=$?
set -e

assert_equals '7' "$run_timeout_rc" 'run timeout rc'
assert_equals 'timeout' "$(json_string_field "$run_timeout_output" status)" 'run timeout status'
run_timeout_request_id=$(json_string_field "$run_timeout_output" request_id)
assert_non_empty "$run_timeout_request_id" 'run timeout request id'

run_timeout_final=$("$WAIT_SCRIPT" --request-id "$run_timeout_request_id" --timeout-seconds 10 < "$ensure_file")
assert_equals 'ok' "$(json_string_field "$run_timeout_final" status)" 'run timeout final status'
assert_equals '0' "$(json_number_or_null_field "$run_timeout_final" exit_code)" 'run timeout final exit code'

printf 'ok\n'

printf 'request_protocol: blocking wait detects interrupted requests ... '

interrupt_submit=$("$SUBMIT_SCRIPT" --cmd 'sleep 30' < "$ensure_file")
interrupt_request_id=$(json_string_field "$interrupt_submit" request_id)
assert_non_empty "$interrupt_request_id" 'interrupt request id'

( sleep 2; tmux send-keys -t "$pane_id" C-c >/dev/null 2>&1 ) &
INTERRUPTER_PID=$!

set +e
interrupt_wait_output=$("$WAIT_SCRIPT" --request-id "$interrupt_request_id" --timeout-seconds 10 < "$ensure_file")
interrupt_wait_rc=$?
set -e
wait "$INTERRUPTER_PID" || true

assert_equals '130' "$interrupt_wait_rc" 'interrupt blocking wait rc'
assert_equals 'interrupted' "$(json_string_field "$interrupt_wait_output" status)" 'interrupt blocking wait status'

run_interrupt_recover=$("$RUN_SCRIPT" --recover-only < "$ensure_file")
assert_equals 'interrupted' "$(json_string_field "$run_interrupt_recover" status)" 'run recover interrupted status'
assert_equals "$interrupt_request_id" "$(json_string_field "$run_interrupt_recover" request_id)" 'run recover interrupted request'
wait_for_request_state "$pane_id" 'idle' 10

printf 'ok\n'

printf 'request_protocol: unknown request ids fail cleanly ... '

set +e
unknown_request_output=$("$WAIT_SCRIPT" --request-id 'missing-request' --query-only < "$ensure_file")
unknown_request_rc=$?
set -e

assert_equals '5' "$unknown_request_rc" 'unknown request rc'
assert_equals 'error' "$(json_string_field "$unknown_request_output" status)" 'unknown request status'
assert_equals 'request is not active and no matching completion was found in the log' "$(json_string_field "$unknown_request_output" message)" 'unknown request message'

printf 'ok\n'

printf 'request_protocol: recover-only distinguishes active busy, legacy busy, and recovered states ... '

tmux set-option -p -q -t "$pane_id" '@tmux_skill_shell_state' 'busy' >/dev/null 2>&1 || fail 'failed to set shell busy for active busy state'
tmux set-option -p -q -t "$pane_id" '@tmux_skill_request_state' 'busy:active-request' >/dev/null 2>&1 || fail 'failed to set request busy:ID'

set +e
active_busy_output=$("$RUN_SCRIPT" --recover-only < "$ensure_file")
active_busy_rc=$?
set -e

assert_equals '4' "$active_busy_rc" 'active busy recover rc'
assert_equals 'busy' "$(json_string_field "$active_busy_output" status)" 'active busy recover status'
assert_equals 'active-request' "$(json_string_field "$active_busy_output" request_id)" 'active busy recover request'

tmux set-option -p -q -t "$pane_id" '@tmux_skill_shell_state' 'idle' >/dev/null 2>&1 || fail 'failed to restore shell idle after active busy'
tmux set-option -p -q -t "$pane_id" '@tmux_skill_request_state' 'idle' >/dev/null 2>&1 || fail 'failed to restore request idle after active busy'

tmux set-option -p -q -t "$pane_id" '@tmux_skill_request_state' 'busy' >/dev/null 2>&1 || fail 'failed to set legacy busy state'

set +e
legacy_busy_output=$("$RUN_SCRIPT" --recover-only < "$ensure_file")
legacy_busy_rc=$?
set -e

assert_equals '4' "$legacy_busy_rc" 'legacy busy recover rc'
assert_equals 'busy' "$(json_string_field "$legacy_busy_output" status)" 'legacy busy recover status'
assert_equals 'target pane uses a legacy busy state without a recoverable request id' "$(json_string_field "$legacy_busy_output" message)" 'legacy busy recover message'
tmux set-option -p -q -t "$pane_id" '@tmux_skill_request_state' 'idle' >/dev/null 2>&1 || fail 'failed to restore request idle after legacy busy'

recovered_seed_output=$("$RUN_SCRIPT" --cmd 'printf recovered-seed' --timeout-seconds 5 < "$ensure_file")
recovered_seed_request=$(json_string_field "$recovered_seed_output" request_id)
assert_non_empty "$recovered_seed_request" 'recovered seed request id'
tmux set-option -p -q -t "$pane_id" '@tmux_skill_request_state' "busy:$recovered_seed_request" >/dev/null 2>&1 || fail 'failed to seed stale busy state'

recovered_output=$("$RUN_SCRIPT" --recover-only < "$ensure_file")
assert_equals 'recovered' "$(json_string_field "$recovered_output" status)" 'recovered state status'
assert_equals "$recovered_seed_request" "$(json_string_field "$recovered_output" request_id)" 'recovered state request'

printf 'ok\n'

printf 'request_protocol: submit reconciles stale busy states before starting a new request ... '

stale_submit_seed=$("$RUN_SCRIPT" --cmd 'printf stale-submit-seed' --timeout-seconds 5 < "$ensure_file")
stale_submit_request=$(json_string_field "$stale_submit_seed" request_id)
assert_non_empty "$stale_submit_request" 'stale submit seed request'
tmux set-option -p -q -t "$pane_id" '@tmux_skill_request_state' "busy:$stale_submit_request" >/dev/null 2>&1 || fail 'failed to seed stale submit state'

stale_submit_output=$("$SUBMIT_SCRIPT" --cmd 'printf post-stale-submit' < "$ensure_file")
assert_equals 'started' "$(json_string_field "$stale_submit_output" status)" 'stale submit status'
fresh_request_id=$(json_string_field "$stale_submit_output" request_id)
assert_non_empty "$fresh_request_id" 'fresh request id after stale submit'

fresh_wait_output=$("$WAIT_SCRIPT" --request-id "$fresh_request_id" --timeout-seconds 10 < "$ensure_file")
assert_equals 'ok' "$(json_string_field "$fresh_wait_output" status)" 'fresh wait status'
assert_equals '0' "$(json_number_or_null_field "$fresh_wait_output" exit_code)" 'fresh wait exit code'

printf 'ok\n'

printf 'request_protocol: wait reports parse errors for malformed logs ... '

missing_start_log=$(write_temp_file "${TMPDIR:-/tmp}/tmux-skill.wait-missing-start.XXXXXX.log" '__TMUX_SKILL_RC_BEGIN__bad-req__0__TMUX_SKILL_RC_END__bad-req__')
missing_start_ensure=$(ensure_fixture_file "$mark" "$pane_id" "$missing_start_log")
set +e
missing_start_output=$("$WAIT_SCRIPT" --request-id 'bad-req' --query-only < "$missing_start_ensure")
missing_start_rc=$?
set -e

assert_equals '6' "$missing_start_rc" 'missing start wait rc'
assert_equals 'error' "$(json_string_field "$missing_start_output" status)" 'missing start wait status'
assert_equals 'start sentinel was not found in the log' "$(json_string_field "$missing_start_output" message)" 'missing start wait message'

bad_exit_log=$(write_temp_file "${TMPDIR:-/tmp}/tmux-skill.wait-bad-exit.XXXXXX.log" '__TMUX_SKILL_BEGIN__bad-exit__payload__TMUX_SKILL_RC_BEGIN__bad-exit__oops__TMUX_SKILL_RC_END__bad-exit__')
bad_exit_ensure=$(ensure_fixture_file "$mark" "$pane_id" "$bad_exit_log")
set +e
bad_exit_output=$("$WAIT_SCRIPT" --request-id 'bad-exit' --query-only < "$bad_exit_ensure")
bad_exit_rc=$?
set -e

assert_equals '6' "$bad_exit_rc" 'bad exit wait rc'
assert_equals 'error' "$(json_string_field "$bad_exit_output" status)" 'bad exit wait status'
assert_equals 'failed to parse command exit code from log' "$(json_string_field "$bad_exit_output" message)" 'bad exit wait message'

printf 'ok\n'

printf 'request_protocol: run_in busy passthrough and recover wrapper parity ... '

tmux send-keys -t "$pane_id" 'sleep 30' C-m >/dev/null 2>&1 || fail 'failed to start unmanaged busy command'
wait_for_shell_state "$pane_id" 'busy' 10

set +e
run_busy_output=$("$RUN_SCRIPT" --cmd 'printf should-not-run' --timeout-seconds 1 < "$ensure_file")
run_busy_rc=$?
set -e

assert_equals '4' "$run_busy_rc" 'run busy rc'
assert_equals 'busy' "$(json_string_field "$run_busy_output" status)" 'run busy status'
assert_equals 'target pane shell is busy with an unmanaged command' "$(json_string_field "$run_busy_output" message)" 'run busy message'

tmux send-keys -t "$pane_id" C-c >/dev/null 2>&1 || fail 'failed to interrupt unmanaged busy command'
wait_for_shell_state "$pane_id" 'idle' 10

run_idle_recover=$("$RUN_SCRIPT" --recover-only < "$ensure_file")
recover_idle=$("$RECOVER_SCRIPT" < "$ensure_file")
assert_equals 'idle' "$(json_string_field "$run_idle_recover" status)" 'run idle recover status'
assert_equals 'idle' "$(json_string_field "$recover_idle" status)" 'recover idle wrapper status'

printf 'ok\n'
printf 'request_protocol.sh: ok\n'

