#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/test_lib.sh"

CHECK_SCRIPT="$TEST_ROOT_DIR/check_tmux.sh"
ENSURE_SCRIPT="$TEST_ROOT_DIR/ensure_tmux_skill_pane.sh"
ADOPT_SCRIPT="$TEST_ROOT_DIR/adopt_tmux_skill_pane.sh"
SUBMIT_SCRIPT="$TEST_ROOT_DIR/submit_tmux_skill_pane_request.sh"
WAIT_SCRIPT="$TEST_ROOT_DIR/wait_for_tmux_skill_pane_request.sh"
RUN_SCRIPT="$TEST_ROOT_DIR/run_in_tmux_skill_pane.sh"
RECOVER_SCRIPT="$TEST_ROOT_DIR/recover_tmux_skill_pane.sh"

trap cleanup_test_resources EXIT HUP INT TERM

require_tmux_session

printf 'cli_validation: check_tmux environment guards ... '

"$CHECK_SCRIPT" >/dev/null 2>&1

set +e
env -u TMUX "$CHECK_SCRIPT" >/dev/null 2>&1
outside_tmux_rc=$?
env PATH=/definitely-missing "$CHECK_SCRIPT" >/dev/null 2>&1
missing_tmux_rc=$?
set -e

assert_equals '2' "$outside_tmux_rc" 'check_tmux outside tmux'
assert_equals '127' "$missing_tmux_rc" 'check_tmux without tmux in PATH'

printf 'ok\n'

printf 'cli_validation: ensure argument guards ... '

set +e
"$ENSURE_SCRIPT" --index abc >/dev/null 2>&1
ensure_bad_index_rc=$?
"$ENSURE_SCRIPT" --horizontal >/dev/null 2>&1
ensure_split_without_mode_rc=$?
"$ENSURE_SCRIPT" --split-window --new-window >/dev/null 2>&1
ensure_conflict_rc=$?
"$ENSURE_SCRIPT" --split-window --percent 0 >/dev/null 2>&1
ensure_bad_percent_rc=$?
"$ENSURE_SCRIPT" --split-window --target-pane %999999 >/dev/null 2>&1
ensure_bad_target_rc=$?
env -u TMUX "$ENSURE_SCRIPT" --index 1 >/dev/null 2>&1
ensure_outside_tmux_rc=$?
set -e

assert_equals '3' "$ensure_bad_index_rc" 'ensure bad index'
assert_equals '3' "$ensure_split_without_mode_rc" 'ensure split option without split mode'
assert_equals '3' "$ensure_conflict_rc" 'ensure conflicting create modes'
assert_equals '3' "$ensure_bad_percent_rc" 'ensure bad percent'
assert_equals '3' "$ensure_bad_target_rc" 'ensure invalid target pane'
assert_equals '2' "$ensure_outside_tmux_rc" 'ensure outside tmux'

printf 'ok\n'

printf 'cli_validation: adopt argument guards ... '

set +e
"$ADOPT_SCRIPT" >/dev/null 2>&1
adopt_missing_pane_rc=$?
"$ADOPT_SCRIPT" --unknown-option >/dev/null 2>&1
adopt_unknown_option_rc=$?
set -e

assert_equals '3' "$adopt_missing_pane_rc" 'adopt missing pane id'
assert_equals '3' "$adopt_unknown_option_rc" 'adopt unknown option'

printf 'ok\n'

printf 'cli_validation: submit and wait argument guards ... '

newline_cmd=$(printf 'printf one\nprintf two')

set +e
"$SUBMIT_SCRIPT" >/dev/null 2>&1
submit_missing_cmd_rc=$?
submit_newline_output=$("$SUBMIT_SCRIPT" --cmd "$newline_cmd")
submit_newline_rc=$?
"$WAIT_SCRIPT" --query-only >/dev/null 2>&1
wait_missing_request_rc=$?
"$WAIT_SCRIPT" --request-id req-1 --query-only --timeout-seconds 1 >/dev/null 2>&1
wait_conflict_rc=$?
"$WAIT_SCRIPT" --request-id req-1 --query-only --search-start-offset -1 >/dev/null 2>&1
wait_bad_offset_rc=$?
set -e

assert_equals '3' "$submit_missing_cmd_rc" 'submit missing cmd'
assert_equals '3' "$submit_newline_rc" 'submit newline command rc'
assert_equals 'error' "$(json_string_field "$submit_newline_output" status)" 'submit newline status'
assert_equals 'command must be a single shell string without newlines' "$(json_string_field "$submit_newline_output" message)" 'submit newline message'
assert_equals '3' "$wait_missing_request_rc" 'wait missing request id'
assert_equals '3' "$wait_conflict_rc" 'wait conflict'
assert_equals '3' "$wait_bad_offset_rc" 'wait bad offset'

printf 'ok\n'

printf 'cli_validation: run and recover argument guards ... '

set +e
"$RUN_SCRIPT" --cmd 'printf hi' >/dev/null 2>&1
run_missing_timeout_rc=$?
run_newline_output=$("$RUN_SCRIPT" --cmd "$newline_cmd" --timeout-seconds 1)
run_newline_rc=$?
"$RUN_SCRIPT" --recover-only --cmd 'printf hi' >/dev/null 2>&1
run_recover_cmd_conflict_rc=$?
"$RUN_SCRIPT" --recover-only --timeout-seconds 1 >/dev/null 2>&1
run_recover_timeout_conflict_rc=$?
"$RECOVER_SCRIPT" --unknown-option >/dev/null 2>&1
recover_unknown_option_rc=$?
set -e

assert_equals '3' "$run_missing_timeout_rc" 'run missing timeout'
assert_equals '3' "$run_newline_rc" 'run newline rc'
assert_equals 'error' "$(json_string_field "$run_newline_output" status)" 'run newline status'
assert_equals 'command must be a single shell string without newlines' "$(json_string_field "$run_newline_output" message)" 'run newline message'
assert_equals '3' "$run_recover_cmd_conflict_rc" 'run recover-only cmd conflict'
assert_equals '3' "$run_recover_timeout_conflict_rc" 'run recover-only timeout conflict'
assert_equals '3' "$recover_unknown_option_rc" 'recover unknown option'

printf 'ok\n'
printf 'cli_validation.sh: ok\n'

