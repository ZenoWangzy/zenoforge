#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "$0")" && pwd -P)/test-env.sh"
trap 'rm -rf "$test_env_root"' EXIT

repo_root="$MAC_AUTOPILOT_ENV_ROOT"
HERE="$repo_root/engine/mac-autopilot"
ROOT="$test_env_root/product"
SUP="$test_env_root/sup"
mkdir -p "$ROOT" "$SUP"
source "$HERE/scheduler.d/self-check.sh"
source "$HERE/scheduler.d/review-rules.sh"

jqf() { command jq "$@"; }
test_evidence_has_pass() { return 1; }
test_evidence_record_pass() { :; }
fail() { printf 'self-check-main-sync.test.sh: %s\n' "$*" >&2; exit 1; }

export ZF_SELF_CHECK_LOCAL=1 SELF_CHECK_STEP_TIMEOUT=10
export PNPM_LOG="$test_env_root/pnpm.log" ROUTE_LOG="$test_env_root/conflict-route.log"
cat > "$test_env_bin/pnpm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PNPM_LOG"
EOF
chmod +x "$test_env_bin/pnpm"

make_repo() {
  local name="$1" conflict="$2" dir origin
  dir="$test_env_root/$name"
  origin="$test_env_root/$name-origin.git"
  mkdir -p "$dir/scripts/ci" "$dir/scripts/checks" "$dir/packages/fruit/src"
  git init -q -b main "$dir"
  git -C "$dir" config user.name fixture
  git -C "$dir" config user.email fixture@example.invalid
  cat > "$dir/scripts/ci/touched-package-selection.mjs" <<'EOF'
console.log(JSON.stringify({rootNames:["fruit"],affectedNames:["fruit"],affectedPaths:["packages/fruit"]}));
EOF
  printf 'export {};\n' > "$dir/scripts/checks/authenticated-origin-contract-packages.mjs"
  cat > "$dir/packages/fruit/package.json" <<'EOF'
{"name":"fruit","scripts":{"build":"true","test":"true","lint":"true"}}
EOF
  printf 'base\n' > "$dir/packages/fruit/src/shared.js"
  git -C "$dir" add .
  git -C "$dir" commit -qm base
  git init --bare -q "$origin"
  git -C "$dir" remote add origin "$origin"
  git -C "$dir" push -q origin main

  git -C "$dir" checkout -q -b "agent/$name"
  printf 'unit\n' > "$dir/packages/fruit/src/unit.js"
  if [[ "$conflict" == true ]]; then
    printf 'unit\n' > "$dir/packages/fruit/src/shared.js"
  fi
  git -C "$dir" add .
  git -C "$dir" commit -qm unit
  git -C "$dir" push -q origin "agent/$name"
  local unit_head
  unit_head="$(git -C "$dir" rev-parse HEAD)"

  git -C "$dir" checkout -q main
  if [[ "$conflict" == true ]]; then
    printf 'main\n' > "$dir/packages/fruit/src/shared.js"
  else
    printf 'main\n' > "$dir/packages/fruit/src/main.js"
  fi
  git -C "$dir" add .
  git -C "$dir" commit -qm main-update
  git -C "$dir" push -q origin main
  git -C "$dir" update-ref refs/remotes/origin/main main
  git -C "$dir" checkout -q "agent/$name"
  printf '%s\n' "$dir" "$origin" "$unit_head" "$(git -C "$dir" rev-parse origin/main)"
}

mapfile -t clean_repo < <(make_repo clean false)
clean="${clean_repo[0]}"
clean_origin="${clean_repo[1]}"
clean_head="${clean_repo[2]}"
clean_main="${clean_repo[3]}"
ROOT="$clean"
clean_output=""
clean_rc=0
if clean_output="$(self_check_run "$clean" "$clean_head" pr main clean-unit agent/clean 101 "$(jqf -cn '{task:"No criteria"}')" 2>&1)"; then :; else clean_rc=$?; fi
[[ "$clean_rc" == 0 ]] || { printf '%s\n' "$clean_output" >&2; fail "clean merge self-check returned $clean_rc"; }
git -C "$clean" merge-base --is-ancestor "$clean_main" HEAD \
  || fail 'clean stale branch did not merge origin/main'
[[ "$(git --git-dir="$clean_origin" rev-parse refs/heads/agent/clean)" == "$(git -C "$clean" rev-parse HEAD)" ]] \
  || fail 'clean main merge was not pushed to the unit branch'
grep -Fq 'self-check main sync: merged clean' <<<"$clean_output" \
  || fail 'clean main merge outcome was not logged'
grep -Fq 'acceptance-criteria coverage: skipped' <<<"$clean_output" \
  || fail 'post-merge acceptance coverage was not checked'
grep -Fq 'run build' "$PNPM_LOG" || fail 'clean main merge did not continue to builds'

run_direct_main_sync() {
  local name="$1" remove_branch="$2" dir origin head main output rc=0 branch
  local -a fixture=()
  mapfile -t fixture < <(make_repo "$name" false)
  dir="${fixture[0]}"; origin="${fixture[1]}"; head="${fixture[2]}"; main="${fixture[3]}"; branch="agent/$name"
  git -C "$dir" checkout -q --detach "$head"
  [[ "$remove_branch" != true ]] || git -C "$dir" branch -D "$branch" >/dev/null
  ROOT="$dir"
  : > "$PNPM_LOG"
  if output="$(self_check_run "$dir" "$head" direct-main '' "$name-unit" "$branch" '' 2>&1)"; then :; else rc=$?; fi
  [[ "$rc" == 0 ]] || { printf '%s\n' "$output" >&2; fail "detached direct-main self-check returned $rc for $name"; }
  git -C "$dir" merge-base --is-ancestor "$main" HEAD || fail "detached direct-main worktree did not merge main for $name"
  [[ "$(git -C "$dir" symbolic-ref --quiet --short HEAD)" == "$branch" ]] || fail "detached direct-main worktree did not attach $branch"
  [[ "$(git -C "$dir" rev-parse "refs/heads/$branch")" == "$(git -C "$dir" rev-parse HEAD)" ]] || fail "direct-main branch did not advance for $name"
  [[ "$(git --git-dir="$origin" rev-parse "refs/heads/$branch")" == "$head" ]] || fail "direct-main self-check unexpectedly pushed $branch"
  grep -Fq 'self-check main sync: merged clean' <<<"$output" || fail "direct-main merge outcome was not logged for $name"
}

run_direct_main_sync direct-present false
run_direct_main_sync direct-absent true

mapfile -t moved_repo < <(make_repo moved false)
moved="${moved_repo[0]}"
moved_head="${moved_repo[2]}"
git -C "$moved" checkout -q --detach "$moved_head"
git -C "$moved" commit -q --allow-empty -m moved-candidate
actual_head="$(git -C "$moved" rev-parse HEAD)"
ROOT="$moved"
moved_output=""
moved_rc=0
if moved_output="$(self_check_run "$moved" "$moved_head" direct-main '' moved-unit agent/moved '' 2>&1)"; then :; else moved_rc=$?; fi
[[ "$moved_rc" == 125 ]] || { printf '%s\n' "$moved_output" >&2; fail "changed detached head was accepted (rc=$moved_rc)"; }
grep -Fq "self-check main sync: refused candidate head mismatch expected=$moved_head actual=$actual_head" <<<"$moved_output" \
  || fail 'rc 125 did not name the candidate head mismatch'
[[ "$(git -C "$moved" rev-parse HEAD)" == "$actual_head" ]] || fail 'refusing a changed head moved the worktree'

mapfile -t conflict_repo < <(make_repo conflict true)
conflict="${conflict_repo[0]}"
conflict_head="${conflict_repo[2]}"
conflict_main="${conflict_repo[3]}"
ROOT="$conflict"
: > "$PNPM_LOG"
: > "$ROUTE_LOG"
merge_conflict_to_repair() {
  printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$5" >> "$ROUTE_LOG"
}
conflict_output=""
conflict_rc=0
if conflict_output="$(self_check_run "$conflict" "$conflict_head" pr main conflict-unit agent/conflict 202 2>&1)"; then :; else conflict_rc=$?; fi
[[ "$conflict_rc" == 76 ]] || { printf '%s\n' "$conflict_output" >&2; fail "conflict did not stop self-check with route status 76 (rc=$conflict_rc)"; }
grep -Fq 'self-check main sync: conflict routed' <<<"$conflict_output" \
  || fail 'conflict route outcome was not logged'
grep -Fq "conflict-unit|202|self-check: conflicts with main before builds|$conflict_head" "$ROUTE_LOG" \
  || fail 'conflict was not handed to merge_conflict_to_repair'
[[ ! -s "$PNPM_LOG" ]] || fail 'conflicting branch ran a build or package command'
[[ "$(git -C "$conflict" rev-parse HEAD)" == "$conflict_head" ]] || fail 'conflict changed the unit branch head'
[[ -z "$(git -C "$conflict" ls-files -u)" ]] || fail 'conflict left unmerged paths in the unit worktree'
[[ "$(git -C "$conflict" rev-parse origin/main)" == "$conflict_main" ]] || fail 'conflict fixture main moved unexpectedly'

UNITS="$test_env_root/self-check-units.json"
STAMP=20261124T000000Z
SHA_RE='^[0-9a-f]{40}$'
say() { :; }
js() { command jq -Rn --arg v "$1" '$v'; }
unit_field() { jqf -r --arg id "$1" "([.units[] | select(.id==\$id) | ($2 // empty)][0] // empty)" "$UNITS"; }
set_unit() {
  jqf --arg id "$1" "(.units[] |= (if .id==\$id then ($2) else . end))" "$UNITS" > "$UNITS.tmp"
  mv "$UNITS.tmp" "$UNITS"
}
hist() {
  local entry
  entry="$(jqf -scR --arg stage "$1" --arg at "$STAMP" '{stage:$stage,result:.[0:-1],at:$at}' <<<"${2:-}")"
  printf '.history += [%s]' "$entry"
}
scheduler_lock_yield_between_units() { SCHEDULER_LOCK_YIELDED=false; }
retry_id=retry-unit
retry_sha="$clean_head"
old_sha=1111111111111111111111111111111111111111
retry_history="$(jqf -cn --arg id "$retry_id" --arg old "$old_sha" --arg sha "$retry_sha" '[{stage:"self-check-deferred",result:("self-check-"+$id+"-"+$old+"-0-old.log")},{stage:"self-check-deferred",result:("self-check-"+$id+"-"+$sha+"-0-old1.log"),defer_rc:125},{stage:"self-check-deferred",result:("self-check-"+$id+"-"+$sha+"-0-old2.log"),defer_rc:125}]')"
jqf -cn --arg id "$retry_id" --arg sha "$retry_sha" --argjson history "$retry_history" \
  '{units:[{id:$id,stage:"review-pending",self_check_pid:1,self_check_start:"test",self_check_output:"",self_check_sha:$sha,self_check_fixes:2,history:$history}]}' > "$UNITS"
defer_attempt() {
  local attempt="$1" rc="${2:-125}" out
  out="$SUP/self-check-$retry_id-$retry_sha-0-$STAMP-$attempt.log"
  if [[ "$rc" == 125 ]]; then printf 'self-check main sync: refused candidate head mismatch\n' > "$out"; else printf 'mypc admission: memory below minimum\n' > "$out"; fi
  printf 'defer\n' > "$out.result"
  printf '%s\n' "$rc" > "$out.result.rc"
  printf '%s\n' "$retry_sha" > "$out.head"
  jqf --arg out "$out" --arg sha "$retry_sha" --argjson pid "$attempt" \
    '(.units[0].self_check_pid=$pid | .units[0].self_check_start="test" | .units[0].self_check_output=$out | .units[0].self_check_sha=$sha | .units[0].self_check_status=null)' \
    "$UNITS" > "$UNITS.tmp"
  mv "$UNITS.tmp" "$UNITS"
}
defer_attempt 1 125
self_check_harvest
[[ "$(jqf -r '.units[0].history[-1].stage' "$UNITS")" == self-check-deferred ]] || fail 'third same-SHA rc125 defer escalated before the limit'
defer_attempt 2 125
self_check_harvest
jqf -e --arg sha "$retry_sha" '.units[0] as $u | $u.history[-1].stage == "self-check-red" and $u.history[-1].reason == ("self-check retry limit reached after 3 rc 125 deferrals for sha="+$sha) and $u.self_check_status == "red" and $u.stage == "repair-pending" and ($u.repair_hint | contains("retry limit reached"))' "$UNITS" >/dev/null \
  || fail 'fourth same-SHA rc125 defer did not become a reasoned red self-check routed to repair'
jqf -cn --arg id "$retry_id" --arg sha "$retry_sha" '{units:[{id:$id,stage:"review-pending",self_check_sha:$sha,self_check_fixes:2,history:[]}]}' > "$UNITS"
for attempt in 3 4 5 6; do
  defer_attempt "$attempt" 75
  self_check_harvest
done
jqf -e '.units[0] | .stage == "review-pending" and (.history | length == 4 and all(.[]; .stage == "self-check-deferred" and .defer_rc == 75)) and (.self_check_status == null)' "$UNITS" >/dev/null \
  || fail 'repeated rc75 admission defers escalated or were counted as rc125 failures'

# A stored red verdict for the same head is reused even when the head is behind main; other verdicts still restart.
TAG=20261121T000000Z
unit_writes="$test_env_root/unit-writes"
set_unit() { printf '%s\n' "$2" >> "$unit_writes"; }
pid_start() { echo 1; }
decision_log_gate_reason() { :; }
how_why_gate_reason() { :; }
incident_report_gate_reason() { :; }
self_check_run() { echo stub; }
reuse_unit() { # status unit-sha
  command jq -cn --arg s "$1" --arg sha "$2" '{id:"reuse-unit",lane:"",self_check_sha:$sha,self_check_status:$s,self_check_lane:"",self_check_base:"",self_check_fixes:0}'
}
ROOT="$clean"
before="$(ls "$SUP" | wc -l)"
: > "$unit_writes"
rc=0; self_check_before_review reuse-unit "$clean_head" "$clean" "$(reuse_unit red "$clean_head")" || rc=$?
[[ "$rc" == 1 ]] || fail "stored red for the same sha did not stop review dispatch (rc=$rc)"
grep -Fq 'repair-pending' "$unit_writes" || fail 'stored red for the same sha was not routed to repair'
[[ "$(ls "$SUP" | wc -l)" == "$before" ]] || fail 'reused red started a new self-check log'
rc=0; self_check_before_review reuse-unit "$clean_head" "$clean" "$(reuse_unit pass "$clean_head")" || rc=$?
wait
[[ "$rc" == 1 ]] || fail "stale head with stored pass was reused instead of re-checked (rc=$rc)"
grep -Fq 'self_check_pid' "$unit_writes" || fail 'stored pass did not start a new self-check'
: > "$unit_writes"
rc=0; self_check_before_review reuse-unit "$clean_head" "$clean" "$(reuse_unit red "$clean_main")" || rc=$?
wait
[[ "$rc" == 1 ]] || fail "stored red for another sha was reused (rc=$rc)"
grep -Fq 'self_check_pid' "$unit_writes" || fail 'red for another sha did not start a new self-check'

echo 'self-check-main-sync.test.sh: PASS'
