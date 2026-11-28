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
write_exploration_config() {
  local wall="$1" tokens="$2" max_features="$3" features="$4" timeout="${5:-5}"
  mkdir -p "$ZF_CONFIG_ROOT/state"
  jq -cn --arg driver "$REPO_DIR/driver.sh" --argjson wall "$wall" --argjson tokens "$tokens" --argjson max "$max_features" --argjson timeout "$timeout" \
    '{enabled:true,driver:{argv:[$driver],timeout_s:$timeout,evidence_dir:"run-evidence"},feature_map:"state/feature-map.json",budget:{wall_seconds:$wall,max_tokens:$tokens,max_features:$max},max_filed_per_run:3,allowed_effects:["read"]}' \
    > "$ZF_CONFIG_ROOT/state/exploration.json"
  printf '%s\n' "$features" | jq -c '{version:1,features:.}' \
    > "$ZF_CONFIG_ROOT/state/feature-map.json"
}
write_config() {
  local wall="$1" tokens="$2" timeout="${3:-30}"
  local features='[{"id":"search","title":"Search","path_prefixes":[],"entrypoints":[],"surfaces":[],"invariants":[],"proofs":{}}]'
  write_exploration_config "$wall" "$tokens" 1 "$features" "$timeout"
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

write_rotation_config() {
  local max_features="$1" features="$2"
  write_exploration_config 20 100 "$max_features" "$features"
}
write_rotation_history() {
  python3 - "$AGENT_HOME/state/explore" <<'PY'
import json
import os
import sys
import time

root = sys.argv[1]
base = time.time()
history = [
    ("1111111111111111111111111111111111111111", "done", "feature-a", 1, 500),
    ("1111111111111111111111111111111111111111", "done", "feature-b", 1, 400),
    ("2222222222222222222222222222222222222222", "started", "feature-c", 1, 1),
    ("2222222222222222222222222222222222222222", "started", "feature-d", 1, 2),
    ("3333333333333333333333333333333333333333", "done", "recent-a", 1, 900),
    ("3333333333333333333333333333333333333333", "done", "recent-a", 2, 100),
    ("3333333333333333333333333333333333333333", "done", "recent-b", 1, 200),
    ("3333333333333333333333333333333333333333", "done", "recent-c", 1, 300),
    ("3333333333333333333333333333333333333333", "done", "recent-d", 1, 400),
    ("4444444444444444444444444444444444444444", "done", "tie-a", 1, 100),
    ("4444444444444444444444444444444444444444", "done", "tie-b", 1, 100),
    ("4444444444444444444444444444444444444444", "done", "tie-c", 1, 100),
    ("4444444444444444444444444444444444444444", "done", "tie-d", 1, 100),
    ("5555555555555555555555555555555555555555", "done", "map-second", 1, 10),
    ("5555555555555555555555555555555555555555", "done", "map-first", 1, 1000),
]
states = {}
for sha, state, feature, attempt, age in history:
    states[sha] = state
    results = os.path.join(root, sha, "results")
    os.makedirs(results, exist_ok=True)
    result = os.path.join(results, f"{feature}-attempt-{attempt}.json")
    with open(result, "w", encoding="utf-8") as file:
        file.write("{}\n")
    timestamp = base - age
    os.utime(result, (timestamp, timestamp))
for sha, state in states.items():
    run = os.path.join(root, sha)
    with open(os.path.join(run, "state.json"), "w", encoding="utf-8") as file:
        json.dump({"state": state}, file)
PY
}
run_rotation_case() {
  local sha="$1" max_features="$2" features="$3" name="$4" expected="$5" before actual
  write_rotation_config "$max_features" "$features"
  write_live "$sha"
  bash "$SCRIPT_DIR/run-explore.sh" dispatch >/dev/null
  before=0
  if [[ -f "$DRIVER_CALLS" ]]; then before="$(wc -l < "$DRIVER_CALLS" | tr -d ' ')"; fi
  export DRIVER_MODE=pass
  bash "$SCRIPT_DIR/run-explore.sh" run "$sha" >/dev/null
  actual="$(python3 - "$DRIVER_CALLS" "$before" <<'PY'
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    features = [line.partition(":")[0] for index, line in enumerate(file) if index >= int(sys.argv[2])]
print(",".join(features))
PY
  )"
  check "$name" "$actual" "$expected"
}
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
write_rotation_history
run_rotation_case ffffffffffffffffffffffffffffffffffffffff 2 \
  '[{"id":"feature-a","title":"A"},{"id":"feature-b","title":"B"},{"id":"feature-c","title":"C"},{"id":"feature-d","title":"D"}]' \
  'unexplored features precede results and started runs are ignored' 'feature-c,feature-d'
run_rotation_case 0123456789abcdef0123456789abcdef01234567 2 \
  '[{"id":"fresh-a","title":"A"},{"id":"fresh-b","title":"B"},{"id":"fresh-c","title":"C"},{"id":"fresh-d","title":"D"}]' \
  'features without earlier results keep map order' 'fresh-a,fresh-b'
run_rotation_case 6666666666666666666666666666666666666666 2 \
  '[{"id":"recent-a","title":"A"},{"id":"recent-b","title":"B"},{"id":"recent-c","title":"C"},{"id":"recent-d","title":"D"}]' \
  'newest attempt determines the last-explored time' 'recent-d,recent-c'
run_rotation_case 7777777777777777777777777777777777777777 2 \
  '[{"id":"tie-a","title":"A"},{"id":"tie-b","title":"B"},{"id":"tie-c","title":"C"},{"id":"tie-d","title":"D"}]' \
  'equal result times keep map order' 'tie-a,tie-b'
run_rotation_case 8888888888888888888888888888888888888888 5 \
  '[{"id":"map-second","title":"Second"},{"id":"map-first","title":"First"}]' \
  'a map that fits the limit keeps map order' 'map-second,map-first'
: > "$SYSTEMD_RUN_LOG"
: > "$DRIVER_CALLS"

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

write_run_state() {
  local sha="$1" state="$2" age_days="$3" run_dir="$AGENT_HOME/state/explore/$1"
  mkdir -p "$run_dir"
  jq -cn --arg state "$state" '{state:$state}' > "$run_dir/state.json"
  python3 - "$run_dir/state.json" "$age_days" <<'PY'
import os
import sys
import time

path, age_days = sys.argv[1], int(sys.argv[2])
mtime = time.time() - age_days * 86400
os.utime(path, (mtime, mtime))
PY
}

done_old_sha=1111111111111111111111111111111111111111
skipped_old_sha=2222222222222222222222222222222222222222
killed_old_sha=3333333333333333333333333333333333333333
needs_filing_old_sha=4444444444444444444444444444444444444444
started_old_sha=5555555555555555555555555555555555555555
done_young_sha=6666666666666666666666666666666666666666
done_missing_evidence_sha=7777777777777777777777777777777777777777
invalid_sha=not-a-valid-release
write_run_state "$done_old_sha" done 20
write_run_state "$skipped_old_sha" skipped 20
write_run_state "$killed_old_sha" killed 20
write_run_state "$needs_filing_old_sha" needs-filing 20
write_run_state "$started_old_sha" started 20
write_run_state "$done_young_sha" done 1
write_run_state "$done_missing_evidence_sha" done 20
write_run_state "$invalid_sha" done 20
mkdir -p "$REPO_DIR/run-evidence/explore-$done_old_sha" "$REPO_DIR/run-evidence/explore-$skipped_old_sha" \
  "$REPO_DIR/run-evidence/explore-$killed_old_sha" "$REPO_DIR/run-evidence/explore-$needs_filing_old_sha" \
  "$REPO_DIR/run-evidence/explore-$started_old_sha" "$REPO_DIR/run-evidence/explore-$done_young_sha" \
  "$REPO_DIR/run-evidence/explore-$invalid_sha"
touch "$AGENT_HOME/state/explore/$done_old_sha.lock" "$AGENT_HOME/state/explore/$skipped_old_sha.lock" \
  "$AGENT_HOME/state/explore/$killed_old_sha.lock"
if ! bash "$SCRIPT_DIR/run-explore.sh" dispatch >/dev/null; then fail 'dispatch failed while reclaiming an old run without evidence'; fi
[[ ! -e "$AGENT_HOME/state/explore/$done_old_sha" ]] || fail 'old done run was not reclaimed'
[[ ! -e "$AGENT_HOME/state/explore/$skipped_old_sha" ]] || fail 'old skipped run was not reclaimed'
[[ ! -e "$AGENT_HOME/state/explore/$killed_old_sha" ]] || fail 'old killed run was not reclaimed'
[[ ! -e "$AGENT_HOME/state/explore/$done_missing_evidence_sha" ]] || fail 'old done run without evidence was not reclaimed'
[[ ! -e "$AGENT_HOME/state/explore/$done_old_sha.lock" ]] || fail 'reclaimed run lock was not removed'
[[ ! -e "$REPO_DIR/run-evidence/explore-$done_old_sha" ]] || fail 'old run evidence was not reclaimed'
[[ ! -e "$REPO_DIR/run-evidence/explore-$skipped_old_sha" ]] || fail 'old skipped run evidence was not reclaimed'
[[ ! -e "$REPO_DIR/run-evidence/explore-$killed_old_sha" ]] || fail 'old killed run evidence was not reclaimed'
[[ -e "$AGENT_HOME/state/explore/$needs_filing_old_sha/state.json" ]] || fail 'old needs-filing run was reclaimed'
[[ -e "$AGENT_HOME/state/explore/$started_old_sha/state.json" ]] || fail 'old started run was reclaimed'
[[ -e "$AGENT_HOME/state/explore/$done_young_sha/state.json" ]] || fail 'young done run was reclaimed'
[[ -e "$AGENT_HOME/state/explore/$invalid_sha/state.json" ]] || fail 'run with an invalid release SHA was reclaimed'
check 'one reclaim log reports the four removed terminal runs' "$(grep -Fc 'explore: reclaimed runs=4' "$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log")" 1

export ZF_EXPLORE_RETAIN_DAYS=invalid
if ! bash "$SCRIPT_DIR/run-explore.sh" dispatch >/dev/null 2>&1; then fail 'dispatch propagated a reclaim failure'; fi

printf 'ok - release exploration contracts\n'
