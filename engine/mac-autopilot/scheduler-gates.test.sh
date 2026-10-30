#!/usr/bin/env bash
# scheduler 门禁/状态机回归：批准绑定 head、结论解析、报告不复用、回合断路、批量回退顺序、
# 非裁决不回退、BLOCK 重派条件、门禁 [skip ci] 评估点、分支清理只删 [gone]、隔离 clone、
# 正文 Blocked by 派发前拦截。
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

# Focused policy tests run one admission stage with a fresh per-call cancellation ledger.
# 一拍内的 run/job 快照在准入各阶段间共享（8ca4eceaa）：每次聚焦调用先清缓存重新取；
# 夹具预置的 TICK_UNFINISHED 就是一份完整快照（含 in_progress，各阶段不再单独回读 gh）。
ci_tick_reset() {
  CI_RUN_JOBS_CACHE=()
  TICK_UNFINISHED_LOADED=false
  TICK_UNFINISHED_IN_PROGRESS_OK=false
  TICK_UNFINISHED_ALL_OK=false
  if [[ -n "${TICK_UNFINISHED:-}" ]]; then
    TICK_UNFINISHED_LOADED=true; TICK_UNFINISHED_IN_PROGRESS_OK=true; TICK_UNFINISHED_ALL_OK=true
  fi
  return 0
}
ci_wip_gate_test() { local CI_HOTFIX_BRANCHES='[]'; local -A CI_ADMISSION_CANCELLED=(); ci_tick_reset; ci_assign_wip; }
ci_admission_test() { ci_tick_reset; ci_admission; }
ci_defer_ci_test() { local CI_HOTFIX_BRANCHES='[]'; local -A CI_ADMISSION_CANCELLED=(); ci_tick_reset; ci_defer_unapproved; }
ci_defer_classified_test() {
  local CI_HOTFIX_BRANCHES
  local -A CI_ADMISSION_CANCELLED=()
  CI_HOTFIX_BRANCHES="$(ci_hotfix_branches)" || CI_HOTFIX_BRANCHES='[]'
  ci_tick_reset
  ci_defer_unapproved
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/gates"
sup="$fixture/supervisor"
mkdir -p "$sup/autopi/alerts" "$fixture/repo"
# Repair now reads the failure itself, rather than sending just its path.
printf 'VERDICT: REQUEST-CHANGES\nNew review failure\n' > "$sup/r.md"
printf 'VERDICT: REQUEST-CHANGES\nNew review failure\n' > "$sup/review-14.md"
# 顾问与本机预检默认开；各自的用例里显式打开，其余用例按原状态机断言
jq '.auto_merge = true | .advisor = false | .precheck = false' "$script_dir/config.template.json" > "$sup/autopi/config.json"
echo '{"units":[]}' > "$sup/autopi/units.json"
echo '{"workers":[]}' > "$sup/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$sup/autopi"
# 本套件在本机跑时也会撞到生产 luna-slots 路径：指向 fixture，隔离在用的门。
export LUNA_SLOTS="$fixture/luna-slots"; mkdir -p "$LUNA_SLOTS"
export CODEX_SESSIONS_DIR="$fixture/sessions"
export ZF_TEST_EVIDENCE_LEDGER="$sup/test-evidence.jsonl"
# Existing state-machine fixtures intentionally use synthetic check names.
export REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
ensure_clone_source="$(declare -f ensure_clone)"
checkout_pr_head_source="$(declare -f checkout_pr_head)"
unset AUTOPI_TEST_LIBRARY_ONLY
# Gate orchestration has a real-tree fixture in scheduler-self-check.test.sh.
self_check_before_review() { return 0; }
# Scheduler gate cases use synthetic SHAs without real diffs; this fixture
# models them as changes that do not affect prompt-evaluation stages.
decision_eval_stages() { printf '\n'; }
# A real tick caches the open-PR census and drops it when the scheduler changes a PR; these fixtures edit the PR table between calls, so every read starts empty.
tick_prs_real_def="$(declare -f tick_prs)"; eval "${tick_prs_real_def/tick_prs ()/tick_prs_real ()}"
tick_prs() { TICK_PRS=""; tick_prs_real; }
# The reproduction worker is detached and slow; the older red-main fixtures below do not exercise it.
main_red_real="$(declare -f main_red_attribution)"
main_red_attribution() { MAIN_RED_REVERTED=0; MAIN_RED_PENDING=0; }

# 合并门评估链：越过 [skip ci] 与只改产品路径的提交，停在第一个改流水线路径的非 skip 提交（含）
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
gr="$fixture/gate-repo"; command git init -q -b main "$gr"
mkdir -p "$gr/.github/workflows" "$gr/engine" "$gr/packages/x"
cat > "$gr/.github/workflows/pipeline-suites.yml" <<'YAML'
on:
  pull_request:
    paths:
      - 'engine/**'
  workflow_dispatch:
YAML
command git -C "$gr" add -A; command git -C "$gr" commit -qm base
echo a > "$gr/engine/a.sh"; command git -C "$gr" add -A; command git -C "$gr" commit -qm 'pipeline change'; g1="$(command git -C "$gr" rev-parse HEAD)"
echo b > "$gr/packages/x/b.ts"; command git -C "$gr" add -A; command git -C "$gr" commit -qm 'product change'; g2="$(command git -C "$gr" rev-parse HEAD)"
echo c > "$gr/engine/c.sh"; command git -C "$gr" add -A; command git -C "$gr" commit -qm '[skip ci] direct landing'; g3="$(command git -C "$gr" rev-parse HEAD)"
command git -C "$gr" update-ref refs/remotes/origin/main "$g3"
[[ "$(ROOT="$gr" gate_eval_sha | tr '\n' ' ')" == "$g3 $g2 $g1 " ]] || fail "gate chain did not walk past product commits: $(ROOT="$gr" gate_eval_sha | tr '\n' ' ')"

fail() { echo "scheduler-gates.test.sh: $*" >&2; exit 1; }
units() { printf '%s\n' "$1" > "$UNITS"; echo '{"workers":[]}' > "$WORKERS"; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }

# An approved predecessor can release a labelled dependent onto its PR head.
stack_sha=0123456789012345678901234567890123456789
dep_states_real="$(declare -f dep_states)"
pr_view_real="$(declare -f pr_view)"
stack_initial_branch_real="$(declare -f stack_initial_branch)"
dep_states() { printf '1\tOPEN\t\n'; }
stack_initial_branch() { return 0; }
pr_view() {
  case "$2" in
    state) echo OPEN ;;
    headRefOid) echo "$stack_sha" ;;
  esac
}
# stack_approved_dependency reads the predecessor PR through gh (open-PR census, then gh pr view), not pr_view.
gh() {
  case "$1 $2" in
    'pr list') printf '[{"number":101,"headRefOid":"%s"}]\n' "$stack_sha" ;;
    'pr view') printf '{"state":"OPEN","headRefOid":"%s"}\n' "$stack_sha" ;;
    *) return 1 ;;
  esac
}
DEP_CHECK_SECONDS=0
printf '0\n' > "$A/dep-check.epoch"
units "$(jq -cn --arg sha "$stack_sha" '{units:[
  {id:"issue-1",issue:1,lane:"pr",pr:101,branch:"agent/issue-1",stage:"ready-to-merge",approved_sha:$sha,reviewed_pr_head:$sha,history:[]},
  {id:"issue-2",issue:2,lane:"pr",branch:"agent/issue-2",labels:["stack-pilot"],stage:"blocked-external",blocked_on:1,history:[]}
]}')"
release_dependency_blocks
[[ "$(field issue-2 .stage)" == implement-pending \
  && "$(field issue-2 '.history[-1].stage')" == stacked_on \
  && "$(field issue-2 '.history[-1].result')" == "issue-1@$stack_sha" \
  && "$(field issue-2 .stacked_on_sha)" == "$stack_sha" ]] \
  || fail 'approved predecessor did not dispatch its labelled dependent on the approved head'
printf '0\n' > "$A/dep-check.epoch"
units "$(jq -cn --arg sha "$stack_sha" '{units:[
  {id:"issue-1",issue:1,lane:"pr",pr:101,branch:"agent/issue-1",stage:"ready-to-merge",approved_sha:$sha,reviewed_pr_head:$sha,history:[]},
  {id:"issue-2",issue:2,lane:"pr",branch:"agent/issue-2",stage:"blocked-external",blocked_on:1,history:[]}
]}')"
release_dependency_blocks
[[ "$(field issue-2 .stage)" == blocked-external && "$(field issue-2 '.stacked_on // "none"')" == none ]] \
  || fail 'unit without the pilot label changed its dependency behavior'
stack_cfg_real="$CFG"; CFG="$(jq '.stacking.enabled=false' <<<"$CFG")"
printf '0\n' > "$A/dep-check.epoch"
units "$(jq -cn --arg sha "$stack_sha" '{units:[
  {id:"issue-1",issue:1,lane:"pr",pr:101,branch:"agent/issue-1",stage:"ready-to-merge",approved_sha:$sha,reviewed_pr_head:$sha,history:[]},
  {id:"issue-2",issue:2,lane:"pr",branch:"agent/issue-2",labels:["stack-pilot"],stage:"blocked-external",blocked_on:1,history:[]}
]}')"
release_dependency_blocks
[[ "$(field issue-2 .stage)" == blocked-external && "$(field issue-2 '.stacked_on // "none"')" == none ]] \
  || fail 'the autopilot stacking switch did not disable the pilot label'
CFG="$stack_cfg_real"
printf '0\n' > "$A/dep-check.epoch"
eval "$dep_states_real"
eval "$pr_view_real"
eval "$stack_initial_branch_real"
unset -f gh

# Fetching a review target must leave only the object in the clone, not a PR remote-tracking ref.
pr_fetch_fixture="$fixture/pr-fetch"
mkdir -p "$pr_fetch_fixture"
command git init -q --bare "$pr_fetch_fixture/remote.git"
command git init -q -b main "$pr_fetch_fixture/source"
command git -C "$pr_fetch_fixture/source" config user.email t@example.invalid
command git -C "$pr_fetch_fixture/source" config user.name t
mkdir -p "$pr_fetch_fixture/source/packages/fixture" "$pr_fetch_fixture/source/packages/dependent"
cat > "$pr_fetch_fixture/source/pnpm-workspace.yaml" <<'YAML'
packages:
  - packages/*
YAML
cat > "$pr_fetch_fixture/source/package.json" <<'JSON'
{"private":true}
JSON
cat > "$pr_fetch_fixture/source/packages/fixture/package.json" <<'JSON'
{"name":"@stub/fixture","version":"1.0.0","scripts":{"test":"vitest run"}}
JSON
cat > "$pr_fetch_fixture/source/packages/dependent/package.json" <<'JSON'
{"name":"@stub/dependent","version":"1.0.0","scripts":{"test":"vitest run"},"dependencies":{"@stub/fixture":"workspace:*"}}
JSON
command git -C "$pr_fetch_fixture/source" add package.json pnpm-workspace.yaml packages/fixture/package.json packages/dependent/package.json
command git -C "$pr_fetch_fixture/source" commit -q -m base
pr_fetch_base="$(command git -C "$pr_fetch_fixture/source" rev-parse HEAD)"
command git -C "$pr_fetch_fixture/source" remote add origin "$pr_fetch_fixture/remote.git"
command git -C "$pr_fetch_fixture/source" push -q origin main
command git --git-dir="$pr_fetch_fixture/remote.git" symbolic-ref HEAD refs/heads/main
command git -C "$pr_fetch_fixture/source" checkout -q -b topic
command git -C "$pr_fetch_fixture/source" commit -q --allow-empty -m PR-head
pr_fetch_head="$(command git -C "$pr_fetch_fixture/source" rev-parse HEAD)"
command git -C "$pr_fetch_fixture/source" push -q origin HEAD:refs/heads/topic
command git --git-dir="$pr_fetch_fixture/remote.git" update-ref refs/pull/40/head "$pr_fetch_head"
command git clone -q "$pr_fetch_fixture/remote.git" "$pr_fetch_fixture/clone"
checkout_pr_head "$pr_fetch_fixture/clone" 40 "$pr_fetch_head" "$pr_fetch_head" || fail 'checkout_pr_head failed'
if command git -C "$pr_fetch_fixture/clone" show-ref --verify --quiet refs/remotes/origin/pr/40; then
  fail 'review fetch retained a PR remote-tracking ref'
fi
command git --git-dir="$pr_fetch_fixture/remote.git" update-ref refs/pull/40/head "$pr_fetch_base"
if checkout_pr_head "$pr_fetch_fixture/clone" 40 "$pr_fetch_head" "$pr_fetch_head"; then
  fail 'review checkout accepted a PR head that moved after observation'
fi
command git --git-dir="$pr_fetch_fixture/remote.git" update-ref refs/pull/40/head "$pr_fetch_head"
command git -C "$pr_fetch_fixture/clone" config user.email t@example.invalid
command git -C "$pr_fetch_fixture/clone" config user.name t
command git -C "$pr_fetch_fixture/clone" checkout -q -b local-repair "$pr_fetch_head"
command git -C "$pr_fetch_fixture/clone" commit -q --allow-empty -m local-repair
pr_fetch_candidate="$(command git -C "$pr_fetch_fixture/clone" rev-parse HEAD)"
checkout_pr_head "$pr_fetch_fixture/clone" 40 "$pr_fetch_candidate" "$pr_fetch_head" \
  || fail 'review checkout rejected a local repair descendant of the observed PR head'
[[ "$(command git -C "$pr_fetch_fixture/clone" rev-parse HEAD)" == "$pr_fetch_candidate" ]] \
  || fail 'review clone did not check out the local repair candidate'

precheck_clone="$pr_fetch_fixture/precheck-clone"
command git clone -q "$pr_fetch_fixture/remote.git" "$precheck_clone"

command git -C "$pr_fetch_fixture/source" checkout -q main
command git -C "$pr_fetch_fixture/source" commit -q --allow-empty -m main-update
pr_fetch_main_update="$(command git -C "$pr_fetch_fixture/source" rev-parse HEAD)"
command git -C "$pr_fetch_fixture/source" push -q origin main
command git -C "$precheck_clone" fetch -q origin main
if ! ( ROOT="$precheck_clone"; pr_behind_main 40 "$pr_fetch_head" ); then
  fail 'slot sync did not identify a PR head behind main'
fi
command git --git-dir="$pr_fetch_fixture/remote.git" update-ref refs/pull/40/head "$pr_fetch_base"
if ( ROOT="$precheck_clone"; pr_behind_main 40 "$pr_fetch_head" ); then
  fail 'slot sync accepted a PR head that moved after observation'
fi

command git -C "$pr_fetch_fixture/source" checkout -q topic
command git -C "$pr_fetch_fixture/source" merge -q --no-ff main -m update-branch
pr_fetch_updated_head="$(command git -C "$pr_fetch_fixture/source" rev-parse HEAD)"
command git -C "$pr_fetch_fixture/source" push -q origin HEAD:refs/heads/topic
command git --git-dir="$pr_fetch_fixture/remote.git" update-ref refs/pull/40/head "$pr_fetch_updated_head"
( ROOT="$precheck_clone"; approval_carries 40 "$pr_fetch_head" "$pr_fetch_updated_head" ) \
  || fail 'approval was not carried across a clean main update'
if command git -C "$precheck_clone" show-ref --verify --quiet refs/remotes/origin/pr/40; then
  fail 'approval check retained a PR remote-tracking ref'
fi
command git --git-dir="$pr_fetch_fixture/remote.git" update-ref refs/pull/40/head "$pr_fetch_base"
if ( ROOT="$precheck_clone"; approval_carries 40 "$pr_fetch_head" "$pr_fetch_updated_head" ); then
  fail 'approval was carried after the PR head moved'
fi

H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
M1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
M2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
M3=cccccccccccccccccccccccccccccccccccccccc

# ---------- 结论解析：只认唯一的整行 VERDICT；旧报告和统一契约都可读 ----------
AUTO_POLICY_FIX="$fixture/policy.mjs"
cat > "$AUTO_POLICY_FIX" <<'JS'
import { readFileSync } from 'node:fs';
const paths = JSON.parse(process.argv[3] === '-' ? readFileSync(0, 'utf8') : process.argv[3]);
console.log(paths.every((p) => !p.startsWith('packages/') && !p.startsWith('.github/')) ? 'eligible' : 'not-eligible');
JS
POLICY_SCRIPT="$AUTO_POLICY_FIX"
r="$fixture/r.md"
printf '总结论（APPROVE / REQUEST-CHANGES / BLOCK）\n' > "$r"; [[ -z "$(verdict_of "$r")" ]] || fail 'template echo parsed as a verdict'
printf '不能 APPROVE，需要修改\n' > "$r"; [[ -z "$(verdict_of "$r")" ]] || fail 'prose APPROVE parsed as a verdict'
printf 'VERDICT: APPROVE / VERDICT: BLOCK\n' > "$r"; [[ -z "$(verdict_of "$r")" ]] || fail 'echoed option list parsed as a verdict'
printf 'VERDICT: APPROVE\nVERDICT: BLOCK\n' > "$r"; [[ -z "$(verdict_of "$r")" ]] || fail 'conflicting verdicts accepted'
printf '**VERDICT: REQUEST-CHANGES**\nbody\n' > "$r"; [[ "$(verdict_of "$r")" == NOT_READY ]] || fail 'legacy bold verdict line not parsed'
printf '# VERDICT: APPROVE\n' > "$r"; [[ "$(verdict_of "$r")" == READY ]] || fail 'legacy heading verdict line not parsed'
printf 'VERDICT: READY\n' > "$r"; [[ "$(verdict_of "$r")" == READY ]] || fail 'canonical ready verdict not parsed'
printf 'VERDICT: NOT_READY\n' > "$r"; [[ "$(verdict_of "$r")" == NOT_READY ]] || fail 'canonical not-ready verdict not parsed'
printf 'VERDICT: INPUT_INCOMPLETE\n' > "$r"; [[ "$(verdict_of "$r")" == INPUT_INCOMPLETE ]] || fail 'canonical incomplete verdict not parsed'
printf '## Verdict\nNOT_READY\n\n## Findings\n' > "$r"; [[ "$(verdict_of "$r")" == NOT_READY ]] || fail 'bare verdict under a Verdict heading not parsed'
printf '## Verdict\n**READY**\n' > "$r"; [[ "$(verdict_of "$r")" == READY ]] || fail 'bold bare verdict under a Verdict heading not parsed'
printf '## Verdict\nREADY once F1 is fixed\n' > "$r"; [[ -z "$(verdict_of "$r")" ]] || fail 'prose under a Verdict heading parsed as a verdict'
cat > "$r" <<'EOF'
Review report without a verdict line.

```review-findings
{"findings":[{"id":"F3","severity":"P1","file":"packages/example-pack/src/order-entry.ts","line":945,"rule":"Defect","status":"open","summary":"order-revision-3618 fails for the stated region.","introduced_by":"candidate","base_evidence":"The failing revision is present on the reviewed candidate."}],"dispositions":[]}
```
EOF
[[ "$(verdict_of "$r")" == NOT_READY ]] || fail 'missing verdict with an open P1 finding was not classified NOT_READY'
sed 's/"severity":"P1"/"severity":"P2"/' "$r" > "$r.p2"
[[ -z "$(verdict_of "$r.p2")" ]] || fail 'open P2 finding was treated as a missing-verdict fallback'
sed 's/"status":"open"/"status":"resolved"/' "$r" > "$r.resolved"
[[ -z "$(verdict_of "$r.resolved")" ]] || fail 'resolved P1 finding was treated as a missing-verdict fallback'
{ printf 'VERDICT: READY\nVERDICT: NOT_READY\n'; cat "$r"; } > "$r.conflicting"
[[ -z "$(verdict_of "$r.conflicting")" ]] || fail 'conflicting explicit verdicts were overridden by findings'

# ---------- 回收：批准绑定被评审的 head，会话按角色分存 ----------
alive() { [[ " ${ALIVE_PIDS:-} " == *" $1 "* ]]; }
units '{"units":[{"id":"pr-1","pr":1,"stage":"review","history":[]}]}'
printf 'VERDICT: APPROVE\n' > "$sup/review-1-T1.md"
printf 'session id: 11111111-2222-3333-4444-555555555555\n' > "$sup/review-1-T1.worker.log"
jq -n --arg sha "$H1" --arg pr_head "$H2" '{workers:[{pid:4242,unit:"pr-1",type:"review",log:"review-1-T1.worker.log",report:"review-1-T1.md",sha:$sha,pr_head:$pr_head}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field pr-1 .stage)" == ready-to-merge ]] || fail 'APPROVE did not reach ready-to-merge'
[[ "$(field pr-1 .approved_sha)" == "$H1" && "$(field pr-1 .reviewed_sha)" == "$H1" \
  && "$(field pr-1 .reviewed_pr_head)" == "$H2" ]] || fail 'approved candidate and observed PR head were not recorded independently'
[[ "$(field pr-1 .review_report)" == review-1-T1.md ]] || fail 'review report not recorded'
[[ "$(field pr-1 '.session_ids.review')" == 11111111-2222-3333-4444-555555555555 ]] || fail 'review session not stored under review role'
[[ "$(jq -r '.workers[0].harvested' "$WORKERS")" == true ]] || fail 'worker not marked harvested'

# 无 VERDICT 行的报告：绝不 APPROVE；第一次重评一次，第二次才转人工
units '{"units":[{"id":"pr-2","pr":2,"stage":"review","history":[]}]}'
printf 'looks fine, APPROVE\n' > "$sup/review-2-T1.md"
jq -n --arg sha "$H1" '{workers:[{pid:4243,unit:"pr-2",type:"review",log:"x.log",report:"review-2-T1.md",sha:$sha}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field pr-2 .stage)" == review-pending && "$(field pr-2 '.approved_sha // "none"')" != "$H1" ]] || fail 'report without VERDICT line was not rerun once'
units '{"units":[{"id":"pr-2","pr":2,"stage":"review","history":[{"stage":"verdict-missing"}]}]}'
jq -n --arg sha "$H1" '{workers:[{pid:4243,unit:"pr-2",type:"review",log:"x.log",report:"review-2-T1.md",sha:$sha}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field pr-2 .stage)" == supervisor-review && "$(field pr-2 '.approved_sha // "none"')" != "$H1" ]] || fail 'second report without VERDICT line was not escalated'

# 打回/BLOCK/转人工的 PR head 不会原样合并：排队中的 CI 立即取消；热修单元不取消
cancel_stub="$(declare -f cancel_branch_runs)"; CANCELS=()
cancel_branch_runs() { CANCELS+=("$1|$2"); }
pr_view_stub="$(declare -f pr_view)"; pr_view() { [[ "$2" == headRefName ]] && echo fix/branch; }
units '{"units":[{"id":"pr-3","pr":3,"stage":"review","history":[]},{"id":"pr-4","pr":4,"stage":"review","hotpatch":true,"history":[]}]}'
printf 'VERDICT: REQUEST-CHANGES\n' > "$sup/review-3-T1.md"; printf 'VERDICT: REQUEST-CHANGES\n' > "$sup/review-4-T1.md"
jq -n --arg sha "$H1" '{workers:[{pid:4244,unit:"pr-3",type:"review",log:"x.log",report:"review-3-T1.md",sha:$sha},{pid:4245,unit:"pr-4",type:"review",log:"x.log",report:"review-4-T1.md",sha:$sha}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field pr-3 .stage)" == repair-pending && "${CANCELS[*]:-}" == "fix/branch|review requested changes; head will change" ]] || fail "request-changes did not cancel the PR's queued CI, or a hot patch was cancelled (${CANCELS[*]:-none})"
CANCELS=(); to_supervisor pr-3 "x" >/dev/null
[[ "${CANCELS[*]:-}" == "fix/branch|parked for the supervisor" ]] || fail 'supervisor escalation did not cancel the PR CI'
[[ "$(field pr-3 '.history[-1].decision.decision')" == 'Hand off to supervisor' \
  && "$(field pr-3 '.history[-1].decision.why')" == x \
  && "$(field pr-3 '.history[-1].decision.evidence')" == x \
  && "$(field pr-3 '.history[-1].decision.rejected[0]')" == 'Continue automated handling' \
  && "$(field pr-3 '.history[-1].decision.owner')" == scheduler ]] || fail 'supervisor handoff did not record its structured decision'

# 打回时把结构化发现记进台账（.review_findings，每次打回一条）：只记 P0/P1 及其状态；块缺失或畸形记为 missing，
# 打回照常进入 repair-pending（81% 的 Claude 打回报告没有块，缺失必须看得见，不能当成零发现）。
fence='```'
findings_report() { # 文件 块内容（空串 = 不写块）
  printf 'VERDICT: REQUEST-CHANGES\n\n## 阻断\nF1 总额算错\n' > "$sup/$1"
  if [[ -n "$2" ]]; then printf '\n%sreview-findings\n%s\n%s\n' "$fence" "$2" "$fence" >> "$sup/$1"; fi
}
harvest_rc() { # 单元 报告 [worker 类型] —— 以 history 里已有 1 次打回的单元收割一份打回报告
  units "{\"units\":[{\"id\":\"$1\",\"stage\":\"review\",\"history\":[{\"stage\":\"review-request-changes\",\"at\":\"2026-10-19T10:00:00Z\"}]}]}"
  jq -n --arg u "$1" --arg r "$2" --arg t "${3:-review}" --arg sha "$H1" '{workers:[{pid:4300,unit:$u,type:$t,log:"x.log",report:$r,sha:$sha}]}' > "$WORKERS"
  harvest_workers || :
}

# issue-2741, 2026-10-28 18:31Z: an absent VERDICT line must not hide the concrete F3 repair.
issue_2741_report='review-4005-20261028T182435Z.md'
cat > "$sup/$issue_2741_report" <<'EOF'
Review of order-revision-3618. The deterministic self-check was red.

```review-findings
{"findings":[{"id":"F3","severity":"P1","file":"packages/example-pack/src/order-entry.ts","line":945,"rule":"Defect","status":"open","summary":"order-revision-3618 fails for the stated region.","introduced_by":"candidate","base_evidence":"The failing revision is present on the reviewed candidate."}],"dispositions":[]}
```
EOF
issue_2741_gh_saved="$(declare -f gh 2>/dev/null || true)"; ISSUE_2741_COMMENTS=()
gh() { [[ "$1 $2" != 'issue comment' ]] || ISSUE_2741_COMMENTS+=("$*"); return 0; }
units "$(jq -cn --argjson history '[{"stage":"supervisor-escalated","result":"review worker tool denial"},{"stage":"verdict-missing","result":"review-4005-20261028T182435Z.md"}]' \
  '{units:[{id:"issue-2741",issue:2741,stage:"review",self_check_status:"red",self_check_output:"self-check failed: order-revision-3618",history:$history}]}')"
jq -n --arg report "$issue_2741_report" --arg sha "$H1" \
  '{workers:[{pid:439400,unit:"issue-2741",type:"review",log:"issue-2741.worker.log",report:$report,sha:$sha}]}' > "$WORKERS"
harvest_workers || :
if [[ -n "$issue_2741_gh_saved" ]]; then eval "$issue_2741_gh_saved"; else unset -f gh; fi
[[ "$(field issue-2741 .stage)" == repair-pending \
  && "$(field issue-2741 .repair_hint)" == *F3* \
  && "$(field issue-2741 .repair_hint)" == *order-revision-3618* \
  && "$(field issue-2741 '.history[-1].stage')" == review-request-changes \
  && "$(field issue-2741 '.review_findings[0].findings[0].id')" == F3 \
  && ${#ISSUE_2741_COMMENTS[@]} == 0 ]] \
  || fail "issue-2741 missing-verdict replay did not enter repair with F3 and no comment (stage=$(field issue-2741 .stage), hint=$(field issue-2741 .repair_hint), comments=${ISSUE_2741_COMMENTS[*]:-none})"

# A real needs-info decision from finish-first writes both the comment and label; unreachable states are parked without a question.
mkdir -p "$AGENT_HOME/state"
printf '%s\n' '{"state":"finish-first"}' > "$AGENT_HOME/state/2742.json"
printf '%s\n' '{"state":"awaiting-release"}' > "$AGENT_HOME/state/2743.json"
printf '%s\n' '{"state":"finish-first","tracker_parent":true}' > "$AGENT_HOME/state/2744.json"
scheduler_issue_transition_saved="$(declare -f scheduler_issue_transition)"
needs_info_gh_saved="$(declare -f gh 2>/dev/null || true)"
NEEDS_INFO_ACTIONS=()
gh() {
  if [[ "$1 $2" == 'issue comment' ]]; then NEEDS_INFO_ACTIONS+=("comment:$3"); fi
  return 0
}
scheduler_issue_transition() {
  local issue="$1" to="$2" reason="$3" state_file="$AGENT_HOME/state/$1.json"
  scheduler_issue_transition_allowed "$issue" "$to" "$reason" || return 1
  jqf --arg state "$to" '.state=$state' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  NEEDS_INFO_ACTIONS+=("label:$issue:$to")
}
scheduler_issue_transition_allowed 2742 needs-info supervisor-needs-info \
  || fail 'finish-first did not permit the needs-info transition'
if scheduler_issue_transition_allowed 2742 needs-info unrelated; then
  fail 'finish-first needs-info transition accepted a non-supervisor reason'
fi
units '{"units":[{"id":"issue-2742","issue":2742,"stage":"supervisor-review","history":[]}]}'
supervisor_needs_info issue-2742 'Which contract version is required?' 'arbiter found a missing product requirement'
[[ "$(jqf -r .state "$AGENT_HOME/state/2742.json")" == needs-info \
  && "$(field issue-2742 .stage)" == needs-human \
  && "${NEEDS_INFO_ACTIONS[*]}" == 'comment:2742 label:2742:needs-info' ]] \
  || fail "finish-first needs-info did not land the question and label together (state=$(jqf -r .state "$AGENT_HOME/state/2742.json"), unit=$(field issue-2742 .stage), actions=${NEEDS_INFO_ACTIONS[*]:-none})"
NEEDS_INFO_ACTIONS=()
units '{"units":[{"id":"issue-2743","issue":2743,"stage":"supervisor-review","history":[]}]}'
supervisor_needs_info issue-2743 'Which contract version is required?' 'arbiter asked for a requirement'
[[ "$(jqf -r .state "$AGENT_HOME/state/2743.json")" == awaiting-release \
  && "$(field issue-2743 .stage)" == parked \
  && "$(field issue-2743 '.history[-1].stage')" == supervisor-park \
  && ${#NEEDS_INFO_ACTIONS[@]} == 0 ]] \
  || fail "unreachable needs-info transition posted a question or was not parked (state=$(jqf -r .state "$AGENT_HOME/state/2743.json"), unit=$(field issue-2743 .stage), actions=${NEEDS_INFO_ACTIONS[*]:-none})"
NEEDS_INFO_ACTIONS=()
units '{"units":[{"id":"issue-2744","issue":2744,"stage":"supervisor-review","history":[]}]}'
supervisor_needs_info issue-2744 'Which contract version is required?' 'arbiter asked for a requirement'
[[ "$(jqf -r .state "$AGENT_HOME/state/2744.json")" == finish-first \
  && "$(field issue-2744 .stage)" == parked \
  && ${#NEEDS_INFO_ACTIONS[@]} == 0 ]] \
  || fail "tracker parent was asked despite refusing active state labels (unit=$(field issue-2744 .stage), actions=${NEEDS_INFO_ACTIONS[*]:-none})"
eval "$scheduler_issue_transition_saved"
if [[ -n "$needs_info_gh_saved" ]]; then eval "$needs_info_gh_saved"; else unset -f gh; fi

good_block='{"findings":[{"id":"F1","severity":"P1","file":"src/a.ts","line":42,"rule":"Defect","status":"open","summary":"x","introduced_by":"candidate","base_evidence":"New branch is absent from origin/main."},
{"id":"F2","severity":"P0","file":"src/路径 c.ts","line":9,"rule":"Spec","status":"resolved","summary":"fixed \"quoted\"","introduced_by":"pre_existing","base_evidence":"The same behavior is present at src/路径 c.ts:7 on origin/main."}],"dispositions":[]}'
good_block="$(jq -c '.findings += [{id:"F3",severity:"P3",file:"src/style.ts",line:3,rule:"Maintainability",status:"open",summary:"Simplify this helper.",introduced_by:"candidate",base_evidence:"The helper was added on this branch."}]' <<<"$good_block")"
findings_report rf-1-T1.md "$good_block"
harvest_rc pr-f1 rf-1-T1.md
[[ "$(field pr-f1 .stage)" == repair-pending ]] || fail 'a rejection with a findings block did not reach repair-pending'
[[ "$(field pr-f1 '.review_findings | length')" == 1 \
  && "$(field pr-f1 '.review_findings[0].findings | map(.id) | join(",")')" == F1,F2 \
  && "$(field pr-f1 '.review_findings[0].all_findings | map(.id) | join(",")')" == F1,F2,F3 \
  && "$(field pr-f1 '.review_findings[0].all_findings[2].severity')" == P3 ]] \
  || fail "blocking and complete finding IDs were not recorded per round: $(field pr-f1 '.review_findings | tojson')"
[[ "$(field pr-f1 '.review_findings[0].at')" == "$STAMP" ]] || fail 'findings record lacks the rejection time'
findings_report rf-2-T1.md "$good_block"
harvest_rc pr-f2 rf-2-T1.md rereview
[[ "$(field pr-f2 '.review_findings[0].block')" == ok && "$(field pr-f2 .stage)" == repair-pending ]] || fail 'a rereview rejection was not recorded like a review rejection'
findings_report rf-3-T1.md '[]'
harvest_rc pr-f3 rf-3-T1.md
[[ "$(field pr-f3 '.review_findings[0] | [.block, (.findings | length)] | tojson')" == '["ok",0]' ]] || fail 'an empty findings block was not recorded as present with no findings'
# Legacy array reports on disk still deserialize, with attribution left unknown rather than invented.
findings_report rf-legacy-T1.md '[{"id":"F1","severity":"P1","file":"src/old.ts","line":3,"status":"open"}]'
harvest_rc pr-legacy rf-legacy-T1.md
[[ "$(field pr-legacy '.review_findings[0] | [.block, .findings[0].introduced_by, .findings[0].base_evidence] | tojson')" == '["ok",null,null]' ]] \
  || fail 'a legacy findings array was not preserved as unattributed history'
# 缺失、畸形一律记 missing（findings 为空），打回不受影响
findings_report rf-4-T1.md ''
harvest_rc pr-f4 rf-4-T1.md
[[ "$(field pr-f4 '.review_findings[0] | [.block, (.findings | length)] | tojson')" == '["missing",0]' && "$(field pr-f4 .stage)" == repair-pending ]] || fail 'a rejection without a findings block was not recorded as missing'
n=0
for bad in 'not json' '{"id":"F1"}' '[{"id":"F1","severity":"P1","line":42,"status":"open"}]' '[{"id":"F1","severity":"P9","file":"a.ts","line":1,"status":"open"}]' \
  '[{"id":"F1","severity":"P1","file":"a.ts","line":"42","status":"open"}]' '[{"id":"F1","severity":"P1","file":"a.ts","line":1,"status":"maybe"}]'; do
  n=$((n+1)); findings_report "rf-bad-$n-T1.md" "$bad"; harvest_rc "pr-fb$n" "rf-bad-$n-T1.md"
  [[ "$(field "pr-fb$n" '.review_findings[0].block')" == missing && "$(field "pr-fb$n" .stage)" == repair-pending ]] || fail "malformed findings block not counted as missing: $bad"
done
bad_canonical='{"findings":[{"id":"F1","severity":"P1","file":"a.ts","line":1,"rule":"Defect","status":"open","summary":"x","introduced_by":"candidate"}],"dispositions":[]}'
findings_report rf-bad-canonical-T1.md "$bad_canonical"
harvest_rc pr-bad-canonical rf-bad-canonical-T1.md
[[ "$(field pr-bad-canonical '.review_findings[0].block')" == missing ]] \
  || fail 'a canonical finding without base evidence was accepted'
{ printf 'VERDICT: REQUEST-CHANGES\n\n%sreview-findings\n[{"id":"F1","severity":"P1","file":"a.ts","line":1,"status":"open"}]\n' "$fence"; } > "$sup/rf-open-T1.md"
harvest_rc pr-fopen rf-open-T1.md
[[ "$(field pr-fopen '.review_findings[0].block')" == missing ]] || fail 'a findings block that is never closed was accepted'
# 有块与无块的单元阶段流转完全一致：只多出 review_findings
findings_report rf-5-T1.md "$good_block"; harvest_rc pr-same rf-5-T1.md; with_block="$(field pr-same 'del(.review_findings,.repair_hint) | tojson')"
[[ "$(field pr-same '.repair_hint // empty')" == 'F1 src/a.ts:42 — x' ]] || fail 'open P1 finding was not copied into the repair hint'
findings_report rf-5-T1.md ''; harvest_rc pr-same rf-5-T1.md; without_block="$(field pr-same 'del(.review_findings,.repair_hint) | tojson')"
[[ "$with_block" == "$without_block" && "$(field pr-same .stage)" == repair-pending \
  && -z "$(field pr-same '.repair_hint // empty')" ]] || fail "findings block changed more than repair evidence: $with_block vs $without_block"
# Author dispositions are attached to the existing unit finding history and included in rereview context.
disposition_report="$sup/repair-dispositions-T1.md"
printf 'Repair delivered.\n\n%sreview-findings\n{"findings":[],"dispositions":[{"id":"F1","disposition":"fixed","reason":"The query now binds the authenticated tenant before returning records."}]}\n%s\n' "$fence" "$fence" > "$disposition_report"
units '{"units":[{"id":"pr-disposition","stage":"repair","author_dispositions_pending":true,"history":[{"stage":"review-request-changes"}],"review_findings":[{"round":1,"report":"review.md","block":"ok","findings":[{"id":"F1","severity":"P1","file":"src/a.ts","line":42,"rule":"Defect","status":"open","summary":"tenant read","introduced_by":"candidate","base_evidence":"absent in base"}],"dispositions":[]}] }]}'
jq -n --arg report "$(basename "$disposition_report")" --arg sha "$H1" '{workers:[{pid:4302,unit:"pr-disposition",type:"repair",log:"repair-dispositions.worker.log",report:$report,sha:$sha}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field pr-disposition '.review_findings[0].disposition_block')" == ok \
  && "$(field pr-disposition .author_dispositions_pending)" == false \
  && "$(field pr-disposition .stage)" == rereview-pending ]] || fail 'repair disposition was not persisted before rereview'
disposition_context="$(review_dispositions_context "$(jq -c '.units[0]' "$UNITS")")"
[[ "$disposition_context" == *"F1: fixed"* && "$disposition_context" == *"binds the authenticated tenant"* ]] \
  || fail 'rereview context omitted the persisted author disposition'
# A later CI repair does not overwrite dispositions from an earlier review repair.
ci_repair_report="$sup/ci-repair-after-review-T1.md"
printf 'CI repair delivered.\n' > "$ci_repair_report"
units '{"units":[{"id":"pr-ci-repair","stage":"repair","history":[{"stage":"ci-red"}],"review_findings":[{"disposition_block":"ok","dispositions":[{"id":"F1","disposition":"fixed","reason":"review repair already recorded"}]}]}]}'
jq -n --arg report "$(basename "$ci_repair_report")" --arg sha "$H1" '{workers:[{pid:4304,unit:"pr-ci-repair",type:"repair",log:"ci-repair.worker.log",report:$report,sha:$sha}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field pr-ci-repair '.review_findings[0].dispositions[0].reason')" == 'review repair already recorded' \
  && "$(field pr-ci-repair '.review_findings[0].disposition_block')" == ok ]] \
  || fail 'a CI repair replaced stored author dispositions with a missing review response'
# An incomplete author response stays visible while the normal rereview continues.
incomplete_disposition_report="$sup/repair-incomplete-dispositions-T1.md"
printf '%sreview-findings\n{"findings":[],"dispositions":[]}\n%s\n' "$fence" "$fence" > "$incomplete_disposition_report"
units '{"units":[{"id":"pr-incomplete-disposition","stage":"repair","author_dispositions_pending":true,"history":[],"review_findings":[{"findings":[{"id":"F1"}],"all_findings":[{"id":"F1"},{"id":"F2"}]}]}]}'
jq -n --arg report "$(basename "$incomplete_disposition_report")" --arg sha "$H1" '{workers:[{pid:4303,unit:"pr-incomplete-disposition",type:"repair",log:"repair-incomplete.worker.log",report:$report,sha:$sha}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field pr-incomplete-disposition '.review_findings[0].disposition_block')" == incomplete \
  && "$(field pr-incomplete-disposition .author_dispositions_pending)" == false \
  && "$(field pr-incomplete-disposition .stage)" == rereview-pending ]] || fail 'missing finding disposition was hidden or became a new merge gate'
# 批准不记录发现
{ printf 'VERDICT: APPROVE\n\n%sreview-findings\n[]\n%s\n' "$fence" "$fence"; } > "$sup/rf-6-T1.md"
units '{"units":[{"id":"pr-fa","stage":"review","history":[]}]}'
jq -n --arg sha "$H1" '{workers:[{pid:4301,unit:"pr-fa",type:"review",log:"x.log",report:"rf-6-T1.md",sha:$sha,pr_head:$sha}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field pr-fa 'has("review_findings")')" == false ]] || fail 'an approval wrote a findings record'
eval "$cancel_stub"; eval "$pr_view_stub"

# Old approval workers without the separately captured PR head fail closed.
units '{"units":[{"id":"pr-2b","pr":2,"stage":"review","history":[]}]}'
printf 'VERDICT: APPROVE\n' > "$sup/review-2b-T1.md"
jq -n --arg sha "$H1" '{workers:[{pid:4243,unit:"pr-2b",type:"review",log:"x.log",report:"review-2b-T1.md",sha:$sha}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field pr-2b .stage)" == supervisor-review && "$(field pr-2b '.approved_sha // "none"')" == none ]] || fail 'approval without a captured PR head was accepted'

# 无产出死亡：到上限先换全新会话重试一次，再死才转人工
units '{"units":[{"id":"pr-3","pr":3,"stage":"review","session_ids":{"review":"s1"},"history":[{"stage":"worker-no-output","result":"review","at":"x"}]}]}'
jq -n '{workers:[{pid:4244,unit:"pr-3",type:"review",log:"none.log",report:"missing.md"}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field pr-3 .stage)" == review-pending && "$(field pr-3 '.session_ids | length')" == 0 ]] || fail 'second zero-output death did not get one fresh-session retry'
jq -n '{workers:[{pid:4245,unit:"pr-3",type:"review",log:"none.log",report:"missing.md"}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field pr-3 .stage)" == supervisor-review ]] || fail 'death after the fresh-session retry did not stop redispatch'

# 运行中的 repair 不会因旧修复报告存在而被提前推进
units '{"units":[{"id":"pr-4","pr":4,"stage":"repair","history":[]}]}'
printf 'old fix\n' > "$sup/impl-4-fix.md"
jq -n '{workers:[{pid:5000,unit:"pr-4",type:"repair",log:"impl-4-fix-T2.worker.log",report:"impl-4-fix-T2.md"}]}' > "$WORKERS"
ALIVE_PIDS=5000
harvest_workers || :; recover_orphans || :
[[ "$(field pr-4 .stage)" == repair ]] || fail 'live repair advanced on a stale report'
ALIVE_PIDS=""
# 竞态：worker 在收割判活之后退出，孤儿自愈不得再派（下一拍收割它的报告）；记录收割后无记录才回 pending
units '{"units":[{"id":"pr-4","pr":4,"stage":"repair","history":[]}]}'
jq -n '{workers:[{pid:5001,unit:"pr-4",type:"repair",log:"impl-4-fix-T3.worker.log",report:"impl-4-fix-T3.md"}]}' > "$WORKERS"
recover_orphans || :
[[ "$(field pr-4 .stage)" == repair ]] || fail 'worker that exited after the harvest check was re-dispatched as an orphan'
jq -n '{workers:[{pid:5001,unit:"pr-4",type:"repair",harvested:true}]}' > "$WORKERS"
recover_orphans || :
[[ "$(field pr-4 .stage)" == repair-pending ]] || fail 'unit without any unharvested worker record was not recovered'

# ---------- 派发：复审基线、回合断路 ----------
GH_HEAD="$H1"; GH_STATE=OPEN; GH_MERGE_SHA=""; GH_RUNS='[]'; GH_LOG=""
GH_MERGES=(); GH_RERUNS=()
# PR runner 名额（60ba960cf）：默认 1 个在线 PR runner；离线和非 PR 池（cihost-ci-main）的不算。
# GH_RUNNERS 是 actions/runners 的响应体，应答时套调用方的 --jq；GH_RUN_JOBS 按 run id 给 {jobs:[...]}。
GH_RUNNERS='{"runners":[{"id":1,"status":"online","labels":[{"name":"cihost-ci"}]},{"id":2,"status":"offline","labels":[{"name":"cihost-ci"}]},{"id":3,"status":"online","labels":[{"name":"cihost-ci-main"}]}]}'
GH_RUN_JOBS='{}'
GH_CHECKS_PASS='[{"name":"ci","bucket":"pass"}]'
# open PR 表放在文件里（$(...) 和后台任务里的调用也算数）。用例把 GH_PR_TABLE 指到一个文件才打开；
# 没指时 `gh pr list` 照旧不出声。列表和真 CLI 一样：只回 --json 要的字段，再套 --jq。
GH_PR_CALLS="$fixture/gh-pr-calls"
gh_pr_open() { # number head draft(true|false) mergeable branch [statusCheckRollup-json]
  local t; t="$(jq -c --argjson n "$1" --arg h "$2" --argjson d "$3" --arg m "$4" --arg b "$5" --argjson r "${6:-[]}" \
    '. += [{number:$n, headRefOid:$h, isDraft:$d, mergeable:$m, headRefName:$b, labels:[], statusCheckRollup:$r}]' "$GH_PR_TABLE")" && printf '%s\n' "$t" > "$GH_PR_TABLE"
}
gh_pr_is_draft() { jq -r --argjson n "$1" '.[] | select(.number == $n) | .isDraft' "$GH_PR_TABLE"; }
gh_pr_list() { # pr list ... [--json fields] [--jq expr]
  local fields="" query="." n c rows='[]'
  echo "$*" >> "$GH_PR_CALLS"
  if [[ -z "${GH_PR_TABLE:-}" ]]; then
    # No table: the census check rows come from the per-PR `pr checks` stub, heads left unknown (the lane then asks pr view).
    [[ "$*" == *statusCheckRollup* ]] || return 0
    while (( $# )); do case "$1" in --jq) query="$2" ;; esac; shift; done
    for n in $(jq -r '.units[] | select(.stage == "ready-to-merge" and .pr != null) | .pr' "$UNITS"); do
      c="$(gh pr checks "$n" --json name,bucket,link 2>/dev/null)"
      rows="$(jq -c --argjson n "$n" --argjson c "${c:-[]}" '. += [{number: $n, headRefOid: null, isDraft: false, statusCheckRollup: ($c | map({__typename: "CheckRun", name: .name, detailsUrl: (.link // ""), startedAt: (.started_at // null), status: (if .bucket == "pending" then "IN_PROGRESS" else "COMPLETED" end), conclusion: ({pass: "SUCCESS", fail: "FAILURE", skipping: "SKIPPED", neutral: "NEUTRAL", cancel: "CANCELLED"}[.bucket] // null)}))}]' <<<"$rows")"
    done
    jq -cr "$query" <<<"$rows"
    return 0
  fi
  while (( $# )); do case "$1" in --json) fields="$2" ;; --jq) query="$2" ;; esac; shift; done
  jq -c --arg f "$fields" '($f | split(",")) as $k | map(with_entries(select(.key as $x | $k | index($x))))' "$GH_PR_TABLE" | jq -cr "$query"
}
gh_pr_ready() { # number [--undo]：幂等，已在目标状态也成功
  local t; echo "pr ready $*" >> "$GH_PR_CALLS"
  [[ -n "${GH_PR_TABLE:-}" ]] || return 0
  t="$(jq -c --argjson n "$1" --argjson d "$([[ "${2:-}" == --undo ]] && echo true || echo false)" 'map(if .number == $n then .isDraft = $d else . end)' "$GH_PR_TABLE")" \
    && printf '%s\n' "$t" > "$GH_PR_TABLE"
}
gated_unit() { # id pr branch approved_sha → 一个 ready-to-merge 单元行，标成调度器自己的（gated）
  jq -cn --arg id "$1" --argjson pr "$2" --arg b "$3" --arg s "$4" '{id:$id, pr:$pr, branch:$b, stage:"ready-to-merge", approved_sha:$s, gated:true, history:[]}'
}
gh() {
  case "$1 $2" in
    "pr list") gh_pr_list "$@" ;;
    "pr ready") shift 2; gh_pr_ready "$@" ;;
    "pr edit")
      printf '%s\n' "$*" >> "$fixture/pr-edit.calls"
      local edit_status="${GH_PR_EDIT_STATUS:-0}"
      [[ "$edit_status" == 0 ]] || return "$edit_status"
      if [[ -n "${GH_PR_TABLE:-}" ]]; then
        local updated_table
        case "$4" in
          --remove-label)
            updated_table="$(jq -c --argjson n "$3" --arg label "$5" 'map(if .number == $n then .labels = [(.labels // [])[] | select(.name != $label)] else . end)' "$GH_PR_TABLE")" ;;
          --add-label)
            updated_table="$(jq -c --argjson n "$3" --arg label "$5" 'map(if .number == $n then .labels = ((.labels // []) | map(select(.name != $label)) + [{name:$label}]) else . end)' "$GH_PR_TABLE")" ;;
        esac
        [[ -z "${updated_table:-}" ]] || printf '%s\n' "$updated_table" > "$GH_PR_TABLE"
      fi
      return 0 ;;
    "pr update-branch") echo "$*" >> "$GH_PR_CALLS" ;;
    "pr view")
      case "$5" in
        headRefOid) echo "$GH_HEAD" ;; state) echo "$GH_STATE" ;; headRefName) echo "fix/branch" ;;
        mergeCommit) echo "$GH_MERGE_SHA" ;; *) echo "" ;;
      esac ;;
    "pr checks") echo "${GH_CHECKS:-$GH_CHECKS_PASS}" ;;
    "pr merge") GH_MERGES+=("$*") ;;
    "run list")
      if [[ -n "${GH_RUN_JSON:-}" ]]; then # apply the caller's --jq filter to canned run records
        local jq_expr=""; while [[ $# -gt 0 ]]; do [[ "$1" == --jq ]] && jq_expr="$2"; shift; done
        jq -r "${jq_expr:-.[] | .databaseId}" <<<"$GH_RUN_JSON"
      else echo "$GH_RUNS"; fi
      return "${GH_RUN_LIST_FAIL:-0}" ;;
    "run rerun") GH_RERUNS+=("$*"); [[ -z "${GH_RERUN_FAIL_ID:-}" || "$3" != "$GH_RERUN_FAIL_ID" ]] || return 1; return "${GH_RERUN_FAIL:-0}" ;;
    'api repos/example-maintainer/example-repo/issues/'*'/sub_issues?per_page=100') echo '[]' ;;
    "api --paginate")
      case "$3" in
        # 在线 PR runner 名额（60ba960cf）：套调用方的 --jq，让过滤表达式本身被测到
        "repos/{owner}/{repo}/actions/runners?per_page=100")
          local runners_jq="" runners_prev="" arg
          for arg in "$@"; do [[ "$runners_prev" == --jq ]] && runners_jq="$arg"; runners_prev="$arg"; done
          jq -r "${runners_jq:-.runners[].id}" <<<"$GH_RUNNERS" ;;
        # 按状态列 run（8ca4eceaa 的 unfinished_runs / ci_pr_free_slots）：从 GH_RUNS 过滤，
        # 调用方 --jq 只做形状映射，这里直接给映射后的行（run 对象或 id）
        "repos/{owner}/{repo}/actions/runs?status="*)
          local st="$3" runs_jq="" runs_prev="" arg
          st="${st#*status=}"; st="${st%%&*}"
          for arg in "$@"; do [[ "$runs_prev" == --jq ]] && runs_jq="$arg"; runs_prev="$arg"; done
          if [[ "$runs_jq" == '.workflow_runs[].id' ]]; then
            jq -r --arg st "$st" '.[] | select(.status == $st) | .databaseId' <<<"$GH_RUNS"
          else
            jq -c --arg st "$st" '.[] | select(.status == $st)' <<<"$GH_RUNS"
          fi ;;
      esac ;;
    # 一个 run 的 job 快照：[{status, runner_id}]（cd947d120 的共享缓存契约）
    "api repos/{owner}/{repo}/actions/runs/"*"/jobs"*)
      local jobs_id="$2" jobs_jq="" jobs_prev="" arg
      jobs_id="${jobs_id#*actions/runs/}"; jobs_id="${jobs_id%%/*}"
      for arg in "$@"; do [[ "$jobs_prev" == --jq ]] && jobs_jq="$arg"; jobs_prev="$arg"; done
      jq -c --arg id "$jobs_id" '.[$id] // {jobs:[]}' <<<"$GH_RUN_JOBS" | jq -r "${jobs_jq:-.}" ;;
    "run view") printf '%s\n' "$*" >> "$fixture/run-view.calls"; echo "$GH_LOG" ;;
  esac
}

# 供应商桩自检：后续票（就绪、降级、车道规则）的用例都靠它，桩错了它们会假绿。
# open PR 表只回问到的 --json 字段再套 --jq；ready/--undo 幂等（重复调用仍成功），每次调用都留痕；update-branch 留痕。
(
  GH_PR_TABLE="$fixture/gh-prs-selfcheck.json"; echo '[]' > "$GH_PR_TABLE"; : > "$GH_PR_CALLS"
  gh_pr_open 41 "$H1" true MERGEABLE agent/issue-41
  gh_pr_open 42 "$H2" false CONFLICTING hand/x
  [[ "$(gh pr list --state open --json number,headRefOid,isDraft,mergeable,headRefName --jq 'map("\(.number):\(.headRefOid[0:1]):\(.isDraft):\(.mergeable):\(.headRefName)") | join(" ")')" == "41:1:true:MERGEABLE:agent/issue-41 42:2:false:CONFLICTING:hand/x" ]] \
    || fail 'stub PR listing lacks number, head, draft state, mergeable or branch'
  [[ "$(gh pr list --json number --jq '.[0] | keys | join(",")')" == number ]] || fail 'stub PR listing returned fields that were not asked for'
  gh pr ready 41 && gh pr ready 41 || fail 'repeated ready was not idempotent'
  [[ "$(gh_pr_is_draft 41)" == false ]] || fail 'ready did not flip the PR out of draft'
  gh pr ready 41 --undo && gh pr ready 41 --undo || fail 'repeated return to draft was not idempotent'
  [[ "$(gh_pr_is_draft 41)" == true && "$(gh_pr_is_draft 42)" == false ]] || fail 'return to draft missed its PR or touched another one'
  gh pr update-branch 42 || fail 'stub update-branch failed'
  [[ "$(grep -v '^pr list' "$GH_PR_CALLS" | tr '\n' '|')" == "pr ready 41|pr ready 41|pr ready 41 --undo|pr ready 41 --undo|pr update-branch 42|" ]] || fail "stub did not record every flip and update-branch call ($(tr '\n' '|' < "$GH_PR_CALLS"))"
  [[ "$(gated_unit pr-41 41 agent/issue-41 "$H1" | jq -r '[.id, .pr, .branch, .stage, .approved_sha, .gated] | join(" ")')" == "pr-41 41 agent/issue-41 ready-to-merge $H1 true" ]] || fail 'gated unit row helper lacks a field'
)
ensure_clone() { printf '%s' "$fixture/wt-$1"; }
checkout_pr_head() { :; }
ensure_clone_stub="$(declare -f ensure_clone)"
checkout_pr_head_stub="$(declare -f checkout_pr_head)"
live_workers() { echo 0; }
live_by_type() { echo 0; }
DISPATCHED=()
dispatch() { DISPATCHED+=("$1:$4:$8"); DISPATCH_PR_HEAD="${10:-}"; DISPATCH_PROMPT="$7"; }

# The implement dispatch passes the approved predecessor ref and SHA to the isolated clone.
stack_ensure_clone_real="$(declare -f ensure_clone)"; STACK_ENSURE_ARGS=()
ensure_clone() { printf '%s\n' "$@" > "$fixture/stack-ensure.args"; printf '%s' "$fixture/repo"; }
units "$(jq -cn --arg sha "$H2" '{units:[{id:"issue-23",issue:23,lane:"pr",branch:"agent/issue-23",stage:"implement-pending",task:"continue the dependent unit",stacked_on:"issue-1@sha",stacked_on_unit:"issue-1",stacked_on_branch:"agent/issue-1",stacked_on_sha:$sha,history:[]}]}')"
dispatch_pending || :
mapfile -t STACK_ENSURE_ARGS < "$fixture/stack-ensure.args"
[[ "${DISPATCHED[0]:-}" == implement:issue-23:* && ${#STACK_ENSURE_ARGS[@]} == 6 \
  && "${STACK_ENSURE_ARGS[4]}" == agent/issue-1 && "${STACK_ENSURE_ARGS[5]}" == "$H2" ]] \
  || fail "stacked implement dispatch did not start its clone at the approved predecessor head (dispatch=${DISPATCHED[*]:-none} args=${STACK_ENSURE_ARGS[*]:-none} stage=$(field issue-23 .stage))"
eval "$stack_ensure_clone_real"
DISPATCHED=(); STACK_ENSURE_ARGS=(); rm -f "$fixture/stack-ensure.args"

# #4361：pipeline-system（direct-main）车道按文件范围并发，没有自己的单元上限。
# 两张 lane ticket 的 expected_paths 不相交 → 同一拍都派发；相交 → 后一张等待。
lane_dispatch_real="$(declare -f dispatch)"
dispatch() { # 真实 dispatch 会登记 worker；footprint_room 读 workers 台账判占用
  DISPATCHED+=("$1:$4")
  jq --argjson pid "$$" --arg unit "$4" --arg type "$1" \
    '.workers += [{pid:$pid,unit:$unit,type:$type,harvested:false}]' \
    "$WORKERS" > "$WORKERS.lane-tmp" && mv "$WORKERS.lane-tmp" "$WORKERS"
}
mkdir -p "$AGENT_HOME/state"
lane_dispatch_tick() { # path-a path-b：写入两张 lane 票的单元与 state，跑一拍派发
  jq -cn --arg pa "$1" --arg pb "$2" '{units:[
    {id:"issue-91",issue:91,lane:"direct-main",branch:"agent/auto-issue-91",stage:"implement-pending",task:"lane fix a",history:[]},
    {id:"issue-92",issue:92,lane:"direct-main",branch:"agent/auto-issue-92",stage:"implement-pending",task:"lane fix b",history:[]}]}' > "$UNITS"
  echo '{"workers":[]}' > "$WORKERS"
  printf '{"expected_paths":["%s"]}' "$1" > "$AGENT_HOME/state/91.json"
  printf '{"expected_paths":["%s"]}' "$2" > "$AGENT_HOME/state/92.json"
  DISPATCHED=()
  dispatch_pending || :
}
lane_dispatch_tick "engine/alpha.sh" "docs/agents/beta.md"
[[ ${#DISPATCHED[@]} == 2 && "$(field issue-91 .stage)" == implement && "$(field issue-92 .stage)" == implement ]] \
  || fail "disjoint pipeline-system scopes were not dispatched together (${DISPATCHED[*]:-none}, 91=$(field issue-91 .stage), 92=$(field issue-92 .stage))"
lane_dispatch_tick "engine/lib.sh" "engine/lib.sh"
[[ ${#DISPATCHED[@]} == 1 && "$(field issue-92 .stage)" == implement-pending ]] \
  || fail "overlapping pipeline-system scope did not wait (dispatched=${DISPATCHED[*]:-none}, 92=$(field issue-92 .stage))"
rm -f "$AGENT_HOME/state/91.json" "$AGENT_HOME/state/92.json" "$WORKERS.lane-tmp"
eval "$lane_dispatch_real"
DISPATCHED=()

# A stacked product unit opens its PR against the predecessor branch.
stack_gh_real="$(declare -f gh)"; stack_pr_changed_real="$(declare -f tick_prs_changed)"
stack_gated_label_real="$(declare -f ensure_gated_label)"
ensure_gated_label() { :; }
tick_prs_changed() { :; }
gh() {
  case "$1 $2" in
    'pr list') if [[ "${STACK_PR_EXISTING:-0}" == 1 ]]; then echo '102 true'; else echo ''; fi ;;
    'pr create') printf '%s\n' "$*" > "$fixture/stack-pr-create.args"; echo 'https://github.com/example/repo/pull/102' ;;
    'pr edit') printf '%s\n' "$*" >> "$fixture/stack-pr-edit.args" ;;
  esac
}
scheduler_pr_open agent/issue-23 'stack child' 'Refs #23' agent/issue-1
[[ "$SCHED_PR_NUM" == 102 && "$(cat "$fixture/stack-pr-create.args")" == *'--draft --label agent/ci-gated --base agent/issue-1'* ]] \
  || fail 'stacked unit PR did not target its predecessor branch'
STACK_PR_EXISTING=1
scheduler_pr_open agent/issue-23 'stack child' 'Refs #23' agent/issue-1
[[ "$SCHED_PR_NUM" == 102 && "$(tail -1 "$fixture/stack-pr-edit.args")" == 'pr edit 102 --base agent/issue-1' ]] \
  || fail 'an existing stacked unit PR did not retarget its predecessor branch'
eval "$stack_gh_real"; eval "$stack_pr_changed_real"; eval "$stack_gated_label_real"

units "{\"units\":[{\"id\":\"pr-5\",\"pr\":5,\"stage\":\"rereview-pending\",\"reviewed_sha\":\"$H1\",\"reviewed_pr_head\":\"$H1\",\"review_report\":\"review-5-T1.md\",\"history\":[]}]}"
dispatch_pending || :
[[ "$(field pr-5 .stage)" == rereview-pending && "$(field pr-5 .arbiter)" == true && ${#DISPATCHED[@]} == 0 ]] || fail 'unchanged head did not turn into one arbiter review'
dispatch_pending || :
[[ "${DISPATCHED[0]:-}" == review:pr-5:* && "$DISPATCH_PROMPT" == *"仲裁评审"* ]] || fail "arbiter review not dispatched as a full review (${DISPATCHED[*]:-none})"
[[ "$DISPATCH_PROMPT" == *".agents/skills/zf-code-review/SKILL.md"* ]] || fail 'arbiter review prompt does not reference the canonical review contract'
DISPATCHED=()
units "{\"units\":[{\"id\":\"pr-5\",\"pr\":5,\"stage\":\"rereview-pending\",\"reviewed_sha\":\"$H1\",\"reviewed_pr_head\":\"$H1\",\"review_report\":\"review-5-T1.md\",\"history\":[{\"stage\":\"arbiter-review\"}]}]}"
dispatch_pending || :
[[ "$(field pr-5 .stage)" == supervisor-review && ${#DISPATCHED[@]} == 0 ]] || fail 'unchanged head after an arbiter review was redispatched'
# 合并后被 revert 的单元：原 PR 已 MERGED，repair 推的提交挂不上去；repair 交付后用同一分支开新 PR（#4009 空转 4 小时）
DISPATCHED=(); gh_reopen_saved="$(declare -f gh)"
gh() { case "$1 $2" in "pr list") echo "" ;; "pr create") printf '%s' "$*" > "$fixture/reopen.args"; echo "https://github.com/example-maintainer/example-repo/pull/4100" ;; *) eval "${gh_reopen_saved/gh ()/gh_r ()}"; gh_r "$@" ;; esac; }
units "{\"units\":[{\"id\":\"issue-3451\",\"issue\":3451,\"title\":\"reply lost\",\"pr\":4009,\"branch\":\"agent/issue-3451\",\"stage\":\"rereview-pending\",\"reopen_pr\":true,\"reviewed_sha\":\"$H1\",\"reviewed_pr_head\":\"$H1\",\"history\":[{\"stage\":\"merge-reverted\"},{\"stage\":\"repair-delivered\"}]}]}"
dispatch_pending || :
[[ "$(field issue-3451 .pr):$(field issue-3451 '.reopen_pr // "none"'):$(field issue-3451 '.reviewed_sha // "none"'):$(field issue-3451 .stage)" == "4100:none:none:rereview-pending" && ${#DISPATCHED[@]} == 0 ]] \
  || fail "reverted merge not re-delivered on a new PR ($(field issue-3451 .pr) $(field issue-3451 .stage))"
[[ "$(cat "$fixture/reopen.args")" == *"--head agent/issue-3451"* && "$(cat "$fixture/reopen.args")" == *"Refs #3451"* && "$(cat "$fixture/reopen.args")" == *"Re-delivery of #4009"* ]] || fail "re-delivery PR args wrong: $(cat "$fixture/reopen.args")"
eval "$gh_reopen_saved"; DISPATCHED=()

# 尺寸准入（10-22 R2）：>800 改动行（锁文件/快照不计）的实现不开评审，连同数字转 supervisor 重切；
# 正好 800 或超出的行数都在锁文件里 → 照常开 PR（docs-only/generated-only 不因此阻断）。
sa="$fixture/size-admission"; mkdir -p "$sa"
command git init -q --bare -b main "$sa/origin.git"
command git init -q -b main "$sa/src"
sa_git() { command git -C "$sa/src" "$@"; }
sa_git config user.email t@example.invalid; sa_git config user.name t
echo base > "$sa/src/base.txt"; sa_git add -A; sa_git commit -qm base
sa_git remote add origin "$sa/origin.git"; sa_git push -q origin main
WT_ROOT_SAVED="$WT_ROOT"; WT_ROOT="$sa/wt-root"; mkdir -p "$WT_ROOT"
command git clone -q "$sa/origin.git" "$WT_ROOT/wt-issue-901"
sa_impl() { # code-lines lockfile-lines → 在 agent/issue-901 上重做一次实现并 force push
  sa_git checkout -q -B agent/issue-901 origin/main
  mkdir -p "$sa/src/packages/x"; seq 1 "$1" > "$sa/src/packages/x/large.ts"
  (( $2 > 0 )) && seq 1 "$2" >> "$sa/src/pnpm-lock.yaml"
  sa_git add -A; sa_git commit -qm impl; sa_git push -q -f origin agent/issue-901
}
size_gh_saved="$(declare -f gh)"; : > "$fixture/size-create.log"
gh() { case "$1 $2" in "pr list") echo "" ;; "pr create") printf 'create\n' >> "$fixture/size-create.log"; echo "https://github.com/example-maintainer/example-repo/pull/4100" ;; *) eval "${size_gh_saved/gh ()/gh_s ()}"; gh_s "$@" ;; esac; }
units '{"units":[{"id":"issue-901","issue":901,"title":"big fix","branch":"agent/issue-901","lane":"pr","stage":"implement","history":[]}]}'
printf 'fix delivered\n' > "$sup/impl-901.md"
sa_impl 801 0
harvest_pr_implement issue-901 "$sup/impl-901.md" || :
[[ "$(field issue-901 .stage)" == supervisor-review ]] || fail "801-line implementation was not routed to the supervisor re-scope ($(field issue-901 .stage))"
[[ "$(field issue-901 '.history[-1].stage')" == supervisor-escalated && "$(field issue-901 .note)" == *"801 changed lines"* && "$(field issue-901 .note)" == *"800"* ]] \
  || fail "size escalation lacks the numbers ($(field issue-901 .note))"
[[ "$(field issue-901 '.history[-1].decision.decision')" == 'Request recut or split before review' \
  && "$(field issue-901 '.history[-1].decision.evidence')" == '801 changed lines on agent/issue-901 exceed 800-line limit' \
  && "$(field issue-901 '.history[-1].decision.rejected[0]')" == 'Open PR for review without recutting' ]] || fail 'size admission did not record why the implementation must be recut'
[[ ! -s "$fixture/size-create.log" ]] || fail 'over-limit implementation still opened a PR for review'
units '{"units":[{"id":"issue-901","issue":901,"title":"big fix","branch":"agent/issue-901","lane":"pr","stage":"implement","history":[]}]}'
sa_impl 700 5000
harvest_pr_implement issue-901 "$sup/impl-901.md" || :
[[ "$(field issue-901 .stage)" == review-pending && "$(field issue-901 .pr)" == 4100 ]] || fail "lockfile lines were not excluded from the size count ($(field issue-901 .stage))"
units '{"units":[{"id":"issue-901","issue":901,"title":"big fix","branch":"agent/issue-901","lane":"pr","stage":"implement","history":[]}]}'
sa_git checkout -q -B agent/issue-901 origin/main
mkdir -p "$sa/src/packages/x/generated"
seq 1 801 > "$sa/src/packages/x/generated/api.ts"
sa_git add -A; sa_git commit -qm generated; sa_git push -q -f origin agent/issue-901
harvest_pr_implement issue-901 "$sup/impl-901.md" || :
[[ "$(field issue-901 .stage)" == review-pending ]] || fail "generated-only implementation was blocked by the size admission ($(field issue-901 .stage))"
units '{"units":[{"id":"issue-901","issue":901,"title":"big fix","branch":"agent/issue-901","lane":"pr","stage":"implement","history":[]}]}'
sa_git checkout -q -B agent/issue-901 origin/main
mkdir -p "$sa/src/docs"
seq 1 801 > "$sa/src/docs/guide.md"
sa_git add -A; sa_git commit -qm docs; sa_git push -q -f origin agent/issue-901
harvest_pr_implement issue-901 "$sup/impl-901.md" || :
[[ "$(field issue-901 .stage)" == review-pending ]] || fail "docs-only implementation was blocked by the size admission ($(field issue-901 .stage))"
units '{"units":[{"id":"issue-901","issue":901,"title":"big fix","branch":"agent/issue-901","lane":"pr","stage":"implement","history":[]}]}'
sa_git checkout -q -B agent/issue-901 origin/main
mkdir -p "$sa/src/.agents/skills/example"
seq 1 801 > "$sa/src/.agents/skills/example/SKILL.md"
sa_git add -A; sa_git commit -qm nested-docs; sa_git push -q -f origin agent/issue-901
harvest_pr_implement issue-901 "$sup/impl-901.md" || :
[[ "$(field issue-901 .stage)" == review-pending ]] || fail "nested Markdown-only implementation was blocked by the size admission ($(field issue-901 .stage))"
units '{"units":[{"id":"issue-901","issue":901,"title":"big fix","branch":"agent/issue-901","lane":"pr","stage":"implement","history":[]}]}'
sa_impl 800 0
harvest_pr_implement issue-901 "$sup/impl-901.md" || :
[[ "$(field issue-901 .stage)" == review-pending ]] || fail "exactly 800 changed lines must still open for review ($(field issue-901 .stage))"
[[ "$(wc -l < "$fixture/size-create.log")" == 5 ]] || fail "expected exactly five PRs opened across the admitted cases ($(cat "$fixture/size-create.log"))"
# #4482：尺寸准入在 repair 交付的新 head 上复查——开门时合规的 PR 会被修复轮养过线
#（如 #4396 从 611 变到 1090 准入行）；超线不开下一轮复检，转 supervisor 拆分。
units '{"units":[{"id":"issue-901","issue":901,"title":"big fix","branch":"agent/issue-901","pr":4100,"lane":"pr","stage":"repair","reviewed_sha":"'"$H1"'","history":[{"stage":"review-request-changes","at":"2026-10-19T10:00:00Z"}]}]}'
sa_impl 900 0
printf 'repaired\n' > "$sup/repair-901.md"
jq -n --arg dir "$WT_ROOT/wt-issue-901" '{workers:[{pid:4390,unit:"issue-901",type:"repair",log:"x.log",report:"repair-901.md",workdir:$dir}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field issue-901 '.history[-2].stage')" == repair-delivered ]] || fail "oversized repair was not delivered before the recheck ($(field issue-901 '.history[-2].stage'))"
[[ "$(field issue-901 .stage)" == supervisor-review ]] || fail "oversized repair head was not routed to the supervisor re-scope ($(field issue-901 .stage))"
[[ "$(field issue-901 '.history[-1].stage')" == supervisor-escalated && "$(field issue-901 .note)" == *"900 changed lines on agent/issue-901 after repair"* ]] \
  || fail "repair size escalation lacks the numbers ($(field issue-901 .note))"
[[ "$(field issue-901 '.history[-1].decision.decision')" == 'Request recut or split before review' ]] || fail 'repair size escalation did not record the recut decision'
units '{"units":[{"id":"issue-901","issue":901,"title":"big fix","branch":"agent/issue-901","pr":4100,"lane":"pr","stage":"repair","reviewed_sha":"'"$H1"'","history":[{"stage":"review-request-changes","at":"2026-10-19T10:00:00Z"}]}]}'
sa_impl 700 0
jq -n --arg dir "$WT_ROOT/wt-issue-901" '{workers:[{pid:4391,unit:"issue-901",type:"repair",log:"x.log",report:"repair-901.md",workdir:$dir}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field issue-901 .stage)" == rereview-pending ]] || fail "in-limit repair head was blocked by the size recheck ($(field issue-901 .stage))"
eval "$size_gh_saved"; WT_ROOT="$WT_ROOT_SAVED"

# supervisor 批准后 CI 测试红转 repair：批准前的失败回合不再计入断路
DISPATCHED=()
units "{\"units\":[{\"id\":\"pr-5c\",\"pr\":5,\"stage\":\"repair-pending\",\"loop_total_allowed\":12,\"review_report\":\"r.md\",\"history\":[{\"stage\":\"arbiter-review\"},$(printf '{"stage":"review-request-changes"},%.0s' 1 2 3 4 5){\"stage\":\"supervisor-approve\"},{\"stage\":\"ci-test-red\"}]}]}"
dispatch_pending || :
[[ "${DISPATCHED[0]:-}" == repair:pr-5c:* ]] || fail "rounds before a supervisor approval tripped the loop-breaker ($(field pr-5c .stage))"
DISPATCHED=()
# A repair whose failure evidence cannot be read goes to the supervisor, not into a silent skip every tick.
units "{\"units\":[{\"id\":\"pr-5d\",\"pr\":5,\"stage\":\"repair-pending\",\"review_report\":\"gone.md\",\"history\":[{\"stage\":\"review-request-changes\"}]}]}"
dispatch_pending || :
[[ "$(field pr-5d .stage)" == supervisor-review && ${#DISPATCHED[@]} == 0 ]] || fail "unreadable repair evidence was skipped silently ($(field pr-5d .stage))"
DISPATCHED=()

# 止损预算（#4363）：第 4 轮（implement+repair，每个 write-start 一轮）或超 4h 墙钟不再派发——
# 原票自动 on-hold 并评论附原因，单元转 supervisor；supervisor 裁决后预算重新给满；无 issue 的单元只转 supervisor。
stoploss_gh_saved="$(declare -f gh)"
: > "$fixture/stop-loss-calls"
gh() {
  case "$1 $2" in
    "issue comment") printf 'issue comment %s\n' "$*" >> "$fixture/stop-loss-calls" ;;
    "issue list") printf '[]\n' ;;
    "issue view")
      if [[ " $* " == *" -q "* ]]; then return 0; fi
      jq -cn --argjson n "$3" '{number:$n,labels:[]}'
      ;;
    "issue edit") printf 'issue edit %s\n' "$*" >> "$fixture/stop-loss-calls" ;;
    "label list") printf '[]\n' ;;
    "label create") return 0 ;;
    *) eval "${stoploss_gh_saved/gh ()/gh_sl ()}"; gh_sl "$@" ;;
  esac
}
# 止损搁置走 hold.sh（on-hold 的唯一写入口）：fixture root 放一个记录桩。
mkdir -p "$fixture/repo/engine"
printf '#!/usr/bin/env bash\nprintf "hold.sh %%s\\n" "$*" >> %q\n' "$fixture/stop-loss-calls" > "$fixture/repo/engine/hold.sh"
chmod +x "$fixture/repo/engine/hold.sh"
sl_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sl_rounds() { printf '{"stage":"write-start","at":"%s"},' "$sl_at"; printf '{"stage":"review-request-changes"},'; }
# 第 4 轮：已花 3 轮的 repair-pending 单元不再派发。
units "{\"units\":[{\"id\":\"issue-707\",\"issue\":707,\"pr\":55,\"branch\":\"agent/issue-707\",\"lane\":\"pr\",\"title\":\"stuck fix\",\"stage\":\"repair-pending\",\"review_report\":\"r.md\",\"history\":[$(sl_rounds)$(sl_rounds)$(sl_rounds){\"stage\":\"review-request-changes\"}]}]}"
dispatch_pending || :
[[ "$(field issue-707 .stage)" == supervisor-review && ${#DISPATCHED[@]} == 0 ]] || fail "a 4th round was dispatched past the stop-loss budget ($(field issue-707 .stage))"
[[ "$(field issue-707 .note)" == *"stop-loss: rounds 3 of 3"* ]] || fail "stop-loss note lacks the spent rounds ($(field issue-707 .note))"
[[ "$(field issue-707 '.history[-1].decision.evidence')" == *"3 rounds (implement+repair)"* ]] || fail "stop-loss decision lacks the budget evidence"
grep -q -- '--holder scheduler-stop-loss' "$fixture/stop-loss-calls" && grep -q -- '--kind stop-loss' "$fixture/stop-loss-calls" \
  && grep -q -- '--hold 707' "$fixture/stop-loss-calls" \
  || fail "the over-budget issue was not held through hold.sh ($(cat "$fixture/stop-loss-calls"))"
grep -qF '止损预算' "$fixture/stop-loss-calls" || fail "the hold carries no reason comment"

# 墙钟：第 2 轮前就超过 4h 同样搁置（原因带 wall 与分钟数）。
sl_old="$(date -u -d '5 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
units "{\"units\":[{\"id\":\"issue-708\",\"issue\":708,\"pr\":55,\"branch\":\"agent/issue-708\",\"lane\":\"pr\",\"title\":\"slow fix\",\"stage\":\"repair-pending\",\"review_report\":\"r.md\",\"history\":[{\"stage\":\"write-start\",\"at\":\"$sl_old\"},{\"stage\":\"review-request-changes\"}]}]}"
dispatch_pending || :
[[ "$(field issue-708 .stage)" == supervisor-review && "$(field issue-708 .note)" == *"wall "*"min of 240min after 1 rounds"* ]] \
  || fail "a unit over the 4h wall clock was not held with a wall reason ($(field issue-708 .stage) $(field issue-708 .note))"
# 预算内照常派发；rereview 不消耗轮数预算，不受它拦截。
units "{\"units\":[{\"id\":\"issue-709\",\"issue\":709,\"pr\":55,\"branch\":\"agent/issue-709\",\"lane\":\"pr\",\"title\":\"fine fix\",\"stage\":\"repair-pending\",\"review_report\":\"r.md\",\"history\":[$(sl_rounds)$(sl_rounds){\"stage\":\"review-request-changes\"}]}]}"
DISPATCHED=(); dispatch_pending || :
[[ "${DISPATCHED[0]:-}" == repair:issue-709:* ]] || fail "a unit inside the 3-round budget was not dispatched ($(field issue-709 .stage))"
units "{\"units\":[{\"id\":\"pr-5e\",\"pr\":5,\"stage\":\"rereview-pending\",\"review_report\":\"review-5-T1.md\",\"arbiter\":true,\"history\":[{\"stage\":\"arbiter-review\"},$(sl_rounds)$(sl_rounds)$(sl_rounds){\"stage\":\"review-request-changes\"}]}]}"
DISPATCHED=(); dispatch_pending || :
[[ "${DISPATCHED[0]:-}" == review:pr-5e:* ]] || fail "a rereview (not a budget round) was blocked by the stop-loss ($(field pr-5e .stage))"
[[ "$(grep -c '^hold.sh' "$fixture/stop-loss-calls")" == 2 ]] || fail "in-budget dispatches must not hold their issue ($(cat "$fixture/stop-loss-calls"))"
# supervisor 裁决后预算重新给满：3 轮 + supervisor-approve 之后照常派发。
units "{\"units\":[{\"id\":\"issue-710\",\"issue\":710,\"pr\":55,\"branch\":\"agent/issue-710\",\"lane\":\"pr\",\"title\":\"ruled fix\",\"stage\":\"repair-pending\",\"review_report\":\"r.md\",\"history\":[$(sl_rounds)$(sl_rounds)$(sl_rounds){\"stage\":\"supervisor-approve\"},{\"stage\":\"ci-test-red\"}]}]}"
DISPATCHED=(); dispatch_pending || :
[[ "${DISPATCHED[0]:-}" == repair:issue-710:* ]] || fail "a supervisor ruling did not refill the stop-loss budget ($(field issue-710 .stage))"
# 工单 token 是仪表盘指标，不是停单开关（#4486）：生命周期 raw token 再高（大头是缓存读取）、
# 只要轮数和墙钟在止损预算内就照常派发，不 park、不写预算 note。#4053 的硬停按 raw token 按
# 生命周期累计（实测 ~96% 是缓存读取），解除 PAUSE 后 36 次误停正常与已批准单元（10-29 05:10Z）。
high_cache_log="impl-issue-711-20261029T000000Z.worker.log"
printf 'tokens used\n40,586,714\n' > "$sup/$high_cache_log"
units "$(jq -cn --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{units:[
  {id:"issue-711",issue:711,pr:711,branch:"agent/issue-711",lane:"pr",stage:"repair-pending",review_report:"r.md",history:[{stage:"supervisor-requeue"},{stage:"write-start",at:$now},{stage:"review-request-changes"}]}]}')"
DISPATCHED=(); dispatch_pending || :
[[ "${DISPATCHED[0]:-}" == repair:issue-711:* && "$(field issue-711 .stage)" == repair \
  && "$(field issue-711 '.history | map(select(.stage=="supervisor-budget-park")) | length')" == 0 \
  && "$(field issue-711 '.note // ""')" != *"budget"* ]] \
  || fail "a high-cache-read unit inside the rounds+wall budget was stopped or noted as over budget (stage=$(field issue-711 .stage), dispatches=${DISPATCHED[*]:-none})"
rm -f "$sup/$high_cache_log"
# 派发路径不再包 spend runner：worker 命令就是 codex 本身，token 用量不构成停止条件。
if grep -Fq 'workorder_spend_runner' "$script_dir/scheduler.sh"; then
  fail "the dispatch path still wraps workers with the token spend runner"
fi
# A no-PR unit at the current rounds+wall stop-loss enters the real recut route.
recut_gh_bin="$fixture/recut-gh-bin"; mkdir -p "$recut_gh_bin"
recut_gh_log="$fixture/recut-gh.log"
cat > "$recut_gh_bin/gh" <<EOF
#!/usr/bin/env bash
case "\${1:-}:\${2:-}" in
  issue:view)
    if [[ " \$* " == *" -q "* ]]; then exit 0; fi
    printf '{"number":%s,"labels":[]}\\n' "\$3"
    ;;
  issue:list) printf '[]\\n' ;;
  issue:edit|issue:comment) printf '%s\\n' "\$*" >> "$recut_gh_log" ;;
  label:list) printf '[]\\n' ;;
  label:create) exit 0 ;;
  *) printf 'unexpected GH call in recut fixture: %s\\n' "\$*" >&2; exit 90 ;;
esac
EOF
chmod +x "$recut_gh_bin/gh"
recut_gh_function_saved="$(declare -f gh)"; recut_path_saved="$PATH"
unset -f gh
PATH="$recut_gh_bin:$PATH"
mkdir -p "$AGENT_HOME/state"
stoploss_model_policy="$AGENT_HOME/model-policy.json"
cp -- "$stoploss_model_policy" "$fixture/stoploss-model-policy.saved"
jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' "$stoploss_model_policy" > "$fixture/stoploss-model-policy.tmp"
mv -- "$fixture/stoploss-model-policy.tmp" "$stoploss_model_policy"
printf '%s\n' '{"attempts":1,"state":"ready-for-agent","recut_refused_at":"2026-10-28T00:00:00Z"}' > "$AGENT_HOME/state/713.json"
budget_recut_unit="issue-713-$$"
units "$(jq -cn --arg id "$budget_recut_unit" --arg at "$sl_at" '{units:[{id:$id,issue:713,stage:"implement-pending",history:[{stage:"write-start",at:$at},{stage:"write-start",at:$at},{stage:"write-start",at:$at}]}]}')"
dispatch_pending || :
[[ "$(field "$budget_recut_unit" .stage)" == closed \
  && "$(field "$budget_recut_unit" '.history[-1].stage')" == supervisor-budget-recut \
  && "$(jq -r '.state' "$AGENT_HOME/state/713.json")" == needs-recut \
  && "$(jq -r 'has("recut_refused_at")' "$AGENT_HOME/state/713.json")" == false ]] \
  || fail "an over-budget no-PR issue did not enter a fresh needs-recut episode (unit=$(field "$budget_recut_unit" .stage; field "$budget_recut_unit" .note), state=$(cat "$AGENT_HOME/state/713.json"))"
grep -Fq 'issue edit 713 --repo' "$recut_gh_log" \
  && grep -Fq -- '--add-label needs-recut' "$recut_gh_log" \
  || fail "the no-PR budget route did not write the needs-recut label through lib.sh ($(cat "$recut_gh_log" 2>/dev/null))"

# Preserve unfinished work before recut: cleanup must not discard uncommitted worktree contents.
WT_ROOT_SAVED="$WT_ROOT"; WT_ROOT="$fixture/budget-wt"; budget_wip_unit="issue-716-$$"; mkdir -p "$WT_ROOT/wt-$budget_wip_unit"
command git -C "$WT_ROOT/wt-$budget_wip_unit" init -q
echo wip > "$WT_ROOT/wt-$budget_wip_unit/wip.txt"
units "$(jq -cn --arg id "$budget_wip_unit" '{units:[{id:$id,issue:716,stage:"implement-pending",history:[]}]}')"
supervisor_budget_recut "$budget_wip_unit" "ticket stop-loss budget: test"
[[ "$(field "$budget_wip_unit" .stage)" == parked && "$(field "$budget_wip_unit" .note)" == *"unpushed work"* ]] \
  && ! grep -Fq 'issue edit 716' "$recut_gh_log" \
  || fail "an over-budget unit with uncommitted worktree work was closed or routed (716=$(field "$budget_wip_unit" .stage))"
budget_stash_unit="issue-717-$$"; mkdir -p "$WT_ROOT/wt-$budget_stash_unit"
command git -C "$WT_ROOT/wt-$budget_stash_unit" init -q
command git -C "$WT_ROOT/wt-$budget_stash_unit" config user.email t@example.invalid
command git -C "$WT_ROOT/wt-$budget_stash_unit" config user.name t
echo base > "$WT_ROOT/wt-$budget_stash_unit/tracked.txt"
command git -C "$WT_ROOT/wt-$budget_stash_unit" add tracked.txt
command git -C "$WT_ROOT/wt-$budget_stash_unit" commit -q -m stash-base
echo stashed > "$WT_ROOT/wt-$budget_stash_unit/tracked.txt"
command git -C "$WT_ROOT/wt-$budget_stash_unit" stash push -q -m budget-recut-test
units "$(jq -cn --arg id "$budget_stash_unit" '{units:[{id:$id,issue:717,stage:"implement-pending",history:[]}]}')"
supervisor_budget_recut "$budget_stash_unit" "ticket stop-loss budget: test"
[[ "$(field "$budget_stash_unit" .stage)" == parked \
  && -n "$(command git -C "$WT_ROOT/wt-$budget_stash_unit" stash list)" ]] \
  && ! grep -Fq 'issue edit 717' "$recut_gh_log" \
  || fail "an over-budget unit with a Git stash was closed or routed (717=$(field "$budget_stash_unit" .stage))"
WT_ROOT="$WT_ROOT_SAVED"

# A rejected real recut route must park the unit and keep the issue out of closed.
printf '%s\n' '{"attempts":1,"state":"ready-for-agent","recut_children":[900,901]}' > "$AGENT_HOME/state/718.json"
budget_refused_unit="issue-718-$$"
units "$(jq -cn --arg id "$budget_refused_unit" '{units:[{id:$id,issue:718,stage:"implement-pending",history:[]}]}')"
supervisor_budget_recut "$budget_refused_unit" "ticket stop-loss budget: test"
[[ "$(field "$budget_refused_unit" .stage)" == parked \
  && "$(jq -r '.state' "$AGENT_HOME/state/718.json")" == ready-for-agent ]] \
  && ! grep -Fq 'issue edit 718' "$recut_gh_log" \
  || fail "a refused recut route closed the unit or changed the issue state (718=$(field "$budget_refused_unit" .stage))"
PATH="$recut_path_saved"; eval "$recut_gh_function_saved"
cp -- "$fixture/stoploss-model-policy.saved" "$stoploss_model_policy"

# 无 GitHub issue 的单元（如 main-red）超预算只转 supervisor，不写 issue。
units "{\"units\":[{\"id\":\"main-red-abc\",\"main_red\":true,\"critical\":true,\"lane\":\"direct-main\",\"branch\":\"agent/main-red-abc\",\"stage\":\"implement-pending\",\"history\":[$(sl_rounds)$(sl_rounds)$(sl_rounds){\"stage\":\"write-end\"}]}]}"
dispatch_pending || :
[[ "$(field main-red-abc .stage)" == supervisor-review ]] || fail "an issue-less unit was not parked at the stop-loss ($(field main-red-abc .stage))"
[[ "$(grep -c '^hold.sh' "$fixture/stop-loss-calls")" == 2 ]] || fail "an issue-less unit must not produce issue writes ($(cat "$fixture/stop-loss-calls"))"
eval "$stoploss_gh_saved"
DISPATCHED=()

# Every cancel the scheduler sends names its cause for the audit log (ZF_CANCEL_REASON): one stable, distinct reason per site.
cr="$fixture/cancel-reason-root"; mkdir -p "$cr/engine/night"
printf '#!/usr/bin/env bash\necho "${ZF_CANCEL_REASON-unset}" >> "%s/reasons"\n' "$cr" > "$cr/engine/night/main-ci-recovery.sh"
reasons_of() { local r; r="$(cat "$cr/reasons" 2>/dev/null)"; : > "$cr/reasons"; printf '%s' "$r"; }
: > "$cr/reasons"; root_saved="$ROOT"; ROOT="$cr"; GH_RUNS=501
units "{\"units\":[{\"id\":\"pr-5d\",\"pr\":5,\"stage\":\"repair-pending\",\"review_report\":\"r.md\",\"history\":[]}]}"
DISPATCHED=(); dispatch_pending || :
[[ "${DISPATCHED[0]:-}" == repair:pr-5d:* && "$(reasons_of)" == "repair dispatched" ]] || fail "repair dispatch cancel did not carry its reason (${DISPATCHED[*]:-none})"
units '{"units":[{"id":"pr-3v","pr":3,"stage":"review","history":[]}]}'
printf 'VERDICT: REQUEST-CHANGES\n' > "$sup/review-3v-T1.md"
jq -n --arg sha "$H1" '{workers:[{pid:4246,unit:"pr-3v",type:"review",log:"x.log",report:"review-3v-T1.md",sha:$sha}]}' > "$WORKERS"
harvest_workers || :
[[ "$(reasons_of)" == "review requested changes" ]] || fail 'send-back cancel did not carry its reason'
units '{"units":[{"id":"pr-3w","pr":3,"stage":"review","history":[]}]}'
printf 'VERDICT: BLOCK\n' > "$sup/review-3w-T1.md"
jq -n --arg sha "$H1" '{workers:[{pid:4247,unit:"pr-3w",type:"review",log:"x.log",report:"review-3w-T1.md",sha:$sha}]}' > "$WORKERS"
harvest_workers || :
[[ "$(reasons_of)" == "review blocked" ]] || fail 'BLOCK cancel did not carry its reason'
to_supervisor pr-3w "x" >/dev/null
[[ "$(reasons_of)" == "parked for the supervisor" ]] || fail 'supervisor escalation cancel did not carry its reason'
register_saved="$(declare -f ensure_lane room_for)"; gh_reg_saved="$(declare -f gh)"; cfg_saved="$CFG"
CFG="$(jq '.auto_dispatch_new_prs = true' <<<"$CFG")"; ensure_lane() { echo direct-main; }; room_for() { return 1; }
gh() { if [[ "$1 $2" == "pr list" ]]; then printf '[{"number":9,"headRefOid":"%s","headRefName":"feat/doc","isDraft":false,"title":"title","labels":[]}]\n' "$H1"; else eval "${gh_reg_saved/gh ()/gh_g ()}"; gh_g "$@"; fi; }
units '{"units":[]}'; register_new_prs || :
[[ "$(reasons_of)" == "direct-main lane" ]] || fail 'direct-main registration cancel did not carry its reason'
gh() { if [[ "$1 $2" == "pr list" ]]; then printf '[{"number":9,"headRefOid":"%s","headRefName":"agent/issue-hf-9","isDraft":false,"title":"title","labels":[{"name":"hotfix"}]}]\n' "$H1"; else eval "${gh_reg_saved/gh ()/gh_g ()}"; gh_g "$@"; fi; }
TICK_PRS=""; units '{"units":[]}'; register_new_prs || :
[[ "$(jq '.units | length' "$UNITS")" == 0 ]] || fail 'hotfix PR was registered as a pipeline unit'
# #4615: configured prefixes, PR labels, linked issue labels and automatic PR labels share is_hotfix_pr.
[[ "$(jq -c '.hotfix_lane' "$script_dir/config.template.json")" == '{"branch_prefixes":["hotfix/","agent/issue-hf-"],"label":"hotfix"}' ]] \
  || fail 'config.template.json does not define the hotfix lane'
hotfix_list_calls="$fixture/hotfix-issue-list.calls"; : > "$hotfix_list_calls"
hotfix_label_edits=()
gh() {
  if [[ "$1 $2" == "pr list" ]]; then
    jq -cn --arg sha "$H1" '[
      {number:10,headRefOid:$sha,headRefName:"agent/issue-31-cells",isDraft:false,title:"branch linked",labels:[],body:""},
      {number:11,headRefOid:$sha,headRefName:"feat/plain",isDraft:false,title:"body linked",labels:[],body:"work\n\nRefs #31"},
      {number:12,headRefOid:$sha,headRefName:"hotfix/urgent",isDraft:false,title:"configured prefix",labels:[],body:""},
      {number:13,headRefOid:$sha,headRefName:"agent/issue-hf-32",isDraft:false,title:"hf prefix",labels:[],body:""},
      {number:14,headRefOid:$sha,headRefName:"feat/ordinary",isDraft:false,title:"ordinary",labels:[],body:"no association"},
      {number:15,headRefOid:$sha,headRefName:"hotfix/label-write-fails",isDraft:false,title:"label write failure",labels:[],body:""}
    ]'
  elif [[ "$1 $2" == "issue list" ]]; then
    printf '%s\n' "$*" >> "$hotfix_list_calls"
    [[ "$*" == *"--label hotfix"* && "$*" == *"--json number,labels"* ]] || fail "hotfix issue census ignored config or labels ($*)"
    printf '%s\n' '[{"number":31,"labels":[{"name":"hotfix"}]}]'
  elif [[ "$1 $2" == "pr edit" ]]; then
    hotfix_label_edits+=("$3:$5")
    [[ "$3" != 15 ]]
  else eval "${gh_reg_saved/gh ()/gh_g ()}"; gh_g "$@"; fi
}
TICK_PRS=""; TICK_HOTFIX_ISSUES='[]'; TICK_HOTFIX_ISSUES_LOADED=false; units '{"units":[]}'; register_new_prs || :
[[ "$(jq -r '[.units[].id] | join(",")' "$UNITS")" == "pr-14" ]] || fail "hotfix PRs were registered or ordinary PR was skipped ($(jq -c '[.units[].id]' "$UNITS"))"
[[ "${hotfix_label_edits[*]}" == "15:hotfix 13:hotfix 12:hotfix 11:hotfix 10:hotfix" ]] || fail "hotfix PRs were not auto-labeled (${hotfix_label_edits[*]:-none})"
grep -Fq 'hotfix PR#15: could not add configured label hotfix' "$LOG" || fail 'hotfix label write failure was not recorded'
[[ "$(wc -l < "$hotfix_list_calls")" == 1 ]] || fail "register_new_prs read issue labels $(wc -l < "$hotfix_list_calls") times for one tick"
# The decision follows the loaded config, so a CTO rule change takes effect on the next tick.
CFG="$(jq '.hotfix_lane = {branch_prefixes:["urgent/"],label:"urgent-hotfix"}' <<<"$CFG")"
hotfix_label_edits=(); : > "$hotfix_list_calls"
gh() {
  if [[ "$1 $2" == "pr list" ]]; then
    jq -cn --arg sha "$H1" '[
      {number:15,headRefOid:$sha,headRefName:"urgent/one",isDraft:false,title:"configured prefix",labels:[],body:""},
      {number:16,headRefOid:$sha,headRefName:"feat/already-hotfix",isDraft:false,title:"configured label",labels:[{name:"urgent-hotfix"}],body:""}
    ]'
  elif [[ "$1 $2" == "pr edit" ]]; then hotfix_label_edits+=("$3:$5")
  elif [[ "$1 $2" == "issue list" ]]; then printf '%s\n' "$*" >> "$hotfix_list_calls"; printf '[]\n'
  else eval "${gh_reg_saved/gh ()/gh_g ()}"; gh_g "$@"; fi
}
TICK_PRS=""; TICK_HOTFIX_ISSUES='[]'; TICK_HOTFIX_ISSUES_LOADED=false; units '{"units":[]}'; register_new_prs || :
[[ "$(jq '.units | length' "$UNITS")" == 0 && "${hotfix_label_edits[*]}" == "15:urgent-hotfix" && ! -s "$hotfix_list_calls" ]] \
  || fail "custom hotfix config did not classify and label PR before issue lookup (units=$(jq -c '.units' "$UNITS"), labels=${hotfix_label_edits[*]:-none}, issue_reads=$(wc -l < "$hotfix_list_calls"))"
CFG="$(jq '.issue_intake.labels=["ready-for-agent"] | .issue_intake.product_labels=[]' <<<"$CFG")"
gh() {
  if [[ "$1 $2" == "issue list" && "$*" == *"--label ready-for-agent"* ]]; then
    jq -cn '[{number:17,title:"hotfix issue",labels:[{name:"ready-for-agent"},{name:"urgent-hotfix"}]}]'
  else printf '[]\n'; fi
}
[[ -z "$(intake_candidates)" ]] || fail 'configured hotfix issue label entered regular issue intake'
eval "$register_saved"; eval "$gh_reg_saved"; CFG="$cfg_saved"; ROOT="$root_saved"; GH_RUNS='[]'; DISPATCHED=()

# 名额空了慢阶段之间就补派；满了不动。worker 退出后的补派由 loop.sh 的补派窗口调 --refill 入口完成（#4628）
REFILL_CALLS=(); harvest_saved="$(declare -f harvest_workers recover_orphans dispatch_pending live_workers)"
harvest_workers() { REFILL_CALLS+=(harvest); }; recover_orphans() { :; }; dispatch_pending() { REFILL_CALLS+=(dispatch); }
live_workers() { echo "$MAX"; }; refill
[[ -z "${REFILL_CALLS[*]:-}" ]] || fail "refill ran with every slot busy (${REFILL_CALLS[*]})"
live_workers() { echo $((MAX - 1)); }; refill
[[ "${REFILL_CALLS[*]:-}" == "harvest dispatch" ]] || fail "free slot was not refilled between phases (${REFILL_CALLS[*]:-none})"
eval "$harvest_saved"
( AUTOPI_LOOP_LIBRARY_ONLY=true; source "$(dirname "$0")/loop.sh"
  true & dead=$!; wait "$dead"
  jq -n --argjson d "$dead" --argjson l "$$" '{workers:[{pid:$l},{pid:$d,harvested:true}]}' > "$fixture/w-live.json"
  jq -n --argjson d "$dead" --argjson l "$$" '{workers:[{pid:$l},{pid:$d}]}' > "$fixture/w-done.json"
  [[ -z "$(exited_worker_signature "$fixture/w-live.json")" ]] \
    && [[ "$(exited_worker_signature "$fixture/w-done.json")" == "$dead" ]] ) || fail 'loop does not detect a newly exited worker'
# 补派窗口（#4628）：worker 退出在一次 5 秒轮询内触发 --refill；锁忙时保留触发并重试；
# 慢 tick 仍运行时，释放共享锁后补派必须完成。无退出时按 cadence 触发，空闲时不空转。
rg="$fixture/refill-gap"; mkdir -p "$rg/live" "$rg/state"
cat > "$rg/live/scheduler.sh" <<'SH'
#!/usr/bin/env bash
mkdir "$RG_LOCK" 2>/dev/null || exit 75
printf '%s\n' "$BASHPID" > "$RG_LOCK/pid"
trap 'rm -rf -- "$RG_LOCK"' EXIT
printf '%s\n' "$*" >> "$RG_CALLS"
if [[ "${RG_SLOW_PID:-}" =~ ^[1-9][0-9]*$ ]] && kill -0 "$RG_SLOW_PID" 2>/dev/null; then
  printf 'during-slow-tick\n' >> "$RG_DURING"
fi
jq '{"workers": [.workers[] | .harvested = true]}' "$RG_STATE/workers.json" > "$RG_STATE/workers.json.tmp" \
  && mv "$RG_STATE/workers.json.tmp" "$RG_STATE/workers.json"
SH
( AUTOPI_LOOP_LIBRARY_ONLY=true; source "$(dirname "$0")/loop.sh"
  A="$rg/state"; LIVE="$rg/live"; export RG_CALLS="$rg/calls" RG_STATE="$rg/state" RG_LOCK="$rg/lock" RG_DURING="$rg/during"
  export RG_SLOW_PID=0; : > "$RG_CALLS"; : > "$RG_DURING"
  true & dead=$!; wait "$dead"
  jq -n --argjson d "$dead" '{workers:[{pid:$d}]}' > "$A/workers.json"
  sleep() { :; }
  refill_window 6 ) || fail 'refill window failed with an exited worker'
[[ "$(cat "$rg/calls")" == '--refill' ]] || fail "an exited worker did not trigger exactly one immediate refill tick ($(cat "$rg/calls" 2>/dev/null))"
: > "$rg/calls"
( AUTOPI_LOOP_LIBRARY_ONLY=true; source "$(dirname "$0")/loop.sh"
  A="$rg/state"; LIVE="$rg/live"; export RG_CALLS="$rg/calls" RG_STATE="$rg/state" RG_LOCK="$rg/lock" RG_DURING="$rg/during"
  export RG_SLOW_PID=0; : > "$RG_CALLS"
  export AUTOPI_REFILL_SECONDS=0
  jq -n --argjson l "$$" '{workers:[{pid:$l}]}' > "$A/workers.json"
  sleep() { :; }
  refill_window 6 ) || fail 'refill window failed on its cadence'
grep -qx -- '--refill' "$rg/calls" || fail "the cadence did not run a refill tick with every worker alive ($(cat "$rg/calls" 2>/dev/null))"
: > "$rg/calls"
( AUTOPI_LOOP_LIBRARY_ONLY=true; source "$(dirname "$0")/loop.sh"
  A="$rg/state"; LIVE="$rg/live"; export RG_CALLS="$rg/calls" RG_STATE="$rg/state" RG_LOCK="$rg/lock" RG_DURING="$rg/during"
  export RG_SLOW_PID=0; : > "$RG_CALLS"
  jq -n --argjson l "$$" '{workers:[{pid:$l}]}' > "$A/workers.json"
  sleep() { :; }
  refill_window 6 ) || fail 'refill window failed while idle'
[[ ! -s "$rg/calls" ]] || fail "refill tick ran before its cadence with every worker alive ($(cat "$rg/calls"))"
# A slow tick holding the mutex yields it during a long phase; the refill retries contention
# and dispatches while that slow tick is still alive.
( AUTOPI_LOOP_LIBRARY_ONLY=true; source "$(dirname "$0")/loop.sh"
  A="$rg/state"; LIVE="$rg/live"; export RG_CALLS="$rg/calls" RG_STATE="$rg/state" RG_LOCK="$rg/lock" RG_DURING="$rg/during"
  : > "$RG_CALLS"; : > "$RG_DURING"
  command sleep 3 & slow=$!; export RG_SLOW_PID="$slow"
  mkdir "$RG_LOCK"; printf '%s\n' "$$" > "$RG_LOCK/pid"
  true & dead=$!; wait "$dead"
  jq -n --argjson d "$dead" '{workers:[{pid:$d}]}' > "$A/workers.json"
  polls=0
  sleep() { polls=$((polls + 1)); (( polls < 2 )) || rm -rf -- "$RG_LOCK"; }
  refill_window 10 "$slow"
  kill "$slow" 2>/dev/null || :; wait "$slow" 2>/dev/null || : ) || fail 'refill did not retry and dispatch while slow tick was alive'
grep -qx -- '--refill' "$rg/calls" && grep -qx 'during-slow-tick' "$rg/during" \
  || fail "refill did not run during a live slow tick ($(cat "$rg/calls" 2>/dev/null); $(cat "$rg/during" 2>/dev/null))"
# 源 checkout 的 HEAD 变了，下一拍前把机制文件同步进运行目录；HEAD 没变不重复同步
sr="$fixture/syncroot"; mkdir -p "$sr/engine/mac-autopilot" "$sr/rt"
git -C "$sr" init -q; printf 'echo synced >> "$SYNC_LOG"\n' > "$sr/engine/mac-autopilot/start.sh"
git -C "$sr" add -A; git -C "$sr" -c user.name=t -c user.email=t@e commit -qm one
( AUTOPI_LOOP_LIBRARY_ONLY=true; source "$(dirname "$0")/loop.sh"; A="$sr/rt"; MAC_AUTOPILOT_ROOT="$sr"; export SYNC_LOG="$sr/sync.log"
  sync_from_main; sync_from_main
  git -C "$sr" -c user.name=t -c user.email=t@e commit -qm two --allow-empty; sync_from_main )
[[ "$(wc -l < "$sr/sync.log")" == 2 ]] || fail "runtime sync did not follow main exactly once per new head ($(wc -l < "$sr/sync.log"))"
grep -q 'SYNC runtime from main' "$sr/rt/scheduler.log" || fail 'runtime sync not logged'
# Each tick enters through the live pointer; siblings stay pinned even when it switches mid-tick.
lp="$fixture/live-ticks"; mkdir -p "$lp/one" "$lp/two" "$lp/state/alerts"
printf 'one\n' > "$lp/one/sibling.txt"; printf 'two\n' > "$lp/two/sibling.txt"
cat > "$lp/one/scheduler.sh" <<'SH'
code="$(cd "$(dirname "$0")" && pwd -P)"
ln -sfn "$TICK_FIXTURE/two" "$TICK_FIXTURE/next"
mv -Tf "$TICK_FIXTURE/next" "$TICK_FIXTURE/live"
cat "$code/sibling.txt" >> "$TICK_FIXTURE/seen"
SH
cat > "$lp/two/scheduler.sh" <<'SH'
code="$(cd "$(dirname "$0")" && pwd -P)"
cat "$code/sibling.txt" >> "$TICK_FIXTURE/seen"
SH
ln -s one "$lp/live"
( AUTOPI_LOOP_LIBRARY_ONLY=true; source "$(dirname "$0")/loop.sh"; A="$lp/state"; LIVE="$lp/live"; export TICK_FIXTURE="$lp"
  run_tick; run_tick )
[[ "$(cat "$lp/seen")" == $'one\ntwo' ]] || fail 'ticks did not follow live pointer with pinned siblings'

# loop.sh derives the live pointer from the supervisor dir (the units' path), not from where loop.sh sits.
[[ "$( ( AUTOPI_LOOP_LIBRARY_ONLY=true; MAC_AUTOPILOT_SUPERVISOR_DIR="$lp/sup"; source "$(dirname "$0")/loop.sh"; printf %s "$LIVE" ) )" == "$lp/sup/autopi-live" ]] || fail 'loop.sh live pointer is not <supervisor>/autopi-live'

# L76：卡住的一拍被限时终止并告警，loop 照常进入下一拍
lt="$fixture/looptick"; mkdir -p "$lt/alerts"; printf 'exec sleep 60 # wall-clock-allow: stands in for a hung tick that the limit must kill\n' > "$lt/scheduler.sh"
( AUTOPI_LOOP_LIBRARY_ONLY=true; source "$(dirname "$0")/loop.sh"; A="$lt"; LIVE="$lt"; AUTOPI_TICK_LIMIT_SECONDS=1 run_tick ) || fail 'run_tick failed on a hung tick'
grep -q 'TICK-TIMEOUT' "$lt/scheduler.log" && grep -q 'TICK-TIMEOUT' "$lt/alerts/waste.md" || fail 'hung tick was not killed and alerted'

# repair 没推出新 head：自动重试两次，第三次转人工
for round in 1 2 3; do
  hist_json="$(jq -cn --argjson n "$((round-1))" '[{stage:"review-request-changes"}] + [range($n) | {stage:"repair-no-push"}, {stage:"repair-delivered"}] + [{stage:"repair-delivered"}]')"
  units "{\"units\":[{\"id\":\"pr-5b\",\"pr\":5,\"stage\":\"rereview-pending\",\"reviewed_sha\":\"$H1\",\"reviewed_pr_head\":\"$H1\",\"review_report\":\"r.md\",\"history\":$hist_json}]}"
  dispatch_pending || :
  if (( round < 3 )); then
    [[ "$(field pr-5b .stage)" == repair-pending ]] || fail "repair-no-push round $round was not retried"
  else
    [[ "$(field pr-5b .stage)" == rereview-pending && "$(field pr-5b .arbiter)" == true ]] || fail 'repair-no-push retried more than twice (expected one arbiter review)'
  fi
done
# A CI failure after approval followed by an unchanged repair returns to native CI within the existing unit-row bound.
gh_head_saved="$GH_HEAD"; gh_runs_saved="$GH_RUNS"; cancel_unit_runs_saved="$(declare -f cancel_unit_runs)"
GH_HEAD="$H1"; GH_RUNS=777; GH_RERUNS=(); DISPATCHED=(); cancel_unit_runs() { :; }
ci_repair_history="$(jq -cn --arg sha "$H1" '[{stage:"review-approve",result:$sha},{stage:"ci-red",result:"external CI failure"},{stage:"repair-delivered"}]')"
units "$(jq -cn --arg sha "$H1" --argjson history "$ci_repair_history" \
  '{units:[{id:"pr-5ci",pr:5,stage:"rereview-pending",reviewed_sha:$sha,reviewed_pr_head:$sha,review_report:"r.md",history:$history}]}')"
for retry in 1 2 3; do
  DISPATCHED=()
  dispatch_pending || :
  [[ "$(field pr-5ci .stage):$(field pr-5ci .approved_sha):$(field pr-5ci .ci_infra_reruns):$(field pr-5ci .ci_rerun_sha)" == "ready-to-merge:$H1:$retry:$H1" \
    && ${#GH_RERUNS[@]} == "$retry" && ${#DISPATCHED[@]} == 0 && "$(field pr-5ci '.arbiter // false')" == false ]] \
    || fail "unchanged approved CI repair did not rerun within the existing bound ($retry; stage=$(field pr-5ci .stage), reruns=${#GH_RERUNS[@]}, dispatches=${DISPATCHED[*]:-none})"
  set_unit pr-5ci '.history += [{stage:"ci-red",result:"external CI failure"},{stage:"repair-delivered"}] | .approved_sha=null | .stage="rereview-pending"'
done
reruns_before=${#GH_RERUNS[@]}; DISPATCHED=()
dispatch_pending || :
[[ "$(field pr-5ci .stage):$(field pr-5ci .ci_infra_reruns)" == "supervisor-review:3" \
  && ${#GH_RERUNS[@]} == "$reruns_before" && ${#DISPATCHED[@]} == 0 \
  && "$(field pr-5ci '.arbiter // false')" == false ]] \
  || fail "exhausted unchanged-approved CI retry budget did not stop at supervisor (stage=$(field pr-5ci .stage), reruns=${#GH_RERUNS[@]}, dispatches=${DISPATCHED[*]:-none})"
GH_RERUNS=(); GH_RERUN_FAIL=1; DISPATCHED=()
units "$(jq -cn --arg sha "$H1" --argjson history "$ci_repair_history" \
  '{units:[{id:"pr-5ci-fail",pr:5,stage:"rereview-pending",reviewed_sha:$sha,reviewed_pr_head:$sha,review_report:"r.md",history:$history}]}')"
dispatch_pending || :
[[ "$(field pr-5ci-fail .stage):$(field pr-5ci-fail '.ci_infra_reruns // 0')" == "supervisor-review:0" \
  && "${GH_RERUNS[*]:-}" == "run rerun 777 --failed" && ${#DISPATCHED[@]} == 0 \
  && "$(field pr-5ci-fail '.arbiter // false')" == false ]] \
  || fail "rejected native rerun spent the bound or dispatched repair (stage=$(field pr-5ci-fail .stage), reruns=${GH_RERUNS[*]:-none})"
GH_RERUNS=(); GH_RERUN_FAIL=0; GH_RUN_LIST_FAIL=1; DISPATCHED=()
units "$(jq -cn --arg sha "$H1" --argjson history "$ci_repair_history" \
  '{units:[{id:"pr-5ci-list-fail",pr:5,stage:"rereview-pending",reviewed_sha:$sha,reviewed_pr_head:$sha,review_report:"r.md",history:$history}]}')"
dispatch_pending || :
[[ "$(field pr-5ci-list-fail .stage):$(field pr-5ci-list-fail '.ci_infra_reruns // 0')" == "supervisor-review:0" \
  && ${#GH_RERUNS[@]} == 0 && ${#DISPATCHED[@]} == 0 \
  && "$(field pr-5ci-list-fail '.arbiter // false')" == false ]] \
  || fail "failed-run listing failure spent the bound or dispatched repair (stage=$(field pr-5ci-list-fail .stage), reruns=${GH_RERUNS[*]:-none})"
GH_RUN_LIST_FAIL=0; GH_RUNS=$'777\n778'; GH_RERUN_FAIL_ID=778; GH_RERUNS=(); DISPATCHED=()
units "$(jq -cn --arg sha "$H1" --argjson history "$ci_repair_history" \
  '{units:[{id:"pr-5ci-partial-fail",pr:5,stage:"rereview-pending",reviewed_sha:$sha,reviewed_pr_head:$sha,review_report:"r.md",history:$history}]}')"
dispatch_pending || :
[[ "$(field pr-5ci-partial-fail .stage):$(field pr-5ci-partial-fail '.ci_infra_reruns // 0'):$(field pr-5ci-partial-fail '.ci_rerun_sha // "none"')" == "supervisor-review:0:none" \
  && "${GH_RERUNS[*]}" == "run rerun 777 --failed run rerun 778 --failed" && ${#DISPATCHED[@]} == 0 \
  && "$(field pr-5ci-partial-fail '.arbiter // false')" == false ]] \
  || fail "partially rejected rerun batch advanced the head or dispatched repair (stage=$(field pr-5ci-partial-fail .stage), reruns=${GH_RERUNS[*]:-none})"
GH_RUN_LIST_FAIL=0; GH_RERUN_FAIL_ID=; GH_RERUNS=(); DISPATCHED=()
# ci-test-red entry cancels the head's other in-progress runs, so the red run is usually "cancelled", not "failure".
GH_RUN_JSON='[{"databaseId":901,"conclusion":"cancelled"},{"databaseId":902,"conclusion":"success"}]'
ci_test_red_history="$(jq -cn --arg sha "$H1" '[{stage:"review-approve",result:$sha},{stage:"ci-test-red",result:"required check cancelled"},{stage:"repair-delivered"}]')"
units "$(jq -cn --arg sha "$H1" --argjson history "$ci_test_red_history" \
  '{units:[{id:"pr-5ci-cancelled",pr:5,stage:"rereview-pending",reviewed_sha:$sha,reviewed_pr_head:$sha,review_report:"r.md",history:$history}]}')"
dispatch_pending || :
[[ "$(field pr-5ci-cancelled .stage):$(field pr-5ci-cancelled '.ci_infra_reruns // 0')" == "ready-to-merge:1" \
  && "${GH_RERUNS[*]:-}" == "run rerun 901 --failed" && ${#DISPATCHED[@]} == 0 \
  && "$(field pr-5ci-cancelled '.arbiter // false')" == false ]] \
  || fail "ci-test-red repair with a cancelled run did not rerun within the bound (stage=$(field pr-5ci-cancelled .stage), reruns=${GH_RERUNS[*]:-none})"
GH_RUN_JSON=
GH_RUNS=777; GH_RERUN_FAIL_ID=
eval "$cancel_unit_runs_saved"; GH_HEAD="$gh_head_saved"; GH_RUNS="$gh_runs_saved"; GH_RERUNS=()
DISPATCHED=()
units '{"units":[{"id":"pr-6","pr":6,"stage":"rereview-pending","history":[]}]}'
dispatch_pending || :
[[ "${DISPATCHED[0]:-}" == "review:pr-6:$H1" ]] || fail "rereview without a baseline must be a full review (got ${DISPATCHED[*]:-none})"
[[ "$DISPATCH_PROMPT" == *".agents/skills/zf-code-review/SKILL.md"* ]] || fail 'full review prompt does not reference the canonical contract'
[[ "$(field pr-6 .review_sha)" == "$H1" ]] || fail 'dispatched review sha not recorded'
[[ "$DISPATCH_PR_HEAD" == "$H1" ]] || fail 'dispatched review did not retain its observed PR head'

# L63：PR 车道的修复推送会同时移动 PR head 与候选；上轮 head 是祖先就必须走增量复审，不能回落成全量重审。
rr="$fixture/wt-pr-7"; rm -rf "$rr"; command git init -q -b main "$rr"
command git -C "$rr" commit -q --allow-empty -m reviewed; R1="$(command git -C "$rr" rev-parse HEAD)"
command git -C "$rr" commit -q --allow-empty -m repair; R2="$(command git -C "$rr" rev-parse HEAD)"
command git -C "$rr" checkout -q --orphan rebased; command git -C "$rr" commit -q --allow-empty -m rebased; R3="$(command git -C "$rr" rev-parse HEAD)"
DISPATCHED=(); GH_HEAD="$R2"
units "{\"units\":[{\"id\":\"pr-7\",\"pr\":7,\"stage\":\"rereview-pending\",\"reviewed_sha\":\"$R1\",\"reviewed_pr_head\":\"$R1\",\"review_report\":\"review-7-T1.md\",\"history\":[]}]}"
dispatch_pending || :
[[ "${DISPATCHED[0]:-}" == "rereview:pr-7:$R2" && "$DISPATCH_PR_HEAD" == "$R2" ]] || fail "repair push (PR head moved, old head is an ancestor) did not get an incremental rereview (got ${DISPATCHED[*]:-none})"
[[ "$DISPATCH_PROMPT" == *"$R1..$R2"* && "$DISPATCH_PROMPT" == *".agents/skills/zf-code-review/SKILL.md"* ]] \
  || fail 'incremental rereview prompt lost its repair delta or canonical contract reference'
DISPATCHED=(); GH_HEAD="$R2"
units "{\"units\":[{\"id\":\"pr-7\",\"pr\":7,\"stage\":\"rereview-pending\",\"reviewed_sha\":\"$R1\",\"reviewed_pr_head\":\"$R1\",\"review_report\":\"review-7-T1.md\",\"history\":[],\"review_findings\":[{\"disposition_block\":\"ok\",\"dispositions\":[{\"id\":\"F1\",\"disposition\":\"fixed\",\"reason\":\"tenant predicate now precedes the write\"}]}]}]}"
dispatch_pending || :
[[ "${DISPATCHED[0]:-}" == "rereview:pr-7:$R2" && "$DISPATCH_PROMPT" == *"F1: fixed"* \
  && "$DISPATCH_PROMPT" == *"tenant predicate now precedes the write"* ]] || fail "incremental rereview did not consume persisted author dispositions: ${DISPATCHED[*]:-none}; prompt=${DISPATCH_PROMPT}"
DISPATCHED=(); GH_HEAD="$R3"
units "{\"units\":[{\"id\":\"pr-7\",\"pr\":7,\"stage\":\"rereview-pending\",\"reviewed_sha\":\"$R1\",\"reviewed_pr_head\":\"$R1\",\"review_report\":\"review-7-T1.md\",\"history\":[]}]}"
dispatch_pending || :
[[ "${DISPATCHED[0]:-}" == "review:pr-7:$R3" ]] || fail "rewritten history (old head not an ancestor) must get a full review (got ${DISPATCHED[*]:-none})"
GH_HEAD="$H1"

DISPATCHED=()
units "{\"units\":[{\"id\":\"pr-7b\",\"pr\":7,\"stage\":\"rereview-pending\",\"reviewed_sha\":\"$H1\",\"reviewed_pr_head\":\"$H2\",\"review_report\":\"review-7-T1.md\",\"history\":[]}]}"
dispatch_pending || :
[[ "${DISPATCHED[0]:-}" == "review:pr-7b:$H1" && "$DISPATCH_PR_HEAD" == "$H1" ]] || fail 'changed PR head with unchanged local candidate did not trigger a fresh full review'

# #4411: the worker clone seeded from a depth-one scheduler checkout must fetch full history;
# otherwise the real rereview-pending tick cannot prove that the prior reviewed SHA is an ancestor.
shallow="$fixture/shallow-rereview"; rm -rf "$shallow"; mkdir -p "$shallow"
command git init -q --bare "$shallow/remote.git"
command git init -q -b main "$shallow/source"
command git -C "$shallow/source" config user.email t@example.invalid
command git -C "$shallow/source" config user.name t
command git -C "$shallow/source" commit -q --allow-empty -m base-1
command git -C "$shallow/source" commit -q --allow-empty -m reviewed-before-shallow-boundary
SR1="$(command git -C "$shallow/source" rev-parse HEAD)"
command git -C "$shallow/source" commit -q --allow-empty -m base-2
shallow_main="$(command git -C "$shallow/source" rev-parse HEAD)"
command git -C "$shallow/source" remote add origin "$shallow/remote.git"
command git -C "$shallow/source" push -q -u origin main
command git --git-dir="$shallow/remote.git" symbolic-ref HEAD refs/heads/main
command git -C "$shallow/source" checkout -q -b agent/issue-7
command git -C "$shallow/source" commit -q --allow-empty -m repair
SR2="$(command git -C "$shallow/source" rev-parse HEAD)"
command git -C "$shallow/source" push -q origin agent/issue-7
command git --git-dir="$shallow/remote.git" update-ref refs/pull/77/head "$SR2"
command git clone -q --depth 1 "file://$shallow/remote.git" "$shallow/root"
[[ "$(command git -C "$shallow/root" rev-parse --is-shallow-repository)" == true ]] \
  || fail 'shallow rereview fixture did not create a depth-one scheduler checkout'
saved_root="$ROOT"; saved_main_head="$MAIN_HEAD"; saved_wt_root="$WT_ROOT"; saved_gh_head="$GH_HEAD"
ROOT="$shallow/root"; MAIN_HEAD="$shallow_main"; WT_ROOT="$shallow/worktrees"
eval "$ensure_clone_source"; eval "$checkout_pr_head_source"
DISPATCHED=(); GH_HEAD="$SR2"
units "{\"units\":[{\"id\":\"pr-shallow-7\",\"pr\":77,\"stage\":\"rereview-pending\",\"reviewed_sha\":\"$SR1\",\"reviewed_pr_head\":\"$SR1\",\"review_report\":\"review-shallow-7-T1.md\",\"history\":[]}]}"
dispatch_pending || :
[[ "${DISPATCHED[0]:-}" == "rereview:pr-shallow-7:$SR2" && "$DISPATCH_PR_HEAD" == "$SR2" ]] \
  || fail "a shallow worker clone fell back to a full review instead of rereview (got ${DISPATCHED[*]:-none})"
[[ "$DISPATCH_PROMPT" == *"$SR1..$SR2"* ]] || fail 'shallow-clone rereview did not retain its repair delta'
eval "$ensure_clone_stub"; eval "$checkout_pr_head_stub"
ROOT="$saved_root"; MAIN_HEAD="$saved_main_head"; WT_ROOT="$saved_wt_root"
GH_HEAD="$saved_gh_head"

DISPATCHED=()
units '{"units":[
 {"id":"pr-8","pr":8,"stage":"repair-pending","history":[{"stage":"review-request-changes"},{"stage":"review-request-changes"},{"stage":"review-request-changes"},{"stage":"review-request-changes"},{"stage":"review-request-changes"}]},
 {"id":"pr-9","pr":9,"stage":"ready-to-merge","history":[{"stage":"review-request-changes"},{"stage":"repair-delivered"},{"stage":"review-request-changes"},{"stage":"repair-delivered"},{"stage":"review-approve"},{"stage":"x"}]}]}'
dispatch_pending || :
[[ "$(field pr-8 .stage)" == review-pending && "$(field pr-8 .arbiter)" == true ]] || fail 'loop-breaker did not turn 5 failed rounds into one arbiter review'
[[ "$(field pr-8 '.history[-1].decision.decision')" == 'Route to one arbiter review' \
  && "$(field pr-8 '.history[-1].decision.why')" == 'review loop reached breaker threshold' \
  && "$(field pr-8 '.history[-1].decision.evidence')" == '5 failed rounds; no prior arbiter review' \
  && "$(field pr-8 '.history[-1].decision.owner')" == scheduler ]] || fail 'loop-breaker arbiter choice lacks its decision record'
[[ "$(field pr-9 .stage)" == ready-to-merge ]] || fail 'loop-breaker parked an approved unit'
units '{"units":[{"id":"pr-8","pr":8,"stage":"repair-pending","history":[{"stage":"arbiter-review"},{"stage":"review-request-changes"},{"stage":"review-request-changes"},{"stage":"review-request-changes"},{"stage":"review-request-changes"},{"stage":"review-request-changes"}]}]}'
DISPATCHED=()
dispatch_pending || :
[[ "$(field pr-8 .stage)" == supervisor-review \
  && "$(field pr-8 '.history[-1].decision.decision')" == 'Stop automated repair and escalate to supervisor' \
  && "$(field pr-8 '.history[-1].decision.evidence')" == '5 failed rounds after an arbiter review' ]] || fail 'loop-breaker after an arbiter review did not record its stop decision'
# supervisor-requeue 之后重新计回合
units '{"units":[{"id":"pr-8b","pr":8,"stage":"review-pending","history":[{"stage":"review-request-changes"},{"stage":"review-request-changes"},{"stage":"review-request-changes"},{"stage":"review-request-changes"},{"stage":"review-request-changes"},{"stage":"supervisor-requeue"},{"stage":"review-request-changes"}]}]}'
DISPATCHED=()
dispatch_pending || :
[[ "$(field pr-8b .stage)" != supervisor-review && "${DISPATCHED[0]:-}" == review:pr-8b:* ]] || fail 'supervisor-requeue did not reset the loop-breaker count'
# 终身上限：重排清零了 loop_rounds，但总共 8 轮打回仍转 supervisor 拆票，且裁决后再给 4 轮（pr-3863）
rc8='{"stage":"review-request-changes"}'
units "{\"units\":[{\"id\":\"pr-8c\",\"pr\":8,\"stage\":\"repair-pending\",\"history\":[$rc8,$rc8,$rc8,$rc8,{\"stage\":\"supervisor-requeue\"},$rc8,$rc8,$rc8,{\"stage\":\"supervisor-requeue\"},$rc8]}]}"
DISPATCHED=()
dispatch_pending || :
[[ "$(field pr-8c .stage)" == supervisor-review && "$(field pr-8c .note)" == non-converging:* && "$(field pr-8c .loop_total_allowed)" == 12 && -z "${DISPATCHED[0]:-}" ]] \
  || fail "8 request-changes rounds in total did not go to the supervisor for a re-scope ($(field pr-8c .stage) $(field pr-8c .loop_total_allowed))"
set_unit pr-8c '.stage="repair-pending" | .note=""'
dispatch_pending || :
[[ "$(field pr-8c .stage)" != supervisor-review ]] || [[ "$(field pr-8c .note)" != non-converging:* ]] || fail 'a supervisor-requeued unit was escalated again before its 4 extra rounds'

# 评审范围：CI/描述措辞不作结论依据；快车道评审本地提交、PR head/CI 不同步不阻断
[[ "$(review_prompt 1 t "$H1" r.md)" == *".agents/skills/zf-code-review/SKILL.md"* ]] || fail 'review prompt lacks the canonical contract reference'
[[ "$(review_prompt 1 t "$H1" r.md direct-main)" == *"直落 main"*"$H1"* || "$(review_prompt 1 t "$H1" r.md direct-main)" == *"$H1"*"直落 main"* ]] || fail 'direct-main review prompt lacks the lane rule'
[[ "$(review_prompt 1 t "$H1" r.md pr)" != *"非产品快车道"* ]] || fail 'PR-lane review prompt got the fast-lane rule'

# repair 先合入最新 main：落后过多的分支过不了 push preflight 的 freshness 门禁（#3859 三轮修复都没推上）
DISPATCHED=(); DISPATCH_PROMPT=""
units '{"units":[{"id":"pr-14","pr":14,"stage":"repair-pending","review_report":"review-14.md","history":[]}]}'
dispatch_pending || :
[[ "${DISPATCHED[0]:-}" == repair:pr-14:* && "$DISPATCH_PROMPT" == *"git merge --no-edit origin/main"* && "$DISPATCH_PROMPT" != *"禁止：动主 checkout、merge"* ]] || fail 'repair prompt does not merge origin/main before pushing (or still forbids merge)'

# ---------- 合并门：批准必须等于当前 head，merge 带 --match-head-commit ----------
MAIN_HEAD="$M1"
gate_eval_sha() { printf '%s' "$M1"; }
git() {
  if [[ " $* " == *" ls-remote "* ]]; then printf '%s\trefs/heads/main\n' "$MAIN_HEAD"
  elif [[ "${1:-}" == -C && "${3:-}" == fetch && "${!#}" == refs/pull/*/head ]]; then return 0
  elif [[ "${1:-}" == -C && "${3:-}" == rev-parse && "${5:-}" == FETCH_HEAD* ]]; then echo "$GH_HEAD"
  else command git "$@"; fi
}
mkdir -p "$ROOT/engine"
cat > "$ROOT/engine/rule-lane.sh" <<'SH'
#!/usr/bin/env bash
printf 'rule-lane: decision=pass actor=%s touched=0\n' "${ZF_AGENT_NAME:-unit}"
SH
GH_RUNS="[{\"headSha\":\"$M1\",\"conclusion\":\"success\",\"status\":\"completed\",\"createdAt\":\"2026-10-19T00:00:00Z\",\"databaseId\":7}]"
units "{\"units\":[{\"id\":\"pr-10\",\"pr\":10,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H2\",\"history\":[]}]}"
run_merge_lane || :
[[ ${#GH_MERGES[@]} == 0 && "$(field pr-10 .stage)" == rereview-pending ]] || fail 'PR merged although head moved after approval'
units "{\"units\":[{\"id\":\"pr-11\",\"pr\":11,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H1\",\"history\":[]}]}"
GH_MERGE_SHA="$M2"
GH_CHECKS='[{"name":"Pipeline suites","bucket":"pass"}]'
run_merge_lane || :
unset GH_CHECKS
[[ "${GH_MERGES[0]:-}" == *"--match-head-commit $H1"* ]] || fail "merge not pinned to the approved head (${GH_MERGES[*]:-none})"
[[ "$(field pr-11 .stage)" == merged && "$(field pr-11 .merge_sha)" == "$M2" ]] || fail 'a green pipeline PR did not merge straight to merged'
# Pipeline PRs merge independently on their own checks: no batch, no merging state, no interim-run cancel.
gh_int_saved="$(declare -f gh)"
gh() {
  if [[ "$1 $2 $3 $5" == "pr view 11 mergeCommit" ]]; then echo "$M1"
  elif [[ "$1 $2 $3 $5" == "pr view 12 mergeCommit" ]]; then echo "$M2"
  else eval "${gh_int_saved/gh ()/gh_i ()}"; gh_i "$@"; fi
}
units "{\"units\":[{\"id\":\"pr-11\",\"pr\":11,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H1\",\"history\":[]},{\"id\":\"pr-12\",\"pr\":12,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H1\",\"history\":[]}]}"
GH_CHECKS='[{"name":"Pipeline suites","bucket":"pass"}]'
run_merge_lane || :; unset GH_CHECKS
[[ "$(field pr-11 .stage)" == merged && "$(field pr-12 .stage)" == merged && "$(field pr-12 '.batch_tip // "none"')" == none ]] || fail 'two ready pipeline PRs did not merge independently'
eval "$gh_int_saved"; GH_MERGES=()
grep -q 'merge lane open' "$A/alerts/gate.md" || fail 'gate status not recorded'
lines="$(wc -l < "$A/alerts/gate.md")"
gate_note "GATE main=$M1 suites=success — merge lane open"
[[ "$(wc -l < "$A/alerts/gate.md")" == "$lines" ]] || fail 'unchanged gate state was re-appended'

# Required checks use the deployed shared definition; missing/skipping/neutral
# rows cannot merge and must not change stage, cancel, or rerun anything.
(
  # required_checks_without_pass deliberately uses `command gh --version`, so
  # pin the external CLI used by this synthetic merge fixture instead of
  # inheriting the cihost runner's installed version.
  gh_cli_stub="$fixture/gh-cli"
  mkdir -p "$gh_cli_stub"
  cat > "$gh_cli_stub/gh" <<'SH'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  printf 'gh version %s (fixture)\n' "${FIXTURE_GH_VERSION:-2.50.0}"
  exit 0
fi
exit 98
SH
  chmod +x "$gh_cli_stub/gh"
  PATH="$gh_cli_stub:$PATH"
  export PATH
  REQUIRED_PR_CHECKS_FILE="$script_dir/required-pr-checks.json"
  passing_checks="$(jq -c '.required | map({name:.,bucket:"pass"})' "$REQUIRED_PR_CHECKS_FILE")"
  FIXTURE_GH_VERSION=2.49.0; export FIXTURE_GH_VERSION
  [[ "$(required_checks_without_pass "$passing_checks")" == 'gh 2.49.0 is older than required 2.50.0' ]] \
    || fail 'an older GitHub CLI version did not fail the required-check guard'
  FIXTURE_GH_VERSION=2.50.0
  for aggregate_bucket in missing skipping neutral; do
    GH_CHECKS="$(jq -c --arg bucket "$aggregate_bucket" '
      map(select(.name != "Required CI gates")) +
      (if $bucket == "missing" then [] else [{name:"Required CI gates",bucket:$bucket}] end)
    ' <<< "$passing_checks")"
    units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-required",pr:11,stage:"ready-to-merge",approved_sha:$sha,history:[]}]}')"
    GH_MERGES=(); GH_RERUNS=(); : > "$LOG"
    cancel_branch_runs() { fail 'required-check block cancelled a run'; }
    run_merge_lane || :
    [[ ${#GH_MERGES[@]} == 0 && ${#GH_RERUNS[@]} == 0 && "$(field pr-required .stage)" == ready-to-merge ]] || fail "$aggregate_bucket aggregate did not leave the merge blocked without side effects"
    grep -Fq 'merge skipped PR#11 (required checks without a real pass: Required CI gates)' "$LOG" || fail "$aggregate_bucket aggregate lacks the required-check log"
  done
  # The aggregate is the single required source (#4484): heavy gates that legitimately did not
  # run (only skipping rows) no longer block the merge when the aggregate row is green.
  GH_CHECKS="$(jq -c '. + [{name:"Touched packages PR gate",bucket:"skipping"},{name:"Example pack PR gate",bucket:"skipping"}]' <<< "$passing_checks")"
  units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-required",pr:11,stage:"ready-to-merge",approved_sha:$sha,history:[]}]}')"
  GH_MERGES=(); run_merge_lane || :
  [[ "${GH_MERGES[0]:-}" == *"pr merge 11"* && "$(field pr-required .stage)" == merged ]] || fail 'skipping heavy rows blocked a green aggregate from merging'
  ready_at='2026-10-28T22:00:00Z'
  GH_CHECKS="$(jq -c --arg started_at '2026-10-28T21:59:59Z' '
    .required | map({name:.,bucket:"pass",started_at:$started_at})
  ' "$REQUIRED_PR_CHECKS_FILE")"
  units "$(jq -cn --arg sha "$H1" --arg ready "$ready_at" '{units:[{id:"pr-ready-event",pr:11,branch:"agent/issue-11",stage:"ready-to-merge",approved_sha:$sha,gated:true,ci_ready_sha:$sha,ci_ready_at:$ready,history:[]}]}')"
  GH_MERGES=(); : > "$LOG"
  run_merge_lane || :
  [[ ${#GH_MERGES[@]} == 0 && "$(field pr-ready-event .stage)" == ready-to-merge ]] || fail 'checks from before ready_for_review satisfied the merge gate'
  grep -Fq 'merge skipped PR#11 (required checks without a real pass:' "$LOG" || fail 'stale checks lack the required-check block reason'
  GH_CHECKS="$(jq -c --arg started_at '2026-10-28T22:00:00.123456Z' '.required | map({name:.,bucket:"pass",started_at:$started_at})' "$REQUIRED_PR_CHECKS_FILE")"
  units "$(jq -cn --arg sha "$H1" --arg ready "$ready_at" '{units:[{id:"pr-ready-event",pr:11,branch:"agent/issue-11",stage:"ready-to-merge",approved_sha:$sha,gated:true,ci_ready_sha:$sha,ci_ready_at:$ready,history:[]}]}')"
  GH_MERGES=(); run_merge_lane || :
  [[ "${GH_MERGES[0]:-}" == *"pr merge 11"* && "$(field pr-ready-event .stage)" == merged ]] || fail 'checks started at ready_for_review did not satisfy the merge gate'
  # #4484：非 agent 分支的接管 PR 首拍先补 pipeline-ci 标签（labeled 事件开 CI）并记账时间下限，
  # 打标签前的聚合绿行不能直接拿来合入；第二个拍检查行早于下限仍不合，晚于下限才合。
  : > "$fixture/pr-edit.calls"
  unset GH_PR_TABLE
  GH_CHECKS="$passing_checks"
  GH_PR_EDIT_STATUS=1
  units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-adopt-failed",pr:11,branch:"fix/dispatch-unique-sku-unit",stage:"ready-to-merge",approved_sha:$sha,history:[]}]}')"
  GH_MERGES=(); : > "$LOG"; run_merge_lane || :
  [[ ${#GH_MERGES[@]} == 0 && "$(cat "$fixture/pr-edit.calls")" == 'pr edit 11 --add-label pipeline-ci' ]] \
    || fail 'a failed pipeline-ci label add did not hold the merge'
  [[ "$(field pr-adopt-failed .ci_adopt_head)" == null ]] || fail 'a failed label add was recorded as successful adoption'
  grep -Fq 'pipeline-ci label event setup failed; retried next pass' "$LOG" || fail 'a failed label event setup has no retry reason'
  unset GH_PR_EDIT_STATUS

  : > "$fixture/pr-edit.calls"
  units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-adopt",pr:11,branch:"fix/dispatch-unique-sku-unit",stage:"ready-to-merge",approved_sha:$sha,history:[]}]}')"
  GH_MERGES=(); : > "$LOG"; run_merge_lane || :
  [[ ${#GH_MERGES[@]} == 0 && "$(cat "$fixture/pr-edit.calls")" == 'pr edit 11 --add-label pipeline-ci' ]] \
    || fail 'a non-agent adopted PR was not labeled pipeline-ci instead of merging'
  [[ "$(field pr-adopt .ci_adopt_head)" == "$H1" && "$(field pr-adopt .ci_adopt_at)" != null ]] || fail 'adoption did not pin the head and its time floor'
  grep -Fq 'adopt PR#11: pipeline-ci label event started branch policy and heavy gates' "$LOG" || fail 'adoption lacks its log line'

  # An old/manual pipeline-ci label makes --add-label a no-op. Remove and add it back
  # so both pull_request and pull_request_target receive a new labeled event.
  cp "$fixture/pr-edit.calls" "$fixture/pr-edit.calls.before-existing-label"
  GH_PR_TABLE="$fixture/pr-adopt-existing-label.json"
  jq -cn --arg sha "$H1" '[{number:11,headRefOid:$sha,headRefName:"fix/dispatch-unique-sku-unit",isDraft:false,title:"adopted PR",labels:[{name:"pipeline-ci"}],statusCheckRollup:[]}]' > "$GH_PR_TABLE"
  : > "$fixture/pr-edit.calls"
  units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-adopt-existing-label",pr:11,branch:"fix/dispatch-unique-sku-unit",stage:"ready-to-merge",approved_sha:$sha,history:[]}]}')"
  GH_MERGES=(); : > "$LOG"; run_merge_lane || :
  [[ "$(cat "$fixture/pr-edit.calls")" == $'pr edit 11 --remove-label pipeline-ci\npr edit 11 --add-label pipeline-ci' ]] \
    || fail 'a pre-existing adoption label did not produce a fresh labeled event'
  jq -e 'any(.[] | select(.number == 11) | .labels[]?; .name == "pipeline-ci")' "$GH_PR_TABLE" >/dev/null \
    || fail 'refreshing the adoption label did not leave it attached'
  [[ ${#GH_MERGES[@]} == 0 && "$(field pr-adopt-existing-label .ci_adopt_head)" == "$H1" \
      && "$(field pr-adopt-existing-label .ci_adopt_at)" != null ]] \
    || fail 'a pre-existing adoption label was recorded without holding for fresh checks'
  grep -Fq 'label event started branch policy and heavy gates' "$LOG" || fail 'pre-existing label refresh lacks its log line'
  unset GH_PR_TABLE
  mv "$fixture/pr-edit.calls.before-existing-label" "$fixture/pr-edit.calls"

  adopt_at='2026-10-29T10:00:00Z'
  GH_CHECKS="$(jq -c --arg started_at '2026-10-29T09:59:59Z' '.required | map({name:.,bucket:"pass",started_at:$started_at})' "$REQUIRED_PR_CHECKS_FILE")"
  units "$(jq -cn --arg sha "$H1" --arg at "$adopt_at" '{units:[{id:"pr-adopt",pr:11,branch:"fix/dispatch-unique-sku-unit",stage:"ready-to-merge",approved_sha:$sha,ci_adopt_head:$sha,ci_adopt_at:$at,history:[]}]}')"
  GH_MERGES=(); : > "$LOG"; run_merge_lane || :
  [[ ${#GH_MERGES[@]} == 0 ]] || fail 'pre-adoption green rows satisfied the merge gate'
  grep -Fq 'merge skipped PR#11 (required checks without a real pass:' "$LOG" || fail 'pre-adoption rows lack the required-check block reason'
  [[ "$(wc -l < "$fixture/pr-edit.calls")" == 1 ]] || fail 'an already-adopted head was labeled again'
  GH_CHECKS="$(jq -c --arg started_at '2026-10-29T10:00:01Z' '.required | map({name:.,bucket:"pass",started_at:$started_at})' "$REQUIRED_PR_CHECKS_FILE")"
  GH_MERGE_SHA="$M2"
  run_merge_lane || :
  [[ "${GH_MERGES[0]:-}" == *"pr merge 11"* && "$(field pr-adopt .stage)" == merged ]] || fail 'post-adoption green rows did not merge'
  # A later synchronize event has already launched CI because the adoption label remains on
  # the PR. Advancing the ledger head must preserve the first label timestamp, not label again
  # or move the freshness floor past those synchronize checks.
  adopt_at="$(field pr-adopt .ci_adopt_at)"
  GH_HEAD="$H2"; GH_MERGE_SHA="$M3"
  units "$(jq -cn --arg old "$H1" --arg head "$H2" --arg at "$adopt_at" '{units:[{id:"pr-adopt-next-head",pr:11,branch:"fix/dispatch-unique-sku-unit",stage:"ready-to-merge",approved_sha:$head,ci_adopt_head:$old,ci_adopt_at:$at,history:[]}]}')"
  GH_MERGES=(); run_merge_lane || :
  [[ ${#GH_MERGES[@]} == 0 && "$(field pr-adopt-next-head .ci_adopt_head)" == "$H2" ]] \
    || fail 'a new adopted head was not recorded before reading synchronize checks'
  [[ "$(field pr-adopt-next-head .ci_adopt_at)" == "$adopt_at" ]] \
    || fail 'a synchronize head reset the adoption freshness floor after CI had started'
  [[ "$(wc -l < "$fixture/pr-edit.calls")" == 1 ]] || fail 'a new head re-added the existing pipeline-ci label'
  run_merge_lane || :
  [[ "${GH_MERGES[0]:-}" == *"pr merge 11"* && "$(field pr-adopt-next-head .stage)" == merged ]] \
    || fail 'fresh synchronize checks on an already-adopted label did not merge'
  # #4484：分支自带的 workflow 先于聚合 job 的，永远没有聚合行：落后 main 且干净就服务端
  # update-branch 刷新分支 workflow（批准由 approval_carries 沿用），不再永久等待。
  UPDATE_BRANCH_CALLS="$fixture/update-branch.calls"; : > "$UPDATE_BRANCH_CALLS"
  ci_update_branch_saved="$(declare -f ci_update_branch)"; pr_behind_saved="$(declare -f pr_behind_main)"
  ci_update_branch() { printf '%s %s\n' "$1" "$2" >> "$UPDATE_BRANCH_CALLS"; return 0; }
  pr_behind_main() { return 0; }
  pr_view_saved="$(declare -f pr_view)"
  pr_view() { case "$2" in state) echo OPEN ;; headRefOid) echo "$GH_HEAD" ;; mergeable) echo "${GH_MERGEABLE_STATE:-MERGEABLE}" ;; mergeCommit) echo "$GH_MERGE_SHA" ;; *) echo "" ;; esac; }
  GH_HEAD="$H1"
  GH_CHECKS='[{"name":"Enforce branch delivery policy","bucket":"pass"}]'
  units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-stale-wf",pr:11,branch:"agent/issue-11",stage:"ready-to-merge",approved_sha:$sha,history:[]}]}')"
  GH_MERGES=(); : > "$LOG"; run_merge_lane || :
  [[ "$(cat "$UPDATE_BRANCH_CALLS")" == "11 $H1" && ${#GH_MERGES[@]} == 0 ]] || fail 'a missing aggregate row on a stale branch did not request update-branch'
  grep -Fq 'update-branch refreshes the branch workflows' "$LOG" || fail 'the workflow refresh lacks its log line'
  [[ "$(field pr-stale-wf .ci_sync_head)" == "$H1" ]] || fail 'the workflow refresh was not pinned to the head'
  # 同一 head 不重复请求；冲突照旧派修复合 main。
  : > "$UPDATE_BRANCH_CALLS"
  run_merge_lane || :
  [[ -s "$UPDATE_BRANCH_CALLS" ]] && fail 'update-branch was requested twice for the same head'
  GH_MERGEABLE_STATE=CONFLICTING
  units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-stale-wf2",pr:11,branch:"agent/issue-11",stage:"ready-to-merge",approved_sha:$sha,history:[]}]}')"
  run_merge_lane || :
  [[ "$(field pr-stale-wf2 .stage)" == repair-pending ]] || fail 'a conflicting stale branch was not routed to repair'
  eval "$pr_view_saved"; eval "$ci_update_branch_saved"; eval "$pr_behind_saved"
  unset GH_MERGEABLE_STATE
  GH_CHECKS="$passing_checks"
  REQUIRED_PR_CHECKS_FILE="$fixture/absent-required-pr-checks.json"
  units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-required",pr:11,stage:"ready-to-merge",approved_sha:$sha,history:[]}]}')"
  GH_MERGES=(); GH_RERUNS=(); : > "$LOG"
  run_merge_lane || :
  [[ ${#GH_MERGES[@]} == 0 && ${#GH_RERUNS[@]} == 0 && "$(field pr-required .stage)" == ready-to-merge ]] || fail 'unreadable required checks did not block without side effects'
  grep -Fq 'merge skipped PR#11 (required checks without a real pass: required-pr-checks.json unreadable)' "$LOG" || fail 'unreadable required checks lack the reason'
)

# A draft PR with otherwise green checks must never reach gh pr merge.
(
  GH_PR_TABLE="$fixture/draft-merge.json"; echo '[]' > "$GH_PR_TABLE"
  gh_pr_open 11 "$H1" true MERGEABLE agent/issue-11
  units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-draft-merge",pr:11,branch:"agent/issue-11",stage:"ready-to-merge",approved_sha:$sha,gated:true,ci_ready_sha:$sha,ci_ready_at:"2026-10-28T22:00:00Z",history:[]}]}')"
  tick_prs_changed; GH_MERGES=(); : > "$LOG"
  run_merge_lane || :
  [[ ${#GH_MERGES[@]} == 0 && "$(field pr-draft-merge .stage)" == ready-to-merge ]] || fail 'a draft PR reached gh pr merge'
  grep -Fq 'merge skipped PR#11 (draft' "$LOG" || fail 'draft merge block lacks its reason'
  # slot_sync 的 update-branch 让 draft 的 head 变了：批准要在 draft 跳过之前沿用，否则名额永远不 ready（10-29 卡死 8 个名额）
  echo '[]' > "$GH_PR_TABLE"; gh_pr_open 11 "$H2" true MERGEABLE agent/issue-11
  units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-draft-merge",pr:11,branch:"agent/issue-11",stage:"ready-to-merge",approved_sha:$sha,gated:true,history:[]}]}')"
  approval_carries() { [[ "$2" == "$H1" && "$3" == "$H2" ]]; }
  tick_prs_changed; GH_MERGES=(); : > "$LOG"
  run_merge_lane || :
  [[ "$(field pr-draft-merge .approved_sha)" == "$H2" && ${#GH_MERGES[@]} == 0 ]] || fail 'a draft whose head moved by a clean update-branch did not carry its approval'
)

# L69：候选检查并行预取，只等预取进程——worker 也是本 shell 的后台子进程，合并车道不能等它们
sleep 30 & bg_worker=$! # wall-clock-allow: proves the merge lane does not wait for an unrelated long-running background child
t0=$SECONDS # wall-clock-allow: proves the merge lane does not wait for an unrelated long-running background child
units "{\"units\":[{\"id\":\"pr-11b\",\"pr\":11,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H2\",\"history\":[]}]}"
run_merge_lane || :
(( SECONDS - t0 < 20 )) || fail "merge lane waited for an unrelated background worker" # wall-clock-allow: proves the merge lane does not wait for an unrelated long-running background child
kill "$bg_worker" 2>/dev/null; wait "$bg_worker" 2>/dev/null || :
# ---------- 合并车道：CI 红先重跑一次，同一 head 重跑后仍红才派 repair（不再每拍空转） ----------
gh_merge_stub="$(declare -f gh)"
gh() { if [[ "$*" == "run list --commit"*"select(.conclusion"* ]]; then echo 99; else eval "${gh_merge_stub/gh ()/gh_m ()}"; gh_m "$@"; fi; }
GH_CHECKS='[{"name":"suites","bucket":"fail"},{"name":"lint","bucket":"pass"}]'
GH_MERGES=(); GH_RERUNS=()
units "{\"units\":[{\"id\":\"pr-12\",\"pr\":12,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H1\",\"review_report\":\"r.md\",\"history\":[]}]}"
run_merge_lane || :
[[ ${#GH_MERGES[@]} == 0 && "$(field pr-12 .stage)" == ready-to-merge && "$(field pr-12 .ci_rerun_sha)" == "$H1" ]] || fail 'first red CI was not just rerun'
[[ "${GH_RERUNS[*]:-}" == *"rerun 99 --failed"* ]] || fail "failed run not rerun (${GH_RERUNS[*]:-none})"
run_merge_lane || :
[[ "$(field pr-12 .stage)" == repair-pending && "$(field pr-12 '.approved_sha // "none"')" == none ]] || fail 'CI still red after rerun not sent to repair'
[[ "$(field pr-12 .repair_hint)" == *suites* ]] || fail 'repair hint lacks the failing check'
# L64：只有取消、没有失败的检查（流水线自己取消的）不是代码结论：重启被取消的 job，不耗重跑额度、不作废批准；
# 已用过重跑额度的 head 也一样（pr-2609）。同一 head 连续 3 次后交 supervisor。
GH_CHECKS='[{"name":"suites","bucket":"cancel"},{"name":"lint","bucket":"pass"}]'; GH_RERUNS=()
units "{\"units\":[{\"id\":\"pr-13\",\"pr\":13,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H1\",\"ci_rerun_sha\":\"$H1\",\"history\":[]}]}"
run_merge_lane || :
[[ "$(field pr-13 .stage)" == ready-to-merge && "$(field pr-13 .approved_sha)" == "$H1" && "$(field pr-13 .ci_cancel_reruns)" == 1 ]] || fail "cancelled-only checks dropped the approval or went to repair ($(field pr-13 .stage))"
[[ "${GH_RERUNS[*]:-}" == *"rerun 99 --failed"* ]] || fail "cancelled run not restarted (${GH_RERUNS[*]:-none})"
run_merge_lane || :; run_merge_lane || :
[[ "$(field pr-13 .stage)" == ready-to-merge && "$(field pr-13 .ci_cancel_reruns)" == 3 ]] || fail 'cancel restarts not counted per head'
run_merge_lane || :
[[ "$(field pr-13 .stage)" == supervisor-review && "$(field pr-13 .approved_sha)" == "$H1" \
  && "$(field pr-13 '.history[-1].decision.decision')" == 'Stop CI retries and escalate repeated cancellation to supervisor' \
  && "$(field pr-13 '.history[-1].decision.evidence')" == "head $H1 after 3 restarts:"* ]] || fail 'repeatedly cancelled checks were not bounded and recorded'
# L77：PR CI 名额不再是配置的 ci_wip，而是在线 PR runner 减去这些 runner 上在跑的 job（60ba960cf）。
# 等名额的单元（.ci_wip_wait 绑定 head）按 main-red > opt > normal、同级 ready_since 补进空槽，
# 只补被取消的 job；热修不占名额。没等到名额的排队 run 取消并留在 .ci_wip_wait；
# 等名额的单元只有取消、没有失败时合并车道不重启；名额空出后按就绪先后补跑被取消的 job。
wr="$fixture/wip-root"; mkdir -p "$wr/engine/night"
printf '#!/usr/bin/env bash\necho "$2" >> "%s/cancelled"\necho "${ZF_CANCEL_REASON-unset}" >> "%s/reasons"\n' "$wr" "$wr" > "$wr/engine/night/main-ci-recovery.sh"
CFG_SAVED="$CFG"; CFG="$(jq '.precheck=false' <<<"$CFG")"; GH_RERUNS=()
# 默认 runner 桩：1 个在线 PR runner、无在跑 job → 1 个空槽
units "{\"units\":[{\"id\":\"pr-30\",\"pr\":30,\"stage\":\"ready-to-merge\",\"branch\":\"a\",\"approved_sha\":\"$H2\",\"ci_adopt_head\":\"$H2\",\"ci_adopt_at\":\"2026-10-29T00:00:00Z\",\"ci_wip_wait\":\"$H2\",\"ready_since\":1,\"history\":[]},{\"id\":\"pr-31\",\"pr\":31,\"stage\":\"ready-to-merge\",\"branch\":\"b\",\"approved_sha\":\"$H1\",\"ci_adopt_head\":\"$H1\",\"ci_adopt_at\":\"2026-10-29T00:00:00Z\",\"ci_wip_wait\":\"$H1\",\"ready_since\":2,\"history\":[]},{\"id\":\"pr-32\",\"pr\":32,\"stage\":\"ready-to-merge\",\"hotpatch\":true,\"branch\":\"hp\",\"approved_sha\":\"$H2\",\"ci_adopt_head\":\"$H2\",\"ci_adopt_at\":\"2026-10-29T00:00:00Z\",\"ready_since\":3,\"history\":[]}]}"
TICK_UNFINISHED="[{\"databaseId\":81,\"status\":\"queued\",\"event\":\"pull_request\",\"headBranch\":\"b\"},{\"databaseId\":83,\"status\":\"queued\",\"event\":\"pull_request\",\"headBranch\":\"hp\"}]"
GH_RUN_JSON='[{"databaseId":82,"conclusion":"cancelled"}]'
root_saved="$ROOT"; ROOT="$wr"; ci_wip_gate_test; ROOT="$root_saved"
[[ "$(field pr-30 '.history[-1].stage'):$(field pr-30 '.history[-1].result')" == "ci-wip-start:slot 1/1" \
  && "${GH_RERUNS[*]:-}" == "run rerun 82 --failed" && "$(field pr-30 '.ci_wip_wait // "none"')" == none ]] \
  || fail "the oldest waiting unit did not take the free runner slot (${GH_RERUNS[*]:-none})"
[[ "$(cat "$wr/cancelled" 2>/dev/null)" == 81 && "$(field pr-31 .ci_wip_wait)" == "$H1" && "$(field pr-32 '.ci_wip_wait // "none"')" == none ]] \
  || fail "WIP gate held the wrong runs ($(tr '\n' ' ' < "$wr/cancelled" 2>/dev/null))"
[[ "$(sort -u "$wr/reasons")" == "ci wip" ]] || fail "WIP gate cancel did not carry its reason ($(tr '\n' ',' < "$wr/reasons"))"
grep -q 'ci wip: 1 free PR runner slot(s)' "$LOG" || fail 'slot count was not sized from the online PR runners'
GH_CHECKS='[{"name":"suites","bucket":"cancel"}]'
run_merge_lane || :
grep -q 'merge skipped PR#31 (CI waits for a WIP slot)' "$LOG" && [[ "$(field pr-31 '.ci_cancel_reruns // 0')" == 0 ]] || fail 'merge lane restarted CI of a unit waiting for a WIP slot'
set_unit pr-30 '.stage="merged"'; set_unit pr-31 '.ci_cancel_reruns=2'; TICK_UNFINISHED='[]'; GH_RERUNS=()
GH_RUN_JSON='[{"databaseId":99,"conclusion":"cancelled"}]'
root_saved="$ROOT"; ROOT="$wr"; ci_wip_gate_test; ROOT="$root_saved"
[[ "${GH_RERUNS[*]:-}" == *"rerun 99 --failed"* && "$(field pr-31 '.ci_wip_wait // "none"')" == none ]] || fail "freed runner slot did not start the next unit's CI (${GH_RERUNS[*]:-none})"
[[ "$(field pr-31 '.ci_cancel_reruns // "none"')" == none ]] || fail 'WIP start kept the cancel-restart count from the WIP wait (L78)'
# 非产品 PR 不排 CI 名额；同级先按 ready_since，依赖只在 readiness 相同时作 tie-break（maintainer 10-22：非产品尽快）
CFG="$(jq '.precheck=false' <<<"$CFG_SAVED")"; : > "$wr/cancelled"; GH_RUN_JSON='[]'
units "{\"units\":[{\"id\":\"pr-40\",\"pr\":40,\"stage\":\"ready-to-merge\",\"branch\":\"c\",\"approved_sha\":\"$H1\",\"ci_wip_wait\":\"$H1\",\"ready_since\":1,\"history\":[]},{\"id\":\"pr-41\",\"pr\":41,\"stage\":\"ready-to-merge\",\"branch\":\"agent/issue-77\",\"approved_sha\":\"$H1\",\"ci_wip_wait\":\"$H1\",\"ready_since\":2,\"history\":[]},{\"id\":\"pr-42\",\"pr\":42,\"stage\":\"ready-to-merge\",\"branch\":\"ci/x\",\"approved_sha\":\"$H1\",\"ready_since\":0,\"history\":[]},{\"id\":\"issue-78\",\"issue\":78,\"stage\":\"blocked-external\",\"blocked_on\":77,\"history\":[]}]}"
gh() { if [[ "$1 $2" == "pr view" && "$*" == *files* ]]; then case "$3" in 42) printf '.github/workflows/ci.yml\nscripts/agent/x.sh\nREADME.md\n' ;; *) printf 'packages/shared/a.ts\nscripts/b.sh\n' ;; esac; else eval "${gh_merge_stub/gh ()/gh_m ()}"; gh_m "$@"; fi; }
TICK_UNFINISHED="[{\"databaseId\":91,\"status\":\"queued\",\"event\":\"pull_request\",\"headBranch\":\"c\"},{\"databaseId\":92,\"status\":\"queued\",\"event\":\"pull_request\",\"headBranch\":\"agent/issue-77\"},{\"databaseId\":93,\"status\":\"queued\",\"event\":\"pull_request\",\"headBranch\":\"ci/x\"}]"
root_saved="$ROOT"; ROOT="$wr"; ci_wip_gate_test; ROOT="$root_saved"
[[ "$(field pr-42 .product_paths):$(field pr-40 .product_paths)" == "false:true" ]] || fail "product paths not classified ($(field pr-42 .product_paths) $(field pr-40 .product_paths))"
[[ "$(field pr-40 '.history[-1].stage')" == ci-wip-start && "$(field pr-40 '.ci_wip_wait // "none"')" == none ]] \
  || fail "the free slot did not follow same-class readiness ($(field pr-40 '.history[-1].stage // "none"'))"
[[ "$(cat "$wr/cancelled")" == 92 && "$(field pr-41 .ci_wip_wait)" == "$H1" && "$(field pr-42 '.ci_wip_wait // "none"')" == none ]] \
  || fail "the next waiting unit's queued run was not cancelled or a non-product PR waited ($(tr '\n' ' ' < "$wr/cancelled"))"
GH_RUN_JSON=
# 本机预检：等名额的单元先在本机跑 PR 自己改动的测试；FAIL 直接返工、不占 CI 名额，PASS 才开始 CI（10-22 批准后 CI 红 14/14 在 PR 自己改的测试里）
CFG="$(jq '.precheck=true' <<<"$CFG_SAVED")"; GH_RERUNS=(); TICK_UNFINISHED='[]'; ALIVE_PIDS=""; mkdir -p "$fixture/wt-precheck"
wait_precheck_output() {
  local id="$1" attempt
  for ((attempt=0; attempt<50; attempt++)); do
    [[ -s "$SUP/precheck-pr-$id.out" ]] && return 0
    sleep 0.1
  done
  fail "precheck $id did not write a result"
}
units "{\"units\":[{\"id\":\"pr-50\",\"pr\":50,\"stage\":\"ready-to-merge\",\"branch\":\"p50\",\"approved_sha\":\"$H1\",\"ci_wip_wait\":\"$H1\",\"ready_since\":1,\"history\":[]},{\"id\":\"pr-51\",\"pr\":51,\"stage\":\"ready-to-merge\",\"branch\":\"p51\",\"approved_sha\":\"$H2\",\"ci_wip_wait\":\"$H2\",\"ready_since\":2,\"history\":[]}]}"
here_saved="$HERE"; HERE="$fixture/precheck-code"; mkdir -p "$HERE"
printf '#!/usr/bin/env bash\ncase "$2" in 50) printf "PRECHECK: FAIL changed tests fail locally in packages/x\\n FAIL  tests/a.test.ts > keeps totals\\n" ;; *) echo "PRECHECK: PASS changed tests pass locally in packages/y" ;; esac\n' > "$HERE/precheck.sh"
gh() { if [[ "$1 $2" == "pr view" && "$*" == *files* ]]; then echo packages/x/a.ts; elif [[ "$*" == "run list --commit"*"select(.conclusion"* ]]; then echo 99; else eval "${gh_merge_stub/gh ()/gh_m ()}"; gh_m "$@"; fi; }
root_saved="$ROOT"; ROOT="$wr"; ci_wip_gate_test; ROOT="$root_saved"
p50="$(field pr-50 '.precheck_pid // "none"')"
[[ "$p50" != none && "$(field pr-51 '.precheck_pid // "none"')" == none && "${GH_RERUNS[*]:-}" != *rerun* ]] || fail "unprechecked unit got a CI slot or prechecks ran in parallel (${GH_RERUNS[*]:-none})"
wait "$p50" 2>/dev/null || :
wait_precheck_output 50
root_saved="$ROOT"; ROOT="$wr"; ci_wip_gate_test; ROOT="$root_saved"
[[ "$(field pr-50 .stage):$(field pr-50 '.approved_sha // "none"'):$(field pr-50 '.ci_wip_wait // "none"')" == "repair-pending:none:none" && "$(field pr-50 .repair_hint)" == *"keeps totals"* ]] \
  || fail "local precheck failure did not go straight to repair with the failing test ($(field pr-50 .stage))"
p51="$(field pr-51 '.precheck_pid // "none"')"; [[ "$p51" != none ]] || fail 'next waiting unit was not prechecked'
wait "$p51" 2>/dev/null || :
wait_precheck_output 51
root_saved="$ROOT"; ROOT="$wr"; ci_wip_gate_test; ROOT="$root_saved"
[[ "$(field pr-51 .precheck_sha)" == "$H2" && "$(field pr-51 '.ci_wip_wait // "none"')" == none && "${GH_RERUNS[*]:-}" == *"rerun 99 --failed"* ]] \
  || fail "passing precheck did not start the unit's CI ($(field pr-51 '.ci_wip_wait // "none"') ${GH_RERUNS[*]:-none})"
# 名额按在跑 job 折算（60ba960cf）：两个在线 PR runner，run 60 的一个 job 占着 runner 1；
# 另一个在跑 job 在非 PR runner（cihost-ci-main）上，不占 PR 名额 → 1 个空槽。
# 已放行的 pr-52（CI 已在跑，无 ci_wip_wait）不重复占槽；排队中的 pr-53 没有预检结论也不占槽，先预检。
GH_RUNNERS='{"runners":[{"id":1,"status":"online","labels":[{"name":"cihost-ci"}]},{"id":2,"status":"online","labels":[{"name":"zf-suites"}]},{"id":3,"status":"online","labels":[{"name":"cihost-ci-main"}]},{"id":4,"status":"offline","labels":[{"name":"cihost-ci"}]}]}'
GH_RUN_JOBS='{"60":{"jobs":[{"status":"in_progress","runner_id":1},{"status":"in_progress","runner_id":3}]}}'
: > "$wr/cancelled"
units "{\"units\":[{\"id\":\"pr-52\",\"pr\":52,\"stage\":\"ready-to-merge\",\"branch\":\"p52\",\"approved_sha\":\"$H1\",\"precheck_sha\":\"$H1\",\"ready_since\":1,\"history\":[]},{\"id\":\"pr-53\",\"pr\":53,\"stage\":\"ready-to-merge\",\"branch\":\"p53\",\"approved_sha\":\"$H2\",\"ci_wip_wait\":\"$H2\",\"ready_since\":2,\"history\":[]}]}"
TICK_UNFINISHED="[{\"databaseId\":60,\"status\":\"in_progress\",\"event\":\"pull_request\",\"headBranch\":\"p52\",\"headSha\":\"$H1\"},{\"databaseId\":61,\"status\":\"queued\",\"event\":\"pull_request\",\"headBranch\":\"p53\"}]"
root_saved="$ROOT"; ROOT="$wr"; ci_wip_gate_test; ROOT="$root_saved"
p53="$(field pr-53 '.precheck_pid // "none"')"
[[ "$p53" != none && "$(field pr-52 '.precheck_pid // "none"')" == none ]] || fail 'queued unit was not prechecked ahead of its CI slot'
[[ "$(field pr-53 .ci_wip_wait)" == "$H2" && "$(cat "$wr/cancelled" 2>/dev/null)" == 61 ]] \
  || fail "the busy runner slot did not keep the next unit waiting ($(tr '\n' ' ' < "$wr/cancelled" 2>/dev/null))"
wait "$p53" 2>/dev/null || :
wait_precheck_output 53
# 预检 PASS 后：1 个空槽（2 runner − 1 在跑 job）正好放行 pr-53；slot 1/1 钉住名额算术
root_saved="$ROOT"; ROOT="$wr"; ci_wip_gate_test; ROOT="$root_saved"
[[ "$(field pr-53 '.history[-1].stage'):$(field pr-53 '.history[-1].result')" == "ci-wip-start:slot 1/1" ]] \
  || fail "a freed runner slot did not start the prechecked waiting unit ($(field pr-53 '.history[-1].stage // "none"'):$(field pr-53 '.history[-1].result // "none"'))"
GH_RUNNERS='{"runners":[{"id":1,"status":"online","labels":[{"name":"cihost-ci"}]},{"id":2,"status":"offline","labels":[{"name":"cihost-ci"}]},{"id":3,"status":"online","labels":[{"name":"cihost-ci-main"}]}]}'; GH_RUN_JOBS='{}'
rm -f "$HERE/precheck.sh"; HERE="$here_saved"
CFG="$CFG_SAVED"; TICK_UNFINISHED=""; GH_RERUNS=()
GH_CHECKS='[{"name":"suites","bucket":"fail"},{"name":"lint","bucket":"pass"}]'
# runner 环境步骤红（磁盘门）不是代码结论：保留批准再重跑，连红 3 次交 supervisor，不派 repair
gh() { if [[ "$*" == "run list --commit"*"select(.conclusion"* ]]; then echo 99; elif [[ "$*" == "api repos/{owner}/{repo}/actions/runs/99/jobs"* ]]; then printf '%s\n' "${GH_FAILED_STEPS[@]}"; else eval "${gh_merge_stub/gh ()/gh_m ()}"; gh_m "$@"; fi; }
GH_FAILED_STEPS=("Ensure CI runner has capacity before dependency install"); GH_RERUNS=()
units "{\"units\":[{\"id\":\"pr-14\",\"pr\":14,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H1\",\"ci_rerun_sha\":\"$H1\",\"history\":[]}]}"
run_merge_lane || :
[[ "$(field pr-14 .stage)" == ready-to-merge && "$(field pr-14 .approved_sha)" == "$H1" && "$(field pr-14 .ci_infra_reruns)" == 1 ]] || fail 'runner disk failure dropped the approval or went to repair'
[[ "${GH_RERUNS[*]:-}" == *"rerun 99 --failed"* ]] || fail 'runner disk failure not rerun'
grep -q "RUNNER-INFRA-RED PR#14 head=$H1 steps: Ensure CI runner has capacity" "$A/alerts/gate.md" || fail 'runner disk failure not reported'
units "{\"units\":[{\"id\":\"pr-14\",\"pr\":14,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H1\",\"ci_rerun_sha\":\"$H1\",\"ci_infra_reruns\":3,\"history\":[]}]}"
run_merge_lane || :
[[ "$(field pr-14 .stage)" == supervisor-review && "$(field pr-14 .approved_sha)" == "$H1" ]] || fail 'persistent runner failure not escalated to the supervisor'
[[ "$(field pr-14 '.history[-1].decision.decision')" == 'Stop CI retries and escalate runner failure to supervisor' \
  && "$(field pr-14 '.history[-1].decision.evidence')" == "head $H1 after 3 reruns:"* ]] || fail 'persistent runner handoff omitted its decision evidence'
GH_FAILED_STEPS=("Ensure CI runner has capacity before dependency install" "Run touched package gates in Dagger")
units "{\"units\":[{\"id\":\"pr-14\",\"pr\":14,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H1\",\"ci_rerun_sha\":\"$H1\",\"history\":[]}]}"
run_merge_lane || :
[[ "$(field pr-14 .stage)" == repair-pending ]] || fail 'a code step failure was classified as runner environment'
# 停线：失败 job 日志已有测试断言失败，不等其余检查、不重跑，直接派修复并取消该分支剩余 run；只有环境类失败照旧等齐
gh() { case "$*" in
  "api --allow-escape-sequences repos/{owner}/{repo}/actions/jobs/555/logs") printf ' FAIL  tests/a.test.ts > example > claim\nAssertionError: expected false to be true\n' ;;
  "api --allow-escape-sequences repos/{owner}/{repo}/actions/jobs/556/logs") printf 'ENOSPC: no space left on device\n' ;;
  "api --allow-escape-sequences repos/{owner}/{repo}/actions/jobs/557/logs") printf '320 : \xe2\x94\x86 [4m8s] | \x1b[41m\x1b[1m FAIL \x1b[22m\x1b[49m tests/a.test.ts\x1b[2m > \x1b[22mexample\nerror: column "wake_token" does not exist\n' ;;
  "run list --branch"*) echo 801 ;;
  *) eval "${gh_merge_stub/gh ()/gh_m ()}"; gh_m "$@" ;;
esac; }
tr_root="$fixture/testred-root"; mkdir -p "$tr_root/engine/night"
printf '#!/usr/bin/env bash\necho "$2" >> "%s/cancelled"\necho "${ZF_CANCEL_REASON-unset}" >> "%s/reasons"\n' "$tr_root" "$tr_root" > "$tr_root/engine/night/main-ci-recovery.sh"
GH_CHECKS='[{"name":"Repo-path gate","bucket":"fail","link":"https://github.com/o/r/actions/runs/9/job/555"},{"name":"Example gate","bucket":"pending"}]'; GH_RERUNS=()
units "{\"units\":[{\"id\":\"pr-17\",\"pr\":17,\"stage\":\"ready-to-merge\",\"branch\":\"agent/issue-17\",\"approved_sha\":\"$H1\",\"history\":[]}]}"
root_saved="$ROOT"; ROOT="$tr_root"; run_merge_lane || :; ROOT="$root_saved"
[[ "$(field pr-17 .stage)" == repair-pending && "$(field pr-17 '.approved_sha // "none"')" == none && -z "${GH_RERUNS[*]:-}" && "$(cat "$tr_root/cancelled" 2>/dev/null)" == 801 ]] || fail "test failure waited for other checks or a rerun ($(field pr-17 .stage), reruns=${GH_RERUNS[*]:-none})"
[[ "$(sort -u "$tr_root/reasons")" == "tests already red" ]] || fail "test-red cancel did not carry its reason ($(tr '\n' ',' < "$tr_root/reasons"))"
[[ "$(field pr-17 .repair_hint)" == *"Repo-path gate"* ]] || fail 'test-red repair hint lacks the failing check'
# Dagger 里 vitest 的 FAIL 行带 ANSI 颜色、没有 AssertionError（#3860：SQL 报错），也是测试红（L75）
GH_CHECKS='[{"name":"Touched packages PR gate","bucket":"fail","link":"https://github.com/o/r/actions/runs/9/job/557"}]'; GH_RERUNS=()
units "{\"units\":[{\"id\":\"pr-17\",\"pr\":17,\"stage\":\"ready-to-merge\",\"branch\":\"agent/issue-17\",\"approved_sha\":\"$H1\",\"history\":[]}]}"
root_saved="$ROOT"; ROOT="$tr_root"; run_merge_lane || :; ROOT="$root_saved"
[[ "$(field pr-17 .stage)" == repair-pending && -z "${GH_RERUNS[*]:-}" ]] || fail "ANSI-coloured vitest failure not recognised as a test failure ($(field pr-17 .stage))"
GH_CHECKS='[{"name":"Repo-path gate","bucket":"fail","link":"https://github.com/o/r/actions/runs/9/job/556"},{"name":"Example gate","bucket":"pending"}]'
units "{\"units\":[{\"id\":\"pr-17\",\"pr\":17,\"stage\":\"ready-to-merge\",\"branch\":\"agent/issue-17\",\"approved_sha\":\"$H1\",\"history\":[]}]}"
run_merge_lane || :
[[ "$(field pr-17 .stage)" == ready-to-merge && "$(field pr-17 .ci_test_checked)" == "$H1:Repo-path gate" ]] || fail 'environment failure without test failures did not keep waiting'
eval "$gh_merge_stub"
GH_CHECKS='[{"name":"suites","bucket":"pending"}]'
units "{\"units\":[{\"id\":\"pr-13\",\"pr\":13,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H1\",\"history\":[]}]}"
run_merge_lane || :
[[ "$(field pr-13 .stage)" == ready-to-merge && "$(field pr-13 '.ci_rerun_sha // "none"')" == none && ${#GH_MERGES[@]} == 0 ]] || fail 'pending checks treated as red or merged'
unset GH_CHECKS; eval "$gh_merge_stub"; GH_RERUNS=()

# ---------- 队头阻塞：窗口里 CI 已出结论的单元排在还在跑的、被挡的前面 ----------
gh_hol_saved="$(declare -f gh)"
gh() { if [[ "$1 $2" == "pr list" && "$*" == *statusCheckRollup* ]]; then
  jq -n --arg h "$H2" '[{number:31,headRefOid:$h,isDraft:false,statusCheckRollup:[{__typename:"CheckRun",status:"IN_PROGRESS"}]},{number:32,headRefOid:$h,isDraft:false,statusCheckRollup:[{__typename:"CheckRun",status:"COMPLETED",conclusion:"SUCCESS"}]},{number:33,headRefOid:$h,isDraft:false,statusCheckRollup:[{__typename:"CheckRun",status:"COMPLETED",conclusion:"FAILURE"}]}]'; else eval "${gh_hol_saved/gh ()/gh_h ()}"; gh_h "$@"; fi; }
units "{\"units\":[{\"id\":\"pr-31\",\"pr\":31,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H1\",\"ready_since\":\"2026-10-20T01:00:00Z\"},{\"id\":\"pr-34\",\"pr\":34,\"stage\":\"ready-to-merge\",\"critical\":true,\"approved_sha\":\"$H1\",\"ready_since\":\"2026-10-20T00:00:00Z\"},{\"id\":\"pr-32\",\"pr\":32,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H1\",\"ready_since\":\"2026-10-20T03:00:00Z\"},{\"id\":\"pr-33\",\"pr\":33,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H1\",\"ready_since\":\"2026-10-20T02:00:00Z\"}]}"
[[ "$(merge_candidates 3 | jq -r .id | tr '\n' ' ')" == "pr-34 pr-32 pr-33 " ]] || fail "merge window still blocked at the head of the line ($(merge_candidates 3 | jq -r .id | tr '\n' ' '))"
# 候选带回批量列表里的 PR head，合并车道不再逐个 gh pr view；不在 open 列表里的（已合/已关）不带
[[ "$(merge_candidates 4 | jq -r '"\(.id)=\(.pr_open_head // "none")"' | sort | tr '\n' ' ')" == "pr-31=$H2 pr-32=$H2 pr-33=$H2 pr-34=none " ]] || fail "merge candidates lack the bulk-listed PR head ($(merge_candidates 4 | jq -c '{id,pr_open_head}' | tr '\n' ' '))"
# 同一优先级和 CI 状态内先检查尚未检查的单元；轮转不能越过 critical 类。
(
  gh() { if [[ "$1 $2" == "pr list" && "$*" == *statusCheckRollup* ]]; then
    jq -n --arg h "$H1" '[31,32,33] | map({number:., headRefOid:$h, isDraft:false, statusCheckRollup:[{__typename:"CheckRun",status:"COMPLETED",conclusion:"SUCCESS"}]})'
    else eval "${gh_hol_saved/gh ()/gh_h ()}"; gh_h "$@"; fi; }
  units '{"units":[
    {"id":"pr-31","pr":31,"stage":"ready-to-merge","merge_checked_epoch":100,"ready_since":"2026-10-20T01:00:00Z"},
    {"id":"pr-32","pr":32,"stage":"ready-to-merge","ready_since":"2026-10-20T02:00:00Z"},
    {"id":"pr-33","pr":33,"stage":"ready-to-merge","critical":true,"merge_checked_epoch":900,"ready_since":"2026-10-20T03:00:00Z"}]}'
  [[ "$(merge_candidates 3 | jq -r .id | tr '\n' ' ')" == "pr-33 pr-32 pr-31 " ]] || fail 'scan rotation ignored priority or kept a checked peer at the head'
  set_unit pr-32 '.merge_checked_epoch=200'
  [[ "$(merge_candidates 3 | jq -r .id | tr '\n' ' ')" == "pr-33 pr-31 pr-32 " ]] || fail 'same-class scan rotation did not advance after observing a candidate'
)
eval "$gh_hol_saved"
# 候选带回 PR 的 draft 状态；仍是同一次批量列表调用，不为 draft 多一次 gh（未在 open 列表里的单元为 null）
(
  GH_PR_TABLE="$fixture/gh-prs-candidates.json"; echo '[]' > "$GH_PR_TABLE"; CALLS="$fixture/candidate-gh.calls"; : > "$CALLS"
  gh_pr_open 31 "$H2" true MERGEABLE agent/issue-31
  gh_pr_open 32 "$H2" false MERGEABLE agent/issue-32 '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]'
  units "{\"units\":[$(gated_unit pr-31 31 agent/issue-31 "$H1"),$(gated_unit pr-32 32 agent/issue-32 "$H1"),$(gated_unit pr-34 34 agent/issue-34 "$H1")]}"
  gh() { echo "$*" >> "$CALLS"; eval "${gh_hol_saved/gh ()/gh_h ()}"; gh_h "$@"; }
  [[ "$(merge_candidates 3 | jq -r '"\(.id)=\(.pr_open_draft)"' | sort | tr '\n' ' ')" == "pr-31=true pr-32=false pr-34=null " ]] \
    || fail "merge candidates lack the bulk-listed draft state ($(merge_candidates 3 | jq -c '{id,pr_open_draft}' | tr '\n' ' '))"
  : > "$CALLS"; merge_candidates 3 > /dev/null
  [[ "$(wc -l < "$CALLS")" == 1 && "$(cat "$CALLS")" == "pr list --state open"* ]] || fail "draft state cost an extra provider call ($(tr '\n' '|' < "$CALLS"))"
)

# ---------- 门控 draft 单元（draft-ci 09-12）：批准且占到名额才 ready；名额外留在 draft；repair 派出退回 draft ----------
(
  gh_gs_saved="$(declare -f gh)"; GS="$fixture/gate-status.calls"; : > "$GS"
  GH_PR_TABLE="$fixture/gh-prs-gate.json"; echo '[]' > "$GH_PR_TABLE"; : > "$GH_PR_CALLS"
  gh_pr_open 51 "$H1" true MERGEABLE agent/issue-51
  gh_pr_open 52 "$H1" true MERGEABLE agent/issue-52
  gh_pr_open 53 "$H1" true MERGEABLE agent/issue-53
  gh_pr_open 54 "$H1" true MERGEABLE agent/issue-54
  jq -c 'map(.labels = [{name: "agent/ci-gated"}])' "$GH_PR_TABLE" > "$GH_PR_TABLE.tmp" && mv "$GH_PR_TABLE.tmp" "$GH_PR_TABLE"
  gh() { case "$*" in
    "api repos/{owner}/{repo}/commits/"*"/status"*) echo 0 ;;
    "api repos/{owner}/{repo}/statuses/"*) echo "$*" >> "$GS" ;;
    *) eval "${gh_gs_saved/gh ()/gh_g ()}"; gh_g "$@" ;;
  esac; }
  CFG="$(jq '.precheck=false' <<<"$CFG_SAVED")"; TICK_UNFINISHED=""; ROOT="$wr"
  units "{\"units\":[$(gated_unit pr-51 51 agent/issue-51 "$H1" | jq -c '.ready_since=1'),$(gated_unit pr-52 52 agent/issue-52 "$H1" | jq -c '.ready_since=2'),$(gated_unit pr-53 53 agent/issue-53 "$H1" | jq -c '.ready_since=3'),$(jq -cn --arg sha "$H1" '{id:"pr-54",pr:54,branch:"agent/issue-54",stage:"review-pending",gated:true,reviewed_sha:$sha,history:[]}')]}"
  ci_wip_gate_test
  [[ "$(gh_pr_is_draft 51):$(gh_pr_is_draft 52):$(gh_pr_is_draft 53)" == "false:true:true" ]] || fail "slot gate did not ready exactly the top gated unit ($(gh_pr_is_draft 51):$(gh_pr_is_draft 52):$(gh_pr_is_draft 53))"
  [[ "$(gh_pr_is_draft 54)" == true && "$(field pr-54 .stage)" == review-pending ]] || fail 'an unapproved draft PR was readied'
  grep -q "agent/ci-approved" "$GS" && grep -q "agent/ci-waiting" "$GS" || fail 'slot gate did not write the head-bound approved and waiting statuses'
  [[ "$(field pr-52 .ci_wip_wait)" == "$H1" && "$(field pr-51 '[.history[] | select(.stage == "ci-ready")] | length')" == 1 ]] || fail 'ready or wait was not recorded on the unit rows'
  [[ "$(field pr-51 .ci_ready_sha)" == "$H1" && "$(field pr-51 .ci_ready_at)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || fail 'ready event time was not bound to the approved head'
  # 名额让出后下一个 ready
  set_unit pr-51 '.stage="merged"'
  ci_wip_gate_test
  [[ "$(gh_pr_is_draft 52)" == false ]] || fail 'freed slot did not ready the next gated unit'
  # 批准的 head 与 PR 现 head 不一致：不 ready
  jq -c 'map(if .number == 53 then .headRefOid = "'"$H2"'" else . end)' "$GH_PR_TABLE" > "$GH_PR_TABLE.tmp" && mv "$GH_PR_TABLE.tmp" "$GH_PR_TABLE"
  set_unit pr-52 '.stage="merged"'; ci_wip_gate_test
  [[ "$(gh_pr_is_draft 53)" == true ]] || fail 'a head that is not the approved one was readied'
  # repair 派出：门控 PR 退回 draft；非 agent/issue- 分支不走 draft 生命周期
  gh_pr_ready 52
  units "{\"units\":[{\"id\":\"pr-52\",\"pr\":52,\"branch\":\"agent/issue-52\",\"stage\":\"repair-pending\",\"history\":[]}]}"
  repair_demote pr-52 52 agent/issue-52
  [[ "$(gh_pr_is_draft 52)" == true && "$(field pr-52 .gated)" == true ]] || fail 'repair dispatch did not return the gated PR to draft'
  : > "$GH_PR_CALLS"; repair_demote pr-52 52 hand/x
  ! grep -q "pr ready" "$GH_PR_CALLS" || fail 'a hand branch was moved through the draft lifecycle'
)
# ---------- CI 只跑会合并的 head：评审中的普通单元，没开跑的 PR run 取消；获批后起跑不占首红重跑额度 ----------
dr="$fixture/defer-root"; mkdir -p "$dr/engine/night"
printf '#!/usr/bin/env bash\necho "$2" >> "%s/cancelled"\necho "${ZF_CANCEL_REASON-unset}" >> "%s/reasons"\n' "$dr" "$dr" > "$dr/engine/night/main-ci-recovery.sh"
gh_def_saved="$(declare -f gh)"
gh() { case "$*" in
  "api --paginate repos/{owner}/{repo}/actions/runs?status=queued"*) for r in 61:rv 63:hp 64:unrelated; do printf '{"databaseId":%s,"status":"queued","event":"pull_request","headBranch":"%s","headSha":"%s"}\n' "${r%%:*}" "${r#*:}" "$H2"; done ;;
  "api --paginate repos/{owner}/{repo}/actions/runs?status=in_progress"*) printf '{"databaseId":62,"status":"in_progress","event":"pull_request","headBranch":"rv","headSha":"%s"}\n' "$H2" ;;
  "api --paginate"*) : ;;
  "api repos/{owner}/{repo}/actions/runs/62/jobs"*) echo '[{"status":"in_progress"},{"status":"queued"}]' ;;
  "run list --commit"*) echo 61 ;;
  "run rerun"*) GH_RERUNS+=("$*") ;;
  *) eval "${gh_def_saved/gh ()/gh_d ()}"; gh_d "$@" ;;
esac; }
units "{\"units\":[{\"id\":\"pr-41\",\"pr\":41,\"stage\":\"rereview-pending\",\"branch\":\"rv\",\"history\":[]},{\"id\":\"pr-42\",\"pr\":42,\"stage\":\"review\",\"hotpatch\":true,\"branch\":\"hp\",\"history\":[]}]}"
TICK_UNFINISHED=""; ( ROOT="$dr"; ci_defer_ci_test ) || fail 'ci_defer_ci_test errored'
[[ "$(cat "$dr/cancelled" 2>/dev/null)" == 61 && "$(field pr-41 .ci_deferred_sha)" == "$H2" ]] || fail "CI on a head in review was not deferred, or a running/hot-patch run was cancelled ($(tr '\n' ' ' < "$dr/cancelled" 2>/dev/null))"
[[ "$(sort -u "$dr/reasons")" == "ci deferred" ]] || fail "deferral cancel did not carry its reason ($(tr '\n' ',' < "$dr/reasons"))"
GH_RERUNS=()
units "{\"units\":[{\"id\":\"pr-41\",\"pr\":41,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H2\",\"ci_deferred_sha\":\"$H2\",\"history\":[]}]}"
ci_red pr-41 41 "$H2" "CI"
[[ "${GH_RERUNS[*]:-}" == "run rerun 61 --failed" && "$(field pr-41 '.ci_deferred_sha // "none"')" == none && "$(field pr-41 '.ci_rerun_sha // "none"')" == none ]] || fail "approved deferred head did not start CI without using the rerun budget (${GH_RERUNS[*]:-none})"
eval "$gh_def_saved"; GH_RERUNS=()

# The generated reviewer prompt points to the formal contract, which owns all verdict and finding policy.
[[ "$(review_prompt 41 title "$H1" review-41.md pr "$feature_repo")" == *".agents/skills/zf-code-review/SKILL.md"* ]] \
  || fail 'review prompt does not point at the canonical review contract'
review_risk_fixture="$fixture/review-risk"
command git init -q -b main "$review_risk_fixture"
command git -C "$review_risk_fixture" config user.email t@example.invalid
command git -C "$review_risk_fixture" config user.name t
command git -C "$review_risk_fixture" commit -q --allow-empty -m base
review_risk_base="$(command git -C "$review_risk_fixture" rev-parse HEAD)"
mkdir -p "$review_risk_fixture/engine" "$review_risk_fixture/packages/auth-tokens/src"
printf 'risk\n' > "$review_risk_fixture/engine/review-gate.sh"
printf 'token\n' > "$review_risk_fixture/packages/auth-tokens/src/token.ts"
command git -C "$review_risk_fixture" add -A
command git -C "$review_risk_fixture" commit -q -m risk-change
command git -C "$review_risk_fixture" update-ref refs/remotes/origin/main "$review_risk_base"
review_risk_rule="$(risk_class_safety_rule "$review_risk_fixture")"
[[ "$review_risk_rule" == *"control-surface: engine/review-gate.sh"* \
  && "$review_risk_rule" == *"durable-write: packages/auth-tokens/src/token.ts"* ]] \
  || fail "risk-class prompt omitted a path from the existing classifier: $review_risk_rule"

# ---------- 热修优先（统一准入，#4625 起挡板退役）：热修分支的 run 不被任何准入取消；census 不可用时不做取消决定 ----------
ph="$fixture/prio-root"; mkdir -p "$ph/engine/night"
printf '#!/usr/bin/env bash\necho "$2" >> "%s/cancelled"\necho "${ZF_CANCEL_REASON-unset}" >> "%s/reasons"\n' "$ph" "$ph" > "$ph/engine/night/main-ci-recovery.sh"
run_json() { printf '{"databaseId":%s,"status":"%s","event":"pull_request","headBranch":"%s","headSha":"%s","workflowName":"%s"}' "$@"; }
gh_prio_saved="$(declare -f gh)"
# 关联 issue 分类为 hotfix 的 review PR 不能被 draft defer 取消。
rm -f "$ph/cancelled"
units "{\"units\":[{\"id\":\"linked-hotfix\",\"pr\":30,\"stage\":\"review-pending\",\"branch\":\"agent/issue-30\",\"history\":[]}]}"
GH_PR_TABLE="$fixture/defer-linked-hotfix-prs.json"; printf '[{"number":30,"headRefName":"agent/issue-30","headRefOid":"%s","isDraft":false,"labels":[],"statusCheckRollup":[]} ]\n' "$H2" > "$GH_PR_TABLE"
TICK_PRS=""; TICK_UNFINISHED="[$(run_json 76 queued agent/issue-30 "$H2" CI)]"
hotfix_issues_saved="$TICK_HOTFIX_ISSUES"; hotfix_issues_loaded_saved="$TICK_HOTFIX_ISSUES_LOADED"
TICK_HOTFIX_ISSUES='[30]'; TICK_HOTFIX_ISSUES_LOADED=true
( ROOT="$ph"; ci_defer_classified_test ) || fail 'draft defer errored on a linked hotfix PR'
[[ ! -s "$ph/cancelled" && "$(field linked-hotfix '.ci_deferred_sha // "none"')" == none ]] \
  || fail "draft defer cancelled or marked a linked hotfix run ($(cat "$ph/cancelled" 2>/dev/null))"
TICK_HOTFIX_ISSUES="$hotfix_issues_saved"; TICK_HOTFIX_ISSUES_LOADED="$hotfix_issues_loaded_saved"
unset GH_PR_TABLE; GH_RUNS='[]'; TICK_UNFINISHED=""
# 读不到 PR census 时 controller 不做取消决定，避免漏识别热修后把它送进 defer。
rm -f "$ph/cancelled"
units "{\"units\":[{\"id\":\"pr-21\",\"pr\":21,\"stage\":\"review-pending\",\"branch\":\"plain\",\"history\":[]},{\"id\":\"pr-20\",\"pr\":20,\"stage\":\"review-pending\",\"hotpatch\":true,\"branch\":\"hp\",\"history\":[]}]}"
GH_RUNS="[$(run_json 70 queued hp "$H2" CI),$(run_json 71 queued plain "$H1" CI)]"
gh_census_saved="$(declare -f gh)"
gh() { if [[ "$1 $2" == "pr list" ]]; then return 1; else eval "${gh_census_saved/gh ()/gh_f ()}"; gh_f "$@"; fi; }
( ROOT="$ph"; TICK_PRS=""; ci_admission ) || fail 'ci_admission errored with an unavailable PR census'
[[ ! -s "$ph/cancelled" ]] || fail "controller cancelled runs without hotfix classification ($(tr '\n' ' ' < "$ph/cancelled"))"
eval "$gh_census_saved"; GH_RUNS='[]'
# ---------- 统一优先级与 FIFO：main-red > opt > normal；同级按 ready_since ----------
rank_prs="$fixture/ci-admission-ranked-prs.json"; GH_PR_TABLE="$rank_prs"; echo '[]' > "$GH_PR_TABLE"; : > "$GH_PR_CALLS"
gh_pr_open 61 "$H1" true MERGEABLE agent/issue-61
gh_pr_open 62 "$H1" true MERGEABLE agent/issue-62
gh_pr_open 63 "$H1" true MERGEABLE agent/issue-63
gh_pr_open 64 "$H1" true MERGEABLE agent/issue-64
jq -c 'map(.labels = [{name: "agent/ci-gated"}])' "$GH_PR_TABLE" > "$GH_PR_TABLE.tmp" && mv "$GH_PR_TABLE.tmp" "$GH_PR_TABLE"
gh_rank_saved="$(declare -f gh)"
gh() { case "$1 $2" in
  "pr list") cat "$GH_PR_TABLE" ;;
  "pr ready") if [[ "${4:-}" == "--undo" ]]; then gh_pr_ready "$3" --undo; else gh_pr_ready "$3"; fi ;;
  "api repos/{owner}/{repo}/commits/"*"/status"*) echo 0 ;;
  "api repos/{owner}/{repo}/statuses/"*) echo "$*" >> "$GH_PR_CALLS" ;;
  "run list"*) echo '[]' ;;
  "api --paginate")
    case "$3" in
      # 一个在线 PR runner → 一个空槽；名额来自 runner 而不是配置（60ba960cf）
      "repos/{owner}/{repo}/actions/runners?per_page=100") echo 1 ;;
    esac ;;
  "api "*) echo '[]' ;;
  *) echo "unexpected gh in admission fixture: $*" >&2; return 97 ;;
esac; }
pr_behind_rank_saved="$(declare -f pr_behind_main)"
pr_behind_main() { return 1; } # 排序用例不覆盖 update-branch / mergeability
CFG="$(jq '.precheck=false' <<<"$CFG_SAVED")"
units "$(jq -cn --arg h "$H1" '{units:[
  {id:"main-red",pr:61,branch:"agent/issue-61",stage:"ready-to-merge",main_red:true,approved_sha:$h,ready_since:30,product_paths:true,history:[]},
  {id:"opt-early",pr:62,branch:"agent/issue-62",stage:"ready-to-merge",ci_priority:true,approved_sha:$h,ready_since:10,product_paths:true,history:[]},
  {id:"opt-late",pr:63,branch:"agent/issue-63",stage:"ready-to-merge",ci_priority:true,approved_sha:$h,ready_since:20,product_paths:true,history:[]},
  {id:"normal",pr:64,branch:"agent/issue-64",stage:"ready-to-merge",approved_sha:$h,ready_since:1,product_paths:true,history:[]}
]}')"
( ROOT="$ph"; TICK_PRS=""; TICK_UNFINISHED='[]'; ci_wip_gate_test )
[[ "$(gh_pr_is_draft 61):$(gh_pr_is_draft 62):$(gh_pr_is_draft 63):$(gh_pr_is_draft 64)" == "false:true:true:true" ]] \
  || fail "main-red did not win the full slot over opt and normal ($(gh_pr_is_draft 61):$(gh_pr_is_draft 62):$(gh_pr_is_draft 63):$(gh_pr_is_draft 64))"
jq -c 'map(.isDraft = true)' "$GH_PR_TABLE" > "$GH_PR_TABLE.tmp" && mv "$GH_PR_TABLE.tmp" "$GH_PR_TABLE"
units "$(jq -cn --arg h "$H1" '{units:[
  {id:"opt-early",pr:62,branch:"agent/issue-62",stage:"ready-to-merge",ci_priority:true,approved_sha:$h,ready_since:10,product_paths:true,history:[]},
  {id:"opt-late",pr:63,branch:"agent/issue-63",stage:"ready-to-merge",ci_priority:true,approved_sha:$h,ready_since:20,product_paths:true,history:[]},
  {id:"normal",pr:64,branch:"agent/issue-64",stage:"ready-to-merge",approved_sha:$h,ready_since:1,product_paths:true,history:[]}
]}')"
( ROOT="$ph"; TICK_PRS=""; TICK_UNFINISHED='[]'; ci_wip_gate_test )
[[ "$(gh_pr_is_draft 62):$(gh_pr_is_draft 63):$(gh_pr_is_draft 64)" == "false:true:true" ]] \
  || fail "opt did not outrank normal or preserve same-level ready order ($(gh_pr_is_draft 62):$(gh_pr_is_draft 63):$(gh_pr_is_draft 64))"
eval "$pr_behind_rank_saved"
# 关联 issue 分类为 hotfix 的门控 PR 不占产品 WIP 名额，满额时仍立即 ready；它进入 review 后也不能被 demote 取消。
GH_PR_TABLE="$fixture/ci-admission-hotfix-gated.json"; echo '[]' > "$GH_PR_TABLE"; : > "$GH_PR_CALLS"
gh_pr_open 65 "$H1" true MERGEABLE agent/issue-65
gh_pr_open 66 "$H1" true MERGEABLE agent/issue-66
CFG_RANK_SAVED="$CFG"
jq -c '.hotfix_lane={branch_prefixes:["hotfix/","agent/issue-hf-"],label:"hotfix"}' <<<"$CFG" > "$fixture/ci-admission-config.json"
CFG="$(cat "$fixture/ci-admission-config.json")"
jq -c 'map(.labels = [{name: "agent/ci-gated"}]) + [{number:67,headRefOid:"'"$H1"'",isDraft:true,mergeable:"MERGEABLE",headRefName:"hotfix/urgent",labels:[{name:"agent/ci-gated"}],statusCheckRollup:[]}]' "$GH_PR_TABLE" > "$GH_PR_TABLE.tmp" && mv "$GH_PR_TABLE.tmp" "$GH_PR_TABLE"
hotfix_issues_saved="$TICK_HOTFIX_ISSUES"; hotfix_issues_loaded_saved="$TICK_HOTFIX_ISSUES_LOADED"
TICK_HOTFIX_ISSUES='[65]'; TICK_HOTFIX_ISSUES_LOADED=true
units "$(jq -cn --arg h "$H1" '{units:[
  {id:"hotfix",pr:65,branch:"agent/issue-65",stage:"ready-to-merge",approved_sha:$h,ready_since:20,product_paths:true,history:[]},
  {id:"normal",pr:66,branch:"agent/issue-66",stage:"ready-to-merge",approved_sha:$h,ready_since:1,product_paths:true,history:[]},
  {id:"prefixed-hotfix",pr:67,branch:"hotfix/urgent",stage:"ready-to-merge",approved_sha:$h,ready_since:2,product_paths:true,history:[]}
]}')"
( ROOT="$ph"; TICK_PRS=""; TICK_UNFINISHED='[]'; ci_admission_test )
[[ "$(gh_pr_is_draft 65):$(gh_pr_is_draft 66):$(gh_pr_is_draft 67)" == "false:false:false" ]] \
  || fail "linked or configured-prefix hotfix did not start outside the full normal WIP slot ($(gh_pr_is_draft 65):$(gh_pr_is_draft 66):$(gh_pr_is_draft 67))"
[[ "$(grep '^pr ready ' "$GH_PR_CALLS" | tr '\n' ' ')" == "pr ready 65 pr ready 67 pr ready 66 " ]] \
  || fail "full-slot admission readied normal CI before hotfix CI ($(grep '^pr ready ' "$GH_PR_CALLS" | tr '\n' ' '))"
units "$(jq -cn --arg h "$H1" '{units:[
  {id:"hotfix",pr:65,branch:"agent/issue-65",stage:"review-pending",history:[]},
  {id:"normal",pr:66,branch:"agent/issue-66",stage:"ready-to-merge",approved_sha:$h,ci_ready_sha:$h,ci_ready_at:"2026-10-30T00:00:00Z",ready_since:1,product_paths:true,history:[]},
  {id:"prefixed-hotfix",pr:67,branch:"hotfix/urgent",stage:"review-pending",history:[]}
]}')"
: > "$GH_PR_CALLS"
( ROOT="$ph"; TICK_PRS=""; TICK_UNFINISHED='[]'; ci_admission_test )
[[ "$(gh_pr_is_draft 65):$(gh_pr_is_draft 67)" == "false:false" ]] \
  && ! grep -Eq 'pr ready (65|67) --undo' "$GH_PR_CALLS" \
  || fail "linked or configured-prefix hotfix was demoted and its CI cancelled ($(cat "$GH_PR_CALLS" 2>/dev/null | tr '\n' '|'))"
CFG="$CFG_RANK_SAVED"
TICK_HOTFIX_ISSUES="$hotfix_issues_saved"; TICK_HOTFIX_ISSUES_LOADED="$hotfix_issues_loaded_saved"
unset GH_PR_TABLE
TICK_PRS=""; TICK_UNFINISHED=""
eval "$gh_prio_saved"; GH_RUNS='[]'; GH_RERUNS=()

# ---------- 流水线 PR 与产品 PR 同一条绿合并车道：只看自己 head 的必需检查，合完直接 merged ----------
GH_MERGES=(); GH_MERGE_SHA="$M2"
units "{\"units\":[{\"id\":\"pr-15\",\"pr\":15,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H1\",\"history\":[]}]}"
run_merge_lane || :
[[ "${GH_MERGES[0]:-}" == *"pr merge 15"* && "$(field pr-15 .stage)" == merged && "$(field pr-15 .merge_sha)" == "$M2" ]] || fail "product PR did not merge on its own green checks (${GH_MERGES[*]:-none})"
GH_MERGES=(); GH_CHECKS='[{"name":"Pipeline suites","bucket":"pass"}]'
GH_RUNS="[{\"headSha\":\"$M1\",\"conclusion\":null,\"status\":\"in_progress\",\"createdAt\":\"t\",\"databaseId\":8,\"attempt\":1}]"
units "{\"units\":[{\"id\":\"pr-16\",\"pr\":16,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H1\",\"history\":[]}]}"
run_merge_lane || :
[[ "${GH_MERGES[0]:-}" == *"pr merge 16"*"--match-head-commit $H1"* && "$(field pr-16 .stage)" == merged ]] || fail 'pipeline PR did not merge on its own green checks, pinned to the approved head'
unset GH_CHECKS
# A completed main verdict that is not green still stops pipeline PRs, and a missing verdict must not
# starve a later product PR behind a full bounded scan of held pipeline candidates.
(
  CFG="$(jq '.batch_max=1' <<<"$CFG")"
  GH_RUNS='[]'
  GH_MERGES=(); GH_MERGE_SHA="$M2"; NOW_EPOCH=200000
  units "{\"units\":[
    {\"id\":\"pr-71\",\"pr\":71,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H1\",\"ready_since\":1,\"history\":[]},
    {\"id\":\"pr-72\",\"pr\":72,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H1\",\"ready_since\":2,\"history\":[]},
    {\"id\":\"pr-73\",\"pr\":73,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H1\",\"ready_since\":3,\"history\":[]},
    {\"id\":\"pr-74\",\"pr\":74,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H1\",\"ready_since\":4,\"history\":[]}] }"
  gh() {
    if [[ "$1 $2" == 'pr checks' ]]; then
      if [[ "$3" == 74 ]]; then echo '[{"name":"ci","bucket":"pass"}]'
      else echo '[{"name":"Pipeline suites","bucket":"pass"}]'; fi
    else eval "${gh_merge_stub/gh ()/gh_fair ()}"; gh_fair "$@"; fi
  }
  run_merge_lane || :
  [[ ${#GH_MERGES[@]} == 0 ]] || fail 'bounded pipeline scan merged a held candidate'
  NOW_EPOCH=$((NOW_EPOCH + 120))
  run_merge_lane || :
  [[ ${#GH_MERGES[@]} == 1 && "${GH_MERGES[0]}" == *'pr merge 74'* && "$(field pr-74 .stage)" == merged ]] || fail 'held pipeline candidates starved a later green product PR'
  [[ "$(jq '.units | length' "$UNITS")" == 4 ]] || fail 'fair lane scanning dropped a unit'
)
# 合并失败后 mergeable 先 UNKNOWN 再 CONFLICTING：要送修复，不能当成 squash 失败每拍空试
: > "$fixture/mergeable.calls"
gh() {
  if [[ "$1 $2" == "pr merge" ]]; then return 1; fi
  if [[ "$1 $2 $5" == "pr view mergeable" ]]; then echo x >> "$fixture/mergeable.calls"; (( $(wc -l < "$fixture/mergeable.calls") > 1 )) && echo CONFLICTING || echo UNKNOWN; return 0; fi
  eval "${gh_merge_stub/gh ()/gh_m ()}"; gh_m "$@"
}
units "{\"units\":[{\"id\":\"pr-17\",\"pr\":17,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H1\",\"history\":[]}]}"
run_merge_lane || :
[[ "$(field pr-17 .stage)" == repair-pending ]] || fail 'conflict reported as UNKNOWN right after a failed merge was not sent to repair'
# 两处"冲突送修复"共用一个帮手，但历史、提示和日志仍各是各的原话（合并失败后发现冲突 / checks 未齐时发现冲突）
[[ "$(field pr-17 '.history[-1] | "\(.stage) \(.result)"'):$(field pr-17 '.approved_sha // "none"')" == "merge-conflict PR#17 conflicts with main:none" && "$(field pr-17 .repair_hint)" == *"迁移编号顺延"* ]] \
  || fail "conflict found after a failed merge lost its history entry or repair hint ($(field pr-17 '.history[-1] | "\(.stage) \(.result)"'))"
grep -qF 'merge skipped PR#17 (conflicts with main) -> repair-pending' "$LOG" || fail 'conflict found after a failed merge lost its log line'
eval "$gh_merge_stub"
# checks 永远 pending 是因为冲突（GitHub 不跑 CI）：不等合并失败，直接送修复（热修回迁 pr-3588）；热修/critical 排在合并车道最前
gh() { if [[ "$1 $2 $5" == "pr view mergeable" ]]; then echo CONFLICTING; return 0; fi; eval "${gh_merge_stub/gh ()/gh_m ()}"; gh_m "$@"; }
GH_CHECKS='[{"name":"CI","bucket":"pending"}]'
units "{\"units\":[{\"id\":\"pr-18\",\"pr\":18,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H1\",\"history\":[]}]}"
run_merge_lane || :
[[ "$(field pr-18 .stage)" == repair-pending && "$(field pr-18 .repair_hint)" == *"不会跑 CI"* ]] || fail "conflicting PR with pending checks waited instead of going to repair ($(field pr-18 .stage))"
[[ "$(field pr-18 '.history[-1] | "\(.stage) \(.result)"'):$(field pr-18 '.approved_sha // "none"')" == "merge-conflict PR#18 conflicts with main; CI cannot start:none" && "$(field pr-18 .repair_hint)" == *"热修回迁"* ]] \
  || fail "conflict found while checks were pending lost its history entry or repair hint ($(field pr-18 '.history[-1] | "\(.stage) \(.result)"'))"
grep -qF 'merge skipped PR#18 (conflicts with main; CI cannot start) -> repair-pending' "$LOG" || fail 'conflict found while checks were pending lost its log line'
unset GH_CHECKS; eval "$gh_merge_stub"
# 冲突送修复前再问一次 GitHub：已无冲突就 update-branch 一次（带 expected_head_sha，按 unit/head 记账），批准保留；
# 仍冲突、锁文件/迁移 PR、更新失败都照旧派修复。
GH_HEAD_SAVED="${GH_HEAD:-}"; GH_HEAD="$H1"
gh() {
  case "$1 $2 $5" in
    "pr view mergeable") echo CONFLICTING; return 0 ;;
    "pr view mergeable,headRefOid") echo "${GH_FRESH:-MERGEABLE $H1}"; return 0 ;;
    "pr view files") printf '%s\n' "${GH_PR_FILES:-packages/x/a.ts}"; return 0 ;;
  esac
  if [[ "$1" == api ]]; then GH_API_CALLS+=("$*"); return "${GH_API_FAIL:-0}"; fi
  eval "${gh_merge_stub/gh ()/gh_m ()}"; gh_m "$@"
}
GH_CHECKS='[{"name":"CI","bucket":"pending"}]'
for cc_case in cleared still-conflicted lockfile update-fails; do
  GH_API_CALLS=(); GH_FRESH=""; GH_PR_FILES=""; GH_API_FAIL=0
  case "$cc_case" in
    still-conflicted) GH_FRESH="CONFLICTING $H1" ;;
    lockfile) GH_PR_FILES=$'packages/x/a.ts\npnpm-lock.yaml' ;;
    update-fails) GH_API_FAIL=1 ;;
  esac
  units "{\"units\":[{\"id\":\"pr-19\",\"pr\":19,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H1\",\"history\":[]}]}"
  run_merge_lane || :
  if [[ "$cc_case" == cleared ]]; then
    [[ ${#GH_API_CALLS[@]} == 1 && "${GH_API_CALLS[0]}" == *"pulls/19/update-branch"*"expected_head_sha=$H1"* ]] || fail "a cleared conflict did not update the branch exactly once with the expected head (${GH_API_CALLS[*]:-none})"
    [[ "$(field pr-19 .stage)" == ready-to-merge && "$(field pr-19 .approved_sha)" == "$H1" ]] || fail 'a cleared conflict dropped the approval or the stage'
    # 同一 head 上冲突仍在（mergeability 过期）：已记账的那一次不重复，改派修复。
    run_merge_lane || :
    [[ ${#GH_API_CALLS[@]} == 1 && "$(field pr-19 .stage)" == repair-pending ]] || fail 'a second update-branch was attempted on the same head'
  else
    [[ "$(field pr-19 .stage)" == repair-pending && "$(field pr-19 .repair_hint)" == *"热修回迁"* ]] || fail "$cc_case did not go to the existing repair"
    [[ "$cc_case" == update-fails && ${#GH_API_CALLS[@]} == 1 || "$cc_case" != update-fails && ${#GH_API_CALLS[@]} == 0 ]] || fail "$cc_case made the wrong number of update-branch calls (${#GH_API_CALLS[@]})"
  fi
done
GH_HEAD="$GH_HEAD_SAVED"; unset GH_CHECKS GH_FRESH GH_PR_FILES GH_API_FAIL; eval "$gh_merge_stub"

# ---------- 非产品快车道：分类、批准后派 land worker、不进合并车道 ----------
GH_FILES_RESPONSE='[[{"filename":"engine/lib.sh"},{"filename":"docs/x.md"}]]'
gh_base_stub="$(declare -f gh)"
gh() { if [[ "$1 $2" == "api --paginate" ]]; then jq -r '.[][] | .filename, (.previous_filename // empty)' <<<"$GH_FILES_RESPONSE"; else eval "${gh_base_stub/gh ()/gh_base ()}"; gh_base "$@"; fi; }
[[ "$(classify_lane 80)" == direct-main ]] || fail 'non-product PR not classified direct-main'
GH_FILES_RESPONSE='[[{"filename":"engine/lib.sh"},{"filename":"engine/new-name.ts","previous_filename":"packages/example/src/a.ts"}]]'
[[ "$(classify_lane 81)" == pr ]] || fail 'renamed product path was classified as direct-main'
GH_FILES_RESPONSE='[[{"filename":"packages/example/src/a.ts"},{"filename":"engine/lib.sh"}]]'
[[ "$(classify_lane 81)" == pr ]] || fail 'product PR classified as direct-main'
# 策略变了，之前记成 pr 的单元重分一次；同一策略下不重复查 GitHub
GH_FILES_RESPONSE='[[{"filename":"engine/lib.sh"}]]'
units '{"units":[{"id":"pr-84","pr":84,"stage":"ready-to-merge","lane":"pr","lane_policy":"old-policy","history":[]}]}'
[[ "$(ensure_lane pr-84 84)" == direct-main && "$(field pr-84 .lane)" == direct-main ]] || fail "pr lane not reclassified after a policy change ($(field pr-84 .lane))"
units '{"units":[{"id":"pr-85","pr":85,"stage":"ready-to-merge","lane":"pr","history":[]}]}'
ensure_lane pr-85 85 >/dev/null; p85="$(field pr-85 .lane_policy)"
GH_FILES_RESPONSE='[[{"filename":"packages/example/src/a.ts"}]]'
[[ "$(ensure_lane pr-85 85)" == direct-main && "$(field pr-85 .lane_policy)" == "$p85" ]] || fail 'same policy reclassified again'
LANDS=(); launch_land() { LANDS+=("$2:$3:$8"); }
GH_HEAD="$H1"; GH_MERGES=()
units "{\"units\":[{\"id\":\"pr-82\",\"pr\":82,\"stage\":\"ready-to-merge\",\"lane\":\"direct-main\",\"approved_sha\":\"$H1\",\"reviewed_pr_head\":\"$H1\",\"history\":[]},{\"id\":\"pr-83\",\"pr\":83,\"stage\":\"ready-to-merge\",\"lane\":\"direct-main\",\"approved_sha\":\"$H1\",\"reviewed_pr_head\":\"$H1\",\"history\":[]}]}"
fast_land_lane || :
[[ "${LANDS[*]}" == "82:$H1:$H1" && "$(field pr-82 .stage)" == landing && "$(field pr-83 .stage)" == ready-to-merge ]] || fail "fast lane must land one approval with both SHA bindings at a time (${LANDS[*]:-none})"
# If the PR head has rolled back since review, even an approved ancestor candidate is not landed.
LANDS=(); GH_HEAD="$H1"
units "{\"units\":[{\"id\":\"pr-84\",\"pr\":84,\"stage\":\"ready-to-merge\",\"lane\":\"direct-main\",\"approved_sha\":\"$H1\",\"reviewed_pr_head\":\"$H2\",\"history\":[]}]}"
fast_land_lane || :
[[ ${#LANDS[@]} == 0 && "$(field pr-84 .stage)" == rereview-pending \
  && "$(field pr-84 '.approved_sha // "none"')" == none ]] || fail 'fast lane did not invalidate approval after PR-head rollback'
GH_RUNS="[{\"headSha\":\"$M1\",\"conclusion\":\"success\",\"status\":\"completed\",\"createdAt\":\"t\",\"databaseId\":7}]"
MAIN_HEAD="$M1"; gate_eval_sha() { printf '%s' "$M1"; }
git() {
  if [[ " $* " == *" ls-remote "* ]]; then printf '%s\trefs/heads/main\n' "$MAIN_HEAD"
  elif [[ "${1:-}" == -C && "${3:-}" == fetch && "${!#}" == refs/pull/*/head ]]; then return 0
  elif [[ "${1:-}" == -C && "${3:-}" == rev-parse && "${5:-}" == FETCH_HEAD* ]]; then echo "$GH_HEAD"
  else command git "$@"; fi
}
run_merge_lane || :
[[ ${#GH_MERGES[@]} == 0 ]] || fail 'merge lane merged a direct-main PR'
unset -f git
units "{\"units\":[{\"id\":\"pr-82\",\"pr\":82,\"stage\":\"landing\",\"history\":[]}]}"
printf 'LANDED %s\n' "$M2" > "$sup/land-82.md"
jq -n '{workers:[{pid:8282,unit:"pr-82",type:"land",log:"land-82.worker.log",report:"land-82.md"}]}' > "$WORKERS"
alive() { return 1; }
harvest_workers || :
[[ "$(field pr-82 .stage)" == landed && "$(field pr-82 .land_sha)" == "$M2" ]] || fail 'LANDED report not harvested'
units '{"units":[{"id":"pr-84","pr":84,"stage":"landing","history":[]}]}'
printf 'FAILED not eligible for the direct-main lane (product paths)\n' > "$sup/land-84.md"
jq -n '{workers:[{pid:8484,unit:"pr-84",type:"land",log:"l.log",report:"land-84.md"}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field pr-84 .stage)" == ready-to-merge && "$(field pr-84 .lane)" == pr ]] || fail 'refused land not returned to the merge lane'
# 落地卡死/冲突 → repair（附落地日志）；传输失败重试一次再转人工
land_case() { # id report-line history
  units "{\"units\":[{\"id\":\"$1\",\"pr\":87,\"stage\":\"landing\",\"approved_sha\":\"$H1\",\"history\":$3}]}"
  printf '%s\n' "$2" > "$sup/land-$1.md"
  jq -n --arg u "$1" '{workers:[{pid:8787,unit:$u,type:"land",log:"l.log",report:("land-" + $u + ".md")}]}' > "$WORKERS"
  harvest_workers || :
}
land_case pr-87 'FAILED land-direct-main timed out after 1500s (wedged lander; killed to free the land lock)' '[]'
[[ "$(field pr-87 .stage)" == repair-pending && "$(field pr-87 .repair_hint)" == *land-pr-87.md.land.log* && "$(field pr-87 '.approved_sha // "none"')" == none ]] || fail 'wedged land not sent to repair with its log'
land_case pr-88 'FAILED land-direct-main: lock-released outcome=push-failed' '[]'
[[ "$(field pr-88 .stage)" == ready-to-merge ]] || fail 'first push failure not retried'
land_case pr-88 'FAILED land-direct-main: lock-released outcome=push-failed' '[{"stage":"land-retry"}]'
[[ "$(field pr-88 .stage)" == supervisor-review ]] || fail 'second push failure not escalated'
land_case pr-89 "LANDED-HEAD-MOVED $M2 $H2" '[]'
[[ "$(field pr-89 .stage)" == rereview-pending && "$(field pr-89 .land_sha)" == "$M2" \
  && "$(field pr-89 '.approved_sha // "none"')" == none ]] || fail 'landed PR head drift was treated as terminal'
land_case pr-90 "FAILED POST-LAND PR CLOSE $M2" '[]'
[[ "$(field pr-90 .stage)" == supervisor-review && "$(field pr-90 .land_sha)" == "$M2" \
  && "$(field pr-90 '.approved_sha // "none"')" == none \
  && "$(field pr-90 .note)" == *'PR 后续处理失败'* ]] || fail 'failed PR close was not escalated with landed SHA'
grep -Fq 'post-land follow-up failed unit=pr-90' "$A/alerts/events.md" || fail 'failed PR close was not written to scheduler alerts'
eval "$gh_base_stub"; unset -f launch_land

# unit_head：快车道单元以本地 clone 里基于 PR head 的修复提交为准，否则用 PR head
uh="$WT_ROOT/wt-pr-86"; mkdir -p "$WT_ROOT"; rm -rf "$uh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
command git init -q -b main "$uh"; command git -C "$uh" commit -q --allow-empty -m pr-head
uh_pr="$(command git -C "$uh" rev-parse HEAD)"; command git -C "$uh" checkout -q -b fix/x; command git -C "$uh" commit -q --allow-empty -m local-fix
uh_local="$(command git -C "$uh" rev-parse HEAD)"
GH_HEAD="$uh_pr"
[[ "$(unit_head pr-86 86 direct-main fix/x)" == "$uh_local" ]] || fail 'fast-lane unit_head ignored the local repair commit'
[[ "$(unit_head pr-86 86 pr fix/x)" == "$uh_pr" ]] || fail 'PR-lane unit_head must use the PR head'
GH_HEAD="$H1"

# ---------- 非产品 issue 直落（无 PR）：实现→本地提交→评审本地提交→直落→关 issue ----------
ih="$WT_ROOT/wt-issue-7"; rm -rf "$ih"
command git init -q -b main "$ih"; command git -C "$ih" commit -q --allow-empty -m base
ih_base="$(command git -C "$ih" rev-parse HEAD)"; command git -C "$ih" update-ref refs/remotes/origin/main "$ih_base"
command git -C "$ih" checkout -q -b agent/auto-issue-7; command git -C "$ih" commit -q --allow-empty -m impl
ih_local="$(command git -C "$ih" rev-parse HEAD)"
[[ "$(unit_review_target issue-7 '' direct-main agent/auto-issue-7)" == "$ih_base $ih_local" ]] || fail 'PR-less review target is not <fork point> <local head>'
GH_ISSUE_CALLS=(); GH_ISSUE_LIST='[]'; GH_PR_BRANCHES='[]'
gh_issue_stub="$(declare -f gh)"
gh() {
  case "$1 $2" in
    "issue close") GH_ISSUE_CALLS+=("$*") ;;
    "issue list") jq --arg l "$6" '[.[] | select(any(.labels[]; .name == $l))]' <<<"$GH_ISSUE_LIST" ;;
    # M5 (#4501)：pipeline-system 票带 live-event 验收块才能收单；#7 保持无块，覆盖落地即关的旧路径。
    "issue view") jq -n --argjson n "$3" '{number:$n,title:("t"+($n|tostring)),body:(if $n==7 then "issue body" else ("issue body\n\n```json\n"+({"acceptance":[{"id":"live-event","event":"factory-f3-release-train"}]}|tojson)+"\n```"+(if $n==20 then "\n\n## Blocked by\n- #9001" else "" end)) end)}' ;;
    "pr list") echo "$GH_PR_BRANCHES" ;;
    *) eval "${gh_issue_stub/gh ()/gh_i ()}"; gh_i "$@" ;;
  esac
}
units '{"units":[{"id":"issue-7","issue":7,"lane":"direct-main","branch":"agent/auto-issue-7","stage":"implement","history":[]},{"id":"issue-8","issue":8,"lane":"direct-main","branch":"agent/auto-issue-8","stage":"implement","history":[]}]}'
printf 'fixed it\n' > "$sup/impl-issue-7-T.md"; printf 'OBSOLETE: already fixed by abc123\n' > "$sup/impl-issue-8-T.md"
jq -n '{workers:[{pid:9701,unit:"issue-7",type:"implement",log:"i7.log",report:"impl-issue-7-T.md"},{pid:9801,unit:"issue-8",type:"implement",log:"i8.log",report:"impl-issue-8-T.md"}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field issue-7 .stage)" == review-pending ]] || fail "PR-less implement with a local commit did not go to review ($(field issue-7 .stage))"
[[ "$(field issue-8 .stage)" == closed && "${GH_ISSUE_CALLS[*]:-}" == *"issue close 8"* ]] || fail 'OBSOLETE implement did not close the issue'
DISPATCHED=(); DISPATCH_PROMPT=""
units '{"units":[{"id":"issue-7","issue":7,"lane":"direct-main","branch":"agent/auto-issue-7","stage":"review-pending","history":[]}]}'
dispatch_pending || :
[[ "${DISPATCHED[0]:-}" == "review:issue-7:$ih_local" && "$DISPATCH_PR_HEAD" == "$ih_base" && "$DISPATCH_PROMPT" == *"issue #7"* ]] || fail "PR-less unit not reviewed on its local commit (${DISPATCHED[*]:-none})"
DISPATCHED=(); DISPATCH_PROMPT=""
# 编排简报的六个字段（pstack orchestrate）按序成段：GOAL/SCOPE/ACCEPTANCE/VERIFY/FORBIDDEN/REPORT
impl_headings() { # prompt → 0 当六个标题各占一行开头且按序出现
  local h pos last=0
  for h in GOAL SCOPE ACCEPTANCE VERIFY FORBIDDEN REPORT; do
    pos="$(awk -v h="$h：" 'index($0, h) == 1 { print NR; exit }' <<<"$1")"
    [[ "$pos" =~ ^[0-9]+$ && "$pos" -gt "$last" ]] || return 1
    last="$pos"
  done
}
units '{"units":[{"id":"issue-9","issue":9,"lane":"direct-main","branch":"agent/auto-issue-9","stage":"implement-pending","task":"do x","history":[]}]}'
dispatch_pending || :
[[ "${DISPATCHED[0]:-}" == implement:issue-9:* && "$DISPATCH_PROMPT" == *"不要 push、不开 PR"* && "$DISPATCH_PROMPT" == *"OBSOLETE:"* ]] || fail 'PR-less implement prompt does not commit locally without a PR'
impl_headings "$DISPATCH_PROMPT" || fail 'implement brief lost the GOAL/SCOPE/ACCEPTANCE/VERIFY/FORBIDDEN/REPORT headings'
DISPATCHED=(); DISPATCH_PROMPT=""
units "$(jq -cn '{units:[{id:"issue-9",issue:9,lane:"direct-main",branch:"agent/auto-issue-9",stage:"implement-pending",task:"do x",history:[{stage:"supervisor-escalated",at:"2026-10-27T01:02:03Z",decision:{decision:"Request recut",why:"The prior implementation crossed the size threshold",evidence:"801 changed lines; limit 800",rejected:["Open the original implementation for review"],owner:"scheduler"}},{stage:"advisor-ruling",at:"2026-10-27T02:03:04Z",decision:{decision:"SPLIT",why:"Keep the ledger fix in this unit",evidence:"review-9-T3.md",rejected:["FIX","SCOPE"],owner:"advisor"}}]}]}')"
dispatch_pending || :
expected_decisions=$'Decided earlier (do not reopen without new evidence):\n- 2026-10-27T01:02:03Z [scheduler] Request recut\n  Why: The prior implementation crossed the size threshold\n  Evidence: 801 changed lines; limit 800\n  Rejected: Open the original implementation for review\n- 2026-10-27T02:03:04Z [advisor] SPLIT\n  Why: Keep the ledger fix in this unit\n  Evidence: review-9-T3.md\n  Rejected: FIX, SCOPE'
actual_decisions="$(sed -n '/^Decided earlier (do not reopen without new evidence):$/,/^Feature verification plan /p' <<<"$DISPATCH_PROMPT" | sed '$d')"
[[ "$actual_decisions" == "$expected_decisions" ]] || fail "re-dispatch brief did not carry prior decisions in SCOPE (got: $actual_decisions)"
DISPATCHED=(); DISPATCH_PROMPT=""
units '{"units":[{"id":"issue-23","issue":23,"lane":"pr","branch":"agent/issue-23","stage":"implement-pending","task":"fix it","history":[]}]}'
dispatch_pending || :
[[ "${DISPATCHED[0]:-}" == implement:issue-23:* ]] || fail "PR-lane implement unit was not dispatched (${DISPATCHED[*]:-none})"
impl_headings "$DISPATCH_PROMPT" || fail 'PR-lane implement brief lost the six orchestration headings'
[[ "$DISPATCH_PROMPT" == *"不 push main"* && "$DISPATCH_PROMPT" == *"流水线会开 PR 并派评审"* ]] || fail 'PR-lane implement brief lost its push boundary'
LANDS=(); launch_land() { LANDS+=("$2:$3:$8:$9"); }
units "{\"units\":[{\"id\":\"issue-7\",\"issue\":7,\"lane\":\"direct-main\",\"branch\":\"agent/auto-issue-7\",\"stage\":\"ready-to-merge\",\"approved_sha\":\"$ih_local\",\"reviewed_pr_head\":\"$ih_base\",\"history\":[]}]}"
fast_land_lane || :
[[ "${LANDS[*]:-}" == ":$ih_local:$ih_base:7" && "$(field issue-7 .stage)" == landing ]] || fail "approved PR-less unit not landed (${LANDS[*]:-none})"
unset -f launch_land
units '{"units":[{"id":"issue-7","issue":7,"lane":"direct-main","stage":"landing","history":[]}]}'
printf 'LANDED %s\n' "$M2" > "$sup/land-issue-7.md"
jq -n '{workers:[{pid:9702,unit:"issue-7",type:"land",log:"l.log",report:"land-issue-7.md"}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field issue-7 .stage)" == landed && "${GH_ISSUE_CALLS[*]}" == *"issue close 7"* ]] || fail 'landed PR-less unit did not close its issue'
# intake：按空闲产能收单（max_workers - 在跑 - 待派）；非产品标签走直落、ready-for-agent 走 PR 车道；跳过搁置标签与已有 PR 的 issue，focus 优先
MAX_SAVED="$MAX"; MAX=4
GH_ISSUE_LIST='[{"number":23,"title":"p","labels":[{"name":"ready-for-agent"},{"name":"bug"},{"name":"stack-pilot"}]},{"number":24,"title":"t","labels":[{"name":"ready-for-agent"},{"name":"needs-triage"}]},{"number":20,"title":"a","labels":[{"name":"pipeline-system"}]},{"number":21,"title":"b","labels":[{"name":"pipeline-system"},{"name":"on-hold"}]},{"number":22,"title":"c","labels":[{"name":"pipeline-system"}]},{"number":19,"title":"d","labels":[{"name":"pipeline-system"},{"name":"focus"}]},{"number":18,"title":"e","labels":[{"name":"pipeline-system"}]},{"number":17,"title":"f","labels":[{"name":"pipeline-system"}]},{"number":16,"title":"g","labels":[{"name":"pipeline-system"}]}]'
GH_PR_BRANCHES=$'agent/issue-22 fix c \nnode-auto/x implement it Fixes #18 '
units '{"units":[]}'
register_new_issues || :
[[ "$(jq -r '[.units[].id] | join(",")' "$UNITS")" == "issue-19,issue-23,issue-20,issue-17" ]] || fail "issue intake picked the wrong issues: $(jq -c '[.units[].id]' "$UNITS")"
[[ "$(field issue-23 .lane):$(field issue-23 .branch)" == "pr:agent/issue-23" ]] || fail 'product issue did not enter the PR lane on agent/issue-N'
[[ "$(field issue-23 '.labels | index("stack-pilot")')" == 2 ]] || fail 'intake did not persist the issue label used by the stacking pilot'
[[ "$(field issue-20 '.body_blocked_by | join(",")')" == 9001 ]] || fail 'intake did not persist Blocked by IDs separately from the worker prompt'
[[ "$(field issue-19 .stage):$(field issue-19 .lane):$(field issue-19 '.pr // "none"')" == "implement-pending:direct-main:none" && "$(field issue-19 .task)" == *"issue body"* ]] || fail 'intake unit is not a PR-less direct-main implement unit'
register_new_issues || :
[[ "$(jq '.units | length' "$UNITS")" == 4 ]] || fail 'issue intake admitted more than the idle capacity'
MAX="$MAX_SAVED"
# hotfix 单不进流水线（维护者 10-29：热修由热修 supervisor 直接改生产，验收后再合 main）
MAX=4; units '{"units":[]}'; GH_PR_BRANCHES=''
GH_ISSUE_LIST='[{"number":31,"title":"h","labels":[{"name":"ready-for-agent"},{"name":"hotfix"}]},{"number":32,"title":"p","labels":[{"name":"ready-for-agent"}]}]'
register_new_issues || :
[[ "$(jq -r '[.units[].id] | join(",")' "$UNITS")" == "issue-32" ]] || fail "intake admitted a hotfix issue: $(jq -c '[.units[].id]' "$UNITS")"
MAX="$MAX_SAVED"
# 待合并队列满（合并车道是瓶颈）：不再收单
MAX=4; units '{"units":[]}'
CFG="$(jq '.issue_intake={max_ready:1}' <<<"$CFG")"
units '{"units":[{"id":"pr-90","pr":90,"stage":"ready-to-merge","history":[]}]}'
register_new_issues || :
[[ "$(jq '.units | length' "$UNITS")" == 1 ]] || fail 'intake kept admitting while the merge queue was full'
# 队列满时挡着别人的前置照收（10-22 10 个前置从没进流水线，后继停了 40 小时），普通 issue 仍不收
units '{"units":[{"id":"pr-90","pr":90,"stage":"ready-to-merge","history":[]},{"id":"issue-71","issue":71,"lane":"pr","stage":"blocked-external","blocked_on":70,"history":[]}]}'
gh() { case "$1 $2" in "issue view") jq -n --argjson n "$3" '{number:$n,title:"pred",state:"OPEN",labels:[{name:"bug"}],body:"b"}' ;; *) eval "${gh_issue_stub/gh ()/gh_i ()}"; gh_i "$@" ;; esac; }
register_new_issues || :
[[ "$(jq -r '[.units[].id] | join(",")' "$UNITS")" == "pr-90,issue-71,issue-70" ]] || fail "full merge queue blocked predecessor intake or admitted plain issues: $(jq -c '[.units[].id]' "$UNITS")"
eval "$gh_issue_stub"
CFG="$(jq 'del(.issue_intake)' <<<"$CFG")"; MAX="$MAX_SAVED"
# 直落车道判断要改产品路径（NEEDS-PR）：转 PR 车道重做，不转人工
units '{"units":[{"id":"issue-31","issue":31,"lane":"direct-main","branch":"agent/auto-issue-31","stage":"implement","task":"t","history":[]}]}'
printf 'NEEDS-PR: needs packages/example change\n' > "$sup/impl-issue-31-T.md"
jq -n '{workers:[{pid:9731,unit:"issue-31",type:"implement",log:"i31.log",report:"impl-issue-31-T.md"}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field issue-31 .stage):$(field issue-31 .lane):$(field issue-31 .branch)" == "implement-pending:pr:agent/issue-31" && "$(field issue-31 .task)" == *"PR 车道"* ]] || fail 'NEEDS-PR did not switch the unit to the PR lane'
# 产品 issue 实现推了分支：流水线开 PR（Refs #N）并进评审
pr_remote="$fixture/pr-remote.git"; command git init -q --bare "$pr_remote"
pw="$WT_ROOT/wt-issue-32"; rm -rf "$pw"; command git init -q -b main "$pw"; command git -C "$pw" commit -q --allow-empty -m base
command git -C "$pw" remote add origin "$pr_remote"; command git -C "$pw" push -q origin main
command git -C "$pw" checkout -q -b agent/issue-32; command git -C "$pw" commit -q --allow-empty -m fix; command git -C "$pw" push -q origin agent/issue-32
: > "$fixture/pr-create.args"
gh() {
  case "$1 $2" in
    "pr list") echo "" ;;
    "pr create") printf "%s" "$*" > "$fixture/pr-create.args"; echo "https://github.com/example-maintainer/example-repo/pull/4321" ;;
    *) eval "${gh_issue_stub/gh ()/gh_i ()}"; gh_i "$@" ;;
  esac
}
units '{"units":[{"id":"issue-32","issue":32,"title":"Fixes #9988 title","lane":"pr","branch":"agent/issue-32","stage":"implement","task":"t","history":[]}]}'
printf 'root cause and fix\nFixes #9989\n' > "$sup/impl-issue-32-T.md"
jq -n '{workers:[{pid:9732,unit:"issue-32",type:"implement",log:"i32.log",report:"impl-issue-32-T.md"}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field issue-32 .stage):$(field issue-32 .pr)" == "review-pending:4321" \
  && "$(cat "$fixture/pr-create.args")" == *"Refs #32"* \
  && "$(cat "$fixture/pr-create.args")" == *"--title Fixes issue 9988 title (#32)"* \
  && "$(cat "$fixture/pr-create.args")" == *"Fixes issue 9989"* ]] \
  || fail "product implement did not open a safe PR and enter review ($(field issue-32 .stage)): $(cat "$fixture/pr-create.args")"
eval "$gh_issue_stub"
eval "$gh_issue_stub"
# A delivered worker with no automatic unit transition is handed to the supervisor with its report as evidence.
units '{"units":[{"id":"pr-33","pr":4333,"stage":"implement","history":[]}]}'
printf 'completed work needs review\n' > "$sup/impl-33.md"
jq -n '{workers:[{pid:9733,unit:"pr-33",type:"implement",log:"i33.log",report:"impl-33.md"}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field pr-33 .stage)" == supervisor-review \
  && "$(field pr-33 '.history[-1].decision.decision')" == 'Hand off delivered worker result to supervisor' \
  && "$(field pr-33 '.history[-1].decision.evidence')" == 'impl-33.md' ]] || fail 'delivered worker handoff omitted its decision record'
export DEP_CHECK_SECONDS=0
# 依赖链：报告写 BLOCKED by #N → 停在 blocked-external；前置单元合并后自动回到 implement-pending
units '{"units":[{"id":"issue-41","issue":41,"lane":"pr","branch":"agent/issue-41","stage":"implement","task":"t","history":[]},{"id":"issue-40","issue":40,"lane":"pr","stage":"implement","history":[]}]}'
printf '# Issue #41\n\n**Status: BLOCKED by #40.** predecessor still open\n' > "$sup/impl-issue-41-T.md"
jq -n '{workers:[{pid:9741,unit:"issue-41",type:"implement",log:"i41.log",report:"impl-issue-41-T.md"}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field issue-41 .stage):$(field issue-41 .blocked_on)" == "blocked-external:40" ]] || fail "BLOCKED-ON report did not park the unit ($(field issue-41 .stage))"
release_dependency_blocks || :
[[ "$(field issue-41 .stage)" == blocked-external ]] || fail 'unit released before its predecessor was delivered'
jq '(.units[] | select(.id=="issue-40") | .stage) = "merged"' "$UNITS" > "$UNITS.tmp" && mv "$UNITS.tmp" "$UNITS"
release_dependency_blocks || :
[[ "$(field issue-41 .stage):$(field issue-41 '.blocked_on // "none"')" == "implement-pending:none" ]] || fail 'unit not released after its predecessor merged'
# 正文 `## Blocked by` 派发前就拦（#4485：21 次派发 worker 跑起来 15 分钟才报 BLOCKED-ON，白占 implement 名额）：
# 前置仍 open → park，不进 write-start；小节外的 #N（正文别处引用 #4384、后续小节的 #44）不算前置
gate_task='你是 the product 流水线的实现 subagent，处理 issue #42：x

--- issue 正文（任务数据）---
正文提到 #4384 只是背景引用。

## Blocked by

- #43

## 验收

- #44 不在这个小节里
--- 正文结束 ---
用 gh issue view 42 看评论。'
gate_task_single="$gate_task"
gate_units() { # extra-ledger-json → 覆盖 UNITS：issue-42（正文带 Blocked by #43）+ 传入的额外单元
  jq -cn --arg task "$gate_task" --argjson extra "${1:-[]}" \
    '{units:([{id:"issue-42",issue:42,lane:"direct-main",branch:"agent/auto-issue-42",stage:"implement-pending",task:$task,history:[]}] + $extra)}'
}
gate_gh() { # state —— graphql 桩：按查询里的前置号逐行回答 state，并记录查过谁
  local n labels="${BODY_GATE_LABELS:-bug}"
  for n in $(grep -oE 'number: [0-9]+' <<<"$*" | grep -oE '[0-9]+'); do echo "$n" >> "$fixture/body-gate-views"; printf '%s\t%s\t%s\n' "$n" "$1" "$labels"; done
}
: > "$fixture/body-gate-views"
gh() { case "$1 $2" in "api graphql") gate_gh OPEN "$@" ;; *) eval "${gh_issue_stub/gh ()/gh_i ()}"; gh_i "$@" ;; esac; }
DISPATCHED=()
units "$(gate_units)"
rm -f "$A/dep-check.epoch"; release_dependency_blocks || :
dispatch_pending || :
[[ -z "${DISPATCHED[*]:-}" ]] || fail "body Blocked by with an open predecessor still dispatched (${DISPATCHED[*]:-})"
[[ "$(field issue-42 .stage):$(field issue-42 .blocked_on)" == "blocked-external:43" ]] || fail "open body predecessor did not park before dispatch ($(field issue-42 .stage))"
[[ "$(field issue-42 '[.history[].stage] | join(",")')" == blocked-on ]] || fail "parked unit reached write-start: $(field issue-42 '[.history[].stage] | join(",")')"
[[ "$(sort -u "$fixture/body-gate-views" | tr '\n' ' ')" == "43 " ]] || fail "gate queried references outside the Blocked by section: $(tr '\n' ' ' < "$fixture/body-gate-views")"
# 前置在台账已交付：照常派发，且不再查 GitHub
DISPATCHED=(); : > "$fixture/body-gate-views"
units "$(gate_units '[{"id":"issue-43","issue":43,"stage":"landed","history":[]}]')"
rm -f "$A/dep-check.epoch"; release_dependency_blocks || :
dispatch_pending || :
[[ "${DISPATCHED[0]:-}" == implement:issue-42:* ]] || fail "ledger-delivered body predecessor blocked dispatch (${DISPATCHED[*]:-none})"
[[ ! -s "$fixture/body-gate-views" ]] || fail "gate queried GitHub for a ledger-delivered predecessor: $(tr '\n' ' ' < "$fixture/body-gate-views")"
# 前置不在台账但已关（人工交付）：照常派发
DISPATCHED=(); : > "$fixture/body-gate-views"
gh() { case "$1 $2" in "api graphql") gate_gh CLOSED "$@" ;; *) eval "${gh_issue_stub/gh ()/gh_i ()}"; gh_i "$@" ;; esac; }
units "$(gate_units)"
rm -f "$A/dep-check.epoch"; release_dependency_blocks || :
dispatch_pending || :
[[ "${DISPATCHED[0]:-}" == implement:issue-42:* ]] || fail "closed body predecessor (outside the ledger) blocked dispatch (${DISPATCHED[*]:-none})"
# 伞形 roadmap issue 沿用既有豁免
BODY_GATE_LABELS=roadmap-epic
DISPATCHED=()
gh() { case "$1 $2" in "api graphql") gate_gh OPEN "$@" ;; *) eval "${gh_issue_stub/gh ()/gh_i ()}"; gh_i "$@" ;; esac; }
units "$(gate_units)"
rm -f "$A/dep-check.epoch"; release_dependency_blocks || :
dispatch_pending || :
[[ "${DISPATCHED[0]:-}" == implement:issue-42:* ]] || fail "roadmap umbrella in Blocked by still blocked dispatch (${DISPATCHED[*]:-none})"
BODY_GATE_LABELS=bug
# 多前置：台账已交付的跳过，停在仍未交付的那个上
DISPATCHED=(); : > "$fixture/body-gate-views"
gh() { case "$1 $2" in "api graphql") gate_gh OPEN "$@" ;; *) eval "${gh_issue_stub/gh ()/gh_i ()}"; gh_i "$@" ;; esac; }
gate_task="${gate_task//- #43/- #43
- #45}"
units "$(gate_units '[{"id":"issue-43","issue":43,"stage":"landed","history":[]}]')"
rm -f "$A/dep-check.epoch"; release_dependency_blocks || :
dispatch_pending || :
[[ -z "${DISPATCHED[*]:-}" && "$(field issue-42 .stage):$(field issue-42 .blocked_on)" == "blocked-external:45" ]] \
  || fail "gate ignored a second undelivered body predecessor ($(field issue-42 .stage):$(field issue-42 '.blocked_on // "none"'))"
# issue 正文明示的前置仍 open 时，即使有 stack metadata 也先停；前置进入台账后照常恢复
gate_task="$gate_task_single"
units "$(gate_units '[{"id":"issue-43","issue":43,"branch":"agent/issue-43","stage":"ready-to-merge","history":[]}]')"
set_unit issue-42 '.stacked_on_unit="issue-43" | .stacked_on_branch="agent/issue-43" | .stacked_on_sha="0123456789abcdef0123456789abcdef01234567"'
jq -cn '{epoch:0,states:{"43":{state:"OPEN",labels:"bug"}}}' > "$A/dep-check.cache.json"
DISPATCHED=()
dispatch_pending || :
[[ -z "${DISPATCHED[*]:-}" && "$(field issue-42 .stage):$(field issue-42 .blocked_on)" == "blocked-external:43" ]] \
  || fail "open body prerequisite was bypassed by stack metadata (${DISPATCHED[*]:-none}, $(field issue-42 .stage))"
jq '(.units[] | select(.id=="issue-43") | .stage) = "landed"' "$UNITS" > "$UNITS.tmp" && mv "$UNITS.tmp" "$UNITS"
DEP_CHECK_SECONDS=600; printf '%s\n' "$NOW_EPOCH" > "$A/dep-check.epoch"; release_dependency_blocks || :; DEP_CHECK_SECONDS=0
DISPATCHED=(); dispatch_pending || :
[[ "${DISPATCHED[0]:-}" == implement:issue-42:* ]] || fail "delivered body prerequisite did not release stacked dependent (${DISPATCHED[*]:-none})"
long_issue_body="$(awk 'BEGIN { for (i=0; i<6100; i++) printf "x"; print "\n## Blocked by\n- #7001" }')"
long_issue_json="$(jq -cn --arg body "$long_issue_body" '{number:7000,title:"long issue",body:$body}')"
gh() { [[ "$1 $2" == "issue view" ]] && printf '%s\n' "$long_issue_json"; }
long_issue_task="$(issue_unit_task 7000)"
[[ "$(jq -r '.body_blocked_by | join(",")' <<<"$long_issue_task")" == 7001 ]] \
  || fail 'complete-body dependency metadata lost a Blocked by section after the prompt truncation'
eval "$gh_issue_stub"
# 评审 BLOCK 写明前置 → 停在前置上（不按 main 前进去重评）；前置合并后回到 review-pending
units '{"units":[{"id":"pr-61","pr":61,"stage":"review","history":[]},{"id":"issue-60","issue":60,"lane":"pr","stage":"implement","history":[]}]}'
printf 'VERDICT: BLOCK\n- #61 is Blocked by #60, still open\n' > "$sup/review-61-T1.md"
jq -n --arg sha "$H1" '{workers:[{pid:4261,unit:"pr-61",type:"review",log:"x.log",report:"review-61-T1.md",sha:$sha,pr_head:$sha}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field pr-61 .stage):$(field pr-61 .blocked_on)" == "blocked-external:60" ]] || fail 'review BLOCK naming a predecessor did not park on it'
jq '(.units[] | select(.id=="issue-60") | .stage) = "merged"' "$UNITS" > "$UNITS.tmp" && mv "$UNITS.tmp" "$UNITS"
release_dependency_blocks || :
[[ "$(field pr-61 .stage)" == review-pending ]] || fail 'parked PR not sent back to review after its predecessor merged'
# 显式 `BLOCKED-ON: #N` 标记写在评审报告第 12 行之后（#3469 写在第 16 行）也要停在前置上，不升级成"无前置的阻塞"
units '{"units":[{"id":"pr-62","pr":62,"stage":"review","history":[]}]}'
{ printf 'VERDICT: BLOCK\n# PR #62\n'; for i in $(seq 1 12); do printf -- '- scope line %s\n' "$i"; done; printf -- '   - `BLOCKED-ON: #59`\n'; } > "$sup/review-62-T1.md"
jq -n --arg sha "$H1" '{workers:[{pid:4262,unit:"pr-62",type:"review",log:"x.log",report:"review-62-T1.md",sha:$sha,pr_head:$sha}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field pr-62 .stage):$(field pr-62 .blocked_on)" == "blocked-external:59" ]] || fail "explicit BLOCKED-ON marker past line 12 not parsed ($(field pr-62 .stage))"
# 停在前置上的单元：前置 issue 不在台账里就先把它收进来
units '{"units":[{"id":"issue-71","issue":71,"lane":"pr","stage":"blocked-external","blocked_on":70,"history":[]}]}'
gh() { case "$1 $2" in "issue view") jq -n --argjson n "$3" '{number:$n,title:"pred",state:"OPEN",labels:[{name:"bug"}],body:"b"}' ;; *) eval "${gh_issue_stub/gh ()/gh_i ()}"; gh_i "$@" ;; esac; }
[[ "$(predecessor_candidates)" == $'70\tpr\tpred\t["bug"]' ]] || fail "predecessor not offered for intake: $(predecessor_candidates)"
eval "$gh_issue_stub"
# 前置状态走一次 GraphQL：桩从 query 里取出各前置号，按给定状态/标签逐行回答
gh_dep_answer() { local n; for n in $(grep -oE 'number: [0-9]+' <<<"$*" | grep -oE '[0-9]+'); do printf '%s\t%s\n' "$n" "$1"; done; }
# 前置是路线图 epic：放开一次（epic 不是前置）；第二次停在同一 epic 上交给 supervisor
units '{"units":[{"id":"issue-81","issue":81,"lane":"pr","stage":"blocked-external","blocked_on":80,"history":[]}]}'
gh() { case "$1 $2" in "api graphql") gh_dep_answer $'OPEN\troadmap-epic,enhancement' "$@" ;; *) eval "${gh_issue_stub/gh ()/gh_i ()}"; gh_i "$@" ;; esac; }
release_dependency_blocks || :
[[ "$(field issue-81 .stage):$(field issue-81 '.blocked_on // "none"')" == "implement-pending:none" ]] || fail "unit parked on a roadmap epic was not released ($(field issue-81 .stage))"
jq '(.units[] | select(.id=="issue-81")) |= (.stage="blocked-external" | .blocked_on=80)' "$UNITS" > "$UNITS.tmp" && mv "$UNITS.tmp" "$UNITS"
release_dependency_blocks || :
[[ "$(field issue-81 .stage)" == supervisor-review \
  && "$(field issue-81 '.history[-1].decision.decision')" == 'Hand off repeated roadmap block to supervisor' \
  && "$(field issue-81 '.history[-1].decision.evidence')" == 'history contains repeated epic-not-predecessor events for #80' ]] || fail "second park on the same roadmap epic did not log its scope decision ($(field issue-81 .stage))"
# 两个单元互相等待：放开其中一个，另一个继续等它
units '{"units":[{"id":"issue-91","issue":91,"lane":"pr","stage":"blocked-external","blocked_on":92,"history":[]},{"id":"issue-92","issue":92,"lane":"pr","stage":"blocked-external","blocked_on":91,"history":[]}]}'
gh() { case "$1 $2" in "api graphql") gh_dep_answer $'OPEN\tbug' "$@" ;; *) eval "${gh_issue_stub/gh ()/gh_i ()}"; gh_i "$@" ;; esac; }
release_dependency_blocks || :
[[ "$(field issue-91 .stage):$(field issue-92 .stage)" == "implement-pending:blocked-external" ]] || fail "dependency cycle not broken ($(field issue-91 .stage) $(field issue-92 .stage))"
# 前置状态限频：同一前置一拍只查一次 GitHub；DEP_CHECK_SECONDS 内不再查，台账内已交付的仍立即放开
units '{"units":[{"id":"issue-93","issue":93,"stage":"blocked-external","blocked_on":99,"history":[]},{"id":"issue-94","issue":94,"stage":"blocked-external","blocked_on":99,"history":[]},{"id":"issue-95","issue":95,"stage":"blocked-external","blocked_on":96,"history":[]},{"id":"issue-96","issue":96,"stage":"implement","history":[]}]}'
: > "$fixture/dep-views"
gh() { case "$1 $2" in "api graphql") grep -oE 'number: [0-9]+' <<<"$*" | tr '\n' ' ' >> "$fixture/dep-views"; echo >> "$fixture/dep-views"; gh_dep_answer $'OPEN\tbug' "$@" ;; *) eval "${gh_issue_stub/gh ()/gh_i ()}"; gh_i "$@" ;; esac; }
rm -f "$A/dep-check.epoch"; DEP_CHECK_SECONDS=600 release_dependency_blocks || :
[[ "$(wc -l < "$fixture/dep-views"):$(grep -o 'number: 99' "$fixture/dep-views" | wc -l):$(grep -o 'number: 96' "$fixture/dep-views" | wc -l)" == "1:1:1" ]] || fail "predecessor states not fetched in one call naming each predecessor once: $(tr '\n' '|' < "$fixture/dep-views")"
jq '(.units[] | select(.id=="issue-96") | .stage) = "merged"' "$UNITS" > "$UNITS.tmp" && mv "$UNITS.tmp" "$UNITS"
DEP_CHECK_SECONDS=600 release_dependency_blocks || :
[[ "$(wc -l < "$fixture/dep-views"):$(field issue-95 .stage)" == "1:implement-pending" ]] || fail "throttled tick queried GitHub or missed a ledger-delivered predecessor ($(wc -l < "$fixture/dep-views") $(field issue-95 .stage))"
# 前置是已合并的 PR 号：一样算交付（gh issue view 对 PR 号失败，单元永远放不开）
units '{"units":[{"id":"issue-97","issue":97,"stage":"blocked-external","blocked_on":3808,"history":[]}]}'
gh() { case "$1 $2" in "api graphql") gh_dep_answer $'MERGED\t' "$@" ;; *) eval "${gh_issue_stub/gh ()/gh_i ()}"; gh_i "$@" ;; esac; }
rm -f "$A/dep-check.epoch"; release_dependency_blocks || :
[[ "$(field issue-97 .stage)" == implement-pending ]] || fail "unit parked on a merged PR was not released ($(field issue-97 .stage))"
# 前置 issue 仍 open（发布后才关），但它的 agent/issue-N PR 已合并：算交付（10-22 #3122/#3431 已合并，后继仍停着）
units '{"units":[{"id":"issue-98","issue":98,"stage":"blocked-external","blocked_on":3122,"history":[]},{"id":"issue-99","issue":99,"stage":"blocked-external","blocked_on":3123,"history":[]}]}'
: > "$fixture/dep-query"
gh() { case "$1 $2" in "api graphql") printf '%s' "$*" > "$fixture/dep-query"
    jq -r "${@: -1}" <<<'{"data":{"repository":{"i3122":{"state":"OPEN","labels":{"nodes":[{"name":"bug"}]}},"p3122":{"totalCount":1},"i3123":{"state":"OPEN","labels":{"nodes":[]}},"p3123":{"totalCount":0}}}}' ;;
  *) eval "${gh_issue_stub/gh ()/gh_i ()}"; gh_i "$@" ;; esac; }
rm -f "$A/dep-check.epoch"; release_dependency_blocks || :
grep -q 'headRefName: \"agent/issue-3122\", states: MERGED' "$fixture/dep-query" || grep -q 'headRefName: "agent/issue-3122", states: MERGED' "$fixture/dep-query" || fail "dependency query does not ask for the predecessor's merged PR: $(cat "$fixture/dep-query")"
[[ "$(field issue-98 .stage):$(field issue-99 .stage)" == "implement-pending:blocked-external" ]] || fail "merged agent/issue-N PR did not release its dependent, or an unmerged one did ($(field issue-98 .stage) $(field issue-99 .stage))"
# 台账里的 PR 单元常没有 .issue（孤儿收编），按分支名认前置
units '{"units":[{"id":"pr-3843","pr":3843,"branch":"agent/issue-3124","stage":"merged","history":[]},{"id":"issue-100","issue":100,"stage":"blocked-external","blocked_on":3124,"history":[]}]}'
DEP_CHECK_SECONDS=600 release_dependency_blocks || :
[[ "$(field issue-100 .stage)" == implement-pending ]] || fail "ledger PR unit merged on agent/issue-N did not release its dependent ($(field issue-100 .stage))"
# 孤儿 PR 对账：热修源 PR 先收（任意分支）；issue 已关的关掉；已有带 PR 的单元的关掉；台账单元没 PR 的保留；
# 其余按"挡着别人的前置优先"收，每次最多 ORPHAN_REGISTER_MAX 个；限频期内不再查（2026-10-20 120 个孤儿 PR）
units '{"units":[{"id":"pr-500","pr":500,"stage":"review","history":[]},{"id":"issue-61","issue":61,"pr":610,"stage":"review","history":[]},{"id":"issue-62","issue":62,"stage":"blocked-external","blocked_on":99,"history":[]},{"id":"issue-70","issue":70,"stage":"blocked-external","blocked_on":72,"history":[]}]}'
echo '{"blockers":[507]}' > "$A/release-blockers.json"; : > "$fixture/pr-ops"
gh() { case "$1 $2" in
  "pr list") echo '[{"number":500,"headRefName":"agent/issue-50","isDraft":false,"title":"known"},{"number":501,"headRefName":"agent/issue-60","isDraft":false,"title":"closed issue"},{"number":502,"headRefName":"agent/issue-61","isDraft":false,"title":"superseded"},{"number":503,"headRefName":"agent/issue-62","isDraft":false,"title":"only implementation"},{"number":504,"headRefName":"agent/issue-71","isDraft":false,"title":"plain"},{"number":505,"headRefName":"agent/issue-72","isDraft":true,"title":"predecessor"},{"number":506,"headRefName":"hand/x","isDraft":false,"title":"foreign"},{"number":507,"headRefName":"hand/hotfix","isDraft":false,"title":"hotpatch"},{"number":508,"headRefName":"agent/issue-73","isDraft":false,"title":"over cap"}]' ;;
  "issue list") echo '[{"number":60,"state":"CLOSED"},{"number":61,"state":"OPEN"},{"number":62,"state":"OPEN"},{"number":71,"state":"OPEN"},{"number":72,"state":"OPEN"},{"number":73,"state":"OPEN"}]' ;;
  "pr close"|"pr ready") echo "$1 $2 $3" >> "$fixture/pr-ops" ;;
  "pr edit") echo "$*" >> "$fixture/pr-ops" ;;
  esac; }
rm -f "$A/orphan-check.epoch"; ORPHAN_REGISTER_MAX=2 reconcile_orphan_prs || :
[[ "$(field pr-507 .critical):$(field pr-507 .stage)" == "true:review-pending" ]] || fail "release-blocker PR not registered first ($(field pr-507 .stage))"
[[ "$(sort "$fixture/pr-ops" | tr '\n' ' ')" == "pr close 501 pr close 502 pr edit 505 --add-label agent/ci-gated " ]] || fail "wrong PR closes/gates: $(tr '\n' ' ' < "$fixture/pr-ops")"
[[ "$(field pr-505 .issue):$(field pr-505 .critical):$(field pr-504 .issue)" == "72:true:71" ]] || fail "predecessor PR not taken first or plain PR not registered ($(field pr-505 .issue) $(field pr-504 .issue))"
[[ "$(field pr-505 .gated)" == true ]] || fail 'draft agent PR was not registered with its CI gate marker'
[[ -z "$(field pr-503 .id)$(field pr-508 .id)$(field pr-506 .id)" ]] || fail 'kept, over-cap or foreign PR was registered'
[[ "$(cat "$A/orphan-prs.count")" == "agent=2 foreign=1" ]] || fail "orphan count wrong: $(cat "$A/orphan-prs.count")"
: > "$fixture/pr-ops"; reconcile_orphan_prs || :
[[ ! -s "$fixture/pr-ops" ]] || fail 'reconcile ran again inside ORPHAN_CHECK_SECONDS'
eval "$gh_issue_stub"

# 生产热修回迁：评审写 BLOCKED-ON 也不停在前置上，先按热修规则重评，第二次交 supervisor；评审提示带热修规则
units '{"units":[{"id":"pr-596","pr":596,"hotpatch":true,"stage":"review","history":[]}]}'
park_blocked pr-596 145
[[ "$(field pr-596 .stage):$(field pr-596 '.blocked_on // "none"')" == "review-pending:none" ]] || fail "hot-patch forward-port parked on a predecessor ($(field pr-596 .stage))"
park_blocked pr-596 145
[[ "$(field pr-596 .stage)" == supervisor-review ]] || fail 'second predecessor block on a hot-patch unit did not escalate'
[[ "$(hotpatch_rule '{"hotpatch":true}')" == *生产热修回迁* && -z "$(hotpatch_rule '{}')" ]] || fail 'hot-patch review rule not applied only to hot-patch units'

# Advisor step: none ships. Rejections one and two repair as usual; the third goes straight to one arbiter review.
printf 'VERDICT: REQUEST-CHANGES\nF1 totals wrong\nF2 extra edge\n' > "$sup/review-70-T2.md"
CFG_SAVED="$CFG"; CFG="$(jq '.advisor=true' <<<"$CFG")"; ALIVE_PIDS=""; DISPATCHED=(); DISPATCH_PROMPT=""
units '{"units":[{"id":"pr-70","pr":70,"title":"totals","stage":"repair-pending","branch":"agent/issue-70","review_report":"review-70-T2.md","history":[{"stage":"review-request-changes"},{"stage":"repair-delivered"},{"stage":"review-request-changes"}]}]}'
dispatch_pending || :
[[ "${DISPATCHED[0]:-}" == repair:pr-70:* ]] || fail "second rejection did not get a normal repair (${DISPATCHED[*]:-none})"
DISPATCHED=()
set_unit pr-70 '.stage="repair-pending" | .history += [{"stage":"repair-delivered"},{"stage":"review-request-changes"}] | .review_findings=[{"round":1,"report":"a.md","block":"ok","findings":[{"id":"F1","severity":"P1","file":"src/a.ts","line":4,"rule":"Defect","status":"open","summary":"totals wrong"}]},{"round":3,"report":"c.md","block":"ok","findings":[{"id":"F1","severity":"P1","file":"src/b.ts","line":9,"rule":"Defect","status":"inherited","summary":"totals still wrong"}]}]'
dispatch_pending || :; dispatch_pending || :
[[ "$(field pr-70 .stage)" == review && "$(field pr-70 .arbiter)" == true \
  && "${DISPATCHED[0]:-}" == review:pr-70:* && "$DISPATCH_PROMPT" == *'【仲裁评审】'* ]] \
  || fail "third rejection did not dispatch the arbiter review (stage=$(field pr-70 .stage); ${DISPATCHED[*]:-none})"
[[ "$(field pr-70 '.history[-1].decision.decision')" == 'Route to one arbiter review' \
  && "$(field pr-70 '.history[-1].decision.why')" == 'no advisor configured' \
  && "$(field pr-70 '.history[-1].decision.owner')" == scheduler ]] || fail 'missing advisor did not record the arbiter choice'
CFG="$CFG_SAVED"; DISPATCHED=(); DISPATCH_PROMPT=""

# 派发顺序：修红 main > 热修回迁 > critical > 环节
units '{"units":[{"id":"a","stage":"repair-pending","history":[]},{"id":"b","stage":"review-pending","critical":true,"history":[]},{"id":"c","stage":"review-pending","hotpatch":true,"critical":true,"history":[]},{"id":"d","stage":"implement-pending","main_red":true,"history":[]},{"id":"e","stage":"review","critical":true,"history":[]}]}'
[[ "$(dispatch_order | jq -r .id | tr '\n' ' ')" == "d c b a " ]] || fail "dispatch order ignores release priority: $(dispatch_order | jq -r .id | tr '\n' ' ')"

# supervisor 裁决进评审提示；没有前置号的 blocked-external 单元交 supervisor
[[ "$(supervisor_rule '{"note":"CTO: #2535 is an epic"}')" == *"supervisor 裁决"*"#2535 is an epic"* && -z "$(supervisor_rule '{"note":"waiting"}')" ]] || fail 'supervisor ruling not passed to the worker prompt'
r="$(supervisor_rule '{"note":"CTO: last scoped repair","cto_rulings":["#2535 is an epic, not a predecessor"]}')"
[[ "$r" == *"last scoped repair"* && "$r" == *"#2535 is an epic"* ]] || fail 'an earlier CTO ruling was lost when the note changed'
units '{"units":[{"id":"issue-77","issue":77,"stage":"blocked-external","history":[]}]}'
release_dependency_blocks || :
[[ "$(field issue-77 .stage)" == supervisor-review ]] || fail 'blocked unit without a predecessor stayed parked forever'

# maintainer-test 是维护者提的 issue：收单且排在最前（issue-pipeline.md 队列顺序）
gh() { case "$1 $2" in "issue list") [[ "$*" == *ready-for-agent* ]] && echo '[{"number":5,"title":"top","labels":[{"name":"ready-for-agent"},{"name":"priority:top"}]},{"number":6,"title":"mine","labels":[{"name":"ready-for-agent"},{"name":"maintainer-test"}]},{"number":4,"title":"hot","labels":[{"name":"ready-for-agent"},{"name":"hotfix"}]}]' || echo '[]' ;; esac; }
[[ "$(intake_candidates | cut -f1 | tr '\n' ' ')" == "6 5 " ]] || fail "maintainer-test not taken first or hotfix taken: $(intake_candidates | cut -f1 | tr '\n' ' ')"
eval "$gh_issue_stub"

# 环节 SLO：待合并超 120 分钟报一次，不重复报；未超预算的不报
NOW_SAVED="$NOW_EPOCH"; NOW_EPOCH=1577847600
: > "$A/alerts/slo.md"
units '{"units":[{"id":"pr-95","pr":95,"stage":"ready-to-merge","history":[{"stage":"review-approve","at":"2020-01-01T00:00:00Z"}]},{"id":"pr-96","pr":96,"stage":"review-pending","history":[{"stage":"x","at":"2020-01-01T02:50:00Z"}]}]}'
stage_slo_watch; stage_slo_watch
[[ "$(grep -c 'SLO-BREACH unit=pr-95 stage=ready-to-merge waiting 180min' "$A/alerts/slo.md")" == 1 && "$(grep -c pr-96 "$A/alerts/slo.md")" == 0 ]] || fail "stage SLO breach not reported exactly once: $(cat "$A/alerts/slo.md")"
NOW_EPOCH="$NOW_SAVED"

# 复审报告被写成 review-N-<TAG>.md（丢了 -r-）：认领它，不当无产出死亡（pr-3972）
units '{"units":[{"id":"pr-72","pr":72,"stage":"rereview","history":[]}]}'
printf 'VERDICT: APPROVE\n' > "$sup/review-72-T9.md"; rm -f "$sup/review-72-r-T9.md"
jq -n --arg sha "$H1" '{workers:[{pid:7272,unit:"pr-72",type:"rereview",log:"r72.log",report:"review-72-r-T9.md",sha:$sha,pr_head:$sha}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field pr-72 .stage)" == ready-to-merge && -s "$sup/review-72-r-T9.md" ]] || fail "misnamed rereview report was treated as no output ($(field pr-72 .stage))"
# 正常结束但没写报告文件：用日志里 tokens used 之后的最终回复当报告，不当无产出死亡（issue-2593）
units '{"units":[{"id":"pr-73","pr":73,"stage":"rereview","history":[]}]}'
rm -f "$sup/review-73-r-T9.md"; printf 'codex\nworking\ntokens used\n1,234\nVERDICT: APPROVE\n' > "$sup/r73.log"
jq -n --arg sha "$H1" '{workers:[{pid:7373,unit:"pr-73",type:"rereview",log:"r73.log",report:"review-73-r-T9.md",sha:$sha,pr_head:$sha}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field pr-73 .stage)" == ready-to-merge && "$(cat "$sup/review-73-r-T9.md")" == 'VERDICT: APPROVE' ]] || fail "final message not recovered as the report ($(field pr-73 .stage))"
# 转人工的旧修 main 单元不挡新的红
recovery_home="${AGENT_HOME:-${HOME:-}/.zenoforge}"
mkdir -p "$recovery_home/main-red"
jq -cn --arg sha "$M3" \
  '{red_sha:$sha,red_workflow:"pipeline-suites.yml",status:"bisecting"}' \
  > "$recovery_home/main-red/$M3.json"
units '{"units":[]}'
open_main_red_unit "$M3" 41 1 || :
[[ "$(jq '.units | length' "$UNITS")" == 0 ]] || fail 'bisect-owned Pipeline suites red opened a duplicate repair worker'
rm -f "$recovery_home/main-red/$M3.json"
units "{\"units\":[{\"id\":\"main-red-old\",\"main_red\":true,\"stage\":\"supervisor-review\",\"history\":[]}]}"
open_main_red_unit "$M3" 41 1 || :
[[ "$(field main-red-old .stage)" == closed && "$(field "main-red-${M3:0:9}" .stage)" == implement-pending ]] || fail 'a parked main-red unit blocked the new red main'

# ---------- 门禁：新 [skip ci] 直落提交的 run 还在跑时，用链上最新已完成的裁决 ----------
gate_candidates_stub() { printf '%s\n%s\n' "$M3" "$M1"; }
suites_run_for() { case "$1" in "$M3") jq -cn --arg sha "$1" '{headSha:$sha,status:"in_progress",conclusion:null}';; "$M1") jq -cn --arg sha "$1" '{headSha:$sha,status:"completed",conclusion:"success",databaseId:7}';; esac; }
gate_eval_sha() { gate_candidates_stub; }
units "{\"units\":[{\"id\":\"pr-85\",\"pr\":85,\"stage\":\"ready-to-merge\",\"lane\":\"pr\",\"approved_sha\":\"$H1\",\"history\":[]}]}"
GH_MERGES=(); GH_MERGE_SHA="$M2"; MAIN_HEAD="$M3"
git() {
  if [[ " $* " == *" ls-remote "* ]]; then printf '%s\trefs/heads/main\n' "$MAIN_HEAD"
  elif [[ "${1:-}" == -C && "${3:-}" == fetch && "${!#}" == refs/pull/*/head ]]; then return 0
  elif [[ "${1:-}" == -C && "${3:-}" == rev-parse && "${5:-}" == FETCH_HEAD* ]]; then echo "$GH_HEAD"
  else command git "$@"; fi
}
run_merge_lane || :
[[ "${GH_MERGES[0]:-}" == *"pr merge 85"* ]] || fail 'gate waited on an in-progress run instead of the newest completed verdict'
suites_run_for() { case "$1" in "$M3") jq -cn --arg sha "$1" '{headSha:$sha,status:"completed",conclusion:"cancelled",databaseId:8}';; "$M1") jq -cn --arg sha "$1" '{headSha:$sha,status:"completed",conclusion:"success",databaseId:7}';; esac; }
units "{\"units\":[{\"id\":\"pr-85\",\"pr\":85,\"stage\":\"ready-to-merge\",\"lane\":\"pr\",\"approved_sha\":\"$H1\",\"history\":[]}]}"
GH_MERGES=()
run_merge_lane || :
[[ "${GH_MERGES[0]:-}" == *"pr merge 85"* ]] || fail 'a cancelled (superseded) run held the gate instead of the next verdict down the chain'
# main 套件未出结论（不是红）：流水线 PR 照合、合并后验证（不再以全绿当全局锁）；main 红时都等
suites_run_for() { [[ "$1" == "$M3" ]] && jq -cn --arg sha "$1" '{headSha:$sha,status:"in_progress",conclusion:null,databaseId:9,attempt:1}'; }; gate_eval_sha() { printf '%s\n' "$M3"; }
GH_CHECKS='[{"name":"Pipeline suites","bucket":"pass"}]'
units "{\"units\":[{\"id\":\"pr-86\",\"pr\":86,\"stage\":\"ready-to-merge\",\"lane\":\"pr\",\"approved_sha\":\"$H1\",\"history\":[]}]}"
GH_MERGES=(); run_merge_lane || :
[[ "${GH_MERGES[0]:-}" == *"pr merge 86"* ]] || fail 'pipeline PR waited on pending (not red) main suites'
suites_run_for() { [[ "$1" == "$M3" ]] && jq -cn --arg sha "$1" '{headSha:$sha,status:"completed",conclusion:"failure",databaseId:9,attempt:1}'; }
units "{\"units\":[{\"id\":\"pr-86\",\"pr\":86,\"stage\":\"ready-to-merge\",\"lane\":\"pr\",\"approved_sha\":\"$H1\",\"history\":[]}]}"
echo '{"'"$M3"'":"x"}' > "$A/gate-net-rerun.json"; omr_saved="$(declare -f open_main_red_unit)"; open_main_red_unit() { :; }
GH_MERGES=(); run_merge_lane || :
[[ ${#GH_MERGES[@]} == 0 ]] || fail 'pipeline PR merged while main suites were red'
eval "$omr_saved"; rm -f "$A/gate-net-rerun.json"
suites_run_for() { [[ "$1" == "$M3" ]] && jq -cn --arg sha "$1" '{headSha:$sha,status:"in_progress",conclusion:null,databaseId:9,attempt:1}'; }
units "{\"units\":[{\"id\":\"pr-86\",\"pr\":86,\"stage\":\"ready-to-merge\",\"lane\":\"pr\",\"hotpatch\":true,\"approved_sha\":\"$H1\",\"history\":[]}]}"
GH_MERGES=(); run_merge_lane || :
[[ "${GH_MERGES[0]:-}" == *"pr merge 86"* ]] || fail 'hot patch waited on pending (not red) main suites'
suites_run_for() { [[ "$1" == "$M3" ]] && jq -cn --arg sha "$1" '{headSha:$sha,status:"completed",conclusion:"failure",databaseId:9,attempt:1}'; }
echo '{}' > "$A/gate-net-rerun.json"; jq --arg s "$M3" '.[$s]="x"' "$A/gate-net-rerun.json" > "$A/g.tmp" && mv "$A/g.tmp" "$A/gate-net-rerun.json"
units "{\"units\":[{\"id\":\"pr-86\",\"pr\":86,\"stage\":\"ready-to-merge\",\"lane\":\"pr\",\"hotpatch\":true,\"approved_sha\":\"$H1\",\"history\":[]}]}"
GH_MERGES=(); run_merge_lane || :
[[ ${#GH_MERGES[@]} == 0 ]] || fail 'hot patch merged onto red main suites'
# pending 是已识别的执行状态，不是 API 空值/损坏输出的通行证；产品车道仍只看自身 PR CI。
(
  suites_run_for() { printf '%s\n' "$pending_observation"; }
  GH_CHECKS='[{"name":"Pipeline suites","bucket":"pass"}]'
  gate_eval_sha() { printf '%s\n' "$M3"; }
  for pending_status in queued in_progress waiting pending requested; do
    pending_observation="$(jq -cn --arg sha "$M3" --arg status "$pending_status" '{headSha:$sha,status:$status,conclusion:null,databaseId:19,attempt:1}')"
    units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-86",pr:86,stage:"ready-to-merge",lane:"pr",approved_sha:$sha,history:[]}]}')"
    GH_MERGES=(); run_merge_lane || :
    [[ "${GH_MERGES[0]:-}" == *"pr merge 86"* ]] || fail "valid $pending_status main observation blocked a pipeline PR"
  done
  for invalid_observation in missing malformed wrong-sha missing-run boolean-conclusion nonempty-conclusion unknown-status infra; do
    pending_observation="$(jq -cn --arg sha "$M3" '{headSha:$sha,status:"queued",conclusion:null,databaseId:19,attempt:1}')"
    case "$invalid_observation" in
      missing) pending_observation='' ;;
      malformed) pending_observation='{' ;;
      wrong-sha) pending_observation="$(jq --arg sha "$M1" '.headSha=$sha' <<<"$pending_observation")" ;;
      missing-run) pending_observation="$(jq 'del(.databaseId)' <<<"$pending_observation")" ;;
      boolean-conclusion) pending_observation="$(jq '.conclusion=false' <<<"$pending_observation")" ;;
      nonempty-conclusion) pending_observation="$(jq '.conclusion="failure"' <<<"$pending_observation")" ;;
      unknown-status) pending_observation="$(jq '.status="unavailable"' <<<"$pending_observation")" ;;
      infra) pending_observation="$(jq '.status="completed" | .conclusion="failure"' <<<"$pending_observation")"; GH_LOG='fatal: gnutls connection reset'; rm -f "$A/gate-net-rerun.json" ;;
    esac
    units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-86",pr:86,stage:"ready-to-merge",lane:"pr",approved_sha:$sha,history:[]}]}')"
    GH_MERGES=(); run_merge_lane || :
    [[ ${#GH_MERGES[@]} == 0 && "$(field pr-86 .stage)" == ready-to-merge ]] || fail "$invalid_observation main observation opened the pipeline lane"
  done
  pending_observation=''; GH_CHECKS='[{"name":"ci","bucket":"pass"}]'
  units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-86",pr:86,stage:"ready-to-merge",lane:"pr",approved_sha:$sha,history:[]}]}')"
  GH_MERGES=(); run_merge_lane || :
  [[ "${GH_MERGES[0]:-}" == *"pr merge 86"* && "$(field pr-86 .stage)" == merged ]] || fail 'missing pipeline observation blocked a green product PR'
)
unset GH_CHECKS; gate_eval_sha() { gate_candidates_stub; }
unset -f git suites_run_for
source <(sed -n '/^main_suites_load() {/,/^}/p;/^suites_run_for() {/,/^}/p' "$script_dir/scheduler.sh")
gate_eval_sha() { printf '%s' "$M1"; }
# main suites 首红先重跑；CLI 未确认先保留，服务端更高 attempt 能完成对账
GH_RUNS="[{\"headSha\":\"$M1\",\"conclusion\":\"failure\",\"status\":\"completed\",\"createdAt\":\"t\",\"attempt\":1,\"databaseId\":31}]"
GH_LOG='[pipeline suites] FAILED suite=engine/x.test.sh exit_code=1 first_error=not ok 2 - boom'
units '{"units":[]}'
GH_RERUNS=(); GH_RERUN_FAIL=1; rm -f "$A/gate-net-rerun.json"
run_merge_lane || :; run_merge_lane || :
[[ "$(jq '.units | length' "$UNITS")" == 0 && ${#GH_RERUNS[@]} == 1 ]] || fail 'same red or unconfirmed rerun request opened main-red or spent another retry'
GH_RUNS="$(jq '.[0].attempt=2' <<<"$GH_RUNS")"
run_merge_lane || :; run_merge_lane || :
GH_RERUN_FAIL=0
grep -Fq 'run view 31 --attempt 2 --log-failed' "$fixture/run-view.calls" || fail 'code failure logs were not bound to the observed attempt'
[[ "$(jq -r '[.units[] | select(.main_red == true) | .id] | join(",")' "$UNITS")" == "main-red-${M1:0:9}" ]] || fail "red main did not open exactly one fix unit: $(jq -c '[.units[].id]' "$UNITS")"
[[ "$(field "main-red-${M1:0:9}" .task)" == *"x.test.sh"* && "$(field "main-red-${M1:0:9}" .lane)" == direct-main ]] || fail 'main-red unit lacks the failing suite or the direct lane'
# 首红的并行复现：只有「父提交过、候选败」的报告才回退，其余、冲突、超时都走原路径（rerun 对账后开 main-red）。
eval "$main_red_real"
MR_REVERTS=(); MR_DISPATCHES=0
revert_squash_merge() { MR_REVERTS+=("$1 $2"); return "${MR_REVERT_STATUS:-0}"; }
main_red_launch() { printf '%s\n' "$MR_REPORT" > "$MAIN_RED_DIR/$1.report"; }
for mr_case in culprit fallback revert-conflict still-running; do
  rm -rf "$MAIN_RED_DIR"; rm -f "$A/gate-net-rerun.json"; GH_RERUNS=(); MR_REVERTS=(); MR_REVERT_STATUS=0
  GH_RUNS="[{\"headSha\":\"$M1\",\"conclusion\":\"failure\",\"status\":\"completed\",\"createdAt\":\"t\",\"attempt\":1,\"databaseId\":31}]"
  units "$(jq -cn --arg sha "$M2" '{units:[{id:"landed-1",stage:"landed",lane:"direct-main",land_sha:$sha,history:[]}]}')"
  MR_REPORT="culprit=$M2 suite=engine/x.test.sh first-red-run=31 green=$M3"
  case "$mr_case" in
    fallback) MR_REPORT='fallback=non-pipeline-commit-in-window' ;;
    revert-conflict) MR_REVERT_STATUS=1 ;;
    still-running) main_red_launch() { :; } ;;
  esac
  run_merge_lane || :; run_merge_lane || :
  GH_RUNS="$(jq '.[0].attempt=2' <<<"$GH_RUNS")"
  run_merge_lane || :; run_merge_lane || :
  [[ ${#GH_RERUNS[@]} -le 1 ]] || fail "$mr_case spent more than one native rerun"
  case "$mr_case" in
    culprit)
      [[ "${MR_REVERTS[*]}" == "main-red-${M1:0:9} $M2" ]] || fail "culprit was not reverted exactly once (${MR_REVERTS[*]:-none})"
      [[ "$(field landed-1 .stage)" == repair-pending && "$(field landed-1 .repair_hint)" == *"engine/x.test.sh"* ]] || fail 'the original unit did not return to repair with the suite evidence'
      [[ "$(jq '[.units[] | select(.main_red == true)] | length' "$UNITS")" == 0 ]] || fail 'a reverted culprit still opened a main-red unit' ;;
    fallback)
      [[ ${#MR_REVERTS[@]} == 0 && "$(field landed-1 .stage)" == landed && "$(field "main-red-${M1:0:9}" .stage)" == implement-pending ]] || fail 'a fallback report changed the current path' ;;
    revert-conflict)
      [[ ${#MR_REVERTS[@]} == 1 && "$(field "main-red-${M1:0:9}" .stage)" == implement-pending ]] || fail 'a failed revert was retried every tick or blocked main-red' ;;
    still-running)
      [[ ${#MR_REVERTS[@]} == 0 && "$(jq '[.units[] | select(.main_red == true)] | length' "$UNITS")" == 0 ]] || fail 'main-red opened while the reproduction was still running'
      main_red_launch() { printf '%s\n' "$MR_REPORT" > "$MAIN_RED_DIR/$1.report"; } ;;
  esac
done
unset -f revert_squash_merge main_red_launch
main_red_attribution() { MAIN_RED_REVERTED=0; MAIN_RED_PENDING=0; }
source <(sed -n '/^revert_squash_merge() {/,/^}/p' "$script_dir/scheduler.sh")
# 未知 attempt / 旧预算没有执行身份 / 不同 run 都不证明同一执行已经重跑失败。
for unavailable in missing-attempt legacy-reservation different-run; do
  units '{"units":[]}'; GH_RERUNS=(); rm -f "$A/gate-net-rerun.json"
  GH_RUNS="$(jq '.[0].attempt=1 | .[0].databaseId=31' <<<"$GH_RUNS")"
  case "$unavailable" in
    missing-attempt) GH_RUNS="$(jq '.[0] |= del(.attempt)' <<<"$GH_RUNS")" ;;
    legacy-reservation) jq -n --arg sha "$M1" '{($sha):"2026-10-20T00:00:00Z"}' > "$A/gate-net-rerun.json" ;;
    different-run)
      run_merge_lane || :
      GH_RUNS="$(jq '.[0].databaseId=311 | .[0].attempt=2' <<<"$GH_RUNS")" ;;
  esac
  run_merge_lane || :; run_merge_lane || :
  [[ "$(jq '.units | length' "$UNITS")" == 0 ]] || fail "$unavailable opened main-red without a later attempt of the reserved run"
  expected_reruns=0; [[ "$unavailable" != different-run ]] || expected_reruns=1
  [[ ${#GH_RERUNS[@]} == "$expected_reruns" ]] || fail "$unavailable reset the retry budget"
done
# 只有 suite 超时的失败是 CI 负载：门禁重跑，不开修 main 单元；合并后验证重跑，不回退产品 PR
timeout_log='[pipeline suites] FAILED suite=engine/land-queue.test.sh exit_code=137 first_error=suite engine/land-queue.test.sh timed out after 492s'
suites_timeout_only "$timeout_log" || fail 'timeout-only suite failure not classified as infra'
! suites_timeout_only "$timeout_log
not ok 2 - real" || fail 'a real test failure was classified as a timeout'
GH_LOG="$timeout_log"; GH_RERUNS=(); rm -f "$A/gate-net-rerun.json"
GH_RUNS="[{\"headSha\":\"$M2\",\"conclusion\":\"failure\",\"status\":\"completed\",\"createdAt\":\"t\",\"attempt\":1,\"databaseId\":32}]"
gate_eval_sha() { printf '%s' "$M2"; }
units '{"units":[]}'
run_merge_lane || :
[[ "${GH_RERUNS[*]:-}" == *"rerun 32 --failed"* && "$(jq '[.units[] | select(.main_red == true)] | length' "$UNITS")" == 0 ]] || fail 'timeout-only red main was not rerun (or opened a fix unit)'
GH_RUNS="$(jq '.[0].attempt=2' <<<"$GH_RUNS")"; run_merge_lane || :
[[ ${#GH_RERUNS[@]} == 1 && "$(jq '.units | length' "$UNITS")" == 0 ]] || fail 'second timeout attempt became a code verdict or reset the retry budget'
GH_RUNS="$(jq '.[0].attempt=1' <<<"$GH_RUNS")"
gate_eval_sha() { printf '%s' "$M1"; }
GH_RERUNS=()
GH_LOG=""
GH_RUNS="[{\"headSha\":\"$M1\",\"conclusion\":\"success\",\"status\":\"completed\",\"createdAt\":\"t\",\"databaseId\":7}]"
# 合并失败因冲突 → repair（以前每拍空试）；落后 main 的红 → update-branch，不在旧 base 重跑
MAIN_HEAD="$M1"; git() {
  if [[ " $* " == *" ls-remote "* ]]; then printf '%s\trefs/heads/main\n' "$MAIN_HEAD"
  elif [[ "${1:-}" == -C && "${3:-}" == fetch && "${!#}" == refs/pull/*/head ]]; then return 0
  elif [[ "${1:-}" == -C && "${3:-}" == rev-parse && "${5:-}" == FETCH_HEAD* ]]; then echo "$GH_HEAD"
  else command git "$@"; fi
}
gh_conf_stub="$(declare -f gh)"
gh() {
  case "$1 $2" in
    "pr merge") return 1 ;;
    "pr update-branch") GH_UPDATES+=("$*") ;;
    "api -X") GH_UPDATES+=("$*") ;;
    "pr view") [[ "$5" == mergeable ]] && { echo "$GH_MERGEABLE"; return; }; eval "${gh_conf_stub/gh ()/gh_c ()}"; gh_c "$@" ;;
    *) eval "${gh_conf_stub/gh ()/gh_c ()}"; gh_c "$@" ;;
  esac
}
GH_MERGEABLE=CONFLICTING; GH_UPDATES=()
units "{\"units\":[{\"id\":\"pr-15\",\"pr\":15,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H1\",\"history\":[]}]}"
run_merge_lane || :
[[ "$(field pr-15 .stage)" == repair-pending && "$(field pr-15 .repair_hint)" == *"merge --no-edit origin/main"* ]] || fail 'conflicting PR not sent to repair'
pr_behind_main() { return 0; }
GH_MERGEABLE=MERGEABLE; GH_CHECKS='[{"name":"suites","bucket":"fail"}]'
units "{\"units\":[{\"id\":\"pr-16\",\"pr\":16,\"stage\":\"ready-to-merge\",\"approved_sha\":\"$H1\",\"history\":[]}]}"
run_merge_lane || :
[[ "${GH_UPDATES[*]:-}" == *"pulls/16/update-branch"*"expected_head_sha=$H1"* && "$(field pr-16 .stage)" == ready-to-merge && "$(field pr-16 '.history[-1].stage')" == ci-red-update-branch ]] || fail 'red PR on a stale base was not updated from main'
unset GH_CHECKS; unset -f git pr_behind_main; eval "$gh_conf_stub"
source <(sed -n '/^pr_behind_main() {/,/^}/p' "$script_dir/scheduler.sh")
# revert_squash_merge is the single revert primitive (main-red recovery calls it): history-marker idempotency,
# conflict refusal and commit-not-on-main refusal, against a real bare origin.
(
  rv="$fixture/revert-prim"; rm -rf "$rv"; mkdir -p "$rv"
  command git init -q --bare -b main "$rv/origin.git"
  command git clone -q "$rv/origin.git" "$rv/seed" 2>/dev/null
  rg() { command git -C "$rv/seed" -c user.email=t@example.invalid -c user.name=t "$@"; }
  rg checkout -q -b main; echo one > "$rv/seed/f"; rg add f; rg commit -q -m base
  echo two > "$rv/seed/f"; rg commit -q -am 'squash change'; rv_bad="$(rg rev-parse HEAD)"
  rg push -q origin main
  rg checkout -q -b side "$rv_bad~1"; echo side > "$rv/seed/g"; rg add g; rg commit -q -m side; rv_off="$(rg rev-parse HEAD)"
  rg push -q origin side
  command git clone -q "$rv/origin.git" "$rv/root" 2>/dev/null
  ROOT="$rv/root"; WT_ROOT="$rv/wt"; LOG="$rv/say.log"; : > "$LOG"
  revert_squash_merge 1 "$rv_off" && fail 'a commit that is not on origin/main was reverted'
  grep -q 'refused: commit not on origin/main' "$LOG" || fail 'off-main revert refusal was not recorded'
  revert_squash_merge 1 "$rv_bad" || fail 'a clean squash commit was not reverted'
  [[ "$(command git -C "$rv/origin.git" log main -1 --format=%B | grep -c "This reverts commit $rv_bad")" == 1 ]] || fail 'revert did not land on origin/main with its history marker'
  head_after="$(command git -C "$rv/origin.git" rev-parse main)"
  revert_squash_merge 1 "$rv_bad" || fail 'a repeated revert was not treated as done'
  [[ "$(command git -C "$rv/origin.git" rev-parse main)" == "$head_after" ]] && grep -q 'already present' "$LOG" || fail 'a repeated revert pushed a second commit'
  # conflict: a later commit rewrites the same line, so the plain revert of the earlier change cannot apply
  rg checkout -q main; rg pull -q origin main 2>/dev/null; echo A > "$rv/seed/f"; rg commit -q -am 'change A'; rv_conf="$(rg rev-parse HEAD)"
  echo B > "$rv/seed/f"; rg commit -q -am 'change B'; rg push -q origin main
  conf_head="$(command git -C "$rv/origin.git" rev-parse main)"
  revert_squash_merge 2 "$rv_conf" && fail 'a conflicting revert reported success'
  grep -q 'merge revert conflict PR#2' "$LOG" && [[ "$(command git -C "$rv/origin.git" rev-parse main)" == "$conf_head" ]] || fail 'a conflicting revert was not refused cleanly'
)
# update-branch 的干净合并沿用批准；夹带改动的合并不沿用
ac="$fixture/carry"; rm -rf "$ac"; command git init -q -b main "$ac/src"
command git -C "$ac/src" commit -q --allow-empty -m m0
command git -C "$ac/src" checkout -q -b topic; echo a > "$ac/src/a"; command git -C "$ac/src" add a; command git -C "$ac/src" commit -q -m a1
ac_ok="$(command git -C "$ac/src" rev-parse HEAD)"
command git -C "$ac/src" checkout -q main; echo m > "$ac/src/m"; command git -C "$ac/src" add m; command git -C "$ac/src" commit -q -m m1
command git -C "$ac/src" checkout -q topic; command git -C "$ac/src" merge -q --no-edit main
ac_merge="$(command git -C "$ac/src" rev-parse HEAD)"
echo evil > "$ac/src/e"; command git -C "$ac/src" add e; command git -C "$ac/src" commit -q --amend --no-edit
ac_evil="$(command git -C "$ac/src" rev-parse HEAD)"
command git clone -q --bare "$ac/src" "$ac/remote.git"; command git clone -q "$ac/remote.git" "$ac/root"
command git -C "$ac/remote.git" update-ref refs/pull/16/head "$ac_merge"
( ROOT="$ac/root"; approval_carries 16 "$ac_ok" "$ac_merge" ) || fail 'clean update-branch merge did not carry the approval'
command git -C "$ac/remote.git" update-ref refs/pull/16/head "$ac_evil"
! ( ROOT="$ac/root"; approval_carries 16 "$ac_ok" "$ac_evil" ) || fail 'merge with extra changes carried the approval'
# main 在本地 origin/main 之后又前进（update-branch 合的是 GitHub 最新 main）：仍沿用批准。
command git -C "$ac/src" checkout -q main; echo m2 > "$ac/src/m2"; command git -C "$ac/src" add m2; command git -C "$ac/src" commit -q -m m2
command git -C "$ac/src" checkout -q -b topic2 "$ac_ok"; command git -C "$ac/src" merge -q --no-edit main
ac_merge2="$(command git -C "$ac/src" rev-parse HEAD)"
command git -C "$ac/src" push -q "$ac/remote.git" main topic2
command git -C "$ac/remote.git" update-ref refs/pull/16/head "$ac_merge2"
( ROOT="$ac/root"; approval_carries 16 "$ac_ok" "$ac_merge2" ) || fail 'a clean merge of a main newer than the local origin/main did not carry the approval'

NOW_EPOCH=100000

# ---------- BLOCK 只在 head 变或 main 推进（各一次）时重派 ----------
GH_HEAD="$H1"; MAIN_HEAD="$M1"
units "{\"units\":[{\"id\":\"pr-30\",\"pr\":30,\"stage\":\"blocked-external\",\"reviewed_sha\":\"$H1\",\"blocked_main_sha\":\"$M1\",\"history\":[]}]}"
retry_blocked_units || :
[[ "$(field pr-30 .stage)" == blocked-external ]] || fail 'BLOCK re-dispatched with nothing changed'
MAIN_HEAD="$M2"; retry_blocked_units || :
[[ "$(field pr-30 .stage)" == review-pending ]] || fail 'BLOCK not retried once after main moved'
jq '(.units[0].stage)="blocked-external"' "$UNITS" > "$UNITS.t" && mv "$UNITS.t" "$UNITS"
MAIN_HEAD="$M3"; retry_blocked_units || :
[[ "$(field pr-30 .stage)" == blocked-external ]] || fail 'BLOCK retried more than once for main movement'
GH_HEAD="$H2"; retry_blocked_units || :
[[ "$(field pr-30 .stage)" == rereview-pending ]] || fail 'BLOCK not retried after head moved'
unset -f git gate_eval_sha
source <(sed -n '/^gate_eval_sha() {/,/^}/p' "$script_dir/scheduler.sh")
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# ---------- 门禁评估点跳过 [skip ci] 提交；分支清理只删 [gone]；隔离 clone ----------
remote="$fixture/remote.git"; ROOT="$fixture/root"
command git init -q --bare "$remote"
command git init -q -b main "$ROOT"
command git -C "$ROOT" config user.email t@example.invalid; command git -C "$ROOT" config user.name t
command git -C "$ROOT" commit -q --allow-empty -m 'feat: real change'
real_sha="$(command git -C "$ROOT" rev-parse HEAD)"
command git -C "$ROOT" commit -q --allow-empty -m '[skip ci] docs: handoff'
command git -C "$ROOT" remote add origin "$remote"
command git -C "$ROOT" push -q origin main
command git -C "$ROOT" fetch -q origin
skip_sha="$(command git -C "$ROOT" rev-parse HEAD)"
[[ "$(gate_eval_sha | tr '\n' ' ')" == "$skip_sha $real_sha " ]] || fail 'gate candidates must run from HEAD back to the first non-[skip ci] commit'

command git -C "$ROOT" branch agent/pushed && command git -C "$ROOT" push -q -u origin agent/pushed 2>/dev/null
command git -C "$ROOT" branch agent/local-only
command git -C "$remote" branch -D agent/pushed >/dev/null
rm -f "$A/.branch-gc"
AP_TMPDIR="$fixture/ap-tmp"; mkdir -p "$AP_TMPDIR/stale-test/pg" "$AP_TMPDIR/live-test"
touch -d '-2 days' "$AP_TMPDIR/stale-test"
cleanup_tick || :
! command git -C "$ROOT" rev-parse -q --verify refs/heads/agent/pushed >/dev/null || fail 'branch with a gone upstream was kept'
command git -C "$ROOT" rev-parse -q --verify refs/heads/agent/local-only >/dev/null || fail 'never-pushed local branch was deleted'
[[ ! -e "$AP_TMPDIR/stale-test" && -d "$AP_TMPDIR/live-test" ]] || fail 'worker tmp reap must drop day-old entries and keep fresh ones'
unset AP_TMPDIR
# L72：worker 直接写在 tmpfs /tmp 的条目：里外 6 小时没写才收；内部仍有新写入（在跑的构建）不收；claude-* 不动
st="$fixture/sys-tmp"; mkdir -p "$st/old-log-dir" "$st/live-build/out" "$st/claude-1000"
touch -d '-8 hours' "$st/old-log-dir" "$st/live-build" "$st/claude-1000"; touch "$st/live-build/out/fresh.js"
printf 'x' > "$st/old.zip"; touch -d '-8 hours' "$st/old.zip"
AP_SYSTEM_TMP="$st" AP_SYSTEM_TMP_FS=tmpfs cleanup_tick || :
[[ ! -e "$st/old-log-dir" && ! -e "$st/old.zip" && -d "$st/live-build" && -d "$st/claude-1000" ]] \
  || fail "system /tmp reap removed live or Claude entries, or kept stale ones ($(ls "$st" | tr '\n' ' '))"
mkdir -p "$st/old-on-disk"; touch -d '-8 hours' "$st/old-on-disk"
AP_SYSTEM_TMP="$st" AP_SYSTEM_TMP_FS=ext4 cleanup_tick || :
[[ -d "$st/old-on-disk" ]] || fail 'reaped a disk-backed /tmp'

# A terminal unit may still own work that cleanup_tick must preserve, in either
# supported worktree location. A pushed, clean worktree remains reclaimable.
cleanup_fixture="$fixture/cleanup-preservation"
cleanup_tmp_suffix="$$"
cleanup_dirty_id="cleanup-dirty-$cleanup_tmp_suffix"
cleanup_stash_id="cleanup-stash-$cleanup_tmp_suffix"
cleanup_unpushed_id="cleanup-unpushed-$cleanup_tmp_suffix"
cleanup_clean_id="cleanup-clean-$cleanup_tmp_suffix"
cleanup_tmp_clean_id="cleanup-tmp-clean-$cleanup_tmp_suffix"
cleanup_tmp_stash="/tmp/wt-$cleanup_stash_id"
cleanup_tmp_clean="/tmp/wt-$cleanup_tmp_clean_id"
[[ ! -e "$cleanup_tmp_stash" && ! -e "$cleanup_tmp_clean" ]] || fail 'cleanup test /tmp path already exists'
mkdir -p "$cleanup_fixture" "$cleanup_fixture/runtime" "$cleanup_fixture/supervisor" "$cleanup_fixture/wt"
cleanup_remote="$cleanup_fixture/remote.git"
cleanup_seed="$cleanup_fixture/seed"
command git init -q --bare "$cleanup_remote"
command git init -q -b main "$cleanup_seed"
command git -C "$cleanup_seed" config user.email t@example.invalid
command git -C "$cleanup_seed" config user.name t
echo base > "$cleanup_seed/tracked.txt"
command git -C "$cleanup_seed" add tracked.txt
command git -C "$cleanup_seed" commit -q -m cleanup-base
command git -C "$cleanup_seed" remote add origin "$cleanup_remote"
command git -C "$cleanup_seed" push -q -u origin main
command git --git-dir="$cleanup_remote" symbolic-ref HEAD refs/heads/main
cleanup_dirty_wt="$cleanup_fixture/wt/wt-$cleanup_dirty_id"
cleanup_unpushed_wt="$cleanup_fixture/wt/wt-$cleanup_unpushed_id"
cleanup_clean_wt="$cleanup_fixture/wt/wt-$cleanup_clean_id"
command git clone -q "$cleanup_remote" "$cleanup_dirty_wt"
echo uncommitted > "$cleanup_dirty_wt/scratch.txt"
command git clone -q "$cleanup_remote" "$cleanup_tmp_stash"
echo stashed > "$cleanup_tmp_stash/scratch.txt"
command git -C "$cleanup_tmp_stash" stash push -u -q -m issue-4463-cleanup-test
command git clone -q "$cleanup_remote" "$cleanup_unpushed_wt"
command git -C "$cleanup_unpushed_wt" commit -q --allow-empty -m cleanup-unpushed-test
command git clone -q "$cleanup_remote" "$cleanup_clean_wt"
command git clone -q "$cleanup_remote" "$cleanup_tmp_clean"
cleanup_unpushed_sha="$(command git -C "$cleanup_unpushed_wt" rev-parse HEAD)"
cleanup_saved_root="$ROOT" cleanup_saved_wt_root="$WT_ROOT" cleanup_saved_units="$UNITS"
cleanup_saved_workers="$WORKERS" cleanup_saved_sup="$SUP" cleanup_saved_runtime="$A" cleanup_saved_log="$LOG"
ROOT="$cleanup_fixture/root" WT_ROOT="$cleanup_fixture/wt" UNITS="$cleanup_fixture/units.json"
WORKERS="$cleanup_fixture/workers.json" SUP="$cleanup_fixture/supervisor" A="$cleanup_fixture/runtime" LOG="$cleanup_fixture/scheduler.log"
printf '{"workers":[]}\n' > "$WORKERS"
touch "$A/.branch-gc"
units "$(jq -cn --arg dirty "$cleanup_dirty_id" --arg stash "$cleanup_stash_id" \
  --arg unpushed "$cleanup_unpushed_id" --arg clean "$cleanup_clean_id" --arg tmp_clean "$cleanup_tmp_clean_id" \
  '{units:[$dirty,$stash,$unpushed,$clean,$tmp_clean] | map({id:.,stage:"closed"})}')"
cleanup_tick || fail 'cleanup tick failed while preserving terminal worktrees'
[[ -f "$cleanup_dirty_wt/scratch.txt" ]] || fail 'cleanup removed a terminal worktree with uncommitted changes'
[[ -d "$cleanup_tmp_stash" && -n "$(command git -C "$cleanup_tmp_stash" stash list)" ]] \
  || fail 'cleanup removed a terminal /tmp worktree with a stash'
[[ -d "$cleanup_unpushed_wt" && "$(command git -C "$cleanup_unpushed_wt" rev-parse HEAD)" == "$cleanup_unpushed_sha" ]] \
  || fail 'cleanup removed a terminal worktree with an unpushed HEAD'
[[ ! -e "$cleanup_clean_wt" && ! -e "$cleanup_tmp_clean" ]] \
  || fail 'cleanup kept a clean, pushed terminal worktree'
rm -rf -- "$cleanup_dirty_wt" "$cleanup_tmp_stash" "$cleanup_unpushed_wt" "$cleanup_seed" "$cleanup_remote" "$cleanup_fixture"
ROOT="$cleanup_saved_root" WT_ROOT="$cleanup_saved_wt_root" UNITS="$cleanup_saved_units"
WORKERS="$cleanup_saved_workers" SUP="$cleanup_saved_sup" A="$cleanup_saved_runtime" LOG="$cleanup_saved_log"

unset -f ensure_clone
source <(sed -n '/^fetch_local_first() {/,/^}/p;/^ensure_clone() {/,/^}/p' "$script_dir/scheduler.sh")
WT_ROOT="$fixture/wt"
wt="$(ensure_clone pr-40)"
[[ "$(command git -C "$wt" rev-parse HEAD)" == "$(command git -C "$ROOT" rev-parse origin/main)" ]] || fail 'review clone not at origin/main'
[[ "$(command git -C "$wt" remote get-url origin)" == "$remote" ]] || fail 'clone origin not the real remote'
if ensure_clone pr-41 fix/missing 1 >/dev/null; then fail 'repair clone accepted a branch missing on origin'; fi
# 评审 clone 检出 PR head（refs/pull/N/head）
pr_sha="$(command git -C "$ROOT" rev-parse HEAD~1)"
command git -C "$remote" update-ref refs/pull/40/head "$pr_sha"
unset -f checkout_pr_head
source <(sed -n '/^checkout_pr_head() {/,/^}/p' "$script_dir/scheduler.sh")
checkout_pr_head "$wt" 40 "$pr_sha" "$pr_sha" || fail 'checkout_pr_head failed'
[[ "$(command git -C "$wt" rev-parse HEAD)" == "$pr_sha" ]] || fail 'review clone not at the PR head'
if command git -C "$wt" show-ref --verify --quiet refs/remotes/origin/pr/40; then
  fail 'review clone retained a PR remote-tracking ref'
fi
command git -C "$wt" checkout -q --detach origin/main
echo dirty > "$wt/scratch.txt"
ensure_clone pr-40 >/dev/null || fail 'redispatch on a dirty clone failed'
command git -C "$wt" stash list | grep -q 'kept before redispatch' || fail 'dirty clone work was not preserved in a stash'
# 上一轮已提交未推送的修复：再派发时保留本地领先提交；分叉时留备份 ref
command git -C "$ROOT" branch fix/keep main 2>/dev/null; command git -C "$ROOT" push -q origin fix/keep 2>/dev/null
kwt="$(ensure_clone pr-43 fix/keep 1)" || fail 'clone for fix/keep failed'
command git -C "$kwt" commit -q --allow-empty -m 'local unpushed repair'
local_sha="$(command git -C "$kwt" rev-parse HEAD)"
ensure_clone pr-43 fix/keep 1 >/dev/null || fail 'redispatch on a branch with a local commit failed'
[[ "$(command git -C "$kwt" rev-parse HEAD)" == "$local_sha" ]] || fail 'unpushed local repair commit was reset away'
command git -C "$ROOT" checkout -q fix/keep && command git -C "$ROOT" commit -q --allow-empty -m 'remote moved' && command git -C "$ROOT" push -q origin fix/keep && command git -C "$ROOT" checkout -q main
ensure_clone pr-43 fix/keep 1 >/dev/null || fail 'redispatch on a diverged branch failed'
command git -C "$kwt" for-each-ref --format='%(objectname)' 'refs/autopilot-kept/' | grep -qx "$local_sha" || fail 'diverged local commit not kept in refs/autopilot-kept'
# 本地对象库已有目标提交就不碰 GitHub：把 ROOT 的 origin 指到不存在的路径，本地命中仍成功，对不上才走（此时失败的）GitHub 取。
real_origin="$(command git -C "$ROOT" remote get-url origin)"
command git -C "$ROOT" remote set-url origin "$fixture/no-such-remote"
MAIN_HEAD="$(command git -C "$ROOT" rev-parse refs/remotes/origin/main)"
lwt="$(ensure_clone pr-90)" || fail 'a target commit present in ROOT still needed GitHub'
[[ "$(command git -C "$lwt" rev-parse HEAD)" == "$MAIN_HEAD" && "$(command git -C "$lwt" remote get-url origin)" == "$fixture/no-such-remote" ]] || fail 'local seed missed main or changed the clone origin'
MAIN_HEAD="$M1"
if ensure_clone pr-90 >/dev/null; then fail 'a missing target commit did not fall back to the GitHub fetch'; fi
command git -C "$ROOT" remote set-url origin "$real_origin"
command git -C "$lwt" remote set-url origin "$real_origin"
MAIN_HEAD="$M1"
ensure_clone pr-90 >/dev/null || fail 'the retained GitHub fetch did not deliver main when the target was missing locally'
MAIN_HEAD=""


# ---------- 模型提供方：claude-* 走只读 claude 评审；codex 带 service_tier ----------
build_codex_command review claude-haiku-5-5 xhigh pr-50 'review prompt'
[[ "${CODEX_COMMAND[0]}" == claude && "$WORKER_STDOUT_REPORT" == 1 ]] || fail 'claude model not routed to claude CLI'
[[ " ${CODEX_COMMAND[*]} " == *" --model claude-haiku-5-5 --effort xhigh --permission-mode dontAsk --strict-mcp-config "* ]] || fail "claude flags wrong (MCP servers must not load): ${CODEX_COMMAND[*]}"
[[ " ${CODEX_COMMAND[*]} " != *"danger"* && " ${CODEX_COMMAND[*]} " != *"Write"* && " ${CODEX_COMMAND[*]} " != *"git push"* ]] || fail 'claude reviewer is not read-only'
[[ " ${CODEX_COMMAND[*]} " != *"Edit"* && " ${CODEX_COMMAND[*]} " != *"gh api"* && " ${CODEX_COMMAND[*]} " != *"sed"* ]] || fail 'claude reviewer allowlist grants a write-capable command'
build_codex_command implement gpt-6-luna max fix-1 'implement prompt'
[[ "${CODEX_COMMAND[0]}" == codex && "$WORKER_STDOUT_REPORT" == 0 && " ${CODEX_COMMAND[*]} " == *' --config service_tier="fast" '* ]] || fail "codex service tier missing: ${CODEX_COMMAND[*]}"
[[ " ${CODEX_COMMAND[*]} " == *" -c shell_environment_policy.inherit=all "* ]] || fail 'codex workers would lose the proxy env (L44)'
units '{"units":[{"id":"pr-70","pr":70,"stage":"repair-pending","session_ids":{"repair":"11111111-2222-3333-4444-555555555555"}}]}'
build_codex_command repair gpt-6-luna max pr-70 'p'
[[ " ${CODEX_COMMAND[*]} " == *" -c shell_environment_policy.inherit=all "* ]] || fail 'codex command lost proxy env policy'

source <(sed -n '/^dispatch() {/,/^}/p' "$script_dir/scheduler.sh")
mkdir -p "$fixture/cbin" "$fixture/cwd"
cat > "$fixture/cbin/claude" <<'SH'
#!/usr/bin/env bash
[[ "${FAKE_CLAUDE_FAIL:-0}" == 1 ]] && { echo partial; exit 1; }
printf 'VERDICT: APPROVE\nreviewed in %s\n' "$PWD"
SH
chmod +x "$fixture/cbin/claude"
units '{"units":[{"id":"pr-50","pr":50,"stage":"review-pending","history":[]}]}'
PATH="$fixture/cbin:$PATH" dispatch review claude-haiku-5-5 xhigh pr-50 r50.log r50.md 'p' "$H1" "$fixture/cwd" "$H2"
wait "$(jq -r '.workers[-1].pid' "$WORKERS")" || :
[[ "$(verdict_of "$SUP/r50.md")" == READY ]] && grep -Fq "reviewed in $fixture/cwd" "$SUP/r50.md" || fail 'claude stdout report not written from the unit clone'
[[ "$(jq -r '.workers[-1].pr_head' "$WORKERS")" == "$H2" ]] || fail 'reviewed PR head was not preserved with the worker'
FAKE_CLAUDE_FAIL=1 PATH="$fixture/cbin:$PATH" dispatch review claude-haiku-5-5 xhigh pr-50 r51.log r51.md 'p' "$H1" "$fixture/cwd"
wait "$(jq -r '.workers[-1].pid' "$WORKERS")" || :
[[ ! -e "$SUP/r51.md" ]] || fail 'failed claude run left a harvestable report'

# ---------- 提供方上限：冷却+回退，不计无产出、不转人工 ----------
printf 'tokens used\n617,176 20026092214463990\n' > "$fixture/tok.log"
[[ "$(tokens_of "$fixture/tok.log")" == 617176 ]] || fail 'tokens_of must take only the first number'
NOW_EPOCH=200000; rm -f "$A/cooldown.json"
CFG="$(jq '.models.review=["claude-haiku-5-5","xhigh"] | .models.review_fallback=["gpt-6-luna","max","fast"]' <<<"$CFG")"
alive() { return 1; }
units '{"units":[{"id":"pr-60","pr":60,"stage":"review","history":[{"stage":"worker-no-output"}]}]}'
printf "You've hit your session limit · resets 5pm\n" > "$sup/rv60.md.partial"
jq -n '{workers:[{pid:6060,unit:"pr-60",type:"review",log:"rv60.log",report:"rv60.md",model:"claude-haiku-5-5"}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field pr-60 .stage)" == review && "$(field pr-60 '.history[-1].stage')" == worker-provider-limit ]] || fail 'provider limit escalated or counted as no-output'
[[ ! -e "$sup/rv60.md.partial" ]] || fail 'limit partial not removed'
cooling claude || fail 'claude not cooling after a session-limit death'
NOW_EPOCH=$((NOW_EPOCH + 301)); cooling claude || fail 'session limit released after 5 minutes'; NOW_EPOCH=$((NOW_EPOCH - 301))
pick review && [[ "$PICK_MODEL" == gpt-6-luna && "$PICK_EFFORT" == max ]] || fail "review did not fall back while claude cools ($PICK_MODEL)"
NOW_EPOCH=$((NOW_EPOCH + 1801))
pick review && [[ "$PICK_MODEL" == claude-haiku-5-5 ]] || fail 'review did not return to haiku after cooldown'
CFG="$(jq '.models.implement=["gpt-6-luna","max","fast"] | .models.implement_hotfix=["gpt-6.1-terra","high"]' <<<"$CFG")"
pick implement '{"labels":["bug","hotfix"]}' && [[ "$PICK_MODEL" == gpt-6.1-terra && "$PICK_EFFORT" == high ]] || fail "hotfix unit did not pick implement_hotfix ($PICK_MODEL)"
pick implement '{"labels":["bug"]}' && [[ "$PICK_MODEL" == gpt-6-luna ]] || fail "non-hotfix unit picked $PICK_MODEL"
build_codex_command review gpt-6-luna max pr-60 'p'
[[ " ${CODEX_COMMAND[*]} " == *' --config service_tier="fast" '* ]] || fail 'fallback codex review lost its service tier'

# 日志里的普通文字（技能说明 "an overloaded word"）不能触发冷却；真实的 codex 错误行可以
rm -f "$A/cooldown.json"; NOW_EPOCH=300000
units '{"units":[{"id":"pr-61","pr":61,"stage":"repair","history":[]}]}'
printf -- '- /domain-modeling: resolve an overloaded word ("account" doing three jobs)\nrate limit handling is described in docs\n' > "$sup/rp61.worker.log"
jq -n '{workers:[{pid:6161,unit:"pr-61",type:"repair",log:"rp61.worker.log",report:"rp61.md",model:"gpt-6-luna"}]}' > "$WORKERS"
harvest_workers || :
! cooling codex || fail 'ordinary log text triggered a provider cooldown'
units '{"units":[{"id":"pr-62","pr":62,"stage":"repair","history":[]}]}'
printf 'working...\nERROR: Selected model is at capacity. Please try a different model.\n' > "$sup/rp62.worker.log"
jq -n '{workers:[{pid:6262,unit:"pr-62",type:"repair",log:"rp62.worker.log",report:"rp62.md",model:"gpt-6-luna"}]}' > "$WORKERS"
harvest_workers || :
cooling codex || fail 'real codex capacity error did not start a cooldown'
NOW_EPOCH=$((300000 + 301))
! cooling codex || fail 'transient capacity error held codex longer than 5 minutes'

# #4356 moves product Postsubmit recovery to issue-pipeline's durable tick;
# the old scheduler watcher would create a second owner and duplicate PRs.
! grep -q 'phase watch_main_postsubmit' "$script_dir/scheduler.sh" || fail 'scheduler still dispatches the retired main Postsubmit watcher'
grep -q 'main-red-bisect' "$script_dir/../issue-pipeline.sh" \
  || fail 'issue-pipeline maintenance does not own main-red recovery'
# L71：没有 pid 文件时 CI 花费采样必须启动（kill -0 0 恒成功曾让它永不启动）
here_saved="$HERE"; HERE="$fixture/health-code"; mkdir -p "$HERE"
printf 'import sys\n' > "$HERE/node_health.py"
printf 'open("%s/ci-spend.started", "w").write("1")\n' "$A" > "$HERE/ci_spend.py"
rm -f "$A/.ci-spend.pid" "$A/ci-spend.json" "$A/ci-spend.started"
run_node_health
wait "$(cat "$A/.ci-spend.pid")" 2>/dev/null || :
[[ -e "$A/ci-spend.started" ]] || fail 'CI spend sampler never started without a pid file'
rm -f "$HERE/node_health.py" "$HERE/ci_spend.py" "$A/.ci-spend.pid" "$A/ci-spend.started"
HERE="$here_saved"

# A moved approved predecessor head is rebased under the dependent branch, and the dependent approval is invalidated.
stack_saved_root="$ROOT"; stack_saved_wt_root="$WT_ROOT"; stack_saved_main_head="$MAIN_HEAD"
NOW_EPOCH=900000; DEP_CHECK_SECONDS=0; printf '0\n' > "$A/dep-check.epoch"
stack_root="$fixture/stack-root"; stack_remote="$fixture/stack-origin.git"; stack_wt="$fixture/stack-wt"
command git init -q --bare "$stack_remote"
command git init -q -b main "$stack_root"
command git -C "$stack_root" config user.email t@example.invalid
command git -C "$stack_root" config user.name t
printf 'base\n' > "$stack_root/base.txt"
command git -C "$stack_root" add base.txt; command git -C "$stack_root" commit -q -m base
command git -C "$stack_root" remote add origin "$stack_remote"
command git -C "$stack_root" push -q -u origin main
command git --git-dir="$stack_remote" symbolic-ref HEAD refs/heads/main
stack_main_sha="$(command git -C "$stack_root" rev-parse HEAD)"
command git -C "$stack_root" checkout -q -b agent/issue-1
printf 'parent one\n' > "$stack_root/parent.txt"
command git -C "$stack_root" add parent.txt; command git -C "$stack_root" commit -q -m parent-one
stack_parent_old="$(command git -C "$stack_root" rev-parse HEAD)"
command git -C "$stack_root" push -q origin HEAD:refs/heads/agent/issue-1
command git -C "$stack_root" checkout -q -b agent/issue-2 "$stack_parent_old"
printf 'child work\n' > "$stack_root/child.txt"
command git -C "$stack_root" add child.txt; command git -C "$stack_root" commit -q -m child-work
stack_child_old="$(command git -C "$stack_root" rev-parse HEAD)"
command git -C "$stack_root" push -q origin HEAD:refs/heads/agent/issue-2
command git -C "$stack_root" checkout -q agent/issue-1
printf 'parent two\n' > "$stack_root/parent.txt"
command git -C "$stack_root" commit -qam parent-two
stack_parent_new="$(command git -C "$stack_root" rev-parse HEAD)"
command git -C "$stack_root" push -q origin HEAD:refs/heads/agent/issue-1
ROOT="$stack_root" WT_ROOT="$stack_wt" MAIN_HEAD="$stack_main_sha"
stack_pr_view_real="$(declare -f pr_view)"; stack_dep_states_real="$(declare -f dep_states)"
stack_initial_gh_real="$(declare -f gh)"; stack_initial_edit_log="$fixture/stack-initial-pr-edit.log"
pr_view() { case "$2" in state) echo OPEN ;; headRefOid) echo "$stack_parent_new" ;; esac; }
dep_states() { printf '1\tOPEN\t\n'; }
gh() {
  case "$1 $2" in
    'pr edit') printf '%s\n' "$*" >> "$stack_initial_edit_log" ;;
    'pr view') printf '{"state":"OPEN","headRefOid":"%s"}\n' "$stack_parent_new" ;;
  esac
}
# A unit that already created its local branch before discovering the dependency must still move onto the approved head.
mkdir -p "$stack_wt"
command git clone -q "$stack_remote" "$stack_wt/wt-issue-3"
command git -C "$stack_wt/wt-issue-3" checkout -q -b agent/issue-3 refs/remotes/origin/main
units "$(jq -cn --arg parent "$stack_parent_new" '{units:[
  {id:"issue-1",issue:1,lane:"pr",pr:101,branch:"agent/issue-1",stage:"ready-to-merge",approved_sha:$parent,reviewed_pr_head:$parent,history:[]},
  {id:"issue-3",issue:3,lane:"pr",pr:103,branch:"agent/issue-3",labels:["stack-pilot"],stage:"blocked-external",blocked_on:1,history:[]}
]}')"
printf '0\n' > "$A/dep-check.epoch"
release_dependency_blocks
[[ "$(field issue-3 .stage)" == implement-pending \
  && "$(command git -C "$stack_wt/wt-issue-3" rev-parse HEAD)" == "$stack_parent_new" \
  && "$(field issue-3 .stacked_on_sha)" == "$stack_parent_new" \
  && "$(cat "$stack_initial_edit_log")" == 'pr edit 103 --base agent/issue-1' ]] \
  || fail 'an existing dependent branch did not move onto its approved predecessor before dispatch'
eval "$stack_initial_gh_real"
units "$(jq -cn --arg parent "$stack_parent_new" '{units:[
  {id:"issue-1",issue:1,lane:"pr",pr:101,branch:"agent/issue-1",stage:"ready-to-merge",approved_sha:$parent,reviewed_pr_head:$parent,history:[]},
  {id:"issue-3",issue:3,lane:"pr",branch:"agent/issue-3",stage:"implement-pending",stacked_on_unit:"issue-1",stacked_on_sha:$parent,stacked_on_branch:"agent/issue-1",history:[]}
]}')"
stack_fresh_wt="$(ensure_clone issue-3 agent/issue-3 0 '' agent/issue-1 "$stack_parent_new")"
[[ "$(command git -C "$stack_fresh_wt" rev-parse HEAD)" == "$stack_parent_new" ]] \
  || fail 'new stacked implementation branch did not start at its predecessor head'
# A dependency refresh must not rewrite the branch while its implementer is still running.
stack_child_inflight_before="$(command git -C "$stack_wt/wt-issue-3" rev-parse HEAD)"
command git -C "$stack_root" checkout -q agent/issue-1
printf 'parent three\n' > "$stack_root/parent.txt"
command git -C "$stack_root" commit -qam parent-three
stack_parent_active_old="$stack_parent_new"
stack_parent_new="$(command git -C "$stack_root" rev-parse HEAD)"
command git -C "$stack_root" push -q origin HEAD:refs/heads/agent/issue-1
units "$(jq -cn --arg parent "$stack_parent_new" --arg old "$stack_parent_active_old" '{units:[
  {id:"issue-1",issue:1,pr:101,branch:"agent/issue-1",stage:"ready-to-merge",approved_sha:$parent,reviewed_pr_head:$parent,history:[]},
  {id:"issue-3",issue:3,pr:103,branch:"agent/issue-3",stage:"implement",blocked_on:1,stacked_on:"issue-1@\($old)",stacked_on_unit:"issue-1",stacked_on_sha:$old,stacked_on_branch:"agent/issue-1",history:[]}
]}')"
reconcile_stacked_units
[[ "$(field issue-3 .stage)" == implement \
  && "$(field issue-3 .stacked_on_sha)" == "$stack_parent_active_old" \
  && "$(command git -C "$stack_wt/wt-issue-3" rev-parse HEAD)" == "$stack_child_inflight_before" ]] \
  || fail 'stack reconciliation rewrote a branch while its implementer was running'
units "$(jq -cn --arg parent "$stack_parent_new" --arg old "$stack_parent_old" --arg child "$stack_child_old" '{units:[
  {id:"issue-1",issue:1,pr:101,branch:"agent/issue-1",stage:"ready-to-merge",approved_sha:$parent,reviewed_pr_head:$parent,history:[]},
  {id:"issue-2",issue:2,pr:102,branch:"agent/issue-2",stage:"ready-to-merge",blocked_on:1,stacked_on:"issue-1@\($old)",stacked_on_unit:"issue-1",stacked_on_sha:$old,stacked_on_branch:"agent/issue-1",approved_sha:$child,reviewed_pr_head:$child,history:[]}
]}')"
reconcile_stacked_units
stack_verify="$fixture/stack-verify"
command git clone -q "$stack_remote" "$stack_verify"
stack_child_new="$(command git -C "$stack_verify" rev-parse refs/remotes/origin/agent/issue-2)"
[[ "$(command git -C "$stack_verify" merge-base "$stack_parent_new" "$stack_child_new")" == "$stack_parent_new" \
  && -n "$(command git -C "$stack_verify" show "$stack_child_new:child.txt")" \
  && "$(field issue-2 .stacked_on_sha)" == "$stack_parent_new" \
  && "$(field issue-2 .stage)" == review-pending \
  && "$(field issue-2 '.approved_sha // "none"')" == none ]] \
  || fail 'dependent branch did not restack onto the changed predecessor or invalidate its review'
pr_view() { case "$2" in state) echo CLOSED ;; esac; }
reconcile_stacked_units
[[ "$(field issue-2 .stage)" == blocked-external && "$(field issue-2 .blocked_on)" == 1 ]] \
  || fail 'dependent unit did not return to waiting when its predecessor PR closed'
pr_view() { case "$2" in state) echo MERGED ;; esac; }
dep_states() { printf '1\tMERGED\t\n'; }
gh() { [[ "$1 $2" == 'issue view' ]] && echo OPEN; }
jq --arg id issue-1 '(.units[] | select(.id==$id) | .stage) = "merged"' "$UNITS" > "$UNITS.tmp" && mv "$UNITS.tmp" "$UNITS"
NOW_EPOCH=$((NOW_EPOCH + 1))
release_dependency_blocks
[[ "$(field issue-2 .stage)" == blocked-external && "$(field issue-2 .stacked_on_sha)" == "$stack_parent_new" ]] \
  || fail 'dependent unit left waiting before the merged predecessor completed its release cycle'
command git -C "$stack_root" checkout -q main
printf 'parent two\n' > "$stack_root/parent.txt"
command git -C "$stack_root" add parent.txt; command git -C "$stack_root" commit -q -m parent-squash-merge
command git -C "$stack_root" push -q origin main
stack_merged_main="$(command git -C "$stack_root" rev-parse HEAD)"; MAIN_HEAD="$stack_merged_main"
stack_pr_edit_log="$fixture/stack-pr-edit.log"
pr_view() { case "$2" in state) echo MERGED ;; esac; }
gh() {
  case "$1 $2" in
    'issue view') echo CLOSED ;;
    'pr edit') printf '%s\n' "$*" >> "$stack_pr_edit_log" ;;
  esac
}
NOW_EPOCH=$((NOW_EPOCH + 1))
release_dependency_blocks
stack_child_released="$(command git --git-dir="$stack_remote" rev-parse refs/heads/agent/issue-2)"
[[ "$(command git --git-dir="$stack_remote" merge-base "$stack_merged_main" "$stack_child_released")" == "$stack_merged_main" \
  && -n "$(command git --git-dir="$stack_remote" show "$stack_child_released:child.txt")" \
  && "$(field issue-2 .stacked_on_released)" == true \
  && "$(field issue-2 .stacked_on_branch)" == main \
  && "$(field issue-2 .stacked_on_sha)" == "$stack_merged_main" \
  && "$(field issue-2 '.blocked_on // "none"')" == none \
  && "$(field issue-2 .stage)" == review-pending \
  && "$(cat "$stack_pr_edit_log")" == 'pr edit 102 --base main' ]] \
  || fail 'dependent unit did not restack onto main after its predecessor release'
eval "$stack_pr_view_real"
eval "$stack_dep_states_real"
ROOT="$stack_saved_root"; WT_ROOT="$stack_saved_wt_root"; MAIN_HEAD="$stack_saved_main_head"
# ---------- PR 在 GitHub 已合并/关闭：派活前收掉（10-28 #4039/#4040 被重复派活）----------
retire_saved_tick_prs="$(declare -f tick_prs)"; retire_saved_pr_view="$(declare -f pr_view)"
tick_prs() { printf '[{"number":9001}]'; }
pr_view() { case "$1" in 9002) echo MERGED ;; 9003) echo CLOSED ;; *) echo OPEN ;; esac; }
units '{"units":[{"id":"pr-9001","pr":9001,"stage":"repair-pending","history":[]},{"id":"pr-9002","pr":9002,"stage":"repair-pending","history":[]},{"id":"issue-77","pr":9003,"stage":"rereview-pending","history":[]},{"id":"pr-9004","pr":9004,"stage":"review-pending","history":[]},{"id":"pr-9005","pr":9005,"stage":"merged","history":[]}]}'
retire_landed_pr_units
[[ "$(field pr-9001 .stage)" == repair-pending ]] || fail 'an open PR unit must stay in its work stage'
[[ "$(field pr-9002 .stage)" == merged ]] || fail 'a PR merged outside the pipeline must retire as merged'
[[ "$(field issue-77 .stage)" == closed ]] || fail 'a PR closed outside the pipeline must retire as closed'
[[ "$(field pr-9004 .stage)" == review-pending ]] || fail 'a PR missing from the open list but still OPEN must stay'
eval "$retire_saved_tick_prs"; eval "$retire_saved_pr_view"

# ---------- #4621：按 hotfix > opt > 普通 pipeline 让位；旧 waiter 不挡派发 ----------
rm -f "$LUNA_SLOTS"/wait-*
units '{"units":[{"id":"issue-9","stage":"review-pending","history":[]},{"id":"issue-opt","lane":"direct-main","stage":"review-pending","history":[]},{"id":"issue-hp","hotpatch":true,"stage":"review-pending","history":[]}]}'
: > "$LUNA_SLOTS/wait-opt-$$"   # 本测试 shell 的 pid，即存活等待者
room_for issue-9 review && fail 'ordinary dispatch admitted while an opt run waits at the luna/zc gate'
grep -q 'skip dispatch unit=issue-9 priority=normal (higher-priority run waiting at luna/zc gate: wait-opt-' "$A/scheduler.log" \
  || fail 'the priority hold left no record in scheduler.log'
room_for issue-opt review || fail 'an opt dispatch was held behind another opt waiter'
room_for issue-hp review || fail 'a hotpatch dispatch was held behind an opt waiter'
rm -f "$LUNA_SLOTS/wait-opt-$$"
: > "$LUNA_SLOTS/wait-hotfix-$$"
room_for issue-9 review && fail 'ordinary dispatch admitted while a hotfix run waits at the luna/zc gate'
room_for issue-opt review && fail 'an opt dispatch was admitted while a higher-priority hotfix waits'
room_for issue-hp review || fail 'a hotpatch dispatch was held behind another hotfix waiter'
grep -q 'skip dispatch unit=issue-opt priority=opt (higher-priority run waiting at luna/zc gate: wait-hotfix-' "$A/scheduler.log" \
  || fail 'the hotfix hold of opt work left no record in scheduler.log'
rm -f "$LUNA_SLOTS/wait-hotfix-$$"
room_for issue-9 review || fail 'dispatch did not resume after the wait file went away'
: > "$LUNA_SLOTS/wait-normal-$$"
room_for issue-9 review || fail 'a normal waiter must not hold other normal dispatches'
sleep 0.1 & gate_dead=$!; wait "$gate_dead"
kill -0 "$gate_dead" 2>/dev/null && fail "test setup: pid $gate_dead still alive"
: > "$LUNA_SLOTS/wait-hotfix-$gate_dead"
room_for issue-9 review || fail 'a stale wait file of a dead wrapper blocked dispatch'
[[ -e "$LUNA_SLOTS/wait-hotfix-$gate_dead" ]] && fail 'a stale wait file was not dropped'
rm -f "$LUNA_SLOTS"/wait-*

echo 'scheduler-gates.test.sh: PASS'
