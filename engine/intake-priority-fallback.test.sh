#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root" "$test_env_root"' EXIT
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
echo 'ok (c) bad haiku output writes no label and exits 0'

# (d) fallback_model null -> haiku is not called.
jq -n '{intake_priority:{enabled:true,fallback_model:null}}' > "$ZF_CONFIG_ROOT/night.json"
run_judge_apply fallback '{"priority":"high","route":null}' > "$test_root/d.out" 2>&1 || fail "(d) apply failed: $(cat "$test_root/d.out")"
[[ ! -s "$FALLBACK_CLAUDE_LOG" ]] || fail "(d) haiku called with fallback_model null"
[[ ! -s "$FALLBACK_GH_WRITES" ]] || fail "(d) label written with fallback_model null"
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
source "$SCRIPT_DIR/mac-autopilot/scheduler.d/intake-steps.sh"
source "$SCRIPT_DIR/mac-autopilot/scheduler.d/intake.sh"
HERE="$SCRIPT_DIR/mac-autopilot"
A="$test_root/autopi"
LOG="$test_root/scheduler.log"
STAMP=2026-11-16T00:00:00Z
REPO=fixture/repo
mkdir -p "$A/alerts"
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
chain_exit_trap() { trap "$1" EXIT; }
gh_par_throttle() { :; }
intake_gh_read() { [[ "$1:$2" == issue:list ]] || return 1; cat "$FALLBACK_ISSUES"; }
printf '%s\n' request-failed > "$FALLBACK_JUDGE_MODE"
printf '%s\n' '{"priority":"high","route":null}' > "$FALLBACK_CLAUDE_REPLY"
: > "$FALLBACK_JUDGE_LOG"; : > "$FALLBACK_GH_WRITES"; : > "$FALLBACK_CLAUDE_LOG"
export TYPESAFE_API_KEY=fixture-key
rows="$(intake_candidates false)"
[[ "$(cut -f1 <<< "$rows" | sort | paste -sd, -)" == '9301,9302,9303' ]] || fail "(g) intake candidates missing: $rows"
[[ "$(sort -n "$FALLBACK_JUDGE_LOG" | paste -sd, -)" == '9301,9303' ]] || fail "(g) judged unexpected issues: $(cat "$FALLBACK_JUDGE_LOG")"
grep -Fq 'labels[]=priority:high' "$FALLBACK_GH_WRITES" || fail "(g) request-failed fallback priority missing: $(cat "$FALLBACK_GH_WRITES")"
grep -Fq 'labels[]=judge:fallback' "$FALLBACK_GH_WRITES" || fail "(g) request-failed fallback marker missing: $(cat "$FALLBACK_GH_WRITES")"
[[ -s "$FALLBACK_CLAUDE_LOG" ]] || fail '(g) request-failed did not reach haiku fallback'
jq 'map(if .number == 9301 or .number == 9303 then .labels += [{name:"priority:high"},{name:"judge:fallback"}] else . end)' \
  "$FALLBACK_ISSUES" > "$FALLBACK_ISSUES.tmp" && mv "$FALLBACK_ISSUES.tmp" "$FALLBACK_ISSUES"
intake_candidates false >/dev/null
[[ "$(wc -l < "$FALLBACK_JUDGE_LOG" | tr -d ' ')" == 2 ]] || fail '(g) a priority-labelled issue was re-judged'
echo 'ok (g) ready issue and tracker use request-failed fallback once; labelled issues are skipped'
