#!/bin/sh

set -eu

TEST_LIB_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TEST_ROOT_DIR=$(CDPATH= cd -- "$TEST_LIB_DIR/.." && pwd)

TEST_REGISTERED_WINDOWS=''
TEST_REGISTERED_FILES=''

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equals() {
  expected=$1
  actual=$2
  label=$3

  if [ "$expected" != "$actual" ]; then
    fail "$label: expected '$expected', got '$actual'"
  fi
}

assert_not_equals() {
  left=$1
  right=$2
  label=$3

  if [ "$left" = "$right" ]; then
    fail "$label: expected values to differ, both were '$left'"
  fi
}

assert_non_empty() {
  value=$1
  label=$2

  if [ -z "$value" ]; then
    fail "$label: expected a non-empty value"
  fi
}

assert_file_exists() {
  path=$1
  label=$2

  if [ ! -f "$path" ]; then
    fail "$label: expected file '$path' to exist"
  fi
}

assert_contains() {
  haystack=$1
  needle=$2
  label=$3

  case $haystack in
    *"$needle"*)
      ;;
    *)
      fail "$label: expected '$haystack' to contain '$needle'"
      ;;
  esac
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

register_window() {
  window_id=$1

  if [ -z "$window_id" ]; then
    return 0
  fi

  TEST_REGISTERED_WINDOWS="${TEST_REGISTERED_WINDOWS}${window_id}
"
}

register_file() {
  file_path=$1

  if [ -z "$file_path" ]; then
    return 0
  fi

  TEST_REGISTERED_FILES="${TEST_REGISTERED_FILES}${file_path}
"
}

make_temp_file() {
  template=$1
  file_path=$(mktemp "$template") || fail "failed to create temp file from template '$template'"
  register_file "$file_path"
  printf '%s\n' "$file_path"
}

write_temp_file() {
  template=$1
  content=$2
  file_path=$(make_temp_file "$template")
  printf '%s' "$content" > "$file_path" || fail "failed to write temp file '$file_path'"
  printf '%s\n' "$file_path"
}

window_id_for_pane() {
  tmux display-message -p -t "$1" '#{window_id}' 2>/dev/null || true
}

register_window_for_pane() {
  pane_id=$1
  window_id=$(window_id_for_pane "$pane_id")
  register_window "$window_id"
}

require_tmux_session() {
  if [ -z "${TMUX:-}" ]; then
    fail 'this test must run inside tmux'
  fi
}

wait_for_pane_option() {
  pane_id=$1
  option_name=$2
  expected_value=$3
  timeout_seconds=$4
  deadline=$(( $(date +%s) + timeout_seconds ))

  while :; do
    current_value=$(tmux show-options -p -v -q -t "$pane_id" "$option_name" 2>/dev/null || true)

    if [ "$current_value" = "$expected_value" ]; then
      return 0
    fi

    if [ "$(date +%s)" -ge "$deadline" ]; then
      fail "timed out waiting for $option_name=$expected_value on pane $pane_id (current: '$current_value')"
    fi

    sleep 1
  done
}

wait_for_shell_state() {
  wait_for_pane_option "$1" '@tmux_skill_shell_state' "$2" "$3"
}

wait_for_request_state() {
  wait_for_pane_option "$1" '@tmux_skill_request_state' "$2" "$3"
}

cleanup_test_resources() {
  old_ifs=$IFS
  IFS='
'

  for window_id in $TEST_REGISTERED_WINDOWS; do
    [ -n "$window_id" ] || continue
    tmux kill-window -t "$window_id" >/dev/null 2>&1 || true
  done

  for file_path in $TEST_REGISTERED_FILES; do
    [ -n "$file_path" ] || continue
    rm -f "$file_path" >/dev/null 2>&1 || true
  done

  IFS=$old_ifs
}

