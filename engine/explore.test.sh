#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$test_env_root/repo"
ZF_REPO_DIR="$REPO_DIR"
ZF_CONFIG_ROOT="$REPO_DIR/.zenoforge"
ZF_ENGINE_DIR="$SCRIPT_DIR"
ZF_REPO=fixture/repo
ZF_UNIT_PREFIX=zf
MAC_AUTOPILOT_RUNTIME_DIR="$test_env_root/autopi"
SYSTEMD_RUN_LOG="$test_env_root/systemd-run.log"
UPSERT_LOG="$test_env_root/upsert.log"
UPSERT_BODY="$test_env_root/upsert-body.md"
DRIVER_CALLS="$test_env_root/driver-calls.log"
DRIVER_PARENT_CALLS="$test_env_root/driver-parent-calls.log"
LEASE_CALLS="$test_env_root/lease-calls.log"
LEASE_PID_FILE="$test_env_root/lease.pid"
CODEX_HOME="$test_env_root/codex"
mkdir -p "$REPO_DIR/.zenoforge/state" "$MAC_AUTOPILOT_RUNTIME_DIR" "$test_env_root/bin"
unset ZF_CDP_BROWSER_LEASE_SCRIPT
export ZF_REPO_DIR ZF_CONFIG_ROOT ZF_ENGINE_DIR ZF_REPO ZF_UNIT_PREFIX MAC_AUTOPILOT_RUNTIME_DIR
export SYSTEMD_RUN_LOG UPSERT_LOG UPSERT_BODY DRIVER_CALLS DRIVER_PARENT_CALLS LEASE_CALLS LEASE_PID_FILE CODEX_HOME
export PATH="$test_env_root/bin:$PATH"

cat > "$test_env_root/bin/systemd-run" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMD_RUN_LOG"
SH
cat > "$test_env_root/bin/systemctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$test_env_root/bin/systemd-run" "$test_env_root/bin/systemctl"

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
check() { [[ "$2" == "$3" ]] || fail "$1: got '$2', want '$3'"; printf 'ok - %s\n' "$1"; }
contains() { grep -Fq -- "$2" "$1" || fail "$3"; }
write_live() {
  mkdir -p "$AGENT_HOME/state"
  jq -cn --arg sha "$1" --arg at "$(date -u +%FT%TZ)" '{sha:$sha,at:$at,source:"test"}' > "$AGENT_HOME/state/live-sha.json"
}
write_config() {
  local wall="$1" tokens="$2" timeout="${3:-30}"
  mkdir -p "$ZF_CONFIG_ROOT/state"
  jq -cn --arg driver "$REPO_DIR/driver.sh" --argjson wall "$wall" --argjson tokens "$tokens" --argjson timeout "$timeout" \
    '{enabled:true,driver:{argv:[$driver],timeout_s:$timeout,evidence_dir:"run-evidence"},feature_map:"state/feature-map.json",budget:{wall_seconds:$wall,max_tokens:$tokens,max_features:1},max_filed_per_run:3,allowed_effects:["read"]}' \
    > "$ZF_CONFIG_ROOT/state/exploration.json"
  jq -cn '{version:1,features:[{id:"search",title:"Search",path_prefixes:[],entrypoints:[],surfaces:[],invariants:[],proofs:{}}]}' \
    > "$ZF_CONFIG_ROOT/state/feature-map.json"
}

cat > "$REPO_DIR/upsert.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$UPSERT_LOG"
[[ "${UPSERT_FAIL:-0}" != 1 ]] || exit 1
while (($#)); do
  case "$1" in
    --body-file) cp -- "$2" "$UPSERT_BODY"; shift 2 ;;
    *) shift ;;
  esac
done
SH
chmod +x "$REPO_DIR/upsert.sh"
export ZF_EXPLORE_ISSUE_UPSERT="$REPO_DIR/upsert.sh"

missing_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
write_live "$missing_sha"
if ! output="$(bash "$SCRIPT_DIR/run-explore.sh" dispatch 2>&1)"; then fail "unconfigured dispatch failed: $output"; fi
missing_state="$AGENT_HOME/state/explore/$missing_sha/state.json"
check 'unconfigured release is recorded as skipped' "$(jq -r .state "$missing_state")" skipped
contains "$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log" 'explore: skipped release=aaaaaaaaaaaa reason=no-config' 'no-config skip was not logged'
bash "$SCRIPT_DIR/run-explore.sh" dispatch >/dev/null
check 'a skipped release is logged once' "$(grep -Fc 'explore: skipped release=aaaaaaaaaaaa reason=no-config' "$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log")" 1

cat > "$REPO_DIR/driver.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s:%s\n' "$ZF_EXPLORATION_FEATURE_ID" "$ZF_EXPLORATION_ATTEMPT" >> "$DRIVER_CALLS"
printf '%s\n' "$PPID" >> "$DRIVER_PARENT_CALLS"
mkdir -p "$ZF_EXPLORATION_EVIDENCE_DIR"
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/R0cAAAAASUVORK5CYII=' | base64 -d > "$ZF_EXPLORATION_EVIDENCE_DIR/screen.png"
if [[ "$DRIVER_MODE" == slow ]]; then sleep 3; fi
error_class=TypeError
if [[ "$DRIVER_MODE" == mismatched && "$ZF_EXPLORATION_ATTEMPT" == 2 ]]; then error_class=TimeoutError; fi
if [[ "$DRIVER_MODE" == pass ]]; then
  jq -cn --arg id "$ZF_EXPLORATION_FEATURE_ID" '{feature_id:$id,status:"pass",steps:["open search"]}' > "$ZF_EXPLORATION_RESULT_FILE"
else
  session_id=
  [[ "$DRIVER_MODE" != tokens ]] || session_id="$DRIVER_SESSION_ID"
  jq -cn --arg id "$ZF_EXPLORATION_FEATURE_ID" --arg error "$error_class" --arg session "$session_id" \
    '{feature_id:$id,status:"fail",steps:["open search","submit query"],failing_step_id:"submit-query",error_class:$error,evidence:["screen.png"]} + (if $session=="" then {} else {session_id:$session} end)' \
    > "$ZF_EXPLORATION_RESULT_FILE"
fi
SH
chmod +x "$REPO_DIR/driver.sh"

cat > "$REPO_DIR/browser-lease.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >> "$LEASE_CALLS"
printf '%s\n' "$$" > "$LEASE_PID_FILE"
[[ "${LEASE_DELAY:-}" == "" ]] || sleep "$LEASE_DELAY"
[[ "${1:-}" == -- ]] || exit 64
shift
"$@"
SH
chmod +x "$REPO_DIR/browser-lease.sh"

leased_sha=ffffffffffffffffffffffffffffffffffffffff
write_config 3600 100
write_live "$leased_sha"
export ZF_CDP_BROWSER_LEASE_SCRIPT="$REPO_DIR/browser-lease.sh"
bash "$SCRIPT_DIR/run-explore.sh" dispatch >/dev/null
contains "$SYSTEMD_RUN_LOG" "ZF_CDP_BROWSER_LEASE_SCRIPT=$REPO_DIR/browser-lease.sh" 'detached exploration did not receive the browser lease path'
export DRIVER_MODE=pass
bash "$SCRIPT_DIR/run-explore.sh" run "$leased_sha" >/dev/null
check 'browser lease receives -- and the driver argv' "$(cat "$LEASE_CALLS" 2>/dev/null || :)" "$(printf '%s\n%s' -- "$REPO_DIR/driver.sh")"
check 'driver runs as a child of the browser lease' "$(tail -n 1 "$DRIVER_PARENT_CALLS")" "$(cat "$LEASE_PID_FILE")"
unset ZF_CDP_BROWSER_LEASE_SCRIPT
lease_calls_before="$(wc -l < "$LEASE_CALLS" | tr -d ' ')"
driver_calls_before="$(wc -l < "$DRIVER_CALLS" | tr -d ' ')"

repro_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
write_config 3600 100
write_live "$repro_sha"
bash "$SCRIPT_DIR/run-explore.sh" dispatch >/dev/null
check 'live release starts one exploration unit' "$(wc -l < "$SYSTEMD_RUN_LOG" | tr -d ' ')" 2
contains "$SYSTEMD_RUN_LOG" 'zf-explore-bbbbbbbbbbbb' 'unit name did not include the live release'
export DRIVER_MODE=repeat
export UPSERT_FAIL=1
if bash "$SCRIPT_DIR/run-explore.sh" run "$repro_sha" >/dev/null 2>&1; then fail 'issue-upsert failure should leave the confirmed defect pending'; fi
check 'a reproduced defect uses two fresh driver runs' "$(wc -l < "$DRIVER_CALLS" | tr -d ' ')" "$((driver_calls_before + 2))"
check 'unset lease variable runs the driver directly' "$(wc -l < "$LEASE_CALLS" | tr -d ' ')" "$lease_calls_before"
check 'same signature creates one pending intake finding' "$(wc -l < "$UPSERT_LOG" | tr -d ' ')" 1
contains "$UPSERT_LOG" '--attach' 'issue upsert did not attach the reproduction evidence'
check 'failed filing remains retryable' "$(jq -r .state "$AGENT_HOME/state/explore/$repro_sha/state.json")" needs-filing
export UPSERT_FAIL=0
bash "$SCRIPT_DIR/run-explore.sh" file "$repro_sha" >/dev/null
check 'pending finding retries with its attachments' "$(wc -l < "$UPSERT_LOG" | tr -d ' ')" 2
contains "$UPSERT_BODY" 'submit query' 'issue body omitted reproduction steps'
contains "$UPSERT_BODY" 'screen.png' 'issue body omitted evidence'
check 'completed release run is marked done' "$(jq -r .state "$AGENT_HOME/state/explore/$repro_sha/state.json")" done
bash "$SCRIPT_DIR/run-explore.sh" run "$repro_sha" >/dev/null
check 'a second invocation does not run or file the defect again' "$(wc -l < "$UPSERT_LOG" | tr -d ' ')" 2

mismatch_sha=cccccccccccccccccccccccccccccccccccccccc
write_live "$mismatch_sha"
bash "$SCRIPT_DIR/run-explore.sh" dispatch >/dev/null
export DRIVER_MODE=mismatched
bash "$SCRIPT_DIR/run-explore.sh" run "$mismatch_sha" >/dev/null
check 'different failure signatures are not filed' "$(wc -l < "$UPSERT_LOG" | tr -d ' ')" 2
contains "$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log" 'explore: unconfirmed release=cccccccccccc feature=search' 'unconfirmed finding was not logged'

slow_sha=dddddddddddddddddddddddddddddddddddddddd
write_config 20 100 30
write_live "$slow_sha"
bash "$SCRIPT_DIR/run-explore.sh" dispatch >/dev/null
export ZF_CDP_BROWSER_LEASE_SCRIPT="$REPO_DIR/browser-lease.sh"
export LEASE_DELAY=25
lease_calls_before_wall="$(wc -l < "$LEASE_CALLS" | tr -d ' ')"
bash "$SCRIPT_DIR/run-explore.sh" run "$slow_sha" >/dev/null
check 'wall-limited wait runs through the browser lease' "$(wc -l < "$LEASE_CALLS" | tr -d ' ')" "$((lease_calls_before_wall + 2))"
contains "$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log" 'release=dddddddddddd features=0/1 findings=0 filed=0 tokens=0 wall=' 'wall budget summary was not logged'
contains "$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log" 'stop=budget-time' 'wall budget did not stop the run'

call_timeout_sha=abababababababababababababababababababab
write_config 3600 100 1
write_live "$call_timeout_sha"
bash "$SCRIPT_DIR/run-explore.sh" dispatch >/dev/null
export LEASE_DELAY=3
bash "$SCRIPT_DIR/run-explore.sh" run "$call_timeout_sha" >/dev/null
contains "$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log" 'explore: driver error release=abababababab feature=search attempt=1' 'per-call lease timeout did not use the driver error path'
check 'per-call lease timeout keeps the existing run status' "$(jq -r .stop "$AGENT_HOME/state/explore/$call_timeout_sha/state.json")" done
unset ZF_CDP_BROWSER_LEASE_SCRIPT LEASE_DELAY

token_sha=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
write_config 3600 4
write_live "$token_sha"
bash "$SCRIPT_DIR/run-explore.sh" dispatch >/dev/null
DRIVER_SESSION_ID=11111111-2222-3333-4444-555555555555
export DRIVER_SESSION_ID
mkdir -p "$CODEX_HOME/sessions/2026/10/20"
jq -cn '{type:"event_msg",payload:{type:"token_count",info:{total_token_usage:{input_tokens:3,cached_input_tokens:0,output_tokens:2,total_tokens:5}}}}' \
  > "$CODEX_HOME/sessions/2026/10/20/rollout-$DRIVER_SESSION_ID.jsonl"
prior_calls="$(wc -l < "$DRIVER_CALLS" | tr -d ' ')"
export DRIVER_MODE=tokens
bash "$SCRIPT_DIR/run-explore.sh" run "$token_sha" >/dev/null
check 'token budget stops before a second reproduction session' "$(wc -l < "$DRIVER_CALLS" | tr -d ' ')" "$((prior_calls + 1))"
check 'token budget does not file an unconfirmed defect' "$(wc -l < "$UPSERT_LOG" | tr -d ' ')" 2
contains "$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log" 'release=eeeeeeeeeeee features=1/1 findings=0 filed=0 tokens=5 wall=' 'token usage was not measured by usage_reader'
contains "$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log" 'stop=budget-tokens' 'token budget did not stop the run'

printf 'ok - release exploration contracts\n'
