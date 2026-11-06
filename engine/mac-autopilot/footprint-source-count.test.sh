#!/usr/bin/env bash
# Per-item scheduler paths must not `source lib.sh` (about 0.5s each), and the lib-free footprint
# helpers must return exactly what the lib-sourcing ones did. Part 1 is the parity check against
# verbatim copies of the old bodies; part 2 counts lib.sh loads across N candidates.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/test-env.sh"
engine_dir="$(cd -- "$script_dir/.." && pwd -P)"
fail() { printf 'footprint-source-count.test.sh: %s\n' "$*" >&2; exit 1; }

fixture="$test_env_root/footprint-source-count"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts" "$AGENT_HOME/state"
export MAC_AUTOPILOT_ROOT="$fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
jq '.max_workers=8 | .implement_cap=8 | .hotfix_lane.supervisor_owned=false | .auto_merge=false
  | .issue_intake={enabled:true,max_upstream:100,max_ready:300,labels:[],product_labels:["ready-for-agent"],ready_buffer:100,refill_max:100}' \
  "$engine_dir/mac-autopilot/config.template.json" > "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"; UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
WORKERS="$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"; A="$MAC_AUTOPILOT_RUNTIME_DIR"
STAMP=source-count-test; NOW_EPOCH="$(date +%s)"; SCHED_LOCK_HELD=true; DRY_RUN=0
: > "$LOG"

# Tracked history with real directories and files, so footprint_classify sees both kinds.
git -C "$ROOT" init -q -b main
git -C "$ROOT" config user.name fixture; git -C "$ROOT" config user.email fixture@example.invalid
mkdir -p "$ROOT/packages/hot/src" "$ROOT/packages/cold/src" "$ROOT/migrations/meta"
for i in $(seq 1 24); do printf 'x\n' > "$ROOT/packages/hot/src/f$i.ts"; done
printf 'x\n' > "$ROOT/packages/cold/src/a.ts"; printf 'x\n' > "$ROOT/migrations/meta/_journal.json"
git -C "$ROOT" add . && git -C "$ROOT" commit -qm base
git -C "$ROOT" update-ref refs/remotes/origin/main HEAD

# Every lib.sh load goes through this wrapper, which is the only path the scheduler sees.
real_lib="$SCHEDULER_AGENT_LIB"
mkdir -p "$fixture/wrap"; : > "$fixture/lib-loads"
printf 'printf x >> "%s"\nsource "%s"\n' "$fixture/lib-loads" "$real_lib" > "$fixture/wrap/lib.sh"
SCHEDULER_AGENT_LIB="$fixture/wrap/lib.sh"
lib_loads() { wc -c < "$fixture/lib-loads" | tr -d ' '; }

# ---- Part 1: parity with the lib.sh-sourcing bodies these helpers had before. ----
legacy_active_footprint_conflict() (
  REPO_DIR="$ROOT" MODEL_POLICY_SOURCE_CHECK_ONLY=1
  source "$SCHEDULER_AGENT_LIB" || exit 2
  local candidate other owner scope original rc
  original="$(footprint_strip_shared_append "${4:-$1}")"
  candidate="$(footprint_strip_shared_append "$1")"
  while IFS= read -r other; do
    owner="$(jq -r .id <<<"$other")"
    [[ "$owner" != "$3" ]] || continue
    scope="$(footprint_strip_shared_append "$(jq -c '.footprint // []' <<<"$other")")"
    if footprint_scopes_collide "$candidate" "$scope" "$original"; then
      printf '%s\n' "$owner"; return 0
    else
      rc=$?; (( rc == 1 )) || return "$rc"
    fi
  done < <(jq -c '.[]' <<<"$2")
)
legacy_footprint_match_detail() (
  REPO_DIR="$ROOT" MODEL_POLICY_SOURCE_CHECK_ONLY=1
  source "$SCHEDULER_AGENT_LIB" || exit 2
  local candidate owner origin count original
  original="$(footprint_strip_shared_append "$2")"
  candidate="$(footprint_strip_shared_append "$1")"
  owner="$(footprint_strip_shared_append "$3")"
  if footprint_scopes_collide "$candidate" "$owner" "$original"; then
    candidate="$EXPECTED_SCOPE_COLLISION_CANDIDATE"
    origin=expansion
    if jq -e --arg p "$candidate" 'index($p) != null' <<<"$2" >/dev/null; then origin=original; fi
    if [[ "$origin" == original ]]; then count=not-applicable; else count="$(jq -r --arg p "$candidate" '.[$p] // 0' <<<"$4")"; fi
    printf 'candidate_path=%s owner_path=%s source=%s cochange_count=%s' "$candidate" "$EXPECTED_SCOPE_COLLISION_ACTIVE" "$origin" "$count"
  fi
)
legacy_scheduler_footprint() (
  local u="$1" state issue actual scope preserve_missing=false
  if [[ "$(jq -r '.footprint_source // empty' <<<"$u")" == pr-diff ]] \
    && jq -e '(.footprint | type) == "array"' <<<"$u" >/dev/null; then
    scope="$(jq -c '.footprint' <<<"$u")"; preserve_missing=true
  else
    actual="$(jq -r '[.history[]? | select(.stage=="write-end") | .result] | last // empty' <<<"$u")"
    if jq -e 'type == "array"' <<<"$actual" >/dev/null 2>&1; then
      scope="$(jq -c . <<<"$actual")"; preserve_missing=true
    elif jq -e 'has("footprint")' <<<"$u" >/dev/null; then
      scope="$(jq -c '.footprint' <<<"$u")"
    else
      REPO_DIR="$ROOT" MODEL_POLICY_SOURCE_CHECK_ONLY=1
      source "$SCHEDULER_AGENT_LIB" || return 1
      issue="$(jq -r '.issue // empty' <<<"$u")"
      state="$(cat "$STATE_DIR/$issue.json" 2>/dev/null)"; [[ -n "$state" ]] || state='{}'
      if jq -e '(.footprint // []) | length > 0' <<<"$u" >/dev/null; then
        scope="$(jq -c '.footprint' <<<"$u")"
      elif jq -e '([.expected_paths[]?, .expected_packages[]?] | length) > 0' <<<"$state" >/dev/null; then
        scope="$(selection_scope_json <<<"$state")"
      else
        scope="$(issue_change_surface_json "$u" "$(jq -r '.task // ""' <<<"$u")" '[]')"
      fi
    fi
  fi
  scheduler_footprint_filter_main "$scope" "$preserve_missing"
)
legacy_parent_reason() (
  local preserved_gh=""
  declare -F gh >/dev/null 2>&1 && preserved_gh="$(declare -f gh | sed '1s/^gh ()/scheduler_gh ()/')"
  REPO_DIR="$ROOT" MODEL_POLICY_SOURCE_CHECK_ONLY=1
  source "$SCHEDULER_AGENT_LIB" || return 2
  if [[ -n "$preserved_gh" ]]; then
    eval "$preserved_gh"
    TICK_INTAKE_GH_INVOKE=scheduler_gh
    gh() { intake_gh_read "$@"; }
  fi
  issue_intake_parent_reason "$@"
)

legacy_scheduler_issue_state() (
  local f lock_fd
  REPO_DIR="$ROOT"
  source "$SCHEDULER_AGENT_LIB" || return 1
  f="$(state_file "$1")" || return 1
  mkdir -p "$STATE_DIR" || return 1
  exec {lock_fd}>"$f.lock" || return 1
  flock -sn "$lock_fd" || return 1
  state_read "$1"
)

# same_result <label> <old fn> <new fn> args... : identical stdout and exit status.
same_result() {
  local label="$1" old="$2" new="$3" old_out new_out old_rc=0 new_rc=0
  shift 3
  old_out="$("$old" "$@" 2>/dev/null)" || old_rc=$?
  new_out="$("$new" "$@" 2>/dev/null)" || new_rc=$?
  [[ "$old_rc" == "$new_rc" && "$old_out" == "$new_out" ]] \
    || fail "$label differs: old rc=$old_rc out=[$old_out] new rc=$new_rc out=[$new_out]"
  parity_cases=$((parity_cases + 1))
}
parity_cases=0
declare -A loads_by_n=()

owners='[{"id":"o-dir","footprint":["packages/hot"]},{"id":"o-file","footprint":["packages/hot/src/f2.ts","packages/cold/src/a.ts"]},
  {"id":"o-journal","footprint":["migrations/meta/_journal.json"]},{"id":"o-none","footprint":[]},{"id":"o-new","footprint":["packages/new/x.ts"]}]'
for mode in 0 1; do
  for shared in '[]' '["packages/hot/src/f3.ts"]'; do
    SHARED_APPEND="$shared"; export ZF_FOOTPRINT_DIRECTORY_PREFIX_MATCHING="$mode"
    for cand in '["packages/hot/src/f1.ts"]' '["packages/hot/src/f2.ts"]' '["packages/hot/src/f3.ts"]' '["packages/cold"]' \
      '["packages/cold/src/a.ts"]' '["migrations/meta/_journal.json"]' '["packages/new/y.ts"]' '["packages/new"]' '["docs/x.md"]' '[]'; do
      for orig in "$cand" '["packages/hot/src/f9.ts"]'; do
        same_result "conflict mode=$mode shared=$shared cand=$cand orig=$orig" legacy_active_footprint_conflict active_footprint_conflict "$cand" "$owners" self "$orig"
      done
      same_result "conflict self-owner mode=$mode cand=$cand" legacy_active_footprint_conflict active_footprint_conflict "$cand" "$owners" o-dir
      same_result "match mode=$mode shared=$shared cand=$cand" legacy_footprint_match_detail footprint_match_detail \
        "$cand" '["packages/hot/src/f1.ts"]' '["packages/hot","packages/cold/src/a.ts"]' '{"packages/hot/src/f1.ts":4}'
    done
  done
done
# The batch loop (dispatch_pending's refill) stays the same function over the fixed per-item helper.
SHARED_APPEND='[]'; export ZF_FOOTPRINT_DIRECTORY_PREFIX_MATCHING=0
rows=$'c1\t["packages/hot/src/f1.ts"]\t["packages/hot/src/f1.ts"]\nc2\t["docs/x.md"]\t["docs/x.md"]\nc3\t["packages/cold/src/a.ts"]\t["packages/cold/src/a.ts"]\n'
new_batch="$(active_footprint_conflicts_batch "$owners" "$rows")"
[[ "$new_batch" == $'c1\to-dir\nc3\to-file' ]] || fail "batch verdicts changed: [$new_batch]"

printf '%s\n' '{"expected_paths":["packages/cold/src/a.ts"]}' > "$AGENT_HOME/state/9101.json"
printf '%s\n' '{"expected_packages":["packages/hot/src/"]}' > "$AGENT_HOME/state/9102.json"
printf '%s\n' '{"expected_paths":[]}' > "$AGENT_HOME/state/9103.json"
body=$'## Key files and symbols\n- packages/hot/src/f4.ts\n- packages/gone/missing.ts\nAffected files: packages/cold/src/a.ts'
for unit in \
  '{"id":"u1","issue":9100,"task":"no paths here"}' \
  "$(jq -cn --arg t "$body" '{id:"u2",issue:9100,task:$t}')" \
  '{"id":"u3","issue":9101,"task":"x"}' '{"id":"u4","issue":9102,"task":"x"}' '{"id":"u5","issue":9103,"task":"Fix files: packages/hot/src/f5.ts"}' \
  '{"id":"u6","issue":9100,"footprint":["packages/hot/src/f6.ts","packages/gone/y.ts"]}' \
  '{"id":"u7","issue":9100,"footprint":["packages/gone/y.ts"],"footprint_source":"pr-diff"}' \
  '{"id":"u8","issue":9100,"footprint":[],"task":"Affected files: packages/hot/src/f7.ts"}' \
  '{"id":"u9","issue":9100,"history":[{"stage":"write-end","result":["packages/hot/src/f8.ts","packages/gone/z.ts"]}]}' \
  '{"id":"u10","task":"Affected files: packages/hot/src/f9.ts"}'; do
  same_result "scheduler_footprint $unit" legacy_scheduler_footprint scheduler_footprint "$unit"
done

# scheduler_issue_state: existing state, default for a missing one, and refusal while a transition holds the lock.
printf '%s\n' '{"state":"on-hold","attempts":2}' > "$AGENT_HOME/state/9111.json"
for issue in 9111 9112; do same_result "scheduler_issue_state $issue" legacy_scheduler_issue_state scheduler_issue_state "$issue"; done
( exec 8>"$AGENT_HOME/state/9111.json.lock"; flock -x 8
  same_result 'scheduler_issue_state while locked' legacy_scheduler_issue_state scheduler_issue_state 9111 )
[[ "$(scheduler_issue_state 9111)" == '{"state":"on-hold","attempts":2}' ]] || fail 'scheduler_issue_state did not return the stored state'

# parent reason: same verdicts, same gh arguments (REPO) from the same working directory.
parent_log="$fixture/parent-gh.log"
gh() { printf '%s|%s\n' "$PWD" "$*" >> "$parent_log"; case "$*" in
  'issue view 71 '*) echo OPEN ;; 'issue view 72 '*) echo CLOSED ;; 'api repos/'*/issues/55/sub_issues*) echo '[{"number":1}]' ;;
  'api repos/'*/sub_issues*) echo '[]' ;; *) return 1 ;; esac; }
parent_case() { # issue json
  : > "$parent_log"; local old_rc=0 new_rc=0 old_out new_out old_gh new_gh
  old_out="$(legacy_parent_reason 55 "$1" 2>/dev/null)" || old_rc=$?; old_gh="$(cat "$parent_log")"; : > "$parent_log"
  new_out="$(scheduler_issue_intake_parent_reason 55 "$1" 2>/dev/null)" || new_rc=$?; new_gh="$(cat "$parent_log")"
  [[ "$old_rc" == "$new_rc" && "$old_out" == "$new_out" && "$old_gh" == "$new_gh" ]] \
    || fail "parent reason differs for $1: old rc=$old_rc [$old_out] gh [$old_gh]; new rc=$new_rc [$new_out] gh [$new_gh]"
  parity_cases=$((parity_cases + 1))
}
for json in '{"title":"Add a spec","body":"","subIssuesSummary":{"total":0}}' '{"title":"t","body":"b","subIssuesSummary":{"total":2}}' \
  '{"title":"t","body":"b","subIssuesSummary":{"total":0}}' '{"title":"t","body":"- [ ] child #71","subIssuesSummary":{"total":0}}' \
  '{"title":"t","body":"- [x] child #72","subIssuesSummary":{"total":0}}' '{"title":"t","body":"- [ ] child #73"}' '{"title":"t","body":"b"}'; do
  scheduler_lib_context
  parent_case "$json"
done
unset -f gh

# ---- Part 2: lib.sh loads must not scale with the number of candidates. ----
before="$(lib_loads)"
units_json='[]'; for i in $(seq 1 12); do units_json="$(jq -c --argjson i "$i" '. + [{id:("n-"+($i|tostring)),issue:(9200+$i),task:"Affected files: packages/hot/src/f\($i).ts"}]' <<<"$units_json")"; done
for n in 4 12; do
  for ((i = 1; i <= n; i++)); do scheduler_issue_state 9111 >/dev/null; done
  scopes=''; : > "$fixture/scopes"
  for ((i = 1; i <= n; i++)); do
    u="$(jq -c ".[$((i - 1))]" <<<"$units_json")"
    printf '%s\t%s\t%s\n' "n-$i" "$(scheduler_footprint "$u")" "$(scheduler_footprint "$u")" >> "$fixture/scopes"
  done
  [[ "$(active_footprint_conflicts_batch "$owners" "$(cat "$fixture/scopes")" | wc -l | tr -d ' ')" == "$n" ]] || fail "batch missed conflicts for $n candidates"
  for ((i = 1; i <= n; i++)); do footprint_match_detail '["packages/hot/src/f1.ts"]' '["packages/hot/src/f1.ts"]' '["packages/hot"]' '{}' >/dev/null; done
  loads_by_n[$n]=$(( $(lib_loads) - before )); before="$(lib_loads)"
done
(( loads_by_n[4] == 0 && loads_by_n[12] == 0 )) \
  || fail "footprint helpers sourced lib.sh per item: ${loads_by_n[4]} loads for 4 candidates, ${loads_by_n[12]} for 12"

# End to end: refill intake over N cached candidates that all overlap one running owner.
intake_footprint_snapshot() { printf '[{"id":"issue-9001","stage":"implement-pending","footprint":["packages/hot"]}]\n'; }
live_workers() { printf '0\n'; }
gh() { [[ "$1 $2" == 'pr list' ]] && { echo '[]'; return 0; }; return 97; }
register() { # n -> lib loads and wall seconds for one refill intake over n candidates
  local rows='' i start loads_before
  for ((i = 1; i <= $1; i++)); do
    rows+="$(printf '%s\tpr\tcandidate %s\t["ready-for-agent"]\t%s' "$((9300 + i))" "$i" \
      "$(jq -cn --argjson n "$((9300 + i))" --arg b "Affected files: packages/hot/src/f$i.ts" \
        '{number:$n,title:"candidate",body:$b,state:"OPEN",labels:[{name:"ready-for-agent"}],subIssuesSummary:{total:0,completed:0}}' | base64 -w0)")"$'\n'
  done
  jq -cn --argjson at "$(date +%s)" --arg rows "${rows%$'\n'}" '{schema:3,created_at:$at,rows:$rows}' > "$A/intake-candidates.json"
  printf '{"units":[]}\n' > "$UNITS"; : > "$LOG"; SCHEDULER_LIB_CONTEXT_FOR=''
  loads_before="$(lib_loads)"; start=$SECONDS
  register_new_issues 0 true
  REGISTER_SECS=$((SECONDS - start)); REGISTER_LOADS=$(( $(lib_loads) - loads_before ))
  REGISTER_SKIPS="$(grep -c 'intake skip issue .*footprint overlaps' "$LOG" || true)"
}
register 3;  loads_3=$REGISTER_LOADS; skips_3=$REGISTER_SKIPS
register 20; loads_20=$REGISTER_LOADS; skips_20=$REGISTER_SKIPS; secs_20=$REGISTER_SECS
[[ "$skips_3" == 3 && "$skips_20" == 20 ]] || fail "fixture candidates did not all overlap (3 -> $skips_3, 20 -> $skips_20)"
(( loads_20 == loads_3 && loads_20 <= 1 )) \
  || fail "register_new_issues sourced lib.sh per candidate: $loads_3 loads for 3 candidates, $loads_20 for 20"

printf 'ok - %s parity cases; lib.sh loads: footprint helpers 0 for 4 or 12 candidates, refill intake %s for 3 and %s for 20 candidates (%ss)\n' \
  "$parity_cases" "$loads_3" "$loads_20" "$secs_20"
