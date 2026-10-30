#!/usr/bin/env bash
set -euo pipefail

stage="${1:-}"
unit_name=""
state_stage="$stage"
issue_ids=()
case "$stage" in
  implement|triage|recut)
    [ "$#" -eq 2 ] || { echo "record-unit-result: expected one issue number" >&2; exit 64; }
    issue_ids=("$2")
    unit_name="zf-$stage-$2.service"
    ;;
  triage-batch)
    [ "$#" -ge 2 ] || { echo "record-unit-result: expected batch issue numbers" >&2; exit 64; }
    state_stage=triage
    unit_name=zf-triage-batch.service
    issue_ids=("${@:2}")
    ;;
  *) echo "record-unit-result: unsupported stage: $stage" >&2; exit 64 ;;
esac
for n in "${issue_ids[@]}"; do
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "record-unit-result: invalid issue number" >&2; exit 64; }
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

result="$(jq -n \
  --arg result "${SERVICE_RESULT:-unknown}" \
  --arg exit_code "${EXIT_CODE:-unknown}" \
  --arg exit_status "${EXIT_STATUS:-unknown}" \
  --arg unit "$unit_name" \
  '{unit:$unit, result:$result, exit_code:$exit_code, exit_status:$exit_status, recorded_at:(now|todate)}')"
for n in "${issue_ids[@]}"; do
  state_merge "$n" ".unit_results.$state_stage = $result"
done

if [ "$stage" = implement ]; then
  node "$SCRIPT_DIR/night/attempt-terminal.mjs" terminal "${issue_ids[0]}"
fi
