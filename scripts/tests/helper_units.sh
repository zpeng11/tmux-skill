#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/test_lib.sh"

PANE_COMMON="$TEST_ROOT_DIR/common/pane_common.sh"
REQUEST_COMMON="$TEST_ROOT_DIR/common/request_common.sh"

trap cleanup_test_resources EXIT HUP INT TERM

# request_common expects SCRIPT_DIR to point at the scripts root.
SCRIPT_DIR=$TEST_ROOT_DIR
. "$PANE_COMMON"
SCRIPT_DIR=$TEST_ROOT_DIR
. "$REQUEST_COMMON"

printf 'helper_units: pane helpers ... '

assert_equals '0' "$(normalize_non_negative_integer 000)" 'normalize all zeros'
assert_equals '12' "$(normalize_non_negative_integer 0012)" 'normalize leading zeros'

is_non_negative_integer 0 || fail '0 should be a non-negative integer'
is_non_negative_integer 42 || fail '42 should be a non-negative integer'

if is_non_negative_integer ''; then
  fail 'empty string must not be a non-negative integer'
fi

if is_non_negative_integer '4a'; then
  fail 'alpha suffix must not be a non-negative integer'
fi

is_positive_integer 3 || fail '3 should be a positive integer'

if is_positive_integer 0; then
  fail '0 must not be a positive integer'
fi

assert_equals '5' "$(mark_to_index 'TMUX_SKILL_PANE_005')" 'mark_to_index normalizes zeros'

if mark_to_index 'INVALID_MARK' >/dev/null 2>&1; then
  fail 'invalid mark prefix must not parse'
fi

expected_quote="'a'\\''b'"
assert_equals "$expected_quote" "$(shell_single_quote "a'b")" 'shell_single_quote escapes apostrophes'
assert_equals 'a\"b\\c' "$(json_escape 'a"b\c')" 'json_escape escapes quotes and backslashes'

printf 'ok\n'

printf 'helper_units: request helpers ... '

compact_json='{"status":"ok","pane_id":"%9","count":42,"maybe":null}'
assert_equals 'ok' "$(tmux_skill_extract_json_string_from_compact "$compact_json" status)" 'extract string'
assert_equals '%9' "$(tmux_skill_extract_json_string_from_compact "$compact_json" pane_id)" 'extract pane_id'
assert_equals '42' "$(tmux_skill_extract_json_number_from_compact "$compact_json" count)" 'extract number'
assert_equals 'null' "$(tmux_skill_extract_json_number_from_compact "$compact_json" maybe)" 'extract null number'
assert_equals '3' "$(tmux_skill_byte_length 'abc')" 'byte_length'

byte_file=$(write_temp_file "${TMPDIR:-/tmp}/tmux-skill.helper-bytes.XXXXXX.log" 'xxabcabc')
assert_equals '8' "$(tmux_skill_byte_count "$byte_file")" 'byte_count'
assert_equals '2' "$(tmux_skill_find_fixed_offset_after "$byte_file" 'abc' 0)" 'find first occurrence'
assert_equals '5' "$(tmux_skill_find_fixed_offset_after "$byte_file" 'abc' 3)" 'find second occurrence'

sentinel_file=$(write_temp_file "${TMPDIR:-/tmp}/tmux-skill.helper-sentinel.XXXXXX.log" '__TMUX_SKILL_RC_BEGIN__req-1__7__TMUX_SKILL_RC_END__req-1__')
TMUX_SKILL_LOG_FILE=$sentinel_file

tmux_skill_request_has_end_sentinel "$sentinel_file" 'req-1' || fail 'request end sentinel should be detected'

if tmux_skill_request_has_end_sentinel "$sentinel_file" 'missing-req'; then
  fail 'unexpected end sentinel detection for missing request id'
fi

success_log=$(write_temp_file "${TMPDIR:-/tmp}/tmux-skill.helper-success.XXXXXX.log" '__TMUX_SKILL_BEGIN__req-2__payload__TMUX_SKILL_RC_BEGIN__req-2__42__TMUX_SKILL_RC_END__req-2__')
TMUX_SKILL_LOG_FILE=$success_log
TMUX_SKILL_ERROR_CODE=''
TMUX_SKILL_ERROR_MESSAGE=''
tmux_skill_find_request_result 'req-2' 0 || fail 'expected successful request result parsing'
assert_equals '42' "$TMUX_SKILL_RESULT_EXIT_CODE" 'parsed exit code'
assert_equals '27' "$TMUX_SKILL_CLEAN_START_OFFSET" 'clean start offset'
assert_equals '34' "$TMUX_SKILL_CLEAN_END_OFFSET" 'clean end offset'

missing_start_log=$(write_temp_file "${TMPDIR:-/tmp}/tmux-skill.helper-missing-start.XXXXXX.log" 'payload__TMUX_SKILL_RC_BEGIN__req-3__0__TMUX_SKILL_RC_END__req-3__')
TMUX_SKILL_LOG_FILE=$missing_start_log
TMUX_SKILL_ERROR_CODE=''
TMUX_SKILL_ERROR_MESSAGE=''
set +e
tmux_skill_find_request_result 'req-3' 0
missing_start_rc=$?
set -e
assert_equals '2' "$missing_start_rc" 'missing start parse rc'
assert_equals '6' "$TMUX_SKILL_ERROR_CODE" 'missing start error code'
assert_equals 'start sentinel was not found in the log' "$TMUX_SKILL_ERROR_MESSAGE" 'missing start error message'

non_numeric_log=$(write_temp_file "${TMPDIR:-/tmp}/tmux-skill.helper-bad-exit.XXXXXX.log" '__TMUX_SKILL_BEGIN__req-4__payload__TMUX_SKILL_RC_BEGIN__req-4__oops__TMUX_SKILL_RC_END__req-4__')
TMUX_SKILL_LOG_FILE=$non_numeric_log
TMUX_SKILL_ERROR_CODE=''
TMUX_SKILL_ERROR_MESSAGE=''
set +e
tmux_skill_find_request_result 'req-4' 0
non_numeric_rc=$?
set -e
assert_equals '2' "$non_numeric_rc" 'non-numeric exit parse rc'
assert_equals '6' "$TMUX_SKILL_ERROR_CODE" 'non-numeric exit error code'
assert_equals 'failed to parse command exit code from log' "$TMUX_SKILL_ERROR_MESSAGE" 'non-numeric exit error message'

printf 'ok\n'
printf 'helper_units.sh: ok\n'
