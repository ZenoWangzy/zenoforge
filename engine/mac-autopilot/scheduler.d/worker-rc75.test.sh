#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$script_dir/test-env.sh"

fixture="$test_env_root/worker-rc75"; sup="$fixture/supervisor"
mkdir -p "$sup/autopi/alerts"
cp "$script_dir/config.template.json" "$sup/autopi/config.json"
printf '{"workers":[]}\n' > "$sup/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$test_env_root/repo-root" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup"
mkdir -p "$MAC_AUTOPILOT_ROOT"
export CODEX_SESSIONS_DIR="$fixture/sessions" AUTOPI_TEST_LIBRARY_ONLY=true
export REQUIRED_PR_CHECKS_FILE="$test_env_root/required-pr-checks.json"
printf '{"required":[],"current_regression":"","legacy_regression":[]}\n' > "$REQUIRED_PR_CHECKS_FILE"
export PATH="$script_dir/../gh-shim:$PATH"

fail() { echo "worker-rc75.test.sh: $*" >&2; exit 1; }
source "$script_dir/scheduler.sh"

dead_pid() {
  local pid
  bash -c 'exec -a worker-fake sleep 0.05' >/dev/null 2>&1 & pid=$!
  wait "$pid" 2>/dev/null || true
  printf '%s' "$pid"
}

write_unit() { jq -cn --arg id "$1" '{units:[{id:$id,issue:75,stage:"implement",history:[]}]}' > "$UNITS"; }
write_worker() { # unit suffix session-number → install one finished rc=75 worker and its sidecar
  local unit="$1" suffix="$2" pid log started session reason='no progress for 1800s: simulated CPU starvation'
  pid="$(dead_pid)"; log="impl-${unit}-${suffix}.worker.log"
  started="$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
  printf -v session 'bbbbbbbb-0000-0000-0000-%012d' "$3"
  printf '{"type":"thread.started","thread_id":"%s"}\n{"type":"turn.started"}\n{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":321,"cached_input_tokens":123,"output_tokens":45}}}}\nworker: %s\n' \
    "$session" "$reason" > "$sup/$log"
  printf '{"type":"pipeline.exit","rc":75}\n' > "$sup/$log.pipeline-exit"
  jq -cn --argjson pid "$pid" --arg unit "$unit" --arg log "$log" --arg report "$unit-$suffix.md" \
    --arg started "$started" \
    '{workers:[{pid:$pid,unit:$unit,type:"implement",log:$log,report:$report,started:$started,
      model:"gpt-6-luna",provider:"codex",process_group:$pid}]}' > "$WORKERS"
}

check_eq() {
  local want="$1" got="$2" label="$3"
  [[ "$got" == "$want" ]] && { echo "PASS $label"; return; }
  echo "FAIL $label: expected $want, got $got" >&2
  failures=$((failures + 1))
}
check_contains() {
  local want="$1" got="$2" label="$3"
  [[ "$got" == *"$want"* ]] && { echo "PASS $label"; return; }
  echo "FAIL $label: missing '$want' in '$got'" >&2
  failures=$((failures + 1))
}

failures=0
reason='no progress for 1800s: simulated CPU starvation'
unit_once=issue-rc75-once
write_unit "$unit_once"
write_worker "$unit_once" first 1
harvest_workers
check_eq implement-pending "$(unit_field "$unit_once" .stage)" 'one rc=75 exit requeues the unit'
check_eq worker-rc75 "$(unit_field "$unit_once" '.history[-1].stage')" 'rc=75 history event is recorded'
check_contains 'rc=75' "$(unit_field "$unit_once" '.history[-1].result')" 'history names rc=75'
check_contains "$reason" "$(unit_field "$unit_once" '.history[-1].result')" 'history keeps the failover reason'
jqf -e '.sessions["bbbbbbbb-0000-0000-0000-000000000001"].incomplete == true
  and ([.sessions["bbbbbbbb-0000-0000-0000-000000000001"].turns[] | select(.in==321 and .cached==123 and .out==45)] | length == 1)' \
  "$BUDGET_EVENTS" >/dev/null 2>&1 && echo 'PASS rc=75 harvest records partial token usage' \
  || { echo 'FAIL rc=75 harvest records partial token usage' >&2; failures=$((failures + 1)); }

unit_capped=issue-rc75-capped
write_unit "$unit_capped"
for n in 1 2 3; do
  if (( n > 1 )); then
    set_unit "$unit_capped" '(.history //= []) | .history += [{stage:"write-start",result:"retry dispatch"}]'
  fi
  write_worker "$unit_capped" "$n" "$((n + 1))"
  harvest_workers
done
check_eq supervisor-review "$(unit_field "$unit_capped" .stage)" 'third consecutive rc=75 parks the unit'
check_contains 'rc=75' "$(unit_field "$unit_capped" .note)" 'stop-loss reason names rc=75'
check_contains "$reason" "$(unit_field "$unit_capped" .note)" 'stop-loss reason keeps the failover reason'
rc75_events="$(jqf -r --arg id "$unit_capped" '[.units[]|select(.id==$id)|.history[]|select(.stage=="worker-rc75")]|length' "$UNITS")"
check_eq 3 "$rc75_events" 'three consecutive rc=75 events are retained'

(( failures == 0 )) || exit 1
echo 'worker-rc75.test.sh: PASS'
