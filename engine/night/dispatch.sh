#!/usr/bin/env bash
# Hand dispatch with the permissions the merged wrapper omits.
# engine/dispatch-codex.sh (#1555) launches codex at its default
# `workspace-write` sandbox, which has no network: an agent that has to
# `git push` or call `gh` dies within minutes (pid 866946 did, on #1605).
# Filed separately; this is the path that works meanwhile.
set -euo pipefail
WT="$1"; BRIEF="$2"; NAME="$3"; ROLE="${4:-work}"
REPORT="${5:-}"; ATTEMPT="${6:-0}"
RESUME_NOTE="${7:-}"
PROVIDER_RETRY="${8:-0}"; PROVIDER_EPISODE="${9:-}"
HAND_UNIT="zf-hand-$NAME-$$"
[[ "$NAME" =~ ^[[:alnum:]_.-]+$ ]] || { echo "invalid hand-agent name: $NAME" >&2; exit 2; }
[[ "$ATTEMPT" =~ ^[0-9]+$ ]] || { echo "invalid hand-agent attempt: $ATTEMPT" >&2; exit 2; }
[[ "$PROVIDER_RETRY" =~ ^[0-2]$ ]] || { echo "invalid hand-agent provider retry stage: $PROVIDER_RETRY" >&2; exit 2; }
case "$RESUME_NOTE" in *$'\t'*|*$'\n'*) echo "resume note cannot contain tabs or newlines" >&2; exit 2 ;; esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKTREE_LIFECYCLE="$SCRIPT_DIR/worktree-lifecycle.sh"
REPO_DIR="${ZF_REPO_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd -P)}"
if [[ -f "$REPO_DIR/engine/install-pre-push-guard.sh" ]]; then
  bash "$REPO_DIR/engine/install-pre-push-guard.sh" "$REPO_DIR"
fi
INDEX_ROOT="${ZF_CODE_INTELLIGENCE_ROOT:-${ZF_REPO_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd -P)}}"
source "$SCRIPT_DIR/config.sh"
NIGHT="${ZF_NIGHT_DIR:-$AGENT_HOME/night}"
WORKTREE_ROOT="${ZF_WORKTREE_ROOT:-$HOME/wt}"
source "$SCRIPT_DIR/lib.sh"
# Resolve the tier before any admission gate: the gate reads LUNA_PRIORITY
# (#4621 hotfix > opt > ordinary pipeline), so a priority-blind preflight must
# not defer a hotfix/opt dispatch under pipeline load first.
source "$SCRIPT_DIR/dispatch-load-guard.sh"
enqueue_priority="${ENQUEUE_PRIORITY:-}"
[[ "$RESUME_NOTE" != *'[queue-priority=pipeline]'* ]] || enqueue_priority=pipeline
TIER="$(hand_dispatch_tier "$ROLE" "$NAME" "$enqueue_priority")" || exit 2
LUNA_PRIORITY="$(hand_dispatch_worker_priority "$TIER")"
export LUNA_PRIORITY
pipeline_execution_admit || exit $?
source "$SCRIPT_DIR/night/hand-agent-watchdog.sh"
source "$SCRIPT_DIR/night/hand-crash-recovery.sh"
[[ -r "$SCRIPT_DIR/night/hand-exit-handoff.sh" ]] && source "$SCRIPT_DIR/night/hand-exit-handoff.sh"
PATH="$SCRIPT_DIR/gh-shim:$HOME/.local/bin:$PATH"
export PATH
export BROWSER="$HOME/.local/bin/zf-browser" ZF_AUTOMATION=1
unset DISPLAY WAYLAND_DISPLAY
if [ "$#" -gt 9 ]; then echo "usage: $0 WT BRIEF NAME [ROLE] [REPORT] [ATTEMPT] [RESUME_NOTE] [PROVIDER_RETRY] [PROVIDER_EPISODE]" >&2; exit 2; fi
case "$WT" in "~/"*) WT="$HOME/${WT:2}" ;; esac
WT="$(realpath -- "$WT")"
if ! agent_worktree_is_usable "$REPO_DIR" "$WT"; then
  echo "refusing: worktree $WT is not a usable worktree for $REPO_DIR" >&2
  supervisor_inbox_append_once "hand-dispatch-unusable-worktree:$NAME" \
    "hand-dispatch-unusable-worktree name=$NAME worktree=$WT repo=$REPO_DIR" \
    || echo "dispatch: could not write unusable-worktree alert for $NAME" >&2
  exit 2
fi
if existing_pid="$(hand_agent_worktree_pid "$WT")"; then
  echo "refusing: worktree already running codex pid=$existing_pid worktree=$WT" >&2
  exit 73
fi
HAND_NODE_NAMES="$(hand_agent_node_names "$NAME" "${HAND_NODES:-}")" || {
  echo "invalid hand-owned node list: ${HAND_NODES:-}" >&2
  exit 2
}
HAND_BUDGET_ROLE="$ROLE"
if [ "$TIER" = hotfix ]; then
  HAND_BUDGET_ROLE=production
elif [ "$ROLE" = review ]; then
  HAND_BUDGET_ROLE=work
fi
if [ "$PROVIDER_RETRY" -eq 2 ]; then IDENTITY="$(model_policy fallback-identity "$ROLE")"
else IDENTITY="$(model_policy dispatch-identity "$ROLE")"; fi
SERVICE_TIER="$(model_policy tier "$ROLE")"
IFS=: read -r PROVIDER MODEL EFFORT <<< "$IDENTITY"
HAND_BUDGET_ID=""
HAND_BUDGET_HANDED_OFF=1
case "$PROVIDER" in
  codex)
    if ! codex_dispatch_preflight hand-dispatch; then
      echo "dispatch failed for $NAME: Codex runtime unavailable; dispatch paused" >&2
      exit 1
    fi
    if codex_config_hides_env; then
      codex_env_detail="${CODEX_HOME:-$HOME/.codex}/config.toml sets shell_environment_policy inherit to core/none, which hides GH_TOKEN and the proxy from agent shells"
      supervisor_inbox_append_once env:codex-env-hidden "env:codex-env-hidden stage=hand-dispatch $codex_env_detail" || true
      echo "dispatch failed for $NAME: env:codex-env-hidden: $codex_env_detail" >&2
      exit 1
    fi
    HAND_BUDGET_ID="hand:$NAME:$$"
    if [ "$HAND_BUDGET_ROLE" = production ]; then
      HAND_BUDGET_TOKENS="$CODEX_PRODUCTION_RESERVATION_TOKENS"
    else
      HAND_BUDGET_TOKENS="$CODEX_HAND_DISPATCH_RESERVATION_TOKENS"
    fi
    if codex_budget_reserve "$HAND_BUDGET_ROLE" "$HAND_BUDGET_ID" "$HAND_BUDGET_TOKENS" 1 "" "$IDENTITY"; then
      :
    else
      budget_status=$?
      case "$budget_status" in
        75) echo "hand dispatch: Codex budget/provider hold; dispatch deferred" >&2 ;;
        2) echo "hand dispatch: invalid Codex budget configuration or parameters" >&2 ;;
        *) echo "hand dispatch: Codex budget reservation failed (exit $budget_status)" >&2 ;;
      esac
      exit "$budget_status"
    fi
    HAND_BUDGET_HANDED_OFF=0
    trap 'if [ "$HAND_BUDGET_HANDED_OFF" != 1 ] && [ -n "$HAND_BUDGET_ID" ]; then codex_budget_release "$HAND_BUDGET_ID" || true; fi' EXIT
    ;;
  zcode)
    zcode_provider_config="$HOME/.zcode/v2/provider_config.json"
    zcode_config_model="$(jq -er '.config.defaultModelSelection.modelId | strings' "$zcode_provider_config" 2>/dev/null || true)"
    [ "$zcode_config_model" = "$MODEL" ] || {
      echo "dispatch failed for $NAME: zcode config model mismatch (policy expects $MODEL at .config.defaultModelSelection.modelId)" >&2
      exit 1
    }
    command -v zcode >/dev/null 2>&1 || { echo "dispatch failed for $NAME: zcode runtime unavailable" >&2; exit 1; }
    ;;
  *) echo "role $ROLE has unsupported hand-agent provider: $PROVIDER" >&2; exit 2 ;;
esac
mkdir -p "$NIGHT"
case "$WT" in "~/"*) WT="$HOME/${WT:2}" ;; esac
case "$BRIEF" in "~/"*) BRIEF="$HOME/${BRIEF:2}" ;; esac
WT="$(realpath -- "$WT")"
BRIEF="$(realpath -- "$BRIEF")"
HAND_ISSUE_IDS="$(hand_agent_issue_ids_from_brief "$NAME" "$BRIEF" "${HAND_ISSUES:-}")" || {
  echo "invalid hand-owned issue list in $BRIEF" >&2
  exit 2
}
HAND_NON_PRODUCT_UNIT=0
if [[ -n "$HAND_ISSUE_IDS" ]]; then
  HAND_NON_PRODUCT_UNIT=1
  for issue in $HAND_ISSUE_IDS; do
    issue_json="$(gh issue view "$issue" --repo "$REPO" --json labels 2>/dev/null)" || {
      HAND_NON_PRODUCT_UNIT=0
      break
    }
    if ! pipeline_system_issue_matches "$issue_json"; then
      HAND_NON_PRODUCT_UNIT=0
      break
    fi
  done
fi
if [ -z "$REPORT" ]; then
  report_line="$(sed -n 's/^Report:[[:space:]]*//p' "$BRIEF" | sed -n '1p')"
  read -r REPORT _ <<< "$report_line"
fi
REPORT="${REPORT:-$NIGHT/$NAME-report.md}"
case "$REPORT" in "~/"*) REPORT="$HOME/${REPORT:2}" ;; esac
REPORT="$(realpath -m -- "$REPORT")"
case "$WT$BRIEF$REPORT" in *$'\t'*|*$'\n'*) echo "hand-agent paths cannot contain tabs or newlines" >&2; exit 2 ;; esac
if [ "$PROVIDER" = codex ]; then LOG="$NIGHT/codex-$NAME.log"; else LOG="$NIGHT/zcode-$NAME.log"; fi
MEMINFO_FILE="${AGENT_DISPATCH_MEMINFO_FILE:-/proc/meminfo}"
LOADAVG_FILE="${AGENT_DISPATCH_LOADAVG_FILE:-/proc/loadavg}"
LOAD_LIMIT_MULTIPLIER="${AGENT_DISPATCH_LOAD_LIMIT_MULTIPLIER:-2}"
avail="$(awk '$1=="MemAvailable:"{print int($2/1024)}' "$MEMINFO_FILE")"
# 2026-10-10: at a 2000 MB floor every dispatcher (queue, program sessions, agents) filled WSL's 12 GB,
# and post-land verification (needs 4608 MB) timed out after 1800 s again and again. Keep 6 GB free;
# production fixes keep the old 2000 MB floor so an outage fix is never refused behind ordinary work.
MIN_MEM_MB="$(hand_dispatch_memory_floor "$TIER")"
[ "$avail" -lt "$MIN_MEM_MB" ] && { echo "refusing: MemAvailable ${avail}MB below ${MIN_MEM_MB}MB floor" >&2; exit 1; }
load_1m="$(awk 'NR==1 {print $1}' "$LOADAVG_FILE")"
processors="$(nproc)"
# Production fixes (deploy unblocks) must not queue behind implement load:
# 2026-09-25 a blocked deploy waited twice behind this gate at load 27-31.
if [ -n "${AGENT_EXECUTION_CPU_TARGET_PERCENT:-}" ]; then
  # Refresh shared CPU/load fallback after preflight; do not apply a second load policy.
  python3 "$(pipeline_execution_guard)" resources >/dev/null || exit $?
else
if [ "$TIER" != hotfix ] && dispatch_load_exceeded "$load_1m" "$processors" "$LOAD_LIMIT_MULTIPLIER"; then
  echo "refusing: 1-min load $load_1m exceeds ${LOAD_LIMIT_MULTIPLIER}x nproc ($processors; limit $((processors * LOAD_LIMIT_MULTIPLIER)))" >&2
  exit 1
else
  load_status=$?
  [ "$load_status" -eq 1 ] || { echo "refusing: invalid 1-min load '$load_1m', nproc '$processors', or load multiplier '$LOAD_LIMIT_MULTIPLIER'" >&2; exit 1; }
fi
fi
# 2026-09-23 15:5xZ: 19 gitnexus MCP servers (one per agent) held 4.1GB; agents
# use the `gitnexus` CLI instead (see codex -c flags below).
# Work concurrency remains configurable; production resource admission uses the memory floor above.
MAX_AGENTS="${MAX_AGENTS:-10}"
if [ "$TIER" != hotfix ]; then
  running="$(hand_agent_process_count "$WORKTREE_ROOT/" ordinary-hand)"
  [ "${running:-0}" -ge "$MAX_AGENTS" ] && { echo "refusing: $running hand agents running, cap $MAX_AGENTS" >&2; exit 1; }
fi
HAND_START_TICKS="$(hand_agent_process_start_ticks "$$" 2>/dev/null)" || {
  echo "refusing: could not record dispatcher PID identity" >&2
  exit 2
}
HAND_LOCK_REASON="hand-agent:owner_pid=$$ owner_start_ticks=$HAND_START_TICKS unit=$HAND_UNIT"
HAND_WORKTREE_RECORDS="$(git -C "$REPO_DIR" worktree list --porcelain)" || {
  echo "refusing: could not read worktrees from $REPO_DIR" >&2
  exit 2
}
if grep -Fxq -- "worktree $WT" <<< "$HAND_WORKTREE_RECORDS"; then
  if ! git -C "$REPO_DIR" worktree lock --reason "$HAND_LOCK_REASON" "$WT" 2>/dev/null; then
    owner_status=0
    bash "$WORKTREE_LIFECYCLE" owner-live "$REPO_DIR" "$WT" "$$" >/dev/null 2>&1 || owner_status=$?
    if [ "$owner_status" -eq 0 ]; then
      echo "refusing: worktree $WT already has a live owner" >&2
      exit 2
    fi
    if [ "$owner_status" -ne 1 ]; then
      echo "refusing: worktree $WT owner state is unknown" >&2
      exit 2
    fi
    git -C "$REPO_DIR" worktree unlock "$WT" \
      && git -C "$REPO_DIR" worktree lock --reason "$HAND_LOCK_REASON" "$WT" \
      || { echo "refusing: could not record hand owner lock for $WT" >&2; exit 2; }
  fi
fi
rendered="$NIGHT/.rendered-$NAME.md"
{
  # The roster and the bell read this path; a brief naming another one made a
  # finished agent read as "no STATUS line" (hand-trace-753c, 2026-10-03).
  echo "Report file for this run: $REPORT. Write your report there, STATUS line first; this path overrides any report path the brief names."
  echo "GitNexus index for this run: --repo $INDEX_ROOT (name no other checkout)"
  echo 'Before finishing, re-read your brief file for new ## Addendum sections and address them.'
  cat <<'PRE'
## Required incremental landing

Publish each independently complete unit before beginning the next:
run focused verification, commit, push (direct to main for pipeline-system
changes; open or update a PR for product code), leave the issue/PR record.
For product code, open/update the PR, record it in your report, then exit.
The night caretaker merges PRs after checks turn green. Do not poll CI or wait
for a queue. Start the next unit immediately after publishing.
Before finishing, every PR you opened is merged or closed, or its handoff is
written in your report with the reason.

## Repairing a PR after failed CI

Before pushing a repair head for an existing PR, inspect the failed step in
the existing CI log and identify the failing test file or command. Run that
exact test locally on the repaired head; for build, typecheck, or static-check
failures, run the matching local command. If CI-only infrastructure prevents
the exact run, run the closest available focused check and record the failed
step, local command, and limitation in your report. Never claim the failed
check passed locally when it did not run. Do not rerun CI or wait for it.

Use the live checkout's `branch-delivery-preflight.mjs` to run that exact
command and write the local push-guard receipt. Read the failed check's
`link`, `name`, and `completedAt` from `gh pr checks <PR> --json name,link,completedAt,bucket`,
and the old head from `gh pr view <PR> --json headRefOid --jq .headRefOid`.
After committing the repaired head, run:

```bash
node "$HOME/.zenoforge/checkout/scripts/branch-delivery-preflight.mjs" --mode push --target main \
  --repair-ci-failure-link "$FAILED_CHECK_LINK" --repair-ci-check "$FAILED_CHECK_NAME" \
  --repair-ci-failed-head "$FAILED_HEAD_SHA" --repair-ci-failed-at "$FAILED_CHECK_COMPLETED_AT" \
  --repair-ci-failing-path "$FAILING_TEST_FILE" --repair-ci-command "$EXACT_FAILED_COMMAND"
```

For one failing unit from an aggregate shard, omit `--repair-ci-full-check`; the
receipt says `focused-passed`, never that the shard passed. Add
`--repair-ci-full-check` and remove `--repair-ci-failing-path` only after
running the entire failed check command.
For a stale, diff-unrelated unit, add `--repair-ci-stale-on-main`; the writer
requires the exact command to pass on both tested HEAD and freshly fetched
`origin/main`, pins that main SHA, and verifies the test path is outside the PR
diff. `--repair-ci-reproduces-on-main` requires failure on both tested HEAD
and fresh main with the same path bound outside the diff. A command that fails
on tested HEAD but passes on main is a candidate failure; fix it.

If CI-only infrastructure prevents that command, remove
`--repair-ci-failing-path` and replace `--repair-ci-command` with
`--repair-ci-only-reason "<specific local infrastructure limitation>"`.
Run from the repaired worktree; receipt binds to its current `HEAD` and branch.

If another fix blocks your work, write this as the report's first line and
exit: `STATUS: BLOCKED-ON <commit-subject-regex|issue N|agent name>`.
Only work that is not on origin/main yet can block you. Rebase conflicts with
commits already on main are yours to resolve by intent. A check that fails in
your tree but passes on fresh origin/main is caused by your change: fix it.
When a landing-failed report lists `Findings (file:line)`, check those paths against your diff. Fix findings in your diff, rerun the check, commit, and enqueue again; do not exit `BLOCKED-ON landing-failed` for your own failures.
The night tick tracks the dependency and redispatches this brief in the same
worktree when it lands. Do not poll or idle-wait. SPINNING token threshold:
`ZF_AGENT_SPIN_THRESHOLD_SECONDS` (default 1200 seconds).

## Delivery lane (maintainer rulings 2026-09-23 / 2026-09-24: pipeline changes land directly and fast)

- **Pipeline-system changes** — anything under `engine/`, `.agents/skills/`, `docs/agents/`, `lessons/`, and the operator scripts — do NOT go through PR / CI queue / Postsubmit / release. Run focused local tests, then `node scripts/branch-delivery-preflight.mjs --mode commit` before committing. Write issue references as `issue NNNN`, never `Fixes #NNNN`. Commit on your own branch with `[skip ci]` in every subject. Add a `Plan-Package` trailer, then run `bash engine/land-direct-main.sh --enqueue`. It records the request and returns immediately; the detached unit serializes rebase, fast local preflight, and push. Exit with `STATUS: LANDING-QUEUED`; the unit updates your report to `DONE` with `LANDED <sha>`. If landing fails, it writes `BLOCKED-ON landing-failed <ticket>` and night tick resumes you in the same worktree. Never wait for the unit or CI. Never check out `main` in any worktree; never touch `$HOME/src/target-repo` or `~/.zenoforge/checkout`. Keep pipeline-only and docs-only commits separate. The pipeline runs from `~/.zenoforge/checkout`, which fast-forwards to main on its next tick — that is the deploy.
- **the product product code** (`packages/`, `apps/`, anything that ships in a production image) keeps the full flow: topic branch → PR → CI → merge → release leg → production acceptance.
- **This dev box has no container runtime.** Testcontainers integration suites and image builds cannot run here. Run unit tests and typecheck locally, then commit, push and open the PR; PR CI ("Run touched Postsubmit integration gates" and the image jobs) is where those gates run. A missing local Docker is never a reason to hold back a commit, a push or a PR, and never a `BLOCKED-ON`.
- `.github/workflows/*` other than the agent-workflow-contract file are not in the direct lane; they still need a PR.

## Follow-up and final status contract

- A hand's observation about a ticket it owns stays on that ticket: comment with evidence and acceptance; do not open a follow-up issue for that observation. File a new issue only for a distinct, independently actionable defect, with observed evidence and testable acceptance criteria. Product work gets `needs-triage`; pipeline-system work gets `pipeline-system` and `needs-triage`.
- A fix for a stuck pipeline stage stays out of band through node-auto-owner. Do not enqueue that fix behind the stage it repairs.
- End your final report with exactly one line: `STATUS: DONE`, `STATUS: FOLLOWUP(123, 456)`, `STATUS: NEEDS-DECISION`, `STATUS: FAILED`, or (after accepted pipeline enqueue) `STATUS: LANDING-QUEUED`.
- Write to `~/.zenoforge/supervisor-inbox` only for `NEEDS-DECISION`, `FAILED`, or a guard breach. `DONE` and `FOLLOWUP(...)` never write there.

## Code graph tools

GitNexus indexes TypeScript and JavaScript symbols only. Use `impact` or `context` only for confirmed TypeScript/JavaScript symbols; use `rg` and source inspection for shell functions. Missing or unknown symbols carry no impact evidence.

## Operator brief

PRE
  cat <<'PRE'

## Live checkout and resource rules

Never edit the live pipeline checkout: `~/.zenoforge/checkout` is what the pipeline executes. Read it only; work in your own worktree.
Do not run `gitnexus analyze` on any path, including temporary clones. Query the existing index with the `gitnexus` CLI and explicit `--repo`. Skip whole-repository suites when a package-scoped suite covers the change.
Keep MAX_AGENTS configurable. The default cap is 10 hand agents; existing memory and load guards still apply.
For cihost source tests, commit the candidate, then call scripts/ops/sync-cihost-candidate.sh through with-credentials.sh with exact candidate and base SHAs. Run tests in the returned candidate= path; record bytes_sent, cache, and exact tree receipt. First call sends only compressed delta; same-SHA cache hit sends zero source-payload bytes. Never send a whole-source bundle or tar for cihost source tests; dedicated GitNexus bundle flows stay separate.
Other hand agents run suites on this host at the same time. Stop only processes you started, by the PID you recorded when you started them; never kill, pkill or killall a process you found by scanning, because another agent's test tree looks like yours.
PRE
  cat "$BRIEF"
  if [ -n "$RESUME_NOTE" ]; then
    printf '\n%s\n' "$RESUME_NOTE"
  fi
} > "$rendered"
# 2026-10-08 (issue 2695, run 3): both legs inherit this process's env
# through the --scope run, so the Node env-proxy opt-in and the loopback
# bypass live here once for every hand agent session — otherwise node fetch
# inside a session ignores the proxy vars (ConnectTimeoutError) or, with the
# opt-in but no bypass, sends local test-server traffic to the proxy. The
# zcode leg's explicit -E list below keeps its own copy for the same reason.
# Mirror the inherited unit route for both legs when configured.
if [[ -n "${https_proxy:-}" ]]; then
  export https_proxy="$https_proxy" http_proxy="$https_proxy"
fi
export NODE_USE_ENV_PROXY=1
export no_proxy=127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/8 \
  NO_PROXY=127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/8
attempt_started_at="$(date +%s%N)"
PROVIDER_EPISODE="${PROVIDER_EPISODE:-$attempt_started_at}"
worker_env=()
if [[ "$HAND_NON_PRODUCT_UNIT" == 1 ]]; then
  PATH="$SCRIPT_DIR/non-product-test-shim:$PATH"
  export PATH
  worker_env=("ZF_NON_PRODUCT_UNIT=1" "ZF_PIPELINE_UNIT=$HAND_UNIT" "PATH=$PATH")
fi
codex_home_args=()
[ "$PROVIDER" != codex ] || [ -z "${CODEX_HOME:-}" ] || codex_home_args=(-E "CODEX_HOME=$CODEX_HOME")
# 2026-10-10: eleven agents held WSL (12 cores) at load 35-50 and every post-land verification batch ran past
# its 1800 s budget, so landed commits went unverified. Agents are batch work: weight 20 against the default
# 100 lets verification, the pipeline services and supervisor sessions run first; idle CPU still goes to agents.
HAND_CPU_WEIGHT="${AGENT_HAND_CPU_WEIGHT:-20}"
HAND_CPU_ARGS=(-p "CPUWeight=$HAND_CPU_WEIGHT" -p "IOWeight=$HAND_CPU_WEIGHT")
# Run the agent in its own transient scope. setsid alone leaves it in the
# caller's cgroup, so a one-shot launcher can kill the agent when it exits.
if [ "$PROVIDER" = codex ]; then
  ZF_LAND_MAIN_LOCK_WAIT_FLOOR_SECONDS=1800 ZF_REPO_DIR="$WT" REPO_DIR="$WT" systemd-run --user --scope --quiet --collect "${HAND_CPU_ARGS[@]}" \
    -E "AGENT_HOME=$AGENT_HOME" -E "ZF_AGENT_NAME=$NAME" -E "ZF_AGENT_REPORT=$REPORT" \
    -E "ZF_HAND_PROVIDER_RETRY=$PROVIDER_RETRY" \
    "${codex_home_args[@]}" \
    --unit="$HAND_UNIT" -- setsid nohup env "${worker_env[@]}" bash -c '
      set -euo pipefail
      script_dir="$1"; worktree="$2"; model="$3"; effort="$4"; service_tier="$5"; prompt="$6"; log="$7"; role="$8"; name="$9"; budget_id="${10}"
      source "$script_dir/lib.sh"
      codex_budget_adopt "$budget_id" "$$" || { echo "hand dispatch: Codex budget reservation $budget_id could not be adopted; agent not started" >&2; exit 75; }
      service_tier_args=()
      [ -z "$service_tier" ] || service_tier_args=(-c "service_tier=\"$service_tier\"")
      started="$(date +%s)"
      status=0
      codex exec --json --cd "$worktree" -m "$model" \
        -c "model_reasoning_effort=\"$effort\"" "${service_tier_args[@]}" \
        -s danger-full-access \
        -c sandbox_workspace_write.network_access=true \
        -c mcp_servers.gitnexus.enabled=false \
        - < "$prompt" || status=$?
      tokens="$(codex_tokens_used "$log" 2>/dev/null || true)"
      if [[ "$tokens" =~ ^[0-9]+$ ]]; then
        record_premium_spend "$role" "codex:$model:$effort" "hand:$name" "" "$started" "$tokens" || true
      fi
      codex_session_failure "$log" "$status" "hand:$name" "$model" || true
      codex_budget_release "$budget_id" || true
      exit "$status"
    ' _ "$SCRIPT_DIR" "$WT" "$MODEL" "$EFFORT" "$SERVICE_TIER" "$rendered" "$LOG" "$ROLE" "$NAME" "$HAND_BUDGET_ID" \
    > "$LOG" 2>&1 &
  launcher_pid=$!
else
  zcode_rollout_dir="$HOME/.zcode/cli/rollout"
  zcode_rollouts_before="$(find "$zcode_rollout_dir" -maxdepth 1 -type f -name 'model-io-*.jsonl' -printf '%f\n' 2>/dev/null || true)"
  zcode_prompt="$(cat "$rendered")"
  ZF_LAND_MAIN_LOCK_WAIT_FLOOR_SECONDS=1800 ZF_REPO_DIR="$WT" REPO_DIR="$WT" systemd-run --user --scope --quiet --collect "${HAND_CPU_ARGS[@]}" \
    -E "AGENT_HOME=$AGENT_HOME" -E "ZF_AGENT_NAME=$NAME" -E "ZF_AGENT_REPORT=$REPORT" \
    -E "NODE_USE_ENV_PROXY=1" \
    -E "https_proxy=http://127.0.0.1:3128" -E "HTTPS_PROXY=http://127.0.0.1:3128" \
    -E "http_proxy=http://127.0.0.1:3128" -E "HTTP_PROXY=http://127.0.0.1:3128" \
    --unit="$HAND_UNIT" -- setsid nohup env "${worker_env[@]}" zcode -p "$zcode_prompt" --cwd "$WT" --mode yolo \
    > "$LOG" 2>&1 &
  launcher_pid=$!
fi
sleep 2
if [ "$PROVIDER" = codex ]; then
  # 2026-10-11: one check 2 s after launch failed every hand from 12:55Z under load: sourcing lib.sh
  # outlasted it, the EXIT trap released the budget reservation, and the late child exited 75 on
  # adopt with an empty log. Wait while the launcher lives; a dead launcher has said why in $LOG.
  for _ in $(seq 1 "${ZF_CODEX_PID_WAIT_SECONDS:-120}"); do
    pid="$(hand_agent_worktree_pid "$WT" || true)"
    [ -n "$pid" ] && break
    kill -0 "$launcher_pid" 2>/dev/null || break
    sleep 1
  done
else
  # 2026-10-07: zcode-cli rewrites its argv to "zcode-cli", so an argv match missed a
  # running agent that had already done so and left it off the roster. The agent's
  # environment carries ZF_AGENT_NAME (hand_zcode_agents); poll while the CLI starts.
  for _ in $(seq 1 "${ZF_ZCODE_PID_WAIT_SECONDS:-20}"); do
    # Match the command itself, not an admission guardian's embedded child argv.
    pid="$(ps -ww -eo pid=,args= | awk -v worktree="$WT" '$2 ~ /(^|\/)zcode[^\/]*$/ && $3 == "-p" && index($0, "--cwd " worktree) > 0 {print $1; exit}')"
    if [ -z "$pid" ]; then
      while read -r candidate_pid; do
        [ -n "$candidate_pid" ] || continue
        # Filter CLI identity before environment/name deduplication can hide its child.
        if tr '\0' '\n' < "/proc/$candidate_pid/environ" 2>/dev/null | awk -v worktree="$WT" -v name="$NAME" '
          $0 == "ZF_REPO_DIR=" worktree { under = 1 }
          $0 == "ZF_AGENT_NAME=" name { agent = 1 }
          END { exit !(under && agent) }'; then
          pid="$candidate_pid"
          break
        fi
      done < <(ps -ww -eo pid=,args= | awk '$2 ~ /(^|\/)zcode(-cli)?$/ || ($2 ~ /(^|\/)node$/ && $3 ~ /(^|\/)zcode(\/|[^\/]*$)/) { print $1 }')
    fi
    [ -n "$pid" ] && break
    sleep 1
  done
fi
if [ -z "$pid" ]; then
  # Admission can refuse before a CLI exists. Reap only a finished launcher;
  # waiting on a live launcher here would wait for the model, not registration.
  launcher_status=0
  if ! kill -0 "$launcher_pid" 2>/dev/null; then
    if wait "$launcher_pid"; then launcher_status=0; else launcher_status=$?; fi
  fi
  log_detail="$(tail -n 20 "$LOG" 2>/dev/null || true)"
  provider_kind=""
  if [ "$PROVIDER" = codex ] && codex_config_parse_error "$log_detail"; then
    codex_config_detail="$(codex_config_error_detail "$log_detail")"
    record_codex_config_fault 0 hand-dispatch "$log_detail" 0 || true
    echo "dispatch failed for $NAME: env:codex-config-invalid: $codex_config_detail" >&2
    exit 1
  elif [ "$PROVIDER" = codex ] && model_call_missing_agent_binary "$log_detail" "" codex hand-dispatch; then
    record_codex_runtime_fault env:codex-binary-missing hand-dispatch 0 "$log_detail" || true
    echo "dispatch failed for $NAME: env:codex-binary-missing: $log_detail" >&2
    exit 1
  elif [ "$PROVIDER" = codex ]; then
    provider_kind="$(codex_session_error_kind "$(codex_session_error_output "$LOG")" 1 || true)"
    if [ -n "$provider_kind" ]; then
      wait "$launcher_pid" 2>/dev/null || true
      if grep -Fxq -- "worktree $WT" <<< "$HAND_WORKTREE_RECORDS"; then
        git -C "$REPO_DIR" worktree unlock "$WT" 2>/dev/null || true
      fi
      hand_provider_recover "$NAME" "$WT" "$BRIEF" "$ROLE" "$REPORT" "$ATTEMPT" \
        "RESUME: Codex exited before roster registration after provider error ($provider_kind)." \
        "$PROVIDER_RETRY" "$PROVIDER_EPISODE" "$provider_kind" "$PROVIDER_EPISODE"
      exit $?
    fi
  fi
  if [ "$launcher_status" -eq 75 ]; then
    echo "hand dispatch: execution admission deferred before agent registration (launcher exit 75)" >&2
    exit 75
  fi
  if [ "$PROVIDER" = codex ]; then
    echo "dispatch failed for $NAME; see $LOG" >&2
  else
    echo "dispatch failed for $NAME; $PROVIDER process not found; see $LOG" >&2
  fi
  exit 1
fi
[[ "$pid" =~ ^[1-9][0-9]*$ ]] || { echo "dispatch failed for $NAME; invalid agent PID" >&2; exit 1; }
start_ticks="$(hand_agent_process_start_ticks "$pid" 2>/dev/null || true)"
if ! [[ "$start_ticks" =~ ^[0-9]+$ ]]; then
  kill "$pid" 2>/dev/null || true
  echo "could not record start identity for hand agent $NAME pid=$pid; refusing dispatch" >&2
  exit 1
fi
owner_tmp="$NIGHT/.hand-owner-tmp-$pid"
branch="$(git -C "$WT" branch --show-current 2>/dev/null || true)"
# Preserve queue class after the row is consumed so crash recovery restores it.
printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$WT" "$rendered" "$branch" "$REPORT" "$attempt_started_at" "$enqueue_priority" "$TIER" > "$owner_tmp"
mv -- "$owner_tmp" "$NIGHT/.hand-owner-$pid"
if ! printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$pid" "$NAME" "$MODEL" "$EFFORT" "$WT" "$BRIEF" "$REPORT" "$LOG" "$ATTEMPT" "$attempt_started_at" "$ROLE" "$start_ticks" "$HAND_ISSUE_IDS" "$HAND_NODE_NAMES" "$PROVIDER_RETRY" "$PROVIDER_EPISODE" \
  >> "$NIGHT/agents.txt"; then
  kill "$pid" 2>/dev/null || true
  echo "failed to record hand-agent roster entry for $NAME" >&2
  exit 1
fi
# The roster row leaves agents.txt when the agent exits; this record outlives it
# so the night tick can still name the owner of a later landing failure or of
# work left uncommitted (hand-exit-handoff.sh).
if declare -F hand_registry_record >/dev/null; then
  brief_file="$(jq_arg_file "$BRIEF")" || brief_file=""
  if [[ -z "$brief_file" ]]; then
    echo "warning: could not stage hand brief for registry entry $NAME" >&2
  else
    if ! hand_registry_record "$NAME" "$(jq -cn \
      --arg name "$NAME" --argjson pid "$pid" --arg start_ticks "$start_ticks" --arg role "$ROLE" \
      --arg model "$MODEL" --arg effort "$EFFORT" --arg worktree "$WT" --rawfile brief "$brief_file" \
      --arg report "$REPORT" --arg log "$LOG" --argjson attempt "$ATTEMPT" --argjson provider_retry "$PROVIDER_RETRY" \
      --arg provider_episode "$PROVIDER_EPISODE" --arg started_at_ns "$attempt_started_at" \
      --arg tier "$TIER" --arg branch "$branch" --arg priority "$enqueue_priority" --arg owned_issues "$HAND_ISSUE_IDS" --arg owned_nodes "$HAND_NODE_NAMES" \
      '{name:$name,pid:$pid,start_ticks:$start_ticks,role:$role,priority:$priority,tier:$tier,model:$model,effort:$effort,worktree:$worktree,brief:$brief,report:$report,log:$log,attempt:$attempt,provider_retry:$provider_retry,provider_episode:$provider_episode,started_at_ns:$started_at_ns,branch:$branch,owned_issues:$owned_issues,owned_nodes:$owned_nodes,dispatched_at:now}')"; then
      echo "warning: could not record hand registry entry for $NAME" >&2
    fi
    rm -f -- "$brief_file"
  fi
fi
HAND_BUDGET_HANDED_OFF=1
watcher="not-started"
# The watcher's exit hook (worktree-lifecycle.sh watch -> lib.sh) calls gh and
# jq; the systemd user manager's own PATH (/usr/local/sbin:...:/usr/bin) has
# neither -- both live in the dispatching session's PATH (gh-shim, ~/.local/bin).
if [[ "$start_ticks" =~ ^[0-9]+$ ]] && systemd-run --user \
  --unit="zf-worktree-cleanup-$pid" --collect \
  --description="worktree cleanup for $NAME pid $pid" \
  -E "AGENT_HOME=$AGENT_HOME" -E "ZF_NIGHT_DIR=$NIGHT" \
  -E "ZF_REPO_DIR=$REPO_DIR" -E "ZF_GH_REPO=${ZF_GH_REPO:-$REPO}" \
  -E "ZF_WORKTREE_ROOT=$WORKTREE_ROOT" -E "ZF_HAND_UNIT=$HAND_UNIT.scope" \
  -E "PATH=$PATH" \
  -- bash "$WORKTREE_LIFECYCLE" watch "$REPO_DIR" "$WT" "$pid" "$start_ticks" \
  >/dev/null 2>&1; then
  watcher="zf-worktree-cleanup-$pid"
else
  echo "could not start cleanup watcher for $NAME pid=$pid; night reaper will retry" >> "$LOG"
fi
if [ "$PROVIDER" = zcode ]; then
  # ponytail: 120s first-request deadline; raise if live ZCode startup exceeds it.
  rollout_deadline=$((SECONDS + 120))
  rollout_verified=0
  while [ "$SECONDS" -lt "$rollout_deadline" ]; do
    for rollout in "$zcode_rollout_dir"/model-io-*.jsonl; do
      [ -f "$rollout" ] || continue
      rollout_name="${rollout##*/}"
      if grep -Fxq -- "$rollout_name" <<< "$zcode_rollouts_before"; then continue; fi
      rollout_identity="$(jq -r --arg report "$REPORT" '
        select(.type == "model_io")
        | select(any(.request.messages[]?; tostring | contains($report)))
        | [.request.body.model // "", .request.body.output_config.effort // ""]
        | @tsv
      ' "$rollout" 2>/dev/null | sed -n '1p' || true)"
      [ -n "$rollout_identity" ] || continue
      IFS=$'\t' read -r rollout_model rollout_effort <<< "$rollout_identity"
      if [ "$rollout_model" != "$MODEL" ] || [ "$rollout_effort" != "$EFFORT" ]; then
        failure="dispatch failed for $NAME: zcode first request model/effort mismatch; expected $MODEL/$EFFORT, got $rollout_model/$rollout_effort"
        printf '%s\n' "$failure" | tee -a "$LOG" >&2
        current_start_ticks="$(hand_agent_process_start_ticks "$pid" 2>/dev/null || true)"
        [ "$current_start_ticks" != "$start_ticks" ] || kill "$pid" 2>/dev/null || true
        exit 1
      fi
      rollout_verified=1
      break 2
    done
    if ! hand_agent_pid_live "$pid" "$start_ticks"; then break; fi
    sleep 1
  done
  if [ "$rollout_verified" -ne 1 ]; then
    failure="dispatch failed for $NAME: zcode first request model/effort was not observed within 120s"
    printf '%s\n' "$failure" | tee -a "$LOG" >&2
    current_start_ticks="$(hand_agent_process_start_ticks "$pid" 2>/dev/null || true)"
    [ "$current_start_ticks" != "$start_ticks" ] || kill "$pid" 2>/dev/null || true
    exit 1
  fi
fi
echo "dispatched $NAME pid=$pid role=$ROLE model=$MODEL effort=$EFFORT watcher=$watcher log=$LOG brief=$BRIEF report=$REPORT attempt=$ATTEMPT"
