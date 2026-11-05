#!/usr/bin/env bash
# Focused regression for #424: an eval regression on a delivered change opens a revert PR through the
# shared revert path (no human step) only after a confirming rerun and only when the change itself is to blame,
# covers AGENTS.md and engine/vendor/, and reverts a change once.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/eval-regression-revert"
sup="$fixture/supervisor"
mkdir -p "$sup/autopi/alerts" "$fixture/bin"
jq '.auto_merge = false | .advisor = false | .precheck = false' \
  "$script_dir/config.template.json" > "$sup/autopi/config.json"
printf '%s\n' '{"workers":[]}' > "$sup/autopi/workers.json"

# A repo whose origin/main holds one delivered change (the culprit) and one unrelated commit.
git init -q --bare "$fixture/origin.git"
git clone -q "$fixture/origin.git" "$fixture/repo" 2>/dev/null
git="git -C $fixture/repo -c user.name=t -c user.email=t@example.invalid"
printf 'one\n' > "$fixture/repo/a.txt"; $git add a.txt; $git commit -qm base
printf 'two\n' > "$fixture/repo/a.txt"; $git commit -qam 'fix(#77): change a'
culprit="$($git rev-parse HEAD)"
$git push -q origin HEAD:refs/heads/main; $git fetch -q origin

export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$sup/autopi"
export REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
SCHED_LOCK_HELD=true

fail() { printf 'eval-regression-revert.test.sh: %s\n' "$*" >&2; exit 1; }
field() { jq -r ".units[] | select(.id==\"eval-77\") | $1" "$UNITS"; }
sha=3333333333333333333333333333333333333333
printf '%s\n' "$(jq -cn --arg sha "$sha" '{status:"failed",sha:$sha,label:"gate-t",baseline:"baseline",tree:"t",stages:["triage"],regressions:["triage/case-1/run-1"],criticalFailures:[]}')" > "$sup/report.json"
jq -cn --arg culprit "$culprit" --arg sha "$sha" '{units:[{id:"eval-77",issue:77,lane:"pr",stage:"merged",merge_sha:$culprit,history:[],
  eval_gate:{status:"running",sha:$sha,report:"report.json",stages:["triage"]}}]}' > "$UNITS"
worker() { jq -cn --arg sha "$sha" '{unit:"eval-77",pid:1,type:"eval",report:"report.json",sha:$sha}'; }

OPENED="$fixture/opened"; : > "$OPENED"
real_open="$(declare -f eval_regression_open_revert)"
eval_regression_open_revert() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$OPENED"; echo https://example.invalid/pull/501; }

# Covered paths: AGENTS.md and engine/vendor/ are evaluated like the other agent-facing instructions.
for path in AGENTS.md engine/vendor/pstack/skills/x/SKILL.md; do
  [[ "$(decision_eval_stages_for_paths "$path")" == 'triage advisor implement review end-to-end ' ]] || fail "$path is not evaluated"
done

# First failure: rerun once under a fresh label, no revert and no escalation yet.
workers_json="$(worker)"; printf '%s\n' "{\"workers\":[$workers_json]}" > "$WORKERS"
harvest_prompt_eval "$workers_json"
[[ ! -s "$OPENED" && "$(field .eval_gate.status)" == pending && "$(field .eval_gate.confirm)" == true && "$(field .stage)" == merged ]] || fail 'the first failure was not held for a confirming rerun'
[[ "$(field '[.history[].stage] | index("eval-regression-unconfirmed") != null')" == true ]] || fail 'no eval-regression-unconfirmed history entry'

# Planted regression, confirmed by the rerun: one revert PR for the merged change, recorded on the unit, evidence still escalated.
printf '%s\n' "{\"workers\":[$workers_json]}" > "$WORKERS"
harvest_prompt_eval "$workers_json"
[[ "$(cat "$OPENED")" == "77 $culprit $sha" ]] || fail "planted regression did not open the revert (got: $(cat "$OPENED"))"
[[ "$(field .eval_gate.revert_pr)" == https://example.invalid/pull/501 ]] || fail 'revert PR is not recorded on the unit'
[[ "$(field '[.history[].stage] | index("eval-regression-revert") != null')" == true ]] || fail 'no eval-regression-revert history entry'
[[ "$(field .stage)" == supervisor-review && "$(field .note)" == *'pull/501'* ]] || fail 'the supervisor escalation lost the revert PR'

# Loop guard: the same change is never reverted twice, whether the unit remembers it or main already carries the revert.
printf '%s\n' "{\"workers\":[$workers_json]}" > "$WORKERS"
harvest_prompt_eval "$workers_json"
[[ "$(wc -l < "$OPENED")" == 1 ]] || fail 'a second report reverted the same change again'
jq 'del(.units[0].eval_gate.revert_pr) | .units[0].stage="merged"' "$UNITS" > "$UNITS.tmp"; mv "$UNITS.tmp" "$UNITS"
$git revert --no-edit "$culprit" >/dev/null; $git push -q origin HEAD:refs/heads/main; $git fetch -q origin
printf '%s\n' "{\"workers\":[$workers_json]}" > "$WORKERS"
harvest_prompt_eval "$workers_json"
[[ "$(wc -l < "$OPENED")" == 1 ]] || fail 'a change already reverted on main was reverted again'

# No delivered commit (the eval ran before delivery): fall back to the supervisor escalation alone.
jq 'del(.units[0].merge_sha) | .units[0].stage="merged"' "$UNITS" > "$UNITS.tmp"; mv "$UNITS.tmp" "$UNITS"
printf '%s\n' "{\"workers\":[$workers_json]}" > "$WORKERS"
harvest_prompt_eval "$workers_json"
[[ "$(wc -l < "$OPENED")" == 1 && "$(field .stage)" == supervisor-review ]] || fail 'an undelivered change must only escalate'
# Attribution: the eval tree carries every earlier change, so a regression in stages the unit's own diff never touches,
# or one an earlier delivered change with an unproven eval could cause, is escalated without a revert.
for n in 79 80; do printf '%s\n' "$n" > "$fixture/repo/c$n.txt"; $git add "c$n.txt"; $git commit -qm "fix(#$n): add c$n"; eval "c$n=$($git rev-parse HEAD)"; done
$git push -q origin HEAD:refs/heads/main; $git fetch -q origin
jq -cn --arg a "$c79" --arg b "$c80" --arg sha "$sha" '{units:[
  {id:"eval-79",issue:79,lane:"pr",stage:"merged",merge_sha:$a,history:[],eval_gate:{status:"failed",stages:["triage"],sha:$sha}},
  {id:"eval-80",issue:80,lane:"pr",stage:"merged",merge_sha:$b,history:[],eval_gate:{status:"running",sha:$sha,report:"report.json",stages:["triage"],confirm:true}}]}' > "$UNITS"
workers_json="$(jq -cn --arg sha "$sha" '{unit:"eval-80",pid:1,type:"eval",report:"report.json",sha:$sha}')"
harvest_prompt_eval "$workers_json" || true
[[ "$(wc -l < "$OPENED")" == 1 && -z "$(jq -r '.units[1].eval_gate.revert_pr // empty' "$UNITS")" ]] || fail 'reverted a change while an earlier delivered change has an unproven eval'
jq '.units[0].eval_gate.status="passed"' "$UNITS" > "$UNITS.tmp"; mv "$UNITS.tmp" "$UNITS"
jq '.units[1].eval_gate.stages=["advisor"]' "$UNITS" > "$UNITS.tmp"; mv "$UNITS.tmp" "$UNITS"
harvest_prompt_eval "$workers_json" || true
[[ "$(wc -l < "$OPENED")" == 1 ]] || fail 'reverted a change for a regression outside its own stages'
jq '.units[1].eval_gate.stages=["triage"]' "$UNITS" > "$UNITS.tmp"; mv "$UNITS.tmp" "$UNITS"
harvest_prompt_eval "$workers_json"
[[ "$(tail -n 1 "$OPENED")" == "80 $c80 $sha" ]] || fail 'an attributable regression was not reverted'
# The shared revert helper accepts the eval kind: eval branch name, exact git-revert trailer, PR opened.
cat > "$fixture/bin/gh" <<'GH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'pr list') ;;
  'pr create') printf '%s\n' "$*" >> "$GH_CALLS"; echo https://example.invalid/pull/9 ;;
esac
GH
chmod +x "$fixture/bin/gh"
eval "$real_open"
printf 'three\n' > "$fixture/repo/b.txt"; $git add b.txt; $git commit -qm 'fix(#78): add b'
culprit="$($git rev-parse HEAD)"; $git push -q origin HEAD:refs/heads/main; $git fetch -q origin
revert_url="$(PATH="$fixture/bin:$PATH" GH_CALLS="$fixture/gh-calls" AGENT_HOME="$fixture/home" ZF_REPO=o/r eval_regression_open_revert 78 "$culprit" "$sha" | grep -oE 'https://[^[:space:]]+/pull/[0-9]+' | tail -n 1)" || fail 'the shared revert helper refused the eval kind'
[[ "$revert_url" == https://example.invalid/pull/9 ]] || fail "unexpected revert PR url: $revert_url"
grep -Fq -- "--head agent/revert-eval-78-${culprit:0:12}" "$fixture/gh-calls" || fail 'eval revert PR has the wrong branch'
git -C "$fixture/origin.git" log -1 --format=%B "agent/revert-eval-78-${culprit:0:12}" | grep -Fxq "This reverts commit $culprit." || fail 'revert commit lacks the exact trailer'
printf 'eval-regression-revert.test.sh: planted regression -> rerun, then 1 revert action; repeats, reverted, undelivered and unattributable changes -> none\n'
