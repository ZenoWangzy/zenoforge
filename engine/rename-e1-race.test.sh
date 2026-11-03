#!/usr/bin/env bash
# A stale paginated listing must not mask a more recent legacy stop.
set -euo pipefail
source "$(dirname "$0")/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"
LIST_DATA='[]'
GET_DATA=''
GET_ERROR=''
GET_NUL=0
CONFIRM_FAILURE=0
JQ_RECHECK_FAILURE=0
COUNT_FILE="$test_env_root/list-count"
jq() {
  if [[ "$JQ_RECHECK_FAILURE" == 1 && "$*" == *'invalid legacy mode data'* ]]; then return 2; fi
  command jq "$@"
}
gh() {
  case "$1 $2" in
    'variable list')
      local count=0
      [[ ! -e "$COUNT_FILE" ]] || count="$(cat "$COUNT_FILE")"
      printf '%s' "$((count + 1))" > "$COUNT_FILE"
      if [[ "$CONFIRM_FAILURE" == 1 && "$count" -gt 0 ]]; then echo 'fixture list failure' >&2; return 1; fi
      printf '%s\n' "$LIST_DATA" ;;
    'variable get')
      [[ " $* " != *' --json '* ]] || { echo 'unsupported get option' >&2; return 1; }
      if [[ -n "$GET_ERROR" ]]; then printf '%s\n' "$GET_ERROR" >&2; return 1; fi
      if [[ "$GET_NUL" == 1 ]]; then printf 'tri\0age\n'; return 0; fi
      printf '%s\n' "$GET_DATA" ;;
    *) return 1 ;;
  esac
}
check() {
  local name="$1" expected="$2" result
  printf 0 > "$COUNT_FILE"
  result="$(read_zenoforge_mode race 2> "$test_env_root/race.err")"
  [[ "$result" == "$expected" ]] || { printf 'not ok - %s: expected %s, got %s\n' "$name" "$expected" "$result" >&2; exit 1; }
  printf 'ok - %s\n' "$name"
}
LIST_DATA='[{"name":"AGENT_PIPELINE","value":"triage"},{"name":"AGENT_ZENOFORGE","value":"triage"}]'
GET_DATA='off'
check 'fresh legacy stop wins over stale paginated running pair' off
GET_DATA='triage'
check 'stable running pair stays enabled' triage
GET_NUL=1
check 'NUL in direct legacy value stops' off
GET_NUL=0
JQ_RECHECK_FAILURE=1
check 'failed direct legacy parse stops' off
JQ_RECHECK_FAILURE=0
GET_ERROR='fixture authentication failure'
check 'failed direct legacy recheck stops' off
LIST_DATA='[{"name":"AGENT_ZENOFORGE","value":"triage"}]'
GET_ERROR='variable AGENT_PIPELINE was not found'
CONFIRM_FAILURE=1
check 'missing legacy key with failed access confirmation stops' off
CONFIRM_FAILURE=0
check 'confirmed missing legacy key permits preferred-only mode' triage
GET_ERROR=''
GET_DATA='off'
check 'newly created legacy stop wins over stale absence' off
echo 'rename-e1-race.test.sh: PASS'
