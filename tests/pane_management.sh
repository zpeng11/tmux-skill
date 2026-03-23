#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/test_lib.sh"

ENSURE_SCRIPT="$TEST_ROOT_DIR/ensure_tmux_skill_pane.sh"
ADOPT_SCRIPT="$TEST_ROOT_DIR/adopt_tmux_skill_pane.sh"

SUITE_INDEX_BASE=${TMUX_SKILL_TEST_INDEX:-$((920000 + ($$ % 10000)))}

trap cleanup_test_resources EXIT HUP INT TERM

require_tmux_session

SCRIPT_DIR=$TEST_ROOT_DIR
. "$TEST_ROOT_DIR/tmux_skill_pane_common.sh"

CURRENT_SESSION_ID=$(tmux display-message -p '#{session_id}' 2>/dev/null) || fail 'unable to determine current tmux session'

printf 'pane_management: ensure allocates the current smallest free index ... '

expected_index=$(allocate_index) || fail 'failed to allocate expected index'
auto_output=$("$ENSURE_SCRIPT" --new-window)
auto_mark=$(json_string_field "$auto_output" mark)
auto_pane_id=$(json_string_field "$auto_output" pane_id)
auto_log_file=$(json_string_field "$auto_output" log_file)
assert_equals "${MARK_PREFIX}${expected_index}" "$auto_mark" 'ensure auto mark'
assert_non_empty "$auto_pane_id" 'ensure auto pane id'
assert_file_exists "$auto_log_file" 'ensure auto log file'
register_window_for_pane "$auto_pane_id"
wait_for_shell_state "$auto_pane_id" 'idle' 10

printf 'ok\n'

printf 'pane_management: ensure split-window supports horizontal and vertical targets ... '

split_host_pane=$(tmux new-window -dP -F '#{pane_id}' -n "skill-pane-mgmt-split-$SUITE_INDEX_BASE" -c "$PWD" 2>/dev/null) || fail 'failed to create split host pane'
register_window_for_pane "$split_host_pane"
split_host_window=$(window_id_for_pane "$split_host_pane")

horizontal_index=$((SUITE_INDEX_BASE + 1))
horizontal_output=$("$ENSURE_SCRIPT" --index "$horizontal_index" --split-window --horizontal --percent 25 --target-pane "$split_host_pane")
horizontal_pane_id=$(json_string_field "$horizontal_output" pane_id)
assert_non_empty "$horizontal_pane_id" 'horizontal split pane'
assert_not_equals "$split_host_pane" "$horizontal_pane_id" 'horizontal split target mismatch'
assert_equals "$split_host_window" "$(window_id_for_pane "$horizontal_pane_id")" 'horizontal split window'
wait_for_shell_state "$horizontal_pane_id" 'idle' 10

vertical_index=$((SUITE_INDEX_BASE + 2))
vertical_output=$("$ENSURE_SCRIPT" --index "$vertical_index" --split-window --vertical --percent 35 --target-pane "$split_host_pane")
vertical_pane_id=$(json_string_field "$vertical_output" pane_id)
assert_non_empty "$vertical_pane_id" 'vertical split pane'
assert_not_equals "$split_host_pane" "$vertical_pane_id" 'vertical split target mismatch'
assert_equals "$split_host_window" "$(window_id_for_pane "$vertical_pane_id")" 'vertical split window'
wait_for_shell_state "$vertical_pane_id" 'idle' 10

printf 'ok\n'

printf 'pane_management: ensure recreates a missing idle log file ... '

recreate_index=$((SUITE_INDEX_BASE + 3))
recreate_output=$("$ENSURE_SCRIPT" --index "$recreate_index" --new-window)
recreate_pane_id=$(json_string_field "$recreate_output" pane_id)
recreate_log_file=$(json_string_field "$recreate_output" log_file)
register_window_for_pane "$recreate_pane_id"
rm -f "$recreate_log_file"

recreate_output_2=$("$ENSURE_SCRIPT" --index "$recreate_index" --new-window)
recreate_log_file_2=$(json_string_field "$recreate_output_2" log_file)
assert_file_exists "$recreate_log_file_2" 'recreated ensure log file'
assert_not_equals "$recreate_log_file" "$recreate_log_file_2" 'ensure recreated log path'

printf 'ok\n'

printf 'pane_management: ensure rejects a busy pane with a missing log file ... '

busy_index=$((SUITE_INDEX_BASE + 4))
busy_output=$("$ENSURE_SCRIPT" --index "$busy_index" --new-window)
busy_pane_id=$(json_string_field "$busy_output" pane_id)
busy_log_file=$(json_string_field "$busy_output" log_file)
register_window_for_pane "$busy_pane_id"
tmux set-option -p -q -t "$busy_pane_id" '@tmux_skill_request_state' 'busy:held-request' >/dev/null 2>&1 || fail 'failed to set busy ensure state'
rm -f "$busy_log_file"

set +e
"$ENSURE_SCRIPT" --index "$busy_index" --new-window >/dev/null 2>&1
busy_missing_log_rc=$?
set -e

assert_equals '7' "$busy_missing_log_rc" 'ensure busy missing log rc'

printf 'ok\n'

printf 'pane_management: ensure rejects duplicate marks in the current session ... '

conflict_index=$((SUITE_INDEX_BASE + 5))
conflict_mark="${MARK_PREFIX}${conflict_index}"
conflict_pane_a=$(tmux new-window -dP -F '#{pane_id}' -n "skill-conflict-a-$SUITE_INDEX_BASE" -c "$PWD" 2>/dev/null) || fail 'failed to create first conflict pane'
register_window_for_pane "$conflict_pane_a"
conflict_pane_b=$(tmux new-window -dP -F '#{pane_id}' -n "skill-conflict-b-$SUITE_INDEX_BASE" -c "$PWD" 2>/dev/null) || fail 'failed to create second conflict pane'
register_window_for_pane "$conflict_pane_b"
tmux set-option -p -q -t "$conflict_pane_a" '@tmux_skill_mark' "$conflict_mark" >/dev/null 2>&1 || fail 'failed to seed first conflict mark'
tmux set-option -p -q -t "$conflict_pane_b" '@tmux_skill_mark' "$conflict_mark" >/dev/null 2>&1 || fail 'failed to seed second conflict mark'

set +e
"$ENSURE_SCRIPT" --index "$conflict_index" --new-window >/dev/null 2>&1
duplicate_mark_rc=$?
set -e

assert_equals '4' "$duplicate_mark_rc" 'ensure duplicate mark rc'

printf 'ok\n'

printf 'pane_management: adopt succeeds, reuses state, and rejects index mismatches ... '

adopt_index=$((SUITE_INDEX_BASE + 6))
adopt_pane_id=$(tmux new-window -dP -F '#{pane_id}' -n "skill-adopt-$SUITE_INDEX_BASE" -c "$PWD" 2>/dev/null) || fail 'failed to create adopt pane'
register_window_for_pane "$adopt_pane_id"
adopt_output=$("$ADOPT_SCRIPT" --pane-id "$adopt_pane_id" --index "$adopt_index")
adopt_log_file=$(json_string_field "$adopt_output" log_file)
assert_equals "${MARK_PREFIX}${adopt_index}" "$(json_string_field "$adopt_output" mark)" 'adopt mark'
assert_file_exists "$adopt_log_file" 'adopt log file'

adopt_output_2=$("$ADOPT_SCRIPT" --pane-id "$adopt_pane_id" --index "$adopt_index")
assert_equals "$adopt_pane_id" "$(json_string_field "$adopt_output_2" pane_id)" 'adopt idempotent pane'
assert_equals "$adopt_log_file" "$(json_string_field "$adopt_output_2" log_file)" 'adopt idempotent log'

set +e
"$ADOPT_SCRIPT" --pane-id "$adopt_pane_id" --index $((adopt_index + 1)) >/dev/null 2>&1
adopt_mismatch_rc=$?
set -e

assert_equals '4' "$adopt_mismatch_rc" 'adopt mismatched index rc'

printf 'ok\n'

printf 'pane_management: adopt detects mark collisions with another managed pane ... '

collision_index=$((SUITE_INDEX_BASE + 7))
collision_existing_output=$("$ENSURE_SCRIPT" --index "$collision_index" --new-window)
collision_existing_pane=$(json_string_field "$collision_existing_output" pane_id)
register_window_for_pane "$collision_existing_pane"
collision_target_pane=$(tmux new-window -dP -F '#{pane_id}' -n "skill-collision-$SUITE_INDEX_BASE" -c "$PWD" 2>/dev/null) || fail 'failed to create collision target pane'
register_window_for_pane "$collision_target_pane"

set +e
"$ADOPT_SCRIPT" --pane-id "$collision_target_pane" --index "$collision_index" >/dev/null 2>&1
adopt_collision_rc=$?
set -e

assert_equals '4' "$adopt_collision_rc" 'adopt mark collision rc'

printf 'ok\n'

printf 'pane_management: adopt rejects non-shell panes and panes in tmux mode ... '

non_shell_pane=$(tmux new-window -dP -F '#{pane_id}' -n "skill-nonshell-$SUITE_INDEX_BASE" -c "$PWD" 2>/dev/null) || fail 'failed to create non-shell pane'
register_window_for_pane "$non_shell_pane"
tmux send-keys -t "$non_shell_pane" 'sleep 30' C-m >/dev/null 2>&1 || fail 'failed to start non-shell command'
sleep 1

set +e
"$ADOPT_SCRIPT" --pane-id "$non_shell_pane" --index $((SUITE_INDEX_BASE + 8)) >/dev/null 2>&1
adopt_non_shell_rc=$?
set -e

assert_equals '3' "$adopt_non_shell_rc" 'adopt non-shell rc'
tmux send-keys -t "$non_shell_pane" C-c >/dev/null 2>&1 || true

mode_pane=$(tmux new-window -dP -F '#{pane_id}' -n "skill-mode-$SUITE_INDEX_BASE" -c "$PWD" 2>/dev/null) || fail 'failed to create mode pane'
register_window_for_pane "$mode_pane"
tmux copy-mode -t "$mode_pane" >/dev/null 2>&1 || fail 'failed to enter copy mode'

set +e
"$ADOPT_SCRIPT" --pane-id "$mode_pane" --index $((SUITE_INDEX_BASE + 9)) >/dev/null 2>&1
adopt_mode_rc=$?
set -e

assert_equals '5' "$adopt_mode_rc" 'adopt copy mode rc'

printf 'ok\n'

printf 'pane_management: adopt recreates missing idle logs and rejects missing busy logs ... '

rm -f "$adopt_log_file"
adopt_recreate_output=$("$ADOPT_SCRIPT" --pane-id "$adopt_pane_id" --index "$adopt_index")
adopt_recreate_log=$(json_string_field "$adopt_recreate_output" log_file)
assert_file_exists "$adopt_recreate_log" 'adopt recreated log file'
assert_not_equals "$adopt_log_file" "$adopt_recreate_log" 'adopt recreated log path'

tmux set-option -p -q -t "$adopt_pane_id" '@tmux_skill_request_state' 'busy:held-request' >/dev/null 2>&1 || fail 'failed to seed adopt busy state'
rm -f "$adopt_recreate_log"

set +e
"$ADOPT_SCRIPT" --pane-id "$adopt_pane_id" --index "$adopt_index" >/dev/null 2>&1
adopt_busy_missing_log_rc=$?
set -e

assert_equals '7' "$adopt_busy_missing_log_rc" 'adopt busy missing log rc'

printf 'ok\n'
printf 'pane_management.sh: ok\n'

