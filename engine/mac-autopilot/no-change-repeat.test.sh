#!/usr/bin/env bash
# Row 613: a second NO-CHANGE escalation with the same reason, after no human/head ruling, stays at supervisor-review.
# First NO-CHANGE: one arbiter dispatch (today's behaviour). Second: no arbiter dispatch and no requeue.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/no-change-repeat"
sup="$fixture/supervisor"
mkdir -p "$sup/autopi/alerts" "$fixture/repo" "$fixture/bin" "$fixture/worker-scratch/luna" "$fixture/wt-root"
export ZF_ROADMAP_TREE_CACHE_FILE="$fixture/roadmap-tree.json"
echo '{"roots":[]}' > "$ZF_ROADMAP_TREE_CACHE_FILE"
jq '.auto_merge = false | .advisor = false | .precheck = false | .supervisor_arbiter.enabled = true | .supervisor_arbiter.cap_triage = false' "$script_dir/config.template.json" > "$sup/autopi/config.json"
echo '{"units":[]}' > "$sup/autopi/units.json"
echo '{"workers":[]}' > "$sup/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$sup/autopi" WORKER_SCRATCH_ROOT="$fixture/worker-scratch"
export CODEX_HOME="$fixture/codex-home"
mkdir -p "$CODEX_HOME"
printf '[profiles.terra]\nmodel = "gpt-6.1-terra"\n' > "$CODEX_HOME/config.toml"
export ZF_CONFIG_ROOT="$fixture/repo/.zenoforge"
mkdir -p "$ZF_CONFIG_ROOT/prompts"
cp "$script_dir/../prompts/supervisor-arbiter.md" "$ZF_CONFIG_ROOT/prompts/supervisor-arbiter.md"
cp "$script_dir/../prompts/review-contract.md" "$ZF_CONFIG_ROOT/prompts/review-contract.md"
export CODEX_SESSIONS_DIR="$fixture/sessions"
export REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
decision_eval_stages() { printf '\n'; }

fail() { echo "no-change-repeat.test.sh: $*" >&2; exit 1; }
# The arbiter candidate gate that skips a repeated NO-CHANGE lives in no-human-wait.sh (both arbiter loops read it).
grep -Fq supervisor_no_change_waiting "$script_dir/scheduler.d/no-human-wait.sh" || fail "no-human-wait.sh does not gate the arbiter on a repeated NO-CHANGE"
GH_CALLS="$fixture/gh.calls"; : > "$GH_CALLS"
gh() { printf 'gh %s\n' "$*" >> "$GH_CALLS"; return 0; }
export -f gh 2>/dev/null || true
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/bin/codex"; chmod +x "$fixture/bin/codex"
export PATH="$fixture/bin:$PATH"

WT_ROOT="$fixture/wt-root"
ensure_clone() { printf '%s' "$WT_ROOT/wt-$1"; }
checkout_pr_head() { :; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
command git init -q --bare -b main "$fixture/origin.git"
command git init -q -b main "$fixture/src"
printf 'base\n' > "$fixture/src/f"; command git -C "$fixture/src" add -A; command git -C "$fixture/src" commit -qm base
command git -C "$fixture/src" remote add origin "$fixture/origin.git"; command git -C "$fixture/src" push -q origin main
# The worker clone sits on main with no commits of its own and a clean tree, and the branch is not on origin:
# harvest_pr_implement takes the empty-delivery path, where a NO-CHANGE report is a decision.
command git clone -q "$fixture/origin.git" "$WT_ROOT/wt-issue-613"
command git -C "$WT_ROOT/wt-issue-613" checkout -q -b agent/issue-613

units() { printf '%s\n' "$1" > "$UNITS"; echo '{"workers":[]}' > "$WORKERS"; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }
supervise_workers() { jq -r '[.workers[] | select(.type=="supervise" and .unit=="issue-613")] | length' "$WORKERS"; }
mark_arbiter_done() { jq '.workers |= map(if .type=="supervise" then .harvested=true else . end)' "$WORKERS" > "$WORKERS.tmp" && mv "$WORKERS.tmp" "$WORKERS"; }
units '{"units":[{"id":"issue-613","issue":613,"title":"no-change loop","branch":"agent/issue-613","lane":"pr","stage":"implement-pending","history":[]}]}'

# 1) First NO-CHANGE: the escalation goes to supervisor-review and the arbiter gets its one run (today's behaviour).
printf 'NO-CHANGE: 需先拆出授权范围切片，本轮有意不改代码\n' > "$sup/impl-613a.md"
harvest_pr_implement issue-613 "$sup/impl-613a.md" || :
[[ "$(field issue-613 .stage)" == supervisor-review ]] || fail "first NO-CHANGE did not reach supervisor-review ($(field issue-613 .stage))"
[[ "$(field issue-613 '[.history[] | select(.stage=="supervisor-escalated")] | length')" == 1 ]] || fail 'first NO-CHANGE escalation missing'
dispatch_supervisor_arbiters || :
[[ "$(supervise_workers)" == 1 ]] || fail "first NO-CHANGE must dispatch exactly one arbiter run ($(supervise_workers))"
# The arbiter answers with a requeue (owner supervisor), then the implementer repeats the same no-change report.
mark_arbiter_done
set_unit issue-613 "$(hist supervisor-requeue "arbiter requeue" "$(decision_entry 'Supervisor arbitration: requeue' 'arbiter requeue' 'fixture' '[]' supervisor)") | .stage=\"implement-pending\""
requeues_before="$(field issue-613 '[.history[] | select(.stage=="supervisor-requeue")] | length')"

# 2) Second NO-CHANGE, same reason, the report name differs: no arbiter run, no requeue, unit stays at supervisor-review.
printf 'NO-CHANGE: 需先拆出授权范围切片，本轮有意不改代码\n' > "$sup/impl-613b.md"
harvest_pr_implement issue-613 "$sup/impl-613b.md" || :
[[ "$(field issue-613 .stage)" == supervisor-review ]] || fail "second NO-CHANGE did not stay at supervisor-review ($(field issue-613 .stage))"
[[ "$(field issue-613 '[.history[] | select(.stage=="supervisor-escalated")] | length')" == 2 ]] || fail 'second NO-CHANGE escalation missing'
dispatch_supervisor_arbiters || :
[[ "$(supervise_workers)" == 1 ]] || fail "second NO-CHANGE dispatched an arbiter run ($(supervise_workers) supervise workers)"
[[ "$(field issue-613 '[.history[] | select(.stage=="supervisor-requeue")] | length')" == "$requeues_before" ]] || fail 'second NO-CHANGE was requeued'
[[ "$(field issue-613 .stage)" == supervisor-review ]] || fail "unit left supervisor-review without a ruling ($(field issue-613 .stage))"
[[ "$(field issue-613 '.history | map(select(.stage=="supervisor-escalated")) | last | .no_change_repeat')" == true ]] || fail 'second escalation is not marked as a NO-CHANGE repeat'

# 3) A head ruling (hand-written supervisor requeue, no decision object) ends the wait: the unit is a candidate again.
set_unit issue-613 "$(hist supervisor-requeue 'supervisor ruling: retry with the slice' ) | .stage=\"supervisor-review\""
supervisor_no_change_waiting "$(jqf -c --arg id issue-613 '[.units[] | select(.id==$id)][0]' "$UNITS")" && fail 'a head ruling did not end the NO-CHANGE wait'

echo 'no-change-repeat.test.sh: ok'
