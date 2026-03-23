#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CHECK_TMUX_SCRIPT="$ROOT_DIR/check_tmux.sh"

SUITES='
helper_units.sh
cli_validation.sh
pane_management.sh
request_protocol.sh
request_flow.sh
edge_cases.sh
'

"$CHECK_TMUX_SCRIPT" >/dev/null

old_ifs=$IFS
IFS='
'

for suite in $SUITES; do
  [ -n "$suite" ] || continue
  printf '==> %s\n' "$suite"
  sh "$SCRIPT_DIR/$suite"
done

IFS=$old_ifs

printf 'all.sh: ok\n'

