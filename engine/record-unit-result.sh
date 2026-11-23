#!/usr/bin/env bash
set -euo pipefail

stage="${1:-}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/config.sh" # deploy.env: a clean environment still sees the deployment's unit prefix
# Same setting lib.sh resolves (lib.sh is sourced further down).
UNIT_PREFIX_TRANSIENT="${ZF_UNIT_PREFIX:-zf}"
unit_name=""
state_stage="$stage"
issue_ids=()
claim_owner=""
case "$stage" in
  implement|triage|recut)
    [ "$#" -eq 2 ] || { echo "record-unit-result: expected one issue number" >&2; exit 64; }
    issue_ids=("$2")
    unit_name="${UNIT_PREFIX_TRANSIENT}-$stage-$2.service"
    ;;
  triage-batch)
    [ "$#" -ge 2 ] || { echo "record-unit-result: expected batch issue numbers" >&2; exit 64; }
    state_stage=triage
    if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
      unit_name="${UNIT_PREFIX_TRANSIENT}-triage-batch.service"
      issue_ids=("${@:2}")
    else
      claim_owner="$2"
      shift 2
      unit_name="${UNIT_PREFIX_TRANSIENT}-triage-batch.service"
      if [ "${1:-}" = --unit ]; then
        [ "$#" -ge 3 ] || { echo "record-unit-result: expected batch unit name and issue numbers" >&2; exit 64; }
        unit_name="$2"
        shift 2
      fi
      issue_ids=("$@")
    fi
    [ "${#issue_ids[@]}" -gt 0 ] || { echo "record-unit-result: expected batch issue numbers" >&2; exit 64; }
    ;;
  *) echo "record-unit-result: unsupported stage: $stage" >&2; exit 64 ;;
esac
for n in "${issue_ids[@]}"; do
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "record-unit-result: invalid issue number" >&2; exit 64; }
done

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
if [ "$stage" = triage-batch ] && [ "${ZF_AGENT_TEST_MODE:-0}" != 1 ]; then
  if [ -n "$claim_owner" ] && ! coord_release_many "$claim_owner" "${issue_ids[@]}"; then
    echo "record-unit-result: triage batch issue claims could not be released" >&2
  fi
  systemd-run --user --unit="${UNIT_PREFIX_TRANSIENT}-triage-event-${BASHPID:-$$}" --on-active=1s --collect \
    -p RestartForceExitStatus=75 -p RestartSec=1s -p StartLimitIntervalSec=0 \
    -E PATH -E https_proxy -E HTTPS_PROXY -E http_proxy -E HTTP_PROXY -E no_proxy -E NO_PROXY \
    -E NODE_USE_ENV_PROXY -E ZF_ROADMAP_TREE_CACHE_FILE -E TYPESAFE_ENV_FILE \
    "$SCRIPT_DIR/issue-pipeline.sh" --stage triage-event \
    || echo "record-unit-result: could not start the triage event pass" >&2
fi
