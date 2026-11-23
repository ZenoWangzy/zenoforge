#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
test_root="$test_env_root/intake-priority-fallback"
trap 'rm -rf -- "$test_env_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/config"
export ZF_CONFIG_ROOT="$test_root/config"
export ZF_REPO_DIR="$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel)"
export ZF_ROADMAP_TREE_CACHE_FILE="$test_root/roadmap.json"
export FALLBACK_JUDGE_MODE="$test_root/judge-mode"
export FALLBACK_GH_WRITES="$test_root/gh-writes.log"
export FALLBACK_CLAUDE_LOG="$test_root/claude.log"
export FALLBACK_CLAUDE_ARGS="$test_root/claude-args.log"
export FALLBACK_ISSUES="$test_root/issues.json"
export FALLBACK_CLAUDE_REPLY="$test_root/claude-reply.txt"
export FALLBACK_JUDGE_LOG="$test_root/judge.log"
export CLAUDE_QUOTA_SNAPSHOT_FILE="$test_root/no-quota.json"
unset TYPESAFE_API_KEY TYPESAFE_ENV_FILE
export AGENT_HOME="$test_root/agent"
mkdir -p "$AGENT_HOME"

jq -n '{intake_priority:{enabled:true}}' > "$ZF_CONFIG_ROOT/night.json"
printf '[]\n' > "$ZF_ROADMAP_TREE_CACHE_FILE"
jq -n '{number:9101,title:"Totals are wrong",body:"Sums are off.",labels:[{name:"ready-for-agent"},{name:"bug"}],state:"OPEN"}' > "$test_root/issue.json"
jq -n '{number:9102,title:"Totals are wrong again",body:"Sums are off.",labels:[{name:"ready-for-agent"},{name:"bug"},{name:"judge:fallback"},{name:"priority:normal"}],state:"OPEN"}' > "$test_root/issue-marked.json"
jq -n '[
  {number:9201,title:"Labelled elsewhere",body:"",labels:[{name:"ready-for-agent"},{name:"priority:normal"}],state:"OPEN"},
  {number:9202,title:"Labelled by haiku",body:"",labels:[{name:"ready-for-agent"},{name:"priority:normal"},{name:"judge:fallback"}],state:"OPEN"}
]' > "$FALLBACK_ISSUES"

cat > "$test_root/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "issue list") if [[ " $* " == *" --search "* ]]; then printf '[]\n'; else cat "$FALLBACK_ISSUES"; fi ;;
  "label list") printf '[]\n' ;;
  "api"*) printf '%s\n' "$*" >> "$FALLBACK_GH_WRITES" ;;
  "label create") printf '%s\n' "$*" >> "$FALLBACK_GH_WRITES" ;;
  *) exit 2 ;;
esac
STUB
# Stub claude: records each call and prints the reply in the same json envelope `claude -p --output-format json` uses.
cat > "$test_root/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf 'called\n' >> "$FALLBACK_CLAUDE_LOG"
printf '%s\n' "$@" > "$FALLBACK_CLAUDE_ARGS"
cat > /dev/null
[[ "${FALLBACK_CLAUDE_FAIL:-false}" != true ]] || exit 1
jq -cn --arg result "$(cat "$FALLBACK_CLAUDE_REPLY")" '{type:"result",is_error:false,result:$result}'
STUB
cat > "$test_root/ts-judge.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
input="$(cat)"
printf '%s\n' "$(jq -r '.issue.number // empty' <<< "$input")" >> "$FALLBACK_JUDGE_LOG"
case "$(cat "$FALLBACK_JUDGE_MODE")" in
  fallback) jq -cn '{status:"fallback",question_set:"intake-priority",reason:"credits-exhausted",candidate:null,confidence:null,decision:{priority:"priority:normal",route:"none-fits",duplicate:false,duplicateCandidates:[],stale:false},adopted:false}' ;;
  request-failed) jq -cn '{status:"fallback",question_set:"intake-priority",reason:"request-failed",candidate:null,confidence:null,decision:{priority:"priority:normal",route:"none-fits",duplicate:false,duplicateCandidates:[],stale:false},adopted:false}' ;;
  answered) jq -cn '{status:"answered",question_set:"intake-priority",candidate:"{\"priority\":\"priority:low\",\"route\":\"none-fits\",\"duplicate\":false,\"duplicateCandidates\":[],\"stale\":false}",confidence:0.99,decision:"{\"priority\":\"priority:low\",\"route\":\"none-fits\",\"duplicate\":false,\"duplicateCandidates\":[],\"stale\":false}",adopted:true}' ;;
esac
STUB
chmod +x "$test_root/bin/gh" "$test_root/bin/claude" "$test_root/ts-judge.sh"
export PATH="$test_root/bin:$PATH"
export ZF_TS_JUDGE_SCRIPT="$test_root/ts-judge.sh"
export FALLBACK_CLAUDE_REPLY="$test_root/claude-reply.txt"

run_judge_apply() { # mode reply -> writes $test_root/<mode>.result and gh writes
  local out="$test_root/$1.result"
  printf '%s\n' "$1" > "$FALLBACK_JUDGE_MODE"
  printf '%s\n' "$2" > "$FALLBACK_CLAUDE_REPLY"
  : > "$FALLBACK_GH_WRITES"; : > "$FALLBACK_CLAUDE_LOG"; : > "$FALLBACK_CLAUDE_ARGS"
  bash "$SCRIPT_DIR/intake-priority.sh" judge --repo fixture/repo --issue-file "$test_root/issue.json" --dry-stub > "$out"
  bash "$SCRIPT_DIR/intake-priority.sh" apply --repo fixture/repo --issue-file "$test_root/issue.json" --result-file "$out"
}

fail() { printf 'intake-priority-fallback.test.sh: %s\n' "$*" >&2; exit 1; }

# (a) credits-exhausted + haiku high -> priority:high and the judge:fallback marker, both through the label write path.
run_judge_apply fallback '{"priority":"high","route":null}' > "$test_root/a.out" 2>&1 || fail "(a) apply failed: $(cat "$test_root/a.out")"
grep -Fq 'labels[]=priority:high' "$FALLBACK_GH_WRITES" || fail "(a) no priority:high write: $(cat "$FALLBACK_GH_WRITES")"
grep -Fq 'labels[]=judge:fallback' "$FALLBACK_GH_WRITES" || fail "(a) no judge:fallback marker: $(cat "$FALLBACK_GH_WRITES")"
[[ -s "$FALLBACK_CLAUDE_LOG" ]] || fail "(a) haiku was not called"
# The haiku call gets no tools: --tools is followed by an empty argument, and the default tool list is absent.
[[ "$(awk 'prev == "--tools" { print ($0 == "" ? "empty" : "set"); exit } { prev = $0 }' "$FALLBACK_CLAUDE_ARGS")" == empty ]] || fail "(a) haiku call has tools: $(cat "$FALLBACK_CLAUDE_ARGS")"
grep -qx 'Read,Grep,Glob,Bash' "$FALLBACK_CLAUDE_ARGS" && fail "(a) default tool list on haiku call" || true
echo 'ok (a) credits-exhausted with haiku high writes priority:high and judge:fallback'

# (b) answered judge -> no haiku call and no marker.
run_judge_apply answered '{"priority":"top","route":null}' > "$test_root/b.out" 2>&1 || fail "(b) apply failed: $(cat "$test_root/b.out")"
[[ ! -s "$FALLBACK_CLAUDE_LOG" ]] || fail "(b) haiku called on an answered judge"
grep -Fq 'judge:fallback' "$FALLBACK_GH_WRITES" && fail "(b) marker written on an answered judge" || true
echo 'ok (b) answered judge calls no haiku and writes no marker'

# (c) bad haiku JSON -> no label, rc 0.
run_judge_apply fallback 'not json at all' > "$test_root/c.out" 2>&1 || fail "(c) apply rc non-zero: $(cat "$test_root/c.out")"
[[ ! -s "$FALLBACK_GH_WRITES" ]] || fail "(c) label written from bad haiku output: $(cat "$FALLBACK_GH_WRITES")"
grep -Fq 'intake-priority: haiku fallback skipped issue=#9101 reason=bad-answer' "$test_root/c.out" || fail '(c) bad haiku was not logged'
echo 'ok (c) bad haiku output writes no label and exits 0'

# (c2) a failed Claude call is logged and deferred with rc 75.
export FALLBACK_CLAUDE_FAIL=true
rc=0
bash "$SCRIPT_DIR/intake-priority.sh" judge --repo fixture/repo --issue-file "$test_root/issue.json" --dry-stub > "$test_root/c2.out" 2>&1 || rc=$?
unset FALLBACK_CLAUDE_FAIL
[[ "$rc" == 75 ]] || fail "(c2) a failed Claude call returned rc=$rc: $(cat "$test_root/c2.out")"
grep -Fq 'intake-priority: haiku fallback skipped issue=#9101 reason=call-failed' "$test_root/c2.out" || fail '(c2) call failure was not logged'
grep -Fq 'intake-priority: deferred issue=#9101 reason=call-failed' "$test_root/c2.out" || fail '(c2) call failure did not defer'
echo 'ok (c2) a failed Claude call is logged and deferred with rc 75'

# (d) fallback_model null -> haiku is not called.
jq -n '{intake_priority:{enabled:true,fallback_model:null}}' > "$ZF_CONFIG_ROOT/night.json"
run_judge_apply fallback '{"priority":"high","route":null}' > "$test_root/d.out" 2>&1 || fail "(d) apply failed: $(cat "$test_root/d.out")"
[[ ! -s "$FALLBACK_CLAUDE_LOG" ]] || fail "(d) haiku called with fallback_model null"
[[ ! -s "$FALLBACK_GH_WRITES" ]] || fail "(d) label written with fallback_model null"
grep -Fq 'intake-priority: haiku fallback skipped issue=#9101 reason=no-fallback-model' "$test_root/d.out" || fail '(d) missing fallback model was not logged'
echo 'ok (d) fallback_model null skips haiku and writes no label'

# (e) a real TypeSafe answer on an issue carrying the marker removes the marker through the same DELETE path.
printf '%s\n' answered > "$FALLBACK_JUDGE_MODE"
bash "$SCRIPT_DIR/intake-priority.sh" judge --repo fixture/repo --issue-file "$test_root/issue-marked.json" --dry-stub > "$test_root/e.result"
: > "$FALLBACK_GH_WRITES"
bash "$SCRIPT_DIR/intake-priority.sh" apply --repo fixture/repo --issue-file "$test_root/issue-marked.json" --result-file "$test_root/e.result" > "$test_root/e.out" 2>&1 || fail "(e) apply failed: $(cat "$test_root/e.out")"
grep -Fq 'DELETE repos/fixture/repo/issues/9102/labels/judge%3Afallback' "$FALLBACK_GH_WRITES" || fail "(e) marker not removed: $(cat "$FALLBACK_GH_WRITES")"
echo 'ok (e) answered judge removes the judge:fallback marker'

# (f) --skip-labelled passes an issue with a priority label only when it carries the marker.
printf '%s\n' answered > "$FALLBACK_JUDGE_MODE"
bash "$SCRIPT_DIR/intake-backlog.sh" --repo fixture/repo --output "$test_root/backlog.json" --dry-stub --skip-labelled > "$test_root/f.out" 2>&1 || fail "(f) backlog failed: $(cat "$test_root/f.out")"
jq -e '[.. | objects | select(has("number")) | .number] | index(9202) != null' "$test_root/backlog.json" >/dev/null || fail "(f) marked issue not re-judged"
jq -e '[.. | objects | select(has("number")) | .number] | index(9201) == null' "$test_root/backlog.json" >/dev/null || fail "(f) plain labelled issue was re-judged"
echo 'ok (f) --skip-labelled re-judges the marked issue and skips the plain labelled one'

# (g) scheduler intake judges ready issues before tracker/skip-label filtering, and only once they have a priority label.
HERE="$SCRIPT_DIR/mac-autopilot"
A="$test_root/autopi"
LOG="$test_root/scheduler.log"
STAMP=2026-11-16T00:00:00Z
REPO=fixture/repo
export TMPDIR="$test_env_root"
mkdir -p "$A/alerts"
source "$HERE/scheduler.d/core.sh"
source "$HERE/scheduler.d/intake-steps.sh"
source "$HERE/scheduler.d/intake.sh"
CFG='{"issue_intake":{"labels":["founder-test"],"product_labels":["ready-for-agent"]}}'
jq -n '{intake_priority:{enabled:true},issue_intake:{labels:["founder-test"],product_labels:["ready-for-agent"]}}' > "$ZF_CONFIG_ROOT/night.json"
jq -n '[
  {number:9301,title:"Unlabelled ready issue",body:"",state:"OPEN",labels:[{name:"ready-for-agent"}]},
  {number:9302,title:"Labelled ready issue",body:"",state:"OPEN",labels:[{name:"ready-for-agent"},{name:"priority:low"}]},
  {number:9303,title:"Supervisor tracker",body:"",state:"OPEN",labels:[{name:"founder-test"},{name:"auto-filed"},{name:"tracker"}]}
]' > "$FALLBACK_ISSUES"
jqf() { jq "$@"; }
say() { printf '%s\n' "$*" >> "$LOG"; }
hotfix_lane_label() { printf 'hotfix-lane\n'; }
gh_par_throttle() { :; }
intake_gh_read() { [[ "$1:$2" == issue:list ]] || return 1; cat "$FALLBACK_ISSUES"; }
printf '%s\n' request-failed > "$FALLBACK_JUDGE_MODE"
printf '%s\n' '{"priority":"high","route":null}' > "$FALLBACK_CLAUDE_REPLY"
: > "$FALLBACK_JUDGE_LOG"; : > "$FALLBACK_GH_WRITES"; : > "$FALLBACK_CLAUDE_LOG"
export TYPESAFE_API_KEY=fixture-key
rows="$(intake_candidates false)"
[[ "$(cut -f1 <<< "$rows" | sort | paste -sd, -)" == '9301,9302,9303' ]] || fail "(g) intake candidates missing: $rows"
[[ "$(sort -n "$FALLBACK_JUDGE_LOG" | paste -sd, -)" == '9301,9303' ]] || fail "(g) judged unexpected issues: $(cat "$FALLBACK_JUDGE_LOG")"
grep -Fq 'repos/fixture/repo/issues/9301/labels -f labels[]=priority:normal' "$FALLBACK_GH_WRITES" \
  || fail "(g) request-failed fallback priority missing: $(cat "$FALLBACK_GH_WRITES")"
grep -Fq 'repos/fixture/repo/issues/9303/labels -f labels[]=priority:top' "$FALLBACK_GH_WRITES" \
  || fail "(g) founder tracker floor missing: $(cat "$FALLBACK_GH_WRITES")"
grep -Fq 'labels[]=judge:fallback' "$FALLBACK_GH_WRITES" || fail "(g) request-failed fallback marker missing: $(cat "$FALLBACK_GH_WRITES")"
[[ -s "$FALLBACK_CLAUDE_LOG" ]] || fail '(g) request-failed did not reach haiku fallback'
jq 'map(if .number == 9301 then .labels += [{name:"priority:normal"},{name:"judge:fallback"}]
  elif .number == 9303 then .labels += [{name:"priority:top"},{name:"judge:fallback"}] else . end)' \
  "$FALLBACK_ISSUES" > "$FALLBACK_ISSUES.tmp" && mv "$FALLBACK_ISSUES.tmp" "$FALLBACK_ISSUES"
intake_candidates false >/dev/null
[[ "$(wc -l < "$FALLBACK_JUDGE_LOG" | tr -d ' ')" == 2 ]] || fail '(g) a priority-labelled issue was re-judged'
echo 'ok (g) ready issue and tracker use request-failed fallback once; labelled issues are skipped'

# (h) one candidate pass judges at most three unlabelled issues and leaves the rest for a later pass.
export ZF_INTAKE_JUDGE_PER_PASS=3
jq -n '[range(9401;9406) as $n | {number:$n,title:"Unlabelled issue",body:"",state:"OPEN",labels:[{name:"ready-for-agent"}]}]' > "$FALLBACK_ISSUES"
printf '%s\n' answered > "$FALLBACK_JUDGE_MODE"
: > "$FALLBACK_JUDGE_LOG"; : > "$FALLBACK_GH_WRITES"
LOG="$test_root/capped-scheduler.log"
rows="$(intake_candidates false)"
[[ "$(cut -f1 <<< "$rows" | sort -n | paste -sd, -)" == '9401,9402,9403,9404,9405' ]] || fail "(h) capped intake candidates missing: $rows"
[[ "$(sort -n "$FALLBACK_JUDGE_LOG" | paste -sd, -)" == '9401,9402,9403' ]] || fail "(h) one pass judged other than three: $(cat "$FALLBACK_JUDGE_LOG")"
grep -Fq 'intake priority judges deferred=2' "$LOG" || fail "(h) deferred count missing: $(cat "$LOG")"
echo 'ok (h) a pass judges three of five unlabelled candidates and logs two deferred'

# (i) the existing intake budget stops judges before the deadline, while counting candidates left.
: > "$FALLBACK_JUDGE_LOG"
LOG="$test_root/deadline-scheduler.log"
rows="$(intake_candidates false 0 0)"
[[ ! -s "$FALLBACK_JUDGE_LOG" ]] || fail "(i) judges ran after the intake budget: $(cat "$FALLBACK_JUDGE_LOG")"
grep -Fq 'intake priority judges deferred=5' "$LOG" || fail "(i) deadline did not count deferred candidates: $(cat "$LOG")"
echo 'ok (i) an expired intake budget defers all candidate judges'

# (j) an attempted judge that applies no label is stamped silently and is not retried within six hours.
jq -n '[{number:9501,title:"Judge failure",body:"",state:"OPEN",labels:[{name:"ready-for-agent"}]}]' > "$FALLBACK_ISSUES"
printf '%s\n' fallback > "$FALLBACK_JUDGE_MODE"
printf '%s\n' 'not json' > "$FALLBACK_CLAUDE_REPLY"
: > "$FALLBACK_JUDGE_LOG"
LOG="$test_root/cooldown-scheduler.log"
intake_candidates false >/dev/null
[[ "$(wc -l < "$FALLBACK_JUDGE_LOG" | tr -d ' ')" == 1 ]] || fail "(j) first failed judge missing: $(cat "$FALLBACK_JUDGE_LOG")"
intake_candidates false >/dev/null
[[ "$(wc -l < "$FALLBACK_JUDGE_LOG" | tr -d ' ')" == 1 ]] || fail "(j) failed judge retried within six hours: $(cat "$FALLBACK_JUDGE_LOG")"
grep -Fq '9501 intake priority label not applied' "$A/intake-skip-noted.tsv" || fail '(j) failed judge was not stamped'
! grep -Fq 'intake skip issue' "$LOG" || fail "(j) non-applied judge was logged as a skipped issue: $(cat "$LOG")"
echo 'ok (j) an issue without an applied label is not judged again within six hours'

# (k) TypeSafe credits exhaustion plus a held Claude provider defers and keeps the station candidate retryable.
jq -n '{intake_priority:{enabled:true}}' > "$ZF_CONFIG_ROOT/night.json"
jq -n --argjson reset "$(( $(date +%s) + 3600 ))" '{week_pct:95,week_reset:$reset}' > "$CLAUDE_QUOTA_SNAPSHOT_FILE"
printf '%s\n' fallback > "$FALLBACK_JUDGE_MODE"
: > "$FALLBACK_CLAUDE_LOG"
: > "$FALLBACK_GH_WRITES"
rc=0
bash "$SCRIPT_DIR/intake-priority.sh" triage 9101 ready-for-agent "$REPO" < "$test_root/issue.json" > "$test_root/k.out" 2>&1 || rc=$?
[[ "$rc" == 75 ]] || fail "(k) a held Claude fallback returned rc=$rc: $(cat "$test_root/k.out")"
grep -Fq 'intake-priority: haiku fallback skipped issue=#9101 reason=claude-held' "$test_root/k.out" \
  || fail "(k) the held fallback reason was missing: $(cat "$test_root/k.out")"
grep -Fq 'intake-priority: deferred issue=#9101 reason=claude-held' "$test_root/k.out" \
  || fail "(k) the deferral line was missing: $(cat "$test_root/k.out")"
grep -Fq 'intake-priority: deferred issue=#9101 reason=priority missing classifier=deferred' "$test_root/k.out" \
  || fail "(k) the missing-priority reason was missing: $(cat "$test_root/k.out")"
[[ ! -s "$FALLBACK_CLAUDE_LOG" ]] || fail '(k) Claude ran while its provider was held'
[[ ! -s "$FALLBACK_GH_WRITES" ]] || fail '(k) a classifier hold assigned a default priority or route'
export ZF_INTAKE_PRIORITY_SCRIPT="$SCRIPT_DIR/intake-priority.sh"
CONSUMED_CANDIDATES=0
intake_judge_station_consume_candidate() { CONSUMED_CANDIDATES=$((CONSUMED_CANDIDATES + 1)); }
rm -f "$A/intake-skip-noted.tsv"
intake_priority_judge_issue "$(cat "$test_root/issue.json")" 9101 "$REPO" || fail '(k) the scheduler rejected a held-provider deferral'
[[ ! -e "$A/intake-skip-noted.tsv" ]] || fail '(k) the held-provider deferral was cooldown-stamped'
[[ "$CONSUMED_CANDIDATES" == 0 ]] || fail '(k) the held-provider candidate was consumed'
grep -Fq 'intake-priority: deferred issue=#9101 reason=claude-held' "$LOG" || fail '(k) scheduler output lost the deferral line'
rm -f "$CLAUDE_QUOTA_SNAPSHOT_FILE"
unset -f intake_judge_station_consume_candidate
echo 'ok (k) a Claude hold exits 75, is not stamped, and leaves its candidate retryable'

# (l) outcomes that did not reach a judge do not get a cooldown stamp or skip log.
for skip_reason in disabled missing-typesafe-key invalid-config; do
  case "$skip_reason" in
    disabled)
      export TYPESAFE_API_KEY=fixture-key
      jq -n '{intake_priority:{enabled:false}}' > "$ZF_CONFIG_ROOT/night.json"
      ;;
    missing-typesafe-key)
      unset TYPESAFE_API_KEY TYPESAFE_ENV_FILE
      jq -n '{intake_priority:{enabled:true}}' > "$ZF_CONFIG_ROOT/night.json"
      ;;
    invalid-config)
      export TYPESAFE_API_KEY=fixture-key
      printf '%s\n' 'not json' > "$ZF_CONFIG_ROOT/night.json"
      ;;
  esac
  rm -f -- "$A/intake-skip-noted.tsv"
  : > "$FALLBACK_JUDGE_LOG"
  LOG="$test_root/skip-$skip_reason.log"
  intake_candidates false >/dev/null
  grep -Fq "intake-priority: skipped ($skip_reason)" "$LOG" || fail "(k) missing skipped status $skip_reason: $(cat "$LOG")"
  [[ ! -e "$A/intake-skip-noted.tsv" ]] || fail "(k) $skip_reason created a cooldown stamp"
  [[ ! -s "$FALLBACK_JUDGE_LOG" ]] || fail "(k) $skip_reason reached the judge: $(cat "$FALLBACK_JUDGE_LOG")"
  ! grep -Fq 'intake skip issue' "$LOG" || fail "(k) $skip_reason logged an intake skip: $(cat "$LOG")"
done
echo 'ok (l) disabled, missing-key, and invalid-config outcomes are not stamped or logged as skipped issues'

# (m) rate-limited label writes are retried next pass, while ordinary label failures retain the cooldown.
export FALLBACK_PRIORITY_OUTPUT="$test_root/priority-output.txt" FALLBACK_PRIORITY_RC=0
cat > "$test_root/failed-priority.sh" <<'STUB'
#!/usr/bin/env bash
cat "$FALLBACK_PRIORITY_OUTPUT"
exit "$FALLBACK_PRIORITY_RC"
STUB
chmod +x "$test_root/failed-priority.sh"
export ZF_INTAKE_PRIORITY_SCRIPT="$test_root/failed-priority.sh"
LOG="$test_root/priority-backoff.log"
printf 'intake-priority: label update failed for issue #9601\ngh: rest primary rate limit exhausted; shared backoff until epoch=1794902188\n' > "$FALLBACK_PRIORITY_OUTPUT"
intake_priority_judge_issue '{"number":9601}' 9601 "$REPO" || fail '(m) rate-limited label failure returned non-zero'
[[ ! -e "$A/intake-skip-noted.tsv" ]] || fail '(m) rate-limited label failure was stamped'
printf 'intake-priority: label update failed for issue #9601\n' > "$FALLBACK_PRIORITY_OUTPUT"
intake_priority_judge_issue '{"number":9601}' 9601 "$REPO" || fail '(m) ordinary label failure returned non-zero'
grep -Fq '9601 intake priority label not applied' "$A/intake-skip-noted.tsv" || fail '(m) ordinary label failure was not stamped'
rm -f -- "$A/intake-skip-noted.tsv"
FALLBACK_PRIORITY_RC=75
intake_priority_judge_issue '{"number":9601}' 9601 "$REPO" || fail '(m) rc 75 label failure returned non-zero'
[[ ! -e "$A/intake-skip-noted.tsv" ]] || fail '(m) rc 75 label failure was stamped'
echo 'ok (l) rate-limited label failures are unstamped; ordinary label failures retain the cooldown'

# (n) the triage roadmap tree read is bounded at 180 s, not the 60 s default that the live full-tree read overran.
export FALLBACK_TIMEOUT_LOG="$test_root/timeout-calls.log" FALLBACK_REAL_TIMEOUT="$(command -v timeout)"
cat > "$test_root/bin/timeout" <<'STUB'
#!/usr/bin/env bash
[[ "${2:-}" == gh ]] && printf '%s\n' "$1" >> "$FALLBACK_TIMEOUT_LOG"
exec "$FALLBACK_REAL_TIMEOUT" "$@"
STUB
chmod +x "$test_root/bin/timeout"
printf 'answered\n' > "$FALLBACK_JUDGE_MODE"
printf '{"priority":"low","route":null}\n' > "$FALLBACK_CLAUDE_REPLY"
: > "$FALLBACK_TIMEOUT_LOG"
jq -n '{intake_priority:{enabled:true}}' > "$ZF_CONFIG_ROOT/night.json"
env -u ZF_ROADMAP_TREE_CACHE_FILE bash "$SCRIPT_DIR/intake-priority.sh" judge --repo fixture/repo --issue-file "$test_root/issue.json" --dry-stub > "$test_root/m.result" 2> "$test_root/m.err" || fail "(m) judge failed: $(cat "$test_root/m.err")"
grep -Fxq '180s' "$FALLBACK_TIMEOUT_LOG" || fail "(m) roadmap tree read bound was: $(tr '\n' ' ' < "$FALLBACK_TIMEOUT_LOG")"
echo 'ok (m) the triage roadmap tree read is bounded at 180 s'
