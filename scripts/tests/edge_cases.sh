#!/bin/sh

# Edge-case tests for Critical #2, Critical #3, Significant #5, and code dedup.
# Must be run inside tmux.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
ENSURE_SCRIPT="$ROOT_DIR/ensure_pane.sh"
SUBMIT_SCRIPT="$ROOT_DIR/submit_request.sh"
WAIT_SCRIPT="$ROOT_DIR/wait_for_request.sh"
RECOVER_SCRIPT="$ROOT_DIR/recover_pane.sh"

ENSURE_FILE=''
WINDOW_ID=''
PANE_ID=''
INDEX=${TMUX_SKILL_TEST_INDEX:-$((910000 + ($$ % 10000)))}
PASSED=0
FAILED=0

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
      fail "timed out waiting for shell state '$expected_state' (current: '$current_state')"
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

# ============================================================================
# T1: ensure returns a ready pane (shell_state=idle on first return)
# Verifies Fix 1 (Critical #2): ensure now waits for init hooks.
# ============================================================================
printf 'T1: ensure returns a ready pane ... '

ENSURE_JSON=$("$ENSURE_SCRIPT" --index "$INDEX" --new-window)
PANE_ID=$(json_string_field "$ENSURE_JSON" pane_id)
assert_non_empty "$PANE_ID" 'T1 pane_id'

WINDOW_ID=$(tmux display-message -p -t "$PANE_ID" '#{window_id}' 2>/dev/null || true)
assert_non_empty "$WINDOW_ID" 'T1 window_id'

# The key assertion: shell_state must already be idle (no extra wait needed)
SHELL_STATE=$(tmux show-options -p -v -q -t "$PANE_ID" '@tmux_skill_shell_state' 2>/dev/null || true)
assert_equals 'idle' "$SHELL_STATE" 'T1 shell_state after ensure'

printf 'ok\n'
PASSED=$((PASSED + 1))

# Stage ensure file for subsequent tests
ENSURE_FILE=$(mktemp "${TMPDIR:-/tmp}/tmux-skill.edge.XXXXXX.json") || fail 'failed to create ensure temp file'
printf '%s' "$ENSURE_JSON" > "$ENSURE_FILE" || fail 'failed to stage ensure json'

# ============================================================================
# T2: submit immediately after ensure succeeds
# Verifies that the race from Critical #2 is actually fixed: a command
# submitted right after ensure should succeed, not hit uninitialized state.
# ============================================================================
printf 'T2: submit immediately after ensure succeeds ... '

t2_submit=$("$SUBMIT_SCRIPT" --cmd 'printf immediate-after-ensure' < "$ENSURE_FILE")
t2_request_id=$(json_string_field "$t2_submit" request_id)
run_output=$("$WAIT_SCRIPT" --request-id "$t2_request_id" --timeout-seconds 5 < "$ENSURE_FILE")
assert_equals 'ok' "$(json_string_field "$run_output" status)" 'T2 status'
assert_equals '0' "$(json_number_or_null_field "$run_output" exit_code)" 'T2 exit_code'

printf 'ok\n'
PASSED=$((PASSED + 1))

# ============================================================================
# T3: submit rejects when shell_state is uninitialized (empty)
# Verifies Fix 2 (Critical #3): empty shell_state is not treated as idle.
# ============================================================================
printf 'T3: submit rejects when shell_state is uninitialized ... '

# Manually clear shell_state to simulate uninitialized pane
tmux set-option -p -q -t "$PANE_ID" '@tmux_skill_shell_state' '' >/dev/null 2>&1

set +e
uninit_output=$("$SUBMIT_SCRIPT" --cmd 'printf should-not-run' < "$ENSURE_FILE")
uninit_rc=$?
set -e

assert_equals '4' "$uninit_rc" 'T3 exit code'
assert_equals 'busy' "$(json_string_field "$uninit_output" status)" 'T3 status'
assert_equals 'target pane shell state is not yet initialized' "$(json_string_field "$uninit_output" message)" 'T3 message'

# Restore shell_state for subsequent tests
tmux set-option -p -q -t "$PANE_ID" '@tmux_skill_shell_state' 'idle' >/dev/null 2>&1

printf 'ok\n'
PASSED=$((PASSED + 1))

# ============================================================================
# T4: ensure idempotent reuse returns existing pane
# Verifies that calling ensure a second time with the same index reuses the
# existing pane instead of creating a new one.
# ============================================================================
printf 'T4: ensure idempotent reuse ... '

ENSURE_JSON_2=$("$ENSURE_SCRIPT" --index "$INDEX" --new-window)
PANE_ID_2=$(json_string_field "$ENSURE_JSON_2" pane_id)
assert_equals "$PANE_ID" "$PANE_ID_2" 'T4 pane_id reuse'

printf 'ok\n'
PASSED=$((PASSED + 1))

# ============================================================================
# T5: reconcile recovers a command that completed despite interrupted state
# Verifies Fix 3 Part B (Significant #5): reconcile checks sentinel in the
# interrupted:* handler, returning 'recovered' instead of 'interrupted'.
# ============================================================================
printf 'T5: reconcile recovers completed command in interrupted state ... '

# Run a fast command to get its request_id and sentinel in the log
fast_submit=$("$SUBMIT_SCRIPT" --cmd 'printf sentinel-check' < "$ENSURE_FILE")
fast_request_id=$(json_string_field "$fast_submit" request_id)
fast_output=$("$WAIT_SCRIPT" --request-id "$fast_request_id" --timeout-seconds 5 < "$ENSURE_FILE")
assert_equals 'ok' "$(json_string_field "$fast_output" status)" 'T5 prereq status'
assert_non_empty "$fast_request_id" 'T5 prereq request_id'

# Simulate the TOCTOU race: manually set state to interrupted:REQUEST_ID
# even though the command has completed (sentinel exists in log)
tmux set-option -p -q -t "$PANE_ID" '@tmux_skill_request_state' "interrupted:$fast_request_id" >/dev/null 2>&1

recover_output=$("$RECOVER_SCRIPT" < "$ENSURE_FILE")
assert_equals 'recovered' "$(json_string_field "$recover_output" status)" 'T5 recovery status'
assert_equals "$fast_request_id" "$(json_string_field "$recover_output" request_id)" 'T5 recovery request_id'

# Verify state is now idle
request_state=$(tmux show-options -p -v -q -t "$PANE_ID" '@tmux_skill_request_state' 2>/dev/null || true)
assert_equals 'idle' "$request_state" 'T5 state after recovery'

printf 'ok\n'
PASSED=$((PASSED + 1))

# ============================================================================
# T6: post-recovery command works after T5's simulated race
# Verifies the pane is fully operational after recovering from a simulated
# TOCTOU-interrupted state.
# ============================================================================
printf 'T6: post-TOCTOU-recovery command works ... '

post_submit=$("$SUBMIT_SCRIPT" --cmd 'printf post-toctou-recovery' < "$ENSURE_FILE")
post_request_id=$(json_string_field "$post_submit" request_id)
post_output=$("$WAIT_SCRIPT" --request-id "$post_request_id" --timeout-seconds 5 < "$ENSURE_FILE")
assert_equals 'ok' "$(json_string_field "$post_output" status)" 'T6 status'
assert_equals '0' "$(json_number_or_null_field "$post_output" exit_code)" 'T6 exit_code'

printf 'ok\n'
PASSED=$((PASSED + 1))

# ============================================================================
# T7: non-zero exit code is captured correctly
# Verifies that the sentinel protocol correctly captures non-zero exit codes
# rather than silently treating them as success.
# ============================================================================
printf 'T7: non-zero exit code captured correctly ... '

nonzero_submit=$("$SUBMIT_SCRIPT" --cmd 'sh -c "exit 42"' < "$ENSURE_FILE")
nonzero_request_id=$(json_string_field "$nonzero_submit" request_id)
nonzero_output=$("$WAIT_SCRIPT" --request-id "$nonzero_request_id" --timeout-seconds 5 < "$ENSURE_FILE")

assert_equals 'ok' "$(json_string_field "$nonzero_output" status)" 'T7 status'
assert_equals '42' "$(json_number_or_null_field "$nonzero_output" exit_code)" 'T7 exit_code'

printf 'ok\n'
PASSED=$((PASSED + 1))

# ============================================================================
# Summary
# ============================================================================
printf '\nedge_cases.sh: %d passed, %d failed\n' "$PASSED" "$FAILED"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
