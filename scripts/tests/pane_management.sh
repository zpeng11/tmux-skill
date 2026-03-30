#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/test_lib.sh"

ADOPT_SCRIPT="$TEST_ROOT_DIR/adopt_pane.sh"

SUITE_INDEX_BASE=${TMUX_SKILL_TEST_INDEX:-$((920000 + ($$ % 10000)))}

trap cleanup_test_resources EXIT HUP INT TERM

require_tmux_session

SCRIPT_DIR=$TEST_ROOT_DIR
. "$TEST_ROOT_DIR/common/pane_common.sh"

CURRENT_SESSION_ID=$(tmux display-message -p '#{session_id}' 2>/dev/null) || fail 'unable to determine current tmux session'

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
collision_existing_pane=$(tmux new-window -dP -F '#{pane_id}' -n "skill-collision-existing-$SUITE_INDEX_BASE" -c "$PWD" 2>/dev/null) || fail 'failed to create collision existing pane'
register_window_for_pane "$collision_existing_pane"
collision_existing_output=$("$ADOPT_SCRIPT" --pane-id "$collision_existing_pane" --index "$collision_index")
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
