#!/bin/sh

TMUX_SKILL_MARK_OPTION='@tmux_skill_mark'
TMUX_SKILL_REQUEST_STATE_OPTION='@tmux_skill_request_state'
TMUX_SKILL_SHELL_STATE_OPTION='@tmux_skill_shell_state'
TMUX_SKILL_LOCK_PREFIX='tmux-skill-request:'
TMUX_SKILL_INTERRUPTED_WAIT_SECONDS=1

. "${SCRIPT_DIR:?SCRIPT_DIR must be set before sourcing request_common}/tmux_skill_pane_common.sh"

TMUX_SKILL_INPUT_JSON=''
TMUX_SKILL_INPUT_JSON_COMPACT=''
TMUX_SKILL_MARK=''
TMUX_SKILL_PANE_ID=''
TMUX_SKILL_LOG_FILE=''
TMUX_SKILL_HOST_SESSION_ID=''
TMUX_SKILL_LOCK_CHANNEL=''
TMUX_SKILL_LOCK_HELD=0
TMUX_SKILL_ERROR_CODE=''
TMUX_SKILL_ERROR_MESSAGE=''
TMUX_SKILL_RECOVERY_STATUS=''
TMUX_SKILL_RECOVERY_MESSAGE=''
TMUX_SKILL_RECOVERY_REQUEST_ID=''
TMUX_SKILL_REQUEST_COMPLETE=0
TMUX_SKILL_RESULT_EXIT_CODE=''
TMUX_SKILL_CLEAN_START_OFFSET=''
TMUX_SKILL_CLEAN_END_OFFSET=''
TMUX_SKILL_SEARCH_START_OFFSET=''

tmux_skill_set_error() {
  TMUX_SKILL_ERROR_CODE=$1
  TMUX_SKILL_ERROR_MESSAGE=$2
}

tmux_skill_json_string_or_null() {
  if [ -n "$1" ]; then
    printf '"%s"' "$(json_escape "$1")"
  else
    printf 'null'
  fi
}

tmux_skill_json_number_or_null() {
  if [ -n "$1" ]; then
    printf '%s' "$1"
  else
    printf 'null'
  fi
}

tmux_skill_extract_json_string_from_compact() {
  compact_json=$1
  key=$2
  printf '%s\n' "$compact_json" | sed -n "s/.*\"$key\":\"\\([^\"]*\\)\".*/\\1/p"
}

tmux_skill_extract_json_number_from_compact() {
  compact_json=$1
  key=$2
  printf '%s\n' "$compact_json" | sed -n "s/.*\"$key\":\\([0-9][0-9]*\\|null\\).*/\\1/p"
}

tmux_skill_byte_count() {
  wc -c < "$1" | tr -d ' '
}

tmux_skill_byte_length() {
  printf '%s' "$1" | wc -c | tr -d ' '
}

tmux_skill_find_fixed_offset_after() {
  search_file=$1
  pattern=$2
  min_offset=$3
  LC_ALL=C grep -aboF -- "$pattern" "$search_file" 2>/dev/null |
    awk -F: -v min="$min_offset" '$1 >= min { print $1; exit }'
}

tmux_skill_parse_exit_code_between() {
  parse_file=$1
  start_offset=$2
  end_offset=$3
  length=$((end_offset - start_offset))

  if [ "$length" -lt 0 ]; then
    return 1
  fi

  dd if="$parse_file" bs=1 skip="$start_offset" count="$length" 2>/dev/null
}

tmux_skill_cleanup() {
  if [ "$TMUX_SKILL_LOCK_HELD" -eq 1 ] && [ -n "$TMUX_SKILL_LOCK_CHANNEL" ]; then
    tmux wait-for -U "$TMUX_SKILL_LOCK_CHANNEL" >/dev/null 2>&1 || true
    TMUX_SKILL_LOCK_HELD=0
  fi
}

tmux_skill_require_tmux_session() {
  if ! command -v tmux >/dev/null 2>&1; then
    tmux_skill_set_error 127 'tmux not found in PATH'
    return 1
  fi

  if [ -z "${TMUX:-}" ]; then
    tmux_skill_set_error 2 'not running inside a tmux session'
    return 1
  fi

  TMUX_SKILL_HOST_SESSION_ID=$(tmux display-message -p '#{session_id}' 2>/dev/null) || {
    tmux_skill_set_error 2 'unable to determine the current tmux session'
    return 1
  }
}

tmux_skill_load_ensure_json_from_stdin() {
  TMUX_SKILL_INPUT_JSON=$(cat)
  [ -n "$TMUX_SKILL_INPUT_JSON" ] || {
    tmux_skill_set_error 3 'expected ensure JSON on stdin'
    return 1
  }

  TMUX_SKILL_INPUT_JSON_COMPACT=$(printf '%s' "$TMUX_SKILL_INPUT_JSON" | tr -d '\n')
  TMUX_SKILL_MARK=$(tmux_skill_extract_json_string_from_compact "$TMUX_SKILL_INPUT_JSON_COMPACT" mark)
  TMUX_SKILL_PANE_ID=$(tmux_skill_extract_json_string_from_compact "$TMUX_SKILL_INPUT_JSON_COMPACT" pane_id)
  TMUX_SKILL_LOG_FILE=$(tmux_skill_extract_json_string_from_compact "$TMUX_SKILL_INPUT_JSON_COMPACT" log_file)

  [ -n "$TMUX_SKILL_MARK" ] || {
    tmux_skill_set_error 3 'stdin JSON is missing mark'
    return 1
  }

  [ -n "$TMUX_SKILL_PANE_ID" ] || {
    tmux_skill_set_error 3 'stdin JSON is missing pane_id'
    return 1
  }

  [ -n "$TMUX_SKILL_LOG_FILE" ] || {
    tmux_skill_set_error 3 'stdin JSON is missing log_file'
    return 1
  }

  [ -f "$TMUX_SKILL_LOG_FILE" ] || {
    tmux_skill_set_error 6 'log_file does not exist'
    return 1
  }

  [ -r "$TMUX_SKILL_LOG_FILE" ] || {
    tmux_skill_set_error 6 'log_file is not readable'
    return 1
  }

  current_pane_session_id=$(tmux display-message -p -t "$TMUX_SKILL_PANE_ID" '#{session_id}' 2>/dev/null) || {
    tmux_skill_set_error 3 'pane_id is not a live tmux pane'
    return 1
  }

  [ "$current_pane_session_id" = "$TMUX_SKILL_HOST_SESSION_ID" ] || {
    tmux_skill_set_error 3 'pane_id does not belong to the current tmux session'
    return 1
  }

  current_mark=$(tmux show-options -p -v -q -t "$TMUX_SKILL_PANE_ID" "$TMUX_SKILL_MARK_OPTION" 2>/dev/null)
  [ "$current_mark" = "$TMUX_SKILL_MARK" ] || {
    tmux_skill_set_error 3 'pane_id mark does not match stdin JSON'
    return 1
  }
}

tmux_skill_lock_request() {
  TMUX_SKILL_LOCK_CHANNEL="${TMUX_SKILL_LOCK_PREFIX}${TMUX_SKILL_PANE_ID}"

  tmux wait-for -L "$TMUX_SKILL_LOCK_CHANNEL" >/dev/null 2>&1 || {
    tmux_skill_set_error 5 'failed to acquire request lock'
    return 1
  }

  TMUX_SKILL_LOCK_HELD=1
}

tmux_skill_request_has_end_sentinel() {
  request_log_file=$1
  request_id=$2
  request_end_prefix="__TMUX_SKILL_RC_BEGIN__${request_id}__"
  request_end_prefix_length=$(tmux_skill_byte_length "$request_end_prefix")
  request_end_prefix_offset=$(tmux_skill_find_fixed_offset_after "$request_log_file" "$request_end_prefix" 0)

  [ -n "$request_end_prefix_offset" ] || return 1

  request_end_suffix="__TMUX_SKILL_RC_END__${request_id}__"
  request_end_suffix_search_start=$((request_end_prefix_offset + request_end_prefix_length))
  request_end_suffix_offset=$(tmux_skill_find_fixed_offset_after "$request_log_file" "$request_end_suffix" "$request_end_suffix_search_start")
  [ -n "$request_end_suffix_offset" ]
}

tmux_skill_set_request_state() {
  state=$1

  tmux set-option -p -q -t "$TMUX_SKILL_PANE_ID" "$TMUX_SKILL_REQUEST_STATE_OPTION" "$state" >/dev/null 2>&1 || {
    tmux_skill_set_error 5 "failed to set managed request state to $state"
    return 1
  }
}

tmux_skill_current_shell_state() {
  tmux show-options -p -v -q -t "$TMUX_SKILL_PANE_ID" "$TMUX_SKILL_SHELL_STATE_OPTION" 2>/dev/null
}

tmux_skill_mark_request_interrupted_if_stale() {
  request_id=$1
  expected_busy_state="busy:$request_id"
  interrupted_state="interrupted:$request_id"
  current_state=$(tmux_skill_current_request_state)

  case $current_state in
    "$interrupted_state")
      return 0
      ;;
    "$expected_busy_state")
      ;;
    *)
      return 1
      ;;
  esac

  if tmux_skill_request_has_end_sentinel "$TMUX_SKILL_LOG_FILE" "$request_id"; then
    return 1
  fi

  shell_state=$(tmux_skill_current_shell_state)
  [ "$shell_state" = 'idle' ] || return 1

  sleep "$TMUX_SKILL_INTERRUPTED_WAIT_SECONDS"

  current_state=$(tmux_skill_current_request_state)
  case $current_state in
    "$interrupted_state")
      return 0
      ;;
    "$expected_busy_state")
      ;;
    *)
      return 1
      ;;
  esac

  if tmux_skill_request_has_end_sentinel "$TMUX_SKILL_LOG_FILE" "$request_id"; then
    return 1
  fi

  shell_state=$(tmux_skill_current_shell_state)
  [ "$shell_state" = 'idle' ] || return 1

  # Final request_state re-check: the managed command may have completed
  # between our sentinel scan and now, setting request_state to idle from
  # within the pane. Only write interrupted if still busy:ID.
  current_state=$(tmux_skill_current_request_state)
  case $current_state in
    "$expected_busy_state")
      ;;
    *)
      return 1
      ;;
  esac

  tmux_skill_set_request_state "$interrupted_state" || return 2
}

tmux_skill_reconcile_request_state() {
  current_state=$(tmux show-options -p -v -q -t "$TMUX_SKILL_PANE_ID" "$TMUX_SKILL_REQUEST_STATE_OPTION" 2>/dev/null)

  case $current_state in
    ''|idle)
      TMUX_SKILL_RECOVERY_STATUS='idle'
      TMUX_SKILL_RECOVERY_MESSAGE=''
      TMUX_SKILL_RECOVERY_REQUEST_ID=''
      return 0
      ;;
    busy)
      TMUX_SKILL_RECOVERY_STATUS='busy'
      TMUX_SKILL_RECOVERY_MESSAGE='target pane uses a legacy busy state without a recoverable request id'
      TMUX_SKILL_RECOVERY_REQUEST_ID=''
      return 1
      ;;
    interrupted:*)
      TMUX_SKILL_RECOVERY_REQUEST_ID=${current_state#interrupted:}

      # Check if the command actually completed despite the interrupted state.
      # This handles the TOCTOU race where the managed command finished between
      # the waiter's final sentinel scan and the interrupted state write.
      if tmux_skill_request_has_end_sentinel "$TMUX_SKILL_LOG_FILE" "$TMUX_SKILL_RECOVERY_REQUEST_ID"; then
        tmux_skill_set_request_state 'idle' || {
          tmux_skill_set_error 5 'failed to recover a stale busy managed request'
          return 2
        }

        TMUX_SKILL_RECOVERY_STATUS='recovered'
        TMUX_SKILL_RECOVERY_MESSAGE=''
        return 0
      fi

      tmux_skill_set_request_state 'idle' || {
        tmux_skill_set_error 5 'failed to clear an interrupted managed request'
        return 2
      }

      TMUX_SKILL_RECOVERY_STATUS='interrupted'
      TMUX_SKILL_RECOVERY_MESSAGE='managed request returned to the shell without a completion sentinel'
      return 0
      ;;
    busy:*)
      TMUX_SKILL_RECOVERY_REQUEST_ID=${current_state#busy:}

      if tmux_skill_request_has_end_sentinel "$TMUX_SKILL_LOG_FILE" "$TMUX_SKILL_RECOVERY_REQUEST_ID"; then
        tmux_skill_set_request_state 'idle' || {
          tmux_skill_set_error 5 'failed to recover a stale busy managed request'
          return 2
        }

        TMUX_SKILL_RECOVERY_STATUS='recovered'
        TMUX_SKILL_RECOVERY_MESSAGE=''
        return 0
      fi

      tmux_skill_mark_request_interrupted_if_stale "$TMUX_SKILL_RECOVERY_REQUEST_ID"
      stale_interrupt_rc=$?

      case $stale_interrupt_rc in
        0)
          tmux_skill_set_request_state 'idle' || {
            tmux_skill_set_error 5 'failed to clear an interrupted managed request'
            return 2
          }

          TMUX_SKILL_RECOVERY_STATUS='interrupted'
          TMUX_SKILL_RECOVERY_MESSAGE='managed request returned to the shell without a completion sentinel'
          return 0
          ;;
        1)
          ;;
        *)
          return 2
          ;;
      esac

      TMUX_SKILL_RECOVERY_STATUS='busy'
      TMUX_SKILL_RECOVERY_MESSAGE='request still appears active or is not safely recoverable'
      return 1
      ;;
    *)
      tmux_skill_set_error 5 'unexpected managed request state'
      return 2
      ;;
  esac
}

tmux_skill_generate_request_id() {
  printf '%s-%s\n' "$(date +%s)" "$$"
}

tmux_skill_send_managed_command() {
  request_id=$1
  command_string=$2

  tmux set-option -p -q -t "$TMUX_SKILL_PANE_ID" "$TMUX_SKILL_REQUEST_STATE_OPTION" "busy:$request_id" >/dev/null 2>&1 || {
    tmux_skill_set_error 5 'failed to mark target pane request state as busy'
    return 1
  }

  TMUX_SKILL_SEARCH_START_OFFSET=$(tmux_skill_byte_count "$TMUX_SKILL_LOG_FILE")
  quoted_request_id=$(shell_single_quote "$request_id")
  quoted_command=$(shell_single_quote "$command_string")
  quoted_request_state_option=$(shell_single_quote "$TMUX_SKILL_REQUEST_STATE_OPTION")
  quoted_target_pane=$(shell_single_quote "$TMUX_SKILL_PANE_ID")
  wrapped_command="__tmux_skill_req=$quoted_request_id; __tmux_skill_target=$quoted_target_pane; __tmux_skill_request_option=$quoted_request_state_option; __tmux_skill_cmd=$quoted_command; printf '%s%s%s' '__TMUX_SKILL_BEGIN__' \"\$__tmux_skill_req\" '__'; eval \"\$__tmux_skill_cmd\"; __tmux_skill_rc=\$?; printf '%s%s%s%s%s' '__TMUX_SKILL_RC_BEGIN__' \"\$__tmux_skill_req\" '__' \"\$__tmux_skill_rc\" '__TMUX_SKILL_RC_END__'; printf '%s%s' \"\$__tmux_skill_req\" '__'; tmux set-option -p -t \"\$__tmux_skill_target\" \"\$__tmux_skill_request_option\" idle >/dev/null 2>&1"

  if ! tmux send-keys -l -t "$TMUX_SKILL_PANE_ID" "$wrapped_command" >/dev/null 2>&1; then
    tmux set-option -p -q -t "$TMUX_SKILL_PANE_ID" "$TMUX_SKILL_REQUEST_STATE_OPTION" 'idle' >/dev/null 2>&1 || true
    tmux_skill_set_error 5 'failed to send command to target pane'
    return 1
  fi

  if ! tmux send-keys -t "$TMUX_SKILL_PANE_ID" C-m >/dev/null 2>&1; then
    tmux set-option -p -q -t "$TMUX_SKILL_PANE_ID" "$TMUX_SKILL_REQUEST_STATE_OPTION" 'idle' >/dev/null 2>&1 || true
    tmux_skill_set_error 5 'failed to execute command in target pane'
    return 1
  fi
}

tmux_skill_find_request_result() {
  request_id=$1
  search_start_offset=$2

  TMUX_SKILL_REQUEST_COMPLETE=0
  TMUX_SKILL_RESULT_EXIT_CODE=''
  TMUX_SKILL_CLEAN_START_OFFSET=''
  TMUX_SKILL_CLEAN_END_OFFSET=''

  start_sentinel="__TMUX_SKILL_BEGIN__${request_id}__"
  end_sentinel_prefix="__TMUX_SKILL_RC_BEGIN__${request_id}__"
  end_sentinel_suffix="__TMUX_SKILL_RC_END__${request_id}__"
  start_sentinel_length=$(tmux_skill_byte_length "$start_sentinel")
  end_sentinel_prefix_length=$(tmux_skill_byte_length "$end_sentinel_prefix")

  start_sentinel_offset=$(tmux_skill_find_fixed_offset_after "$TMUX_SKILL_LOG_FILE" "$start_sentinel" "$search_start_offset")
  end_sentinel_prefix_offset=$(tmux_skill_find_fixed_offset_after "$TMUX_SKILL_LOG_FILE" "$end_sentinel_prefix" "$search_start_offset")

  if [ -n "$start_sentinel_offset" ]; then
    TMUX_SKILL_CLEAN_START_OFFSET=$((start_sentinel_offset + start_sentinel_length))
  fi

  if [ -z "$end_sentinel_prefix_offset" ]; then
    return 1
  fi

  end_sentinel_suffix_search_start=$((end_sentinel_prefix_offset + end_sentinel_prefix_length))
  end_sentinel_suffix_offset=$(tmux_skill_find_fixed_offset_after "$TMUX_SKILL_LOG_FILE" "$end_sentinel_suffix" "$end_sentinel_suffix_search_start")
  [ -n "$end_sentinel_suffix_offset" ] || return 1

  TMUX_SKILL_CLEAN_END_OFFSET=$end_sentinel_prefix_offset
  exit_code_start_offset=$((end_sentinel_prefix_offset + end_sentinel_prefix_length))
  TMUX_SKILL_RESULT_EXIT_CODE=$(tmux_skill_parse_exit_code_between "$TMUX_SKILL_LOG_FILE" "$exit_code_start_offset" "$end_sentinel_suffix_offset") || {
    tmux_skill_set_error 6 'failed to parse command exit code from log'
    return 2
  }

  case $TMUX_SKILL_RESULT_EXIT_CODE in
    ''|*[!0-9]*)
      tmux_skill_set_error 6 'failed to parse command exit code from log'
      return 2
      ;;
  esac

  if [ -z "$TMUX_SKILL_CLEAN_START_OFFSET" ]; then
    tmux_skill_set_error 6 'start sentinel was not found in the log'
    return 2
  fi

  TMUX_SKILL_REQUEST_COMPLETE=1
  return 0
}

tmux_skill_current_request_state() {
  tmux show-options -p -v -q -t "$TMUX_SKILL_PANE_ID" "$TMUX_SKILL_REQUEST_STATE_OPTION" 2>/dev/null
}
