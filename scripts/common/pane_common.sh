#!/bin/sh

MARK_OPTION='@tmux_skill_mark'
REQUEST_STATE_OPTION='@tmux_skill_request_state'
SHELL_STATE_OPTION='@tmux_skill_shell_state'
LOG_FILE_OPTION='@tmux_skill_log_file'
MARK_PREFIX='TMUX_SKILL_PANE_'
DEFAULT_PERCENT=30

normalize_non_negative_integer() {
  normalized=$(printf '%s' "$1" | sed 's/^0*//')

  if [ -z "$normalized" ]; then
    normalized=0
  fi

  printf '%s\n' "$normalized"
}

is_non_negative_integer() {
  case $1 in
    ''|*[!0-9]*)
      return 1
      ;;
  esac

  normalize_non_negative_integer "$1" >/dev/null
}

is_positive_integer() {
  is_non_negative_integer "$1" || return 1

  normalized=$(normalize_non_negative_integer "$1")
  [ "$normalized" -gt 0 ] 2>/dev/null
}

mark_to_index() {
  case $1 in
    "${MARK_PREFIX}"*)
      suffix=${1#"$MARK_PREFIX"}
      ;;
    *)
      return 1
      ;;
  esac

  is_non_negative_integer "$suffix" || return 1
  normalize_non_negative_integer "$suffix"
}

list_current_session_panes() {
  window_ids=$(tmux list-windows -t "$CURRENT_SESSION_ID" -F '#{window_id}') || return 1

  for window_id in $window_ids; do
    tmux list-panes -t "$window_id" -F '#{pane_id}' || return 1
  done
}

pane_in_current_session() {
  pane_session_id=$(tmux display-message -p -t "$1" '#{session_id}' 2>/dev/null) || return 1
  [ "$pane_session_id" = "$CURRENT_SESSION_ID" ]
}

find_matching_pane() {
  requested_index=$1
  FOUND_PANE_ID=''
  FOUND_MATCH_COUNT=0
  pane_ids=$(list_current_session_panes) || return 1

  for pane_id in $pane_ids; do
    pane_mark=$(tmux show-options -p -v -q -t "$pane_id" "$MARK_OPTION")
    pane_index=$(mark_to_index "$pane_mark" 2>/dev/null) || continue

    if [ "$pane_index" = "$requested_index" ]; then
      FOUND_MATCH_COUNT=$((FOUND_MATCH_COUNT + 1))
      FOUND_PANE_ID=$pane_id
    fi
  done
}

allocate_index() {
  used_indexes=' '
  pane_ids=$(list_current_session_panes) || return 1

  for pane_id in $pane_ids; do
    pane_mark=$(tmux show-options -p -v -q -t "$pane_id" "$MARK_OPTION")
    pane_index=$(mark_to_index "$pane_mark" 2>/dev/null) || continue

    case $used_indexes in
      *" $pane_index "*)
        ;;
      *)
        used_indexes="${used_indexes}${pane_index} "
        ;;
    esac
  done

  next_index=0
  while :; do
    case $used_indexes in
      *" $next_index "*)
        next_index=$((next_index + 1))
        ;;
      *)
        printf '%s\n' "$next_index"
        return 0
        ;;
    esac
  done
}

shell_single_quote() {
  escaped=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")
  printf "'%s'" "$escaped"
}

json_escape() {
  escaped=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '%s' "$escaped"
}

output_json() {
  printf '{'
  printf '"mark":"%s",' "$(json_escape "$MARK")"
  printf '"pane_id":"%s",' "$(json_escape "$PANE_ID")"
  printf '"log_file":"%s"' "$(json_escape "$LOG_FILE")"
  printf '}\n'
}

current_pane_command() {
  tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
}

pane_is_dead() {
  pane_dead=$(tmux display-message -p -t "$1" '#{pane_dead}' 2>/dev/null) || return 1
  [ "$pane_dead" = '1' ]
}

pane_in_mode() {
  pane_mode=$(tmux display-message -p -t "$1" '#{pane_in_mode}' 2>/dev/null) || return 1
  [ "$pane_mode" = '1' ]
}

create_log_file() {
  mktemp "${TMPDIR:-/tmp}/tmux-skill.${1}.XXXXXX.log"
}

pipe_pane_to_log() {
  pane_id=$1
  log_file=$2
  quoted_log_file=$(shell_single_quote "$log_file")
  tmux pipe-pane -O -t "$pane_id" "exec cat >> $quoted_log_file" >/dev/null 2>&1
}

build_init_cmd() {
  clear_screen=$1
  init_cmd=" _mark_idle() { tmux set-option -p -t \"\$TMUX_PANE\" $SHELL_STATE_OPTION 'idle' >/dev/null 2>&1; tmux wait-for -S ${MARK}_IDLE >/dev/null 2>&1; };"
  init_cmd="$init_cmd _mark_busy() { tmux set-option -p -t \"\$TMUX_PANE\" $SHELL_STATE_OPTION 'busy' >/dev/null 2>&1; };"
  init_cmd="$init_cmd if [ -n \"\${ZSH_VERSION:-}\" ]; then"
  init_cmd="$init_cmd   autoload -Uz add-zsh-hook 2>/dev/null;"
  init_cmd="$init_cmd   add-zsh-hook precmd _mark_idle 2>/dev/null || precmd_functions+=(_mark_idle);"
  init_cmd="$init_cmd   add-zsh-hook preexec _mark_busy 2>/dev/null || preexec_functions+=(_mark_busy);"
  init_cmd="$init_cmd elif [ -n \"\${BASH_VERSION:-}\" ]; then"
  init_cmd="$init_cmd   PROMPT_COMMAND=\"_mark_idle;\${PROMPT_COMMAND:-}\";"
  init_cmd="$init_cmd   trap '_mark_busy' DEBUG;"
  init_cmd="$init_cmd fi;"
  init_cmd="$init_cmd _mark_idle;"

  if [ "$clear_screen" -eq 1 ]; then
    init_cmd="$init_cmd clear;"
  fi

  printf '%s\n' "$init_cmd"
}

wait_for_shell_state() {
  pane_id=$1
  expected_state=$2
  timeout_seconds=$3
  deadline=$(( $(date +%s) + timeout_seconds ))

  while :; do
    current_state=$(tmux show-options -p -v -q -t "$pane_id" "$SHELL_STATE_OPTION" 2>/dev/null)

    if [ "$current_state" = "$expected_state" ]; then
      return 0
    fi

    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      return 1
    fi

    sleep 1
  done
}
