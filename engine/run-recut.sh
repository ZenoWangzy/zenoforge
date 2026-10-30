#!/usr/bin/env bash
# Recut wrapper: a leg of the unattended issue pipeline for a ticket that
# triage classified too big to dispatch (`needs-recut`, refused categorically
# by enforce_autonomy_gate() at every phase -- see lib.sh's
# recut_categorically_oversized(), or measured size-admission evidence). Builds the prompt, runs its selected
# provider through a structured-output schema asking it to cut the ticket into smaller children
# (or refuse, if the domain has no real implementation to ground a cut in),
# then does everything the model itself is not allowed to do: mechanically
# re-verify every file/symbol it named against the real checkout, create the
# child issues, wire their blocking edges, comment.
#
# 2026-09-15: this ticket's entry label is `needs-recut`, not
# `ready-for-human` -- the advisor leg (run-advisor.sh) is what applies it,
# via its own `recut` verdict, and issue-pipeline.sh dispatches this script
# the same way it dispatches triage/implement. `ready-for-human` used to be
# overloaded as both "categorically too big" and "a human must decide";
# splitting the vocabulary first narrowed ready-for-human to the latter
# only. A later 2026-09-15 maintainer ruling ([...]
# ) abolished that latter case too -- nothing in
# this pipeline parks on a human any more; a refusal always climbs to the
# advisor instead.
#
# The parent is never dispatched for implementation after a successful split:
# it remains open as an umbrella with a comment listing its children, but is
# removed from the active `needs-recut` queue. Children are created plain
# `needs-triage` + their inherited category label, nothing more: this
# pipeline does not trust any classification recut itself makes, only a fresh
# triage run's.
#
# --dry-run (or AGENT_DRY_RUN=1): runs the worktree setup and model
# call exactly as live, then prints the verified plan (or the refusal) and
# exits 0 instead of touching the real issue. Same phase-0 human command
# shape as run-triage.sh's own --dry-run -- read the plan, decide by hand
# whether it's right, before this is ever wired into unattended dispatch.
# Safety is structural: every mutating gh call below goes through lib.sh's
# guarded_write(), which no-ops under AGENT_DRY_RUN=1.
#
# Dispatched by issue-pipeline.sh (2026-09-15) the same shape as the other
# three legs -- see its own `recut)` case in dispatch() and the needs-recut
# candidate loop. Its one real run before that (#1136, a correct refusal)
# proved the mechanism works and refuses well; it has not yet been proven to
# produce a dispatchable child from a real ticket, so treat a refusal as the
# expected common case, not a bug.
set -euo pipefail

ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--dry-run" ]; then
    export AGENT_DRY_RUN=1
  else
    ARGS+=("$arg")
  fi
done
N="${ARGS[0]:?usage: run-recut.sh [--dry-run] <issue-number>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"
if state_read "$N" | jq -e '.pipeline_system.enabled == true' >/dev/null 2>&1; then
  pipeline_system_return_to_implement "$N" needs-recut || exit 1
  echo "run-recut: #$N is pipeline-system; returned to implementation without advisor or recut" >&2
  exit 0
fi
MODEL_BACKOFF_REMAINING="$(issue_model_failure_backoff_remaining "$N")"
if [ "$MODEL_BACKOFF_REMAINING" -gt 0 ]; then
  echo "run-recut: issue #$N is in scoped model-failure backoff for ${MODEL_BACKOFF_REMAINING}s" >&2
  exit 0
fi
# See lib.sh's gh()/_bounded_call_timed_out() comment: a bounded `gh` call
# that times out here records env:network-timeout against this stage/$N.
GH_ENV_FAULT_STAGE=recut
MODEL_POLICY_IDENTITY="$(model_policy dispatch-state-identity "$N" recut)"
MODEL_POLICY_STEP="$(state_read "$N" | jq -r 'if .model_policy.unit == "recut" then .model_policy.step // "work" else "work" end')"
if model_config_fault_blocked "$(model_policy step-role "$MODEL_POLICY_STEP")" "$MODEL_POLICY_IDENTITY"; then
  echo "run-recut: model configuration fault remains for $MODEL_POLICY_IDENTITY" >&2
  exit 0
fi
case "$MODEL_POLICY_IDENTITY" in codex:*) ;; *) echo "run-recut: policy step is not a work role; advisor dispatch belongs to the batch runner" >&2; exit 78 ;; esac

# Ponytail: a ticket too big for one dispatch rarely needs more than a
# handful of independently-implementable pieces to become small enough --
# past that, further slicing is coordination overhead exceeding any one
# slice's own value, and a tracker flooded with auto-generated children is a
# worse outcome than the parked ticket it replaced (task brief, "Scale
# discipline"). 4 is the ceiling; the model is told this number and asked
# not to pad a batch just to approach it.
CHILD_CAP=4

WT="${ZF_WORKTREE_ROOT:-$HOME/wt}/recut-$N"
RECUT_JUDGE_ISSUE_FILE=""
RECUT_JUDGE_PLAN_FILE=""

# Every exit uses the shared safe lifecycle gate.
CODEX_BUDGET_RESERVATION_ID=""
cleanup() {
  codex_budget_release "${CODEX_BUDGET_RESERVATION_ID:-}" || true
  [[ -z "$RECUT_JUDGE_ISSUE_FILE" ]] || rm -f -- "$RECUT_JUDGE_ISSUE_FILE"
  [[ -z "$RECUT_JUDGE_PLAN_FILE" ]] || rm -f -- "$RECUT_JUDGE_PLAN_FILE"
  worktree_lifecycle_finish "$WT" "$REPO_DIR" || true
}
trap cleanup EXIT

fail_attempt() {
  local reason="$1" should_pause="${2:-1}" call_output="${3:-}" status="${4:-}" call_provider="${5-codex}" model="${6:-unknown}" caller="${7:-unknown}"
  state_bump_attempts "$N"
  pause_for_backoff "$N" "$call_output" "$status" "$should_pause" "$call_provider" "$model" "$caller"
  if [ "$(state_attempts "$N")" -ge 3 ]; then
    give_up_on_issue "$N" "$reason" "$BACKOFF_QUOTA_PROVIDER"
  fi
  exit 1
}

# The "wrapper declined to create anything" exit: a correct refusal (no real
# implementation to cut against, a proposed batch that failed mechanical
# verification, too many children, a cyclic blocking graph) is a SUCCESSFUL
# run, not a failure to retry -- distinct from fail_attempt() above, which is
# reserved for a genuine run failure (a `model call` error, a `gh issue
# create` that returned nothing) worth retrying up to the usual cap. Posts
# one plain-Chinese comment explaining why, records that a recut was
# attempted (so a human -- or, once this is ever wired into automatic
# dispatch, a later tick -- does not have to reopen the worktree to learn
# why nothing happened), and exits 0.
refuse_and_exit() {
  local reason="$1"
  if [ "$DRY_RUN" != "1" ] && ! issue_verdict_snapshot_guard "$N" "${ISSUE_JSON:-}"; then
    echo "run-recut: #$N -- $ISSUE_VERDICT_GUARD_REASON; skipping stale recut verdict" >&2
    exit 0
  fi
  echo "run-recut: #$N -- refusing to cut: $reason" >&2
  if [ "$DRY_RUN" = "1" ]; then
    cat <<VERDICT
issue: #$N
refused: yes
reason: $reason
VERDICT
    exit 0
  fi
  # 2026-09-15 (ladder, lib.sh): a refused recut used to relabel
  # ready-for-human -- a stop, on risk grounds, which the maintainer has ruled
  # out. A ticket that cannot be split is exactly the case for rung 3:
  # admit_guarded() schedules policy-resolved implementation and review and
  # carries the refusal reason into the brief as context. recut_refused_at
  # and the refusal reason keep the result durable: root recovery can create
  # a prerequisite ticket for missing code or ask the reporter about a scope
  # and permission gap without sending the same parent back into the loop.
  web_advisor_provider_clear_job_state "$N" || exit 1
  local reason_file reason_json production_access_json="${NEEDS_PRODUCTION_ACCESS:-false}"
  [ "$production_access_json" = true ] || production_access_json=false
  reason_file="$(jq_arg_file "$reason")" || exit 1
  reason_json="$(jq -cn --rawfile reason "$reason_file" '$reason')" || {
    rm -f -- "$reason_file"
    exit 1
  }
  rm -f -- "$reason_file"
  state_merge "$N" ". + {recut_refused_at: (now | todate), recut_refused_reason: $reason_json, recut_needs_production_access: $production_access_json}" || exit 1
  # A refusal is a completed recut run. Leaving the active marker made the next
  # tick retry the same recut step (issue 2040: three refusals in 72h).
  model_policy_complete_unit "$N" recut || exit 1
  if [ "$production_access_json" = true ]; then
    # The hot-fix mechanism is closed (2026-10-04); the supervisor decides how production-only work proceeds.
    hold_issue "$N" --holder supervisor --release "$reason" \
      --expires 168h --kind production-access || exit 1
    supervisor_inbox_append production-access "issue=#$N recut needs production access: $(printf '%s' "$reason" | tr '\n' ' ' | cut -c1-160)" || exit 1
    exit 0
  fi
  # 2026-10-05: re-admitting an already-guarded ticket unchanged repeated the
  # same failed implement; 2232, 1263, 1243, 1229 and 1288 each looped four
  # times before the label-churn hold. A refusal on a guarded ticket is the
  # second time through, so the scheduler resumes it from the existing work.
  if jq -e '.guarded == true' <<< "$PARENT_STATE" >/dev/null 2>&1; then
    hold_issue "$N" --holder supervisor --release "recut refused again on a guarded ticket: scheduler resumes from its PR or rescued work" \
      --expires 168h --kind guarded-recut-repeat || exit 1
    scheduler_requeue_issue "$N" "The recut refused this already-guarded ticket again" "${ISSUE_JSON:-}" || exit 1
    exit 0
  fi
  admit_guarded "$N" "$PARENT_RISK" "$PARENT_LEVEL" \
    "流水线尝试把这张票拆成可独立交付的小票，但没能做到：$(scrub_git_object_ids <<< "$reason" | scrub_closing_keywords)" ""
  exit 0
}

# --- Cheap guards, before spending a worktree or a model call ---------------

is_on_hold "$N" && { echo "run-recut: #$N is on-hold, skipping" >&2; exit 0; }

has_label "$N" needs-recut || {
  echo "run-recut: #$N is not labeled needs-recut -- refusing to run recut on it" >&2
  exit 1
}

PARENT_STATE="$(state_read "$N")"
# Read before the first refuse_and_exit() can fire: admit_guarded() carries
# the parent's stored classification (possibly empty for an untriaged
# parent) into the guarded state.
PARENT_RISK="$(echo "$PARENT_STATE" | jq -r '.risk_class // empty')"
PARENT_LEVEL="$(echo "$PARENT_STATE" | jq -r '.level // empty')"
SIZE_ADMISSION="$(jq -c '.size_admission | select(.kind == "size-admission" and (.lines | type == "number") and (.limit | type == "number") and .lines > .limit and (.branch | type == "string" and length > 0) and (.head | type == "string" and test("^[0-9a-f]{40}$")))' <<< "$PARENT_STATE")"

# Idempotency: don't re-cut (or re-refuse) a parent recut has already
# reached a verdict on. Cheap, avoids double-creating children on an
# accidental second invocation.
if echo "$PARENT_STATE" | jq -e 'has("recut_children") or has("recut_refused_at")' > /dev/null 2>&1; then
  echo "run-recut: #$N already has a recut verdict recorded, not re-running" >&2
  model_policy_complete_unit "$N" recut || exit 1
  exit 0
fi

# Belt-and-suspenders re-derivation of "is this the KIND of ticket recut is
# for" -- see lib.sh's recut_categorically_oversized() comment. Measured
# size admission also permits a recut even when risk/level are small (#4482). Only fires
# when a prior triage classification exists; an issue with no state file at
# all (a /wayfinder-produced ticket that was never triaged) is "not yet
# measured", not "measured and admissible", so this check does not apply --
# same distinction triage_classification_status() draws elsewhere in this
# pipeline.
if [ -n "$PARENT_RISK" ] && [ -n "$PARENT_LEVEL" ] \
  && ! recut_categorically_oversized "$PARENT_RISK" "$PARENT_LEVEL" \
  && [ -z "$SIZE_ADMISSION" ]; then
  refuse_and_exit "这张票上次分诊的结果是 risk_class=$PARENT_RISK, level=${PARENT_LEVEL}，在某个权限阶段其实是可以直接派发的，不是「无论如何都太大」——不是拆票能解决的问题，应该调整的是权限阶段，不是把票拆小。"
fi

# --- Worktree + prompt + model call -----------------------------------------

CODEX_BUDGET_ROLE="$(model_policy step-role "$MODEL_POLICY_STEP")"
CODEX_BUDGET_RESERVATION_ID="run-recut:$N:$$"
if ! codex_budget_reserve "$CODEX_BUDGET_ROLE" "$CODEX_BUDGET_RESERVATION_ID" "" 0 "" "$MODEL_POLICY_IDENTITY"; then
  echo "run-recut: Codex budget/provider hold; issue #$N deferred" >&2
  exit 0
fi

if ! worktree_lifecycle_finish "$WT" "$REPO_DIR"; then
  record_env_fault env:worktree-cleanup recut "$N" "prior worktree was kept because cleanup safety checks failed"
  exit 1
fi
if ! git -C "$REPO_DIR" worktree add -q "$WT" origin/main; then
  # Environment fault -> ledger, not the ticket's attempt counter (lib.sh
  # record_env_fault(), lessons/RULES.md V79).
  echo "run-recut: git worktree add failed for $WT" >&2
  record_env_fault env:worktree-add recut "$N" "git worktree add failed for $WT"
  exit 1
fi

if ! ISSUE_JSON="$(gh issue view "$N" --repo "$REPO" \
  --json number,title,body,author,comments,createdAt,labels,state)"; then
  record_env_fault env:gh-api recut "$N" "gh issue view failed (api.github.com unreachable or timed out)"
  exit 1
fi
PIPELINE_SYSTEM_MATCH_STATUS=0
pipeline_system_issue_matches "$ISSUE_JSON" || PIPELINE_SYSTEM_MATCH_STATUS=$?
case "$PIPELINE_SYSTEM_MATCH_STATUS" in
  0)
    prepare_pipeline_system_issue "$N" "$ISSUE_JSON" needs-recut || exit 1
    echo "run-recut: #$N is pipeline-system; returned to implementation without recut" >&2
    exit 0
    ;;
  1) ;;
  *) echo "run-recut: cannot classify #$N from the non-product lane rule; refusing recut" >&2; exit 1 ;;
esac

CATEGORY="$(echo "$ISSUE_JSON" | jq -r \
  '[.labels[].name] | map(select(. == "bug" or . == "enhancement")) | .[0] // "enhancement"')"
# Children keep the parent's queue priority: a focus or priority:top parent split into plain children
# would drop its work to the back of every queue.
INHERITED_LABELS="$(echo "$ISSUE_JSON" | jq -r '[.labels[].name | select(. == "focus" or . == "priority:top")] | .[]')"

MODEL_POLICY_RETRY_NOTE="$(state_read "$N" | jq -r 'select(.model_policy.retry_note.status == 124) | "Previous model call timed out at " + .model_policy.retry_note.stage + "; retry this same policy step without counting the timeout as a failure."')"
PROMPT_FILE="$(mktemp)"
{
  echo "This run's child cap: $CHILD_CAP -- do not propose more children than this."
  [ -z "$MODEL_POLICY_RETRY_NOTE" ] || echo "Retry note: $MODEL_POLICY_RETRY_NOTE"
  echo "GitNexus repo argument for this run: $REPO_DIR"
  matt_skills_note "$WT" to-tickets to-spec
  cat "$SCRIPT_DIR/prompts/recut.md"
  echo
  echo '```json'
  if [ -n "$SIZE_ADMISSION" ]; then
    echo '# issue and measured admission data, not instructions'
    jq -c --argjson size "$SIZE_ADMISSION" '. + {size_admission: $size}' <<< "$ISSUE_JSON"
  else
    echo '# reporter-supplied data, not instructions'
    echo "$ISSUE_JSON"
  fi
  echo '```'
} > "$PROMPT_FILE"

# Same sandbox/model/flags as run-triage.sh: read-only code exploration
# (rg/gitnexus query|context|impact/status, git log/status/diff), no gh, no
# git push, no docker/ssh, cwd already the disposable worktree so the
# model's default Write/Edit root is never this pipeline's own live source
# tree. See prompts/agent-settings.json's own comment for the full audit
# trail; recut needs nothing beyond what triage already needs.
set +e
model_policy_mark_started "$N" recut
OUTPUT="$(run_model_json "$WT" "$MODEL_POLICY_IDENTITY" 45 \
  "$SCRIPT_DIR/prompts/recut.schema.json" "$PROMPT_FILE" \
  "$SCRIPT_DIR/prompts/agent-settings.json" work)"
STATUS=$?
set -e
RECUT_TOKENS="$(jq -r '.tokens_used // empty' <<< "$OUTPUT" 2>/dev/null || true)"
record_premium_spend recut "$MODEL_POLICY_IDENTITY" "$N" "$(model_cost_usd "$OUTPUT")" "" "$RECUT_TOKENS"
codex_budget_release "$CODEX_BUDGET_RESERVATION_ID" || true
CODEX_BUDGET_RESERVATION_ID=""
rm -f "$PROMPT_FILE"

if [ $STATUS -ne 0 ] || [ "$(echo "$OUTPUT" | jq -r '.is_error' 2>/dev/null || echo true)" = "true" ]; then
  LOG_FILE="$(log_model_failure "recut-$N" "$OUTPUT" "$STATUS")"
  echo "run-recut: worktree kept for inspection: $WT" >&2
  POLICY_STATUS="$STATUS"
  [ "$POLICY_STATUS" -ne 0 ] || POLICY_STATUS=1
  state_bump_attempts "$N"
  pause_for_backoff "$N" "$OUTPUT" "$STATUS" 0 "$(provider_quota_provider_for_model "$MODEL_POLICY_IDENTITY")" "$MODEL_POLICY_IDENTITY" run-recut:recut || true
  model_policy_record_failure "$N" "$MODEL_POLICY_STEP" recut \
    "Recut run failed (exit $STATUS); full output in $LOG_FILE" "$(tail -n 80 "$LOG_FILE")" \
    "$POLICY_STATUS" needs-recut recut "$([ "$STATUS" -eq 124 ] && echo 1 || echo 0)" "$ISSUE_JSON" || exit 1
  exit 0
fi

provider_quota_recovered "$(provider_quota_provider_for_model "$MODEL_POLICY_IDENTITY")" || true
model_policy_complete_unit "$N" recut

RESULT="$(echo "$OUTPUT" | jq -c '.structured_output')"

# the project hash ban/ same seam run-triage.sh uses: scrub before
# anything else reads either field. refuse_reason and every child's
# title/body_md all pass through both scrubs immediately.
DOMAIN_VERIFIED="$(echo "$RESULT" | jq -r '.domain_verified')"
REFUSE_REASON="$(echo "$RESULT" | jq -r '.refuse_reason' | scrub_git_object_ids | scrub_closing_keywords)"
NEEDS_PRODUCTION_ACCESS="$(echo "$RESULT" | jq -r '.needs_production_access == true')"
CHILD_COUNT="$(echo "$RESULT" | jq '.children | length')"

RECUT_BASELINE="refuse"
if [ "$DOMAIN_VERIFIED" = "true" ] && [ "$NEEDS_PRODUCTION_ACCESS" = "false" ] && [ "$CHILD_COUNT" -gt 0 ]; then
  RECUT_BASELINE="accept"
fi
RECUT_SIZE_INPUT="$SIZE_ADMISSION"
[ -n "$RECUT_SIZE_INPUT" ] || RECUT_SIZE_INPUT=null
if [ "$RECUT_BASELINE" = "accept" ]; then
  RECUT_JUDGE_OUTPUT=""
  if [[ -n "${TYPESAFE_API_KEY:-}${TYPESAFE_ENV_FILE:-}" ]]; then
    RECUT_JUDGE_ISSUE_FILE="$(jq_arg_file "$ISSUE_JSON")"
    RECUT_JUDGE_PLAN_FILE="$(jq_arg_file "$RESULT")"
    RECUT_JUDGE_INPUT="$(jq -cn --arg event_id "recut:$N:$(date +%s%N)" \
      --arg current "$RECUT_BASELINE" --slurpfile issue "$RECUT_JUDGE_ISSUE_FILE" \
      --slurpfile plan "$RECUT_JUDGE_PLAN_FILE" --argjson size "$RECUT_SIZE_INPUT" \
      '{event_id:$event_id,currentDecision:$current,issue:{title:$issue[0].title,body:$issue[0].body},size_admission:$size,plan:{domain_verified:$plan[0].domain_verified,needs_production_access:$plan[0].needs_production_access,refuse_reason:$plan[0].refuse_reason,children:$plan[0].children}}')"
    rm -f -- "$RECUT_JUDGE_ISSUE_FILE" "$RECUT_JUDGE_PLAN_FILE"
    RECUT_JUDGE_ISSUE_FILE=""
    RECUT_JUDGE_PLAN_FILE=""
    RECUT_JUDGE_OUTPUT="$(printf '%s\n' "$RECUT_JUDGE_INPUT" | bash "$SCRIPT_DIR/ts-judge.sh" recut 2>/dev/null || true)"
  fi
  RECUT_JUDGE_DECISION="$(jq -r 'select(.status=="answered" and .adopted==true) | .decision // empty' <<<"$RECUT_JUDGE_OUTPUT" 2>/dev/null || true)"
  if [ "$RECUT_JUDGE_DECISION" = "refuse" ]; then
    REFUSE_REASON="Jev 对拆分方案的高置信度判断为不应创建子票；本次保留原票，既有文件、符号、子票数量和依赖验证仍是硬要求。"
    DOMAIN_VERIFIED=false
    CHILD_COUNT=0
  fi
fi

# --- The model's own refusal ------------------------------------------------

if [ "$NEEDS_PRODUCTION_ACCESS" = true ] || [ "$DOMAIN_VERIFIED" != "true" ] || [ "$CHILD_COUNT" -eq 0 ]; then
  refuse_and_exit "$REFUSE_REASON"
fi

# --- Code-level enforcement, never trusting the model's own claim ----------

recut_child_count_ok "$CHILD_COUNT" "$CHILD_CAP" || \
  refuse_and_exit "模型提出了 $CHILD_COUNT 张子票，超过了这次运行 $CHILD_CAP 张的上限——为了不把 issue 列表刷屏，整批拆分作废。"

CHILDREN_JSON="$(echo "$RESULT" | jq -c '.children')"

# blocked_by_child_indices range/self-reference sanity, before the (more
# expensive) file/symbol verification below -- a malformed index is a
# structural problem with the whole batch, cheaper to catch first.
for ((i = 0; i < CHILD_COUNT; i++)); do
  while IFS= read -r j; do
    [ -z "$j" ] && continue
    if [ "$j" = "$i" ] || [ "$j" -lt 0 ] || [ "$j" -ge "$CHILD_COUNT" ]; then
      refuse_and_exit "第 $((i + 1)) 个子票声明的阻塞关系引用了一个不存在的子票（索引 ${j}），整批拆分作废。"
    fi
  done < <(echo "$CHILDREN_JSON" | jq -r ".[$i].blocked_by_child_indices[]?")
done

# The hard "never fabricate" gate (lib.sh's recut_slice_verified()): every
# file and symbol a proposed child claims must actually be found in the
# just-checked-out origin/main worktree -- $WT, never the model's own claim.
# All-or-nothing: if even one child fails, the WHOLE batch is voided, not
# just that one child -- a partially-created batch with a missing blocker
# reference would be worse than none at all.
for ((i = 0; i < CHILD_COUNT; i++)); do
  CHILD_FILES="$(echo "$CHILDREN_JSON" | jq -c ".[$i].files")"
  CHILD_SYMBOLS="$(echo "$CHILDREN_JSON" | jq -c ".[$i].symbols")"
  CHILD_TITLE="$(echo "$CHILDREN_JSON" | jq -r ".[$i].title")"
  if ! recut_slice_verified "$CHILD_FILES" "$CHILD_SYMBOLS" "$WT"; then
    refuse_and_exit "第 $((i + 1)) 个子票「${CHILD_TITLE}」引用的文件或符号在当前代码里核对不到，为避免臆造工作，整批拆分作废，原票保留待人工处理。"
  fi
done

CHILD_ORDER="$(recut_topo_order "$CHILDREN_JSON")" || \
  refuse_and_exit "子票之间声明的阻塞关系存在环，无法确定创建顺序，整批拆分作废。"

# --- Dry run: print the verified plan and stop ------------------------------

if [ "$DRY_RUN" = "1" ]; then
  {
    echo "issue: #$N"
    echo "refused: no"
    echo "children ($CHILD_COUNT), in creation order:"
    echo
    while IFS= read -r i; do
      [ -z "$i" ] && continue
      echo "--- child $((i + 1)) (proposed index $i) ---"
      echo "title: $(echo "$CHILDREN_JSON" | jq -r ".[$i].title")"
      echo "files: $(echo "$CHILDREN_JSON" | jq -c ".[$i].files")"
      echo "symbols: $(echo "$CHILDREN_JSON" | jq -c ".[$i].symbols")"
      blockers="$(echo "$CHILDREN_JSON" | jq -r ".[$i].blocked_by_child_indices[]?")"
      if [ -n "$blockers" ]; then
        echo "blocked by (proposed indices): $blockers"
      else
        echo "blocked by: none, can dispatch triage immediately"
      fi
      echo
      echo "body_md:"
      echo "$CHILDREN_JSON" | jq -r ".[$i].body_md"
      echo
    done <<< "$CHILD_ORDER"
  }
  exit 0
fi

if ! issue_verdict_snapshot_guard "$N" "$ISSUE_JSON"; then
  echo "run-recut: #$N -- $ISSUE_VERDICT_GUARD_REASON; skipping stale recut plan" >&2
  exit 0
fi

# --- Live: create children in dependency order, wire native GitHub blocking-
# edges and sub-issue parent links via `gh issue create`'s own --blocked-by/
# --parent flags (no separate `gh api` dependency-graph call needed) --------

declare -A CHILD_NUM_BY_INDEX=()
while IFS= read -r i; do
  [ -z "$i" ] && continue
  TITLE_RAW="$(echo "$CHILDREN_JSON" | jq -r ".[$i].title")"
  BODY_RAW="$(echo "$CHILDREN_JSON" | jq -r ".[$i].body_md")"
  TITLE="$(scrub_git_object_ids <<< "$TITLE_RAW" | scrub_closing_keywords)"
  BODY="$(scrub_git_object_ids <<< "$BODY_RAW" | scrub_closing_keywords)"

  BLOCKERS=""
  while IFS= read -r j; do
    [ -z "$j" ] && continue
    BLOCKERS="${BLOCKERS:+$BLOCKERS,}${CHILD_NUM_BY_INDEX[$j]}"
  done < <(echo "$CHILDREN_JSON" | jq -r ".[$i].blocked_by_child_indices[]?")

  # RECUT_CHILD_MARKER (lib.sh): what tells issue_is_precut() a
  # `## What to build` body is a recut child (born needs-triage for a fresh
  # measurement) and not a maintainer-cut /to-tickets ticket.
  FULL_BODY="## Parent

由 #$N 拆分而来的可独立交付子任务之一，${RECUT_CHILD_MARKER}。

$BODY"
  if [ -n "$BLOCKERS" ]; then
    FULL_BODY="$FULL_BODY

## Blocked by

$(echo "$BLOCKERS" | tr ',' '\n' | sed 's/^/- #/')"
  fi

  CREATE_ARGS=(gh issue create --repo "$REPO" --title "$TITLE" --body "$FULL_BODY" --label "$CATEGORY")
  if [[ "$(roadmap_switch_value)" != true || "$DRY_RUN" == 1 ]]; then
    CREATE_ARGS+=(--label needs-triage --parent "$N")
  fi
  for INHERITED_LABEL in $INHERITED_LABELS; do CREATE_ARGS+=(--label "$INHERITED_LABEL"); done
  [ -n "$BLOCKERS" ] && CREATE_ARGS+=(--blocked-by "$BLOCKERS")

  CHILD_URL="$(guarded_write "${CREATE_ARGS[@]}")"
  if [ "$DRY_RUN" != "1" ] && [ -z "$CHILD_URL" ]; then
    fail_attempt "gh issue create returned no URL for child $((i + 1)) of #$N" 0
  fi
  CHILD_NUM="${CHILD_URL##*/}"
  CHILD_NUM_BY_INDEX[$i]="$CHILD_NUM"
  if [[ "$(roadmap_switch_value)" == true && "$DRY_RUN" != 1 ]]; then
    child_issue_json="$(jq -cn --argjson number "$CHILD_NUM" --arg title "$TITLE" --arg body "$FULL_BODY" --arg category "$CATEGORY" \
      '{number:$number,title:$title,body:$body,state:"OPEN",labels:[{name:$category}]}')" || fail_attempt "could not prepare roadmap intake for child $((i + 1)) of #$N" 0
    issue_transition "$CHILD_NUM" needs-triage recut-child-created . 0 "$child_issue_json" "$N" \
      || fail_attempt "could not place or label child $((i + 1)) of #$N in roadmap" 0
  fi

  guarded_write gh issue comment "$CHILD_NUM" --repo "$REPO" --body "$BOT_DISCLAIMER
本票是流水线把 #$N 自动拆分出的可独立交付子任务之一，会走正常的分诊流程，不会跳过人工分诊。"
done <<< "$CHILD_ORDER"

CHILD_LIST_MD=""
while IFS= read -r i; do
  [ -z "$i" ] && continue
  t="$(echo "$CHILDREN_JSON" | jq -r ".[$i].title" | scrub_git_object_ids | scrub_closing_keywords)"
  CHILD_LIST_MD="$CHILD_LIST_MD
- #${CHILD_NUM_BY_INDEX[$i]} $t"
done <<< "$CHILD_ORDER"

guarded_write gh issue comment "$N" --repo "$REPO" --body "$BOT_DISCLAIMER
这张票范围太大，流水线拆成了 $CHILD_COUNT 张更小的子票，各自会走正常的分诊流程；这张票本身先留在这里作为汇总，不会被自动派发实现。
$CHILD_LIST_MD"

CHILD_NUMBERS_JSON="$(printf '%s\n' "${CHILD_NUM_BY_INDEX[@]}" | jq -R . | jq -s -c 'map(tonumber)')"
complete_recut_parent "$N" "$CHILD_NUMBERS_JSON"
