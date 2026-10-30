#!/usr/bin/env bash
# Shared helpers for engine/*.sh. Source this, do not execute it.
# ponytail: one small shared file beats the same jq/state snippet copy-pasted
# into issue-pipeline.sh, run-triage.sh, run-implement.sh, and run-release.sh.

_AGENT_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$_AGENT_LIB_DIR/closing-keywords.sh"
# Test fixtures that copy lib.sh alone (nine suites) do not carry systemd/; a real checkout always does.
[[ -r "$_AGENT_LIB_DIR/systemd/build-capacity-gate.sh" ]] && source "$_AGENT_LIB_DIR/systemd/build-capacity-gate.sh"
[[ -r "$_AGENT_LIB_DIR/ci-runner-disk-floor.sh" ]] && source "$_AGENT_LIB_DIR/ci-runner-disk-floor.sh"
[[ -r "$_AGENT_LIB_DIR/supervisor-holds.sh" ]] && source "$_AGENT_LIB_DIR/supervisor-holds.sh"
[[ -r "$_AGENT_LIB_DIR/roadmap.sh" ]] && source "$_AGENT_LIB_DIR/roadmap.sh"
[[ -r "$_AGENT_LIB_DIR/land-queue-state.sh" ]] && source "$_AGENT_LIB_DIR/land-queue-state.sh"
[[ -r "$_AGENT_LIB_DIR/hand-codex-liveness.sh" ]] && source "$_AGENT_LIB_DIR/hand-codex-liveness.sh"
[[ -r "$_AGENT_LIB_DIR/runtime-reload.sh" ]] && source "$_AGENT_LIB_DIR/runtime-reload.sh"
[[ -r "$_AGENT_LIB_DIR/matt-skills.sh" ]] && source "$_AGENT_LIB_DIR/matt-skills.sh"
source "${ZF_EXECUTION_MODULE_DIR:-$_AGENT_LIB_DIR}/execution-admission.sh"

AGENT_HOME="${AGENT_HOME:-${ZF_HOME:-$HOME/.zenoforge}}"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/write-guard.sh"
agent_pipeline_write_guard 'lib.sh initialization' "$AGENT_HOME" || return 1
# Host capacity tuning (non-secret) beats the credentials env file. On 2026-10-06 that file pinned
# AGENT_DISPATCH_LOAD_LIMIT_MULTIPLIER=2 into every with-credentials child, so an implement unit held
# the head of the FIFO preflight queue in a 45-minute load-admission wait and every landing waited behind it.
if [ -r "$AGENT_HOME/capacity.env" ]; then set -a; . "$AGENT_HOME/capacity.env"; set +a; fi
STATE_DIR="$AGENT_HOME/state"
LOG_DIR="$AGENT_HOME/logs"

# Host binaries repaired by the night timer. Keep both roots configurable here
# so timer, probes and temporary-directory tests resolve identical paths.
codex_runtime_user_bin_dir() { printf '%s\n' "${ZF_CODEX_RUNTIME_BIN_DIR:-${ZF_LOCAL_BIN_DIR:-$HOME/.local/bin}}"; }
# Opt-in: unset means no bundled-binary repair (nothing reaches into a desktop app bundle by default).
codex_runtime_bundle_dir() { printf '%s\n' "${ZF_CHATGPT_RESOURCES_DIR:-}"; }

agent_worktree_is_usable() {
  local repo="${1:-}" target="${2:-}" top repo_common worktree_common
  [ -d "$repo" ] && [ -d "$target" ] || return 1
  top="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)" || return 1
  top="$(realpath -e -- "$top" 2>/dev/null)" || return 1
  target="$(realpath -e -- "$target" 2>/dev/null)" || return 1
  [ "$top" = "$target" ] || return 1
  repo_common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  worktree_common="$(git -C "$target" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  repo_common="$(realpath -e -- "$repo_common" 2>/dev/null)" || return 1
  worktree_common="$(realpath -e -- "$worktree_common" 2>/dev/null)" || return 1
  [ "$repo_common" = "$worktree_common" ]
}

agent_latest_worktree_for_hand() {
  local repo="${1:-}" name="${2:-}" registry="${3:-}" report="${4:-}" supplied="${5:-}" allow_queued_missing="${6:-0}"
  local repo_real candidate registry_path base queue="${DQ_QUEUE:-}" queue_row_state="" queue_worktree="" queue_record parent
  local -a candidates=() report_candidates=()
  [[ "$name" =~ ^[[:alnum:]_.-]+$ && "$name" != . && "$name" != .. ]] || return 1
  repo_real="$(realpath -e -- "$repo" 2>/dev/null)" || return 1
  if [[ -r "$report" ]]; then
    mapfile -t report_candidates < <(grep -i 'worktree' -- "$report" \
      | grep -oE '~?/[[:alnum:]_./-]+' \
      | sed -E 's/[.,;:!?)]*$//' \
      | tac || true)
    for candidate in "${report_candidates[@]}"; do
      base="${candidate%/}"; base="${base##*/}"
      [[ "$base" == "$name" || "$base" == "$name"-* || "$base" == "$name"_* ]] \
        && candidates+=("$candidate")
    done
  fi
  registry_path="$(jq -r '.worktree // empty' "$registry" 2>/dev/null || true)"
  candidates+=("$registry_path")
  if [[ "$allow_queued_missing" == 1 && ! -e "$registry" && ! -L "$registry" ]]; then
    queue="${queue:-${AGENT_HOME:-$HOME/.zenoforge}/night/supervisor-dispatch-queue.tsv}"
    if [[ -r "$queue" ]]; then
      queue_record="$(awk -F '\t' -v owner="$name" '$1 == owner {
        if (NF >= 5 && $2 != "") print "valid\t" $2
        else print "invalid\t-"
        exit
      }' "$queue" 2>/dev/null || true)"
      if [[ -n "$queue_record" ]]; then
        IFS=$'\t' read -r queue_row_state queue_worktree <<< "$queue_record"
        case "$queue_worktree" in "~/"*) queue_worktree="$HOME/${queue_worktree:2}" ;; esac
        if [[ "$queue_row_state" == valid && "$queue_worktree" == /* ]]; then
          queue_worktree="$(realpath -m -- "$queue_worktree" 2>/dev/null || true)"
          base="${queue_worktree%/}"; base="${base##*/}"
          [[ "$base" == "$name" || "$base" == "$name"-* || "$base" == "$name"_* ]] || queue_row_state=invalid
        else
          queue_row_state=invalid
        fi
        [[ "$queue_row_state" == valid ]] && candidates+=("$queue_worktree")
      fi
    fi
    # A malformed or stale row is authoritative too: do not substitute an unrecorded default path.
    [[ -z "$queue_row_state" ]] && candidates+=("$supplied")
  else
    candidates+=("$supplied")
  fi
  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" ]] || continue
    case "$candidate" in "~/"*) candidate="$HOME/${candidate:2}" ;; esac
    if [[ "$allow_queued_missing" == 1 && "$queue_row_state" == valid \
      && "$candidate" == "$queue_worktree" && ! -e "$candidate" && ! -L "$candidate" ]]; then
      parent="${candidate%/*}"
      [[ -d "$parent" && "$candidate" != "$repo_real" ]] || continue
      printf '%s\n' "$candidate"
      return 0
    fi
    candidate="$(realpath -e -- "$candidate" 2>/dev/null)" || continue
    [[ "$candidate" != "$repo_real" ]] || continue
    agent_worktree_is_usable "$repo_real" "$candidate" || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

supervisor_alert_daily_budget() {
  case "$1" in
    health-check) printf '0\n' ;;
    ticket-progress) printf '20\n' ;;
    repeat-dispatch) printf '16\n' ;;
    label-churn) printf '10\n' ;;
    node-stuck-30min) printf '%s\n' -1 ;; # Uncapped; node-health already limits alerts to once per episode/30 minutes.
    # Uncapped: one line per failed landing or blocked handoff episode. 2026-10-07 >20 failures exhausted the default
    # budget and landings 236/242/243/245 failed silently while their agents had already exited.
    landing-failed|ops-acceptance-after-release|handoff-pr-ambiguous|handoff-preserved-clone) printf '%s\n' -1 ;;
    # Uncapped: one line per exited hand owner and unresolved step (hand-exit-handoff.sh ledger), never a loop.
    hand-exit-handoff) printf '%s\n' -1 ;;
    prod-anomaly) printf '%s\n' -1 ;; # Every new signature, rate spike, restart, or OOM wakes the supervisor.
    efficiency-regression) printf '%s\n' -1 ;; # The metric evaluator owns the six-hour per-metric cadence.
    efficiency-anomaly|efficiency-inbox-unread) printf '%s\n' -1 ;; # Durable per-day markers own duplicate suppression.
    *) printf '20\n' ;;
  esac
}

supervisor_inbox_append() {
  (($# == 2 || $# == 3)) || return 2
  local kind="$1" text="$2" inbox_file="${3:-$AGENT_HOME/supervisor-inbox}"
  case "$inbox_file" in
    "$AGENT_HOME/supervisor-inbox"|"$AGENT_HOME/night/efficiency-inbox") ;;
    *) return 2 ;;
  esac
  agent_pipeline_write_guard supervisor_inbox_append "$inbox_file" || return 1
  local at day suffix="" wake_suffix="" budget wake_count inbox_lock
  local issue_ids="" node="" targets='[]' alert_state="" alert_decision="wake" lock_fd duplicate=1 id
  local collapse_key="" loop_signal=0
  local event_file seen_file wake_file row policy_file
  [[ "$kind" =~ ^[[:alnum:]][[:alnum:]._:-]*$ ]] || return 2
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  [[ "$at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  day="${at%%T*}"
  budget="$(supervisor_alert_daily_budget "$kind")"
  [ -d "$AGENT_HOME/logs" ] || mkdir -p "$AGENT_HOME/logs" || return 1
  mkdir -p "${inbox_file%/*}" || return 1
  event_file="$AGENT_HOME/logs/supervisor-alerts-$day.jsonl"
  if [ "$budget" -eq 0 ]; then
    # ponytail: one append-only write per report-only candidate; add a lock if rows become multi-write.
    printf '{"at":"%s","kind":"%s","targets":[],"state":"","decision":"report-only"}\n' \
      "$at" "$kind" >> "$event_file"
    return $?
  fi
  text="$(printf '%s' "$text" | tr '\r\n\t' '   ')" || return 1
  issue_ids="$(grep -oE '(issue|tickets)=#[0-9,]+' <<< "$text" | grep -oE '[0-9]+' | LC_ALL=C sort -u | paste -sd, - || true)"
  if [ -z "$issue_ids" ]; then
    if [[ "$kind" == node-stuck-30min || "$kind" == node-signature-repeat || "$kind" == node-escalation ]]; then
      node="${text%% *}"
    elif [[ "$text" =~ (^|[[:space:]])node=([^[:space:];]+) ]]; then
      node="${BASH_REMATCH[2]}"
    elif [ "$kind" = health-check ] && [[ "$text" =~ ^(BROKEN|SLOW|STUCK)[[:space:]]+([^[:space:]]+) ]]; then
      node="${BASH_REMATCH[2]}"
    fi
  fi
  if [ -n "$issue_ids" ]; then
    targets="$(jq -cn --arg ids "$issue_ids" '$ids | split(",") | map({type:"issue",id:.})')" || return 1
  elif [ -n "$node" ]; then
    targets="$(jq -cn --arg node "$node" '[{type:"node",id:$node}]')" || return 1
  fi
  if [[ "$text" =~ (^|[[:space:]])(BROKEN|STUCK|SLOW|OK|UNKNOWN|NONE|WAITING)([[:space:]]|$) ]]; then
    alert_state="${BASH_REMATCH[2]}"
  elif [[ "$text" =~ status=([[:alnum:]_-]+) ]]; then
    alert_state="${BASH_REMATCH[1]}"
  fi
  if [[ "$kind" == repeat-dispatch && "$text" =~ (^|[[:space:]])run=([0-9]+)([[:space:]]|$) ]] &&
    (( ${BASH_REMATCH[2]} >= 4 )); then
    loop_signal=1
  fi
  seen_file="$AGENT_HOME/logs/supervisor-alert-seen-$day.tsv"
  wake_file="$AGENT_HOME/logs/supervisor-wakes.log"
  inbox_lock="$event_file.lock"
  [[ "$inbox_file" == "$AGENT_HOME/supervisor-inbox" ]] || inbox_lock="$inbox_file.lock"
  exec {lock_fd}>>"$inbox_lock" || return 1
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }

  if [[ "$kind" == node-stuck-30min || "$kind" == efficiency-regression ]]; then
    duplicate=0
  elif [[ "$kind" == ticket-progress || "$kind" == repeat-dispatch ]] && [ -n "$issue_ids" ]; then
    duplicate=1
    for id in ${issue_ids//,/ }; do
      if ! grep -Fqx -- "$kind"$'\t'"issue:$id" "$seen_file" 2>/dev/null; then duplicate=0; fi
    done
  else
    duplicate=0
    if [ "$targets" != '[]' ]; then
      # Collapse only a repeat of the target's last state: BROKEN -> OK -> BROKEN on one day wakes three times (2026-10-03).
      collapse_key="$kind"$'\t'"targets:$targets"$'\t'"state:$alert_state"
      [ "$(grep -F -- "$kind"$'\t'"targets:$targets"$'\t' "$seen_file" 2>/dev/null | tail -n 1)" = "$collapse_key" ] && duplicate=1
    else
      collapse_key="$kind"$'\t'"text:$text"
      grep -Fqx -- "$collapse_key" "$seen_file" 2>/dev/null && duplicate=1
    fi
  fi
  if [ "$loop_signal" = 1 ]; then duplicate=0; fi
  policy_file="$AGENT_HOME/night/supervisor-alert-policy.json"
  if [[ "$kind" == external-deliverable ]]; then
    alert_decision=informational
  elif [ "$duplicate" = 1 ]; then
    alert_decision=collapsed
  elif [ "$kind" != node-stuck-30min ] && [ "$kind" != efficiency-regression ] && [ "$kind" != ops-acceptance-after-release ] && [ "$kind" != handoff-pr-ambiguous ] && [ "$kind" != handoff-preserved-clone ] && [ "$loop_signal" != 1 ] && jq -e --arg day "$day" --arg kind "$kind" \
    '.date == $day and ((.demoted_classes // []) | index($kind) != null)' \
    "$policy_file" >/dev/null 2>&1; then
    alert_decision=action-rate
  else
    if [ -r "$wake_file" ]; then
      if [ "$kind" = repeat-dispatch ]; then
        # Forced loop signals wake but do not spend the ordinary class budget.
        wake_count="$(awk -F '\t' -v day="$day" '
          $1 >= day "T00:00:00Z" && $1 < day "T24:00:00Z" && $2 == "repeat-dispatch" {
            if (match($3, /run=[0-9]+/)) {
              run = substr($3, RSTART + 4, RLENGTH - 4)
              if (run + 0 >= 4) next
            }
            count++
          }
          END { print count + 0 }
        ' "$wake_file")" || { flock -u "$lock_fd"; exec {lock_fd}>&-; return 1; }
      else
        wake_count="$(awk -F '\t' -v day="$day" -v kind="$kind" \
          '$1 >= day "T00:00:00Z" && $1 < day "T24:00:00Z" && $2 == kind { count++ } END { print count + 0 }' \
          "$wake_file")" || { flock -u "$lock_fd"; exec {lock_fd}>&-; return 1; }
      fi
    else
      wake_count=0
    fi
    if (( budget >= 0 && wake_count >= budget )) && [ "$loop_signal" != 1 ]; then alert_decision=budget; fi
  fi
  row="$(jq -cn --arg at "$at" --arg kind "$kind" --argjson targets "$targets" \
    --arg state "$alert_state" --arg decision "$alert_decision" \
    '{at:$at,kind:$kind,targets:$targets,state:$state,decision:$decision}')" || {
      flock -u "$lock_fd"; exec {lock_fd}>&-; return 1;
    }
  printf '%s\n' "$row" >> "$event_file" || {
    flock -u "$lock_fd"; exec {lock_fd}>&-; return 1;
  }
  # Do not record the deduplication key before the corresponding inbox write.
  if [ "$alert_decision" = informational ]; then
    printf '%s %s %s\n' "$at" "$kind" "$text" >> "$inbox_file" || {
      flock -u "$lock_fd"; exec {lock_fd}>&-; return 1;
    }
  elif [ "$alert_decision" = wake ]; then
    if [ -n "$text" ]; then suffix=" $text"; wake_suffix=$'\t'"$text"; fi
    printf '%s %s%s\n' "$at" "$kind" "$suffix" >> "$inbox_file" || {
      flock -u "$lock_fd"; exec {lock_fd}>&-; return 1;
    }
  fi
  if [[ "$kind" == node-stuck-30min || "$kind" == efficiency-regression ]]; then
    :
  elif [[ "$kind" == ticket-progress || "$kind" == repeat-dispatch ]] && [ -n "$issue_ids" ]; then
    for id in ${issue_ids//,/ }; do printf '%s\tissue:%s\n' "$kind" "$id" >> "$seen_file" || {
      flock -u "$lock_fd"; exec {lock_fd}>&-; return 1;
    }; done
  else
    printf '%s\n' "$collapse_key" >> "$seen_file" || {
      flock -u "$lock_fd"; exec {lock_fd}>&-; return 1;
    }
  fi

  if [ "$alert_decision" != wake ]; then
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    return 0
  fi
  printf '%s\t%s%s\n' "$at" "$kind" "$wake_suffix" >> "$wake_file"
  local status=$?
  flock -u "$lock_fd"
  exec {lock_fd}>&-
  return "$status"
}

ON_HOLD_QUERY_FAILURE_COUNT=0
ON_HOLD_QUERY_FAILURE_ISSUES=""
LOCK_FILE="$AGENT_HOME/lock"
PAUSE_FILE="$AGENT_HOME/PAUSE"
# Distinct from LOCK_FILE above. LOCK_FILE serializes one tick's dispatch
# decisions; this lock serializes only the `gh pr merge` mutation across
# implementers and the merge sweeper.
MERGE_LOCK_FILE="$AGENT_HOME/merge-lock"
# The implement unit's outer deadline is separate from merge handoff. The
# sweeper checks unit liveness and can take over a green PR as soon as its
# implement unit exits.
IMPLEMENT_RUNTIME_MAX_SEC="${IMPLEMENT_RUNTIME_MAX_SEC:-$((9 * 60 * 60))}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-$((3 * 60))}"
NEEDS_INFO_QUESTION_TIMEOUT_SECONDS="${NEEDS_INFO_QUESTION_TIMEOUT_SECONDS:-$((72 * 60 * 60))}"
# A merge sweep runs about once per tick (roughly every six minutes). Three
# identical skips therefore surfaces a PR after about 18 minutes, while one
# transient tick cannot page an issue. Transport failures are excluded below.
MERGE_SWEEP_ESCALATION_THRESHOLD="${MERGE_SWEEP_ESCALATION_THRESHOLD:-3}"
# 2026-09-12: written by run-release.sh the moment a deploy fails and rolled
# back (see deploy_is_blocked() below); read by both run-release.sh itself
# and issue-pipeline.sh section (d) before ever attempting another deploy.
# The exact failed SHA remains blocked; fix-forward descendants are eligible
# for the normal release checks and do not require a marker clear.
DEPLOY_BLOCKED_FILE="$AGENT_HOME/deploy-blocked-sha"
MAIN_RED_DIR="$AGENT_HOME/main-red"
# 2026-09-17: derive the checkout root from this file's own location instead
# of a hardcoded $HOME path -- the CI runner (and any second machine) has no
# $HOME, and the old fallback made every bare `source lib.sh` there
# die on `cd "$REPO_DIR"` (PR #1355 CI, full-script regression). An explicit
# ZF_REPO_DIR still wins, so production systemd units are unaffected.
REPO_DIR="${ZF_REPO_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
# The target repository as owner/name: ZF_REPO, else derived from the checkout's origin remote. Exported for child processes. A checkout with neither stays empty (|| true: no origin remote is exit 2, which set -e would turn into a silent exit).
REPO="${ZF_REPO:-$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null | sed -E 's#^(git@[^:]+:|[a-z+]+://([^/@]+@)?[^/]+/)##; s#\.git$##' || true)}"
export ZF_REPO="$REPO"
# GNU date treats an empty -d value as today's midnight, so reject it before parsing.
agent_epoch() {
  local utc=0 timestamp="${1-}"
  if [[ "$timestamp" == -u ]]; then
    utc=1
    timestamp="${2-}"
  fi
  [[ -n "$timestamp" ]] || return 1
  if (( utc )); then date -u -d "$timestamp" +%s
  else date -d "$timestamp" +%s
  fi
}

# Model choice has one persistent source: the operator file, seeded from this
# versioned policy. Launchers pass role names; this helper owns validation,
# identity formatting, and escalation transitions.
MODEL_POLICY_DEFAULT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/model-policy.default.json"
MODEL_POLICY_FILE="$AGENT_HOME/model-policy.json"
model_policy_validate_json() {
  jq -e --slurpfile canonical "$MODEL_POLICY_DEFAULT" '
    . as $policy
    | ([ $policy.roles | to_entries[] | select(.value.fallback_identity != null)
        | . as $entry
        | if ($entry.value.fallback_identity | type) != "string"
             or (($entry.value.fallback_identity | test("^codex:[A-Za-z0-9._-]+:[A-Za-z0-9_-]+$")) | not)
          then false
          else ($entry.value.provider == "codex")
            and (($entry.value.fallback_identity | split(":")[1]) == $canonical[0].roles.work.model)
            and (($entry.value.fallback_identity | split(":")[1]) != $entry.value.model)
            and any($policy.roles[]; .provider == "codex" and .disabled != true
              and ("codex:" + .model + ":" + .effort) == $entry.value.fallback_identity)
          end
      ] | all) as $fallbacks_valid
    | .schema_version == $canonical[0].schema_version
    and $fallbacks_valid
    and (.roles.work.provider == "codex")
    and (.roles.production.provider == "codex")
    and (.roles.advisor.provider == "web-advisor-provider")
    and ([.roles[] | .model] | all(type == "string" and test("^[A-Za-z0-9._-]+$")))
    and ([.roles | to_entries[] | if (.key == "work" or .key == "review" or .key == "production") then
      (.value | (has("fallback_model") | not) and (has("fallback_identity") | not))
      elif .value.provider == "codex" then
        (if (.value | has("fallback_model")) then
          .value.fallback_model == $canonical[0].roles.work.model
         else .value.disabled == true end)
      else (.value | has("fallback_model") | not) end] | all(. == true))
    and ([.roles[] | select(.provider == "codex" or .provider == "zcode") | .effort] | all(type == "string" and length > 0 and test("^[A-Za-z0-9_-]+$")))
    and ([.roles[] | select(has("service_tier")) | .service_tier] | all(.[]; type == "string"))
    and (.forbidden | type == "array" and length > 0 and all(.[]; type == "string" and test("^[A-Za-z0-9-]+$")))
    and ((.forbidden + $canonical[0].forbidden | unique) as $forbidden
      | [.roles[] as $role | $forbidden[] as $word | (($role.model + " " + ($role.effort // "") + " " + ($role.fallback_model // "")) | ascii_downcase | contains($word | ascii_downcase))]
      | any | not)
    and (.escalation.initial_step | type == "string" and length > 0)
    and (.escalation.steps | type == "array" and length > 0 and all(.[]; (.name | type == "string" and length > 0)))
    and (.escalation as $e | ([$e.steps[].name] | unique | length) == ($e.steps | length))
    and (if has("switches") then (.switches | type == "object" and (if has("roadmap-order") then .["roadmap-order"] | type == "boolean" else true end)) else true end)
    and ([.escalation.steps[].role?] | all(. as $role | $role == null or ($role | type == "string")))
  ' >/dev/null 2>&1
}
model_policy_validate_file() {
  model_policy_validate_json < "$1"
}
# Schema v1 allowed a safe, distinct Codex fallback model instead of requiring
# the canonical work model. Keep its exact validation rules for upgrades: the
# caller will back up the v1 bytes and install the complete validated default.
model_policy_validate_v1_json() {
  jq -e '
    . as $policy
    | ([ $policy.roles | to_entries[] | select(.value.fallback_identity != null)
        | . as $entry
        | if ($entry.value.fallback_identity | type) != "string"
             or (($entry.value.fallback_identity | test("^codex:[A-Za-z0-9._-]+:[A-Za-z0-9_-]+$")) | not)
          then false
          else ($entry.value.provider == "codex")
            and (($entry.value.fallback_identity | split(":")[1]) != $entry.value.model)
            and any($policy.roles[]; .provider == "codex" and .disabled != true
              and ("codex:" + .model + ":" + .effort) == $entry.value.fallback_identity)
          end
      ] | all) as $fallbacks_valid
    | .schema_version == 1
    and $fallbacks_valid
    and (.roles.work.provider == "codex")
    and (.roles.production.provider == "codex")
    and (.roles.advisor.provider == "web-advisor-provider")
    and ([.roles[] | .model] | all(type == "string" and test("^[A-Za-z0-9._-]+$")))
    and ([.roles[] | if .provider == "codex" then
      (if has("fallback_model") then
        (.fallback_model | type == "string" and test("^[A-Za-z0-9._-]+$"))
        and .fallback_model != .model
       else true end)
      else (has("fallback_model") | not) end] | all(. == true))
    and ([.roles[] | select(.provider == "codex" or .provider == "zcode") | .effort] | all(type == "string" and length > 0 and test("^[A-Za-z0-9_-]+$")))
    and ([.roles[] | select(has("service_tier")) | .service_tier] | all(.[]; type == "string"))
    and (.forbidden | type == "array" and length > 0 and all(.[]; type == "string" and test("^[A-Za-z0-9-]+$")))
    and ([$policy.roles[] as $role | $policy.forbidden[] as $word | (($role.model + " " + ($role.effort // "") + " " + ($role.fallback_model // "")) | ascii_downcase | contains($word | ascii_downcase))]
      | any | not)
    and (.escalation.initial_step | type == "string" and length > 0)
    and (.escalation.steps | type == "array" and length > 0 and all(.[]; (.name | type == "string" and length > 0)))
    and (.escalation as $e | ([$e.steps[].name] | unique | length) == ($e.steps | length))
    and (if has("switches") then (.switches | type == "object" and (if has("roadmap-order") then .["roadmap-order"] | type == "boolean" else true end)) else true end)
    and ([.escalation.steps[].role?] | all(. as $role | $role == null or ($role | type == "string")))
  ' >/dev/null 2>&1
}
model_policy_validate_v1_file() {
  model_policy_validate_v1_json < "$1"
}
model_policy_effective_live_json() {
  jq -s '
    .[0] as $default | .[1] as $live
    | ["work", "review", "production"] as $active_codex_roles
    | ($default * $live)
    | .schema_version = $default.schema_version
    | .roles = reduce ((($default.roles // {}) + ($live.roles // {})) | keys[]) as $role
        ({}; .[$role] = (
          ($default.roles[$role] // {}) as $default_role
          | ($live.roles[$role] // {}) as $live_role
          | if ($default_role.provider // null) != null
               and ($live_role.provider // null) != null
               and $default_role.provider != $live_role.provider
            then $live_role
            else $default_role * $live_role
            end
        ))
    # Schema v2 allowed fallbacks on the three active Codex roles, while v3
    # forbids them. A schema upgrade backs up the complete live file and
    # installs the complete v3 default, so discard legacy active-role
    # fallbacks from the validation candidate before checking the remaining
    # settings. This covers both redundant and operator-selected fallbacks.
    | .roles |= with_entries(
        if (.key == "work" or .key == "review" or .key == "production")
           and ($live.schema_version // 0) < $default.schema_version
        then .value |= del(.fallback_model, .fallback_identity)
        else . end)
    # A v1 active fallback is removed above. Its custom target role is also
    # absent from the upgraded default, so omit that role from the current-
    # policy candidate only when no other retained policy reference uses it.
    # This handles fallback_model and fallback_identity alike without
    # suppressing independently configured roles.
    | (if ($live.schema_version // 0) < $default.schema_version then
        [
          $active_codex_roles[] as $source_role
          | $live.roles[$source_role] as $source
          | (
              (if ($source.fallback_identity? | type) == "string" then
                ($source.fallback_identity | split(":")) as $identity_parts
                | {provider:$identity_parts[0], model:$identity_parts[1], effort:$identity_parts[2]}
               else empty end),
              (if ($source.fallback_model? | type) == "string" then
                {provider:$source.provider, model:$source.fallback_model, effort:$source.effort}
               else empty end)
            ) as $target_identity
          | $live.roles | to_entries[]
          | . as $target
          | select($target.value.provider == $target_identity.provider
              and $target.value.model == $target_identity.model
              and $target.value.effort == $target_identity.effort)
          | select((($default.roles // {}) | has($target.key)) | not)
          | select(([$live.escalation.steps[]?.role?] | index($target.key)) == null)
          | select(([
              $live.roles | to_entries[]
              | . as $entry
              | select(($active_codex_roles | index($entry.key)) == null)
              | select(
                  $entry.value.fallback_identity == (
                    $target_identity.provider + ":" + $target_identity.model + ":" + $target_identity.effort
                  )
                  or (
                    $entry.value.provider == $target_identity.provider
                    and $entry.value.fallback_model == $target_identity.model
                    and $entry.value.effort == $target_identity.effort
                  )
                )
            ] | length) == 0)
          | $target.key
        ] | unique
      else [] end) as $discarded_fallback_target_roles
    | .roles |= with_entries(
        . as $role
        | if ($discarded_fallback_target_roles | index($role.key)) == null
          then $role else empty end)
    | .forbidden = reduce ((($live.forbidden // []) + ($default.forbidden // []))[]) as $word
        ([]; if index($word) == null then . + [$word] else . end)
  ' "$MODEL_POLICY_DEFAULT" "$1"
}
model_policy_validate_v1_upgrade_file() {
  local effective_policy
  # Validate original settings by the v1 contract, including fallbacks the
  # upgrade will discard, then validate retained settings by today's policy.
  model_policy_validate_v1_file "$1" || return 1
  effective_policy="$(model_policy_effective_live_json "$1" 2>/dev/null)" || return 1
  model_policy_validate_json <<< "$effective_policy"
}
model_policy_schema_version() {
  jq -er '
    if type != "object" then error("model policy must be an object")
    elif (has("schema_version") | not) then 0
    elif (.schema_version | type == "number" and . >= 0 and floor == .) then .schema_version
    else error("model policy schema_version must be a non-negative integer") end
  ' "$1" 2>/dev/null
}
model_policy_migrate_live() {
  local force="${1:-0}" live_version default_version effective_policy live_json migrated_json backup temporary
  default_version="$(model_policy_schema_version "$MODEL_POLICY_DEFAULT")" || {
    echo "model_policy: versioned policy has an invalid schema_version" >&2
    return 1
  }
  live_version="$(model_policy_schema_version "$MODEL_POLICY_FILE")" || {
    echo "model_policy: persistent policy has an invalid schema_version" >&2
    return 1
  }
  if (( live_version > default_version )); then
    echo "model_policy: persistent schema version $live_version is newer than supported version $default_version" >&2
    return 1
  fi

  model_policy_validate_file "$MODEL_POLICY_DEFAULT" || {
    echo "model_policy: versioned policy is invalid" >&2
    return 1
  }
  if (( live_version == 1 && live_version < default_version )); then
    model_policy_validate_v1_upgrade_file "$MODEL_POLICY_FILE" || {
      echo "model_policy: persistent policy cannot be migrated without changing its valid settings" >&2
      return 1
    }
  else
    effective_policy="$(model_policy_effective_live_json "$MODEL_POLICY_FILE" 2>/dev/null)" || {
      echo "model_policy: persistent policy cannot be migrated" >&2
      return 1
    }
    model_policy_validate_json <<< "$effective_policy" || {
      echo "model_policy: persistent policy cannot be migrated without changing its valid settings" >&2
      return 1
    }
  fi
  if (( live_version == default_version )) && [[ "$force" != 1 ]]; then
    return 0
  fi
  live_json="$(jq -S . "$MODEL_POLICY_FILE" 2>/dev/null)" || {
    echo "model_policy: persistent policy is not valid JSON" >&2
    return 1
  }
  # The live bytes are recoverable in the backup; schema upgrades and forced
  # default syncs install the complete policy so host overrides cannot drift.
  migrated_json="$(jq -S . "$MODEL_POLICY_DEFAULT")" || return 1
  [[ "$live_json" == "$migrated_json" ]] && return 0

  # HEALTH resolves model identities while inspecting hand agents. Those
  # lookups must not rewrite the persistent policy before HEALTH can report
  # whether the original file was missing or stale.
  [[ "${MODEL_POLICY_READ_ONLY:-0}" == 1 ]] && return 0

  if (( live_version < default_version )); then
    backup="$MODEL_POLICY_FILE.bak.schema-v$live_version.$(date -u +%Y%m%dT%H%M%SZ).$$"
    cp -p -- "$MODEL_POLICY_FILE" "$backup" || {
      echo "model_policy: could not preserve the pre-migration policy" >&2
      return 1
    }
  fi
  temporary="$(mktemp "$AGENT_HOME/.model-policy.json.XXXXXX")" || return 1
  if ! printf '%s\n' "$migrated_json" > "$temporary" \
    || ! chmod 600 "$temporary" \
    || ! mv -f -- "$temporary" "$MODEL_POLICY_FILE"; then
    rm -f -- "$temporary"
    echo "model_policy: could not atomically update persistent policy" >&2
    return 1
  fi
}
model_policy_identity_is_allowed() {
  jq -e --slurpfile defaults "$MODEL_POLICY_DEFAULT" --arg identity "$1" '
    ([.roles[], $defaults[0].roles[]]
      | map(if .provider == "codex" or .provider == "zcode" then
          [.provider + ":" + .model + ":" + .effort]
          + (if .fallback_model then [.provider + ":" + .fallback_model + ":" + .effort] else [] end)
        else ["web:" + .model] end)
      | flatten) as $configured
    | ($configured + [.roles[].fallback_identity?, $defaults[0].roles[].fallback_identity? | select(type == "string")])
    | index($identity) != null
  ' "$MODEL_POLICY_FILE" >/dev/null 2>&1
}
model_policy_require_role_identity() {
  local role="$1" identity="$2" expected fallback fallback_model_identity
  expected="$(model_policy identity "$role")" || return 1
  fallback="$(jq -r --arg role "$role" '.roles[$role].fallback_identity // empty' "$MODEL_POLICY_FILE")"
  fallback_model_identity="$(model_policy fallback-identity "$role" 2>/dev/null || true)"
  [ "$identity" = "$expected" ] || { [ -n "$fallback" ] && [ "$identity" = "$fallback" ]; } \
    || { [ -n "$fallback_model_identity" ] && [ "$identity" = "$fallback_model_identity" ]; } || {
    echo "model_policy: identity does not match role '$role' (expected $expected${fallback:+ or $fallback}${fallback_model_identity:+ or $fallback_model_identity})" >&2
    return 64
  }
}
# The escalation ladder runs implement/repair on the work role first and on
# the production role as its last step (model-policy.json). Codex launch
# boundaries accept either; any other role (advisor, forbidden) is refused.
model_policy_require_implementer_identity() {
  local identity="$1" role fallback fallback_model_identity
  for role in work production; do
    [ "$identity" = "$(model_policy identity "$role")" ] && return 0
    fallback="$(jq -r --arg role "$role" '.roles[$role].fallback_identity // empty' "$MODEL_POLICY_FILE" 2>/dev/null || true)"
    [ -n "$fallback" ] && [ "$identity" = "$fallback" ] && return 0
    fallback_model_identity="$(model_policy fallback-identity "$role" 2>/dev/null || true)"
    [ -n "$fallback_model_identity" ] && [ "$identity" = "$fallback_model_identity" ] && return 0
  done
  echo "model_policy: identity matches neither the work nor the production role" >&2
  return 64
}
# Stages that run on the work role (implement, review, triage, recut) also
# run on the ladder's production step (V346); other roles must match exactly.
# The review stage (maintainer ruling 2026-10-07, pipeline-node-execution-model)
# runs on the cross-provider review role when the other provider is available
# and on the implementer's own work/production identity as its documented
# same-provider fallback -- both are legitimate reviewer identities.
model_policy_require_stage_identity() {
  case "$1" in
    work) model_policy_require_implementer_identity "$2" ;;
    review)
      [ "$2" = "$(model_policy identity review 2>/dev/null || true)" ] && return 0
      model_policy_require_implementer_identity "$2"
      ;;
    *) model_policy_require_role_identity "$1" "$2" ;;
  esac
}
model_policy() {
  local action="${1:-}" arg="${2:-}" field="${3:-}" temporary override effective_policy identity fallback primary_identity
  # Checks validate legacy state through the effective view without migrating it.
  if [ "$action" = "source-check" ]; then
    model_policy_validate_file "$MODEL_POLICY_DEFAULT" || { echo "model_policy: versioned policy is invalid" >&2; return 1; }
    [ -s "$MODEL_POLICY_FILE" ] || { echo "model_policy: persistent policy is missing" >&2; return 1; }
    local default_version live_version
    default_version="$(model_policy_schema_version "$MODEL_POLICY_DEFAULT")" || {
      echo "model_policy: versioned policy has an invalid schema_version" >&2
      return 1
    }
    live_version="$(model_policy_schema_version "$MODEL_POLICY_FILE")" || {
      echo "model_policy: persistent policy has an invalid schema_version" >&2
      return 1
    }
    if (( live_version > default_version )); then
      echo "model_policy: persistent schema version $live_version is newer than supported version $default_version" >&2
      return 1
    fi
    if (( live_version == 1 && live_version < default_version )); then
      model_policy_validate_v1_upgrade_file "$MODEL_POLICY_FILE" || {
        echo "model_policy: live policy is invalid or assigns a forbidden model" >&2
        return 1
      }
    else
      effective_policy="$(model_policy_effective_live_json "$MODEL_POLICY_FILE" 2>/dev/null)" || {
        echo "model_policy: live policy is invalid or assigns a forbidden model" >&2
        return 1
      }
      model_policy_validate_json <<< "$effective_policy" || {
        echo "model_policy: live policy is invalid or assigns a forbidden model" >&2
        return 1
      }
    fi
    model_policy_scan_sources || return 1
    echo clean
    return 0
  fi
  if [ ! -s "$MODEL_POLICY_FILE" ]; then
    if [[ "${MODEL_POLICY_READ_ONLY:-0}" == 1 ]]; then
      echo "model_policy: persistent policy is missing (read-only)" >&2
      return 1
    fi
    mkdir -p "$(dirname -- "$MODEL_POLICY_FILE")" || return 1
    temporary="$MODEL_POLICY_FILE.tmp.$$"
    cp -- "$MODEL_POLICY_DEFAULT" "$temporary" && chmod 600 "$temporary" && mv -- "$temporary" "$MODEL_POLICY_FILE" || {
      rm -f -- "$temporary"
      echo "model_policy: cannot seed persistent policy" >&2
      return 1
    }
  fi
  model_policy_migrate_live || return 1
  effective_policy="$(model_policy_effective_live_json "$MODEL_POLICY_FILE" 2>/dev/null)" || {
    echo "model_policy: persistent policy is invalid or contains a forbidden model" >&2
    return 1
  }
  if ! model_policy_validate_json <<< "$effective_policy"; then
    echo "model_policy: persistent policy is invalid or contains a forbidden model" >&2
    return 1
  fi
  case "$action" in
    identity)
      jq -er --arg role "$arg" '
        .roles[$role] as $r |
        # A disabled role stays in the policy but resolves to nothing, so dispatch refuses it.
        if $r.disabled == true then error("role disabled")
        elif $r.provider == "codex" then "codex:" + $r.model + ":" + $r.effort
        elif $r.provider == "zcode" then "zcode:" + $r.model + ":" + $r.effort
        elif $r.provider == "web-advisor-provider" then "web:" + $r.model
        else error("unsupported role provider") end
      ' <<< "$effective_policy"
      ;;
    fallback-identity)
      jq -er --slurpfile defaults "$MODEL_POLICY_DEFAULT" --arg role "$arg" '
        .roles[$role] as $r |
        ($r.fallback_model // $defaults[0].roles[$role].fallback_model // empty) as $model |
        if $r.disabled == true or $r.provider != "codex" or $model == "" then error("fallback model unavailable")
        else "codex:" + $model + ":" + $r.effort end
      ' <<< "$effective_policy"
      ;;
    dispatch-identity)
      identity="$(model_policy identity "$arg")" || return $?
      primary_identity="$identity"
      if [ -n "$field" ] && [ "$field" != "$identity" ]; then
        fallback="$(jq -r --arg role "$arg" '.roles[$role].fallback_identity // empty' <<< "$effective_policy")"
        [ -n "$fallback" ] || fallback="$(model_policy fallback-identity "$arg" 2>/dev/null || true)"
        [ -n "$fallback" ] && [ "$field" = "$fallback" ] || return 64
        identity="$field"
      fi
      if [ "$identity" = "$primary_identity" ] && [[ "$identity" == codex:* ]] \
        && codex_model_capacity_held "$identity"; then
        fallback="$(jq -r --arg role "$arg" '.roles[$role].fallback_identity // empty' <<< "$effective_policy")"
        [ -n "$fallback" ] || fallback="$(model_policy fallback-identity "$arg" 2>/dev/null || true)"
        if [ -n "$fallback" ] && model_policy_identity_is_allowed "$fallback" \
          && ! codex_model_capacity_held "$fallback"; then
          identity="$fallback"
        fi
      fi
      printf '%s\n' "$identity"
      ;;
    tier)
      jq -r --arg role "$arg" '
        (if .roles[$role] != null then .roles[$role]
         else [.roles[] | select(.provider == "codex" and ("codex:" + .model + ":" + .effort) == $role)][0] // {}
         end) | .service_tier // empty
      ' <<< "$effective_policy"
      ;;
    resolve)
      [[ "$field" =~ ^AGENT_MODEL([A-Z0-9_]*)$ ]] || { echo "model_policy: invalid override name" >&2; return 64; }
      override="${!field:-}"
      if [ -n "$override" ]; then
        model_policy_require_role_identity "$arg" "$override" || return $?
        printf '%s\n' "$override"
      else
        model_policy identity "$arg"
      fi
      ;;
    step-role)
      jq -er --arg step "$arg" '.escalation.steps[] | select(.name == $step) | .role' <<< "$effective_policy"
      ;;
    transition)
      jq -er --arg step "$arg" --arg event "$field" '.escalation.steps[] | select(.name == $step) | .[$event]' <<< "$effective_policy"
      ;;
    initial-step)
      jq -er '.escalation.initial_step' <<< "$effective_policy"
      ;;
    state-identity)
      local issue="$arg" unit="${field:-implement}" step role state
      state="$(state_read "$issue")"
      if [ "$(jq -r '.model_policy.unit // (if .model_policy.step then "implement" else empty end)' <<< "$state")" != "$unit" ]; then
        step="$(model_policy initial-step)"
      else
        step="$(jq -r '.model_policy.step // empty' <<< "$state")"
        step="${step:-$(model_policy initial-step)}"
      fi
      role="$(model_policy step-role "$step")" || return 1
      model_policy identity "$role"
      ;;
    dispatch-state-identity)
      local issue="$arg" unit="${field:-implement}" step role state active_role active_identity primary fallback fallback_model_identity
      state="$(state_read "$issue")"
      if [ "$(jq -r '.model_policy.unit // (if .model_policy.step then "implement" else empty end)' <<< "$state")" != "$unit" ]; then
        step="$(model_policy initial-step)"
      else
        step="$(jq -r '.model_policy.step // empty' <<< "$state")"
        step="${step:-$(model_policy initial-step)}"
      fi
      role="$(model_policy step-role "$step")" || return 1
      primary="$(model_policy identity "$role")" || return 1
      active_role="$(jq -r '.model_policy.active.role // empty' <<< "$state")"
      active_identity="$(jq -r '.model_policy.active.identity // empty' <<< "$state")"
      fallback="$(jq -r --arg role "$role" '.roles[$role].fallback_identity // empty' <<< "$effective_policy")"
      fallback_model_identity="$(model_policy fallback-identity "$role" 2>/dev/null || true)"
      if [ "$active_role" = "$role" ] && [[ "$active_identity" == "$primary" \
        || ( -n "$fallback" && "$active_identity" == "$fallback" ) \
        || ( -n "$fallback_model_identity" && "$active_identity" == "$fallback_model_identity" ) ]]; then
        printf '%s\n' "$active_identity"
      else
        model_policy dispatch-identity "$role"
      fi
      ;;
    live)
      local forbidden_words allowed_identities pipeline_worktrees pipeline_settings policy_age
      forbidden_words="$(jq -r '.forbidden | join(",")' <<< "$effective_policy")"
      allowed_identities="$(jq -nr --argjson live "$effective_policy" --slurpfile defaults "$MODEL_POLICY_DEFAULT" '
        [$live.roles[], $defaults[0].roles[]]
          | map(select(.provider == "codex")
            | [.model + ":" + .effort]
              + (if .fallback_model then [.fallback_model + ":" + .effort] else [] end))
          | flatten | unique | join(",")
      ')"
      pipeline_worktrees="${ZF_WORKTREE_ROOT:-${HOME:?HOME is not set}/wt}/"
      pipeline_settings="$AGENT_HOME/checkout/engine/prompts/agent-settings.json"
      # A Codex run older than the live policy file was dispatched under an earlier policy; judging it
      # by today's roles turned 4 in-flight agents BROKEN for hours after a role change (2026-09-30).
      # Forbidden names still apply to it.
      policy_age=$(( $(date +%s) - $(stat -c %Y "$MODEL_POLICY_FILE") ))
      ps -ww -eo etimes=,comm=,args= | awk -v forbidden_words="$forbidden_words" \
        -v allowed_identities="$allowed_identities" -v policy_age="$policy_age" \
        -v worktrees="$pipeline_worktrees" -v settings="$pipeline_settings" '
        BEGIN {
          bad = 0
          forbidden_count = split(forbidden_words, forbidden, ",")
          allowed_count = split(allowed_identities, allowed, ",")
        }
        function basename(value) {
          sub(/^.*\//, "", value)
          return tolower(value)
        }
        # Whole-token match: a substring test flagged package paths such as
        # example-admin and turned model-policy BROKEN on ordinary runs.
        function prohibited(value, i, word) {
          value = tolower(value)
          for (i = 1; i <= forbidden_count; i++) {
            word = tolower(forbidden[i])
            if (word == "") continue
            gsub(/\./, "\\.", word)
            if (value ~ ("(^|[^a-z0-9])" word "([^a-z0-9]|$)")) return 1
          }
          return 0
        }
        function allowed_identity(model, effort, i, identity) {
          identity = tolower(model ":" effort)
          for (i = 1; i <= allowed_count; i++)
            if (identity == tolower(allowed[i])) return 1
          return 0
        }
        {
          predates_policy = ($1 + 0 > policy_age + 0)
          $1 = ""
          $0 = $0
          has_forbidden_executable = 0
          has_codex_exec = 0
          in_pipeline_worktree = 0
          uses_pipeline_settings = 0
          model = ""
          effort = ""
          process = basename($1)
          argv0 = basename($2)
          if (prohibited(process) || prohibited(argv0)) has_forbidden_executable = 1
          if ((process == "codex" || argv0 == "codex") && $3 == "exec") has_codex_exec = 1
          for (i = 1; i < NF; i++) {
            if ($i == "--settings" && index($(i + 1), settings) == 1) uses_pipeline_settings = 1
            if ($i == "--cd" && index($(i + 1), worktrees) == 1) in_pipeline_worktree = 1
            if (index($i, "--cd=") == 1 && index(substr($i, 6), worktrees) == 1) in_pipeline_worktree = 1
            if (index($i, worktrees) == 1) in_pipeline_worktree = 1
            if ($i == "-m" || $i == "--model") {
              model = tolower($(i + 1))
            }
            if ($i ~ /^--model=/) {
              model = tolower(substr($i, 9))
            }
            if (($i == "-c" || $i == "--config") && $(i + 1) ~ /^model_reasoning_effort=/) {
              effort = tolower($(i + 1))
              sub(/^model_reasoning_effort=/, "", effort)
              gsub(/^[\047\042]|[\047\042]$/, "", effort)
            }
            if ($i ~ /^model_reasoning_effort=/) {
              effort = tolower($i)
              sub(/^model_reasoning_effort=/, "", effort)
              gsub(/^[\047\042]|[\047\042]$/, "", effort)
            }
          }
          if (has_forbidden_executable && (uses_pipeline_settings || in_pipeline_worktree)) bad = 1
          if (has_codex_exec && in_pipeline_worktree && (model == "" || prohibited(model))) bad = 1
          if (has_codex_exec && in_pipeline_worktree && !predates_policy && (effort == "" || !allowed_identity(model, effort))) bad = 1
        }
        END { exit bad }
      ' || { echo forbidden; return 1; }
      echo clean
      ;;
    *)
      echo "model_policy: unsupported operation" >&2
      return 64
      ;;
  esac
}
model_policy_scan_sources() {
  local script_dir file source process_name target_text selection word model scan_detail
  local expected_id blocked_family approved_filter approved_sanitized_filter approved_policy_input expanded_approved_policy_input assertion
  local -a forbidden_words role_models forbidden_patterns role_patterns
  if [[ "${ZF_CHECK_RULINGS_POLICY_SOURCE_SCAN_VERIFIED:-0}" == 1 ]]; then return 0; fi
  script_dir="$(dirname -- "$MODEL_POLICY_DEFAULT")"
  mapfile -t forbidden_words < <(jq -r '.forbidden[]' "$MODEL_POLICY_DEFAULT")
  mapfile -t role_models < <(jq -r '.roles[].model' "$MODEL_POLICY_DEFAULT")
  for word in "${forbidden_words[@]}"; do forbidden_patterns+=( -e "$word" ); done
  for model in "${role_models[@]}"; do role_patterns+=( -e "$model" ); done
  while IFS= read -r -d '' file; do
    [[ "$file" == "$MODEL_POLICY_DEFAULT" || "$file" == *.test.* || "${file##*/}" == test-* || "$file" == *-test.* ]] && continue
    if [[ "$file" == "$script_dir/state/rulings.json" ]]; then
      # Keep each switch and argv intact. Only the one exact repository jq assertion is eligible for masking.
      source=""
      expected_id='gpt-6-luna'
      blocked_family='sol'
      approved_filter=".roles.work.provider == \"codex\" and .roles.work.model == \"$expected_id\" and .roles.work.effort == \"max\" and (.roles.work | (has(\"fallback_identity\") | not) and (has(\"fallback_model\") | not)) and .roles.review.provider == \"codex\" and .roles.review.model == \"$expected_id\" and .roles.review.effort == \"max\" and (.roles.review | (has(\"fallback_identity\") | not) and (has(\"fallback_model\") | not)) and .roles.production.provider == \"codex\" and .roles.production.model == \"$expected_id\" and .roles.production.effort == \"high\" and (.roles.production | (has(\"fallback_identity\") | not) and (has(\"fallback_model\") | not)) and (.forbidden | index(\"$blocked_family\")) != null"
      approved_sanitized_filter="$approved_filter"
      assertion=".roles.work.model == \"$expected_id\""
      approved_sanitized_filter="${approved_sanitized_filter//"$assertion"/__approved_policy_assertion__}"
      assertion=".roles.review.model == \"$expected_id\""
      approved_sanitized_filter="${approved_sanitized_filter//"$assertion"/__approved_policy_assertion__}"
      assertion=".roles.production.model == \"$expected_id\""
      approved_sanitized_filter="${approved_sanitized_filter//"$assertion"/__approved_policy_assertion__}"
      assertion="(.forbidden | index(\"$blocked_family\")) != null"
      approved_sanitized_filter="${approved_sanitized_filter//"$assertion"/__approved_policy_assertion__}"
      # This file has hundreds of switches. Extract all command strings in one jq
      # pass instead of starting multiple jq processes for every switch on each
      # HEALTH sample. Preserve the exact approved assertion exception.
      approved_policy_input='${REPO_DIR}/engine/model-policy.default.json'
      expanded_approved_policy_input="${approved_policy_input//'${REPO_DIR}'/$REPO_DIR}"
      [[ "$expanded_approved_policy_input" == "$MODEL_POLICY_DEFAULT" ]] || approved_policy_input=""
      while IFS= read -r -d '' target_text; do
        source+="$target_text"$'\n'
      done < <(jq -j --arg filter "$approved_filter" --arg input "$approved_policy_input" \
        --arg sanitized_filter "$approved_sanitized_filter" '
        def emit: if type == "string" then ., "\u0000" else empty end;
        .rulings[]? | .switches[]? as $switch
        | if $switch.kind == "command" and $switch.scope == "repository"
             and $switch.expected == "exit:0"
             and ($switch | (has("per_tick_target") | not) and (has("per_tick_scope") | not))
             and ($switch.target | type == "array" and length == 4 and all(.[]; type == "string"))
             and $switch.target[0] == "jq" and $switch.target[1] == "-e"
             and $switch.target[2] == $filter and $switch.target[3] == $input
          then [$switch.target[0], $switch.target[1], $sanitized_filter, $switch.target[3]][]
          else [$switch.target?, $switch.per_tick_target?][]
            | if type == "array" then .[]? else . end
          end
        | emit
      ' "$file")
      source="$(sed -E 's/\.claude([^[:alnum:]_]|$)/ /Ig' <<< "$source")"
      selection="$source"
    else
      source="$(sed -E 's/CLAUDE\.md//Ig; s/\.claude([^[:alnum:]_]|$)/ /Ig; s#/tmp/[[:alpha:]]+-[0-9]+# #g; /source=.*CLAUDE/d' "$file" | tr -d '\000')"
      if [[ "$file" == "$script_dir/network-traffic.py" ]]; then
        # `comm` is read-only OS process metadata here, not a model choice.
        # Split token so this scanner does not match its own exception.
        process_name=cla
        process_name+=ude
        source="$(sed -E "s/(comm[[:space:]]+in[[:space:]]*\\([^)]*)([^[:alnum:]_])${process_name}([^[:alnum:]_][^)]*\\))/\\1\\2process-name\\3/g" <<< "$source")"
      fi
      if [[ "$file" == "$script_dir/state/incident-guards.json" \
        || "$file" == "$script_dir"/fragment-text--*.txt ]]; then
        selection="$source"
      else
        selection="$(grep -Ei '(^|[^[:alnum:]_])(--[[:alnum:]_-]*model([_-]name)?([[:space:]]+|=|[[:punct:]]+[[:space:]]*[,;])|([[:alnum:]_]*_)?model([_-](name|id|provider))?[[:space:]]*[:=])' <<< "$source" || true)"
      fi
    fi
    if [[ ${#forbidden_patterns[@]} -gt 0 ]] \
      && grep -Eiwq "${forbidden_patterns[@]}" <<< "$selection"; then
      scan_detail=""
      for word in "${forbidden_words[@]}"; do
        if grep -Fiwq -- "$word" <<< "$selection"; then scan_detail="$word"; break; fi
      done
      echo "model_policy: forbidden model name '$scan_detail' appears in $file" >&2
      return 1
    fi
    if [[ ${#role_patterns[@]} -gt 0 ]] \
      && grep -Fiwq "${role_patterns[@]}" <<< "$selection"; then
      echo "model_policy: role model is hardcoded in $file" >&2
      return 1
    fi
    if grep -Eiq 'gpt-[0-9][[:alnum:]._-]*|(^|[^[:alnum:]_])(codex|web):[[:alnum:]][[:alnum:]._-]*(:[[:alnum:]_-]+)?([^[:alnum:]_]|$)' <<< "$selection"; then
      echo "model_policy: hardcoded model identity appears in $file" >&2
      return 1
    fi
  # bin/ holds the worker launchers (luna, terra, worker): the one place that names concrete models on purpose.
  done < <(find "$script_dir" -type f ! -name '*.test.*' ! -path "$script_dir/bin/*" -print0)
}
# shellcheck source=./dispatch-load-guard.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/dispatch-load-guard.sh"
model_policy_identity_allowed() {
  model_policy_identity_is_allowed "$1"
}
# Read-only policy probes set this before sourcing so library initialization
# cannot seed or migrate the host file before model_policy source-check runs.
if [[ "${MODEL_POLICY_SOURCE_CHECK_ONLY:-0}" != 1 ]]; then
  if ! model_policy identity work >/dev/null; then
    echo "lib.sh: model policy cannot resolve the work role" >&2
    return 1 2>/dev/null || exit 1
  fi
  for _model_policy_override in AGENT_MODEL ${!AGENT_MODEL_@}; do
    [ -n "${!_model_policy_override:-}" ] || continue
    model_policy_require_role_identity work "${!_model_policy_override}" || {
      echo "lib.sh: $_model_policy_override does not match the policy work role" >&2
      return 1 2>/dev/null || exit 1
    }
  done
  # Role aliases remain optional overrides, validated by the same policy helper.
  AGENT_MODEL="$(model_policy resolve work AGENT_MODEL)"
  AGENT_MODEL_RETRY="$(model_policy resolve work AGENT_MODEL_RETRY)"
  AGENT_MODEL_REVIEW="$(model_policy resolve work AGENT_MODEL_REVIEW)"
  AGENT_MODEL_ADVISOR="$(model_policy resolve work AGENT_MODEL_ADVISOR)"
  AGENT_MODEL_ADVISOR_FLOOR="$(model_policy resolve work AGENT_MODEL_ADVISOR_FLOOR)"
fi

implement_model_for_attempt() {
  local issue="${N:-}"
  if [[ "$issue" =~ ^[0-9]+$ ]]; then model_policy dispatch-state-identity "$issue"; else model_policy dispatch-identity work; fi
}

# Cross-provider review (maintainer ruling 2026-10-07, pipeline-node-execution-
# model): the independent review of a diff runs on the model provider that did
# NOT implement it -- a codex implementer is reviewed through the policy's
# zcode review role, a zcode implementer by the codex work role. When the
# other provider is unavailable (quota hold, missing runtime or provider
# config, or a live policy that predates the review role), fall back to the
# implementer's own provider and record .review_provider_fallback in the
# issue state so the bell can see it. Every identity stays policy-resolved;
# these helpers name roles, never models.
ZCODE_PROVIDER_CONFIG_FILE="$HOME/.zcode/v2/provider_config.json"
zcode_provider_config_model_matches() {
  local identity="$1" model config_model
  model="${identity#zcode:}"
  model="${model%:*}"
  [ -r "$ZCODE_PROVIDER_CONFIG_FILE" ] || return 1
  config_model="$(jq -er '.config.defaultModelSelection.modelId | strings' "$ZCODE_PROVIDER_CONFIG_FILE" 2>/dev/null || true)"
  [ -n "$config_model" ] && [ "$config_model" = "$model" ]
}
review_cross_identity_for() {
  local implement_provider="$1" cross
  cross="$(model_policy identity review 2>/dev/null || true)"
  if [ -n "$cross" ] && [ "${cross%%:*}" != "$implement_provider" ]; then
    printf '%s\n' "$cross"
    return 0
  fi
  # A zcode implementer's other provider is codex: the work role. A codex
  # implementer has no zcode reviewer left to try when the review role is
  # unresolvable or same-provider -- the caller falls back.
  if [ "$implement_provider" = zcode ]; then
    model_policy identity work 2>/dev/null && return 0
  fi
  return 1
}
review_identity_available() {
  local identity="$1"
  case "${identity%%:*}" in
    codex)
      codex_quota_exhausted && return 1
      codex_probe_ok || return 1
      command -v codex >/dev/null 2>&1
      ;;
    zcode)
      provider_quota_exhausted zcode && return 1
      command -v zcode >/dev/null 2>&1 || return 1
      zcode_provider_config_model_matches "$identity"
      ;;
    *) return 1 ;;
  esac
}
record_review_provider_fallback() {
  local issue="$1" wanted="$2" used="$3" reason="$4" wanted_json used_json reason_json reason_file
  wanted_json="$(jq -cn --arg value "$wanted" '$value')" || return 1
  used_json="$(jq -cn --arg value "$used" '$value')" || return 1
  reason_file="$(jq_arg_file "$reason")" || return 1
  reason_json="$(jq -cn --rawfile value "$reason_file" '$value')" || { rm -f "$reason_file"; return 1; }
  rm -f "$reason_file"
  state_merge "$issue" ".review_provider_fallback = {at:(now|todate),wanted:$wanted_json,used:$used_json,reason:$reason_json} | .review_provider_fallback_history = ((.review_provider_fallback_history // []) + [.review_provider_fallback]) | .review_provider_fallback_history |= .[-5:]" >/dev/null
}
review_model_for_implementer() {
  local issue="$1" implement_identity="$2" cross
  cross="$(review_cross_identity_for "${implement_identity%%:*}" || true)"
  if [ -n "$cross" ]; then
    if review_identity_available "$cross"; then
      printf '%s\n' "$cross"
      return 0
    fi
    record_review_provider_fallback "$issue" "$cross" "$implement_identity" \
      "cross-provider reviewer unavailable (quota hold, outage, or missing runtime/config); reviewing on the implementer's own provider" || true
  else
    record_review_provider_fallback "$issue" "review-role-unresolvable" "$implement_identity" \
      "cross-provider review role could not be resolved from the live policy; reviewing on the implementer's own provider" || true
  fi
  printf '%s\n' "$implement_identity"
}

# same_failure_streak <old_reason> <old_tail> <new_reason> <new_tail>
# <old_streak> -> repeat count beyond the first failure. A first failure
# returns 0; the same canonical reason+tail increments. No old reason means
# there is no prior failure to compare. Shared by implement and advisor legs.
same_failure_streak() {
  local old_reason="$1" old_tail="$2" new_reason="$3" new_tail="$4" old_streak="${5:-0}"
  if [ -n "$old_reason" ] \
    && [ "$(failure_fingerprint "$old_reason" "$old_tail")" = "$(failure_fingerprint "$new_reason" "$new_tail")" ]; then
    echo $((old_streak + 1))
  else
    echo 0
  fi
}

# Two-strike rule (maintainer ruling 2026-10-07, pipeline-node-execution-model):
# a ticket that fails the same implement step with the same normalized failure
# class twice in a row must not get a third full attempt. Scope/plan failures
# route to needs-recut, decision/ambiguity failures to the advisor;
# environmental failures (quota, CI/landing-slot timeout, provider outage)
# never count as a strike -- their refund paths requeue the ticket without
# charging an attempt, and this classifier must agree with them.
two_strike_failure_class() {
  local reason="$1" status="${2:-}"
  if [ "$status" = "124" ] || grep -Eiq 'usage limit|quota|rate limit|land-lock|landing slot|preflight[ -]?slot|slot (timeout|wait|timed out)|timed?[ -]?out|provider outage|provider transport|network[ -]?(timeout|error)|BLOCKED-ON land|env:|infrastructure retry' <<< "$reason"; then
    echo environmental
    return 0
  fi
  if grep -Eiq 'scope|blast radius|risk[ _-]?class|autonomy|oversized|too (large|big|broad)|recut|split|超出|范围|拆分' <<< "$reason"; then
    echo scope-plan
    return 0
  fi
  if grep -Eiq 'decision|ambiguit|ambiguous|unclear|clarif|confirm|needs-info|决策|明确|确认' <<< "$reason"; then
    echo decision-ambiguity
    return 0
  fi
  echo unclassified
}

# implement_two_strike_route <n> -> prints "recut" or "advisor" when the last
# two implement-unit failures in .model_policy.failures share a step and a
# normalized reason and the class routes away; prints nothing (nonzero) when
# they do not, when the class is environmental, when the ticket runs in the
# pipeline-system lane (the model-policy loop-breaker owns those), when
# the ticket already carries its own open agent PR (#2796: that failure stays
# in the PR lane, not a fresh advisor/recut episode), or when this exact pair
# was already routed (.two_strike marker -- a human re-arming the ticket
# afterwards is a fresh decision this gate must not veto).
implement_two_strike_route() {
  local n="$1" state pair step normalized second_reason second_status open_pr_status=0
  state="$(state_read "$n" 2>/dev/null)" || return 1
  [ "$(jq -r '.pipeline_system.enabled // false' <<< "$state" 2>/dev/null)" = true ] && return 1
  # issue_own_open_agent_pr: 0 owns an open PR, 1 none, 2 GitHub unreadable.
  # Only 1 may route away; 0 keeps the PR-lane recovery, and 2 keeps the
  # current path (the advisor route is the harm this gate must not risk).
  issue_own_open_agent_pr "$n" || open_pr_status=$?
  [ "$open_pr_status" -eq 1 ] || return 1
  pair="$(jq -c '
    [.model_policy.failures[]? | select(.unit == "implement")] as $f
    | [$f[-2], $f[-1]]
    | select(.[0] != null and .[1] != null)
    | select((.[0].step // "") != "" and (.[0].step // "") == (.[1].step // ""))
    | select(((.[0].normalized_reason // .[0].reason // "") != "") and ((.[0].normalized_reason // .[0].reason) == (.[1].normalized_reason // .[1].reason)))
    | {step: .[0].step, normalized_reason: (.[0].normalized_reason // .[0].reason)}
  ' <<< "$state" 2>/dev/null || true)"
  [ -n "$pair" ] || return 1
  step="$(jq -r '.step' <<< "$pair")"
  normalized="$(jq -r '.normalized_reason' <<< "$pair")"
  if [ "$(jq -r --arg step "$step" --arg reason "$normalized" \
    '(.two_strike.step // "") == $step and (.two_strike.normalized_reason // "") == $reason' <<< "$state")" = true ]; then
    return 1
  fi
  second_reason="$(jq -r '[.model_policy.failures[]? | select(.unit == "implement")][-1].reason // ""' <<< "$state")"
  second_status="$(jq -r '[.model_policy.failures[]? | select(.unit == "implement")][-1].status // ""' <<< "$state")"
  case "$(two_strike_failure_class "$second_reason" "$second_status")" in
    environmental) return 1 ;;
    scope-plan) printf 'recut\n' ;;
    *) printf 'advisor\n' ;;
  esac
  return 0
}

# enforce_implement_two_strike <n> -> 0 when the ticket was routed away from
# another full implement attempt (the caller must not dispatch it), nonzero
# when the ordinary dispatch path continues. Routes first, then records the
# idempotency marker and posts the one comment naming both failures -- a route
# that fails leaves no marker, so the next tick retries the routing instead of
# silently dispatching a third attempt.
enforce_implement_two_strike() {
  local n="$1" route first_reason second_reason class state marker comment_body
  route="$(implement_two_strike_route "$n" 2>/dev/null)" || return 1
  [ -n "$route" ] || return 1
  state="$(state_read "$n")" || return 1
  mapfile -t reasons < <(jq -r '([.model_policy.failures[]? | select(.unit == "implement")][-2:][] | .reason // "")' <<< "$state")
  first_reason="${reasons[0]:0:1200}"
  second_reason="${reasons[1]:0:1200}"
  class="$(two_strike_failure_class "$second_reason" "")"
  if [ "$route" = recut ]; then
    route_to_recut "$n" || return 1
  else
    route_to_advisor "$n" || return 1
  fi
  marker="$(jq -cn \
    --arg route "$route" \
    --arg step "$(jq -r '([.model_policy.failures[]? | select(.unit == "implement")][-2].step // ""' <<< "$state")" \
    --arg reason "$(jq -r '([.model_policy.failures[]? | select(.unit == "implement")][-2].normalized_reason // .reason // ""' <<< "$state")" \
    '{routed_at:(now|todate),route:$route,step:$step,normalized_reason:$reason}' 2>/dev/null || true)"
  if [ -n "$marker" ]; then
    state_merge "$n" ".two_strike = $marker" >/dev/null 2>&1 || true
  fi
  comment_body="$BOT_DISCLAIMER
Two-strike rule (ruling pipeline-node-execution-model): the same implement step failed twice in a row with the same normalized failure class, so no third full attempt is dispatched. Class: ${class}; route: needs-${route}.
Failure 1: ${first_reason}
Failure 2: ${second_reason}"
  guarded_issue_comment "$n" "$comment_body" || echo "two-strike: could not post the two-failure comment for #$n" >&2
  record_run_decision "$n" model-policy "Two identical implement failures at the same step (class ${class}); routed to needs-${route} instead of a third full attempt" 1 || true
  printf 'implement-two-strike issue=#%s class=%s route=%s\n' "$n" "$class" "$route" >&2
  return 0
}

# 2026-09-12: the bot has no GitHub account of its own — every comment posts
# as the maintainer's own authenticated account (see README's "Bot
# account" note). BOT_COMMENT_MARKER is an HTML comment (invisible when
# rendered) appended to every bot comment so issue-pipeline.sh's needs-info
# bounce-back can tell "the bot posted this" from "a human posted this" by
# comment CONTENT, not by comparing the commenter's login to the bot's login
# — those logins are the same account, so a login comparison can never tell
# the maintainer's own genuine reply-as-reporter apart from the bot's own
# comment, and silently never fires on the maintainer's own issues.
BOT_COMMENT_MARKER='<!-- zenoforge-agent-comment -->'
# Sandbox mode for every pipeline codex call. Maintainer, 2026-10-06: [...]. The sandbox
# also made every run depend on bubblewrap, which vanished with the 2026-10-05 codex reinstall and
# blocked implement for an hour. The implement call still strips GH_TOKEN, and the wrapper pushes.
CODEX_SANDBOX_MODE="${ZF_CODEX_SANDBOX:-danger-full-access}"
CHECKS_BLOCKED_MAX_AGE_SECONDS=21600
BOT_DISCLAIMER='> *This was generated by AI during triage.* This comment is posted by the automated the product agent pipeline under the maintainer'"'"'s GitHub account — it is not the maintainer writing personally. '"$BOT_COMMENT_MARKER"

# Defect 6, 2026-09-13 (#1094): issue-pipeline.sh's read_needs_info_email_replies()
# relays a reporter's EMAIL reply onto the issue as a comment (see notify.sh).
# That comment gets its own disclaimer-plus-marker, deliberately NOT
# BOT_DISCLAIMER/BOT_COMMENT_MARKER: comment_is_bot() (above) treats
# anything starting with BOT_DISCLAIMER as the pipeline's own comment, and
# this relayed comment is exactly the human answer the needs-info ->
# needs-triage resume (section (a), unmodified) is watching for -- reusing
# the same marker would make it invisible to that check and leave the
# issue stuck on needs-info forever, the identical failure mode
# BOT_COMMENT_MARKER's own comment above describes for quote-replies.
EMAIL_COMMENT_MARKER='<!-- zenoforge-agent-email-relay -->'

# Shared wording for notify_email()'s "对用户有什么影响" section (see
# notify.sh's build_report_body): every "needs a human" email lands here for
# the identical reason -- nothing has shipped yet -- so this is one string,
# not eleven near-identical ones drifting apart across four files.
NOTIFY_IMPACT_BLOCKED="问题还在，用户暂时看不到变化。"

# 2026-09-12 review, item 3: issue-pipeline.sh section (a) used to test "does
# the comment CONTAIN BOT_COMMENT_MARKER anywhere" to decide whether a
# needs-info issue has been answered. GitHub's "Quote reply" copies the
# ENTIRE quoted comment — marker included — into the reporter's own new
# comment body, so a reporter's genuine answer that quote-replies to a bot
# comment carried the marker too and was misread as another bot comment,
# leaving the issue stuck on needs-info forever with nobody told.
#
# Test whether the comment STARTS WITH $BOT_DISCLAIMER instead: every bot
# comment in this pipeline puts the disclaimer as the very first thing in
# the body (see every `guarded_write gh issue comment` call site), and
# GitHub's quote-reply prefixes each quoted line with "> " before appending
# the replier's own text below it — so a quote-reply's body starts with
# "> <quoted first line>", not with the bare disclaimer text, and is
# correctly read as human-authored. This is string-slice comparison, not
# `[[ "$body" == "$BOT_DISCLAIMER"* ]]` glob matching: BOT_DISCLAIMER's own
# markdown contains literal `*` and `` ` `` characters that `[[ == ]]` would
# interpret as wildcards, silently widening the match instead of testing the
# literal text.
#
# Author login is deliberately NOT checked, even though it would be cheap to
# pull from the same `gh issue view --json comments` call already made: the
# bot has no GitHub account of its own (see BOT_COMMENT_MARKER's comment
# above), so every bot comment and every genuine reply from the maintainer
# himself carry the IDENTICAL login. A login comparison has no power to
# distinguish them here, so it would just be dead code.
comment_is_bot() {
  local body="$1"
  [ "${body:0:${#BOT_DISCLAIMER}}" = "$BOT_DISCLAIMER" ]
}

# Either switch set to 1 means dry, and neither silently overrides the other. lib.sh used to assign
# DRY_RUN from AGENT_DRY_RUN alone, so `DRY_RUN=1 run-release.sh N` ran a real production release
# (several times on 2026-10-22). AGENT_DRY_RUN is exported so children that read only it agree.
if [ "${AGENT_DRY_RUN:-0}" = 1 ] || [ "${DRY_RUN:-0}" = 1 ]; then
  DRY_RUN=1
  export AGENT_DRY_RUN=1
else
  DRY_RUN=0
fi

# The full triage state-label vocabulary, shared so run-triage.sh's active
# lifecycle-label invariant and give_up_on_issue()'s cleanup below can never
# drift apart. A successful recut parent is intentionally unlabeled: its
# recut_children record makes it an open umbrella, not active pipeline work.
# needs-triage is not a valid model output (see triage.schema.json)
# but is the real starting label on every issue that reaches triage, so it
# still has to be in the removal set.
# needs-advisor (2026-09-15): the advisor leg's own entry label -- an issue
# enforce_autonomy_gate() refuses lands here now instead of going straight to
# ready-for-human, so run-advisor.sh (the configured advisor pass) gets first
# look. needs-recut: run-recut.sh's entry label, same day -- previously
# ready-for-human was overloaded as both "categorically too big, needs
# splitting" and "a human must decide"; splitting the vocabulary means
# ready-for-human now means only the latter, the one state this pipeline
# never automates past.
# `awaiting-release` is the open state after a successful merge; `released`
# survives alongside `concluded` on a proven production close so GitHub shows
# both terminal outcome and deploy position. Every transition out of either
# still strips both, including reopen recovery.
ALL_STATE_LABELS=(needs-triage needs-info ready-for-agent ready-for-human needs-owner checks-blocked duplicate finish-first wontfix needs-advisor needs-recut awaiting-release awaiting-pipeline-sync awaiting-pipeline-health released concluded)

# 2026-09-15 00:14:51 PDT, zf-triage-1203.service: the two labels above
# were added to ALL_STATE_LABELS by the advisor-leg commit, so EVERY triage
# run's final `gh issue edit` started passing `--remove-label needs-advisor
# --remove-label needs-recut` -- and gh resolves every named label before
# applying any, so on a repo where those labels did not exist yet the whole
# edit failed ("'needs-advisor' not found"), `set -e` killed the run before
# state_merge, and the issue was left with TWO state labels (the add half
# had already applied). The only self-heal lived in run-advisor.sh, which
# cannot run until a triage run has first applied needs-advisor -- a
# chicken-and-egg that guaranteed the first triage after that commit died.
# Shared here so every leg that edits state labels (triage, advisor, the
# scheduler) heals them before its first label edit. `|| true` on each:
# "already exists" is the common case, and DRY_RUN short-circuits
# guarded_write to a 0 that never called gh.
# Covers the WHOLE array, not the two labels that happened to be new
# tonight: the strip loop's dependency is on every name in ALL_STATE_LABELS
# existing, so any future addition would fail the same way. One `gh label
# list` read, then a create only for what is missing -- fails loud (a
# created label is visible on the repo) rather than silently tolerating a
# missing one at removal time.
ensure_state_labels() {
  local existing name
  existing="$(gh label list --repo "$REPO" --limit 200 --json name -q '.[].name' 2>/dev/null)" || existing=""
  for name in "${ALL_STATE_LABELS[@]}"; do
    grep -qx -- "$name" <<< "$existing" && continue
    guarded_write gh label create "$name" --repo "$REPO" --color ededed \
      --description "the product issue pipeline state label" >/dev/null 2>&1 || true
  done
}

# 2026-09-12: same drift risk as ALL_STATE_LABELS, one level up — bug/
# enhancement must also stay exclusive so triage doesn't leave both on an
# issue across a re-triage.
CATEGORY_LABELS=(bug enhancement)

mkdir -p "$STATE_DIR" "$LOG_DIR"
# ADVISOR_LOCKS_DIR: declared far below (Advisor execution locking section)
# alongside the locking primitives that use it, but created here with the
# other shared AGENT_HOME directories -- try_lock_nonblocking() also
# mkdir -p's its own lock file's parent defensively, so this line is not
# load-bearing, just consistent with STATE_DIR/LOG_DIR's own "declared once,
# created once, at source time" convention.
mkdir -p "$AGENT_HOME/locks"

# Every caller (systemd, a bare shell, another wrapper) gets a known cwd, so
# a bare `node scripts/some-check.mjs` (no -C equivalent, it reads process
# cwd) behaves the same regardless of who invoked this script.
cd "$REPO_DIR"

# jq_arg_file <value> -- writes $value to a fresh temp file and prints its
# path on stdout. The caller pairs the path with jq's own --rawfile NAME
# <path> (a byte-for-byte drop-in for --arg NAME "$value": --rawfile binds
# $NAME to the identical plain scalar string --arg does, just read from
# disk instead of argv, so no filter rewrite is needed) or --slurpfile NAME
# <path> (the --argjson replacement for a JSON object/array/etc value --
# --slurpfile always binds $NAME to an ARRAY of every JSON value the file
# contains, so a filter written against it reads $NAME[0], never bare
# $NAME, since this always writes exactly one). Caller removes the file
# right after its own jq call, the same lifecycle state_merge's own
# filter_file already has (mktemp, use, rm -f) -- see this file's other
# 2026-09-15 comment on state_merge for why that shape (not a wrapper that
# hides the temp file) is the house style.
#
# 2026-09-16 (lessons/RULES.md, this same defect class as state_merge's
# 89e205846 fix, found the THIRD time in one day): state_merge's fix put
# the jq FILTER PROGRAM in a file instead of argv, but every call site that
# builds that filter by splicing a $PATCH object together first --
# `jq -n --arg b "$new_brief" --arg c "$merge_conditions" ... '{...}'` --
# still handed jq's own --arg/--argjson flags the caller's raw DATA
# (a brief_md, a decision_md, a whole ISSUE_JSON/PRIOR state object, a
# base64 MIME email) through argv, unfixed. Same failure shape either way:
# once one value crosses Linux's MAX_ARG_STRLEN (128KiB per argv element,
# independent of and much smaller than ARG_MAX), `execve` refuses to even
# start jq -- exit 126, "Argument list too long" -- and the caller's own
# `set -e` (or, worse, a bare loop-body assignment with no `if` around it
# at all, see run-advisor-batch.sh's own per-ticket assembly fix the same
# day) dies before anything is written. A fix applied to ONE function
# (state_merge) is not applied to its siblings just because they rhyme --
# this helper exists so every site with data too big to trust to argv
# routes through the SAME seam, not a fourth bespoke workaround. See
# jq-arg-safety.test.sh for the static guard that keeps a converted call
# site from regressing back to --arg/--argjson on a value this convention
# already knows is unbounded.
jq_arg_file() {
  local f
  f="$(mktemp)" || return 1
  printf '%s' "$1" > "$f"
  echo "$f"
}

state_file() { echo "$STATE_DIR/$1.json"; }

# Prints the issue's state JSON, defaulting to attempts=0 if none exists yet.
state_read() {
  local f
  f="$(state_file "$1")"
  if [ -f "$f" ]; then cat "$f"; else echo '{"attempts":0}'; fi
}

ticket_stage_is_label() {
  local candidate="$1" label
  for label in "${ALL_STATE_LABELS[@]}"; do
    [ "$candidate" = "$label" ] && return 0
  done
  return 1
}

efficiency_metrics_append_rows() {
  local rows="${1:-}" first month file lock_fd row status=0
  [ -n "$rows" ] || return 0
  first="${rows%%$'\n'*}"
  month="$(jq -r '.ts[0:7] // empty' <<< "$first" 2>/dev/null)" || return 1
  [[ "$month" =~ ^[0-9]{4}-[0-9]{2}$ ]] || return 1
  mkdir -p -- "$AGENT_HOME/metrics" || return 1
  chmod 700 -- "$AGENT_HOME/metrics" || return 1
  file="$AGENT_HOME/metrics/efficiency-$month.jsonl"
  exec {lock_fd}>>"$file.lock" || return 1
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    printf '%s\n' "$row" >> "$file" || { status=1; break; }
  done <<< "$rows"
  [ ! -f "$file" ] || chmod 600 -- "$file" || status=1
  flock -u "$lock_fd" || true
  exec {lock_fd}>&-
  return "$status"
}

efficiency_metrics_sync_issue_lifecycle() {
  local issue="$1" script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 0
  [[ -r "$script_dir/night/efficiency-regression.mjs" ]] || return 0
  node "$script_dir/night/efficiency-regression.mjs" sync-issue --home "$AGENT_HOME" --issue "$issue" >/dev/null \
    || echo "efficiency metrics: lifecycle sync failed for issue #$issue" >&2
  return 0
}

efficiency_metrics_record_implement_decision() {
  local issue="$1" tick="$2" outcome="$3" gate="$4" reason="$5" object="$6" ts boot_id retry_reason="${7:-}"
  local values_file row
  ts="$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" || return 1
  boot_id="$(cat /proc/sys/kernel/random/boot_id)" || return 1
  values_file="$(mktemp)" || return 1
  if ! printf '%s\0' "$issue" "$tick" "$outcome" "$gate" "$reason" "$object" "$ts" "$boot_id" "$retry_reason" > "$values_file"; then
    rm -f -- "$values_file"
    return 1
  fi
  row="$(jq -cn --rawfile values "$values_file" '
    ($values|split("\u0000")) as $v |
    def category($gate):
      if $gate == "capacity" then "agent_cap"
      elif $gate == "dispatch-resources" then "memory"
      elif $gate == "quarantine" then "quarantine"
      elif ($gate | test("budget|spend|quota|repeat-cap|attempt-cap")) then "budget"
      elif ($gate | test("block|parent")) then "blocked_by"
      elif ($gate | test("advisor")) then "advisor"
      elif ($gate | test("review")) then "review"
      elif ($gate | test("ci|check")) then "ci_queue"
      elif ($gate | test("land|merge|pr-file-collision")) then "land_queue"
      else "other" end;
    {schema_version:1,record_type:"event",event_type:(if $v[2] == "dispatched" then "dispatch" else "limiter" end),
     ts:$v[6],issue:($v[0]|tonumber),tick:$v[1],outcome:$v[2],gate:$v[3],reason:$v[4],
     object:$v[5],boot_id:$v[7],retry_reason:(if $v[8] == "" then null else $v[8] end),category:(if $v[2] == "dispatched" then null else category($v[3]) end),
     event_id:($v[6]+"|"+$v[0]+"|"+$v[1]+"|"+$v[3]+"|"+$v[2])}')"
  local status=$?
  rm -f -- "$values_file"
  [ "$status" -eq 0 ] || return "$status"
  efficiency_metrics_append_rows "$row"
}

ticket_stage_record() {
  (($# >= 6)) || return 2
  local n="$1" from="$2" to="$3" writer="$4" kind="$5" progress="$6"
  local event_id="${7:-}" ts="${8:-}" event_file="$AGENT_HOME/state/ticket-transitions.jsonl"
  local row lock_fd seed status
  [[ "$n" =~ ^[0-9]+$ ]] || return 2
  [ -n "$ts" ] || ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  if [ -z "$event_id" ]; then
    seed="$n|$from|$to|$ts|$(date +%s%N)|$RANDOM"
    event_id="$(printf '%s' "$seed" | sha256sum | awk '{print $1}')" || return 1
  fi
  row="$(jq -cn --arg ts "$ts" --argjson issue "$n" --arg from "$from" --arg to "$to" \
    --arg writer "$writer" --arg kind "$kind" --arg event_id "$event_id" \
    --argjson progress "$progress" \
    '{ts:$ts,issue:$issue,from_stage:$from,to_stage:$to,writer:$writer,kind:$kind,progress:$progress,event_id:$event_id}')" || return 1
  exec {lock_fd}>>"$event_file.lock" || return 1
  if ! flock -x "$lock_fd"; then
    exec {lock_fd}>&-
    return 1
  fi
  if [ -f "$event_file" ] && grep -Fq -- "\"event_id\":\"$event_id\"" "$event_file"; then
    flock -u "$lock_fd" || true
    exec {lock_fd}>&-
    return 0
  fi
  if printf '%s\n' "$row" >> "$event_file"; then
    local metric_rows
    metric_rows="$(jq -c '
      . as $event |
      (if .from_stage != "" and .from_stage != "untracked" then
        {schema_version:1,record_type:"event",event_type:"stage-exited",ts:.ts,issue:.issue,stage:.from_stage,
         writer:.writer,kind:.kind,progress:.progress,event_id:(.event_id+":exit"),source_event_id:.event_id}
       else empty end),
      (if .from_stage == "untracked" then
        {schema_version:1,record_type:"event",event_type:"ticket-created",ts:.ts,issue:.issue,stage:.to_stage,
         writer:.writer,kind:.kind,event_id:(.event_id+":created"),source_event_id:.event_id}
       else empty end),
      (if .to_stage != "" and .to_stage != "untracked" then
        {schema_version:1,record_type:"event",event_type:"stage-entered",ts:.ts,issue:.issue,stage:.to_stage,
         writer:.writer,kind:.kind,progress:.progress,event_id:(.event_id+":enter"),source_event_id:.event_id}
       else empty end),
      (if .to_stage == "closed" then
        {schema_version:1,record_type:"event",event_type:"ticket-closed",ts:.ts,issue:.issue,stage:.to_stage,
         writer:.writer,kind:.kind,event_id:(.event_id+":closed"),source_event_id:.event_id}
       else empty end),
      (if .to_stage == "released" then
        {schema_version:1,record_type:"event",event_type:"ticket-released",ts:.ts,issue:.issue,stage:.to_stage,
         writer:.writer,kind:.kind,event_id:(.event_id+":released"),source_event_id:.event_id}
       else empty end)
    ' <<< "$row")" || metric_rows=""
    if [ -z "$metric_rows" ] || ! efficiency_metrics_append_rows "$metric_rows"; then
      echo "ticket_stage_record: efficiency metrics append failed for #$n" >&2
    fi
    flock -u "$lock_fd" || true
    exec {lock_fd}>&-
    return 0
  else
    status=$?
  fi
  flock -u "$lock_fd" || true
  exec {lock_fd}>&-
  return "$status"
}

# A hard WSL reset leaves the unflushed tail of this append-only log as NUL
# bytes (2026-09-28 06:09Z: 223 bytes), and every jq reader then rejects the
# whole file. Rows are whole-line appends, so dropping the NULs recovers every
# row that reached the disk.
ticket_transitions_repair() {
  local event_file="$AGENT_HOME/state/ticket-transitions.jsonl" lock_fd
  [ -f "$event_file" ] || return 0
  [ "$(tr -cd '\000' < "$event_file" | wc -c)" -gt 0 ] || return 0
  exec {lock_fd}>>"$event_file.lock" || return 1
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  tr -d '\000' < "$event_file" > "$event_file.repair" && mv -f "$event_file.repair" "$event_file"
  local status=$?
  flock -u "$lock_fd" || true
  exec {lock_fd}>&-
  [ "$status" -eq 0 ] && echo "ticket-transitions: removed NUL bytes left by an unclean shutdown" >&2
  return "$status"
}

ticket_stage_latest() {
  local n="$1" event_file="$AGENT_HOME/state/ticket-transitions.jsonl"
  [ -f "$event_file" ] || return 0
  jq -sr --argjson issue "$n" '[.[] | select(.issue == $issue)][-1].to_stage // empty' "$event_file" 2>/dev/null
}

ticket_stage_record_labels() {
  local n="$1" arg label state_json state_to state_from state_changed_at
  local from="" to="" kind="${TICKET_STAGE_WRITE_KIND:-}" progress=true event_id="" hold_added=0
  local -a added=() removed=()
  shift
  while (($#)); do
    arg="$1"
    shift
    case "$arg" in
      --add-label|--remove-label)
        (($#)) || break
        label="$1"
        shift
        if [ "$arg" = --add-label ] && ticket_stage_is_label "$label"; then added+=("$label"); fi
        if [ "$arg" = --remove-label ] && ticket_stage_is_label "$label"; then removed+=("$label"); fi
        if [ "$arg" = --add-label ] && [ "$label" = on-hold ]; then hold_added=1; fi
        ;;
    esac
  done
  ((${#added[@]} || ${#removed[@]} || hold_added)) || return 0
  state_json="$(state_read "$n")" || state_json='{}'
  state_to="$(jq -r '.state // empty' <<< "$state_json" 2>/dev/null)"
  state_from="$(jq -r '.state_changed_from // empty' <<< "$state_json" 2>/dev/null)"
  state_changed_at="$(jq -r '.state_changed_at // empty' <<< "$state_json" 2>/dev/null)"
  # A deployment writes both released and concluded; released is the stage
  # advancement and concluded is its terminal marker.
  for label in "${added[@]}"; do
    if [ "$label" = released ]; then to=released; break; fi
    [ -n "$to" ] || to="$label"
  done
  [ "$hold_added" = 0 ] || to=on-hold
  if [ -z "$to" ]; then to=unrouted; fi
  if [ "$kind" = requeue ] && [ "$state_to" = "$to" ] && ((${#removed[@]} == 0)); then
    from="$to"
  elif [ "$state_to" = "$to" ] && [ -n "$state_from" ] \
    && [[ " ${removed[*]} " == *" $state_from "* ]]; then
    from="$state_from"
    if [ -n "$state_changed_at" ]; then
      event_id="$(printf '%s' "$n|$from|$to|$state_changed_at" | sha256sum | awk '{print $1}')"
    fi
  elif [ "$to" = needs-triage ] && [ "$(ticket_stage_latest "$n")" = closed ]; then
    from=closed
  elif [ "$state_to" != "$to" ] && [[ " ${removed[*]} " == *" $state_to "* ]]; then
    from="$state_to"
  else
    from="${removed[0]:-${state_from:-untracked}}"
  fi
  if [ "$from" = "$to" ] && [ "$kind" != requeue ]; then return 0; fi
  if [ -n "${TICKET_STAGE_WRITE_KIND:-}" ]; then
    kind="$TICKET_STAGE_WRITE_KIND"
  elif { [ "$from" = ready-for-agent ] && [ "$to" = needs-advisor ]; } \
    || { [ "$from" = needs-advisor ] && [ "$to" = ready-for-agent ]; }; then
    kind=flip
  elif [ "$to" = unrouted ] || [ "$to" = on-hold ]; then
    kind=park
  else
    kind=advance
  fi
  case "$kind" in flip|requeue|park) progress=false ;; *) progress=true ;; esac
  # A closed ticket may receive its terminal display labels after close. Those
  # are metadata; do not record a backwards stage transition.
  if [ "$(jq -r '.closed_by_pipeline // false' <<< "$state_json" 2>/dev/null)" = true ] \
    && { [ "$to" = released ] || [ "$to" = concluded ]; }; then
    return 0
  fi
  ticket_stage_record "$n" "$from" "$to" "${0##*/}" "$kind" "$progress" "$event_id"
}

ticket_stage_record_close() {
  local n="$1" state_json from latest
  state_json="$(state_read "$n")" || state_json='{}'
  latest="$(ticket_stage_latest "$n")"
  from="${latest:-$(jq -r '.state // .state_changed_from // "untracked"' <<< "$state_json" 2>/dev/null)}"
  [ -n "$from" ] || from=untracked
  [ "$from" = closed ] && return 0
  ticket_stage_record "$n" "$from" closed "${0##*/}" close 1
}

ticket_stage_record_gh_write() {
  case "${1:-}:${2:-}" in
    issue:edit)
      ticket_stage_record_labels "${3:-}" "${@:4}"
      ;;
    issue:close)
      ticket_stage_record_close "${3:-}"
      ;;
    *) return 0 ;;
  esac
}

# Merges $2 (a jq filter producing an object to merge) into issue $1's state.
# 2026-09-12 bug: a "read-only" --dry-run triage run gave a real issue
# attempts:1 and paused the live pipeline, because this wrote to disk
# unconditionally. Under AGENT_DRY_RUN=1 it now computes and prints what it
# would have written instead of writing it — same DRY_RUN short-circuit as
# guarded_write, just for local state instead of gh/ssh/docker.
#
# 2026-09-15 bug (#1204/#1206 live, measured): $filter used to go straight
# into jq's own argv (`jq "$filter"`). Every "merge this whole verdict"
# call site (run-advisor.sh's `". + $PATCH"` etc.) builds $filter by
# splicing model-authored JSON -- an advisor ruling's reasoning_md/
# decision_md -- directly into that string. Once a ruling's text pushed the
# resulting argv element past Linux's MAX_ARG_STRLEN (128KiB per argument,
# independent of the much larger ARG_MAX), `execve` refused to even start
# jq: exit 126, "Argument list too long", the run dying mid-function under
# this script's `set -e` before it ever reached its own state write --
# silently, from the caller's side, because the failure looked exactly like
# any other killed unit. #1204's stored ruling alone was 127.7K by the time
# this was caught. Fix the function, not every call site: jq's `-f/
# --from-file` reads the PROGRAM from a file instead of argv, so $filter's
# size is bounded only by disk, never by exec's argument limit -- no call
# site changes needed, since a filter string that was valid as an argv
# element is byte-identical and equally valid read from a file.
#
# This fixed $filter (the PROGRAM); it does not fix a caller's own
# --arg/--argjson DATA (a brief_md, a whole ISSUE_JSON) reaching jq's argv
# on the way to building that $filter -- see jq_arg_file() just above for
# the sibling seam that closes that half, added 2026-09-16 once the same
# argv-size failure turned up a third time in sites this fix did not touch.
#
# A failed merge must not fail silently and must never leave $f half
# written: check jq's own exit status (and guard against an empty $new,
# which pipefail alone would not catch if jq somehow exited 0 with nothing
# on stdout) BEFORE ever touching $f, and return non-zero so the caller's
# `set -e` still stops the run -- now with a diagnostic on stderr naming the
# issue, instead of a bare exec error with no issue number attached. The
# final write itself was already atomic (temp file + rename) and stays so.
# Serialize the full read/merge/rename for each issue: concurrent writers
# otherwise share `$f.tmp`, and one can move that path before another does.
# The subshell releases the per-state lock on every return path.
state_merge() (
  local n="$1" filter="$2" lock_mode="${3:-}" f new filter_file previous_state previous_json legacy_epoch lock_fd
  local old_pr new_pr progress_stage
  f="$(state_file "$n")"
  mkdir -p -- "$STATE_DIR" || { echo "state_merge: could not create state directory for issue #$n -- state file $f NOT written" >&2; return 1; }
  if [ -n "$lock_mode" ] && [ "$lock_mode" != __issue_transition_lock_held ]; then
    echo "state_merge: invalid internal lock mode for issue #$n -- state file $f NOT written" >&2
    return 64
  fi
  if [ "$lock_mode" != __issue_transition_lock_held ]; then
    if ! exec {lock_fd}>"$f.lock"; then
      echo "state_merge: could not open state lock for issue #$n -- state file $f NOT written" >&2
      return 1
    fi
    if ! flock -x "$lock_fd"; then
      echo "state_merge: could not lock state for issue #$n -- state file $f NOT written" >&2
      return 1
    fi
  fi
  previous_json="$(state_read "$n")"
  previous_state="$(jq -r '.state // empty' <<< "$previous_json" 2>/dev/null || true)"
  legacy_epoch="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
  filter_file="$(mktemp)" || { echo "state_merge: mktemp failed for issue #$n -- state file $f NOT written" >&2; return 1; }
  printf '%s\n' "$filter" > "$filter_file"
  # Keep this in the existing atomic state write: counters and merge-sweep
  # bookkeeping must not refresh the progress clock. A legacy file's mtime is
  # copied once as its baseline, before later bookkeeping can change mtime.
  printf '%s\n' ' | if (.state // "") != $previous_state then .state_changed_from = $previous_state | .state_changed_at = (now | todate) elif (.state_changed_at // "") == "" and $legacy_epoch > 0 then .state_changed_at = ($legacy_epoch | todate) else . end' >> "$filter_file"
  if ! new="$(jq --arg previous_state "$previous_state" --argjson legacy_epoch "$legacy_epoch" -f "$filter_file" <<< "$previous_json")" || [ -z "$new" ]; then
    rm -f "$filter_file"
    echo "state_merge: jq failed for issue #$n -- state file $f NOT written (filter kept in a file, out of argv, precisely so this diagnostic -- not an exec error -- is what shows up)" >&2
    return 1
  fi
  rm -f "$filter_file"
  # A stage label cannot reconstruct merge identity after local state loss.
  if ! printf '%s\n%s\n' "$previous_json" "$new" | jq -se '
    def release_identity:
      .run.outcome == "merged" and
      (.run.evidence.pr_number | tostring | test("^[1-9][0-9]*$")) and
      (.deploy_state == "pending" or .deploy_state == "deployed");
    .[0] as $old | .[1] as $new |
    $new.state != "awaiting-release" or ($new | release_identity) or
    ($old.state == "awaiting-release" and ($old | release_identity | not))
  ' >/dev/null; then
    echo "state_merge: refusing incomplete release handoff for issue #$n; reconcile through conclude_merged_run with verified PR/main ancestry -- state file $f NOT written" >&2
    return 1
  fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] state_merge $n -> $new" >&2
    return 0
  fi
  printf '%s\n' "$new" > "$f.tmp" || return 1
  # Rename alone leaves unflushed state vulnerable to NUL loss on a hard WSL reset.
  python3 - "$f.tmp" "$f" <<'PY' || return 1
import os, sys
source, target = sys.argv[1:]
with open(source, 'rb') as state:
    os.fsync(state.fileno())
os.replace(source, target)
directory = os.open(os.path.dirname(target), os.O_RDONLY)
try:
    os.fsync(directory)
finally:
    os.close(directory)
PY
  old_pr="$(jq -r '.run.evidence.pr_number // empty' <<< "$previous_json")"
  new_pr="$(jq -r '.run.evidence.pr_number // empty' <<< "$new")"
  if [ -n "$new_pr" ] && [ "$new_pr" != "$old_pr" ]; then
    progress_stage="$(jq -r '.state // .state_changed_from // "untracked"' <<< "$new")"
    ticket_stage_record "$n" "$progress_stage" "$progress_stage" "${0##*/}" implement true "implement:$n:$new_pr" || {
      echo "state_merge: PR progress record failed for issue #$n PR #$new_pr" >&2
      return 1
    }
  fi
)

# One row per persisted state; tracker retirement is a reason-gated exit from every state.
# `on-hold -> *` and terminal requeues are narrowed further by reason below.
declare -gA ISSUE_TRANSITION_TABLE=(
  [untracked]="needs-triage needs-info ready-for-agent ready-for-human needs-owner checks-blocked duplicate finish-first wontfix needs-advisor needs-recut awaiting-release awaiting-pipeline-sync awaiting-pipeline-health released concluded on-hold tracker"
  [needs-triage]="needs-triage needs-info ready-for-agent ready-for-human needs-owner checks-blocked duplicate finish-first wontfix needs-advisor needs-recut awaiting-release awaiting-pipeline-sync awaiting-pipeline-health concluded on-hold tracker"
  [needs-info]="needs-info needs-triage ready-for-agent ready-for-human needs-advisor needs-recut checks-blocked concluded on-hold tracker"
  [ready-for-agent]="ready-for-agent needs-triage needs-info ready-for-human needs-owner checks-blocked duplicate finish-first wontfix needs-advisor needs-recut awaiting-release awaiting-pipeline-sync awaiting-pipeline-health concluded on-hold tracker"
  [ready-for-human]="ready-for-human needs-triage needs-info ready-for-agent needs-advisor needs-recut checks-blocked concluded on-hold tracker"
  [needs-owner]="needs-owner needs-advisor ready-for-agent needs-info concluded on-hold tracker"
  [checks-blocked]="checks-blocked ready-for-agent needs-advisor needs-info concluded on-hold tracker"
  [duplicate]="duplicate concluded needs-triage ready-for-agent on-hold tracker"
  [finish-first]="finish-first concluded needs-triage needs-info ready-for-agent awaiting-release on-hold tracker"
  [wontfix]="wontfix concluded needs-triage ready-for-agent on-hold tracker"
  [needs-advisor]="needs-advisor ready-for-agent needs-triage needs-info needs-recut tracker checks-blocked concluded on-hold"
  [needs-recut]="needs-recut ready-for-agent needs-advisor needs-triage needs-info tracker released concluded on-hold"
  [awaiting-release]="awaiting-release released concluded duplicate finish-first wontfix on-hold ready-for-agent tracker"
  [awaiting-pipeline-sync]="awaiting-pipeline-sync ready-for-agent awaiting-pipeline-health concluded on-hold tracker"
  [awaiting-pipeline-health]="awaiting-pipeline-health released ready-for-agent concluded on-hold tracker"
  [released]="released concluded ready-for-agent needs-triage on-hold tracker"
  [concluded]="concluded awaiting-release released needs-triage ready-for-agent needs-info needs-advisor needs-recut duplicate finish-first wontfix on-hold tracker"
  [on-hold]="on-hold needs-triage needs-info ready-for-agent ready-for-human needs-owner checks-blocked duplicate finish-first wontfix needs-advisor needs-recut awaiting-release awaiting-pipeline-sync awaiting-pipeline-health released concluded tracker"
  [tracker]="tracker needs-triage ready-for-agent released concluded on-hold"
)

issue_transition_state_is_valid() {
  local state="${1:-}"
  [ -n "$state" ] || return 1
  [ -n "${ISSUE_TRANSITION_TABLE[$state]+set}" ]
}

issue_transition_allowed() {
  local from="$1" to="$2" reason="$3"
  issue_transition_state_is_valid "$from" && issue_transition_state_is_valid "$to" || return 1
  case "$reason" in
    close-reconcile:*)
      case "$to" in concluded|duplicate|wontfix) ;; *) return 1 ;; esac
      case "$from" in concluded|duplicate|wontfix|released|closed) return 1 ;; esac
      return 0
      ;;
  esac
  # Last-child release retires umbrella parents from their current lane.
  if [ "$to" = released ] && [ "$reason" = all-children-released ]; then return 0; fi
  [[ " ${ISSUE_TRANSITION_TABLE[$from]} " == *" $to "* ]] || return 1
  case "$from:$to" in
    on-hold:awaiting-release)
      case "$reason" in ops-acceptance-passed|merged-pr) ;; *) return 1 ;; esac
      ;;
    *:awaiting-release)
      [ "$reason" = merged-pr ] || return 1
      ;;
    *:tracker)
      case "$reason" in
        recut-parent-retired) ;;
        intake-parent:roadmap-container:*)
          case "$from" in untracked|ready-for-agent) ;; *) return 1 ;; esac
          ;;
        *) return 1 ;;
      esac
      ;;
    awaiting-release:ready-for-agent|released:ready-for-agent)
      case "$reason" in revert|failed-deploy|reopened-by-human|main-red-revert|continuation-requeue) ;; *) return 1 ;; esac
      ;;
    awaiting-release:released)
      [ "$reason" = deployment-proven ] || return 1
      ;;
    awaiting-pipeline-health:released)
      [ "$reason" = deployment-proven ] || return 1
      ;;
    tracker:released)
      [ "$reason" = all-children-released ] || return 1
      ;;
    concluded:released)
      [ "$reason" = deployment-proven ] || return 1
      ;;
    on-hold:concluded|on-hold:duplicate|on-hold:finish-first|on-hold:wontfix)
      [[ "$reason" == conclude:* || "$reason" == close-* ]] || return 1
      ;;
    on-hold:*)
      case "$reason" in hold-applied|hold-expired|hold-dead-owner|hold-release|hold-requeue|hold-backfill|hold-supervisor-release|recut-parent-retired|merged-pr|deployment-proven|all-children-released|pipeline-system-verification|main-red-revert) ;; *) return 1 ;; esac
      ;;
    finish-first:needs-triage)
      [ "$reason" = blocking-pr-cleared ] || return 1
      ;;
    finish-first:needs-info)
      [ "$reason" = supervisor-needs-info ] || return 1
      ;;
    finish-first:awaiting-release)
      # The issue's own PR merged while it waited (the autopilot merge lane
      # lands PRs regardless of issue state); #4061 sat refused 2026-10-22.
      [ "$reason" = merged-pr ] || return 1
      ;;
    concluded:needs-triage|duplicate:needs-triage|wontfix:needs-triage|released:needs-triage)
      case "$reason" in reopened-by-human|prod-anomaly-recurred) ;; *) return 1 ;; esac
      ;;
    concluded:ready-for-agent)
      case "$reason" in conclusion-requeue|revert|failed-deploy|reopened-by-human|main-red-revert|continuation-requeue) ;; *) return 1 ;; esac
      ;;
  esac
  return 0
}

# issue_transition <issue> <state-label> <reason> [state-merge-filter] [skip-label-write] [issue-json] [source-issue] [open-issue]
# Keep state JSON and GitHub stage labels serialized by state_merge's lock.
# GitHub and local disk cannot share a transaction; a failed label write rolls
# the local snapshot back, and HEALTH reports any remote drift it cannot undo.
# skip-label-write is for callers that already know the destination label is set.
issue_transition() (
  local n="${1:-}" to="${2:-}" reason="${3:-}" patch="${4:-.}" skip_label_write="${5:-0}" intake_json="${6:-}" source_issue="${7:-}" open_issue="${8:-0}" expected_hold="${9:-}" lock_mode="${10:-}" f before from add_label label restore_status=0 transition_lock_fd release_hold_overlay=0
  local had_state=0 requeue_epoch started_epoch merged_epoch merged_at reason_file requeue_transition=0 hold_json write_kind="label write"
  local -a add_labels=() edit_args=() api_args=() issue_labels=()
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "issue_transition: valid issue number required" >&2; return 64; }
  [ -n "$reason" ] || { echo "issue_transition: reason required for #$n -> $to" >&2; return 64; }
  [[ "$skip_label_write" == 0 || "$skip_label_write" == 1 ]] || { echo "issue_transition: skip-label-write must be 0 or 1 for #$n" >&2; return 64; }
  [[ "$open_issue" == 0 || "$open_issue" == open ]] || { echo "issue_transition: open-issue must be 0 or open for #$n" >&2; return 64; }
  if [ "$open_issue" = open ] && [ "$skip_label_write" = 1 ]; then
    echo "issue_transition: reopening cannot skip the remote label write for #$n" >&2
    return 64
  fi
  if [ "$open_issue" = open ] && ! jq -e '((.state // "") | ascii_downcase) == "closed" and (.labels | type == "array")' <<< "$intake_json" >/dev/null 2>&1; then
    echo "issue_transition: reopening requires a closed issue snapshot with labels for #$n" >&2
    return 64
  fi
  issue_transition_state_is_valid "$to" || { echo "issue_transition: unknown target state '$to' for #$n" >&2; return 64; }
  if [[ "$reason" == close-reconcile:* ]] && ! jq -e --arg issue "$n" '
    (.number | tostring) == $issue and ((.state // "") | ascii_downcase) == "closed" and
    ((.labels | type) == "array" or (.labels.nodes | type) == "array")
  ' <<< "$intake_json" >/dev/null 2>&1; then
    echo "issue_transition: close reconciliation requires a closed issue snapshot for #$n" >&2
    return 64
  fi

  f="$(state_file "$n")" || return 1
  mkdir -p -- "$STATE_DIR" || return 1
  if [ "$lock_mode" != __issue_transition_lock_held ]; then
    exec {transition_lock_fd}>"$f.lock" || { echo "issue_transition: could not open state lock for #$n" >&2; return 1; }
    flock -x "$transition_lock_fd" || { echo "issue_transition: could not lock state for #$n" >&2; return 1; }
  fi
  [ -f "$f" ] && had_state=1
  before="$(state_read "$n")" || return 1
  if [ -n "$expected_hold" ] && ! jq -e --argjson expected "$expected_hold" '.state == "on-hold" and (.hold | del(.aging_window)) == ($expected | del(.aging_window))' <<< "$before" >/dev/null; then
    echo "issue_transition: hold for #$n changed before release; retry from the current hold" >&2
    return 1
  fi
  if ! from="$(jq -r '.state // "untracked"' <<< "$before" 2>/dev/null)"; then
    echo "issue_transition: invalid state JSON for #$n" >&2
    return 1
  fi
  if [ "$from" = on-hold ] && [ "$to" = awaiting-release ] && [ "$reason" = ops-acceptance-passed ]; then
    jq -e '
      .ops_acceptance_after_release.required == true
      and .ops_acceptance_after_release.status == "passed"
      and (.deployed_sha // "") != ""
      and .ops_acceptance_after_release.release_sha == .deployed_sha
      and (.ops_acceptance_after_release.evidence // "" | length > 0)
    ' <<< "$before" >/dev/null 2>&1 || {
      echo "issue_transition: refusing ops acceptance release for #$n without evidence for the deployed SHA" >&2
      return 1
    }
  fi
  if jq -e '.tracker_parent == true or .state == "tracker"' <<< "$before" >/dev/null 2>&1; then
    case "$to" in
      needs-triage|needs-info|ready-for-agent|ready-for-human|needs-owner|checks-blocked|needs-advisor|needs-recut|awaiting-release|awaiting-pipeline-sync|awaiting-pipeline-health)
        echo "issue_transition: refused tracker parent #$n -> active state $to" >&2
        return 1
        ;;
    esac
  fi
  if ! issue_transition_allowed "$from" "$to" "$reason"; then
    echo "issue_transition: refused #$n $from -> $to (reason=$reason)" >&2
    return 1
  fi
  if [ "$to" != on-hold ] && [ "$from" != on-hold ]; then
    case "$to:$reason" in
      concluded:conclude:*|concluded:close-*|duplicate:close-*|duplicate:conclude:*|\
      finish-first:close-*|finish-first:conclude:*|\
      wontfix:close-*|wontfix:conclude:*|\
      awaiting-release:merged-pr|\
      ready-for-agent:hold-requeue|\
      ready-for-agent:revert|ready-for-agent:failed-deploy|ready-for-agent:reopened-by-human|ready-for-agent:main-red-revert)
        # A PR merged to main ends the held episode; releasing the hold through
        # state_requeue first stamped requeued_at after the merge (2026-10-09).
        # Explicit hold requeue also clears a stale remote label after local state advanced.
        release_hold_overlay=1
        ;;
    esac
    if [ "$DRY_RUN" != 1 ] && is_on_hold "$n" \
      && [ "${ISSUE_LABEL_VIEW_STATE[$n]:-}" != failed ] \
      && [ "$release_hold_overlay" != 1 ]; then
      echo "issue_transition: refused held #$n $from -> $to (reason=$reason)" >&2
      return 1
    fi
  fi
  if [ "$to" = concluded ] && [[ "$reason" == conclude:* ]]; then
    requeue_epoch="$(agent_epoch "$(jq -r '.requeued_at // empty' <<< "$before")" 2>/dev/null || echo 0)"
    started_epoch="$(agent_epoch "$(jq -r '.run.implement_started_at // empty' <<< "$before")" 2>/dev/null || echo 0)"
    # Only deployed conclusions may use the exact PR's actual merge evidence.
    # run.merged_at is handoff time and can be newer than a human requeue.
    reason_file="$(jq_arg_file "$reason")" || return 1
    merged_at="$(jq -r --rawfile reason "$reason_file" '
      select($reason == "conclude:deployed" and .run.outcome == "merged" and .deploy_state == "deployed"
        and (.run.evidence.merged_pr.number | tostring) == (.run.evidence.pr_number | tostring)
        and (.run.evidence.merged_pr.merge_sha // "") != "")
      | .run.evidence.merged_pr.merged_at // empty
    ' <<< "$before")" || merged_at=""
    rm -f -- "$reason_file"
    merged_epoch="$(agent_epoch "$merged_at" 2>/dev/null || echo 0)"
    if [[ "$requeue_epoch" =~ ^[0-9]+$ && "$started_epoch" =~ ^[0-9]+$ ]] \
      && (( requeue_epoch > 0 && (started_epoch == 0 || started_epoch < requeue_epoch) && merged_epoch <= requeue_epoch )); then
      echo "issue_transition: refused stale conclusion for #$n after requeue" >&2
      return 1
    fi
  fi
  case "$reason" in *requeue*|revert|failed-deploy|main-red-revert) requeue_transition=1 ;; esac

  if declare -F roadmap_ensure_issue_parent >/dev/null; then
    roadmap_ensure_issue_parent "$n" "$to" "$intake_json" "$source_issue" || return $?
  fi

  case "$to:$reason" in
    concluded:conclude:deployed) add_labels=(concluded released) ;;
    concluded:conclude:duplicate) add_labels=(concluded duplicate) ;;
    concluded:close-reconcile:deployed) add_labels=(concluded released) ;;
    concluded:*) add_labels=(concluded) ;;
    tracker:*) add_labels=() ;;
    *) add_labels=("$to") ;;
  esac
  [ "$DRY_RUN" = 1 ] || ensure_state_labels
  local target_json
  target_json="$(jq -cn --arg state "$to" '$state')" || return 1
  local filter="$patch | .state = $target_json"
  if { [ "$from" = on-hold ] || [ "$release_hold_overlay" = 1 ]; } \
    && [ "$to" != on-hold ] && ! [[ "$patch" == *".hold ="* ]]; then filter+=" | .hold = null"; fi
  if [ "$requeue_transition" = 1 ]; then
    state_merge_attempt_transition "$n" "$filter" __issue_transition_lock_held || {
      echo "issue_transition: state write failed for #$n" >&2
      return 1
    }
  elif ! state_merge "$n" "$filter" __issue_transition_lock_held; then
    echo "issue_transition: state write failed for #$n" >&2
    return 1
  fi
  if [ "$to" = on-hold ]; then
    hold_json="$(state_read "$n" | jq -c '.hold // {}')" || return 1
    if hold_durable_record_valid "$hold_json"; then
      if ! jq -e '.durable_record == true' <<< "$hold_json" >/dev/null 2>&1; then
        if ! hold_durable_record_publish "$n" "$hold_json" \
          || ! state_merge "$n" '.hold.durable_record = true' __issue_transition_lock_held; then
          if [ "$had_state" = 1 ]; then
            printf '%s\n' "$before" > "$f.tmp" && mv -f -- "$f.tmp" "$f" || restore_status=2
          else
            rm -f -- "$f" "$f.tmp" || restore_status=2
          fi
          echo "issue_transition: durable hold record failed for #$n; state rollback status=$restore_status" >&2
          return 1
        fi
      fi
    elif jq -e '.durable_record == true' <<< "$hold_json" >/dev/null 2>&1; then
      state_merge "$n" '.hold.durable_record = false' __issue_transition_lock_held || return 1
    fi
  fi
  [ "$skip_label_write" != 1 ] || return 0

  edit_args=(gh issue edit "$n" --repo "$REPO")
  for label in "${ALL_STATE_LABELS[@]}" on-hold; do
    [ "$label" != on-hold ] || [ "$from" = on-hold ] || [ "$release_hold_overlay" = 1 ] || continue
    local keep=0
    for add_label in "${add_labels[@]}"; do [ "$label" != "$add_label" ] || keep=1; done
    [ "$keep" = 1 ] || edit_args+=(--remove-label "$label")
  done
  edit_args+=(--remove-label in-progress)
  [ "$reason" != conclude:deployed ] || edit_args+=(--remove-label evidence-gate)
  for add_label in "${add_labels[@]}"; do edit_args+=(--add-label "$add_label"); done
  if [ "$open_issue" = open ]; then
    # Reopen and stage labels share one remote PATCH, so failure cannot leave a partially reopened ticket.
    write_kind="open and label write"
    api_args=(gh api --method PATCH "repos/$REPO/issues/$n" -f state=open)
    while IFS= read -r label; do
      [ -n "$label" ] || continue
      case "$label" in
        in-progress) continue ;;
        evidence-gate) [ "$reason" != conclude:deployed ] || continue ;;
        on-hold)
          if [ "$from" != on-hold ] && [ "$release_hold_overlay" != 1 ]; then
            issue_labels+=("$label")
            continue
          fi
          ;;
      esac
      local state_label is_state_label=0
      for state_label in "${ALL_STATE_LABELS[@]}"; do [ "$label" != "$state_label" ] || is_state_label=1; done
      if [ "$is_state_label" = 0 ]; then issue_labels+=("$label"); fi
    done < <(jq -r '.labels[]?.name // empty' <<< "$intake_json")
    issue_labels+=("${add_labels[@]}")
    for label in "${issue_labels[@]}"; do api_args+=(-f "labels[]=$label"); done
    guarded_write "${api_args[@]}" || restore_status=$?
  elif [ "$requeue_transition" = 1 ]; then
    TICKET_STAGE_WRITE_KIND=requeue guarded_write "${edit_args[@]}" || restore_status=$?
  else
    guarded_write "${edit_args[@]}" || restore_status=$?
  fi
  if [ "$restore_status" -ne 0 ]; then
    if [ "$had_state" = 1 ]; then
      printf '%s\n' "$before" > "$f.tmp" && mv -f -- "$f.tmp" "$f" || restore_status=2
    else
      rm -f -- "$f" "$f.tmp" || restore_status=2
    fi
    echo "issue_transition: $write_kind failed for #$n; state rollback status=$restore_status" >&2
    return 1
  fi
  [ "$open_issue" != open ] || issue_label_cache_invalidate || true
  return 0
)

# Reconcile GitHub-side closes that bypassed pipeline close callers. The
# snapshot is the authority for close reason and labels; issue_transition
# remains the only durable-state and stage-label writer.
issue_reconcile_closed_state() {
  local n="$1" issue_json="$2" file state_json from close_reason closed_at target transition_reason labels patch transition_snapshot
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || return 64
  if ! jq -e --arg issue "$n" '
    (.number | tostring) == $issue and ((.state // "") | ascii_downcase) == "closed" and
    ((.labels | type) == "array" or (.labels.nodes | type) == "array") and
    ((.stateReason // .state_reason // null) == null or (.stateReason // .state_reason | type) == "string")
  ' <<< "$issue_json" >/dev/null 2>&1; then
    echo "issue_reconcile_closed_state: invalid closed issue snapshot for #$n" >&2
    return 1
  fi
  file="$(state_file "$n")" || return 1
  [ -f "$file" ] || return 0
  state_json="$(state_read "$n")" || return 1
  from="$(jq -r '.state // "untracked"' <<< "$state_json")" || return 1
  case "$from" in concluded|duplicate|wontfix|released|closed) return 0 ;; esac

  close_reason="$(jq -r '(.stateReason // .state_reason // "UNKNOWN") | ascii_upcase' <<< "$issue_json")" || return 1
  closed_at="$(jq -r '.closedAt // .closed_at // empty' <<< "$issue_json")" || return 1
  labels="$(jq -r 'if (.labels | type) == "array" then .labels[]? | if type == "string" then . else .name end else .labels.nodes[]?.name end' <<< "$issue_json")" || return 1
  ISSUE_LABEL_VIEW_STATE[$n]=loaded
  ISSUE_LABEL_VIEW_LABELS[$n]="$labels"
  ISSUE_LABEL_VIEW_AT[$n]="$SECONDS"
  ISSUE_LABEL_VIEW_ERROR[$n]=""

  if grep -Fqx duplicate <<< "$labels"; then
    target=duplicate; transition_reason=close-reconcile:duplicate
  elif [ "$close_reason" = NOT_PLANNED ]; then
    target=wontfix; transition_reason=close-reconcile:not-planned
  elif [ "$(jq -r '.released // false' <<< "$state_json")" = true ]; then
    target=concluded; transition_reason=close-reconcile:deployed
  else
    target=concluded; transition_reason=close-reconcile:completed
  fi
  patch="$(jq -cn --arg state_reason "$close_reason" --arg closed_at "$closed_at" \
    '{state_reason:$state_reason,closed_at:(if $closed_at == "" then null else $closed_at end),reconciled_at:(now|todate)}')" || return 1
  transition_snapshot="$(jq -c '
    .labels = (if (.labels | type) == "array" then .labels else [.labels.nodes[]?] end)
  ' <<< "$issue_json")" || return 1
  issue_transition "$n" "$target" "$transition_reason" ".closed_issue_reconciliation = $patch" 0 "$transition_snapshot"
}

# Apply attempt changes and re-aim saved pipeline work in the same state write.
# Invalid or partial checkpoints start fresh instead of blocking dispatch.
state_merge_attempt_transition() {
  local n="$1" filter="$2" lock_mode="${3:-}"
  local alignment='if .pipeline_system.enabled == true then
    if ((.pipeline_system.resume_artifact_sha // "") | test("^[0-9a-f]{40,64}$"))
    then .pipeline_system.resume_artifact_attempt = (.attempts // 0)
    else del(.pipeline_system.resume_artifact_sha, .pipeline_system.resume_artifact_attempt)
    end
  else . end'
  state_merge "$n" "$filter | $alignment" "$lock_mode"
}

hold_stage_label_is_valid() {
  [ "$1" != on-hold ] && [ "$1" != concluded ] && ticket_stage_is_label "$1"
}

hold_stage_before() {
  local state_json="$1" issue_json="${2:-}" state_stage state_from existing_stage candidate label
  state_stage="$(jq -r '.state // empty' <<< "$state_json" 2>/dev/null)"
  state_from="$(jq -r '.state_changed_from // empty' <<< "$state_json" 2>/dev/null)"
  existing_stage="$(jq -r '.hold.stage_before // empty' <<< "$state_json" 2>/dev/null)"
  if [ "$state_stage" = on-hold ]; then
    for candidate in "$existing_stage" "$state_from"; do
      if hold_stage_label_is_valid "$candidate"; then echo "$candidate"; return 0; fi
    done
  else
    for candidate in "$state_stage" "$state_from" "$existing_stage"; do
      if hold_stage_label_is_valid "$candidate"; then echo "$candidate"; return 0; fi
    done
  fi
  if [ -n "$issue_json" ]; then
    while IFS= read -r label; do
      if hold_stage_label_is_valid "$label"; then echo "$label"; return 0; fi
    done < <(jq -r '.labels[]?.name // empty' <<< "$issue_json" 2>/dev/null)
  fi
  echo needs-triage
}

hold_expiry_resolve() {
  local spec="$1" now_epoch expiry_epoch
  now_epoch="$(date -u +%s)" || return 1
  if [[ "$spec" =~ ^([1-9][0-9]*)h$ ]]; then
    expiry_epoch=$((now_epoch + BASH_REMATCH[1] * 3600))
  else
    expiry_epoch="$(agent_epoch -u "$spec" 2>/dev/null)" || return 1
  fi
  (( expiry_epoch > now_epoch )) || return 1
  date -u -d "@$expiry_epoch" +%Y-%m-%dT%H:%M:%SZ
}

# hold_issue <issue> --holder X --release TEXT --expires 24h [--kind NAME] [--stage-before LABEL]
# Shared write path for pipeline and operator holds. hold.sh exposes the same
# contract as a command for holds created outside this checkout.
hold_issue() {
  local n="${1:-}" holder="" release_condition="" expires_spec="" kind=manual stage_before_override=""
  local expiry_at state_json issue_json stage_before record_json hold_label=on-hold
  shift || true
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "hold_issue: valid issue number required" >&2; return 64; }
  while (($#)); do
    case "$1" in
      --holder|--release|--expires|--kind|--stage-before)
        (($# >= 2)) || { echo "hold_issue: value required for $1" >&2; return 64; }
        case "$1" in
          --holder) holder="$2" ;;
          --release) release_condition="$2" ;;
          --expires) expires_spec="$2" ;;
          --kind) kind="$2" ;;
          --stage-before) stage_before_override="$2" ;;
        esac
        shift 2
        ;;
      --remove-label)
        (($# >= 2)) || { echo "hold_issue: label required after --remove-label" >&2; return 64; }
        ticket_stage_is_label "$2" && [ "$2" != on-hold ] || {
          echo "hold_issue: invalid stage label '$2'" >&2
          return 64
        }
        shift 2
        ;;
      *) echo "hold_issue: unexpected argument '$1'" >&2; return 64 ;;
    esac
  done
  [ -n "$holder" ] && [ -n "$release_condition" ] && [ -n "$expires_spec" ] || {
    echo "hold_issue: --holder, --release, and --expires are required" >&2
    return 64
  }
  [[ "${holder,,}" != unknown ]] || { echo "hold_issue: unknown holder is not valid hold metadata" >&2; return 64; }
  [[ "$kind" =~ ^[[:alnum:]][[:alnum:]._-]*$ ]] || { echo "hold_issue: invalid kind '$kind'" >&2; return 64; }
  if [ -n "$stage_before_override" ] && ! hold_stage_label_is_valid "$stage_before_override"; then
    echo "hold_issue: invalid --stage-before '$stage_before_override'" >&2
    return 64
  fi
  expiry_at="$(hold_expiry_resolve "$expires_spec")" || {
    echo "hold_issue: --expires must be a future duration in hours or timestamp" >&2
    return 64
  }
  state_json="$(state_read "$n")" || return 1
  if ! jq -e 'type == "object"' <<< "$state_json" >/dev/null 2>&1; then
    echo "hold_issue: invalid state for #$n" >&2
    return 1
  fi
  issue_json="$(gh issue view "$n" --repo "$REPO" --json state,labels 2>/dev/null)" || {
    echo "hold_issue: could not inspect #$n before applying hold" >&2
    return 1
  }
  if ! jq -e '(.state // "" | ascii_downcase) == "open" and (.labels | type == "array")' \
      <<< "$issue_json" >/dev/null 2>&1; then
    echo "hold_issue: #$n is not an open issue or labels could not be read" >&2
    return 1
  fi
  stage_before="${stage_before_override:-$(hold_stage_before "$state_json" "$issue_json")}" || return 1
  record_json="$(jq -cn --arg holder "$holder" --arg release "$release_condition" \
    --arg expires "$expiry_at" --arg stage "$stage_before" --arg kind "$kind" \
    '{holder:$holder,release_condition:$release,expires_at:$expires,stage_before:$stage,kind:$kind,created_at:(now|todate),durable_record:false}')" || return 1
  issue_transition "$n" "$hold_label" hold-applied ".hold = $record_json" || return 1
  return 0
}

# One issue-json predicate keeps label and title marks consistent at intake and hold expiry.
is_hotfix_lane_issue() {
  jq -e '
    any(.labels[]?; (.name // "" | ascii_downcase) == "hotfix")
    or ((.title // "") | test("(?i)(\\[\\s*hotfix\\s*\\]|\\[\\s*hot-fix\\s*\\]|\\[\\s*热修\\s*\\]|【\\s*热修\\s*】|（[^）]*热修）)"))
  ' <<< "$1" >/dev/null 2>&1
}

hold_comment_has_marker() {
  jq -e --arg marker "$2" 'any(.comments[]?; (.body // "") | contains($marker))' \
    <<< "$1" >/dev/null 2>&1
}

hold_durable_record_payload() {
  jq -ce '{holder,release_condition,expires_at,stage_before,kind} + (if has("created_at") then {created_at} else {} end) + (if has("hand_owner") then {hand_owner} else {} end)' <<< "$1"
}

hold_durable_record_valid() {
  local record="$1" stage
  jq -e '
    type == "object"
    and (.holder | type == "string" and length > 0 and ascii_downcase != "unknown")
    and (.release_condition | type == "string" and length > 0)
    and (.expires_at | type == "string" and (try fromdateiso8601 catch null) != null)
    and (.stage_before | type == "string" and length > 0)
    and (.kind | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$") and . != "backfill")
    and (if has("hand_owner") then (.hand_owner | type == "string" and test("^hand-[1-9][0-9]*$")) else true end)
    and (if has("created_at") then (.created_at | type == "string" and (try fromdateiso8601 catch null) != null) else true end)
  ' <<< "$record" >/dev/null 2>&1 || return 1
  stage="$(jq -r '.stage_before' <<< "$record")" || return 1
  hold_stage_label_is_valid "$stage"
}

hold_assign_hand_owner() {
  local n="$1" owner="$2" state hold owner_json record_json
  [[ "$n" =~ ^[1-9][0-9]*$ && "$owner" == "hand-$n" ]] || return 64
  state="$(state_read "$n")" || return 1
  jq -e '.state == "on-hold" and (.hold | type) == "object" and .hold.kind != ""' <<< "$state" >/dev/null 2>&1 || return 1
  owner_json="$(jq -cn --arg owner "$owner" '$owner')" || return 1
  state_merge "$n" ".hold.holder = \"supervisor\" | .hold.hand_owner = $owner_json | .hold.durable_record = false" || return 1
  record_json="$(state_read "$n" | jq -c '.hold')" || return 1
  hold_durable_record_publish "$n" "$record_json" || return 1
  state_merge "$n" '.hold.durable_record = true'
}

hold_clear_hand_owner() {
  local n="$1" state record_json
  state="$(state_read "$n")" || return 1
  jq -e '.state == "on-hold" and (.hold.hand_owner // "") != ""' <<< "$state" >/dev/null 2>&1 || return 0
  state_merge "$n" '.hold = (.hold | del(.hand_owner) | .durable_record = false)' || return 1
  record_json="$(state_read "$n" | jq -c '.hold')" || return 1
  hold_durable_record_publish "$n" "$record_json" || return 1
  state_merge "$n" '.hold.durable_record = true'
}

hold_durable_record_publish() {
  local n="$1" hold_json="$2" payload encoded marker issue_json="${3:-}" body
  payload="$(hold_durable_record_payload "$hold_json")" || return 2
  hold_durable_record_valid "$payload" || return 2
  encoded="$(jq -rn --argjson record "$payload" '$record | @base64')" || return 1
  marker="<!-- zf-hold-record-v1 issue=$n record=$encoded -->"
  [ -n "$issue_json" ] || issue_json="$(gh issue view "$n" --repo "$REPO" --json comments 2>/dev/null)" || return 1
  jq -e 'type == "object" and (.comments | type == "array")' <<< "$issue_json" >/dev/null 2>&1 || return 1
  hold_comment_has_marker "$issue_json" "$marker" && return 0
  body="$BOT_DISCLAIMER
Durable hold record: holder=$(jq -r '.holder' <<< "$payload"); kind=$(jq -r '.kind' <<< "$payload"); expiry=$(jq -r '.expires_at' <<< "$payload"); stage=$(jq -r '.stage_before' <<< "$payload"); release=$(jq -r '.release_condition' <<< "$payload")
$marker"
  guarded_issue_comment "$n" "$body"
}

hold_durable_record_from_issue() {
  local n="$1" issue_json="$2" prefix encoded decoded payload
  prefix="<!-- zf-hold-record-v1 issue=$n record="
  encoded="$(jq -r --arg prefix "$prefix" '
    [.comments[]? | (.body // "") | select(contains($prefix))
      | split($prefix)[1] | split(" -->")[0]] | last // empty
  ' <<< "$issue_json")" || return 2
  [ -n "$encoded" ] || return 1
  decoded="$(jq -Rr '@base64d' <<< "$encoded")" || return 2
  payload="$(hold_durable_record_payload "$decoded")" || return 2
  hold_durable_record_valid "$payload" || return 2
  printf '%s\n' "$payload"
}

hold_restore() {
  local n="$1" issue_json="${2:-}" state_json hold_json durable_record record_json status=0 stages stage_labels stage_before local_record_valid=0
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "hold_restore: valid issue number required" >&2; return 64; }
  [ -n "$issue_json" ] || issue_json="$(gh issue view "$n" --repo "$REPO" --json state,labels,comments 2>/dev/null)" || {
      echo "hold_restore: could not inspect #$n" >&2
      return 1
    }
  stages="$(printf '%s\n' "${ALL_STATE_LABELS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')" || return 1
  if ! jq -e --argjson stages "$stages" '
      (.state // "" | ascii_downcase) == "open"
      and (.labels | type == "array") and (.comments | type == "array")
      and any(.labels[]?; .name == "on-hold")
    ' <<< "$issue_json" >/dev/null 2>&1; then
    echo "hold_restore: #$n must be open and on-hold" >&2
    return 1
  fi
  state_json="$(state_read "$n")" || return 1
  hold_json="$(jq -c '.hold // {}' <<< "$state_json")" || return 1
  if hold_durable_record_valid "$hold_json"; then
    local_record_valid=1
    durable_record="$hold_json"
  else
    durable_record="$(hold_durable_record_from_issue "$n" "$issue_json")" || status=$?
    if [ "$status" -ne 0 ]; then
      echo "hold_restore: #$n has no exact durable hold record; issue left unchanged" >&2
      return 3
    fi
    hold_json="$durable_record"
  fi

  stage_before="$(jq -r '.stage_before' <<< "$durable_record")" || return 1
  stage_labels="$(jq -c --argjson stages "$stages" \
    '[.labels[]?.name | select(. as $label | ($stages | index($label)) != null)] | unique' \
    <<< "$issue_json")" || return 1
  if ! jq -e --arg stage "$stage_before" 'length == 0 or . == [$stage]' <<< "$stage_labels" >/dev/null 2>&1; then
    echo "hold_restore: #$n has stage labels that conflict with exact durable stage $stage_before; issue left unchanged" >&2
    return 1
  fi

  if (( local_record_valid )); then
    if jq -e '.durable_record == true' <<< "$hold_json" >/dev/null 2>&1; then
      echo "hold_restore: #$n already has complete durable hold metadata" >&2
      return 0
    fi
    if ! hold_durable_record_publish "$n" "$hold_json" "$issue_json" \
      || ! state_merge "$n" '.hold.durable_record = true'; then
      echo "hold_restore: could not persist complete local hold metadata for #$n" >&2
      return 1
    fi
    echo "hold_restore: #$n archived its complete local hold metadata" >&2
    return 0
  fi

  record_json="$(jq -c '. + {durable_record:true}' <<< "$durable_record")" || return 1
  if ! issue_transition "$n" on-hold hold-restore ".hold = $record_json"; then
    echo "hold_restore: could not restore durable hold metadata for #$n" >&2
    return 1
  fi
  echo "hold_restore: restored exact GitHub hold metadata for #$n" >&2
}

hold_hand_owner_name() {
  local holder="$1"
  if [[ "$holder" =~ (^|[^[:alnum:]_.-])(hand-[1-9][0-9]*)([^[:alnum:]_.-]|$) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  fi
}

hold_hand_owner_from_record() {
  local record="$1" owner holder
  owner="$(jq -r '.hand_owner // empty' <<< "$record" 2>/dev/null || true)"
  [[ "$owner" =~ ^hand-[1-9][0-9]*$ ]] && { printf '%s\n' "$owner"; return 0; }
  holder="$(jq -r '.holder // empty' <<< "$record" 2>/dev/null || true)"
  hold_hand_owner_name "$holder"
}

hold_hand_owner_report_is_recent() {
  local owner="$1" now_epoch="$2" cutoff report row pid name model effort worktree brief log attempt started_at role start_ticks issues nodes report_epoch
  cutoff=$((now_epoch - 10800))
  if [ -r "$NIGHT/agents.txt" ]; then
    while IFS= read -r row || [ -n "$row" ]; do
      [[ "$row" == *$'\t'* ]] || continue
      IFS=$'\x1f' read -r pid name model effort worktree brief report log attempt started_at role start_ticks issues nodes \
        <<< "${row//$'\t'/$'\x1f'}"
      [[ "$name" == "$owner" || "$name" == "$owner-"* ]] || continue
      case "$report" in "$NIGHT"/*) ;; *) continue ;; esac
      report_epoch="$(stat -c %Y -- "$report" 2>/dev/null || true)"
      [[ "$report_epoch" =~ ^[0-9]+$ ]] && [ "$report_epoch" -ge "$cutoff" ] && return 0
    done < "$NIGHT/agents.txt"
  fi
  for report in "$NIGHT/$owner-report"* "$NIGHT/$owner.report"* "$NIGHT/$owner-"*report*; do
    [ -f "$report" ] || continue
    report_epoch="$(stat -c %Y -- "$report" 2>/dev/null || true)"
    [[ "$report_epoch" =~ ^[0-9]+$ ]] && [ "$report_epoch" -ge "$cutoff" ] && return 0
  done
  return 1
}

hand_agent_role_is_supported() {
  local identity
  identity="$(model_policy identity "$1" 2>/dev/null)" || return 1
  case "$identity" in codex:*|zcode:*) return 0 ;; esac
  return 1
}

blocked_hand_agent_upsert() {
  local pid="$1" name="$2" role="$3" worktree="$4" brief_path="$5" report="$6" log="$7" attempt="$8" dependency="$9" start_ticks="${10}" owned_issues="${11}" owned_nodes="${12}"
  local dependency_override="${13:-}" item tmp dependency_satisfied=false
  local night_dir="${ZF_NIGHT_DIR:-$AGENT_HOME/night}" blocked_file="${BLOCKED_HAND_AGENTS:-${ZF_NIGHT_DIR:-$AGENT_HOME/night}/blocked-hand-agents.json}"
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$attempt" =~ ^[0-9]+$ && "$name" =~ ^[[:alnum:]_.-]+$ ]] || return 1
  hand_agent_role_is_supported "$role" || return 1
  case "$dependency" in *$'\t'*|*$'\n'*) return 1 ;; esac
  if [[ "$dependency_override" == true || "$dependency_override" == false ]]; then
    dependency_satisfied="$dependency_override"
  elif declare -F blocked_hand_agent_dependency_landed >/dev/null && blocked_hand_agent_dependency_landed "$dependency"; then
    dependency_satisfied=true
  fi
  mkdir -p -- "$(dirname -- "$blocked_file")" || return 1
  [ -f "$blocked_file" ] || printf '[]\n' > "$blocked_file"
  jq -e 'type=="array"' "$blocked_file" >/dev/null 2>&1 || return 1
  item="$(jq -cn --argjson pid "$pid" --arg name "$name" --arg role "$role" \
    --arg worktree "$worktree" --arg brief "$brief_path" --arg report "$report" --arg log "$log" \
    --argjson attempt "$attempt" --arg dependency "$dependency" --arg start_ticks "$start_ticks" \
    --arg owned_issues "$owned_issues" --arg owned_nodes "$owned_nodes" --argjson dependency_satisfied "$dependency_satisfied" \
    --argjson blocked_at "$(date +%s)" \
    '{pid:$pid,name:$name,role:$role,worktree:$worktree,brief:$brief,report:$report,log:$log,attempt:$attempt,dependency:$dependency,dependency_satisfied:$dependency_satisfied,start_ticks:$start_ticks,owned_issues:$owned_issues,owned_nodes:$owned_nodes,blocked_at:$blocked_at}')" || return 1
  tmp="$(mktemp "${night_dir}/.blocked-hand-agents.XXXXXX")" || return 1
  jq --argjson item "$item" 'map(select(.name != $item.name)) + [$item]' "$blocked_file" > "$tmp" \
    && mv -- "$tmp" "$blocked_file" || { rm -f -- "$tmp"; return 1; }
  if declare -F say >/dev/null; then
    say "HAND-AGENT-BLOCKED-RECORDED $name dependency=$dependency"
  else
    printf '%s HAND-AGENT-BLOCKED-RECORDED %s dependency=%s\n' "$(date -u +%FT%TZ)" "$name" "$dependency" >> "$night_dir/night.log"
  fi
}

hold_hand_owner_is_live() {
  local owner="$1" now_epoch="$2" units unit_status=0 lib_dir row pid name model effort worktree brief report log attempt started_at role start_ticks issues nodes
  if ! declare -F hand_agent_pid_live >/dev/null; then
    lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 2
    source "$lib_dir/night/hand-agent-watchdog.sh" || return 2
  fi
  if [ -r "$NIGHT/agents.txt" ]; then
    while IFS= read -r row || [ -n "$row" ]; do
      [[ "$row" == *$'\t'* ]] || continue
      IFS=$'\x1f' read -r pid name model effort worktree brief report log attempt started_at role start_ticks issues nodes \
        <<< "${row//$'\t'/$'\x1f'}"
      [[ "$name" == "$owner" || "$name" == "$owner-"* ]] || continue
      [[ "$pid" =~ ^[1-9][0-9]*$ && "$start_ticks" =~ ^[0-9]+$ ]] || continue
      hand_agent_pid_live "$pid" "$start_ticks" && return 0
    done < "$NIGHT/agents.txt"
  fi
  if units="$(systemctl --user list-units --state=active --no-legend --no-pager "zf-hand-$owner-*" 2>/dev/null)"; then
    if awk -v prefix="zf-hand-$owner-" 'index($1, prefix) == 1 { found = 1 } END { exit !found }' <<< "$units"; then
      return 0
    fi
  else
    unit_status=2
  fi
  hold_hand_owner_report_is_recent "$owner" "$now_epoch" && return 0
  [ "$unit_status" -eq 0 ] && return 1
  return 2
}

hold_sweep_age_notice() {
  local n="$1" state_json="$2" hold_json="$3" now_epoch="$4" holder kind created_at created_epoch age_seconds window last_window age_hours
  kind="$(jq -r '.kind // empty' <<< "$hold_json")"
  [[ "$kind" == supervisor || "$kind" == manual ]] || return 0
  created_at="$(jq -r '.created_at // empty' <<< "$hold_json")"
  [ -n "$created_at" ] || return 0
  created_epoch="$(agent_epoch -u "$created_at" 2>/dev/null || true)"
  [[ "$created_epoch" =~ ^[0-9]+$ ]] && [ "$created_epoch" -le "$now_epoch" ] || return 0
  age_seconds=$((now_epoch - created_epoch))
  (( age_seconds >= 172800 )) || return 0
  window=$((age_seconds / 172800))
  last_window="$(jq -r '.hold.aging_window // 0' <<< "$state_json")"
  [[ "$last_window" =~ ^[0-9]+$ ]] || last_window=0
  (( window > last_window )) || return 0
  holder="$(jq -r '.holder // "unknown"' <<< "$hold_json" | tr '\r\n\t' '   ')"
  age_hours=$((age_seconds / 3600))
  supervisor_inbox_append_once "hold-aging:$n:$window" \
    "hold-aging issue=#$n holder=$holder kind=$kind age=${age_hours}h" || return 1
  state_merge "$n" ".hold.aging_window = $window"
}

hold_sweep() {
  local NIGHT="${ZF_NIGHT_DIR:-$AGENT_HOME/night}"
  local held_numbers live_hold_numbers numbers n issue_json state_json hold_json holder release_condition expires_at kind hand_owner owner_status dead_owner
  local stage now_epoch expiry_epoch marker body record_json expiry_at renewal_expiry hold_created_at state_path state_label_json live_stage_labels durable_record
  local routing_stage inbox_key github_state handoff_patch
  local failure=0
  if ! held_numbers="$(gh issue list --repo "$REPO" --state open --label on-hold --limit 1000 --json number)"; then
    echo "hold_sweep: could not list open on-hold issues" >&2
    return 1
  fi
  if ! jq -e 'type == "array" and all(.[]; (.number | type) == "number")' \
      <<< "$held_numbers" >/dev/null 2>&1; then
    echo "hold_sweep: invalid issue list response" >&2
    return 1
  fi
  live_hold_numbers="$(jq -r '.[].number' <<< "$held_numbers")" || return 1
  numbers="$live_hold_numbers"
  for state_path in "$STATE_DIR"/*.json; do
    [ -f "$state_path" ] || continue
    [ "$(jq -r '.state // empty' "$state_path" 2>/dev/null || true)" = on-hold ] || continue
    n="${state_path##*/}"
    n="${n%.json}"
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || continue
    grep -Fxq "$n" <<< "$numbers" || numbers="${numbers}${numbers:+$'\n'}$n"
  done
  numbers="$(printf '%s\n' "$numbers" | LC_ALL=C sort -u)" || return 1
  state_label_json="$(printf '%s\n' "${ALL_STATE_LABELS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')" || return 1
  now_epoch="$(date -u +%s)" || return 1
  while IFS= read -r n; do
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || continue
    state_json="$(state_read "$n")" || { failure=1; continue; }
    hold_json="$(jq -c '.hold // {}' <<< "$state_json" 2>/dev/null)"
    kind="$(jq -r '.kind // empty' <<< "$hold_json")"
    if ! grep -Fxq "$n" <<< "$live_hold_numbers"; then
      [ "$(jq -r '.state // empty' <<< "$state_json")" = on-hold ] || continue
      if ! issue_json="$(gh issue view "$n" --repo "$REPO" --json state,stateReason,closedAt,labels,comments,title 2>/dev/null)"; then
        echo "hold_sweep: could not inspect state-only held #$n; leaving state untouched" >&2
        failure=1
        continue
      fi
      if ! jq -e '(.state | type) == "string" and (.labels | type) == "array" and all(.labels[]; (.name | type) == "string")
          and ((.stateReason == null) or (.stateReason | type == "string"))
          and ((.closedAt == null) or (.closedAt | type == "string"))' \
          <<< "$issue_json" >/dev/null 2>&1; then
        echo "hold_sweep: invalid issue state or labels for state-only held #$n; leaving state untouched" >&2
        failure=1
        continue
      fi
      github_state="$(jq -r '.state | ascii_downcase' <<< "$issue_json")"
      if [ "$github_state" = closed ]; then
        if ! issue_reconcile_closed_state "$n" "$issue_json"; then
          echo "hold_sweep: could not reconcile closed hold for #$n" >&2
          failure=1
          continue
        fi
        echo "hold_sweep: reconciled closed hold for #$n" >&2
        continue
      fi
      # The advisor owns open holds and their escalation cadence.
      [ "$kind" != supervisor-inbox ] || continue
      [ "$github_state" = open ] || continue
      if jq -e 'any(.labels[]; .name == "on-hold")' <<< "$issue_json" >/dev/null 2>&1; then
        continue
      fi
      live_stage_labels="$(jq -c --argjson stage_labels "$state_label_json" \
        '[.labels[]?.name | select(. as $label | ($stage_labels | index($label)) != null)] | unique' \
        <<< "$issue_json")" || { failure=1; continue; }
      case "$(jq 'length' <<< "$live_stage_labels")" in
        0) stage="$(hold_stage_before "$state_json" "$issue_json")" || { failure=1; continue; } ;;
        1) stage="$(jq -r '.[0]' <<< "$live_stage_labels")" ;;
        *)
          if jq -e '.durable_record == true' <<< "$hold_json" >/dev/null 2>&1 \
            && hold_durable_record_valid "$hold_json"; then
            stage="$(jq -r '.stage_before' <<< "$hold_json")" || { failure=1; continue; }
            echo "hold_sweep: reconciling released #$n from durable stage=$stage despite stale labels" >&2
          else
            echo "hold_sweep: ambiguous live stage labels for released #$n; leaving state untouched" >&2
            failure=1
            continue
          fi
          ;;
      esac
      if ! issue_transition_allowed on-hold "$stage" hold-release; then
        echo "hold_sweep: unsafe stage '$stage' for released #$n; leaving state untouched" >&2
        failure=1
        continue
      fi
      if ! issue_transition "$n" "$stage" hold-release; then
        echo "hold_sweep: could not reconcile released hold for #$n" >&2
        failure=1
        continue
      fi
      echo "hold_sweep: reconciled manually released hold for #$n at stage=$stage" >&2
      continue
    fi
    # Durable metadata lets the common case avoid a GitHub comments read.
    if hold_durable_record_valid "$hold_json" \
      && jq -e '.durable_record == true' <<< "$hold_json" >/dev/null 2>&1; then
      holder="$(jq -r '.holder' <<< "$hold_json")"
      hand_owner="$(hold_hand_owner_from_record "$hold_json")"
      dead_owner=""
      if [ -n "$hand_owner" ]; then
        owner_status=0
        hold_hand_owner_is_live "$hand_owner" "$now_epoch" || owner_status=$?
        [ "$owner_status" -ne 1 ] || dead_owner="$hand_owner"
      fi
      if [ -z "$dead_owner" ] && jq -e --argjson now "$now_epoch" \
        '(.expires_at | fromdateiso8601) > $now' <<< "$hold_json" >/dev/null 2>&1; then
        hold_sweep_age_notice "$n" "$state_json" "$hold_json" "$now_epoch" || failure=1
        continue
      fi
    fi
    if ! issue_json="$(gh issue view "$n" --repo "$REPO" --json state,labels,comments,title 2>/dev/null)"; then
      echo "hold_sweep: could not inspect #$n; leaving hold untouched" >&2
      failure=1
      continue
    fi
    if ! jq -e '(.state // "" | ascii_downcase) == "open" and (.labels | type == "array") and (.comments | type == "array") and any(.labels[]?; .name == "on-hold")' \
        <<< "$issue_json" >/dev/null 2>&1; then
      continue
    fi
    if ! jq -e '.durable_record == true' <<< "$hold_json" >/dev/null 2>&1 \
      || ! hold_durable_record_valid "$hold_json"; then
      status=0
      hold_restore "$n" "$issue_json" || status=$?
      if [ "$status" -eq 3 ]; then
        kind="$(jq -r '.kind // "unknown"' <<< "$hold_json")"
        holder="$(jq -r '.holder // "missing"' <<< "$hold_json")"
        inbox_key="ownerless-hold:#$n"
        if ! supervisor_inbox_append_once "$inbox_key" \
          "ownerless-hold issue=#$n kind=$kind holder=$holder action=restore-an-exact-GitHub-hold-record-or-verify-metadata-before-release"; then
          failure=1
        fi
        echo "hold_sweep: #$n is ownerless; no exact durable hold record, leaving on-hold unchanged" >&2
        continue
      elif [ "$status" -ne 0 ]; then
        echo "hold_sweep: could not restore durable hold record for #$n" >&2
        failure=1
        continue
      fi
      state_json="$(state_read "$n")" || { failure=1; continue; }
      hold_json="$(jq -c '.hold' <<< "$state_json")" || { failure=1; continue; }
    fi
    kind="$(jq -r '.kind // empty' <<< "$hold_json")"
    # The advisor owns these holds and their escalation cadence.
    [ "$kind" != supervisor-inbox ] || continue
    holder="$(jq -r '.holder' <<< "$hold_json")"
    release_condition="$(jq -r '.release_condition' <<< "$hold_json")"
    expires_at="$(jq -r '.expires_at' <<< "$hold_json")"
    hold_sweep_age_notice "$n" "$state_json" "$hold_json" "$now_epoch" || failure=1
    hand_owner="$(hold_hand_owner_from_record "$hold_json")"
    dead_owner=""
    if [ -n "$hand_owner" ]; then
      owner_status=0
      hold_hand_owner_is_live "$hand_owner" "$now_epoch" || owner_status=$?
      [ "$owner_status" -ne 1 ] || dead_owner="$hand_owner"
    fi
    if [ -n "$dead_owner" ]; then
      kind="$(jq -r '.kind // empty' <<< "$hold_json")"
      case "$kind" in
        external-deliverable|ops-acceptance-after-release|pipeline-system-fastlane|guarded-recut-repeat|hand-dispatch|supervisor-hand|blocked-on-resolution)
          scheduler_requeue_issue "$n" "hold owner $dead_owner is inactive" "$issue_json" "" "" "" . "" "$hold_json" || failure=1
          continue ;;
      esac
      stage="$(jq -r '.stage_before // empty' <<< "$hold_json")"
      if ! hold_stage_label_is_valid "$stage"; then
        stage="$(hold_stage_before "$state_json" "$issue_json")" || { failure=1; continue; }
      fi
      hold_created_at="$(jq -r '.created_at // .expires_at' <<< "$hold_json")"
      marker="<!-- zf-hold-dead-owner issue=$n owner=$dead_owner hold=$hold_created_at -->"
      if ! hold_comment_has_marker "$issue_json" "$marker"; then
        body="$BOT_DISCLAIMER
Hold released because hand agent $dead_owner is inactive: no active systemd unit or report newer than 3 hours. Resuming at stage $stage.
$marker"
        if ! guarded_issue_comment "$n" "$body"; then
          echo "hold_sweep: could not record dead owner $dead_owner for #$n; leaving hold untouched" >&2
          failure=1
          continue
        fi
      fi
      handoff_patch='.'
      if [ "$stage" = ready-for-agent ]; then
        scheduler_requeue_issue "$n" "hold owner $dead_owner is inactive" "$issue_json" "" "hold-$hold_created_at" "" . "" "$hold_json" || failure=1
        continue
      fi
      if ! issue_transition "$n" "$stage" hold-dead-owner "$handoff_patch" 0 "" "" 0 "$hold_json"; then
        echo "hold_sweep: could not release dead-owner hold for #$n" >&2
        failure=1
        continue
      fi
      continue
    fi
    if ! expiry_epoch="$(agent_epoch -u "$expires_at" 2>/dev/null)"; then
      echo "hold_sweep: invalid expiry in hold record for #$n; leaving hold untouched" >&2
      failure=1
      continue
    fi
    (( expiry_epoch <= now_epoch )) || continue
    kind="$(jq -r '.kind // empty' <<< "$hold_json")"
    renewal_reason=""
    if [ "$kind" = pipeline-system-fastlane ] && [ "$holder" = "hand-$n" ]; then
      if supervisor_hold_owner_state "$n"; then
        case "$SUPERVISOR_HOLD_OWNER_STATE" in
          queued|running|blocked|worktree-live) renewal_reason="while the pipeline-system hand owner remains active" ;;
        esac
      else
        owner_status=$?
        if ((owner_status != 1)); then
          echo "hold_sweep: could not confirm pipeline-system hand owner for #$n; leaving hold untouched: $SUPERVISOR_HOLD_OWNER_DETAIL" >&2
          failure=1
          continue
        fi
      fi
    elif { [ "$kind" = label-churn ] && [ "$holder" = detect-label-churn ]; } \
      || { [ "$kind" = repeat-cap ] && [ "$holder" = implement-repeat-cap ]; }; then
      hand_name="hand-$n"
      hand_root="${ZF_WORKTREE_ROOT:-$HOME/wt}"
      hand_wt="$hand_root/$hand_name"
      if supervisor_hand_owner_status "$hand_name" "$hand_wt"; then
        renewal_reason="while the hand agent owns the ticket"
      else
        owner_status=$?
        if ((owner_status != 1)); then
          echo "hold_sweep: could not confirm hand owner for #$n; leaving hold untouched: $SUPERVISOR_HAND_OWNER_ERROR" >&2
          failure=1
          continue
        fi
      fi
    # The hot-fix mechanism closed on 2026-10-04. Holds it left behind keep renewing until the supervisor hands
    # each issue back to the pipeline (hand-hotfix-sort); delete this branch and is_hotfix_lane_issue then.
    elif [ "$kind" = hotfix-lane ] && is_hotfix_lane_issue "$issue_json"; then
      renewal_reason="while the issue remains marked for the hot-fix lane"
    fi
    if [ -n "$renewal_reason" ]; then
      renewal_expiry="$(hold_expiry_resolve 168h)" || { failure=1; continue; }
      if ! (
        f="$(state_file "$n")" || exit 1
        exec {hold_lock_fd}>"$f.lock" && flock -x "$hold_lock_fd" || exit 1
        current="$(state_read "$n")" || exit 1
        jq -e --argjson expected "$hold_json" '.state == "on-hold" and (.hold | del(.aging_window)) == ($expected | del(.aging_window))' <<< "$current" >/dev/null || exit 1
        marker="<!-- zf-hold-renewed issue=$n expires=$expires_at -->"
        if ! hold_comment_has_marker "$issue_json" "$marker"; then
          body="$BOT_DISCLAIMER
Hold renewed for 168 hours $renewal_reason. Holder: $holder; next expiry: $renewal_expiry.
$marker"
          guarded_issue_comment "$n" "$body" || exit 1
        fi
        record_json="$(jq -c --arg expires "$renewal_expiry" '.expires_at = $expires | .durable_record = false' <<< "$hold_json")" || exit 1
        state_merge "$n" ".hold = $record_json" __issue_transition_lock_held \
          && hold_durable_record_publish "$n" "$record_json" "$issue_json" \
          && state_merge "$n" '.hold.durable_record = true' __issue_transition_lock_held
      ); then
        echo "hold_sweep: could not renew hold for #$n" >&2
        failure=1
      fi
      continue
    fi
    case "$kind" in
      external-deliverable|ops-acceptance-after-release|pipeline-system-fastlane|guarded-recut-repeat|hand-dispatch|supervisor-hand|blocked-on-resolution)
        scheduler_requeue_issue "$n" "hold expired; $release_condition" "$issue_json" "" "" "" . "" "$hold_json" || failure=1
        continue ;;
    esac
    stage="$(jq -r '.stage_before // empty' <<< "$hold_json")"
    if ! hold_stage_label_is_valid "$stage"; then
      stage="$(hold_stage_before "$state_json" "$issue_json")" || { failure=1; continue; }
    fi
    marker="<!-- zf-hold-expired issue=$n expires=$expires_at -->"
    if ! hold_comment_has_marker "$issue_json" "$marker"; then
      body="$BOT_DISCLAIMER
Hold expired. Holder: $holder. Release condition was not met: $release_condition. Resuming at stage $stage.
$marker"
      if ! guarded_issue_comment "$n" "$body"; then
        echo "hold_sweep: could not record expiry for #$n; leaving hold untouched" >&2
        failure=1
        continue
      fi
    fi
    # Reset the attempt budget in the same locked transition as the release.
    handoff_patch='.attempts = 0 | if .pipeline_system.enabled == true then if ((.pipeline_system.resume_artifact_sha // "") | test("^[0-9a-f]{40,64}$")) then .pipeline_system.resume_artifact_attempt = .attempts else del(.pipeline_system.resume_artifact_sha, .pipeline_system.resume_artifact_attempt) end else . end'
    if [ "$stage" = ready-for-agent ]; then
      hold_created_at="$(jq -r '.created_at // .expires_at' <<< "$hold_json")"
      scheduler_requeue_issue "$n" "hold expired; $release_condition" "$issue_json" "" "hold-$hold_created_at" "" "$handoff_patch" "" "$hold_json" || failure=1
      continue
    fi
    if ! issue_transition "$n" "$stage" hold-expired "$handoff_patch" 0 "" "" 0 "$hold_json"; then
      echo "hold_sweep: could not release expired hold for #$n" >&2
      failure=1
      continue
    fi
  done <<< "$numbers"
  [ "$failure" -eq 0 ]
}

# Operator-selected answer: refresh roadmap context outside the scheduler, then
# use the same serialized requeue. The patch checks the hold episode under the
# transition lock, so a new decision request cannot consume an older answer.
hold_answer() (
  local n="${1:-}" comment_id="${2:-}" state requested hold_created comment answer patch
  [[ "$n" =~ ^[1-9][0-9]*$ && "$comment_id" =~ ^[1-9][0-9]*$ ]] || return 64
  state="$(state_read "$n")" || return 1
  jq -e '.state == "on-hold" and .hold.holder == "supervisor-inbox"
    and .hold.kind == "conclusion" and .hold.stage_before == "ready-for-agent"
    and .implement_decision.route == "supervisor-inbox"
    and (.implement_decision.requested_at // "") != ""' <<< "$state" >/dev/null || {
    echo "hold_answer: #$n has no pending implement supervisor decision" >&2
    return 1
  }
  requested="$(jq -r '.implement_decision.requested_at' <<< "$state")" || return 1
  hold_created="$(jq -r '.hold.created_at' <<< "$state")" || return 1
  comment="$(gh api "repos/$REPO/issues/comments/$comment_id")" || return 1
  answer="$(jq -ce --arg issue_url "https://api.github.com/repos/$REPO/issues/$n" \
    --arg requested "$requested" --argjson id "$comment_id" '
    select(.id == $id and .issue_url == $issue_url and .author_association == "OWNER"
      and ((.created_at | fromdateiso8601) >= ($requested | fromdateiso8601))
      and (.body | type == "string" and test("\\S")))
    | {id, url:.html_url, body, created_at, applied_at:(now|todate)}' <<< "$comment")" || {
    echo "hold_answer: comment $comment_id is not a fresh owner answer on #$n" >&2
    return 1
  }
  patch="$(jq -nr --arg requested "$requested" --arg created "$hold_created" --argjson answer "$answer" '
    "if .state == \"on-hold\" and .hold.holder == \"supervisor-inbox\" and .hold.kind == \"conclusion\""
    + " and .hold.created_at == " + ($created|tojson)
    + " and .implement_decision.requested_at == " + ($requested|tojson)
    + " then .implement_decision.answer = " + ($answer|tojson)
    + " | .brief_md = ((.brief_md // \"\" | gsub(\"(?s)<!-- ZF_SUPERVISOR_WORKFLOW_DECISION:BEGIN -->.*?<!-- ZF_SUPERVISOR_WORKFLOW_DECISION:END -->\"; \"\")) + "
    + ("\n\n<!-- ZF_SUPERVISOR_WORKFLOW_DECISION:BEGIN -->\n## Supervisor workflow decision (automated engineering guidance; not maintainer-authored facts or authority)\nSource: "
       + $answer.url + "\n\n" + $answer.body + "\n<!-- ZF_SUPERVISOR_WORKFLOW_DECISION:END -->" | tojson) + ")"
    + " else error(\"supervisor decision episode changed\") end"')" || return 1
  state_requeue "$n" release-hold hold-requeue "$patch"
)

hold_cli_main() {
  if [ "${1:-}" = --sweep ]; then
    shift
    (($# == 0)) || { echo "usage: hold.sh --sweep" >&2; return 64; }
    hold_sweep
  elif [ "${1:-}" = --hold ]; then
    shift
    (($# >= 1)) || { echo "usage: hold.sh --hold <issue> --holder <name> --release <condition> --expires <duration>" >&2; return 64; }
    hold_issue "$@"
  elif [ "${1:-}" = --restore ]; then
    (($# == 2)) || { echo "usage: hold.sh --restore <issue>" >&2; return 64; }
    hold_restore "$2"
  elif [ "${1:-}" = --answer ]; then
    (($# == 4)) && [ "$3" = --comment ] || { echo "usage: hold.sh --answer <issue> --comment <id>" >&2; return 64; }
    hold_answer "$2" "$4"
  else
    hold_issue "$@"
  fi
}

state_attempts() { state_read "$1" | jq -r '.attempts // 0'; }

# state_requeue <n> -- start a new implement episode for an issue.
# Keep the state reset and queue-label transition together so a requeue cannot
# leave the old conclude rung attached to fresh work.
# state_requeue N [release-hold]: release-hold also removes on-hold in the same write, the
# hold guard's release transition; without it a held issue's requeue is suppressed.
state_requeue() {
  local n="$1" release_hold="${2:-}" reason="${3:-}" patch="${4:-.}" expected_hold="${5:-}" initial initial_json filter child_status=1
  [ -n "$reason" ] || { [ "$release_hold" = release-hold ] && reason=hold-requeue || reason=pipeline-requeue; }
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "state_requeue: invalid issue number '$n'" >&2; return 64; }
  if recut_parent_has_open_child "$n" "${OPEN_ISSUE_BLOCKER_GRAPH_JSON:-[]}" "" 0; then child_status=0; else child_status=$?; fi
  case "$child_status" in
    0)
      if [ "$release_hold" = release-hold ]; then
        retire_tracker_parent "$n"
        return $?
      fi
      echo "state_requeue: keeping parent #$n out of ready-for-agent while children remain open" >&2
      return 0
      ;;
    2) echo "state_requeue: cannot verify children for #$n; refusing ready-for-agent" >&2; return 1 ;;
  esac
  initial="$(model_policy initial-step)" || return 1
  initial_json="$(jq -nc --arg step "$initial" '$step')" || return 1
  filter="$patch | .model_policy as \$old | .attempts = 0 | .requeued_at = (now | todate) | .model_policy = {unit:\"implement\",step:$initial_json,history:((\$old.history // []) + (if ((\$old.unit // \"\") != \"\" or (\$old.step // \"\") != \"\") then [{unit:\$old.unit,step:\$old.step,failure:\$old.failure,advisor_decision:\$old.advisor_decision,completed_at:(now|todate),requeued:true}] else [] end))}"
  [ "$release_hold" != release-hold ] || filter+=" | .hold = null | .hold_released_at = (now | todate)"
  issue_transition "$n" ready-for-agent "$reason" "$filter" 0 "" "" 0 "$expected_hold" || return $?
  if [ "$release_hold" = release-hold ] && [[ "${ZF_AGENT_NAME:-}" =~ ^(supervisor|hand-) ]]; then
    local resume_row
    resume_row="$(jq -cn --argjson issue "$n" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" '
      {schema_version:1,record_type:"event",event_type:"attempt-resumed",issue:$issue,ts:$ts,
       retry_reason:"supervisor-resume",event_id:($ts+"|resume|"+($issue|tostring))}')" || return 1
    efficiency_metrics_append_rows "$resume_row" || return 1
  fi
}

refund_implement_attempt() {
  state_merge_attempt_transition "$1" '.attempts = (if (.attempts // 0) > 0 then (.attempts - 1) else 0 end)'
}

# conclusion_classification_for_state <issue> <state-json> <needs-md>
# Returns the stable class, route, and owner written before a terminal ticket
# becomes visible to the next issue-pipeline sweep.
conclusion_classification_for_state() {
  local n="$1" state="$2" needs_md="${3:-}" target_outcome="${4:-}" started since env_row env_epoch env_event='null' env_signature="" env_reason="" env_scope="" env_at="" ledger row
  local ticket_route=requeue ticket_owner=implement classification_status risk_class level needs_file classified_json
  started="$(jq -r '.run.implement_started_at // empty' <<< "$state")"
  if [ -n "$started" ]; then
    since="$(agent_epoch "$started" 2>/dev/null || echo 0)"
    for ledger in "$ENV_FAULT_DIR"/*.log; do
      [ -f "$ledger" ] || continue
      row="$(awk -F '\t' -v issue="$n" -v since="$since" \
        '$1 >= since && $3 == issue && $2 ~ /^implement(@|$)/ { latest=$0 } END { print latest }' "$ledger")"
      [ -n "$row" ] || continue
      env_epoch="${row%%$'\t'*}"
      [[ "$env_epoch" =~ ^[0-9]+$ ]] || continue
      if [ -z "$env_at" ] || [ "$env_epoch" -gt "$env_at" ]; then
        env_at="$env_epoch"
        env_scope="$(cut -f2 <<< "$row")"
        env_signature="$(cut -f4 <<< "$row")"
        env_reason="$(cut -f5 <<< "$row")"
      fi
    done
    if [ -n "$env_at" ]; then
      env_event="$(jq -cn --arg signature "$env_signature" --arg reason "$env_reason" --arg scope "$env_scope" \
        --arg recorded_at "$(date -u -d "@$env_at" +%Y-%m-%dT%H:%M:%SZ)" \
        '{type:"env-fault",signature:$signature,reason:$reason,scope:$scope,recorded_at:$recorded_at}')"
    fi
  fi

  classification_status="$(triage_classification_status "$STATE_DIR/$n.json")"
  if [ "$classification_status" = measured ]; then
    risk_class="$(jq -r '.risk_class // empty' <<< "$state")"
    level="$(jq -r '.level // empty' <<< "$state")"
    if recut_categorically_oversized "$risk_class" "$level"; then
      ticket_route=recut
      ticket_owner=recut
    fi
  fi

  needs_file="$(jq_arg_file "$needs_md")" || return 1
  # State goes on stdin: issue state files pass 128 KiB, the per-argument limit, and --argjson then
  # failed with "Argument list too long" (2026-10-10: issues 1820/1952/1970/2144 could not conclude).
  if ! classified_json="$(jq -c --argjson env "$env_event" --rawfile needs "$needs_file" --arg outcome "$target_outcome" \
    --arg ticket_route "$ticket_route" --arg ticket_owner "$ticket_owner" '
    (. as $s
     | ($s.run.implement_started_at // $s.requeued_at // "") as $boundary
     | ([ $s.model_policy.retry_note?, $s.model_policy.failure?, ($s.model_policy.failures[]?) ]
        | map(select(type == "object" and (.recorded_at // "") != "" and ($boundary == "" or .recorded_at >= $boundary)))) as $policy_events
     | ($policy_events | sort_by(.recorded_at) | last // {}) as $policy
     | ($s.unit_results.implement // {}) as $unit
     | (if (($unit.result // "") | IN("oom-kill","timeout","watchdog","start-limit-hit"))
        then {type:"unit-result",reason:("systemd Result=" + $unit.result),recorded_at:($unit.recorded_at // "")}
        else {} end) as $unit_fault
     | ([$policy, $unit_fault, $env] | map(select(type == "object" and (.recorded_at // "") != "")) | sort_by(.recorded_at) | last // {}) as $latest
     | ($latest.reason // $needs // $s.last_failure_reason // "") as $reason
     | ($reason | ascii_downcase) as $reason_text
     | (if $latest.type == "env-fault" then $latest.signature
        elif $latest.type == "unit-result" then ($latest.reason | gsub("[^A-Za-z0-9=.-]"; "-"))
        elif $latest.signature == "pipeline-system-delivery-failed" then $latest.signature
        elif $latest.stage == "role-identity" or (($latest.status // 0) == 64 and ($reason_text | test("identity|role"))) then "model-role-identity-rejected"
        elif ($reason_text | test("(high|critical).*(blast radius|impact).*(stop|halt)|(blast radius|impact).*(high|critical).*(stop|halt)")) then "implement-impact-level-stop"
        elif ($reason_text | test("previous (model|implement|policy) unit .*without recording a result|no persisted systemd result")) then "unit-result-not-recorded"
        else "" end) as $signature
     | (if $s.run.disposition == "not-planned" or $s.run.close_as_not_planned == true or $s.run.outcome == "not-planned"
        then {class:"ticket",route:"close-not-planned",owner:"closed",signature:"not-planned",reason:$reason}
        elif $signature == "pipeline-system-delivery-failed"
        then {class:"pipeline-defect",route:"requeue",owner:"supervisor-inbox",signature:$signature,reason:$reason}
        elif $s.pipeline_system.enabled == true
        then {class:"ticket",route:"requeue",owner:"issue-pipeline",signature:"pipeline-system-requeue",reason:$reason}
        elif (($s.run.outcome // $outcome // "") == "" or ($s.run.outcome // $outcome // "") == "unknown")
        then {class:"ticket",route:"needs-info",owner:"reporter",signature:"missing-conclusion-outcome",reason:"No terminal outcome was recorded; please confirm the intended result."}
        elif $signature == "model-role-identity-rejected" or $signature == "implement-impact-level-stop" or $signature == "unit-result-not-recorded"
        then {class:"pipeline-defect",route:"requeue",owner:"supervisor-inbox",signature:$signature,reason:$reason}
        elif ($latest.attempt_refunded == true)
          or ($latest.type == "env-fault")
          or ($latest.type == "unit-result")
          or ($reason_text | test("ci runner capacity|ci deadline|merge-lock contention|provider quota|provider outage|network fault|docker hub dns/connect timeout|checkout step failed before project checks|systemd result=(oom-kill|timeout|watchdog|start-limit-hit)"))
        then {class:"infrastructure",route:"requeue",owner:"issue-pipeline",signature:(if ($signature | length) > 0 then $signature else "infrastructure-precondition" end),reason:$reason,scope:($latest.scope // null)}
        elif $s.review_verdict == "INPUT_INCOMPLETE"
          or ($reason_text | test("product decision|input[_ -]+incomplete|missing .*decision|permission stage|risk_class=|level="))
        then {class:"ticket",route:"needs-info",owner:"reporter",signature:"product-input-incomplete",reason:$reason}
        elif $s.concluded_blocker_recovery.last_action == "needs-advisor"
        then {class:"ticket",route:"needs-info",owner:"reporter",signature:"advisor-route-retry",reason:$reason}
        elif ($s.recut_refused_at // "") != ""
        then {class:"ticket",route:"needs-info",owner:"reporter",signature:"recut-refused",reason:$reason}
        else {class:"ticket",route:$ticket_route,owner:$ticket_owner,signature:"ticket-code-or-scope-failure",reason:$reason}
        end)
    )' <<< "$state")"; then
    rm -f -- "$needs_file"
    return 1
  fi
  rm -f -- "$needs_file"
  printf '%s\n' "$classified_json"
}

pipeline_system_issue_labels_json() {
  local rulings_file
  rulings_file="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/state/rulings.json"
  jq -ce '[.rulings[] | select(.id == "nonproduct-lane-routing") | .membership.labels[]?] | unique | select(length > 0 and all(.[]; type == "string" and length > 0))' "$rulings_file"
}

pipeline_system_issue_matches() {
  local issue_json="$1" labels_json
  jq -e 'type == "object" and (.labels | type == "array")' <<< "$issue_json" >/dev/null 2>&1 || return 2
  labels_json="$(pipeline_system_issue_labels_json)" || return 2
  jq -e --argjson lane_labels "$labels_json" \
    'any(.labels[]?; .name as $lane_label | ($lane_labels | index($lane_label)) != null)' \
    <<< "$issue_json" >/dev/null 2>&1
}

pipeline_system_return_to_product() {
  local n="$1" labels_json label
  local -a edit_args=(gh issue edit "$n" --repo "$REPO")
  labels_json="$(pipeline_system_issue_labels_json)" || return 1
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    edit_args+=(--remove-label "$label")
  done < <(jq -r '.[]' <<< "$labels_json")
  [ "${#edit_args[@]}" -gt 6 ] || return 1
  guarded_write "${edit_args[@]}" || return 1
  state_merge "$n" '.pipeline_system.product_ruling = {classification:"product-path",classified_at:(now|todate)} | del(.pipeline_system.enabled)' \
    || return 1
}

pipeline_system_route_status() {
  local n="$1" issue_json status=0
  # Live labels define membership; persisted state and caller snapshots can
  # outlive a reclassification. The blocker-root sweep passes "fresh" with the
  # labels it read from GitHub in the same pass: re-reading them cost ~1.3s per
  # root and starved implement of its whole scan budget (2026-09-30).
  PIPELINE_SYSTEM_ROUTE_ISSUE_JSON=""
  if [ "${3:-}" = fresh ] && [ -n "${2:-}" ]; then
    issue_json="$2"
  else
    issue_json="$(gh issue view "$n" --repo "$REPO" --json number,labels)" || return 2
  fi
  PIPELINE_SYSTEM_ROUTE_ISSUE_JSON="$issue_json"
  pipeline_system_issue_matches "$issue_json" || status=$?
  case "$status" in
    0) return 0 ;;
    1)
      if state_read "$n" | jq -e '.pipeline_system.enabled == true' >/dev/null 2>&1; then
        state_merge "$n" 'del(.pipeline_system.enabled)' || return 2
      fi
      return 1
      ;;
    *) return 2 ;;
  esac
}

advisor_queue_filter_json() {
  local issues="$1" lane_labels pending_json issue state_file state
  local -a pending_ids=()
  lane_labels="$(pipeline_system_issue_labels_json)" || return 1
  jq -e 'type == "array"' <<< "$issues" >/dev/null 2>&1 || return 1
  while IFS= read -r issue; do
    [[ "$issue" =~ ^[1-9][0-9]*$ ]] || continue
    state_file="$AGENT_HOME/state/$issue.json"
    [ -e "$state_file" ] || continue
    state="$(jq -ce 'select(type == "object")' "$state_file" 2>/dev/null)" || return 1
    if jq -e '.hand_loop_breaker.advisor_pending == true and .model_policy.step == "advisor"' <<< "$state" >/dev/null 2>&1; then
      pending_ids+=("$issue")
    fi
  done < <(jq -r --argjson lane_labels "$lane_labels" '[.[] | select(any(.labels[]?; .name as $label | ($lane_labels | index($label)) != null)) | .number | tostring] | unique[]' <<< "$issues")
  pending_json="$(printf '%s\n' "${pending_ids[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')" || return 1
  jq -c --argjson lane_labels "$lane_labels" --argjson pending "$pending_json" '
    [.[]
      | select(any(.labels[]?; .name == "on-hold") | not)
      | . as $issue
      | select(
          if any($issue.labels[]?; .name as $label | ($lane_labels | index($label)) != null)
          then ($pending | index($issue.number | tostring)) != null
          else true end
        )]
  ' <<< "$issues"
}

pipeline_system_return_to_implement() {
  local n="$1" remove_label="${2:-}" initial initial_json child_status=1 state merged_pr filter
  state="$(state_read "$n")" || return 1
  if [ "$(jq -r '.run.outcome // empty' <<< "$state")" = merged ]; then
    if [ "$(jq -r '.state // empty' <<< "$state")" = awaiting-release ] \
      && [ "$remove_label" = awaiting-release ]; then
      return 0
    fi
    merged_pr="$(jq -r '.run.evidence.pr_number // empty | tostring' <<< "$state")"
    [[ "$merged_pr" =~ ^[1-9][0-9]*$ ]] || {
      echo "pipeline_system_return_to_implement: merged issue #$n has no recorded PR; refusing implementation requeue" >&2
      return 1
    }
    mark_awaiting_release "$n" "$merged_pr"
    return $?
  fi
  if recut_parent_has_open_child "$n" "${OPEN_ISSUE_BLOCKER_GRAPH_JSON:-[]}" "" 0; then child_status=0; else child_status=$?; fi
  case "$child_status" in
    0) echo "pipeline_system_return_to_implement: keeping parent #$n out of ready-for-agent while children remain open" >&2; return 0 ;;
    2) echo "pipeline_system_return_to_implement: cannot verify children for #$n; refusing ready-for-agent" >&2; return 1 ;;
  esac
  initial="$(model_policy initial-step)" || return 1
  initial_json="$(jq -nc --arg step "$initial" '$step')" || return 1
  filter=".pipeline_system.enabled = true
    | if (.model_policy.step == \"advisor\" or .pending_advisor_verdict != null or .web_advisor_provider_job_id != null or .web_advisor_provider_job_started_at != null or .web_advisor_provider_job_episode_seq != null) then
        .advisor_episode_seq = ((.advisor_episode_seq // 0) + 1)
      else . end
    | del(.pipeline_system.product_ruling, .needs_info_origin, .advisor_ruled_at, .pending_advisor_verdict, .web_advisor_provider_job_id, .web_advisor_provider_job_started_at, .web_advisor_provider_job_episode_seq)
    | if .model_policy.step == \"advisor\" then
        .model_policy.history = ((.model_policy.history // []) + [{unit:(.model_policy.unit // \"implement\"),step:\"advisor\",failure:.model_policy.failure,lane_reset:true,completed_at:(now|todate)}])
        | .model_policy.unit = \"implement\" | .model_policy.step = $initial_json | del(.model_policy.active,.model_policy.failure,.model_policy.advisor_decision,.model_policy.resume_stage)
      else . end"
  if is_on_hold "$n"; then
    issue_transition "$n" on-hold hold-backfill "$filter"
  else
    issue_transition "$n" ready-for-agent pipeline-system-resume "$filter"
  fi
}

prepare_pipeline_system_issue() {
  local n="$1" issue_json="${2:-}" remove_label="${3:-}" match_status=0
  if pipeline_system_issue_is_prepared "$n" "$issue_json" "$remove_label"; then
    return 0
  fi
  pipeline_system_route_status "$n" || match_status=$?
  issue_json="$PIPELINE_SYSTEM_ROUTE_ISSUE_JSON"
  case "$match_status" in
    0) ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
  if pipeline_system_issue_is_prepared "$n" "$issue_json" "$remove_label"; then
    return 0
  fi
  pipeline_system_return_to_implement "$n" "$remove_label"
}

pipeline_system_issue_is_prepared() {
  local n="$1" issue_json="$2" remove_label="${3:-}"
  # A zero-write shortcut may use the caller's current label snapshot; every
  # route that writes state or labels must pass the live membership check.
  jq -e --arg extra "$remove_label" '
      [.labels[]?.name] as $names
      | ($names | index("ready-for-agent")) != null
      and ([ "needs-info","needs-triage","needs-advisor","needs-recut","ready-for-human","needs-owner","awaiting-release", $extra ]
           | map(select(length > 0 and . != "ready-for-agent")) | all(. as $l | ($names | index($l)) == null))' \
      <<< "$issue_json" >/dev/null 2>&1 \
    && state_read "$n" | jq -e '.pipeline_system.enabled == true and .state == "ready-for-agent" and (.model_policy.step // "") != "advisor"' >/dev/null 2>&1
}

# model_timeout_for_attempt <base_minutes> [issue] -- a wall-clock kill means
# the next attempt needs more room, not a refunded attempt. Keep escalation
# bounded to one step: a later timeout gets the same larger budget instead of
# multiplying forever.
model_timeout_for_attempt() {
  local base="${1:-}" n="${2:-${N:-}}" failure
  case "$base" in
    ''|*[!0-9]*) printf '%s\n' "$base"; return 0 ;;
  esac
  [ -n "$n" ] || { printf '%s\n' "$base"; return 0; }
  failure="$(state_read "$n" | jq -r '.last_failure_kind // empty' 2>/dev/null || true)"
  if [ "$failure" = "timeout" ]; then
    printf '%s\n' "$((base * 2))"
  else
    printf '%s\n' "$base"
  fi
}

state_bump_attempts() { state_merge "$1" '.attempts = ((.attempts // 0) + 1)'; }
# state_unbump_attempts: give back one attempt, floored at zero. Only for a
# failure the TICKET did not cause -- a provider-wide quota window is the
# case this exists for (note_provider_quota_exhausted). Never use it to forgive
# a run that actually tried and failed; the give-up budget is what stops a
# ticket cycling forever, and quietly refunding real attempts would remove it.
state_unbump_attempts() { state_merge_attempt_transition "$1" '.attempts = (if (.attempts // 0) > 0 then (.attempts - 1) else 0 end)'; }

# pause_for_backoff [issue] [call_output] [exit_status] [pause_nonquota=1] [provider=codex] [model] [caller] [log_path] [termination_class] [termination_source] [termination_evidence] [transcript_empty] [stage]
#
# Provider transport failures and quota refusals are not issue failures.
# Keep the model-policy rung, refund the dispatch attempt, and retry later;
# repeated Codex transport failures open the shared provider circuit below.
# Exit 124 remains a local wall-clock timeout. Deterministic configuration
# errors stay blocked until role configuration changes; other failures back off
# only this issue for 60 minutes.
BACKOFF_QUOTA_PROVIDER=""
issue_model_failure_backoff_remaining() {
  local n="$1" now="${2:-$(date +%s)}" until_epoch
  until_epoch="$(state_read "$n" | jq -r '.model_failure_backoff.until_epoch // 0' 2>/dev/null || echo 0)"
  [[ "$until_epoch" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || { printf '0\n'; return; }
  if [ "$until_epoch" -gt "$now" ]; then printf '%s\n' "$((until_epoch - now))"; else printf '0\n'; fi
}

model_failure_backoff_summary() {
  local now="${1:-$(date +%s)}" f n remaining detail summary="" preselection_output preselection_ready=0
  local -a files=() candidates=()
  for f in "$STATE_DIR"/*.json; do
    [ -f "$f" ] || continue
    n="${f##*/}"; n="${n%.json}"
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || continue
    files+=("$f")
  done

  if [ "${#files[@]}" -gt 0 ] && preselection_output="$(mktemp 2>/dev/null)"; then
    if python3 - "${files[@]}" >"$preselection_output" 2>/dev/null <<'PYTHON'
import json
import os
import sys

try:
    for path in sys.argv[1:]:
        try:
            with open(path, "r", encoding="utf-8") as state_file:
                state = json.load(state_file)
        except (json.JSONDecodeError, UnicodeDecodeError, RecursionError, ValueError):
            # Let the existing jq path decide how malformed or unsupported JSON behaves.
            include = True
        else:
            include = isinstance(state, dict) and "model_failure_backoff" in state
        if include:
            sys.stdout.buffer.write(os.fsencode(path) + b"\0")
except OSError:
    sys.exit(1)
PYTHON
    then
      preselection_ready=1
      while IFS= read -r -d '' f; do candidates+=("$f"); done < "$preselection_output"
    fi
    rm -f -- "$preselection_output"
  fi

  if [ "$preselection_ready" -eq 1 ]; then
    files=("${candidates[@]}")
  fi

  for f in "${files[@]}"; do
    n="${f##*/}"; n="${n%.json}"
    remaining="$(issue_model_failure_backoff_remaining "$n" "$now")"
    [ "$remaining" -gt 0 ] || continue
    detail="$(state_read "$n" | jq -r --arg issue "#$n" --argjson remaining "$remaining" \
      '(.model_failure_backoff // {}) | "\($issue) \(.provider // "unknown")/\(.model // "unknown") caller=\(.caller // "unknown") remaining=\($remaining)s"' 2>/dev/null || true)"
    [ -n "$detail" ] && summary="${summary:+$summary; }$detail"
  done
  printf '%s\n' "$summary"
}

manual_pause_is_valid() {
  local timestamp
  [ -s "$PAUSE_FILE" ] || return 1
  jq -e '
    type == "object" and .caller == "operator" and
    ([.reason, .issue, .provider, .model, .timestamp] | all(type == "string" and length > 0)) and
    (.timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  ' "$PAUSE_FILE" >/dev/null 2>&1 || return 1
  timestamp="$(jq -r .timestamp "$PAUSE_FILE" 2>/dev/null)" || return 1
  agent_epoch -u "$timestamp" >/dev/null 2>&1
}

model_call_exit_class() {
  local status="${1:-}"
  [[ "$status" =~ ^[0-9]+$ ]] || { printf 'unknown\n'; return 0; }
  case "$status" in
    0) printf 'success\n' ;;
    124) printf 'wall_clock_timeout\n' ;;
    *)
      if ((10#$status >= 129 && 10#$status <= 192)); then
        printf 'signal_termination\n'
      else
        printf 'application_exit\n'
      fi
      ;;
  esac
}

model_call_signal_name() {
  local status="${1:-0}" number name
  number=$((10#$status - 128))
  name="$(kill -l "$number" 2>/dev/null || true)"
  case "$name" in
    '') name="SIG$number" ;;
    SIG*) ;;
    *) name="SIG$name" ;;
  esac
  printf '%s\n' "$name"
}

model_call_capture_termination_source() {
  local unit="zf-implement-${1:-unknown}.service" output=""
  MODEL_CALL_TERMINATION_SOURCE=unknown
  MODEL_CALL_TERMINATION_EVIDENCE=unknown
  if ! command -v systemctl >/dev/null 2>&1; then
    MODEL_CALL_TERMINATION_EVIDENCE="systemctl-unavailable"
    return 0
  fi
  if ! output="$(systemctl --user show "$unit" -p ActiveState -p SubState -p Result -p ExecMainCode -p ExecMainStatus 2>/dev/null)"; then
    MODEL_CALL_TERMINATION_EVIDENCE="systemctl-query-failed unit=$unit"
    return 0
  fi
  output="${output//$'\n'/;}"
  if [ -z "$output" ]; then
    MODEL_CALL_TERMINATION_EVIDENCE="systemctl-query-empty unit=$unit"
    return 0
  fi
  MODEL_CALL_TERMINATION_EVIDENCE="$output"
  if [[ "$output" == *ActiveState=failed* ]]; then
    case "$output" in
      *Result=oom-kill*) MODEL_CALL_TERMINATION_SOURCE="systemd unit $unit reported Result=oom-kill" ;;
      *Result=signal*) MODEL_CALL_TERMINATION_SOURCE="systemd unit $unit reported Result=signal" ;;
      *Result=timeout*) MODEL_CALL_TERMINATION_SOURCE="systemd unit $unit reported Result=timeout" ;;
    esac
  fi
}

model_call_failure_record() {
  local issue="$1" stage="$2" caller="$3" provider="$4" model="$5" status="$6"
  local exit_class="$7" termination_source="$8" termination_evidence="$9"
  local log_path="${10}" transcript_empty="${11}" timestamp record
  [[ "$issue" =~ ^[1-9][0-9]*$ && "$status" =~ ^[0-9]+$ && "$status" != 0 ]] || return 0
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  record="$(jq -cn --arg issue "$issue" --arg stage "$stage" --arg caller "$caller" \
    --arg provider "$provider" --arg model "$model" --arg timestamp "$timestamp" \
    --arg status "$status" --arg exit_class "$exit_class" \
    --arg termination_source "$termination_source" --arg termination_evidence "$termination_evidence" \
    --arg log_path "$log_path" --arg transcript_empty "$transcript_empty" \
    '{issue:$issue,stage:$stage,caller:$caller,provider:$provider,model:$model,timestamp:$timestamp,exit_status:(try ($status|tonumber) catch null),termination_class:$exit_class,termination_source:$termination_source,termination_evidence:$termination_evidence,log_path:$log_path,transcript_empty:($transcript_empty == "true")}')" || return 1
  state_merge "$issue" ".last_model_call_failure = $record"
}

pause_for_backoff() {
  agent_pipeline_write_guard pause_for_backoff "$AGENT_HOME" || return 1
  # `${5-codex}` preserves an explicit empty provider: an unsupported
  # identity must not borrow another provider's quota state.
  local n="${1:-}" call_output="${2:-}" status="${3:-}" pause_nonquota="${4:-1}" provider="${5-codex}"
  local model="${6:-unknown}" caller="${7:-unknown}" timeout_detail timeout_stage reason reason_file now timestamp until_epoch backoff_json provider_kind="" role fault_detail fault_signature
  local log_path="${8:-}" termination_class="${9:-}" termination_source="${10:-}" termination_evidence="${11:-}"
  local transcript_empty="${12:-false}" stage="${13:-}" exit_status_json=null
  BACKOFF_QUOTA_PROVIDER=""
  MODEL_CALL_ENVIRONMENTAL_FAILURE=0
  MODEL_CALL_ENVIRONMENTAL_FAILURE_KIND=""
  MODEL_CALL_ENVIRONMENTAL_FAILURE_DETAIL=""
  [ -n "$stage" ] || stage="${caller##*:}"
  [ -n "$stage" ] || stage=unknown
  [ -n "$termination_class" ] || termination_class="$(model_call_exit_class "$status")"
  if [ -z "$termination_source" ]; then
    if [ "$termination_class" = signal_termination ]; then termination_source=unknown; else termination_source=not_applicable; fi
  fi
  if [[ "$status" =~ ^[0-9]+$ ]]; then exit_status_json="$status"; fi
  if [ -n "$log_path" ]; then
    model_call_failure_record "$n" "$stage" "$caller" "$provider" "$model" "$status" \
      "$termination_class" "$termination_source" "$termination_evidence" "$log_path" "$transcript_empty" || return 1
  fi
  if [ "$status" = "124" ]; then
    timeout_detail="$(printf '%s\n' "$call_output" | grep -Eo '[^[:cntrl:]]*timed out after [0-9]+s \(elapsed [0-9]+s\)' | tail -n 1 || true)"
    [ -n "$timeout_detail" ] || timeout_detail="premium call timed out with exit 124; configured limit and elapsed time were not supplied by caller"
    timeout_stage="${GH_ENV_FAULT_STAGE:-premium-call}"
    echo "pause_for_backoff: $timeout_detail -- recorded as env:network-timeout; no PAUSE or quota alert" >&2
    record_env_fault env:network-timeout "$timeout_stage" "${n:-0}" "$timeout_detail" "" "" 0
    [ -n "$n" ] && state_merge "$n" '.last_failure_kind = "timeout"' || true
    return 0
  fi
  if model_call_missing_agent_binary "$call_output" "$status" "$provider" "$model"; then
    if [ "$provider" = codex ] || grep -qi 'codex' <<< "$call_output"; then
      MODEL_CALL_ENVIRONMENTAL_FAILURE_KIND=codex-binary-missing
      fault_signature=env:codex-binary-missing
    else
      MODEL_CALL_ENVIRONMENTAL_FAILURE_KIND=agent-tool-exit-127
      fault_signature=env:agent-tool-exit-127
    fi
    MODEL_CALL_ENVIRONMENTAL_FAILURE=1
    fault_detail="$(printf '%s' "$call_output" | tr '\r\n\t' '   ' | cut -c1-1000)"
    MODEL_CALL_ENVIRONMENTAL_FAILURE_DETAIL="$fault_detail"
    record_codex_runtime_fault "$fault_signature" "$stage" "${n:-0}" "$fault_detail" || return 1
    if [[ "$n" =~ ^[1-9][0-9]*$ ]] \
      && state_read "$n" | jq -e '.model_policy.active | type == "object"' >/dev/null 2>&1; then
      if [ "$MODEL_CALL_ENVIRONMENTAL_FAILURE_KIND" = codex-binary-missing ]; then
        state_merge "$n" '.model_policy.active.provider_outage = true | .model_policy.active.provider_outage_kind = "codex-binary-missing"' || return 1
      else
        state_merge "$n" '.model_policy.active.provider_outage = true | .model_policy.active.provider_outage_kind = "agent-tool-exit-127"' || return 1
      fi
    fi
    echo "pause_for_backoff: $MODEL_CALL_ENVIRONMENTAL_FAILURE_KIND at $caller; kept stage and refunded through model-policy retry" >&2
    return 0
  fi
  if [ "$termination_class" != signal_termination ] && [ "$provider" = codex ] \
    && codex_config_fast_failure "$call_output"; then
    record_codex_config_fault "$n" "$stage" "$call_output"
    return $?
  fi
  if [ "$termination_class" != signal_termination ] && [ "$provider" = "codex" ] && [ -n "$call_output" ] \
    && [ "$status" != "0" ]; then
    provider_kind="$(premium_call_provider_outage_kind "$call_output" || true)"
  fi
  if [ "$termination_class" != signal_termination ] && model_call_is_configuration_error "$call_output" "${status:-1}" \
    && [ "$(model_call_failure_kind "$call_output" "${status:-1}")" = execution ] \
    && [ "$provider_kind" != websocket-401 ]; then
    if [ "$provider" = web-advisor-provider ]; then
      role=advisor
    else
      role="$(state_read "$n" | jq -r '.model_policy.active.role // "work"')"
    fi
    record_model_config_fault "$n" "${caller#*:}" "$role" "$model" "$call_output" || return 1
    return 0
  fi
  if [ -n "$provider_kind" ]; then
    note_codex_provider_outage "$n" "$provider_kind" "$caller" "$model" || return 1
    echo "pause_for_backoff: Codex provider outage ($provider_kind); issue #${n:-unknown} kept on current rung for retry" >&2
    return 0
  fi
  if [ "$termination_class" != signal_termination ] && [ -n "$provider" ] && [ -n "$call_output" ] && premium_call_is_quota_refused "$call_output" "$status"; then
    [ -n "$n" ] && state_merge "$n" 'del(.last_failure_kind)' || true
    note_provider_quota_exhausted "$provider" "$n" "$call_output"
    BACKOFF_QUOTA_PROVIDER="$provider"
    return $?
  fi
  if [ "$termination_class" != signal_termination ] && [ -n "$call_output" ] && [ "$(model_call_failure_kind "$call_output" "${status:-1}")" = transient ]; then
    case "$provider" in
      codex) note_codex_provider_outage "$n" transport "$caller" "$model"; return $? ;;
      web-advisor-provider)
        note_provider_quota_exhausted web-advisor-provider "$n" "$call_output"
        BACKOFF_QUOTA_PROVIDER=web-advisor-provider
        return $? ;;
      # A transient zcode failure holds the zcode review lane for one backoff
      # window (same shape as web-advisor-provider above), which is exactly the signal
      # review_identity_available() reads to fall the next review back to the
      # implementer's own provider.
      zcode)
        note_provider_quota_exhausted zcode "$n" "$call_output"
        BACKOFF_QUOTA_PROVIDER=zcode
        return $? ;;
    esac
  fi
  [ -n "$n" ] && state_merge "$n" 'del(.last_failure_kind)' || true
  [ "$pause_nonquota" = "1" ] || return 0
  if ! [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
    echo "pause_for_backoff: unclassified model failure has no valid issue; no global PAUSE written" >&2
    return 0
  fi
  now="$(date +%s)"
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  until_epoch=$((now + 3600))
  reason="unclassified model call failure (exit ${status:-unknown})"
  reason_file="$(jq_arg_file "$reason")" || return 1
  if ! backoff_json="$(jq -cn --rawfile reason "$reason_file" --arg caller "$caller" --arg issue "$n" \
    --arg provider "${provider:-unknown}" --arg model "$model" --arg timestamp "$timestamp" \
    --arg stage "$stage" --arg termination_class "$termination_class" \
    --arg termination_source "$termination_source" --arg termination_evidence "$termination_evidence" \
    --arg log_path "$log_path" --arg transcript_empty "$transcript_empty" \
    --argjson exit_status "$exit_status_json" --argjson until_epoch "$until_epoch" \
    '{reason:$reason,caller:$caller,issue:$issue,stage:$stage,provider:$provider,model:$model,timestamp:$timestamp,exit_status:$exit_status,termination_class:$termination_class,termination_source:$termination_source,termination_evidence:$termination_evidence,log_path:$log_path,transcript_empty:($transcript_empty == "true"),until_epoch:$until_epoch}')"; then
    rm -f -- "$reason_file"
    return 1
  fi
  rm -f -- "$reason_file"
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] pause_for_backoff -> issue #$n backoff $backoff_json" >&2
    return 0
  fi
  state_merge "$n" ".model_failure_backoff = $backoff_json" || return 1
  # No maintainer mail: a per-issue backoff is an internal alert (maintainer mail contract; 2026-10-04 the bell
  # flagged "[example] 模型调用暂不可用" as off-contract). A node stalled by it reaches him via the health mail.
  echo "pause_for_backoff: issue #$n backed off for 3600s after $caller failure; no global PAUSE written" >&2
}

# A failed structured model result is exactly where the
# diagnosis lives (.is_error, .subtype, .result, .api_error_status) — the
# 2026-09-12 bug was throwing it away on failure instead of writing it
# anywhere, so a 45-minute run left a human with nothing to look at. Always
# writes (a diagnostic log is not pipeline state, so it is NOT gated by
# AGENT_DRY_RUN — a dry run is exactly when a human most wants this file) and
# echoes the decisive fields to stderr so a human running the script by hand
# sees them immediately without opening the log. Prints the log path on
# stdout so the caller can fold it into a state file or issue comment.
log_model_failure() {
  local tag="$1" output="$2" status="$3" log_file
  log_file="$LOG_DIR/$tag-$(date -u +%Y%m%dT%H%M%SZ).log"
  {
    echo "exit_status=$status"
    echo "--- raw model call output ---"
    echo "$output"
  } > "$log_file"
  {
    echo "$tag: model call failed (exit $status). Full output: $log_file"
    echo "$tag: is_error=$(echo "$output" | jq -r '.is_error' 2>/dev/null || echo '?')" \
      "subtype=$(echo "$output" | jq -r '.subtype' 2>/dev/null || echo '?')" \
      "api_error_status=$(echo "$output" | jq -r '.api_error_status' 2>/dev/null || echo '?')"
    echo "$tag: result=$(echo "$output" | jq -r '.result' 2>/dev/null | head -c 500 || echo '?')"
  } >&2
  echo "$log_file"
}

# gh()/git_fetch_bounded() -- 2026-09-15 incident: `gh issue edit 1204 ...`
# (route_to_advisor(), below) connected and then simply never returned, for
# 2h25m -- not a network failure text `gh` ever printed, a genuine
# indefinite hang. issue-pipeline.sh's own tick lock (LOCK_FILE, `flock -n
# 9`) was held by that one wedged tick the entire time, so every
# subsequent tick hit the NON-blocking `flock -n 9 || exit 0` and exited 0
# -- a successful-looking no-op, not a failure -- so nothing anywhere
# (run-tick.sh's own fail-count/alert machinery included) ever saw this as
# broken. Recovered by hand with `kill -TERM` on the wedged `gh` process.
#
# Every `gh` invocation in every script that sources this file now goes
# through gh() below, which shadows the real binary by name: bash resolves
# a bareword command against defined functions before PATH, so all ~200
# existing `gh <subcommand> ...` call sites across issue-pipeline.sh and
# every run-*.sh wrapper are covered with zero per-call-site edits -- a
# `timeout` prefix hand-added at 200 sites is exactly the kind of N-site
# patch this codebase avoids (see guarded_write() right below for the same
# discipline applied to dry-run safety). `git fetch` has no comparable
# single choke point -- it is one of many git subcommands, most of them
# local and legitimately allowed to take as long as they need (`git
# worktree add`, `git commit`, `git log` are deliberately NOT wrapped
# here, only the one that reaches the network), so its handful of call
# sites (issue-pipeline.sh, run-implement.sh x2, run-release.sh x2, plus
# run-tick.sh, which sources this file only in a child subshell to keep
# its cwd and shared state setup out of the launcher) each call
# git_fetch_bounded() explicitly.
#
# 60s, for both: this box has no recorded telemetry for normal `gh`/`git
# fetch` latency, so the bound is reasoned from shape, not measured from a
# sample. A single round-trip mutation like `gh issue edit` or a small
# `git fetch` against a repo whose main branch moves every few minutes
# normally completes in low single-digit seconds; even a slow proxy hop or
# a `gh`-internal rate-limit retry (gh_failure_is_transient() below
# already expects "HTTP 429") should clear well inside 60s -- an order of
# magnitude of headroom above a healthy call, generous enough that this
# must never fire on a working network, while bounding the failure
# actually observed (a connection that succeeds and then never answers)
# to a fixed, small wait instead of the 2h25m this incident ran. A
# legitimately long-running wait already has its own deadline instead of
# needing a single call's timeout raised to match: the CI/release
# polls in this file poll a SNAPSHOT (`gh pr checks`, never `--watch` --
# checked, nothing in engine uses `--watch` or an equivalent
# self-blocking mode) inside a `while` loop already bounded by
# POLL_INTERVAL_SECONDS and its caller's own deadline, so bounding the
# individual snapshot call only makes one stuck poll iteration fail fast
# instead of freezing the whole wait.
#
# Exit 124 is `timeout`'s own reserved "command was killed after the time
# limit" code -- nothing else in these scripts produces it -- so
# _bounded_call_timed_out() below keys off the exit status directly
# instead of inspecting output text.
GH_CALL_TIMEOUT_SEC="${GH_CALL_TIMEOUT_SEC:-60}"
GIT_FETCH_TIMEOUT_SEC="${GIT_FETCH_TIMEOUT_SEC:-60}"

# _bounded_call_timed_out <detail> -- shared by gh()/git_fetch_bounded()
# below. Always logs loudly to stderr, so a timeout lands in the
# dispatched unit's own journal the same way every other failure here
# does. Additionally files a proper environment-fault ledger entry
# (record_env_fault() further down -- same ledger env:gh-api/env:worktree-
# add/env:git-identity already use) when the calling script has opted in
# by setting GH_ENV_FAULT_STAGE (and, where relevant, $N -- the current
# issue number every single-issue wrapper already carries).
#
# Opted in: run-triage.sh, run-implement.sh, run-recut.sh, run-release.sh
# -- each sets GH_ENV_FAULT_STAGE once near its own top. None of the four
# had ANY failure handling on their later mutating `gh` calls before this
# fix (only their first read, `gh issue view`, already checked itself) --
# the exact shape of a defect already found and fixed once, 2026-09-15,
# for run-advisor.sh alone (its apply_gh_write(), Defect 2, zf-
# advisor-1205: "TLS handshake timeout crashed the whole run under `set
# -e` AFTER the paid-for verdict was already computed, discarding it with
# nothing recorded"). This closes the same gap for its three siblings
# without copying apply_gh_write()'s per-script logic three more times.
#
# NOT opted in: issue-pipeline.sh's own multi-issue tick loop (no `$N` in
# scope across it, and the one place it charges an attempt --
# state_bump_attempts() before an implement dispatch -- is followed only
# by a local systemd-run call, never another `gh` call, so nothing there
# needs a refund; an unhandled failure already aborts the whole tick under
# `set -euo pipefail` into run-tick.sh's scheduler-failed refusal, counter
# + maintainer alert, which is what actually needed fixing -- see run-
# tick.sh's own header) and run-advisor.sh (apply_gh_write() already
# covers every one of its mutating calls end to end, correctly, including
# record_env_fault() and the attempt-refund question -- see its own
# comment; setting GH_ENV_FAULT_STAGE there too would only double-log the
# identical event under a second signature). record_env_fault() itself
# only ever refunds the dispatch-time attempts bump for stage=implement
# (lessons/RULES.md V79, a ticket must never be stuck four times);
# triage/recut/release have no such external pre-charge to refund, so for
# them this is ledger visibility (feeding the same systemic/quarantine
# check env:gh-api already feeds), not a refund.
#
# Accepted trade-off: each of the four scripts' OWN pre-existing initial
# `gh issue view` check already records its own env:gh-api entry on
# failure -- a timeout there now also produces this function's
# env:network-timeout entry, two ledger lines for one event. Suppressing
# that would need GH_ENV_FAULT_STAGE unset for one specific early call and
# set for every later one, i.e. exactly the per-call-site plumbing this
# whole mechanism exists to avoid. Two entries under two signatures cost
# nothing -- env_fault_is_systemic() evaluates each signature
# independently, so neither is double-counted against itself -- and are
# strictly more information, not less.
_bounded_call_timed_out() {
  local detail="$1"
  echo "$detail -- treated as an environment fault, not a verdict" >&2
  if [ -n "${GH_ENV_FAULT_STAGE:-}" ] && declare -F record_env_fault >/dev/null 2>&1; then
    record_env_fault env:network-timeout "$GH_ENV_FAULT_STAGE" "${N:-0}" "$detail"
  fi
}

# Retry only idempotent reads. A timed-out write may have landed before its
# response was lost, so replaying it can duplicate comments or mutations.
# An owner-admission caller may set ZF_GH_CALL_DEADLINE_EPOCH_MS as an
# unexported, dynamically scoped variable. It is an absolute cutoff for the
# parent tick's GH work (already reduced by that caller's dispatch reserve),
# not a child-process timeout setting. Each real attempt is independently
# bounded against the current time; ordinary callers leave it unset.
gh_call_now_ms() {
  local realtime="${EPOCHREALTIME/./}"
  [[ "$realtime" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$((realtime / 1000))"
}

gh_tick_attempt_timeout_sec() {
  local deadline="${ZF_GH_CALL_DEADLINE_EPOCH_MS:-}" now remaining_ms allowed_ms timeout_sec default_timeout
  default_timeout="${GH_CALL_TIMEOUT_SEC:-60}"
  [[ "$default_timeout" =~ ^[1-9][0-9]*$ ]] || default_timeout=60
  [ -z "$deadline" ] && { printf '%s\n' "$default_timeout"; return 0; }
  [[ "$deadline" =~ ^[0-9]+$ ]] || return 1
  now="$(gh_call_now_ms)" || return 1
  remaining_ms=$((deadline - now))
  # Keep timeout's 5s kill grace and 1s process-start/scheduling slack inside
  # the caller's absolute deadline. A one-second GH attempt is the minimum.
  allowed_ms=$((remaining_ms - 6000))
  (( allowed_ms >= 1000 )) || return 1
  timeout_sec=$((allowed_ms / 1000))
  (( timeout_sec > default_timeout )) && timeout_sec="$default_timeout"
  (( timeout_sec > 0 )) || return 1
  printf '%s\n' "$timeout_sec"
}

gh_tick_retry_fits() {
  local deadline="${ZF_GH_CALL_DEADLINE_EPOCH_MS:-}" now remaining_ms
  [ -z "$deadline" ] && return 0
  [[ "$deadline" =~ ^[0-9]+$ ]] || return 1
  now="$(gh_call_now_ms)" || return 1
  remaining_ms=$((deadline - now))
  # The existing retry delay is 2s. After it, the next attempt needs a
  # one-second timeout, five-second kill grace, and one-second setup slack.
  (( remaining_ms >= 9000 ))
}

gh() {
  local status attempt retry_read=0 stderr_file stderr i api_method="" api_fields=0 arg attempt_timeout
  local profile_source="" profile_function="" profile_line=0 profile_started_us="" profile_ended_us
  local args=("$@")
  if [ "${ZF_PIPELINE_CALL_PROFILE_ENABLED:-0}" = 1 ]; then
    profile_source="${BASH_SOURCE[1]:-}"
    profile_function="${FUNCNAME[1]:-main}"
    profile_line="${BASH_LINENO[0]:-0}"
    if [ "$profile_function" = guarded_write ]; then
      profile_source="${BASH_SOURCE[2]:-}"
      profile_function="${FUNCNAME[2]:-main}"
      profile_line="${BASH_LINENO[1]:-0}"
    fi
    profile_source="${profile_source##*/}"
    profile_started_us="${EPOCHREALTIME/./}"
  fi
  case "${1:-}:${2:-}" in
    issue:view|issue:list|pr:view|pr:list|pr:checks|pr:diff|pr:status|run:view|run:list|label:list|repo:view|repo:list|workflow:view|workflow:list|release:view|release:list|variable:get|variable:list|auth:status)
      retry_read=1
      ;;
    api:*)
      for ((i = 2; i < ${#args[@]}; i++)); do
        arg="${args[$i]}"
        case "$arg" in
          --method|-X)
            i=$((i + 1))
            api_method="${args[$i]:-}"
            ;;
          --method=*|-X=*) api_method="${arg#*=}" ;;
          -X?*) api_method="${arg#-X}" ;;
          -f|--field|-F|--raw-field|--input)
            api_fields=1
            i=$((i + 1))
            ;;
          --field=*|--raw-field=*|--input=*|-f?*|-F?*) api_fields=1 ;;
        esac
      done
      if [ "${api_method^^}" = GET ] || { [ -z "$api_method" ] && [ "$api_fields" -eq 0 ]; }; then
        retry_read=1
      fi
      ;;
  esac

  if [ "$retry_read" != 1 ]; then
    attempt_timeout="$(gh_tick_attempt_timeout_sec)" || {
      echo 'gh: refusing call because the owner-admission deadline cannot fit one bounded attempt' >&2
      if [ -n "$profile_started_us" ]; then
        profile_ended_us="${EPOCHREALTIME/./}"
        _call_profile_record gh "$profile_started_us" "$profile_ended_us" 124 \
          "$profile_source" "$profile_function" "$profile_line" "${args[@]}"
      fi
      return 124
    }
    [ -z "$profile_started_us" ] || profile_started_us="${EPOCHREALTIME/./}"
    if command timeout --kill-after=5s "${attempt_timeout}s" gh "$@"; then
      if [ -n "$profile_started_us" ]; then
        profile_ended_us="${EPOCHREALTIME/./}"
        _call_profile_record gh "$profile_started_us" "$profile_ended_us" 0 \
          "$profile_source" "$profile_function" "$profile_line" "${args[@]}"
      fi
      if ! ticket_stage_record_gh_write "$@"; then
        echo "gh: issue #${3:-?} changed stage but transition could not be recorded" >&2
        return 1
      fi
      return 0
    else
      status=$?
      if [ -n "$profile_started_us" ]; then
        profile_ended_us="${EPOCHREALTIME/./}"
        _call_profile_record gh "$profile_started_us" "$profile_ended_us" "$status" \
          "$profile_source" "$profile_function" "$profile_line" "${args[@]}"
      fi
    fi
    [ "$status" -eq 124 ] && _bounded_call_timed_out \
      "gh: call timed out after ${attempt_timeout}s: gh $*"
    return "$status"
  fi

  stderr_file="$(mktemp)" || return 1
  for attempt in 1 2; do
    [ -z "$profile_started_us" ] || profile_started_us="${EPOCHREALTIME/./}"
    attempt_timeout="$(gh_tick_attempt_timeout_sec)" || {
      rm -f -- "$stderr_file"
      echo 'gh: refusing read because the owner-admission deadline cannot fit one bounded attempt' >&2
      if [ -n "$profile_started_us" ]; then
        profile_ended_us="${EPOCHREALTIME/./}"
        _call_profile_record gh "$profile_started_us" "$profile_ended_us" 124 \
          "$profile_source" "$profile_function" "$profile_line" "${args[@]}"
      fi
      return 124
    }
    : > "$stderr_file"
    [ -z "$profile_started_us" ] || profile_started_us="${EPOCHREALTIME/./}"
    if command timeout --kill-after=5s "${attempt_timeout}s" gh "$@" 2>"$stderr_file"; then
      if [ -n "$profile_started_us" ]; then
        profile_ended_us="${EPOCHREALTIME/./}"
        _call_profile_record gh "$profile_started_us" "$profile_ended_us" 0 \
          "$profile_source" "$profile_function" "$profile_line" "${args[@]}"
      fi
      cat "$stderr_file" >&2
      rm -f "$stderr_file"
      return 0
    else
      status=$?
      if [ -n "$profile_started_us" ]; then
        profile_ended_us="${EPOCHREALTIME/./}"
        _call_profile_record gh "$profile_started_us" "$profile_ended_us" "$status" \
          "$profile_source" "$profile_function" "$profile_line" "${args[@]}"
      fi
    fi
    stderr="$(cat "$stderr_file")"
    if [ "$attempt" -eq 1 ] && { [ "$status" -eq 124 ] || gh_failure_is_transient "$stderr"; }; then
      if ! gh_tick_retry_fits; then
        cat "$stderr_file" >&2
        rm -f -- "$stderr_file"
        echo 'gh: skipping read retry because its backoff and bounded attempt would cross the owner-admission deadline' >&2
        echo "gh: transient read failed after bounded retry: gh $*" >&2
        return "$status"
      fi
      echo "gh: transient read failed; retrying once after 2s backoff: gh $*" >&2
      sleep 2
      continue
    fi
    if [ "$status" -eq 124 ] || gh_failure_is_transient "$stderr"; then
      echo "gh: transient read failed after bounded retry: gh $*" >&2
    fi
    cat "$stderr_file" >&2
    rm -f "$stderr_file"
    [ "$status" -eq 124 ] && _bounded_call_timed_out \
      "gh: read timed out twice after ${attempt_timeout}s per attempt: gh $*"
    return "$status"
  done
}

# Preserve older short read deadlines while letting the optional scheduler
# profiler observe the actual bounded GitHub invocation at its callsite.
gh_timeout() {
  local timeout_value profile_source="" profile_function="" profile_line=0
  local profile_started_us="" profile_ended_us status=0
  local -a timeout_options=()
  while [[ "${1:-}" == -k || "${1:-}" == --kill-after ]]; do
    [ "$#" -ge 2 ] || return 2
    timeout_options+=("$1" "$2")
    shift 2
  done
  [ "$#" -ge 1 ] || return 2
  timeout_value="$1"
  shift
  if [ "${ZF_PIPELINE_CALL_PROFILE_ENABLED:-0}" = 1 ]; then
    profile_source="${BASH_SOURCE[1]:-}"
    profile_function="${FUNCNAME[1]:-main}"
    profile_line="${BASH_LINENO[0]:-0}"
    profile_source="${profile_source##*/}"
    profile_started_us="${EPOCHREALTIME/./}"
  fi
  if command timeout "${timeout_options[@]}" "$timeout_value" gh "$@"; then status=0; else status=$?; fi
  if [ -n "$profile_started_us" ]; then
    profile_ended_us="${EPOCHREALTIME/./}"
    _call_profile_record gh "$profile_started_us" "$profile_ended_us" "$status" \
      "$profile_source" "$profile_function" "$profile_line" "$@"
  fi
  return "$status"
}

# git_fetch_remove_stale_lock <repo_dir> <git_stderr> -- remove only an old
# lock path named by Git's ref-lock diagnostic inside this repository's git dir.
git_fetch_remove_stale_lock() {
  local dir="$1" stderr_file="$2" repo_dir line pattern lock_path=""
  local git_common_dir lock_parent lock_base lock_mtime lock_stat now age profile_started_us="" profile_ended_us profile_status profile_line=0
  pattern="['\"]([^'\"]+\\.lock)['\"]"
  while IFS= read -r line; do
    [[ "$line" == *"cannot lock ref"* || "$line" == *"Unable to create"* ]] || continue
    if [[ "$line" =~ $pattern ]]; then
      lock_path="${BASH_REMATCH[1]}"
      break
    fi
  done < "$stderr_file"
  [[ "$lock_path" == *.lock ]] || return 1

  repo_dir="$(cd -- "$dir" 2>/dev/null && pwd -P)" || return 1
  if [ "${ZF_PIPELINE_CALL_PROFILE_ENABLED:-0}" = 1 ]; then
    profile_line=$((LINENO + 1))
    profile_started_us="${EPOCHREALTIME/./}"
  fi
  if git_common_dir="$(command git -C "$repo_dir" rev-parse --git-common-dir 2>/dev/null)"; then
    profile_status=0
  else
    profile_status=$?
  fi
  if [ -n "$profile_started_us" ]; then
    profile_ended_us="${EPOCHREALTIME/./}"
    _call_profile_record git "$profile_started_us" "$profile_ended_us" "$profile_status" \
      lib.sh git_fetch_remove_stale_lock "$profile_line" -C "$repo_dir" rev-parse --git-common-dir
  fi
  [ "$profile_status" = 0 ] || return 1
  [[ "$git_common_dir" == /* ]] || git_common_dir="$repo_dir/$git_common_dir"
  git_common_dir="$(cd -- "$git_common_dir" 2>/dev/null && pwd -P)" || return 1
  [[ "$lock_path" == /* ]] || lock_path="$repo_dir/$lock_path"
  lock_parent="$(cd -- "$(dirname -- "$lock_path")" 2>/dev/null && pwd -P)" || return 1
  lock_base="$(basename -- "$lock_path")"
  case "$lock_parent/" in
    "$git_common_dir/"*) ;;
    *) return 1 ;;
  esac
  lock_path="$lock_parent/$lock_base"
  [[ -f "$lock_path" && ! -L "$lock_path" ]] || return 1

  lock_stat="$(stat -c '%d:%i:%Y' -- "$lock_path" 2>/dev/null)" || return 1
  lock_mtime="${lock_stat##*:}"
  [[ "$lock_mtime" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s)" || return 1
  age=$((now - lock_mtime))
  (( age > 120 )) || return 1
  [[ "$(stat -c '%d:%i:%Y' -- "$lock_path" 2>/dev/null)" == "$lock_stat" ]] || return 1
  now="$(date +%s)" || return 1
  age=$((now - lock_mtime))
  (( age > 120 )) || return 1

  rm -- "$lock_path" || return 1
  supervisor_inbox_append stale-git-lock "path=$lock_path age=$age" || {
    echo "git_fetch_bounded: removed stale lock but could not record it in the supervisor inbox" >&2
    return 1
  }
  return 0
}

# git_fetch_bounded <repo_dir> [ref ...] -- bounded `git -C <repo_dir> fetch
# -q origin [ref ...]`, the one git subcommand in these scripts that
# reaches the network. Call sites pass whatever ref args they already
# passed to the raw `git fetch` this replaces (usually just `main`).
agent_transport_is_transient() {
  grep -qiE 'Authentication failed|Permission denied|response (401|403|407)|returned error: (401|403|407)' <<< "$1" && return 1
  grep -qiE 'Proxy CONNECT aborted|CONNECT tunnel failed|failed to refresh available models.{0,160}(timed out|timeout)|GnuTLS.*(handshake failed|non-properly terminated)|TLS connection.*terminated|response 50[0-9]|HTTP[ /][0-9.]* 50[0-9]|returned error: 50[0-9]|TLS handshake timeout|connection (reset|timed out|refused)|Could not resolve (host|proxy)|Failed to connect|unexpected EOF|Operation timed out|Operation too slow|GnuTLS recv error|No route to host|Network is unreachable' <<< "$1"
}

agent_ref_update_race_is_transient() {
  grep -qiE 'cannot lock ref .*: is at ([0-9a-f]{40}|[0-9a-f]{64}) but expected ([0-9a-f]{40}|[0-9a-f]{64})' <<< "$1"
}

agent_fetch_failure_is_transient() {
  agent_transport_is_transient "$1" ||
    agent_ref_update_race_is_transient "$1" ||
    grep -qiE 'Unable to create .*\.lock.*File exists|Another git process seems to be running' <<< "$1"
}

git_fetch_bounded() {
  local dir="$1" status stderr_file trace_file transient_retries=0 retry_delay=1 stale_lock_retried=0 timeout_retried=0
  local profile_source="" profile_function="" profile_line=0 profile_started_us="" profile_ended_us
  local transient_retry_limit="${ZF_GIT_FETCH_TRANSIENT_RETRIES:-2}"
  if [ "${ZF_PIPELINE_CALL_PROFILE_ENABLED:-0}" = 1 ]; then
    profile_source="${BASH_SOURCE[1]:-}"
    profile_function="${FUNCNAME[1]:-main}"
    profile_line="${BASH_LINENO[0]:-0}"
    profile_source="${profile_source##*/}"
  fi
  [[ "$transient_retry_limit" =~ ^[0-9]+$ ]] || return 2
  shift
  # An omitted ref must never inherit the remote wildcard refspec.
  (($#)) || set -- main
  GIT_FETCH_LAST_TRANSIENT=0
  GIT_FETCH_LAST_STDERR=""
  stderr_file="$(mktemp)" || return 1
  # Phase timings for a fetch that times out: the 20s low-speed abort never
  # fired on the train's 2026-10-22 timeouts, so the stall is not an idle
  # transfer, and the timeout line alone cannot say which phase held it.
  trace_file="$(mktemp)" || { rm -f -- "$stderr_file"; return 1; }
  while :; do
    [ "${ZF_PIPELINE_CALL_PROFILE_ENABLED:-0}" != 1 ] || profile_started_us="${EPOCHREALTIME/./}"
    # A proxy tunnel can stall after CONNECT (2026-10-22: two back-to-back 60s
    # stalls failed the release train). Abort a stalled transfer after 20s so
    # the transient retry below gets a fresh tunnel inside the same budget.
    : > "$trace_file"
    if GIT_TRACE2_PERF="$trace_file" command timeout -k 10 "${GIT_FETCH_TIMEOUT_SEC}s" git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=20 -C "$dir" fetch --no-tags -q origin "$@" 2>"$stderr_file"; then
      status=0
    else
      status=$?
    fi
    if [ -n "$profile_started_us" ]; then
      profile_ended_us="${EPOCHREALTIME/./}"
      _call_profile_record git "$profile_started_us" "$profile_ended_us" "$status" \
        "$profile_source" "$profile_function" "$profile_line" -C "$dir" fetch --no-tags -q origin "$@"
    fi
    if [ "$status" -ne 0 ] && [ "$stale_lock_retried" -eq 0 ] && git_fetch_remove_stale_lock "$dir" "$stderr_file"; then
      stale_lock_retried=1
      : > "$stderr_file"
      continue
    fi
    # GNU timeout returns 137 when its kill-after SIGKILL ends a child that
    # ignored SIGTERM; preserve callers' existing timeout handling as 124.
    [ "$status" -eq 137 ] && status=124
    if [ "$status" -eq 124 ]; then
      echo "git fetch: last phases before the timeout (elapsed, region, child):" >&2
      awk -F'|' 'NF > 6 && $NF !~ /def_param|cmd_name|ancestry|version/ { print "  " $6 "|" $7 "|" $NF }' "$trace_file" \
        | sed -E 's#(https?://)[^/@[:space:]]+@#\1[redacted]@#g' | tail -n 12 >&2
    fi
    if [ "$status" -eq 124 ] && [ "$timeout_retried" -eq 0 ]; then
      echo "git fetch: timed out; retrying once in ${retry_delay}s" >&2
      sleep "$retry_delay"
      timeout_retried=1
      : > "$stderr_file"
      continue
    fi
    # A short transport flap or concurrent fetch can break a fetch before caller retry policy runs.
    if [ "$status" -ne 0 ] && [ "$status" -ne 124 ] && [ "$transient_retries" -lt "$transient_retry_limit" ] && \
      agent_fetch_failure_is_transient "$(cat "$stderr_file")"; then
      echo "git fetch: transient failure; retrying in ${retry_delay}s" >&2
      sleep "$retry_delay"
      transient_retries=$((transient_retries + 1))
      retry_delay=$((retry_delay * 2))
      : > "$stderr_file"
      continue
    fi
    break
  done
  if [ "$status" -eq 124 ] || { [ "$status" -ne 0 ] && agent_fetch_failure_is_transient "$(cat "$stderr_file")"; }; then
    GIT_FETCH_LAST_TRANSIENT=1
  fi
  GIT_FETCH_LAST_STDERR="$(head -c 512 "$stderr_file" | tr '\r\n\t' ' ' | sed -E 's#(https?://)[^/@[:space:]]+@#\1[redacted]@#g')"
  cat "$stderr_file" >&2
  rm -f -- "$stderr_file" "$trace_file"
  [ "$status" -eq 124 ] && _bounded_call_timed_out \
    "git fetch: timed out after ${GIT_FETCH_TIMEOUT_SEC}s: git -C $dir fetch origin $*"
  return "$status"
}

# A hand needs current main, its open PR branch and matching rescued work only.
git_fetch_hand_bounded() {
  local dir="$1" issue="$2" branch="${3:-}" remote_refs ref sha stderr_file status
  local -a refs=(main)
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 2
  [[ -z "$branch" ]] || refs+=("+refs/heads/$branch:refs/remotes/origin/$branch")
  stderr_file="$(mktemp)" || return 1
  if remote_refs="$(command timeout -k 10 "${GIT_FETCH_TIMEOUT_SEC}s" git -C "$dir" ls-remote --heads origin "refs/heads/rescued/*issue-$issue*" "refs/heads/rescued/*hand-$issue*" 2>"$stderr_file")"; then
    status=0
  else
    status=$?
  fi
  GIT_FETCH_LAST_STDERR="$(head -c 512 "$stderr_file" | tr '\r\n\t' ' ' | sed -E 's#(https?://)[^/@[:space:]]+@#\1[redacted]@#g')"
  rm -f -- "$stderr_file"
  GIT_FETCH_LAST_TRANSIENT=0
  if [[ "$status" != 0 ]]; then
    if [[ "$status" == 124 || "$status" == 137 ]] || agent_fetch_failure_is_transient "$GIT_FETCH_LAST_STDERR"; then
      GIT_FETCH_LAST_TRANSIENT=1
    fi
    return "$status"
  fi
  while read -r sha ref; do
    [[ -n "$ref" ]] || continue
    [[ "$ref" == refs/heads/rescued/* && "$ref" =~ (issue-|hand-)${issue}([^0-9]|$) ]] || continue
    git check-ref-format "$ref" || return 2
    refs+=("+$ref:refs/remotes/origin/${ref#refs/heads/}")
  done <<< "$remote_refs"
  git_fetch_bounded "$dir" "${refs[@]}"
}

# Every mutating call in issue-pipeline.sh/run-*.sh — gh issue/pr writes,
# `git push`, `gh pr merge`, and (run-release.sh) the ssh/docker compose calls
# that actually touch production — routes through this instead of a
# `--dry-run` check at each call site. With AGENT_DRY_RUN=1 (or a script's own
# --dry-run flag exporting it before sourcing this file) it prints what
# would have run and returns 0 without running it. Native auto-merge is
# refused before dry-run or execution; other commands pass their exit status
# through. This makes "no write
# happened" a property of one function, not of every call site remembering
# to check a flag. Reads (gh issue view, docker inspect, docker compose
# config, ...) never go through this — only things that change state do.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/gh-auto-merge-guard.sh"
guarded_write() {
  reject_native_auto_merge "$@" || return $?
  local issue_number lane caller create_repo="${REPO:-}" has_lane_add=0 has_hold_remove=0 has_ready_add=0 has_edit=0 child_status i
  local status profile_source="" profile_function="" profile_line=0
  local -a command_args=("$@") filtered_args=()
  if [ "${ROADMAP_ISSUE_CREATE_INNER:-0}" != 1 ] \
    && [ "${command_args[0]:-}" = gh ] && [ "${command_args[1]:-}" = issue ] \
    && [ "${command_args[2]:-}" = create ]; then
    for ((i = 3; i < ${#command_args[@]}; i++)); do
      case "${command_args[i]}" in
        --repo|-R) ((i += 1)); create_repo="${command_args[i]:-}" ;;
        --repo=*) create_repo="${command_args[i]#*=}" ;;
      esac
    done
    if [[ "${create_repo,,}" == "${REPO,,}" ]]; then
      if ! declare -F roadmap_issue_create >/dev/null; then
        echo "guarded_write: refusing the product issue creation; roadmap helper is unavailable" >&2
        return 1
      fi
      roadmap_issue_create "${command_args[@]}"
      return $?
    fi
  fi
  if [ "$DRY_RUN" != 1 ] && [ "${command_args[0]:-}" = gh ] && [ "${command_args[1]:-}" = issue ] \
    && [ "${command_args[2]:-}" = edit ]; then
    issue_number="${command_args[3]:-}"
    if [[ "$issue_number" =~ ^[0-9]+$ ]]; then
      for ((i = 4; i < ${#command_args[@]}; i++)); do
        if [ "${command_args[i]:-}" = --remove-label ] \
          && [ "${command_args[i + 1]:-}" = on-hold ]; then
          has_hold_remove=1
        fi
        [ "${command_args[i]:-}" = --add-label ] || continue
        lane="${command_args[i + 1]:-}"
        case "$lane" in
          ready-for-agent|needs-advisor|needs-triage|needs-recut|awaiting-release)
            has_lane_add=1
            ;;
        esac
        [ "$lane" = ready-for-agent ] && has_ready_add=1
      done
      # Suppress only a hold that was actually read. is_on_hold fails closed on
      # an unreadable label (right for dispatch), but dropping awaiting-release
      # or ready-for-agent on a GitHub read hiccup strands the ticket off every lane.
      # An explicit same-write removal is the hold expiry/release transition.
      if [ "$has_lane_add" = 1 ] && [ "$has_hold_remove" = 0 ] && is_on_hold "$issue_number" \
        && [ "${ISSUE_LABEL_VIEW_STATE[$issue_number]:-}" != failed ]; then
        caller="${FUNCNAME[1]:-main}"
        if [ "$caller" = issue_transition ]; then
          echo "guarded_write: refusing partial stage transition for held #$issue_number" >&2
          return 1
        fi
        for ((i = 0; i < ${#command_args[@]}; i++)); do
          if [ "$i" -ge 4 ] && [ "${command_args[i]:-}" = --add-label ]; then
            lane="${command_args[i + 1]:-}"
            case "$lane" in
              ready-for-agent|needs-advisor|needs-triage|needs-recut|awaiting-release)
                printf 'guarded_write: suppressed %s on held #%s by %s\n' \
                  "$lane" "$issue_number" "$caller" >&2
                [ "$lane" = ready-for-agent ] && has_ready_add=0
                i=$((i + 1))
                continue
                ;;
            esac
          fi
          filtered_args+=("${command_args[i]}")
        done
        for ((i = 4; i < ${#filtered_args[@]}; i++)); do
          case "${filtered_args[i]}" in
            --repo) i=$((i + 1)) ;;
            --repo=*) ;;
            *) has_edit=1; break ;;
          esac
        done
        [ "$has_edit" = 1 ] || return 0
        set -- "${filtered_args[@]}"
      fi
      if [ "$has_ready_add" = 1 ]; then
        child_status=1
        if recut_parent_has_open_child "$issue_number" "${OPEN_ISSUE_BLOCKER_GRAPH_JSON:-[]}" "" 0; then child_status=0; else child_status=$?; fi
        if [ "$child_status" -eq 0 ] || [ "$child_status" -eq 2 ]; then
          caller="${FUNCNAME[1]:-main}"
          if [ "$child_status" -eq 0 ]; then
            printf 'guarded_write: suppressed ready-for-agent on parent #%s with open children by %s\n' \
              "$issue_number" "$caller" >&2
          else
            printf 'guarded_write: suppressed ready-for-agent on parent #%s; child state is unverified by %s\n' \
              "$issue_number" "$caller" >&2
          fi
          if [ "$caller" = issue_transition ]; then
            echo "guarded_write: refusing partial stage transition for parent #$issue_number" >&2
            return 1
          fi
          filtered_args=()
          for ((i = 0; i < ${#command_args[@]}; i++)); do
            if [ "$i" -ge 4 ] && [ "${command_args[i]:-}" = --add-label ] \
              && [ "${command_args[i + 1]:-}" = ready-for-agent ]; then
              i=$((i + 1))
              continue
            fi
            if [ "$i" -ge 4 ] && [ "${command_args[i]:-}" = --remove-label ]; then
              lane="${command_args[i + 1]:-}"
              case " ${ALL_STATE_LABELS[*]} " in
                *" $lane "*) i=$((i + 1)); continue ;;
              esac
            fi
            filtered_args+=("${command_args[i]}")
          done
          for ((i = 4; i < ${#filtered_args[@]}; i++)); do
            case "${filtered_args[i]}" in
              --repo) i=$((i + 1)) ;;
              --repo=*) ;;
              *) has_edit=1; break ;;
            esac
          done
          [ "$has_edit" = 1 ] || return 0
          set -- "${filtered_args[@]}"
        fi
      fi
    fi
  fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] $*" >&2
    if [ "${ZF_PIPELINE_CALL_PROFILE_ENABLED:-0}" = 1 ]; then
      _call_profile_guarded_dry_run "${command_args[@]}" || true
    fi
    return 0
  fi
  if [ "${ZF_PIPELINE_CALL_PROFILE_ENABLED:-0}" = 1 ] \
    && [ "${command_args[0]:-}" = systemd-run ]; then
    profile_source="${BASH_SOURCE[1]:-}"
    profile_function="${FUNCNAME[1]:-main}"
    profile_line="${BASH_LINENO[0]:-0}"
    profile_source="${profile_source##*/}"
    if _call_profile_external systemd-run "$profile_source" "$profile_function" "$profile_line" "${command_args[@]:1}"; then
      status=0
    else
      status=$?
    fi
  elif "$@"; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -eq 0 ]; then
    if [ "${1:-}" = gh ] && [ "${2:-}" = issue ] && [ "${3:-}" = edit ]; then
      issue_label_cache_invalidate
    fi
    return 0
  fi
  return "$status"
}

# Keep issue-comment bodies out of argv. Besides avoiding shell substitution
# hazards, this lets callers pass evidence text without exposing it in a
# process list. The temporary file is removed on both real and dry-run paths.
guarded_issue_comment() {
  local n="$1" body="$2" body_file rc
  body_file="$(mktemp)" || return 1
  if ! printf '%s\n' "$body" > "$body_file"; then
    rm -f "$body_file"
    return 1
  fi
  guarded_write gh issue comment "$n" --repo "$REPO" --body-file "$body_file"
  rc=$?
  rm -f "$body_file"
  return "$rc"
}

# add_issue_blocked_by <issue> <blocker> -- create the native GitHub
# blocked-by edge $issue <- $blocker through the guarded write path. Moved
# here from run-implement.sh's implement_add_blocked_by (01dca99f4) so the
# hand-agent exit path issues the exact same write. Idempotent: reads the
# blocker's database id, skips when the edge already exists, POSTs once
# otherwise, so a retry after a transient failure never duplicates the edge.
add_issue_blocked_by() {
  local issue="$1" blocker="$2" issue_json blocker_id dependencies endpoint
  endpoint="repos/$REPO/issues/$issue/dependencies/blocked_by"
  issue_json="$(gh api "repos/$REPO/issues/$blocker")" || return 1
  blocker_id="$(jq -er '.id | numbers | select(. > 0 and . == floor)' <<< "$issue_json")" || return 1
  dependencies="$(gh api "$endpoint")" || return 1
  jq -e 'type == "array"' <<< "$dependencies" >/dev/null 2>&1 || return 1
  if jq -e --argjson id "$blocker_id" --argjson number "$blocker" \
    'any(.[]; .id == $id or .number == $number)' <<< "$dependencies" >/dev/null 2>&1; then
    return 0
  fi
  guarded_write gh api --method POST "$endpoint" -F "issue_id=$blocker_id"
}

# hand_report_blocked_on_dependency <name> <report-file> <owned-issues>
# A hand agent tied to issue N (run-recut.sh's guarded flow queues them as
# hand-<N>) ends a blocked run by writing `STATUS: BLOCKED-ON issue M` as the
# report's first line and exiting. Nothing repo-side acted on that report
# (2026-10-07: hand-1914 ended BLOCKED-ON issue 1131; the issue stayed on-hold
# until the supervisor added the native dependency by hand and ran
# state_requeue 1914 release-hold). worktree-lifecycle.sh watch calls this at
# agent exit, before dropping the roster row. Open blocker: add the native
# blocked-by edge, post one comment naming the blocker and the report's
# reason line, then state_requeue N release-hold so the open-blocker
# gate holds N exactly until M merges. Closed or unreadable blocker: leave N
# held and route one line to the supervisor inbox (same terminal-blocker rule
# as implement, 01dca99f4). Never fails the caller: every branch returns 0.
hand_report_blocked_on_dependency() {
  local name="$1" report="$2" owned="${3:-}" header dependency blocker issue
  local state_json blocker_issue blocker_state reason_line marker_filter
  [ -f "$report" ] || return 0
  case "$name$owned" in *$'\t'*|*$'\n'*) return 0 ;; esac
  header="$(sed -n '1p' "$report" 2>/dev/null || true)"
  dependency=""
  case "$header" in
    'STATUS: BLOCKED-ON issue '*) dependency="${header#STATUS: BLOCKED-ON issue }" ;;
    'STATUS: BLOCKED-ON #'*) dependency="${header#STATUS: BLOCKED-ON #}" ;;
    *) return 0 ;;
  esac
  blocker="$(awk '{print $1}' <<< "$dependency")"
  [[ "$blocker" =~ ^[1-9][0-9]*$ ]] || return 0
  issue=""
  if [[ "$owned" =~ ^([1-9][0-9]*)([[:space:]]|$) ]]; then issue="${BASH_REMATCH[1]}"; fi
  if [ -z "$issue" ] && [[ "$name" =~ ^hand-([1-9][0-9]*)$ ]]; then issue="${BASH_REMATCH[1]}"; fi
  [ -n "$issue" ] || return 0
  [ "$issue" != "$blocker" ] || return 0
  state_json="$(state_read "$issue" 2>/dev/null || true)"
  if [ "$(jq -r '.hand_blocked_on.blocker // ""' <<< "$state_json" 2>/dev/null)" = "$blocker" ]; then
    return 0
  fi
  reason_line="$(awk 'NR > 1 && NF { print; exit }' "$report" 2>/dev/null | tr '\r\t' '  ' | cut -c1-200)"
  if ! blocker_issue="$(gh issue view "$blocker" --repo "$REPO" --json state,stateReason,closedAt 2>/dev/null)"; then
    supervisor_inbox_append_once \
      "hand-blocked-on-terminal issue=#$issue blocker=#$blocker" \
      "hand-blocked-on-terminal issue=#$issue agent=$name blocker=#$blocker unreadable: #$issue stays on-hold" \
      || echo "hand-blocked-on: could not route unreadable blocker #$blocker to supervisor inbox" >&2
    return 0
  fi
  blocker_state="$(jq -r '.state // empty | ascii_downcase' <<< "$blocker_issue" 2>/dev/null)" || blocker_state=""
  if [ "$blocker_state" != open ]; then
    supervisor_inbox_append_once \
      "hand-blocked-on-terminal issue=#$issue blocker=#$blocker" \
      "hand-blocked-on-terminal issue=#$issue agent=$name blocker=#$blocker state=${blocker_state:-unknown}: #$issue stays on-hold" \
      || echo "hand-blocked-on: could not route closed blocker #$blocker to supervisor inbox" >&2
    return 0
  fi
  if ! add_issue_blocked_by "$issue" "$blocker"; then
    supervisor_inbox_append_once \
      "hand-blocked-on-write-failed issue=#$issue blocker=#$blocker" \
      "hand-blocked-on-write-failed issue=#$issue agent=$name blocker=#$blocker: native dependency write failed; #$issue stays on-hold" \
      || echo "hand-blocked-on: could not route failed dependency write #$blocker to supervisor inbox" >&2
    return 0
  fi
  # Record the marker before comment/requeue so a re-run for the same blocker
  # can never duplicate the comment.
  marker_filter=".hand_blocked_on = {blocker: $blocker, agent: $(jq -Rn --arg agent "$name" '$agent'), recorded_at: (now | todate)}"
  state_merge "$issue" "$marker_filter" >/dev/null 2>&1 || true
  guarded_issue_comment "$issue" "$BOT_DISCLAIMER
Hand agent $name ended \`STATUS: BLOCKED-ON issue #$blocker\` with no landed diff.
${reason_line:-(no reason line in the report)}
Native blocked-by dependency #$blocker added; #$issue re-enters the queue once #$blocker merges." \
    || echo "hand-blocked-on: could not post BLOCKED-ON comment on #$issue" >&2
  if ! state_requeue "$issue" release-hold; then
    supervisor_inbox_append_once \
      "hand-blocked-on-requeue-failed issue=#$issue blocker=#$blocker" \
      "hand-blocked-on-requeue-failed issue=#$issue agent=$name blocker=#$blocker: dependency and comment recorded, but release-hold requeue failed" \
      || echo "hand-blocked-on: could not route failed requeue of #$issue to supervisor inbox" >&2
    return 0
  fi
  echo "hand-blocked-on: #$issue recorded as blocked by #$blocker (agent $name); requeued with release-hold" >&2
  return 0
}

# hand_report_followup_dependencies <name> <report> <owned-issues> <pid>
#   <role> <worktree> <brief> <log> <attempt> <start-ticks> <owned-nodes>
# A final FOLLOWUP list can name other issues or PRs. Link each open issue
# blocker to every open issue owned by the hand. Keep a blocked owner record
# until every listed dependency closes so fastlane sees a real owner and the
# same hand resumes with its retained worktree.
hand_report_followup_dependencies() {
  local name="$1" report="$2" owned="${3:-}" pid="${4:-}" role="${5:-}"
  local worktree="${6:-}" brief="${7:-}" log="${8:-}" attempt="${9:-0}"
  local start_ticks="${10:-}" owned_nodes="${11:-}" header listed_ids owned_ids issue_json issue_state
  local pr_json pr_state refs ref_issue_json ref_state issue blocker primary dependency token
  local -a owned_issues=() open_owned_issues=() listed=() issue_blockers=() pr_blockers=()
  local -A owned_set=() issue_seen=() pr_seen=()
  [ -f "$report" ] || return 0
  header="$(sed -n '1p' "$report" 2>/dev/null || true)"
  [[ "$header" =~ ^STATUS:\ FOLLOWUP\(([1-9][0-9]*(,[[:space:]]*[1-9][0-9]*)*)\)$ ]] || return 0
  listed_ids="${BASH_REMATCH[1]}"
  owned_ids="$(agent_owned_issue_ids "$name" "$owned" 2>/dev/null)" || return 0
  [ -n "$owned_ids" ] || return 0
  read -r -a owned_issues <<< "$owned_ids"
  primary="${owned_issues[0]}"
  for issue in "${owned_issues[@]}"; do owned_set["$issue"]=1; done

  # Only open owned issues need new dependency edges or requeueing.
  for issue in "${owned_issues[@]}"; do
    issue_json="$(gh api "repos/$REPO/issues/$issue" 2>/dev/null)" || {
      supervisor_inbox_append_once "hand-followup-dependency-read issue=#$issue" \
        "hand-followup-dependency-read issue=#$issue agent=$name: could not read owned issue state; left its hold unchanged" || true
      return 0
    }
    if ! jq -e --argjson n "$issue" 'type == "object" and .number == $n and ((.state // "" | ascii_downcase) | IN("open", "closed"))' \
      <<< "$issue_json" >/dev/null 2>&1; then
      supervisor_inbox_append_once "hand-followup-dependency-read issue=#$issue" \
        "hand-followup-dependency-read issue=#$issue agent=$name: owned issue state response invalid; left its hold unchanged" || true
      return 0
    fi
    issue_state="$(jq -r '.state | ascii_downcase' <<< "$issue_json")"
    [ "$issue_state" = open ] && open_owned_issues+=("$issue")
  done
  ((${#open_owned_issues[@]} > 0)) || return 0

  listed="${listed_ids//,/ }"
  read -r -a listed <<< "$listed"
  for blocker in "${listed[@]}"; do
    [ -z "${owned_set[$blocker]:-}" ] || continue
    issue_json="$(gh api "repos/$REPO/issues/$blocker" 2>/dev/null)" || {
      supervisor_inbox_append_once "hand-followup-dependency-read issue=#$primary blocker=#$blocker" \
        "hand-followup-dependency-read issue=#$primary agent=$name blocker=#$blocker: could not classify FOLLOWUP dependency; left its hold unchanged" || true
      return 0
    }
    if ! jq -e --argjson n "$blocker" 'type == "object" and .number == $n
      and ((.state // "" | ascii_downcase) | IN("open", "closed"))
      and (if has("pull_request") then (.pull_request | type == "object") else true end)' \
      <<< "$issue_json" >/dev/null 2>&1; then
      supervisor_inbox_append_once "hand-followup-dependency-read issue=#$primary blocker=#$blocker" \
        "hand-followup-dependency-read issue=#$primary agent=$name blocker=#$blocker: invalid FOLLOWUP dependency response; left its hold unchanged" || true
      return 0
    fi
    issue_state="$(jq -r '.state | ascii_downcase' <<< "$issue_json")"
    if jq -e 'has("pull_request") and (.pull_request | type == "object")' <<< "$issue_json" >/dev/null 2>&1; then
      pr_json="$(gh pr view "$blocker" --repo "$REPO" --json state,closingIssuesReferences 2>/dev/null)" || {
        supervisor_inbox_append_once "hand-followup-pr-read issue=#$primary pr=#$blocker" \
          "hand-followup-pr-read issue=#$primary agent=$name pr=#$blocker: could not read closing issues; left its hold unchanged" || true
        return 0
      }
      if ! jq -e 'type == "object" and ((.state // "" | ascii_downcase) | IN("open", "closed"))
        and ((.closingIssuesReferences // []) | type == "array" and all(.[]; (.number | type) == "number" and .number > 0))' \
        <<< "$pr_json" >/dev/null 2>&1; then
        supervisor_inbox_append_once "hand-followup-pr-read issue=#$primary pr=#$blocker" \
          "hand-followup-pr-read issue=#$primary agent=$name pr=#$blocker: invalid closing-issues response; left its hold unchanged" || true
        return 0
      fi
      pr_state="$(jq -r '.state | ascii_downcase' <<< "$pr_json")"
      refs="$(jq -r '(.closingIssuesReferences // []) | .[].number' <<< "$pr_json")"
      if [ -z "$refs" ]; then
        if [ "$pr_state" = open ] && [ -z "${pr_seen[$blocker]:-}" ]; then
          pr_seen["$blocker"]=1
          pr_blockers+=("$blocker")
        fi
        continue
      fi
      while IFS= read -r ref; do
        [[ "$ref" =~ ^[1-9][0-9]*$ ]] || continue
        [ -z "${owned_set[$ref]:-}" ] || continue
        ref_issue_json="$(gh api "repos/$REPO/issues/$ref" 2>/dev/null)" || {
          supervisor_inbox_append_once "hand-followup-pr-issue-read issue=#$primary pr=#$blocker blocker=#$ref" \
            "hand-followup-pr-issue-read issue=#$primary agent=$name pr=#$blocker blocker=#$ref: could not read closing issue; left its hold unchanged" || true
          return 0
        }
        if ! jq -e --argjson n "$ref" 'type == "object" and .number == $n
          and ((.state // "" | ascii_downcase) | IN("open", "closed"))' <<< "$ref_issue_json" >/dev/null 2>&1; then
          supervisor_inbox_append_once "hand-followup-pr-issue-read issue=#$primary pr=#$blocker blocker=#$ref" \
            "hand-followup-pr-issue-read issue=#$primary agent=$name pr=#$blocker blocker=#$ref: invalid closing issue response; left its hold unchanged" || true
          return 0
        fi
        ref_state="$(jq -r '.state | ascii_downcase' <<< "$ref_issue_json")"
        if [ "$ref_state" = open ] && [ -z "${issue_seen[$ref]:-}" ]; then
          issue_seen["$ref"]=1
          issue_blockers+=("$ref")
        fi
      done <<< "$refs"
    elif [ "$issue_state" = open ] && [ -z "${issue_seen[$blocker]:-}" ]; then
      issue_seen["$blocker"]=1
      issue_blockers+=("$blocker")
    fi
  done

  ((${#issue_blockers[@]} + ${#pr_blockers[@]} > 0)) || return 0
  for issue in "${open_owned_issues[@]}"; do
    for blocker in "${issue_blockers[@]}"; do
      if ! add_issue_blocked_by "$issue" "$blocker"; then
        supervisor_inbox_append_once "hand-followup-dependency-write issue=#$issue blocker=#$blocker" \
          "hand-followup-dependency-write issue=#$issue agent=$name blocker=#$blocker: native dependency write failed; left its hold unchanged" || true
        return 0
      fi
    done
  done

  dependency=followup
  for blocker in "${issue_blockers[@]}"; do dependency+=" issue:$blocker"; done
  for blocker in "${pr_blockers[@]}"; do dependency+=" pr:$blocker"; done
  if ! blocked_hand_agent_upsert "$pid" "$name" "$role" "$worktree" "$brief" "$report" "$log" \
    "$attempt" "$dependency" "$start_ticks" "$owned_ids" "$owned_nodes"; then
    supervisor_inbox_append_once "hand-followup-owner-write issue=#$primary" \
      "hand-followup-owner-write issue=#$primary agent=$name dependency=$dependency: blocked owner record failed; left its hold unchanged" || true
    return 0
  fi
  for issue in "${open_owned_issues[@]}"; do
    if ! state_requeue "$issue" release-hold; then
      supervisor_inbox_append_once "hand-followup-requeue issue=#$issue" \
        "hand-followup-requeue issue=#$issue agent=$name dependency=$dependency: dependency recorded, but issue requeue failed" || true
      return 0
    fi
  done
  echo "hand-followup: $name owns ${open_owned_issues[*]}, blocked by $dependency" >&2
  return 0
}

main_pr_merge_failure_reason() {
  local status="$1" expected_head="$2" observed_head="${3:-}"
  case "$status" in
    124) printf 'GitHub merge command timed out (status=124)' ;;
    *)
      if [[ -z "$observed_head" ]]; then
        printf 'PR head state unavailable (gh status=%s)' "$status"
      elif [[ "$observed_head" != "$expected_head" ]]; then
        printf 'head moved'
      else
        printf 'gate refused merge (gh status=%s)' "$status"
      fi
      ;;
  esac
}

# Merge commands carry the existing head-commit guard. In dry-run output the
# guard value is deliberately omitted so dry-run only exercises decisions.
guarded_pr_merge() {
  local pr="$1" subject="$2" body="$3" match_head_commit="$4" body_file rc status
  local head_ref identity touches_lessons pr_state reconcile_script agent_home manifest_failed=0
  PR_MERGE_LOCK_FAILED=0
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] gh pr merge $pr --repo $REPO --squash --delete-branch --subject <scrubbed-title> --body-file <fixed-body> --match-head-commit <omitted>" >&2
    return 0
  fi
  body_file="$(mktemp)" || return 1
  if ! printf '%s\n' "$body" > "$body_file"; then
    rm -f "$body_file"
    return 1
  fi
  if ! identity="$(gh pr view "$pr" --repo "$REPO" --json headRefName,headRefOid,files,state,mergeCommit \
    -q '[.headRefName, .headRefOid, any(.files[]; (.path | startswith("lessons/")) or .path == "engine/state/incident-guards.json"), .state, (.mergeCommit.oid // "")] | @tsv')"; then
    rm -f "$body_file"
    return 1
  fi
  IFS=$'\t' read -r head_ref observed_head touches_lessons pr_state _ <<< "$identity"
  if [ -z "$head_ref" ] || [ "$observed_head" != "$match_head_commit" ]; then
    rm -f "$body_file"
    return 1
  fi
  PR_MERGE_LANDED=0
  PR_MERGE_COMMIT=""
  if [[ "$pr_state" != MERGED ]] \
    && ! worktree_lifecycle_manifest merging-pr-head "$head_ref" "$observed_head" "pr=$pr"; then
    rm -f "$body_file"
    return 1
  fi
  if merge_pr_and_reconcile "$pr" "$subject" "$body_file" "$match_head_commit"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$PR_MERGE_LANDED" = 1 ]; then
    worktree_lifecycle_manifest merged-pr-head "$head_ref" "$observed_head" \
      "pr=$pr;merge_sha=${PR_MERGE_COMMIT:-unavailable}" \
      || echo "guarded_pr_merge: merge landed but branch manifest could not be completed for PR #$pr" >&2
    if [[ "$touches_lessons" == true ]]; then
      if [[ ! "${PR_MERGE_COMMIT:-}" =~ ^[0-9a-f]{40,64}$ ]]; then
        echo "guarded_pr_merge: PR #$pr merged but merge SHA is unavailable; reconciliation remains pending" >&2
        rm -f "$body_file"
        return 1
      fi
      if ! worktree_lifecycle_manifest pending-pr-reconciliation "pr-$pr" "$PR_MERGE_COMMIT" \
        "head_ref=$head_ref;head_sha=$observed_head"; then
        echo "guarded_pr_merge: PR #$pr merged as $PR_MERGE_COMMIT; could not persist pending reconciliation" >&2
        manifest_failed=1
      fi
      agent_home="${AGENT_HOME:-${ZF_HOME:-${HOME:?HOME is not set}/.zenoforge}}"
      reconcile_script="$agent_home/checkout/engine/land-direct-main.sh"
      [[ -r "$reconcile_script" ]] || reconcile_script="$REPO_DIR/engine/land-direct-main.sh"
      if (cd -- "$REPO_DIR" && AGENT_HOME="$agent_home" ZF_REPO_DIR="$REPO_DIR" \
        bash "$reconcile_script" --reconcile-pr "$pr"); then
        if ! worktree_lifecycle_manifest completed-pr-reconciliation "pr-$pr" "$PR_MERGE_COMMIT" \
          "head_ref=$head_ref;head_sha=$observed_head"; then
          echo "guarded_pr_merge: PR #$pr reconciled as $PR_MERGE_COMMIT but completion record failed" >&2
          rm -f "$body_file"
          return 1
        fi
        if ((manifest_failed)); then
          rm -f "$body_file"
          return 1
        fi
        rc=0
      else
        status=$?
        echo "guarded_pr_merge: PR #$pr merged as $PR_MERGE_COMMIT; lesson ID reconciliation pending (status=$status)" >&2
        rm -f "$body_file"
        return "$status"
      fi
    fi
  fi
  rm -f "$body_file"
  return "$rc"
}

pr_merge_delivery_row() {
  local pr="$1"
  gh pr view "$pr" --repo "$REPO" --json state,headRefOid,mergeCommit \
    -q '[.state, .headRefOid, (.mergeCommit.oid // "")] | @tsv'
}

merge_pr_and_reconcile() {
  local pr="$1" subject="$2" body_file="$3" match_head_commit="$4" row pr_state pr_head merge_sha rc
  row="$(pr_merge_delivery_row "$pr")" || { echo "guarded_pr_merge: could not read current state for PR #$pr" >&2; return 1; }
  IFS=$'\t' read -r pr_state pr_head merge_sha <<< "$row"
  if [[ "$pr_state" == MERGED ]]; then
    PR_MERGE_LANDED=1
    if [[ "$pr_head" != "$match_head_commit" || ! "$merge_sha" =~ ^[0-9a-f]{40,64}$ ]]; then
      echo "guarded_pr_merge: PR #$pr is merged but exact head or merge SHA is unavailable" >&2
      return 1
    fi
    PR_MERGE_COMMIT="$merge_sha"
    echo "guarded_pr_merge: PR #$pr already merged as $merge_sha; merge skipped" >&2
    return 0
  fi
  if [[ "$pr_state" != OPEN || "$pr_head" != "$match_head_commit" ]]; then
    echo "guarded_pr_merge: PR #$pr is not open at the pinned head; refusing merge" >&2
    return 1
  fi
  if ! acquire_merge_lock; then
    PR_MERGE_LOCK_FAILED=1
    echo "guarded_pr_merge: could not acquire the merge lock within $((MERGE_LOCK_WAIT_SECONDS / 60)) minutes" >&2
    return 1
  fi
  if guarded_write gh pr merge "$pr" --repo "$REPO" --squash --delete-branch \
    --subject "$subject" \
    --body-file "$body_file" \
    --match-head-commit "$match_head_commit"; then
    rc=0
  else
    rc=$?
  fi
  release_merge_lock
  [ "$rc" -eq 0 ] || return "$rc"
  PR_MERGE_LANDED=1
  row="$(pr_merge_delivery_row "$pr")" || {
    echo "guarded_pr_merge: PR #$pr merged but merge identity read failed; reconciliation is retryable" >&2
    return 1
  }
  IFS=$'\t' read -r pr_state pr_head merge_sha <<< "$row"
  if [[ "$pr_state" != MERGED || "$pr_head" != "$match_head_commit" \
    || ! "$merge_sha" =~ ^[0-9a-f]{40,64}$ ]]; then
    echo "guarded_pr_merge: PR #$pr merged but exact merge identity is unavailable; reconciliation is retryable" >&2
    return 1
  fi
  PR_MERGE_COMMIT="$merge_sha"
}

# Defect 3, 2026-09-13: local pipeline-state writes that are a bare `echo >
# file` redirect, not a command guarded_write() can wrap (guarded_write runs
# "$@" as a command; a shell redirect isn't one). Same shape state_merge()/
# pause_for_backoff() already fixed for their own writes (2026-09-12) — "no
# writes happen under AGENT_DRY_RUN=1" has to cover local state too, not just
# gh/ssh/docker. Reproduced live: run-release.sh's bare marker write
# ($DEPLOY_BLOCKED_FILE) was the one remaining way a
# dry run touching the deploy section left a real trace on disk.
guarded_state_write() {
  local file="$1" content="$2"
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] write '$content' -> $file" >&2
    return 0
  fi
  echo "$content" > "$file"
}

# --- loop-break: a generic transition bound owned by the state machine, ---
# --- not any one leg (2026-09-16, lessons/RULES.md V112/V113/V114/V116) ----
# Tonight's #1204/#1206 incident: two writers -- the advisor's own `guarded`
# ruling (admit_guarded(), below) and the admission gate's dispatch-time
# recheck (issue-pipeline.sh section (c), which calls route_to_advisor() on
# a refusal) -- each applied a rule that was LOCALLY correct in isolation
# and produced a ready-for-agent<->needs-advisor ping-pong neither writer
# could see, because neither reads anything but its own single transition.
# The specific defect (the gate recheck ignoring an admission the ladder
# already granted) is fixed separately, in issue-pipeline.sh's own
# state_is_guarded() skip -- this is the general case: ANY two
# locally-correct writers can produce the same shape for a reason nobody has
# found yet, and fixing one incident does not retire that risk.
#
# What this adds is not a smarter router -- a smarter router is just another
# locally-reasoning writer that can itself be wrong someday. It is a BOUND:
# read the ticket's own trajectory (the one thing every individual writer
# above lacks) from the same durable, restart-proof signal
# detect-label-churn.sh already reads -- GitHub's own issue timeline, not a
# local counter. A local counter is exactly the class of signal #1180
# (lessons/RULES.md, "#1187, 7881d0fc1") showed can be silently zeroed by a
# restart or an out-of-band edit, and V113's own incident showed a
# state-file idempotency marker (advisor_ruled_at) can ALSO fail this way
# even without any of that -- a neighboring, entirely legitimate write path
# (route_to_advisor()'s own `del(.advisor_ruled_at)`, for a genuine second
# episode) clears it as a side effect of doing its own job correctly. A
# bound built the same way would be one edit away from the same defeat.
# Keep the label with each timestamp: duplicate adds can happen after an
# unlabeled/re-add without a real move, as in #3685. The first selected label
# establishes the baseline; only later alternations are flips.
label_transition_events() {
  local n="$1" label_a="$2" label_b="$3" since="$4"
  gh api "repos/$REPO/issues/$n/timeline" --paginate \
    --jq '.[] | select(.event=="labeled") | select(.label.name=="'"$label_a"'" or .label.name=="'"$label_b"'") | select(.created_at >= "'"$since"'") | [.created_at, .label.name] | @tsv' \
    2>/dev/null | awk -F '\t' -v label_a="$label_a" -v label_b="$label_b" '
      ($2 == label_a || $2 == label_b) {
        if (previous != "" && $2 != previous) print $1
        previous = $2
      }
    ' || true
}

# Same threshold/window/recency reasoning as detect-label-churn.sh's own
# (former) CHURN_THRESHOLD/WINDOW_HOURS/RECENCY_MINUTES -- one set of knobs
# now, not two, since that detector calls this same function for its own
# periodic scan (see its own header) instead of keeping duplicated logic that can
# drift the way risk-class.mjs's pattern list once did
# (advisor_footprint_risky()'s comment, above).
LOOP_BREAK_THRESHOLD="${LOOP_BREAK_THRESHOLD:-4}"
LOOP_BREAK_WINDOW_HOURS="${LOOP_BREAK_WINDOW_HOURS:-6}"
LOOP_BREAK_RECENCY_MINUTES="${LOOP_BREAK_RECENCY_MINUTES:-90}"
LOOP_ESCALATION_MARKER="<!-- zf-loop-escalation -->"

# loop_break_check <n> <label_a> <label_b> -- shared by inline route paths
# and detect-label-churn.sh. A per-issue lock makes episode check-and-freeze
# single-writer even when the timer and pipeline tick overlap.
#
# An active loop is frozen on-hold. Callers receive LOOP_BREAK_ESCALATED=1
# and stop before applying the route that would continue the flip.
#
# The latest transition timestamp keys one episode. The state marker,
# supervisor inbox key and episode-specific comment suppress duplicate writes;
# a later transition starts a new episode.
loop_break_check() {
  local n="$1" lock_fd="" status
  LOOP_BREAK_ESCALATED=0
  if ! try_lock_nonblocking "$AGENT_HOME/locks/label-churn-$n.lock" lock_fd; then
    echo "loop_break_check: #$n issue lock busy or unavailable; suppressing route until next tick" >&2
    LOOP_BREAK_ESCALATED=1
    return 0
  fi
  loop_break_check_locked "$@" || status=$?
  status="${status:-0}"
  unlock_fd "$lock_fd" || return 1
  return "$status"
}

loop_break_check_locked() {
  local n="$1" label_a="$2" label_b="$3" since events count latest recency_cutoff trajectory comment_bodies previous_episode episode_marker lifted_at writer_since writers transition_file dispatched_at cutoff
  since="$(date -u -d "-${LOOP_BREAK_WINDOW_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)"
  events="$(label_transition_events "$n" "$label_a" "$label_b" "$since")"
  count="$(printf '%s\n' "$events" | grep -c . || true)"
  [ "${count:-0}" -ge "$LOOP_BREAK_THRESHOLD" ] || return 0
  # Lifting on-hold or reopening a concluded ticket starts a new episode:
  # earlier transitions belong to a loop that was frozen and fixed (issue 1943
  # was re-frozen 27 min after a supervisor lift) or to a finished lifecycle
  # (issue 3050 was frozen after one advisor round trip post-reopen). Read only
  # past the threshold, so scans stay cheap.
  lifted_at="$(gh api "repos/$REPO/issues/$n/timeline" --paginate \
    --jq '.[] | select(.event=="unlabeled" and (.label.name=="on-hold" or .label.name=="concluded")) | .created_at' 2>/dev/null | sort | tail -n1 || true)"
  writer_since="$since"
  if [[ -n "$lifted_at" && "$lifted_at" > "$since" ]]; then
    # Rebuild alternations at the new episode boundary; the first post-lift
    # label is a baseline, not a flip from the prior lifecycle.
    events="$(label_transition_events "$n" "$label_a" "$label_b" "$lifted_at")"
    count="$(printf '%s\n' "$events" | grep -c . || true)"
    [ "${count:-0}" -ge "$LOOP_BREAK_THRESHOLD" ] || return 0
    writer_since="$lifted_at"
  fi

  # Same reason as detect-label-churn.sh's own former RECENCY_MINUTES: count
  # alone cannot tell a ticket still actively looping right now from one
  # that churned in a settled historical burst earlier in the same window.
  latest="$(printf '%s\n' "$events" | tail -n1)"
  recency_cutoff="$(date -u -d "-${LOOP_BREAK_RECENCY_MINUTES} minutes" +%Y-%m-%dT%H:%M:%SZ)"
  [[ "$latest" < "$recency_cutoff" ]] && return 0
  transition_file="$AGENT_HOME/state/ticket-transitions.jsonl"
  writers=""
  if [ -r "$transition_file" ]; then
    writers="$(jq -sr --argjson issue "$n" --arg label_a "$label_a" --arg label_b "$label_b" \
      --arg since "$writer_since" '
      [.[]
        | select(.issue == $issue and .kind == "flip")
        | select(.ts >= $since)
        | select((.from_stage == $label_a and .to_stage == $label_b)
          or (.from_stage == $label_b and .to_stage == $label_a))
        | .writer | select(type == "string" and length > 0)]
      | unique | join(",")
    ' "$transition_file" 2>/dev/null)" || writers=""
  fi
  [ -n "$writers" ] || writers=unknown

  previous_episode="$(state_read "$n" | jq -r '.loop_escalated_episode // empty')"
  if [ "$previous_episode" = "$latest" ]; then
    LOOP_BREAK_ESCALATED=1
    return 0
  fi
  comment_bodies="$(gh api "repos/$REPO/issues/$n/comments" --paginate \
      --jq '.[] | select(.created_at >= "'"$since"'") | .body' 2>/dev/null || true)"
  episode_marker="<!-- zf-loop-episode=$latest -->"
  echo "loop_break_check: #$n crossed $LOOP_BREAK_THRESHOLD transitions between $label_a/$label_b in the last ${LOOP_BREAK_WINDOW_HOURS}h (latest $latest) -- freezing on-hold" >&2
  trajectory="$(printf '%s\n' "$events" | nl -ba -s'. ' -w1)"
  supervisor_inbox_append_once \
    "label-churn issue=#$n episode=$latest" \
    "label-churn issue=#$n episode=$latest action=on-hold writers=$writers" || return 1
  if ! grep -qF "$episode_marker" <<< "$comment_bodies"; then
      guarded_write gh issue comment "$n" --repo "$REPO" --body "$BOT_DISCLAIMER
$LOOP_ESCALATION_MARKER
这是循环保护：这张票在 \`$label_a\`/\`$label_b\` 之间切换 $count 次，最近一次是 $latest。已加上 \`on-hold\`，停止本轮自动派发。
$episode_marker
本轮观测到的标签写入者：\`writers=$writers\`。" || return 1
  fi
  hold_issue "$n" --holder detect-label-churn \
    --release 'label churn is reviewed; expiry resumes the ticket at its prior stage' \
    --expires 24h --kind label-churn \
    --remove-label "$label_a" --remove-label "$label_b" || return 1
  state_merge "$n" ". + {loop_escalated_at: (now | todate), loop_escalated_episode: $(jq -Rn --arg episode "$latest" '$episode'), loop_trajectory_md: $(jq -Rs . <<<"$trajectory")}" \
    || echo "loop_break_check: state_merge failed for #$n -- on-hold and inbox notice already applied" >&2
  LOOP_BREAK_ESCALATED=1
  dispatched_at="$(state_read "$n" | jq -r '.loop_hand_dispatch_at // empty')" || return 1
  cutoff="$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)" || return 1
  if [[ -n "$dispatched_at" && "$dispatched_at" > "$cutoff" ]]; then
    supervisor_inbox_append_once "loop-hold-hand-repeat issue=#$n" \
      "loop-hold-hand-repeat issue=#$n status=held reason=previous-scheduler-handoff-within-24h"
    return $?
  fi
  [ "${DRY_RUN:-0}" != 1 ] || return 0
  scheduler_requeue_issue "$n" "label churn requires a repair of the recorded trajectory" "" "" "$latest" pipeline-requeue \
    '.loop_hand_dispatch_at = (now | todate)'
}

# The shipped policy marks the advisor role disabled: no advisor provider ships, so nobody can rule.
# advisor_role_disabled is the one test for that; callers skip the advisor step (or hold) instead of
# queueing work for an advisor that never answers.
advisor_role_disabled() { ! model_policy identity advisor >/dev/null 2>&1; }

# hold_for_missing_advisor <n> [remove_label] -- park the issue for the maintainer, who rules and requeues it.
hold_for_missing_advisor() {
  local n="$1" remove_label="${2:-ready-for-agent}"
  hold_issue "$n" --holder supervisor --expires 168h --kind advisor-disabled \
    --release "the advisor role is disabled: the maintainer rules on this issue, then requeues it" \
    --remove-label "$remove_label" || return 1
  supervisor_inbox_append_once "advisor-disabled:$n" \
    "issue $n held for the maintainer: the advisor role is disabled, so no ruling can be requested"
}

# route_to_advisor <n> -- the one write path for sending an issue into a
# NEW advisor episode. issue-pipeline.sh's own advisor-dispatch loop skips
# any issue whose state file `has("advisor_ruled_at")`, on the stated
# assumption that the label is only ever applied once per issue lifetime --
# a human (or a bug) re-applying needs-advisor to something already ruled
# on. That assumption is false: needs-advisor is legitimately re-applied to
# the SAME issue for a genuinely new episode (a second NOT_READY verdict, a
# second P2/L4 hit, a second blast-radius miss, ...), and advisor_ruled_at
# is a single permanent field written once by run-advisor.sh and never
# cleared -- so a second episode's needs-advisor label was silently
# undispatchable forever: not ready-for-agent (implement will not
# redispatch it) and not advisor-eligible (this guard skips it). Zero live
# producers, no poller, no escalation, no email. Measured live 2026-09-15:
# 15 of 21 open needs-advisor issues were stuck this way, one of them
# (#1215) wedging its own open PR's file footprint against two unrelated
# ready-for-agent tickets via open_pr_file_collision. Every call site that
# starts a new advisor episode must clear the stale verdict here, in the
# same write, so line 413's guard only ever catches what it was meant to
# catch: a re-apply that did NOT go through this function.
#
# $2 (remove_label, default ready-for-agent): the label the issue is
# carrying when it climbs to the advisor. Five call sites climb from
# ready-for-agent (run-implement.sh, issue-pipeline.sh's autonomy-gate
# recheck); sweep-parked-backlog.sh climbs from ready-for-human (a ticket
# parked there before the ladder existed, found in flight). Same defect,
# same fix -- a second parameter is cheaper than a second copy of this
# function.
# 2026-09-16 fix (V102's third recurrence): the del() above used to run as a
# bare statement. `state_merge` returns 1 on a real failure (malformed state
# JSON, mktemp/jq trouble) WITHOUT writing -- but a bare call only aborts the
# script via `set -e` when nothing between here and the top of the process is
# an if/while/&&/|| condition. Live proof it is not: run-advisor-batch.sh
# calls this from inside `if apply_one_ruling ...; then`, which disables `-e`
# for everything apply_one_ruling runs, this function included (confirmed by
# direct test -- a `false` deep inside a chain like that never stops the
# script). #1245 wedged this exact way: the clear failed, nothing checked it,
# and the label moved anyway with the stale marker still on disk. Checking
# the return value here does not depend on the caller's own `set -e`
# context, so it closes the bug regardless of how future callers invoke this.
ISSUE_VERDICT_GUARD_REASON=""
ISSUE_VERDICT_GUARD_SKIPPED=0
issue_verdict_snapshot_guard() {
  local n="$1" snapshot_json="${2:-}" current_json current_state snapshot_state current_labels snapshot_labels
  ISSUE_VERDICT_GUARD_REASON=""
  if ! current_json="$(gh issue view "$n" --repo "$REPO" --json state,labels 2>/dev/null)"; then
    ISSUE_VERDICT_GUARD_REASON="could not verify current issue state and labels"
    return 2
  fi
  current_state="$(jq -r '.state // empty | ascii_downcase' <<< "$current_json" 2>/dev/null)" || {
    ISSUE_VERDICT_GUARD_REASON="could not verify current issue state and labels"
    return 2
  }
  case "$current_state" in
    closed) ISSUE_VERDICT_GUARD_REASON="issue is closed"; return 1 ;;
    open) ;;
    *) ISSUE_VERDICT_GUARD_REASON="could not verify current issue state and labels"; return 2 ;;
  esac
  [ -n "$snapshot_json" ] || return 0

  snapshot_state="$(jq -r '.state // empty | ascii_downcase' <<< "$snapshot_json" 2>/dev/null)" || {
    ISSUE_VERDICT_GUARD_REASON="could not verify snapshot issue state and labels"
    return 2
  }
  if [ "$snapshot_state" != open ]; then
    ISSUE_VERDICT_GUARD_REASON="snapshot issue was not open"
    return 1
  fi
  if [ "$current_state" != "$snapshot_state" ]; then
    ISSUE_VERDICT_GUARD_REASON="issue state changed since snapshot"
    return 1
  fi
  current_labels="$(jq -c '.labels | map(.name) | sort' <<< "$current_json" 2>/dev/null)" || {
    ISSUE_VERDICT_GUARD_REASON="could not verify current issue state and labels"
    return 2
  }
  snapshot_labels="$(jq -c '.labels | map(.name) | sort' <<< "$snapshot_json" 2>/dev/null)" || {
    ISSUE_VERDICT_GUARD_REASON="could not verify snapshot issue state and labels"
    return 2
  }
  if [ "$current_labels" != "$snapshot_labels" ]; then
    ISSUE_VERDICT_GUARD_REASON="issue labels changed since snapshot"
    return 1
  fi
  return 0
}

route_to_advisor() {
  local n="$1" remove_label="${2:-ready-for-agent}" snapshot_json="${4:-}" pipeline_loop_breaker="${5:-}"
  local convergence_attempt current_attempt skip_label_write=0
  local lane_state pipeline_system_status=0
  ISSUE_VERDICT_GUARD_SKIPPED=0
  if ! issue_verdict_snapshot_guard "$n" "$snapshot_json"; then
    ISSUE_VERDICT_GUARD_SKIPPED=1
    echo "route_to_advisor: #$n -- $ISSUE_VERDICT_GUARD_REASON; skipping stale route" >&2
    return 0
  fi
  lane_state="$(state_read "$n")"
  if jq -e '.tracker_parent == true or .state == "tracker"' <<< "$lane_state" >/dev/null 2>&1; then
    echo "route_to_advisor: #$n -- tracker parent; retiring stale advisor state and labels" >&2
    retire_tracker_parent "$n" || return 1
    return 0
  fi
  pipeline_system_route_status "$n" "$snapshot_json" || pipeline_system_status=$?
  case "$pipeline_system_status" in
    0)
      if [ "$pipeline_loop_breaker" = hand-loop-breaker ]; then
        if ! jq -e --argjson limit "$(jq -er '.hand_loop_breaker.work_no_progress_limit' "$MODEL_POLICY_DEFAULT")" '
          .model_policy.step == "advisor"
          and .model_policy.failure.unit == "implement"
          and (.model_policy.failure.step == "work" or .model_policy.failure.step == "work_retry")
          and .model_policy.failure.transition == "advisor"
          and .model_policy.failure.same_failure_streak >= $limit
          and (.model_policy.advisor_decision // "" | length) == 0
        ' <<< "$lane_state" >/dev/null 2>&1; then
          echo "route_to_advisor: #$n -- loop-breaker advisor request failed its persisted-state guard" >&2
          return 1
        fi
        state_merge "$n" '.hand_loop_breaker.advisor_pending = true' || return 1
      else
        if ! jq -e '.model_policy.failure.stage == "risk-class"
          and .model_policy.failure.early_stop.reason == "same-failure"
          and .model_policy.failure.early_stop.advisor_seen == false' <<< "$lane_state" >/dev/null 2>&1; then
          pipeline_system_return_to_implement "$n" "$remove_label"
          return $?
        fi
        # Pipeline-system issues use this existing hold for ordinary risk refusals.
        hold_issue "$n" --holder supervisor --expires 168h --kind pipeline-system-risk-class \
          --release "repeated P2/L4 risk-class refusal: supervisor sets guarded admission (guarded + required_test_paths) or hand-dispatches" \
          --remove-label "$remove_label" || return 1
        supervisor_inbox_append_once "pipeline-system-risk-class:$n" \
          "pipeline-system issue $n held for supervisor: repeated P2/L4 risk-class refusal needs a guarded-admission decision" || return 1
        return 0
      fi
      ;;
    1) ;;
    *) echo "route_to_advisor: #$n -- cannot classify lane; refusing advisor route" >&2; return 1 ;;
  esac
  # A merged ticket awaiting deployment still belongs to the release leg.
  # Moving only its local state to needs-advisor strands that leg while the
  # awaiting-release label remains (production #1140 after migration 42501).
  if jq -e '.state == "awaiting-release" and .deploy_state == "pending" and .run.outcome == "merged"' \
    <<< "$lane_state" >/dev/null; then
    echo "route_to_advisor: #$n -- merged deploy pending; retaining awaiting-release" >&2
    return 0
  fi
  if advisor_role_disabled; then
    echo "route_to_advisor: #$n -- advisor role disabled; holding for the maintainer" >&2
    hold_for_missing_advisor "$n" "$remove_label"
    return $?
  fi
  if jq -e '.advisor_convergence_pass == true' <<< "$lane_state" >/dev/null 2>&1; then
    convergence_attempt="$(jq -r '.advisor_convergence_pass_attempt // .attempts // 0' <<< "$lane_state")"
    current_attempt="$(jq -r '.attempts // 0' <<< "$lane_state")"
    if ! [[ "$convergence_attempt" =~ ^[0-9]+$ && "$current_attempt" =~ ^[0-9]+$ ]]; then
      echo "route_to_advisor: #$n -- cannot verify whether the one implement pass ran; refusing advisor route" >&2
      return 1
    fi
    if (( current_attempt > convergence_attempt )); then
      echo "route_to_advisor: #$n -- repeated advisor ruling received its one implement pass; routing failed pass to needs-recut" >&2
      route_to_recut "$n"
      return $?
    fi
    echo "route_to_advisor: #$n -- repeated advisor ruling still awaits its one implement pass; keeping the implement route" >&2
    return 0
  fi
  local admission=0
  advisor_retry_admission "$n" || admission=$?
  case "$admission" in
    0) ;;
    10) return 0 ;;
    *) return "$admission" ;;
  esac
  if [ "$remove_label" != needs-advisor ]; then
    loop_break_check "$n" "$remove_label" needs-advisor
    [ "$LOOP_BREAK_ESCALATED" = 1 ] && return 0
  else
    skip_label_write=1
  fi
  # 2026-09-19 addition: also clear .pending_advisor_verdict here, same
  # episode-boundary reasoning as .advisor_ruled_at just above. run-advisor.sh
  # now persists a computed verdict to this field BEFORE attempting its own
  # GitHub side-effects (comment/label/notify), specifically so an
  # interrupted apply can resume on the NEXT tick without paying for a
  # second model call -- see that script's own header comment on the
  # resume check for the live defect this closes. That resume check is
  # scoped to "did the ticket's own content change", which only protects
  # against staleness WITHIN one episode; it has no way to know a NEW
  # episode has begun (a second NOT_READY verdict, a second footprint miss,
  # ...) if the ticket's title/body/comments happen to read identically to
  # the last episode's. route_to_advisor() is the one write path for
  # starting that new episode (see this function's own header comment) --
  # exactly where a leftover verdict from the PRIOR episode must stop being
  # eligible to resume, the same way a leftover advisor_ruled_at must stop
  # blocking dispatch.
  #
  # 2026-09-19 SECOND addition, same day: also increment advisor_episode_seq
  # -- the episode-sequence guard advisor_persist_pending()/advisor_resume_
  # check() (engine/advisor-core.sh) read. The del() just above only
  # protects a resume check that compares TICKET CONTENT; it has no power
  # over a reasoning pass that is still physically in flight (a web-advisor-provider-
  # advisor job dispatched by the PRIOR episode, still polling) when this
  # function starts a new one -- that stale pass could otherwise finish
  # later and get persisted/applied as if it belonged to the episode this
  # call just opened. advisor_episode_seq is a plain incrementing counter,
  # not a hash/fingerprint of anything (the project hash ban) -- it
  # only ever answers "is this the same episode", nothing about content.
  local transition_filter='del(.advisor_ruled_at, .pending_advisor_verdict, .web_advisor_provider_job_id, .web_advisor_provider_job_started_at, .web_advisor_provider_job_episode_seq, .advisor_admission_measure_only) | .advisor_episode_seq = ((.advisor_episode_seq // 0) + 1)'
  if is_on_hold "$n"; then
    issue_transition "$n" on-hold hold-backfill "$transition_filter"
  else
    issue_transition "$n" needs-advisor advisor-route "$transition_filter" "$skip_label_write"
  fi
}

# Preserve the existing answer transition for both an actual reporter reply
# and a timeout that applies a default. State and label move through the same
# seam as section (a) has always used.
needs_info_resume_answered_issue() {
  local n="$1" issue_json="$2"
  if [ "$(state_read "$n" | jq -r '.needs_info_origin // empty')" = advisor ]; then
    route_to_advisor "$n" needs-info false "$issue_json"
  else
    issue_transition "$n" needs-triage needs-info-answered
  fi
}

# Extract only explicit choices/defaults from the emailed question. The
# standard email footer says replies may accept defaults, but that footer by
# itself does not turn an open question into a decision.
needs_info_default_option() {
  local body="$1" line
  while IFS= read -r line; do
    case "$line" in
      '> 如果都同意上面写的默认处理方式，直接回复这封邮件说一声'*|https://github.com/*) break ;;
      *'建议：'*|*'建议:'*|*'默认：'*|*'默认:'*|*'按默认处理'*|*'按默认执行'*)
        printf '%s\n' "$line"
        return 0
        ;;
    esac
  done <<< "$body"
  return 1
}

needs_info_human_reply_after() {
  local issue_json="$1" sent_at="$2" sent_at_iso comment comment_at comment_body
  sent_at_iso="$(date -u -d "@$sent_at" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  while IFS= read -r comment; do
    comment_at="$(jq -r '.createdAt // empty' <<< "$comment")"
    [[ -n "$comment_at" && ( "$comment_at" > "$sent_at_iso" || "$comment_at" = "$sent_at_iso" ) ]] || continue
    comment_body="$(jq -r '.body // empty' <<< "$comment")"
    comment_is_bot "$comment_body" && continue
    return 0
  done < <(jq -c '.comments[]?' <<< "$issue_json")
  return 1
}

# needs_info_timeout_step <issue-number> <issue-json> <now-epoch>
# The caller has already read the Gmail thread and seeded its first-message
# date/default into state. This function owns one timeout decision and leaves
# the same reply transition available to later ticks if a write fails.
needs_info_timeout_step() {
  local n="$1" issue_json="$2" now="$3" state thread_id sent_at default_option age days marker
  local applied_thread marker_exists at decision_patch comment_body
  NEEDS_INFO_TIMEOUT_ACTION=unchanged
  jq -e '.labels | any(.name == "needs-info")' <<< "$issue_json" >/dev/null 2>&1 || return 0

  state="$(state_read "$n")" || return 1
  thread_id="$(jq -r '.needs_info_thread_id // empty' <<< "$state")"
  [ -n "$thread_id" ] || return 0
  applied_thread="$(jq -r '.needs_info_default_applied.thread_id // empty' <<< "$state")"
  if [ "$applied_thread" = "$thread_id" ]; then
    needs_info_resume_answered_issue "$n" "$issue_json" || return 1
    NEEDS_INFO_TIMEOUT_ACTION=default-applied
    return 0
  fi

  sent_at="$(jq -r '.needs_info_question_sent_at // empty' <<< "$state")"
  [[ "$now" =~ ^[0-9]+$ && "$sent_at" =~ ^[0-9]+$ && "$NEEDS_INFO_QUESTION_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || return 0
  age=$((now - sent_at))
  (( age >= NEEDS_INFO_QUESTION_TIMEOUT_SECONDS )) || return 0
  needs_info_human_reply_after "$issue_json" "$sent_at" && return 0

  default_option="$(jq -r '.needs_info_default_option // empty' <<< "$state")"
  if [ -z "$default_option" ]; then
    route_to_advisor "$n" needs-info false "$issue_json" || return 1
    NEEDS_INFO_TIMEOUT_ACTION=advisor-routed
    return 0
  fi

  marker="<!-- zf-needs-info-default issue=$n thread=$thread_id -->"
  if jq -e --arg marker "$marker" 'any(.comments[]?; ((.body // "") | contains($marker)))' \
    <<< "$issue_json" >/dev/null 2>&1; then
    marker_exists=1
  else
    marker_exists=0
  fi
  if [ "$marker_exists" = 0 ]; then
    days=$((age / 86400))
    comment_body="$BOT_DISCLAIMER
这个问题已等待${days}天仍未收到回复，因此按问题中写明的默认处理继续：
> $default_option
之后如果你回复更正，流水线仍会读取并把回复贴到问题评论。
$marker"
    guarded_write gh issue comment "$n" --repo "$REPO" --body "$comment_body" || return 1
  fi

  at="$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  decision_patch="$(jq -cn --arg at "$at" --arg option "$default_option" --arg thread "$thread_id" \
    '{needs_info_default_applied:{at:$at,option:$option,thread_id:$thread}}')" || return 1
  state_merge "$n" ". + $decision_patch" || return 1
  needs_info_resume_answered_issue "$n" "$issue_json" || return 1
  NEEDS_INFO_TIMEOUT_ACTION=default-applied
}

# issue_own_open_agent_pr <n> -- 0 if issue owns an open implement PR, 1 if
# none exists, 2 if GitHub could not answer. Read GitHub, not local state: the
# run that opened a PR can die before pr_number reaches state, so state-only
# checks miss orphaned PRs. Callers must keep the current route on status 2.
issue_own_open_agent_pr() {
  local n="$1" rows
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  rows="$(gh pr list --repo "$REPO" --state open --limit 1 --head "agent/issue-$n" --json number 2>/dev/null)" || return 2
  jq -e 'type == "array"' <<< "$rows" >/dev/null 2>&1 || return 2
  [ -n "$(jq -r '.[0].number // empty' <<< "$rows" 2>/dev/null)" ]
}

# Keep failure text stable across issue-number and whitespace changes while
# preserving meaningful differences in the classified reason.
model_policy_normalize_failure_reason() {
  failure_fingerprint "$1"
}

# Record one model-unit failure or transient retry note.
# `evidence` is bounded before persistence; it can contain untrusted logs.
model_policy_record_failure() {
  local n="$1" step="$2" stage="$3" reason="$4" evidence="$5" status="${6:-1}" remove_label="${7:-ready-for-agent}" unit="${8:-}" refund_attempt="${9:-0}" snapshot_json="${10:-}"
  local next stored_step role identity reason_file evidence_file normalized_reason_file failure_patch retry_patch reason_json evidence_json state provider_outage provider_kind pipeline_system_enabled pipeline_system_status=0 open_pr_status=0 loop_limit loop_breaker_advisor=0
  local prior_failure prior_stage prior_reason prior_evidence prior_transition prior_streak previous_normalized_reason normalized_reason same_failure=0 same_streak=0 advisor_seen=false diff_summary="" failure_worktree="" early_stop_json=null prior_reason_argfile current_reason_argfile normalized_reason_argfile diff_summary_argfile
  unit="${unit:-$(state_read "$n" | jq -r '.model_policy.unit // "implement"')}"
  # SIGTERM from systemd stop/shutdown is an interrupted dispatch, not model failure.
  if [ "$unit" = implement ] && [ "$status" = 143 ]; then refund_attempt=1; fi
  state="$(state_read "$n")"
  advisor_seen="$(jq -r '((.model_policy.advisor_decision // "") | tostring | length) > 0' <<< "$state")"
  pipeline_system_enabled="$(jq -r '.pipeline_system.enabled // false' <<< "$state")"
  provider_outage="$(jq -r '.model_policy.active.provider_outage // false' <<< "$state")"
  provider_kind="$(jq -r '.model_policy.active.provider_outage_kind // "transport"' <<< "$state")"
  if [ "${MODEL_CALL_ENVIRONMENTAL_FAILURE:-0}" = 1 ]; then
    provider_outage=true
    provider_kind="${MODEL_CALL_ENVIRONMENTAL_FAILURE_KIND:-agent-tool-exit-127}"
  fi
  if [ "$(jq -r '.model_policy.active.config_fault // false' <<< "$state")" = true ]; then
    state_merge "$n" '.model_policy.retry_note = {reason:"model configuration fault; waiting for role configuration change",recorded_at:(now|todate)} | del(.model_policy.active)' || return 1
    echo "model_policy: #$n $step configuration fault at $stage; kept rung until role configuration changes" >&2
    return 0
  fi
  loop_limit="$(jq -er '.hand_loop_breaker.work_no_progress_limit | select(type == "number" and . > 0)' "$MODEL_POLICY_DEFAULT")" || return 1
  if [ "$provider_outage" = true ]; then
    case "$provider_kind" in
      codex-binary-missing)
        reason="Codex agent binary unavailable; retry the current rung"
        evidence="${MODEL_CALL_ENVIRONMENTAL_FAILURE_DETAIL:-Codex invocation could not start}"
        ;;
      agent-tool-exit-127)
        reason="Agent tool exited 127; retry the current rung"
        evidence="${MODEL_CALL_ENVIRONMENTAL_FAILURE_DETAIL:-agent tool could not start}"
        ;;
      *)
        reason="Codex provider outage ($provider_kind); retry the current rung"
        evidence="Codex transport failure; provider output redacted"
        ;;
    esac
    refund_attempt=1
  fi
  if [ "${#evidence}" -gt 12000 ]; then evidence="${evidence: -12000}"; fi
  [[ "$refund_attempt" == 0 || "$refund_attempt" == 1 ]] || return 64
  if [ "$status" = 124 ] || [ "$provider_outage" = true ] || [ "$refund_attempt" = 1 ]; then
    if [ "$unit" = implement ]; then
      record_implement_failure "$n" "$reason" "$evidence" "$status" "$stage" 1 || return 1
    fi
    reason_file="$(jq_arg_file "$reason")"
    evidence_file="$(jq_arg_file "$evidence")"
    retry_patch="$(jq -nc --arg unit "$unit" --arg step "$step" --arg stage "$stage" \
      --argjson status "$status" --argjson refunded "$refund_attempt" --rawfile reason "$reason_file" --rawfile evidence "$evidence_file" \
      '{unit:$unit,step:$step,stage:$stage,status:$status,attempt_refunded:($refunded == 1),reason:$reason,evidence:$evidence,recorded_at:(now|todate)}')"
    reason_json="$(jq -n --rawfile value "$reason_file" '$value')"
    evidence_json="$(jq -n --rawfile value "$evidence_file" '$value')"
    rm -f -- "$reason_file" "$evidence_file"
    state_merge_attempt_transition "$n" ".model_policy = (.model_policy // {}) | .model_policy.retry_note = $retry_patch | .model_policy.failure |= (if type == \"object\" then .same_failure_streak = 0 else . end) | .last_failure_reason = $reason_json | .last_failure_tail = $evidence_json | .same_failure_streak = 0 | .attempts = (if $refund_attempt == 1 and (.attempts // 0) > 0 then .attempts - 1 else (.attempts // 0) end) | del(.model_policy.active)" \
      || return 1
    if [ "$provider_kind" = codex-binary-missing ] || [ "$provider_kind" = agent-tool-exit-127 ]; then
      echo "model_policy: #$n $step hit $provider_kind at $stage; kept the rung and refunded attempt" >&2
    elif [ "$provider_outage" = true ]; then
      echo "model_policy: #$n $step hit Codex provider outage at $stage; kept the rung and recorded retry note" >&2
    elif [ "$refund_attempt" = 1 ]; then
      echo "model_policy: #$n $step recorded infrastructure retry at $stage: $reason; refunded attempt and kept the rung" >&2
    else
      echo "model_policy: #$n $step recorded transient retry at $stage: $reason; kept the rung" >&2
    fi
    return 0
  fi
  if [ "$unit" = implement ]; then
    record_implement_failure "$n" "$reason" "$evidence" "$status" "$stage" || return 1
  fi
  prior_failure="$(jq -c '.model_policy.failure // {}' <<< "$state")"
  prior_stage="$(jq -r '.stage // ""' <<< "$prior_failure")"
  prior_reason="$(jq -r '.reason // ""' <<< "$prior_failure")"
  prior_transition="$(jq -r '.transition // ""' <<< "$prior_failure")"
  prior_streak="$(jq -r 'if (.same_failure_streak | type) == "number" then .same_failure_streak else 1 end' <<< "$prior_failure")"
  normalized_reason="$(model_policy_normalize_failure_reason "$reason")"
  previous_normalized_reason="$(model_policy_normalize_failure_reason "$(jq -r '.normalized_reason // .reason // ""' <<< "$prior_failure")")"
  if [ "$unit" = implement ] && [ "$(jq -r '.unit // ""' <<< "$prior_failure")" = implement ] \
    && [ "$prior_streak" -gt 0 ] && [ -n "$prior_reason" ] \
    && [ "$prior_stage" = "$stage" ] && [ "$previous_normalized_reason" = "$normalized_reason" ]; then
    same_streak=$((prior_streak + 1))
    if ((same_streak >= loop_limit)); then same_failure=1; fi
  else
    same_streak=1
  fi
  if [ "$same_failure" = 1 ]; then
    if [ "$pipeline_system_enabled" = true ] && [ "$advisor_seen" = false ]; then
      next=advisor
    elif [ "$pipeline_system_enabled" = true ] || { [ "$prior_transition" = advisor ] && [ "$advisor_seen" = true ]; }; then
      next=conclude
    else
      next=advisor
    fi
    prior_evidence="$(jq -r '.evidence // ""' <<< "$prior_failure")"
    if [ "${#prior_evidence}" -gt 2500 ]; then prior_evidence="${prior_evidence: -2500}"; fi
    if [ "${#evidence}" -gt 2500 ]; then evidence="${evidence: -2500}"; fi
    failure_worktree="${WT:-${ZF_WORKTREE_ROOT:-${HOME:-}/wt}/issue-$n}"
    if [ -d "$failure_worktree" ]; then
      diff_summary="$(git -C "$failure_worktree" diff --stat origin/main...HEAD 2>/dev/null || true)"
      if [ -z "$diff_summary" ]; then
        diff_summary="$(git -C "$failure_worktree" show --stat --format= -1 2>/dev/null || true)"
      fi
    fi
    diff_summary="${diff_summary:-No Git diff summary available.}"
    evidence="$(printf 'Repeated classified failure at %s.\n\nPrevious failure: %s\n%s\n\nCurrent failure: %s\n%s\n\nDiff summary:\n%s' \
      "$stage" "$prior_reason" "$prior_evidence" "$reason" "$evidence" "$diff_summary")"
    prior_reason_argfile="$(jq_arg_file "$prior_reason")" || return 1
    current_reason_argfile="$(jq_arg_file "$reason")" || { rm -f -- "$prior_reason_argfile"; return 1; }
    normalized_reason_argfile="$(jq_arg_file "$normalized_reason")" || { rm -f -- "$prior_reason_argfile" "$current_reason_argfile"; return 1; }
    diff_summary_argfile="$(jq_arg_file "$diff_summary")" || { rm -f -- "$prior_reason_argfile" "$current_reason_argfile" "$normalized_reason_argfile"; return 1; }
    if ! early_stop_json="$(jq -nc --arg stage "$stage" --arg prior_stage "$prior_stage" \
      --arg decision "$next" --argjson streak "$same_streak" --argjson advisor_seen "$advisor_seen" \
      --rawfile normalized_reason "$normalized_reason_argfile" --rawfile prior_reason "$prior_reason_argfile" \
      --rawfile reason "$current_reason_argfile" --rawfile diff_summary "$diff_summary_argfile" \
      '{reason:"same-failure",stage:$stage,normalized_reason:$normalized_reason,streak:$streak,decision:$decision,advisor_seen:$advisor_seen,previous_failure:{stage:$prior_stage,reason:$prior_reason},current_failure:{stage:$stage,reason:$reason},diff_summary:$diff_summary,recorded_at:(now|todate)}')"; then
      rm -f -- "$prior_reason_argfile" "$current_reason_argfile" "$normalized_reason_argfile" "$diff_summary_argfile"
      return 1
    fi
    rm -f -- "$prior_reason_argfile" "$current_reason_argfile" "$normalized_reason_argfile" "$diff_summary_argfile"
    if [ "${#evidence}" -gt 12000 ]; then evidence="${evidence: -12000}"; fi
  else
    case "$unit:$step:$stage" in
      triage:work:*|recut:work:*|implement:work:blast-radius|implement:work:risk-class|implement:work:merge-risk-class|implement:work:merge-gate)
        next=advisor
        ;;
      implement:work:*) next=work ;;
      *) next="$(model_policy transition "$step" on_failure)" || return 1 ;;
    esac
  fi
  # Advisor role disabled (the shipped default): skip that step. One work retry, then conclude.
  if [ "$next" = advisor ] && advisor_role_disabled; then
    if [ "$step" = work_retry ] || [ "$same_failure" = 1 ]; then next=conclude; else next=work_retry; fi
  fi
  if [ "$next" = advisor ] || [ "$step" = work_retry ] || [ "$pipeline_system_enabled" = true ]; then
    pipeline_system_route_status "$n" || pipeline_system_status=$?
    case "$pipeline_system_status" in
      0) pipeline_system_enabled=true ;;
      1) pipeline_system_enabled=false ;;
      *) echo "model_policy: #$n -- cannot classify lane; refusing advisor transition" >&2; return 1 ;;
    esac
  fi
  if [ "$pipeline_system_enabled" = true ] && [ "$next" = advisor ]; then
    if [ "$unit" = implement ]; then
      if [ "$step" = work_retry ]; then
        next=conclude
      elif [ "$same_failure" = 1 ] && [ "$step" = work ] \
        && [ "$advisor_seen" = false ]; then
        # V437 keeps ordinary routes fenced; this marker admits only the bounded repeated-failure episode.
        loop_breaker_advisor=1
      elif [ "$same_failure" = 1 ]; then next=conclude
      else next=work_retry
      fi
    else
      pipeline_system_return_to_implement "$n" "$remove_label"
      return $?
    fi
  fi
  if [ "$unit" = implement ] && [ "$step" = work ] && [ "$next" = work ] \
    && [ "$pipeline_system_enabled" != true ]; then
    issue_own_open_agent_pr "$n" || open_pr_status=$?
    case "$open_pr_status" in
      0) next=pr-lane ;;
      2) next=wait ;;
    esac
  fi
  # 2026-10-07, issues #2694/#2721 (#2097 the day before): a work failure on
  # a product ticket that already carries its own open agent PR must not open
  # a new advisor episode. The advisor is the admission oracle; a ticket with
  # its own PR was already admitted into the implement lane, so the episode's
  # outcome is decided in advance -- re-admission, or misclassified -> recut
  # -> recut-refused, either way back to ready-for-agent -- and the next
  # repair failure starts the same episode again. Two locally-correct writers
  # (this ladder's route_to_advisor() and run-advisor-batch.sh's
  # apply_one_ruling()) then flip one ticket until loop_break_check() freezes
  # it with a green PR mid-lane. Keep the failure in the PR lane instead:
  # blocking-pr-recovery owns repair dispatches (bounded by the attempts
  # cap), the merge sweeper owns the green finish. A repeated identical
  # failure still concludes through the same-failure early stop, so this
  # Admission gates are separate from work failures: blast-radius, risk-class,
  # merge-risk-class, and merge-gate decide whether the change may enter or
  # merge; only the advisor can answer them, even when the issue already owns
  # an open PR.
  if [ "$next" = advisor ] && [ "$pipeline_system_enabled" != true ]; then
    case "$stage" in
      blast-radius|risk-class|merge-risk-class|merge-gate) ;;
      *)
        issue_own_open_agent_pr "$n" || open_pr_status=$?
        case "$open_pr_status" in
          0)
            if [ "$same_failure" = 1 ]; then next=conclude; else next=pr-lane; fi
            ;;
          2) next=wait ;;
        esac
        ;;
    esac
  fi
  if [ "$same_failure" = 1 ]; then
    early_stop_json="$(jq -c --arg decision "$next" '.decision = $decision' <<< "$early_stop_json")"
  fi
  stored_step="$next"
  # pr-lane keeps the ladder on its current step, like wait: the ticket never
  # left the work queue, so the next dispatch must not find step=advisor and
  # route instead of running (dispatch_policy_unit's advisor branch).
  case "$next" in wait|pr-lane) stored_step="$step" ;; esac
  role="$(model_policy step-role "$step")" || return 1
  identity="$(model_policy identity "$role")" || return 1
  reason_file="$(jq_arg_file "$reason")"
  evidence_file="$(jq_arg_file "$evidence")"
  normalized_reason_file="$(jq_arg_file "$normalized_reason")"
  failure_patch="$(jq -n --arg unit "$unit" --arg step "$stored_step" --arg transition "$next" --arg failed_step "$step" \
    --arg role "$role" --arg identity "$identity" --arg stage "$stage" \
    --argjson status "$status" --argjson same_streak "$same_streak" --argjson early_stop "$early_stop_json" \
    --rawfile normalized_reason "$normalized_reason_file" --rawfile reason "$reason_file" --rawfile evidence "$evidence_file" \
    '{unit: $unit, step: $step, resume_stage: $unit, failure: ({unit: $unit, step: $failed_step, transition: $transition, role: $role, identity: $identity, stage: $stage, status: $status, reason: $reason, normalized_reason: $normalized_reason, same_failure_streak: $same_streak, evidence: $evidence, recorded_at: (now | todate)} + (if $early_stop == null then {} else {early_stop: $early_stop} end))}')"
  rm -f -- "$reason_file" "$evidence_file" "$normalized_reason_file"
  state_merge "$n" ".model_policy = (.model_policy // {}) + $failure_patch | .model_policy.failures = ((.model_policy.failures // []) + [.model_policy.failure]) | del(.model_policy.active)" || return 1
  if [ "$same_failure" = 1 ]; then
    printf 'implement-early-stop issue=#%s reason=same-failure streak=%s decision=%s stage=%s\n' "$n" "$same_streak" "$next" "$stage" >&2
  fi
  case "$next" in
    work)
      echo "model_policy: #$n $step failed at $stage; requeueing on work role" >&2
      ;;
    work_retry)
      echo "model_policy: #$n $step failed at $stage; retrying once on work role" >&2
      ;;
    advisor)
      if [ "$loop_breaker_advisor" = 1 ]; then
        route_to_advisor "$n" "$remove_label" true "$snapshot_json" hand-loop-breaker || return 1
      else
        route_to_advisor "$n" "$remove_label" true "$snapshot_json" || return 1
      fi
      if [ "$ISSUE_VERDICT_GUARD_SKIPPED" = "1" ]; then
        echo "model_policy: #$n $step failed at $stage; closed or changed issue skipped advisor route" >&2
      else
        echo "model_policy: #$n $step failed at $stage; routed run evidence to web-advisor-provider advisor batch" >&2
      fi
      ;;
    conclude)
      if [ "$unit" = implement ] && [ "$step" = work_retry ] && [ "$advisor_seen" = true ]; then
        local episode hold_status=0
        episode="$(state_read "$n" | jq -r '.model_policy.failure.recorded_at // "unknown"')"
        hold_issue "$n" --holder hand-loop-breaker --expires 168h --kind hand-loop-breaker \
          --release "supervisor reviews the recorded failure and explicitly requeues" || hold_status=$?
        if [ "$hold_status" = 0 ]; then
          supervisor_inbox_append_once "hand-loop-breaker issue=#$n episode=$episode" \
            "hand-loop-breaker issue=#$n action=parked role=work stage=$stage reason=$reason evidence=$evidence" || return 1
        else
          supervisor_inbox_append_once "hand-loop-breaker issue=#$n episode=$episode" \
            "hand-loop-breaker issue=#$n action=park-failed-conclude role=work stage=$stage reason=$reason evidence=$evidence" || true
          record_run_decision "$n" model-policy \
            "Hand loop breaker could not apply hold after the advisor retry; concluding to prevent another automatic work dispatch" 1 || true
          conclude_run "$n" not-completed \
            "Hand loop breaker could not apply hold after the advisor retry. Failure evidence is stored in model_policy.failure." || return 1
          return 0
        fi
        record_run_decision "$n" model-policy \
          "Advisor-guided work retry repeated the same failure; parked for supervisor review" 1 || true
        echo "model_policy: #$n repeated the same failure after advisor-guided retry; parked for supervisor review" >&2
        return 0
      fi
      if [ "$same_failure" = 1 ]; then
        record_run_decision "$n" model-policy "Stopped early after the same classified failure repeated at $stage: $reason" 1
      else
        record_run_decision "$n" model-policy "Configured model escalation exhausted after $stage: $reason" 1
      fi
      if [ "$pipeline_system_enabled" = true ] && [ "$unit" = implement ]; then
        local episode
        episode="$(state_read "$n" | jq -r '.model_policy.failure.recorded_at // "unknown"')"
        supervisor_inbox_append_once \
          "pipeline-system-model-policy issue=#$n episode=$episode" \
          "pipeline-system-model-policy issue=#$n episode=$episode action=concluded stage=$stage reason=$reason" || return 1
      fi
      if [ "$same_failure" = 1 ]; then
        conclude_run "$n" not-completed "Stopped early after the same classified failure repeated at $stage (streak $same_streak): $reason. Both failures and the diff summary are stored in model_policy.failure.early_stop." || return 1
      else
        conclude_run "$n" not-completed "Configured model escalation exhausted after $stage. Failure evidence is stored in model_policy.failure." || return 1
      fi
      ;;
    wait)
      echo "model_policy: #$n routing evidence unavailable; state remains at $step for next tick" >&2
      ;;
    pr-lane)
      echo "model_policy: #$n $step failed at $stage with the issue's own PR still open; staying in the PR repair/final-check lane -- no new advisor episode, no label move" >&2
      ;;
    *)
      echo "model_policy: unrecognized failure transition; issue #$n remains held" >&2
      return 1
      ;;
  esac
}

model_policy_begin_unit() {
  local n="$1" unit="$2" queue_label="${3:-}" current initial unit_json patch filter step attempts
  case "$unit" in triage|recut|implement) ;; *) echo "model_policy: unsupported issue unit '$unit'" >&2; return 64 ;; esac
  current="$(state_read "$n" | jq -r '.model_policy.unit // (if .model_policy.step then "implement" else empty end)')"
  if [ "$current" = "$unit" ]; then
    step="$(state_read "$n" | jq -r '.model_policy.step // empty')"
    if [ "$step" = conclude ]; then
      attempts="$(state_attempts "$n")"
      if [ "$queue_label" = ready-for-agent ] || [ "$attempts" = 0 ]; then
        # The ticket is back in an admission queue, so this conclude belongs
        # to its prior episode. Archive it, clear its failure, then let the
        # existing unit initializer start at the configured initial step.
        state_merge "$n" '.model_policy.history = ((.model_policy.history // []) + [{unit:.model_policy.unit,step:.model_policy.step,failure:.model_policy.failure,advisor_decision:.model_policy.advisor_decision,completed_at:(now|todate),requeued:true}]) | .model_policy |= del(.unit,.step,.active,.failure,.advisor_decision,.resume_stage,.failures)' || return 1
        current=""
      fi
    fi
  fi
  [ "$current" != "$unit" ] || return 0
  initial="$(model_policy initial-step)" || return 1
  unit_json="$(jq -nc --arg unit "$unit" '$unit')"
  patch="$(jq -nc --arg unit "$unit" --arg step "$initial" '{unit:$unit,step:$step}')"
  filter=".model_policy = (.model_policy // {}) | if (.model_policy.unit // \"\") != $unit_json then .model_policy.history = ((.model_policy.history // []) + (if (.model_policy.unit // \"\") == \"\" then [] else [{unit:.model_policy.unit,step:.model_policy.step,failure:.model_policy.failure,advisor_decision:.model_policy.advisor_decision,completed_at:(now|todate)}] end)) | .model_policy |= del(.active,.failure,.advisor_decision,.resume_stage) | .model_policy += $patch else . end"
  filter="${filter//\$unit_json/$unit_json}"
  filter="${filter//\$patch/$patch}"
  state_merge "$n" "$filter"
}

model_policy_mark_started() {
  local n="$1" unit="$2" implement_marker="" implement_sha="" implement_sha_json=null
  if [ "$unit" = implement ]; then
    if [ "$#" -ge 3 ]; then
      implement_sha="$3"
    else
      implement_sha="$(git -C "${REPO_DIR:-.}" rev-parse HEAD 2>/dev/null || true)"
    fi
    if [[ "$implement_sha" =~ ^[0-9a-f]{40,64}$ ]]; then
      implement_sha_json="$(jq -nc --arg sha "$implement_sha" '$sha')"
    fi
    implement_marker=" | if .run.implement_started_attempt == (.attempts // 0) then
      .run.implement_started_at = (.run.implement_started_at // (now | todate))
      | if $implement_sha_json != null then .run.implement_started_sha = (.run.implement_started_sha // $implement_sha_json) else . end
      else .run.implement_started_at = (now | todate)
      | if $implement_sha_json != null then .run.implement_started_sha = $implement_sha_json else del(.run.implement_started_sha) end
      | .run.evidence |= del(.implementation_ended_at,.implementation_head_sha,.implementation_attempt,
        .review_ready_at,.reviewed_head_sha,.review_attempt,.ci_started_at,.ci_completed_at,.ci_green_at,
        .ci_head_sha,.ci_jobs,.ci_attempt)
      end | .run.implement_started_attempt = (.attempts // 0)"
  fi
  state_merge "$n" "if .model_policy.unit == \"$unit\" and .model_policy.active.unit == \"$unit\" then .model_policy.active.model_started = true | .model_policy.active.model_started_at = (now | todate)$implement_marker else . end" || return $?
  [ "$unit" != implement ] || efficiency_metrics_sync_issue_lifecycle "$n"
}

model_policy_complete_unit() {
  local n="$1" unit="$2"
  state_merge "$n" "if .model_policy.unit == \"$unit\" then .model_policy.history = ((.model_policy.history // []) + [{unit:.model_policy.unit,step:.model_policy.step,failure:.model_policy.failure,advisor_decision:.model_policy.advisor_decision,retry_note:.model_policy.retry_note,completed_at:(now|todate)}]) | .model_policy |= del(.unit,.step,.active,.failure,.advisor_decision,.resume_stage,.retry_note) else . end"
}

# complete_recut_parent <n> <children-json> -- finish a successful recut.
#
# A successful split keeps its parent open only as an umbrella: the child
# list and parent comment remain the durable record, but `needs-recut` must
# be removed because it is the scheduler's active-work queue. Leaving that
# label in place after writing recut_children makes the parent permanently
# match the dispatch pre-filter and turns an already-completed split into a
# dead queue entry. Keep the two effects together here so run-recut.sh and
# any future writer cannot update just one half of the transition.
#
# The local marker is deliberately written first. If its write fails, do not
# change the label; if the label edit fails, return non-zero so the caller
# leaves a visible failure and the reconciliation sweep can retry the one
# safe remaining operation without creating another set of children.
retire_recut_parent() {
  local n="$1"
  issue_transition "$n" tracker recut-parent-retired
}

complete_recut_parent() {
  local n="$1" children_json="$2"
  state_merge "$n" ". + {recut_children: $children_json}" || {
    echo "complete_recut_parent: state_merge failed to record recut_children for #$n -- ABORTING the label move" >&2
    return 1
  }
  retire_recut_parent "$n"
}

# One REST read gives this process the live native child list for each parent.
# GitHub caps native children at 100, matching the endpoint's per-page maximum.
declare -gA NATIVE_PARENT_SUBISSUES_CACHE=()
native_parent_subissues_json() {
  local n="$1" raw normalized err_file
  if [[ ${NATIVE_PARENT_SUBISSUES_CACHE[$n]+cached} ]]; then
    [ "${NATIVE_PARENT_SUBISSUES_CACHE[$n]}" != '!unavailable!' ] || return 2
    printf '%s\n' "${NATIVE_PARENT_SUBISSUES_CACHE[$n]}"
    return 0
  fi
  # 2026-10-08 07:37-07:38Z, #2511/#2520: this call's stderr was discarded
  # here, so a transient gh failure aborted the blocker-root reconcile with
  # no output anywhere -- not in the journal, not in the supervisor inbox
  # line. Keep gh's own error as the one-line reason instead.
  err_file="$(mktemp 2>/dev/null)" || err_file=/dev/null
  if ! raw="$(gh api "repos/$REPO/issues/$n/sub_issues?per_page=100" 2>"$err_file")"; then
    NATIVE_PARENT_SUBISSUES_CACHE[$n]='!unavailable!'
    blocker_root_fail "gh api sub_issues failed for #$n: $(head -c 200 "$err_file" | tr '\r\n\t;' '   ,')"
    [ "$err_file" = /dev/null ] || rm -f -- "$err_file"
    return 2
  fi
  [ "$err_file" = /dev/null ] || rm -f -- "$err_file"
  if ! normalized="$(jq -ce '
    def valid:
      type == "object"
      and (.number | type == "number" and . > 0 and . == floor)
      and ((.state | ascii_downcase) == "open" or (.state | ascii_downcase) == "closed")
      and (.closed_at == null or (.closed_at | type == "string"))
      and ((.labels // []) | type == "array")
      and all((.labels // [])[]; type == "object" and (.name | type == "string"));
    if type == "array" and length <= 100 and all(.[]; valid) then
      map({number, state:(.state | ascii_downcase), closed_at:(.closed_at // ""), labels:[.labels[]?.name]})
    else error("invalid sub-issue response") end
  ' <<< "$raw" 2>/dev/null)"; then
    NATIVE_PARENT_SUBISSUES_CACHE[$n]='!unavailable!'
    return 2
  fi
  NATIVE_PARENT_SUBISSUES_CACHE[$n]="$normalized"
  printf '%s\n' "$normalized"
}

# Read permanent recut evidence from local state first. Otherwise, reuse the
# same parent path for native GitHub sub-issues, then try legacy split comments.
recut_parent_children_json() {
  local n="$1" state="${2:-}" allow_comment_fallback="${3:-1}" issue_json marker_text native_json children_json requeued_at last_child_closed_at
  [ -n "$state" ] || state="$(state_read "$n")" || return 2
  if jq -e 'type == "object" and has("recut_children")' <<< "$state" >/dev/null 2>&1; then
    jq -e '(.recut_children | type) == "array" and length > 0 and all(.recut_children[]; type == "number" and . > 0 and . == floor)' \
      <<< "$state" >/dev/null 2>&1 || return 2
    jq -c '.recut_children | unique' <<< "$state"
    return 0
  fi
  native_parent_subissues_json "$n" >/dev/null || return 2
  native_json="${NATIVE_PARENT_SUBISSUES_CACHE[$n]}"
  children_json="$(jq -ce '[.[].number] | unique' <<< "$native_json")" || return 2
  if [ "$(jq 'length' <<< "$children_json")" -gt 0 ]; then
    # Once discovered, the blocker-root sweep keeps monitoring this parent
    # even if an advisor or requeue route leaves it outside ready-for-agent.
    if jq -e '.native_subissue_parent != true' <<< "$state" >/dev/null 2>&1; then
      state_merge "$n" '.native_subissue_parent = true' || return 2
    fi
    if ! jq -e 'any(.[]; .state == "open")' <<< "$native_json" >/dev/null 2>&1; then
      requeued_at="$(jq -r '.requeued_at // empty' <<< "$state")" || return 2
      last_child_closed_at="$(jq -r '[.[].closed_at // ""] | max // ""' <<< "$native_json")" || return 2
      if [ -n "$requeued_at" ] && [[ "$requeued_at" > "$last_child_closed_at" ]]; then
        state_merge "$n" 'del(.native_subissue_parent)' || return 2
        return 1
      fi
      # A sub-issue closed as a duplicate delivered nothing; the parent implements its own work
      # (reconcile_recut_parent_children keeps it open for the same reason).
      if jq -e 'any(.[]; .labels | index("duplicate") != null)' <<< "$native_json" >/dev/null 2>&1; then
        state_merge "$n" 'del(.native_subissue_parent)' || return 2
        return 1
      fi
    fi
    printf '%s\n' "$children_json"
    return 0
  fi
  if jq -e '.native_subissue_parent == true' <<< "$state" >/dev/null 2>&1; then
    state_merge "$n" 'del(.native_subissue_parent)' || return 2
  fi
  [ "$allow_comment_fallback" != 0 ] || return 1
  # Every parent split since recut_children existed records it in state, so a
  # root whose comments carry no split marker never needs a second read. The
  # blocker-root sweep re-read ~65 roots' comments every tick, which pushed the
  # scheduler past its 20 min timeout before release ran (2026-09-28).
  jq -e '.recut_comment_scanned == true' <<< "$state" >/dev/null 2>&1 && return 1
  if ! issue_json="$(gh issue view "$n" --repo "$REPO" --json body,comments 2>/dev/null)"; then
    return 2
  fi
  marker_text="$(jq -r '
    [(.body // ""), (.comments[]?.body // "")]
    | map(select(contains("这张票范围太大，流水线拆成了")))
    | join("\n")
  ' <<< "$issue_json" 2>/dev/null)" || return 2
  if [ -z "$marker_text" ]; then
    state_merge "$n" '.recut_comment_scanned = true' >/dev/null 2>&1 || true
    return 1
  fi
  jq -cn --arg text "$marker_text" --argjson parent "$n" '
    [$text | scan("#[1-9][0-9]*") | ltrimstr("#") | tonumber | select(. != $parent)]
    | unique
  '
}

recut_parent_has_open_child() {
  local n="$1" open_issues_json="${2:-[]}" state_json="${3:-}" allow_comment_fallback="${4:-1}" children child state native_json
  [ -n "$state_json" ] || state_json="$(state_read "$n")" || return 2
  if ! jq -e 'type == "object" and has("recut_children")' <<< "$state_json" >/dev/null 2>&1; then
    native_parent_subissues_json "$n" >/dev/null || return $?
  fi
  children="$(recut_parent_children_json "$n" "$state_json" "$allow_comment_fallback")" || return $?
  native_json="${NATIVE_PARENT_SUBISSUES_CACHE[$n]:-}"
  while IFS= read -r child; do
    [[ "$child" =~ ^[1-9][0-9]*$ ]] || return 2
    if jq -e --argjson child "$child" 'any(.[]; .number == $child and (.state | ascii_downcase) == "open")' \
      <<< "$open_issues_json" >/dev/null 2>&1; then
      return 0
    fi
    if [ -n "$native_json" ] && [ "$native_json" != '!unavailable!' ]; then
      state="$(jq -r --argjson child "$child" '[.[] | select(.number == $child)][0].state // empty' <<< "$native_json")" || return 2
      if [ -n "$state" ]; then
        case "${state^^}" in OPEN) return 0 ;; CLOSED) continue ;; *) return 2 ;; esac
      fi
    fi
    state="$(gh issue view "$child" --repo "$REPO" --json state -q .state 2>/dev/null)" || return 2
    case "${state^^}" in OPEN) return 0 ;; CLOSED) ;; *) return 2 ;; esac
  done < <(jq -r '.[]' <<< "$children")
  return 3
}

# issue_has_open_native_subissue_parent <issue> -- 0 if an open native child
# or roadmap container remains, 1 if neither does, 2 if its state is unknown.
issue_has_open_native_subissue_parent() {
  local n="$1" state native_json roadmap_status
  native_parent_subissues_json "$n" >/dev/null || return 2
  native_json="${NATIVE_PARENT_SUBISSUES_CACHE[$n]}"
  if jq -e 'any(.[]; .state == "open")' <<< "$native_json" >/dev/null; then
    state="$(state_read "$n")" || return 2
    jq -e '.native_subissue_parent == true' <<< "$state" >/dev/null 2>&1 \
      || state_merge "$n" '.native_subissue_parent = true' || return 2
    return 0
  fi
  if declare -F roadmap_issue_is_container >/dev/null; then
    roadmap_issue_is_container "$n" || roadmap_status=$?
    case "${roadmap_status:-0}" in
      0) return 0 ;;
      1) return 1 ;;
      *) return 2 ;;
    esac
  fi
  return 1
}

reconcile_recut_parent_children() {
  local n="$1" children_json="$2" open_issues_json="$3" child dependent_json existing_child_edges child_state child_list native_json native_child_json
  local -a live_children=() dependents=() edit_args=()
  native_json="${NATIVE_PARENT_SUBISSUES_CACHE[$n]:-}"
  dependents_json="$(jq -c --argjson parent "$n" \
    '[.[] | select(any(.blockedBy.nodes[]?; .number == $parent and (.state | ascii_downcase) == "open")) | .number]' \
    <<< "$open_issues_json")" || { blocker_root_fail "umbrella dependents extraction failed for #$n"; return 1; }
  while IFS= read -r child; do
    [[ "$child" =~ ^[1-9][0-9]*$ ]] || { blocker_root_fail "umbrella child list for #$n has a malformed entry '$child'"; return 1; }
    if jq -e --argjson child "$child" 'any(.[]; .number == $child and (.state | ascii_downcase) == "open")' \
      <<< "$open_issues_json" >/dev/null 2>&1; then
      live_children+=("$child")
    else
      child_state=""
      if [ -n "$native_json" ] && [ "$native_json" != '!unavailable!' ]; then
        child_state="$(jq -r --argjson child "$child" '[.[] | select(.number == $child)][0].state // empty' <<< "$native_json")" \
          || { blocker_root_fail "umbrella child #$child state read failed for #$n"; return 1; }
      fi
      [ -n "$child_state" ] || child_state="$(gh issue view "$child" --repo "$REPO" --json state -q .state 2>/dev/null)" \
        || { blocker_root_fail "umbrella child #$child issue view failed for #$n"; return 1; }
      case "${child_state^^}" in CLOSED) ;; OPEN) live_children+=("$child") ;; *) blocker_root_fail "umbrella child #$child has unrecognized state '$child_state'"; return 1 ;; esac
    fi
  done < <(jq -r '.[]' <<< "$children_json")
  if ((${#live_children[@]} == 0)); then
    # A parent requeued after its last child closed still has its own work
    # (issue 1397: reclosed five minutes after a supervisor requeue).
    local requeued_at child_json child_closed_at last_child_closed_at="" all_released=1 duplicate_children=""
    requeued_at="$(state_read "$n" | jq -r '.requeued_at // empty')" \
      || { blocker_root_fail "umbrella requeue timestamp read failed for #$n"; return 1; }
    while IFS= read -r child; do
      native_child_json=""
      if [ -n "$native_json" ] && [ "$native_json" != '!unavailable!' ]; then
        native_child_json="$(jq -c --argjson child "$child" '[.[] | select(.number == $child)][0] // empty' <<< "$native_json")" \
          || { blocker_root_fail "umbrella child #$child record read failed for #$n"; return 1; }
      fi
      if [ -n "$native_child_json" ]; then
        child_closed_at="$(jq -r '.closed_at // empty' <<< "$native_child_json")" \
          || { blocker_root_fail "umbrella child #$child closed-at read failed for #$n"; return 1; }
        jq -e '(.labels // []) | index("released") != null' <<< "$native_child_json" >/dev/null || all_released=0
        ! jq -e '(.labels // []) | index("duplicate") != null' <<< "$native_child_json" >/dev/null \
          || duplicate_children+=" #$child"
      else
        child_json="$(gh issue view "$child" --repo "$REPO" --json closedAt,labels 2>/dev/null)" \
          || { blocker_root_fail "umbrella child #$child closure view failed for #$n"; return 1; }
        child_closed_at="$(jq -r '.closedAt // empty' <<< "$child_json")" \
          || { blocker_root_fail "umbrella child #$child closed-at parse failed for #$n"; return 1; }
        jq -e 'any(.labels[]?; .name == "released")' <<< "$child_json" >/dev/null || all_released=0
        ! jq -e 'any(.labels[]?; .name == "duplicate")' <<< "$child_json" >/dev/null \
          || duplicate_children+=" #$child"
      fi
      [[ "$child_closed_at" > "$last_child_closed_at" ]] && last_child_closed_at="$child_closed_at"
    done < <(jq -r '.[]' <<< "$children_json")
    if [ -n "$requeued_at" ] && [[ "$requeued_at" > "$last_child_closed_at" ]]; then
      state_merge "$n" 'del(.recut_children, .native_subissue_parent) | .recut_comment_scanned = true' \
        || { blocker_root_fail "umbrella keep-after-requeue write failed for #$n"; return 1; }
      echo "issue-pipeline: recut-parent issue=#$n action=kept reason=requeued-after-children requeued_at=$requeued_at last_child_closed_at=$last_child_closed_at" >&2
      return 0
    fi
    # A child closed as a duplicate delivered nothing: on 2026-10-04 child 2425 closed as a duplicate whose
    # work "由 #1141 承担", and this close then shut 1141 as completed with its work undone.
    if [ -n "$duplicate_children" ]; then
      state_merge "$n" 'del(.recut_children, .native_subissue_parent) | .recut_comment_scanned = true' \
        || { blocker_root_fail "umbrella keep-after-duplicate write failed for #$n"; return 1; }
      echo "issue-pipeline: recut-parent issue=#$n action=kept reason=child-closed-as-duplicate children=${duplicate_children# }" >&2
      return 0
    fi
    child_list="$(jq -r 'map("#" + tostring) | join(", ")' <<< "$children_json")" \
      || { blocker_root_fail "umbrella child list build failed for #$n"; return 1; }
    if [ "$all_released" != 1 ]; then
      echo "issue-pipeline: recut-parent issue=#$n action=kept reason=children-not-released children=$child_list" >&2
      return 0
    fi
    if [ -n "$native_json" ] && [ "$native_json" != '!unavailable!' ]; then
      state_merge "$n" 'del(.native_subissue_parent)' \
        || { blocker_root_fail "umbrella native marker clear failed for #$n"; return 1; }
    fi
    issue_transition "$n" released all-children-released \
      || { blocker_root_fail "umbrella released transition failed for #$n"; return 1; }
    guarded_write gh issue close "$n" --repo "$REPO" --comment "$BOT_DISCLAIMER
拆分出的子票 $child_list 均已关闭，汇总票自动关闭。" \
      || { blocker_root_fail "umbrella close write failed for #$n"; return 1; }
    echo "issue-pipeline: recut-parent issue=#$n action=closed children=$child_list" >&2
    BLOCKING_ROOT_GRAPH_CHANGED=1
    return 0
  fi
  while IFS= read -r dependent; do
    [[ "$dependent" =~ ^[1-9][0-9]*$ ]] || continue
    dependent_json="$(jq -c --argjson dependent "$dependent" '[.[] | select(.number == $dependent)][0] // {}' <<< "$open_issues_json")"
    edit_args=(gh issue edit "$dependent" --repo "$REPO")
    for child in "${live_children[@]}"; do
      existing_child_edges="$(jq -r --argjson child "$child" '[.blockedBy.nodes[]? | select(.number == $child and (.state | ascii_downcase) == "open")] | length' <<< "$dependent_json")"
      [ "$existing_child_edges" -gt 0 ] || edit_args+=(--add-blocked-by "$child")
    done
    edit_args+=(--remove-blocked-by "$n")
    guarded_write "${edit_args[@]}" || { blocker_root_fail "umbrella edge transfer write failed for #$n dependent #$dependent"; return 1; }
    BLOCKING_ROOT_GRAPH_CHANGED=1
    child_list="$(IFS=,; echo "${live_children[*]}")"
    echo "issue-pipeline: blocker-root issue=#$n class=recut-umbrella action=transfer-to-children dependent=#$dependent children=$child_list" >&2
  done < <(jq -r '.[]' <<< "$dependents_json")
}

# route_to_recut <n> -- the one write path for sending an issue into a NEW
# recut episode. All writers that apply needs-recut come here so the state
# transition and label transition cannot drift. issue-pipeline.sh's
# needs-recut pre-filter (and run-recut.sh's idempotency check) skip any
# issue whose state has recut_children or recut_refused_at, so a new episode
# must clear only the marker that belongs to a prior, refused episode.
#
# A refusal is not permanent: refuse_and_exit() (run-recut.sh) routes the
# parent to admit_guarded() -> ready-for-agent, which can later return to the
# advisor and receive a genuinely new recut verdict. Clear its old
# recut_refused_at before applying the active queue label.
#
# recut_children is deliberately NOT cleared here, unlike advisor_ruled_at
# in route_to_advisor() above. It is a one-way terminal marker: a successful
# split is completed by complete_recut_parent(), which removes needs-recut
# while retaining the parent as an umbrella. A parent with children cannot
# legitimately begin another recut episode; deleting its marker would allow
# a second run to create duplicate children. Reject that invalid route before
# any label write instead of trying to "heal" it by deleting the marker.
# 2026-09-16 fix (V102's third recurrence, this leg's own twin of
# route_to_advisor()'s fix just above -- same comment, same reasoning):
# check the del() before moving the label. #1256 wedged this exact way,
# from run-advisor-batch.sh's `if apply_one_ruling ...; then`, which
# disables `set -e` for the whole call.
route_to_recut() {
  local n="$1" pipeline_system_status=0 size_evidence="${3:-}"
  if state_read "$n" | jq -e 'has("recut_children")' >/dev/null 2>&1; then
    echo "route_to_recut: #$n already has recut_children -- refusing to reapply needs-recut or delete the permanent child marker" >&2
    return 1
  fi
  pipeline_system_route_status "$n" || pipeline_system_status=$?
  case "$pipeline_system_status" in
    0) pipeline_system_return_to_implement "$n" needs-recut; return $? ;;
    1) ;;
    *) echo "route_to_recut: #$n -- cannot classify lane; refusing recut route" >&2; return 1 ;;
  esac
  # A failed recut goes to advisor; if the advisor sends that same episode
  # back to recut, retain its measured size. A later unrelated recut must not
  # inherit stale size evidence from an old implementation.
  local transition_filter='if .state == "needs-advisor" and .model_policy.failure.unit == "recut" then . else del(.size_admission) end | del(.recut_refused_at, .advisor_convergence_pass, .advisor_convergence_pass_attempt, .web_advisor_provider_job_id, .web_advisor_provider_job_started_at, .web_advisor_provider_job_episode_seq)'
  [[ -z "$size_evidence" ]] || transition_filter+=" | .size_admission = $size_evidence"
  if is_on_hold "$n"; then
    issue_transition "$n" on-hold hold-backfill "$transition_filter"
  else
    issue_transition "$n" needs-recut recut-route "$transition_filter"
  fi
}

issue_is_tracker_parent() {
  state_read "$1" | jq -e '.tracker_parent == true or .state == "tracker"' >/dev/null 2>&1
}

retire_tracker_parent() {
  local n="$1"
  local transition_filter='del(.advisor_ruled_at, .pending_advisor_verdict, .web_advisor_provider_job_id, .web_advisor_provider_job_started_at, .web_advisor_provider_job_episode_seq, .advisor_convergence_pass, .advisor_convergence_pass_attempt) | .advisor_episode_seq = ((.advisor_episode_seq // 0) + 1) | .tracker_parent = true | .hold = null'
  issue_transition "$n" tracker recut-parent-retired "$transition_filter"
}

# Failed attempts on one issue: stop retrying THIS leg, hand it to the
# advisor for a fresh episode instead -- a different script, possibly a
# different model/provider, gets a shot before anyone parks.
# 2026-09-12 bug: this added needs-owner but left whatever state label made
# the issue eligible (needs-triage, ready-for-agent, ...) in place, so the
# poller kept re-selecting the same poison-pill issue every tick forever
# (breaking "exactly one state label" too). Strip every other state label in
# the same call.
# 2026-09-15 (maintainer ruling, verbatim: [...]
# ): needs-owner is the same banned human terminal as
# ready-for-human -- a queue nobody is assigned to drain is not a queue. No
# code path in this pipeline may add it any more; a repeated tool/model
# failure routes to needs-advisor instead, same destination
# enforce_autonomy_gate()'s own refusals use. Can't call route_to_advisor()
# (lib.sh) directly here: that helper only ever strips the ONE label named
# in its $2 (default ready-for-agent), but this call site's issue can be
# eligible from any prior state (needs-triage, ready-for-agent, ...) and
# still needs the full ALL_STATE_LABELS strip below to hold "exactly one
# state label" -- so this replicates route_to_advisor's other effect
# (clearing a stale advisor_ruled_at, so a fresh advisor episode is
# actually dispatchable) inline instead of bending that helper's contract.
#
# A provider quota hold suppresses this ticket-local terminal only when this
# same provider caused the current failure.
give_up_on_issue() {
  local n="$1" reason="$2" quota_provider="${3:-}" issue_json="${4:-}" pipeline_system_status=0 readable_reason
  if [ -n "$quota_provider" ] && provider_quota_exhausted "$quota_provider"; then
    echo "give_up_on_issue: refusing #$n -- $quota_provider provider quota hold is open" >&2
    return 1
  fi
  pipeline_system_route_status "$n" "$issue_json" || pipeline_system_status=$?
  case "$pipeline_system_status" in
    0)
      echo "give_up_on_issue: #$n is pipeline-system; returning it to implementation instead of advisor" >&2
      pipeline_system_return_to_implement "$n"
      return $?
      ;;
    1) ;;
    *) echo "give_up_on_issue: #$n -- cannot classify lane; refusing advisor route" >&2; return 1 ;;
  esac
  if advisor_role_disabled; then
    echo "give_up_on_issue: #$n -- advisor role disabled; holding for the maintainer" >&2
    hold_for_missing_advisor "$n"
    return $?
  fi
  local admission=0
  advisor_retry_admission "$n" || admission=$?
  case "$admission" in
    0) ;;
    10) return 0 ;;
    *) return "$admission" ;;
  esac
  # Same guard as route_to_advisor()/route_to_recut() (2026-09-16, V102's
  # third recurrence): do not move the label if the clear itself failed.
  # .pending_advisor_verdict cleared alongside .advisor_ruled_at as of
  # 2026-09-19, same reasoning as route_to_advisor()'s own comment on its
  # twin del() -- this call site starts a fresh advisor episode too (a
  # different leg's repeated failure routing here for "a fresh look"), and
  # a verdict left over from whatever the LAST advisor episode computed
  # must not be eligible for that fresh episode's own resume check to
  # silently reuse. advisor_episode_seq incremented in this SAME call, same
  # day, same reasoning as route_to_advisor()'s own twin addition just
  # above it in this file -- see that function's own comment for the race
  # (a web-advisor-provider job still in flight from the episode THIS call is
  # ending) this closes.
  local transition_filter='del(.advisor_ruled_at, .pending_advisor_verdict, .web_advisor_provider_job_id, .web_advisor_provider_job_started_at, .web_advisor_provider_job_episode_seq) | .advisor_episode_seq = ((.advisor_episode_seq // 0) + 1)'
  if is_on_hold "$n"; then
    issue_transition "$n" on-hold hold-backfill "$transition_filter" || return 1
  else
    issue_transition "$n" needs-advisor attempts-exhausted "$transition_filter" || return 1
  fi
  guarded_write gh issue comment "$n" --repo "$REPO" --body "$BOT_DISCLAIMER
$reason after $(state_attempts "$n") attempts. Routed to the advisor for a fresh look before another automated attempt."
  readable_reason="$(_maintainer_readable_or_fallback "$reason" "这一轮没能改完，已转给顾问继续判断。")"
  notify_email "$n" "[example] #$n 已转给顾问了" \
    "$readable_reason" \
    "问题还没有解决，顾问会继续判断。" \
    "通常不用管；进展会保留在这条 issue 里。" || true
}

# --- concluding a run: an account of itself, never a park with a label ------
# docs/agents/issue-pipeline.md "Every run concludes with an account of
# itself" -- maintainer ruling, verbatim, 2026-09-15: [...]
#  Built here
# (2026-09-15) by run-implement.sh's own owner, for run-implement.sh's own
# need -- the two primitives the doc specifies and marks "routed, not made
# [t]here": record_run_decision (an append-only log entry) and conclude_run
# (the one guarded terminal). Scope, stated plainly, as of the 2026-09-15
# build: this did NOT rewrite give_up_on_issue() (used, unchanged, by
# run-triage.sh/run-advisor.sh/run-recut.sh -- files that session did not
# own or test) or wire rung tracking into those legs' own dispatch code (the
# doc's own routing: "run-advisor.sh/run-recut.sh/run-triage.sh -- one
# record_run_decision call at each verdict", not built there).
# run-implement.sh calls conclude_run directly at its own terminal points
# instead of calling give_up_on_issue(). Since converted (2026-09-15, same
# night): run-advisor.sh's own fail_attempt() also calls conclude_run
# directly now, same as run-implement.sh -- see run-advisor.sh's fail_attempt
# for its own not-completed guard. give_up_on_issue() is still live: called
# by run-triage.sh and run-recut.sh (both still give-up-after-3, at their own
# gate-side terminal -- ownership/scope resolution, not an in-flight stop),
# and by run-implement.sh's own fail_attempt() up until this same commit,
# whose 4-attempt terminal was the one give_up_on_issue() call site missed
# when the rest of this file converted (see run-implement.sh's fail_attempt()
# for the fix and #1221 for the live incident it caused).

# record_run_decision <n> <by> <what> [forced] -- appends one entry to the
# run's decision log (.run.decisions[]), never overwrites a prior one.
# $by: advisor|wrapper|reviewer|recut (who actually decided, on the
# maintainer's behalf). $forced ("1"/"0", default "0"): was this decision
# forced by a cap/fault/missing capability rather than chosen.
record_run_decision() {
  local n="$1" by="$2" what="$3" forced="${4:-0}" entry forced_json what_file
  [ "$forced" = "1" ] && forced_json=true || forced_json=false
  # $what is untrusted-size: callers splice a model's own reasoning_md/
  # decision_md into it (e.g. run-advisor-batch.sh's duplicate-verdict call)
  # -- jq_arg_file() (above), not --arg, so a long one never risks argv.
  what_file="$(jq_arg_file "$what")"
  entry="$(jq -n --arg by "$by" --rawfile what "$what_file" --argjson forced "$forced_json" \
    '{at: (now | todate), by: $by, what: $what, forced: $forced}')"
  rm -f "$what_file"
  state_merge "$n" ".run.entered_at = (.run.entered_at // (now | todate)) | .run.decisions = ((.run.decisions // []) + [$entry])"
}

# The bound every conclude_run "not-completed" refusal is measured against --
# the same give-up-at-4 threshold fail_attempt() (run-implement.sh) already
# enforces everywhere else; not re-derived, just named once here so both
# sides read the identical number.
CONCLUDE_RUN_ATTEMPT_CAP=4

# recorded_failure_reason_from_state <state-json> -- prefer the current guard
# or failure reason, then the persisted review/failure evidence.
recorded_failure_reason_from_state() {
  jq -r '
    [.guard_reason, .last_failure_reason,
     .model_policy.failure.normalized_reason, .model_policy.failure.reason,
     .last_failure_tail, .review_verdict]
    | map(select(type == "string" and length > 0))
    | first // ""
  ' <<< "$1"
}

# 0: a new episode is allowed; 10: a bounded conclusion was recorded.
# Routing, re-dispatch and process restart never reset the persisted budget.
# An UNREADABLE attempt count is not an admission decision: this gate only
# refuses when the persisted count is a known number at or above the cap.
# When state is malformed, admission steps aside loudly and lets the
# caller's own guards fire -- state_merge will fail there and abort with a
# distinguishing message (lib.test.sh "the abort is loud"), instead of this
# gate short-circuiting the route into a silent return that moved nothing
# and explained nothing (PR #1355 CI, first run).
advisor_retry_admission() {
  local n="$1" attempts state policy_unit policy_step failure_reason
  state="$(state_read "$n")"
  policy_unit="$(jq -r '.model_policy.unit // empty' <<< "$state")"
  policy_step="$(jq -r '.model_policy.step // empty' <<< "$state")"
  # A model failure has already advanced its unit to the advisor step before
  # route_to_advisor() reaches this gate. The persistent ladder owns its
  # bound; legacy attempt counts must not conclude a policy-managed unit.
  if [ -n "$policy_unit" ] && [ "$policy_step" = advisor ]; then return 0; fi
  attempts="$(state_attempts "$n")" || {
    echo "advisor admission: cannot read attempt state for #$n -- standing aside; the caller's state guards will fail loudly if state is broken" >&2
    return 0
  }
  case "$attempts" in
    ''|*[!0-9]*)
      echo "advisor admission: invalid attempt state for #$n -- standing aside; the caller's state guards will fail loudly if state is broken" >&2
      return 0 ;;
  esac
  [ "$attempts" -lt "$CONCLUDE_RUN_ATTEMPT_CAP" ] && return 0
  record_run_decision "$n" wrapper "Advisor retry admission exhausted after $attempts attempts" 1 || return 1
  failure_reason="$(recorded_failure_reason_from_state "$state")"
  [ -n "$failure_reason" ] || failure_reason="No further advisor episode was admitted after $attempts attempts. The preceding failure requires a changed input, capability or environment; routing cannot reset the retry budget."
  conclude_run "$n" not-completed "$failure_reason" || return 1
  return 10
}

# release_feature_evidence_valid <n> <evidence> -- require evidence to name an
# exercised feature surface; photo tickets require the actual attachment path.
release_feature_evidence_valid() {
  local n="$1" evidence="$2" state brief surface surface_matches=0 token cjk photo_bytes i
  RELEASE_SURFACE_UNCOVERED=0
  state="$(state_read "$n")"
  if ! grep -Eq '^Feature surface: .{8,}$' <<< "$evidence"; then
    echo "release evidence: refusing #$n -- feature surface is unnamed" >&2
    return 1
  fi
  brief="$(jq -r '[(.title // ""),(.brief_md // "")] | join("\n")' <<< "$state" | tr '[:upper:]' '[:lower:]')"
  surface="$(sed -n 's/^Feature surface: //p' <<< "$evidence" | tr '[:upper:]' '[:lower:]' | head -n1)"
  # ponytail: token overlap is a cheap surface matcher; replace with explicit feature IDs if ticket metadata gains them.
  if [ -n "$brief" ] && [[ ! "$brief" =~ (photo|image|multimodal|attachment|图片|照片|多模态|附件) ]]; then
    while IFS= read -r token; do
      case "$token" in
        about|across|after|again|agent|allow|and|any|apply|based|before|between|build|change|changed|check|client|code|could|create|critical|data|default|design|detail|during|each|enable|every|example|existing|feature|file|first|flow|from|function|generic|image|include|input|issue|must|need|new|only|other|path|please|product|production|release|request|required|result|same|send|service|should|show|state|support|system|test|tests|through|ticket|under|user|using|value|when|with|work|works|worker|write) continue ;;
      esac
      if [[ "$surface" == *"$token"* ]]; then surface_matches=1; break; fi
    done < <(grep -Eio '[[:alpha:]][[:alnum:]_-]{4,}' <<< "$brief" | sort -u || true)
    if [ "$surface_matches" != 1 ]; then
      while IFS= read -r cjk; do
        for ((i = 0; i + 1 < ${#cjk}; i++)); do
          token="${cjk:i:2}"
          if [[ "$surface" == *"$token"* ]]; then surface_matches=1; break 2; fi
        done
      done < <(grep -Eo '[一-龥]{2,}' <<< "$brief" || true)
    fi
    if [ "$surface_matches" != 1 ]; then
      # 2026-09-24 ruling: a feature the automated acceptance cannot exercise
      # closes at deploy and the reporter reopens it if broken. Refusing here
      # reran the full production E2E every tick (issue 1211). Photo tickets
      # below still need the real photo path.
      RELEASE_SURFACE_UNCOVERED=1
      echo "release evidence: #$n feature surface is not exercised by the automated acceptance; closing at deploy per the 2026-09-24 ruling" >&2
    fi
  fi
  if [[ "$brief" =~ (photo|image|multimodal|attachment|图片|照片|多模态|附件) ]]; then
    photo_bytes="$(sed -nE 's/^Photo attachment: ([0-9]+) bytes$/\1/p' <<< "$evidence" | head -n1)"
    if [[ "$evidence" != *"Feature surface: photo attachment send through /chat/"* ]] \
      || ! [[ "$photo_bytes" =~ ^[0-9]+$ ]] || (( photo_bytes < 250000 || photo_bytes > 500000 )) \
      || ! grep -Eq '^Photo upload: POST /chat/api/v1/files/ -> [23][0-9]{2} \(finished\)$' <<< "$evidence" \
      || ! grep -Eq '^Photo completion: POST /chat/api/chat/completions -> [23][0-9]{2} \(finished\)$' <<< "$evidence" \
      || ! grep -Eq '^Visible assistant reply: yes \([1-9][0-9]* chars\)$' <<< "$evidence"; then
      echo "release evidence: refusing #$n -- photo/attachment feature needs a 250-500 KB upload, successful chat completion, and visible assistant reply" >&2
      return 1
    fi
  fi
  return 0
}

# Close-contract refusals depend on ticket revision; acceptance depends on SHA.
release_close_state_revision() {
  jq -c '[.state, .requeued_at, .run.implement_started_at, .run.concluded_at,
    .run.previous_concluded_at, .run.evidence.pr_number, .run.evidence.merged_pr,
    .run.evidence.mandatory_checks.status, .run.evidence.mandatory_checks.head_sha]'
}

release_close_refusal_seen() {
  local n="$1" sha="$2" state revision
  [[ "$n" =~ ^[1-9][0-9]*$ && "$sha" =~ ^[a-f0-9]{40,64}$ ]] || return 64
  state="$(state_read "$n")" || return 2
  jq -e 'type == "object" and ((.release_close_refusals // {}) | type == "object")' \
    <<< "$state" >/dev/null 2>&1 || return 2
  revision="$(release_close_state_revision <<< "$state")" || return 2
  jq -e --arg sha "$sha" --argjson revision "$revision" '
    .release_close_contract_refusal_revision == $revision
    or ((.release_close_refusals[$sha] // "") | . != "" and . != "close-contract-failed")
  ' <<< "$state" >/dev/null 2>&1
}

release_close_refusal_record() {
  local n="$1" sha="$2" reason="$3" state sha_json reason_json reason_file revision
  [[ "$n" =~ ^[1-9][0-9]*$ && "$sha" =~ ^[a-f0-9]{40,64}$ && -n "$reason" ]] || return 64
  state="$(state_read "$n")" || return 2
  jq -e 'type == "object" and ((.release_close_refusals // {}) | type == "object")' \
    <<< "$state" >/dev/null 2>&1 || return 2
  if [ "$reason" = close-contract-failed ]; then
    revision="$(release_close_state_revision <<< "$state")" || return 2
    state_merge "$n" ".release_close_contract_refusal_revision = $revision"
    return $?
  fi
  sha_json="$(jq -Rn --arg value "$sha" '$value')" || return 1
  reason_file="$(jq_arg_file "$reason")" || return 1
  reason_json="$(jq -Rn --rawfile value "$reason_file" '$value')" || { rm -f -- "$reason_file"; return 1; }
  rm -f -- "$reason_file"
  state_merge "$n" ".release_close_refusals = ((.release_close_refusals // {}) + {($sha_json): $reason_json})"
}

release_close_refusal_comment_once() {
  local n="$1" reason="$2" body="$3" state last_reason comments_json prior_reason reason_json reason_file
  state="$(state_read "$n")" || return 1
  last_reason="$(jq -r '.release_close_last_comment_reason // empty' <<< "$state")" || return 1
  if [ -z "$last_reason" ]; then
    if comments_json="$(gh issue view "$n" --repo "$REPO" --json comments -q .comments 2>/dev/null)"; then
      prior_reason="$(jq -r \
        --arg evidence "this ticket's acceptance evidence did not satisfy its close contract" \
        --arg preparation "ticket-specific close preparation failed" \
        --arg close "this ticket's close contract failed" \
        'if type == "array" then ([.[] | (.body? // "") | if contains($evidence) then "acceptance-evidence-rejected" elif contains($preparation) then "close-preparation-failed" elif contains($close) then "close-contract-failed" else empty end] | last // "") else "" end' \
        <<< "$comments_json")" || return 1
      if [ "$prior_reason" = "$reason" ]; then
        reason_file="$(jq_arg_file "$reason")" || return 1
        reason_json="$(jq -Rn --rawfile value "$reason_file" '$value')" || { rm -f -- "$reason_file"; return 1; }
        rm -f -- "$reason_file"
        state_merge "$n" ".release_close_last_comment_reason = $reason_json" || return 1
        echo "run-release: suppressing repeated close-refusal comment for #$n (reason=$reason)" >&2
        return 0
      fi
    else
      echo "run-release: suppressing close-refusal comment for #$n -- previous comments are unreadable" >&2
      return 0
    fi
  elif [ "$last_reason" = "$reason" ]; then
    echo "run-release: suppressing repeated close-refusal comment for #$n (reason=$reason)" >&2
    return 0
  fi
  if ! guarded_issue_comment "$n" "$body"; then
    echo "run-release: close-refusal comment failed for #$n" >&2
    return 0
  fi
  reason_file="$(jq_arg_file "$reason")" || return 1
  reason_json="$(jq -Rn --rawfile value "$reason_file" '$value')" || { rm -f -- "$reason_file"; return 1; }
  rm -f -- "$reason_file"
  state_merge "$n" ".release_close_last_comment_reason = $reason_json"
}

release_close_refusal_note() {
  local n="$1" sha="$2" reason="$3" body="$4"
  release_close_refusal_record "$n" "$sha" "$reason" || return 1
  release_close_refusal_comment_once "$n" "$reason" "$body"
}

# record_deploy_evidence <n> <sha> <real-user-path-evidence> -- stores the
# evidence `run-release.sh` extracted from one authenticated browser run.
# `conclude_run deployed` verifies this exact record before closing, so a
# deploy/readback alone can never take the close path.
record_deploy_evidence() {
  local n="$1" deployed_sha="$2" evidence="$3" state pr_number outcome deploy_state evidence_file evidence_json sha_json
  state="$(state_read "$n")"
  pr_number="$(echo "$state" | jq -r '.run.evidence.pr_number // empty')"
  outcome="$(echo "$state" | jq -r '.run.outcome // empty')"
  deploy_state="$(echo "$state" | jq -r '.deploy_state // empty')"
  # Empty deploy_state is the one-way migration shape from the former
  # close-at-merge record: it already proves a merge, but predates this
  # handoff field. New merges always arrive here as pending.
  if [ -z "$pr_number" ] || [ "$outcome" != "merged" ] \
    || { [ -n "$deploy_state" ] && [ "$deploy_state" != "pending" ] && [ "$deploy_state" != "deployed" ]; }; then
    echo "record_deploy_evidence: refusing #$n -- merged outcome with empty/pending deploy_state required (pr_number=${pr_number:-<empty>} outcome=${outcome:-<empty>} deploy_state=${deploy_state:-<empty>})" >&2
    return 1
  fi
  if [ -z "$deployed_sha" ] || [[ "$evidence" != *"URL:"* ]] || [[ "$evidence" != *"Visible DOM:"* ]] || [[ "$evidence" != *"Same-run network:"* ]]; then
    echo "record_deploy_evidence: refusing #$n -- production proof requires deployed SHA plus URL, visible DOM, and same-run network evidence" >&2
    return 1
  fi
  release_feature_evidence_valid "$n" "$evidence" || return 1
  evidence_file="$(jq_arg_file "$evidence")"
  evidence_json="$(jq -n --rawfile e "$evidence_file" '$e')"
  rm -f "$evidence_file"
  sha_json="$(jq -n --arg sha "$deployed_sha" '$sha')"
  state_merge "$n" ".run.evidence.production_evidence_at = (if .deployed_sha == $sha_json then (.run.evidence.production_evidence_at // (now | todate)) else (now | todate) end) | .run.evidence.production_evidence_attempt = (if .deployed_sha == $sha_json then (.run.evidence.production_evidence_attempt // (.attempts // 0)) else (.attempts // 0) end) | .deploy_state = \"deployed\" | .deployed_sha = $sha_json | .run.evidence.real_user_path = $evidence_json" || return $?
  efficiency_metrics_sync_issue_lifecycle "$n"
}

# record_mandatory_check_receipt <issue> <status> <head-sha> <summary>
# Status is replaced for each checked head; replaying the same receipt keeps
# its original timestamp and any later exact-head CI evidence.
record_mandatory_check_receipt() {
  local n="$1" status="$2" head_sha="$3" summary="${4:-}" receipt_json status_json head_json summary_json filter
  case "$status" in passed|deferred|blocked|failed|missing) ;; *) return 2 ;; esac
  if [ -n "$head_sha" ] && ! [[ "$head_sha" =~ ^[0-9a-f]{40,64}$ ]]; then return 2; fi
  receipt_json="$(jq -nc --arg status "$status" --arg head_sha "$head_sha" --arg summary "$summary" \
    '{status:$status,head_sha:$head_sha,summary:$summary}')" || return 1
  status_json="$(jq -Rn --arg value "$status" '$value')" || return 1
  head_json="$(jq -Rn --arg value "$head_sha" '$value')" || return 1
  summary_json="$(jq -Rn --arg value "$summary" '$value')" || return 1
  filter="if (.run.evidence.mandatory_checks.status == $status_json and .run.evidence.mandatory_checks.head_sha == $head_json and .run.evidence.mandatory_checks.summary == $summary_json) then . else .run.evidence.mandatory_checks = ($receipt_json + {recorded_at:(now|todate)}) | del(.run.evidence.ci_outcome,.run.evidence.ci_head_sha) end"
  state_merge "$n" "$filter"
}

# mandatory_check_receipt_ready <issue> <expected-head-sha>
# Fails only when the receipt for this exact head says blocked or failed.
mandatory_check_receipt_ready() {
  local n="$1" expected_sha="$2" state status receipt_sha
  state="$(state_read "$n")" || return 1
  status="$(jq -r '.run.evidence.mandatory_checks.status // empty' <<< "$state")"
  receipt_sha="$(jq -r '.run.evidence.mandatory_checks.head_sha // empty' <<< "$state")"
  # Only a run's own claim that this exact head's checks were blocked or failed stops the
  # terminal. Hand PRs, PRs opened before receipts existed, and heads pushed after the
  # receipt carry none, and the merge gate already required exact-head CI; requiring a
  # receipt refused every in-flight PR and every awaiting-release ticket (2026-10-04).
  [ -n "$status" ] && [ "$receipt_sha" = "$expected_sha" ] || return 0
  case "$status" in
    blocked|failed) return 1 ;;
    *) return 0 ;;
  esac
}

# A sandbox signature is not a real check blocker when the pipeline runs
# unsandboxed. Keep this list shared by intake and parked-ticket recovery.
checks_blocked_line_is_sandbox_signature() {
  local line="${1,,}"
  [[ "$line" == *"blocked by the sandbox policy"* ]] && return 0
  [[ "$line" == *"operation not permitted"* && "$line" == *"user bus"* ]] && return 0
  [[ "$line" == *"gh"* && "$line" == *"disabled by execution policy"* ]] && return 0
  [[ "$line" == *"read-only file system"* ]] && return 0
  [[ "$line" == *"tsx"* && "$line" == *"pipe"* && "$line" == *"eperm"* ]] && return 0
  return 1
}

checks_blocked_summary_is_sandbox_only() {
  local line found=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    found=1
    checks_blocked_line_is_sandbox_signature "$line" || return 1
  done <<< "$1"
  [ "$found" -eq 1 ]
}

checks_blocked_escalate_repeat() {
  local n="$1" head_sha="$2" summary="$3" state auto_head escalated_head head_json
  state="$(state_read "$n")" || return 1
  auto_head="$(jq -r '.checks_blocked.auto_requeued_head_sha // empty' <<< "$state")" || return 1
  escalated_head="$(jq -r '.checks_blocked.escalated_head_sha // empty' <<< "$state")" || return 1
  [ "$auto_head" = "$head_sha" ] && [ "$escalated_head" != "$head_sha" ] || return 0
  supervisor_inbox_append_once "checks-blocked-repeat issue=#$n head=$head_sha" \
    "checks-blocked-repeat issue=#$n head=$head_sha action=review-required-checks checks=$summary" || return 1
  head_json="$(jq -Rn --arg value "$head_sha" '$value')" || return 1
  state_merge "$n" ".checks_blocked = ((.checks_blocked // {}) + {escalated_head_sha:$head_json,escalated_at:(now|todate)})"
}

# Each tick owns parked checks-blocked issues: release recovered blockers or
# retry once after the bound, then let record_implement_blocked_checks escalate repeats.
checks_blocked_sweep() {
  local numbers n state status head_sha summary recorded_at recorded_epoch auto_head repeat_head escalated_head
  local now should_requeue failure=0 head_json summary_json
  numbers="$(gh issue list --repo "$REPO" --limit 1000 --label checks-blocked --state open --json number --jq '.[].number')" || return 1
  now="$(date +%s)" || return 1
  while IFS= read -r n; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    state="$(state_read "$n")" || { failure=1; continue; }
    status="$(jq -r '.run.evidence.mandatory_checks.status // empty' <<< "$state")" || { failure=1; continue; }
    [ "$status" = blocked ] || continue
    head_sha="$(jq -r '.run.evidence.mandatory_checks.head_sha // empty' <<< "$state")" || { failure=1; continue; }
    [ -n "$head_sha" ] || continue
    summary="$(jq -r '.run.evidence.mandatory_checks.summary // empty' <<< "$state")" || { failure=1; continue; }
    auto_head="$(jq -r '.checks_blocked.auto_requeued_head_sha // empty' <<< "$state")" || { failure=1; continue; }
    repeat_head="$(jq -r '.checks_blocked.repeat_head_sha // empty' <<< "$state")" || { failure=1; continue; }
    escalated_head="$(jq -r '.checks_blocked.escalated_head_sha // empty' <<< "$state")" || { failure=1; continue; }
    if [ "$repeat_head" = "$head_sha" ] && [ "$escalated_head" != "$head_sha" ]; then
      checks_blocked_escalate_repeat "$n" "$head_sha" "$summary" || failure=1
      continue
    fi
    [ "$auto_head" != "$head_sha" ] || continue

    should_requeue=0
    if [ "$CODEX_SANDBOX_MODE" = danger-full-access ] && checks_blocked_summary_is_sandbox_only "$summary"; then
      should_requeue=1
    else
      recorded_at="$(jq -r '.run.evidence.mandatory_checks.recorded_at // empty' <<< "$state")" || { failure=1; continue; }
      recorded_epoch="$(agent_epoch "$recorded_at" 2>/dev/null || echo 0)"
      [[ "$recorded_epoch" =~ ^[0-9]+$ ]] || recorded_epoch=0
      if (( recorded_epoch > 0 && now - recorded_epoch >= CHECKS_BLOCKED_MAX_AGE_SECONDS )); then
        should_requeue=1
      fi
    fi
    [ "$should_requeue" -eq 1 ] || continue
    is_on_hold "$n" && continue
    if ! state_requeue "$n"; then
      echo "checks_blocked_sweep: could not requeue #$n" >&2
      failure=1
      continue
    fi
    head_json="$(jq -Rn --arg value "$head_sha" '$value')" || { failure=1; continue; }
    summary_json="$(jq -Rn --arg value "$summary" '$value')" || { failure=1; continue; }
    if ! state_merge "$n" ".checks_blocked = ((.checks_blocked // {}) + {auto_requeued_head_sha:$head_json,auto_requeued_summary:$summary_json,auto_requeued_at:(now|todate)})"; then
      echo "checks_blocked_sweep: #$n requeued but could not record head guard" >&2
      failure=1
    fi
  done <<< "$numbers"
  [ "$failure" -eq 0 ]
}

# record_implement_blocked_checks <issue> <worktree> <model-log>
# Returns 1 when no actionable marker remains; otherwise parks the issue and
# escalates a second block on the same auto-requeued head.
record_implement_blocked_checks() {
  local n="$1" worktree="$2" log_file="$3" summary head_sha state_before auto_head repeat_head repeat_filter="" line filtered_summary="" failure_json transition_filter
  [ -r "$log_file" ] || return 2
  # 2026-10-05: issues 2146, 2184, 2388 and 2465 sat in checks-blocked over checks the sandbox cannot run but
  # the wrapper runs outside it anyway: check-rulings.sh (push preflight), git diff --check, the commit
  # itself, and changed scripts/**/*.test.{sh,mjs} suites (run_package_gates reruns them).
  # git fetch/rebase/pull/push (2151, 2159, 2164: read-only .git in the sandbox) belong to the wrapper too.
  # Later the same day 1243 and 1267 (tsx pipe EPERM in `pnpm --filter X test`), 1703, 2186, 2351
  # and 2491 (graph CLIs), and 1857, 1941, 1989, 2257, 2358 and 2543 (docker, gh, curl, browser,
  # E2E) sat there too: the package gates rerun build/test/typecheck outside the sandbox, graph
  # tools are advisory, and PR CI and the release step own the rest.
  summary="$(awk '
    /^BLOCKED-CHECKS:/ && /check-rulings\.sh|git diff --check|git commit|git (fetch|rebase|pull|push)|(scripts|engine)\/[^ ]*\.test\.(sh|mjs)/ { next }
    /^BLOCKED-CHECKS:/ && /pnpm (--filter [^ ]+ )?(run )?(test|build|typecheck)([^:a-z]|$)/ { next }
    /^BLOCKED-CHECKS:/ && /gitnexus/ { next }
    /^BLOCKED-CHECKS:/ && /docker|ssh |curl |wget |`gh |E2E|浏览器|browser/ { next }
    /^BLOCKED-CHECKS:[[:space:]]*[^[:space:]]/ && count < 10 {
      line = $0
      sub(/^BLOCKED-CHECKS:[[:space:]]*/, "", line)
      printf "%s%s", count++ ? "\n" : "", substr(line, 1, 500)
    }
  ' "$log_file")" || return 2
  if [ "$CODEX_SANDBOX_MODE" = danger-full-access ]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      checks_blocked_line_is_sandbox_signature "$line" && continue
      filtered_summary="${filtered_summary:+$filtered_summary$'\n'}$line"
    done <<< "$summary"
    summary="$filtered_summary"
  fi
  [ -n "$summary" ] || return 1
  head_sha="$(git -C "$worktree" rev-parse HEAD)" || return 2
  state_before="$(state_read "$n")" || return 2
  auto_head="$(jq -r '.checks_blocked.auto_requeued_head_sha // empty' <<< "$state_before")" || return 2
  repeat_head="$(jq -r '.checks_blocked.repeat_head_sha // empty' <<< "$state_before")" || return 2
  [ "$auto_head" != "$head_sha" ] || repeat_filter=" | .checks_blocked = ((.checks_blocked // {}) + {repeat_head_sha:$(jq -Rn --arg value "$head_sha" '$value')})"
  record_mandatory_check_receipt "$n" blocked "$head_sha" "$summary" || return 2
  # The blocked run is an implement failure like any other: record it where
  # requeue carries it into .model_policy.history, so the blind-rerun gate
  # sees issue 2695's four identical blocks instead of four fresh starts.
  failure_json="$(jq -cn --arg reason "$summary" --arg head "$head_sha" \
    '{unit:"implement",step:"work",stage:"checks-blocked",status:1,reason:$reason,head_sha:$head,recorded_at:(now|todate)}')" || return 2
  transition_filter=".run.previous_concluded_at = (.run.concluded_at // .run.previous_concluded_at) | .run.outcome = \"checks-blocked\" | .model_policy = (.model_policy // {}) | .model_policy.failure = $failure_json | .model_policy.failures = ((.model_policy.failures // []) + [$failure_json]) | del(.run.concluded_at,.run.needs_md,.run.conclusion,.closed_by_pipeline,.released)$repeat_filter"
  issue_transition "$n" checks-blocked required-checks-blocked "$transition_filter" || return 2
  if [ "$auto_head" = "$head_sha" ] && [ "$repeat_head" != "$head_sha" ]; then
    checks_blocked_escalate_repeat "$n" "$head_sha" "$summary" || return 2
  fi
  echo "implement checks blocked for issue $n; issue remains open as checks-blocked" >&2
}

# --- blind-rerun gate (2026-10-08) -------------------------------------------
# Issue 2695 ran implement four times (~440k tokens each) to the same
# BLOCKED-CHECKS network timeout, and 2731 four times to the same lesson
# delivery refusal; the repeat-dispatch bell rang at run 2 and nothing stopped
# runs 3 and 4. A ticket whose last two implement failures share a stage and a
# failure class is not dispatched again until an input changed: a main commit
# touching the failing area or the run environment, a non-pipeline issue
# comment, a supervisor hold release, or a newer env file. Otherwise it is
# parked once (one inbox line, one comment) with the decisive reason.
BLIND_RERUN_ENV_PATHS="${ZF_BLIND_RERUN_ENV_PATHS:-engine/dispatch-codex.sh engine/test-env.sh engine/night/dispatch.sh}"

# implement_failure_records <state-json> -- every recorded implement failure,
# oldest first, from the model-policy records (current, appended, and those
# requeue moved into history). Copies of one failure collapse.
implement_failure_records() {
  jq -c '
    ([(.model_policy.history // [])[] | .failure?] + [.model_policy.failure?] + (.model_policy.failures // []))
    | map(select(type == "object" and ((.unit // "implement") == "implement")
        and ((.reason // "") != "") and ((.recorded_at // "") != "")))
    | map({stage: (.stage // "unknown"), reason, recorded_at})
    | unique_by([.recorded_at, .reason]) | sort_by(.recorded_at)
  ' <<< "$1"
}

# implement_failure_class_key <stage> <reason> -- what a failure was about,
# stable across runs: the stage, an environmental category, and the failing
# commands/suites; otherwise the decisive text with paths, SHAs and numbers
# blanked. Model-written summaries vary in wording ("ConnectTimeoutError",
# "Connect Timeout Error"), so environmental causes compare by category.
implement_failure_class_key() {
  local stage="$1" reason="$2" env="" subjects text
  case "${reason,,}" in
    *connecttimeout*|*"connect timeout"*|*"fetch failed"*|*etimedout*|*econnrefused*|*econnreset*|*enotfound*|*eai_again*|*getaddrinfo*|*"could not resolve host"*|*"network is unreachable"*|*"proxy"*) env=network ;;
    *"sandbox"*|*"operation not permitted"*|*"read-only file system"*) env=sandbox ;;
    *"host overloaded"*|*"insufficient memory"*|*"out of memory"*) env=host ;;
  esac
  subjects="$(printf '%s\n' "$reason" | awk '
    {
      line = $0
      # The first backticked span of a line names the blocked command.
      if (match(line, /`[^`]+`/)) print substr(line, RSTART + 1, RLENGTH - 2)
    }
    /^Preflight command failed: / { cmd = $0; sub(/^Preflight command failed: /, "", cmd); sub(/ \(exit=[0-9]+\)$/, "", cmd); print cmd }
    /^Focused suite: [^ ]+ duration_ms=/ { print $3 }
    /^not ok/ { t = $0; sub(/^not ok [0-9]* *-? */, "", t); print "not ok: " t }
  ' | sed -E 's/[0-9]+(\.[0-9]+)?ms//g' | LC_ALL=C sort -u | paste -sd ';' -)"
  if [ -z "$subjects" ]; then
    text="$(printf '%s\n' "$reason" | grep -Ev '^[[:space:]]*($|ok |PROGRESS |CHECKED |To |From |\* |Switched |Cloning |remote: |Falling back|Applied patch .* cleanly)' \
      | sed -E 's#/tmp/[^ ]*#<tmp>#g; s/[0-9a-f]{7,64}/<sha>/g; s/[0-9]+/#/g; s/[[:space:]]+/ /g' | tail -n 3 | paste -sd ' ' -)"
    subjects="${text,,}"
  fi
  printf '%s|%s|%s\n' "$stage" "$env" "${subjects:0:600}"
}

# blind_rerun_failure_paths <reasons> <state-json> -- repo paths that count as
# the failing area: paths named in the failures, the ticket's expected paths,
# and the run-environment carriers above.
blind_rerun_failure_paths() {
  local reasons="$1" state="$2" path
  {
    grep -oE '(^|[^A-Za-z0-9_./-])[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+\.[A-Za-z0-9]+' <<< "$reasons" | sed -E 's#^[^A-Za-z0-9_.]##'
    jq -r '(.expected_paths // [])[]?' <<< "$state" 2>/dev/null
    tr ' ' '\n' <<< "$BLIND_RERUN_ENV_PATHS"
  } | while IFS= read -r path; do
    [ -n "$path" ] && [[ "$path" != /* ]] && [[ "$path" != *..* ]] && printf '%s\n' "$path"
  done | LC_ALL=C sort -u
}

# implement_rerun_input_change <n> <since> <reasons> <state-json> <comments-json>
# -- prints what changed since the latest failure and returns 0; returns 1
# when nothing did.
implement_rerun_input_change() {
  local n="$1" since="$2" reasons="$3" state="$4" comments="$5" since_epoch env_file env_epoch commit
  local -a paths=()
  if [ "$(jq -r --arg since "$since" '(.hold_released_at // "") > $since' <<< "$state")" = true ]; then
    echo "supervisor released the hold after the failure"
    return 0
  fi
  if [ "$(jq -r --arg since "$since" --arg marker "$BOT_COMMENT_MARKER" \
    '[.[] | select((.created_at // "") > $since and ((.body // "") | contains($marker) | not))] | length' <<< "$comments")" -gt 0 ]; then
    echo "new issue comment after the failure"
    return 0
  fi
  env_file="${ENV_FAULT_ENV_FILE:-$AGENT_HOME/env}"
  since_epoch="$(agent_epoch "$since" 2>/dev/null || echo 0)"
  env_epoch="$(stat -c %Y "$env_file" 2>/dev/null || echo 0)"
  if [[ "$since_epoch" =~ ^[0-9]+$ && "$env_epoch" =~ ^[0-9]+$ ]] && (( since_epoch > 0 && env_epoch > since_epoch )); then
    echo "run environment file changed after the failure"
    return 0
  fi
  mapfile -t paths < <(blind_rerun_failure_paths "$reasons" "$state")
  if ((${#paths[@]} > 0)); then
    commit="$(git -C "$REPO_DIR" log -1 --format=%h --since="$since" origin/main -- "${paths[@]}" 2>/dev/null || true)"
    if [ -n "$commit" ]; then
      echo "main commit $commit touched the failing area or run environment"
      return 0
    fi
  fi
  return 1
}

# implement_blind_rerun_gate <n> -> 0 when this dispatch must not run (the
# ticket is parked, or its input history could not be read this tick); 1 when
# dispatch continues. BLIND_RERUN_DECISION carries the reason for the caller's
# tick decision record.
implement_blind_rerun_gate() {
  local n="$1" state records count first second stage1 stage2 reason1 reason2 since key1 key2 change comments
  local decisive marker inbox_key paths_note
  BLIND_RERUN_DECISION=""
  state="$(state_read "$n" 2>/dev/null)" || return 1
  # A landing retry replays the rescued commit without a model call.
  [ -z "$(jq -r '.pipeline_system.landing_retry_sha // empty' <<< "$state")" ] || return 1
  records="$(implement_failure_records "$state" 2>/dev/null)" || return 1
  count="$(jq 'length' <<< "$records")"
  [ "${count:-0}" -ge 2 ] || return 1
  first="$(jq -c '.[-2]' <<< "$records")"
  second="$(jq -c '.[-1]' <<< "$records")"
  stage1="$(jq -r '.stage' <<< "$first")"; stage2="$(jq -r '.stage' <<< "$second")"
  [ "$stage1" = "$stage2" ] || return 1
  reason1="$(jq -r '.reason' <<< "$first")"; reason2="$(jq -r '.reason' <<< "$second")"
  key1="$(implement_failure_class_key "$stage1" "$reason1")"
  key2="$(implement_failure_class_key "$stage2" "$reason2")"
  [ "$key1" = "$key2" ] || return 1
  # Where two-strike routing (recut/advisor) owns the pair, it decides.
  if declare -F implement_two_strike_route >/dev/null 2>&1 && implement_two_strike_route "$n" >/dev/null 2>&1; then
    return 1
  fi
  since="$(jq -r '.recorded_at' <<< "$second")"
  if ! comments="$(gh api "repos/$REPO/issues/$n/comments" --paginate --jq '.[] | {created_at, body}' 2>/dev/null | jq -s '.' 2>/dev/null)"; then
    BLIND_RERUN_DECISION="同类失败已连续两次，但无法读取 issue 评论以确认输入是否变化，本 tick 暂缓派发"
    return 0
  fi
  if change="$(implement_rerun_input_change "$n" "$since" "$reason1"$'\n'"$reason2" "$state" "$comments")"; then
    printf 'blind-rerun-gate issue=#%s rerun allowed: %s\n' "$n" "$change" >&2
    return 1
  fi
  decisive="$(grep -Ev '^[[:space:]]*$' <<< "$reason2" | head -n 6 | cut -c1-300)"
  paths_note="$(blind_rerun_failure_paths "$reason1"$'\n'"$reason2" "$state" | head -n 8 | paste -sd ' ' -)"
  BLIND_RERUN_DECISION="最近两次 implement 在 $stage2 以同一类原因失败，之后没有任何输入变化；不再盲目重跑，已挂起并通知 supervisor"
  inbox_key="blind-rerun issue=#$n failure=$since"
  supervisor_inbox_append_once "$inbox_key" \
    "blind-rerun issue=#$n stage=$stage2 failures=2 since=$since reason=$(tr '\n' ' ' <<< "$decisive" | cut -c1-500) unblock=land-a-fix-touching[$paths_note]|comment-on-issue|change-env" \
    || echo "blind-rerun-gate: supervisor inbox write failed for #$n" >&2
  marker="<!-- zf-blind-rerun issue=#$n failure=$since -->"
  if ! jq -e --arg marker "$marker" 'any(.[]; (.body // "") | contains($marker))' <<< "$comments" >/dev/null 2>&1; then
    guarded_issue_comment "$n" "$BOT_DISCLAIMER
Blind-rerun gate: the last two implement runs failed at \`$stage2\` for the same reason, and nothing changed since (no main commit touching the failing area or run environment, no new issue comment, no environment change). Another run would repeat the failure, so this ticket is parked instead of redispatched.

Decisive reason:
\`\`\`
$decisive
\`\`\`
To rerun: land a fix touching the failing area or environment (${paths_note:-the paths named above}), add an issue comment with the new input, or release the hold with \`state_requeue $n release-hold\`.
$marker" || echo "blind-rerun-gate: comment failed for #$n" >&2
  fi
  hold_issue "$n" --holder blind-rerun-gate \
    --release 'an input changed: a main commit touching the failing area or run environment, a new issue comment, or a supervisor hold release' \
    --expires 72h --kind blind-rerun \
    || echo "blind-rerun-gate: on-hold write failed for #$n; candidate stays skipped and the hold retries next tick" >&2
  printf 'blind-rerun-gate issue=#%s parked stage=%s since=%s\n' "$n" "$stage2" "$since" >&2
  return 0
}

# conclusion_check_report failed -- plain-language mail fields for a failed mandatory check.
conclusion_check_report() {
  case "$1" in
    failed)
      jq -nc '{what:"本轮必要测试已运行，但没有通过。",impact:"问题还在，用户暂时看不到变化。",action:"测试通过前不能确认改动完成。"}'
      ;;
    *) return 1 ;;
  esac
}

mark_awaiting_release() {
  local n="$1" pr_number="$2" expected_hold="${3:-}" pr_json transition_filter
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "mark_awaiting_release: invalid issue number '$n'" >&2; return 64; }
  [[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || { echo "mark_awaiting_release: invalid PR number '$pr_number' for #$n" >&2; return 64; }
  pr_json="$(jq -cn --arg pr "$pr_number" '$pr')" || return 1
  transition_filter="if .run.outcome == \"merged\" and (.run.evidence.pr_number | tostring) == $pr_json then
    .run.merged_at = (.run.merged_at // .run.evidence.merged_pr.merged_at // (now | todate)) | .deploy_state = (.deploy_state // \"pending\")
    else .run.outcome = \"merged\" | .run.evidence.pr_number = $pr_json
    | if (.run.evidence.merged_pr.number | tostring) != $pr_json then del(.run.evidence.merged_pr) else . end
    | .run.merged_at = (.run.evidence.merged_pr.merged_at // (now | todate)) | .deploy_state = \"pending\" | del(.deployed_sha, .run.evidence.real_user_path, .closed_by_pipeline, .released) end
    | del(.web_advisor_provider_job_id, .web_advisor_provider_job_started_at, .web_advisor_provider_job_episode_seq) | .hold = null"
  issue_transition "$n" awaiting-release merged-pr "$transition_filter" 0 "" "" 0 "$expected_hold"
}

# conclude_run <n> <outcome> <needs_md> [quota_provider] -- records every
# terminal run result and performs the production-proven close. Refuses
# (prints why, returns 1, writes nothing) unless the record already carries
# the artifact $outcome requires:
#   merged        .run.evidence.pr_number recorded; moves open issue to
#                 awaiting-release / deploy_state=pending, never closes
#   deployed      merged outcome, deploy_state=deployed, deployed SHA, and
#                 real-user-path URL + visible DOM + same-run network proof
#   pr-open       .run.evidence.pr_number, .review_verdict, .ci_outcome all
#                 recorded -- a draft PR exists that a human could merge
#   not-completed state_attempts(n) at CONCLUDE_RUN_ATTEMPT_CAP, a real
#                 implement start since the last requeue/conclusion, and
#                 $needs_md names the missing capability -- not a bare attempt
#                 count. `duplicate` keeps its existing independent terminal
#                 behavior.
agent_owned_issue_ids() {
  local owner="$1" explicit="${2:-}" roster="$AGENT_HOME/night/agents.txt" row
  local pid name model effort worktree brief report log attempt started_at role start_ticks owned_issues owned_nodes lib_dir
  if ! declare -F hand_agent_issue_ids >/dev/null; then
    lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
    source "$lib_dir/night/hand-agent-watchdog.sh" || return 1
  fi
  if [[ -e "$roster" && ! -r "$roster" ]]; then return 1; fi
  if [[ -r "$roster" ]]; then
    while IFS= read -r row || [[ -n "$row" ]]; do
      [[ "$row" == *$'\t'* ]] || continue
      IFS=$'\x1f' read -r pid name model effort worktree brief report log attempt started_at role start_ticks owned_issues owned_nodes \
        <<< "${row//$'\t'/$'\x1f'}"
      [[ "$name" == "$owner" && -n "$owned_issues" ]] || continue
      explicit="${explicit:+$explicit }$owned_issues"
    done < "$roster"
  fi
  hand_agent_issue_ids "$owner" "$explicit"
}

pipeline_system_external_close_comment_valid() {
  local issue="$1" body="$2" repo='example-org/example-infra' default_branch pr_json pr_ref sha_ref pr_number sha
  local -a prs=() sha_refs=()
  grep -Eiq 'example-org/example-infra' <<< "$body" || return 1
  mapfile -t prs < <(grep -Eio 'pull request[[:space:]]*#?[[:space:]]*[0-9]+|pr[[:space:]]*#?[[:space:]]*[0-9]+' <<< "$body" | grep -Eo '[0-9]+' | sort -u || true)
  mapfile -t sha_refs < <(grep -Eio 'example-org/example-infra@[[:xdigit:]]{40,64}|merge[[:space:]]+sha[[:space:]:=]+[[:xdigit:]]{40,64}' <<< "$body" || true)
  ((${#prs[@]} > 0 && ${#sha_refs[@]} > 0)) || return 1
  default_branch="$(gh repo view "$repo" --json defaultBranchRef --jq '.defaultBranchRef.name')" || return 1
  [[ "$default_branch" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  for pr_ref in "${prs[@]}"; do
    [[ "$pr_ref" =~ ^[1-9][0-9]*$ ]] || continue
    pr_number="$pr_ref"
    for sha_ref in "${sha_refs[@]}"; do
      [[ "$sha_ref" =~ ([[:xdigit:]]{40,64})$ ]] || continue
      sha="${BASH_REMATCH[1],,}"
      pr_json="$(gh pr view "$pr_number" --repo "$repo" --json number,state,mergedAt,baseRefName,mergeCommit,body)" || continue
      jq -e --arg pr "$pr_number" --arg issue "$issue" --arg sha "$sha" --arg base "$default_branch" --arg slug "$REPO" '
        type == "object" and (.number | tostring) == $pr and .state == "MERGED" and
        ((.mergedAt // "") | type == "string" and length > 0) and
        .baseRefName == $base and (.mergeCommit.oid // "") == $sha and
        ((.body // "") | test("(?i)(^|[^[:alnum:]_])" + ($slug | gsub("[.]"; "\\.")) + "#" + $issue + "([^[:alnum:]_]|$)"))
      ' <<< "$pr_json" >/dev/null 2>&1 && return 0
    done
  done
  return 1
}

pipeline_system_finish_external_landing() {
  local repo_dir="$1" issue="$2" pr_number="$3" merge_sha="$4" issue_json comment sha_json
  [[ "$issue" =~ ^[1-9][0-9]*$ && "$pr_number" =~ ^[1-9][0-9]*$ \
    && "$merge_sha" =~ ^[[:xdigit:]]{40,64}$ ]] || return 1
  issue_json="$(gh issue view "$issue" --repo "$REPO" --json number,state,labels)" || return 1
  jq -e --arg issue "$issue" '
    (.number | tostring) == $issue and .state == "OPEN" and
    any(.labels[]?; .name == "pipeline-system")
  ' <<< "$issue_json" >/dev/null 2>&1 || return 1
  comment="结案：delivered in example-org/example-infra PR $pr_number, merged as example-org/example-infra@$merge_sha."
  pipeline_system_close_comment_valid "$repo_dir" "$issue" "$comment" || return 1
  guarded_write gh issue close "$issue" --repo "$REPO" --reason completed --comment "$comment" || return 1
  sha_json="$(jq -n --arg sha "$merge_sha" '$sha')" || return 1
  issue_transition "$issue" concluded close-external-factory-pr \
    ".closed_by_pipeline = true | .pipeline_system.enabled = true | .pipeline_system.commit_sha = $sha_json | .pipeline_system.delivery_state = \"concluded\" | .pipeline_system.close_comment_posted_at = (now | todate) | .run.outcome = \"pipeline-system\" | .run.concluded_at = (now | todate)"
}

pipeline_system_legacy_queue_close_comment_valid() {
  # Historical close audits may use the exact landed request; fresh close writers stay issue-linked.
  local repo_dir="$1" issue="$2" body="$3" reference_sha="${4:-}" ticket request owner owned_issues issue_ids queue_sha commit
  [[ "$body" =~ land-queue[[:space:]]ticket=([0-9]{20}) ]] || return 1
  ticket="${BASH_REMATCH[1]}"
  [[ "$body" =~ sha=([[:xdigit:]]{40,64}) ]] || return 1
  queue_sha="${BASH_REMATCH[1]}"
  request="${ZF_LAND_QUEUE_DIR:-$AGENT_HOME/land-queue}/requests/$ticket.json"
  [[ -r "$request" ]] || return 1
  jq -e --arg ticket "$ticket" --arg sha "$queue_sha" '
    .ticket == $ticket and .state == "landed" and .landed_sha == $sha and
    (.post_land_verdict.outcome | IN("green", "flaky", "pre-existing", "inconclusive"))
  ' "$request" >/dev/null 2>&1 || return 1
  owner="$(jq -r '.owner // empty' "$request")"
  owned_issues="$(jq -r '.owned_issues // ""' "$request")"
  issue_ids="$(agent_owned_issue_ids "$owner" "$owned_issues")" || return 1
  [[ " $issue_ids " == *" $issue "* ]] || return 1
  commit="$(git -C "$repo_dir" rev-parse --verify "$queue_sha^{commit}" 2>/dev/null)" || return 1
  git -C "$repo_dir" merge-base --is-ancestor "$commit" "${reference_sha:-origin/main}" 2>/dev/null
}

pipeline_system_close_comment_valid() {
  local repo_dir="$1" issue="$2" body="$3" allow_legacy_queue="${4:-false}" reference_sha="${5:-}" body_lower candidate commit message
  local -a candidates=()
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
  body_lower="${body,,}"
  [[ "$body" == *"结案"* || "$body" == *"关闭"* || "$body_lower" == *"clos"* ]] \
    || grep -Eq "已完成[[:space:]#]*$issue([^[:alnum:]_]|$)" <<< "$body" || return 1
  mapfile -t candidates < <(grep -Eo '[[:xdigit:]]{7,64}' <<< "$body" | sort -u || true)
  ((${#candidates[@]} > 0)) || return 1
  for candidate in "${candidates[@]}"; do
    commit="$(git -C "$repo_dir" rev-parse --verify "$candidate^{commit}" 2>/dev/null)" || continue
    git -C "$repo_dir" merge-base --is-ancestor "$commit" "${reference_sha:-origin/main}" 2>/dev/null || continue
    message="$(git -C "$repo_dir" show -s --format=%B "$commit" 2>/dev/null)" || continue
    # Direct-main commits normally write `issue N`; merged-PR bodies may carry
    # `Refs #N`, `fix(#N)`, or another `#N` reference. Keep this aligned with candidate lookup.
    grep -Eiq "(^|[^[:alnum:]_])(#|issue[[:space:]]+)$issue([^[:alnum:]_]|$)" <<< "$message" && return 0
  done
  if [[ "$allow_legacy_queue" == true ]] \
    && pipeline_system_legacy_queue_close_comment_valid "$repo_dir" "$issue" "$body" "$reference_sha"; then
    return 0
  fi
  pipeline_system_external_close_comment_valid "$issue" "$body"
}

pipeline_system_owner_report_status() {
  local report="$1"
  [[ -r "$report" ]] || return 1
  awk '
    /^STATUS: / { final = $0 }
    END {
      if (final != "") print final
      else exit 1
    }
  ' "$report"
}

pipeline_system_report_has_landed_marker() {
  local report="$1" ticket="$2" sha="$3"
  [[ -r "$report" ]] || return 1
  awk -v ticket="$ticket" -v sha="$sha" \
    '$1 == "LANDED" && $2 == ticket && $3 == sha { found = 1 } END { exit !found }' "$report"
}

pipeline_system_finish_direct_landing() {
  local request="$1" outcome="$2" mode="${3:-landing}" ticket owner owned_issues issue_ids landed_sha landed_epoch landed_at landed_at_json landed_sha_json issue issue_json issue_state status comment existing_comment valid_existing hold_kind hold_release
  local report report_status owner_status conclusion="close"
  case "$outcome" in
    green|flaky|pre-existing|inconclusive|culprit-reverted|culprit-not-reverted) ;;
    *) return 2 ;;
  esac
  [[ "$mode" == landing || "$mode" == exit ]] || return 2
  jq -e --arg outcome "$outcome" '.state == "landed" and .post_land_verdict.outcome == $outcome' \
    "$request" >/dev/null 2>&1 || return 1
  ticket="$(jq -r '.ticket' "$request")"
  owner="$(jq -r '.owner' "$request")"
  owned_issues="$(jq -r '.owned_issues // ""' "$request")"
  landed_sha="$(jq -r '.landed_sha // empty' "$request")"
  landed_epoch="$(jq -r '.finished_epoch // empty' "$request")"
  report="$(jq -r '.report // empty' "$request")"
  [[ "$ticket" =~ ^[0-9]{20}$ && "$landed_sha" =~ ^[[:xdigit:]]{40,64}$ ]] || return 1
  landed_at=""
  if [[ "$landed_epoch" =~ ^[0-9]+$ ]] && (( landed_epoch > 0 )); then
    landed_at="$(date -u -d "@$landed_epoch" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  fi
  landed_at_json="$(jq -nc --arg at "$landed_at" 'if $at == "" then null else $at end')" || return 1
  landed_sha_json="$(jq -nc --arg sha "$landed_sha" '$sha')" || return 1
  issue_ids="$(agent_owned_issue_ids "$owner" "$owned_issues")" || return 1
  [[ -n "$issue_ids" ]] || return 0

  for issue in $issue_ids; do
    issue_json="$(gh issue view "$issue" --repo "$REPO" --json number,state,labels,title,body,comments)" || return 1
    if pipeline_system_issue_matches "$issue_json"; then
      :
    else
      status=$?
      [[ "$status" == 1 ]] && continue
      return 1
    fi
    case "$outcome" in
      green|flaky|pre-existing|inconclusive)
        report_status="$(pipeline_system_owner_report_status "$report" 2>/dev/null || true)"
        case "$report_status" in
          'STATUS: DONE'|'STATUS: DONE '*|'STATUS: LANDED'|'STATUS: LANDED '*) ;;
          'STATUS: FOLLOWUP('*|'STATUS: BLOCKED-ON '*|'STATUS: NEEDS-DECISION'|'STATUS: NEEDS-DECISION '*|'STATUS: FAILED'|'STATUS: FAILED '*)
            conclusion="progress"
            ;;
          *)
            if [[ "$mode" != exit ]] || ! pipeline_system_report_has_landed_marker "$report" "$ticket" "$landed_sha"; then
              return 2
            fi
            ;;
        esac
        owner_status="${report_status#STATUS: }"
        owner_status="$(printf '%s' "$owner_status" | tr '\r\n\t' '   ' | cut -c1-200)"
        ;;
      *) ;;
    esac
    issue_state="$(jq -r '.state // empty' <<< "$issue_json")"
    case "$issue_state" in OPEN|CLOSED) ;; *) return 1 ;; esac

    if [[ "$outcome" == culprit-reverted ]]; then
      if [[ "$issue_state" == CLOSED ]]; then
        guarded_write gh issue reopen "$issue" --repo "$REPO" || return 1
        issue_json="$(gh issue view "$issue" --repo "$REPO" --json number,state,labels,title,body,comments)" || return 1
      fi
      scheduler_requeue_issue "$issue" "direct-main landing reverted by post-land verification" "$issue_json" "" "landing-$ticket-$landed_sha" revert \
        '.last_failure_reason = "direct-main landing reverted by post-land verification"' || return 1
      [ "$SCHEDULER_REQUEUE_RESULT" = requeued ] || return 1
      continue
    fi

    case "$outcome" in green|flaky|pre-existing|inconclusive) ;; *) continue ;; esac
    if [[ "$conclusion" == progress ]]; then
      comment="进展：land-queue ticket=$ticket sha=$landed_sha outcome=$outcome status=$owner_status"
      if ! jq -e --arg comment "$comment" 'any(.comments[]?; .body == $comment)' <<< "$issue_json" >/dev/null 2>&1; then
        guarded_write gh issue comment "$issue" --repo "$REPO" --body "$comment" || return 1
      fi
      continue
    fi
    comment="结案：land-queue ticket=$ticket sha=$landed_sha outcome=$outcome"
    if [[ "$issue_state" == OPEN ]]; then
      pipeline_system_close_comment_valid "$REPO_DIR" "$issue" "$comment" || return 1
      guarded_write gh issue close "$issue" --repo "$REPO" --reason completed --comment "$comment" || return 1
    else
      if jq -e --arg comment "$comment" 'any(.comments[]?; .body == $comment)' <<< "$issue_json" >/dev/null 2>&1; then
        pipeline_system_close_comment_valid "$REPO_DIR" "$issue" "$comment" true || return 1
      else
        valid_existing=0
        while IFS= read -r existing_comment; do
          if pipeline_system_close_comment_valid "$REPO_DIR" "$issue" "$existing_comment" true; then
            valid_existing=1
            break
          fi
        done < <(jq -r '.comments[]?.body // empty' <<< "$issue_json")
        if ((valid_existing == 0)); then
          # A prior close can predate its post-land verdict; attach evidence only after validating this ticket and SHA.
          pipeline_system_close_comment_valid "$REPO_DIR" "$issue" "$comment" true || return 1
          guarded_write gh issue comment "$issue" --repo "$REPO" --body "$comment" || return 1
        fi
      fi
    fi
    issue_transition "$issue" concluded close-direct-main-post-land \
      ".closed_by_pipeline = true | .pipeline_system.enabled = true | .pipeline_system.commit_sha = $landed_sha_json | .pipeline_system.landed_at = $landed_at_json | .pipeline_system.landed_attempt = (.attempts // 0) | .pipeline_system.delivery_state = \"concluded\" | .pipeline_system.close_comment_posted_at = (now | todate) | .run.outcome = \"pipeline-system\" | .run.concluded_at = (now | todate)" || return 1
    efficiency_metrics_sync_issue_lifecycle "$issue"
  done
}

# Shared closure evidence for the close path and every outcome auditor.
# Pipeline-system comments must cite their issue-linked main commit; ordinary
# Product closes need release or maintainer evidence; source-only closes require
# a main-reachable docs/test commit. Decision closures remain exceptions.
issue_closure_evidence_valid() {
  local repo_dir="$1" issue="$2" labels="$3" comments_json="$4"
  local maintainer_login="$5" close_epoch="$6" now_epoch="$7" candidate_comment="${8:-}"
  local state_reason="${9:-}" reference_sha="${10:-}" start end comment_b64 comment allow_legacy_queue=false
  [[ "$issue" =~ ^[1-9][0-9]*$ && "$close_epoch" =~ ^[0-9]+$ && "$now_epoch" =~ ^[0-9]+$ ]] || return 2
  if ((close_epoch > 0)); then allow_legacy_queue=true; fi
  if [ -z "$candidate_comment" ] && ! jq -e '
    type == "array" and all(flatten[]?;
      type == "object" and
      ((.body == null) or (.body | type == "string")) and
      ((.created_at == null) or (.created_at | type == "string")) and
      ((.user == null) or ((.user | type) == "object" and ((.user.login == null) or (.user.login | type == "string"))))
    )
  ' <<< "$comments_json" >/dev/null 2>&1; then
    return 2
  fi

  # A not-planned, wontfix or duplicate close delivers nothing, so it needs no delivery commit; pipeline-system
  # issues closed as obsolete (2026-10-03, issue 1352) otherwise stayed "unclassified" forever.
  [[ ",$labels," == *,wontfix,* || ",$labels," == *,duplicate,* || "$state_reason" == NOT_PLANNED ]] && return 0

  if [[ ",$labels," == *,pipeline-system,* ]]; then
    if [ -n "$candidate_comment" ]; then
      pipeline_system_close_comment_valid "$repo_dir" "$issue" "$candidate_comment" "$allow_legacy_queue" "$reference_sha"
      return $?
    fi
    start="$(date -u -d "@$((close_epoch - 86400))" +%Y-%m-%dT%H:%M:%SZ)" || return 2
    end="$(date -u -d "@$((now_epoch + 600))" +%Y-%m-%dT%H:%M:%SZ)" || return 2
    while IFS= read -r comment_b64; do
      [ -n "$comment_b64" ] || continue
      comment="$(base64 --decode <<< "$comment_b64")" || return 2
      if pipeline_system_close_comment_valid "$repo_dir" "$issue" "$comment" "$allow_legacy_queue" "$reference_sha"; then
        return 0
      fi
    done < <(jq -r --arg start "$start" --arg time_end "$end" '
      flatten[]?
      | select((.created_at // "") >= $start and (.created_at // "") <= $time_end)
      | .body | @base64
    ' <<< "$comments_json") || return 2
    return 1
  fi

  [[ ",$labels," == *,released,* ]] && return 0
  if issue_source_close_comment_valid "$repo_dir" "$issue" "$comments_json" \
    "$maintainer_login" "$close_epoch" "$reference_sha"; then
    return 0
  else
    local source_status=$?
    [ "$source_status" -ne 2 ] || return 2
  fi

  [ -n "$maintainer_login" ] || return 1
  start="$(date -u -d "@$((close_epoch - 86400))" +%Y-%m-%dT%H:%M:%SZ)" || return 2
  end="$(date -u -d "@$((now_epoch + 600))" +%Y-%m-%dT%H:%M:%SZ)" || return 2
  jq -e --arg owner "$maintainer_login" --arg start "$start" --arg time_end "$end" '
    any(flatten[]?;
      ((.user.login // "" | ascii_downcase) == ($owner | ascii_downcase)) and
      ((.body // "") | test("^维护者(补充)?裁决")) and
      ((.created_at // "") >= $start and (.created_at // "") <= $time_end)
    )
  ' <<< "$comments_json" >/dev/null 2>&1
}

issue_source_close_comment_valid() {
  local repo_dir="$1" issue="$2" comments_json="$3" maintainer_login="$4" close_epoch="$5" reference_sha="${6:-}"
  local sha commit commit_epoch path paths main_sha valid_paths
  local -a source_shas=()
  [[ "$issue" =~ ^[1-9][0-9]*$ && "$close_epoch" =~ ^[0-9]+$ && -n "$maintainer_login" ]] || return 1
  mapfile -t source_shas < <(jq -r --arg owner "${maintainer_login,,}" --arg issue "$issue" '
    flatten[]?
    | select((.user.login // "" | ascii_downcase) == $owner)
    | (.body // "")
    | try capture("<!-- zf-source-close-evidence issue=" + $issue + " sha=(?<sha>[[:xdigit:]]{40}) -->").sha catch empty
  ' <<< "$comments_json")
  ((${#source_shas[@]} > 0)) || return 1
  # A retrospective marker is safe only when its source was on main before closure.
  main_sha="$(git -C "$repo_dir" rev-parse --verify "${reference_sha:-origin/main}^{commit}" 2>/dev/null)" || return 2
  for sha in "${source_shas[@]}"; do
    commit="$(git -C "$repo_dir" rev-parse --verify "$sha^{commit}" 2>/dev/null)" || continue
    git -C "$repo_dir" merge-base --is-ancestor "$commit" "$main_sha" 2>/dev/null || continue
    commit_epoch="$(git -C "$repo_dir" show -s --format=%ct "$commit" 2>/dev/null)" || return 2
    [[ "$commit_epoch" =~ ^[0-9]+$ ]] || return 2
    ((commit_epoch <= close_epoch)) || continue
    paths="$(git -C "$repo_dir" diff-tree --no-commit-id --name-only -r -m "$commit" 2>/dev/null)" || return 2
    [ -n "$paths" ] || continue
    valid_paths=1
    while IFS= read -r path; do
      case "$path" in
        docs/*|tests/*|*/tests/*|test-support/*|*/test-support/*|*/src/test-helpers/*|*.test.*|*.spec.*|vitest.config.*|jest.config.*|*/vitest.config.*|*/jest.config.*) ;;
        *) valid_paths=0; break ;;
      esac
    done <<< "$paths"
    [ "$valid_paths" = 1 ] && return 0
  done
  return 1
}

conclude_run() {
  local n="$1" outcome="$2" needs_md="${3:-}" quota_provider="${4:-}" expected_hold="${5:-}" state pr_number pr_head_sha review_verdict ci_outcome attempts acceptor duplicate_of deploy_state deployed_sha real_user_path policy_exhausted implement_episode implement_after_requeue implementation_run pipeline_sha pipeline_close_comment health_target health_detail health_target_json health_detail_json issue_state mandatory_check_status="" check_report_json conclusion_json='null'
  if [ -n "$quota_provider" ] && provider_quota_exhausted "$quota_provider"; then
    echo "conclude_run: refusing outcome=$outcome for #$n -- $quota_provider provider quota hold is open" >&2
    return 1
  fi
  state="$(state_read "$n")"
  case "$outcome" in
    merged)
      pr_number="$(echo "$state" | jq -r '.run.evidence.pr_number // empty')"
      if [ -z "$pr_number" ]; then
        echo "conclude_run: refusing outcome=merged for #$n -- no .run.evidence.pr_number recorded" >&2
        return 1
      fi
      pr_head_sha="$(echo "$state" | jq -r '.run.evidence.pr_head_sha // empty')"
      if ! mandatory_check_receipt_ready "$n" "$pr_head_sha"; then
        mandatory_check_status="$(state_read "$n" | jq -r '.run.evidence.mandatory_checks.status // "missing"')"
        echo "conclude_run: refusing outcome=merged for #$n -- mandatory checks are $mandatory_check_status" >&2
        return 1
      fi
      ;;
    deployed)
      pr_number="$(echo "$state" | jq -r '.run.evidence.pr_number // empty')"
      deploy_state="$(echo "$state" | jq -r '.deploy_state // empty')"
      deployed_sha="$(echo "$state" | jq -r '.deployed_sha // empty')"
      real_user_path="$(echo "$state" | jq -r '.run.evidence.real_user_path // empty')"
      if [ "$(echo "$state" | jq -r '.run.outcome // empty')" != "merged" ] \
        || [ "$deploy_state" != "deployed" ] || [ -z "$pr_number" ] || [ -z "$deployed_sha" ] \
        || [[ "$real_user_path" != *"URL:"* ]] || [[ "$real_user_path" != *"Visible DOM:"* ]] || [[ "$real_user_path" != *"Same-run network:"* ]]; then
        echo "conclude_run: refusing outcome=deployed for #$n -- merged outcome plus deployed SHA, URL, visible DOM, and same-run network evidence required" >&2
        return 1
      fi
      release_feature_evidence_valid "$n" "$real_user_path" || return 1
      pr_head_sha="$(echo "$state" | jq -r '.run.evidence.pr_head_sha // empty')"
      if ! mandatory_check_receipt_ready "$n" "$pr_head_sha"; then
        mandatory_check_status="$(state_read "$n" | jq -r '.run.evidence.mandatory_checks.status // "missing"')"
        echo "conclude_run: refusing outcome=deployed for #$n -- mandatory checks are $mandatory_check_status" >&2
        return 1
      fi
      ;;
    pr-open)
      pr_number="$(echo "$state" | jq -r '.run.evidence.pr_number // empty')"
      review_verdict="$(echo "$state" | jq -r '.run.evidence.review_verdict // empty')"
      ci_outcome="$(echo "$state" | jq -r '.run.evidence.ci_outcome // empty')"
      if [ -z "$pr_number" ] || [ -z "$review_verdict" ] || [ -z "$ci_outcome" ]; then
        echo "conclude_run: refusing outcome=pr-open for #$n -- missing evidence (pr_number=${pr_number:-<empty>} review_verdict=${review_verdict:-<empty>} ci_outcome=${ci_outcome:-<empty>})" >&2
        return 1
      fi
      ;;
    not-completed)
      attempts="$(state_attempts "$n")"
      implement_episode="$(echo "$state" | jq -r '((.model_policy.unit // (if .model_policy.step then "implement" else "" end)) == "implement") or ((.requeued_at // "") != "")')"
      policy_exhausted="$(echo "$state" | jq -r '(. as $s | (if ($s.model_policy.unit // (if $s.model_policy.step then "implement" else "" end)) == "implement" then [$s.requeued_at // "", $s.run.concluded_at // "", $s.run.previous_concluded_at // ""] else [$s.requeued_at // "", $s.run.previous_concluded_at // ""] end | max) as $boundary | $s.model_policy.step == "conclude" and (($s.model_policy.failure.reason // "") != "") and (($s.model_policy.failure.recorded_at // "") > $boundary))')"
      implement_after_requeue="$(echo "$state" | jq -r '(. as $s | ([$s.requeued_at // "", $s.run.concluded_at // "", $s.run.previous_concluded_at // ""] | max) as $boundary | ($s.run.implement_started_at // "") as $started | ($started != "" and ($boundary == "" or $started >= $boundary)))')"
      # At the cap no new implement can start (only a requeue resets attempts), so demanding one after the
      # last conclusion livelocked hold-expired issues: issues 1758/1820/1952/1970/2144 sat 5 days re-refused every tick.
      if { [ "$implement_episode" = true ] && [ "$attempts" -lt "$CONCLUDE_RUN_ATTEMPT_CAP" ] \
          && { [ "$attempts" -eq 0 ] || [ "$implement_after_requeue" != true ]; }; } \
        || { [ "$attempts" -lt "$CONCLUDE_RUN_ATTEMPT_CAP" ] && [ "$policy_exhausted" != true ]; } \
        || [ -z "$needs_md" ]; then
        echo "conclude_run: refusing outcome=not-completed for #$n -- attempts=$attempts (cap $CONCLUDE_RUN_ATTEMPT_CAP), needs_md=${needs_md:+set}${needs_md:-<empty>}" >&2
        return 1
      fi
      ;;
    # 2026-09-16 (batch advisor sweep, run-advisor-batch.sh): a ticket the
    # advisor rules a duplicate of another, SURVIVING ticket has its own
    # work done by the survivor -- an ordinary conclusion through this same
    # terminal, not a new one and not a park. .run.evidence.duplicate_of
    # (the survivor's issue number) is the evidence this outcome requires,
    # same shape as `merged` requiring .run.evidence.pr_number: the caller
    # writes it before calling this, this only verifies it is there.
    duplicate)
      duplicate_of="$(echo "$state" | jq -r '.run.evidence.duplicate_of // empty')"
      if [ -z "$duplicate_of" ] || [ -z "$needs_md" ]; then
        echo "conclude_run: refusing outcome=duplicate for #$n -- duplicate_of=${duplicate_of:-<empty>}, needs_md=${needs_md:+set}${needs_md:-<empty>}" >&2
        return 1
      fi
      ;;
    pipeline-system)
      pipeline_sha="$(echo "$state" | jq -r '.pipeline_system.commit_sha // empty')"
      if [ "$(echo "$state" | jq -r '.pipeline_system.enabled // false')" != true ] \
        || ! [[ "$pipeline_sha" =~ ^[0-9a-f]{40,64}$ ]] \
        || ! git -C "$REPO_DIR" merge-base --is-ancestor "$pipeline_sha" HEAD; then
        echo "conclude_run: refusing outcome=pipeline-system for #$n -- pipeline-system commit is not recorded in live checkout" >&2
        return 1
      fi
      pipeline_close_comment="$BOT_DISCLAIMER
流水线系统改动已进入 live checkout。

Commit: $pipeline_sha

$needs_md

这张票已经关闭。如果验证下来还是不对，重新打开这张 issue 就行，机器人会当成新的一轮重新处理。"
      if ! issue_closure_evidence_valid "$REPO_DIR" "$n" pipeline-system '[]' \
        "${REPO%%/*}" 0 "$(date +%s)" "$pipeline_close_comment"; then
        echo "conclude_run: refusing outcome=pipeline-system for #$n -- close comment must cite its issue-linked commit reachable from origin/main" >&2
        return 1
      fi
      issue_state="$(gh issue view "$n" --repo "$REPO" --json state -q .state)" || return 1
      ;;
    *)
      echo "conclude_run: unknown outcome '$outcome' for #$n -- refusing" >&2
      return 1
      ;;
  esac

  if [ "$outcome" = "not-completed" ]; then
    mandatory_check_status="$(echo "$state" | jq -r '.run.evidence.mandatory_checks.status // empty')"
    implementation_run="$(echo "$state" | jq -r '((.model_policy.unit // "") == "implement") or (.run.evidence.mandatory_checks != null)')"
    [ "$implement_after_requeue" = true ] && implementation_run=true
    if [ -z "$mandatory_check_status" ] && [ "$implementation_run" = true ]; then
      pr_head_sha="$(echo "$state" | jq -r '.run.evidence.pr_head_sha // empty')"
      record_mandatory_check_receipt "$n" missing "$pr_head_sha" "No mandatory-check receipt was recorded."
      mandatory_check_status=missing
      state="$(state_read "$n")"
    fi
    conclusion_json="$(conclusion_classification_for_state "$n" "$state" "$needs_md" "$outcome")" || return 1
    conclusion_json="$(jq -c --arg status "$mandatory_check_status" '.mandatory_checks_status = $status' <<< "$conclusion_json")" || return 1
  fi

  web_advisor_provider_clear_job_state "$n" || return 1
  local outcome_json needs_json needs_md_file label
  outcome_json="$(jq -n --arg o "$outcome" '$o')"
  needs_md_file="$(jq_arg_file "$needs_md")"
  needs_json="$(jq -n --rawfile m "$needs_md_file" '$m')"
  rm -f "$needs_md_file"
  # The old rule solved a real wait-forever problem: no human reply may block
  # a completed pipeline run. The replacement keeps that property but makes
  # production evidence, not merge, the mechanical completion condition.
  if [ "$outcome" = "merged" ]; then
    state_merge "$n" ".run.needs_md = $needs_json" || return 1
    mark_awaiting_release "$n" "$pr_number" "$expected_hold" || return 1
    local merged_comment_marker="<!-- zf-merged-outcome issue=$n pr=$pr_number -->" merged_comments_json
    if [ "${AGENT_DRY_RUN:-0}" != 1 ] && [ "${DRY_RUN:-0}" != 1 ]; then
      merged_comments_json="$(gh api "repos/$REPO/issues/$n/comments?per_page=100" --paginate --slurp)" || {
        echo "conclude_run: cannot inspect merged-outcome comments for #$n; leaving merge reconciliation retryable" >&2
        return 1
      }
      if ! jq -e 'type == "array" and all(flatten[]?; type == "object" and (.body | type == "string"))' \
        <<< "$merged_comments_json" >/dev/null 2>&1; then
        echo "conclude_run: merged-outcome comments have invalid shape for #$n; leaving merge reconciliation retryable" >&2
        return 1
      fi
    else
      merged_comments_json='[]'
    fi
    # The exact-PR text check recognizes handoff comments posted before the marker existed.
    if ! jq -e --arg marker "$merged_comment_marker" --arg pr "PR #$pr_number" --arg disclaimer "$BOT_DISCLAIMER" '
      any(flatten[]?.body; contains($marker) or (startswith($disclaimer) and contains("这张票的实现已合并") and test("(^|[^0-9])" + $pr + "([^0-9]|$)")))
    ' <<< "$merged_comments_json" >/dev/null 2>&1; then
      needs_md+=$'\n\n'"$merged_comment_marker"
      guarded_issue_comment "$n" "$BOT_DISCLAIMER
这张票的实现已合并，正在等待生产部署及同一次真实用户路径的 URL、可见 DOM 和网络交换证据。$needs_md" || return 1
    fi
    return 0
  fi

  if [ "$outcome" = "deployed" ]; then
    # `record_deploy_evidence` writes the proof before this point. Keep that
    # state durable if a GitHub mutation retries; only mark concluded after
    # the actual close succeeds. The pending marker lets the scheduler rebuild
    # the mail outbox if queueing later fails.
    state_merge "$n" '.maintainer_outcome_pending = true' || return 1
    local transition_filter='del(.advisor_admission_measure_only) | .run.previous_concluded_at = (.run.concluded_at // .run.previous_concluded_at) | .run.concluded_at = (now | todate) | .released = true | .closed_by_pipeline = true | del(.web_advisor_provider_job_id, .web_advisor_provider_job_started_at, .web_advisor_provider_job_episode_seq)'
    issue_transition "$n" concluded conclude:deployed "$transition_filter" || return 1
    guarded_issue_comment "$n" "$BOT_DISCLAIMER
这张票已部署，并已记录同一次真实用户路径的 URL、可见 DOM 和网络交换证据。$needs_md

这张票已经关闭。如果之后验证发现仍有问题，重新打开这张 issue 就行，机器人会当成新的一轮重新处理。" || return 1
    guarded_write gh issue close "$n" --repo "$REPO" || return 1
    if queue_maintainer_outcome "$n" "$deployed_sha"; then
      if ! state_merge "$n" 'del(.maintainer_outcome_pending)'; then
        echo "conclude_run: queued production outcome for #$n, but retry marker could not be cleared" >&2
      fi
    else
      echo "conclude_run: deployed outcome for #$n is recorded for digest retry" >&2
    fi
    return 0
  fi

  if [ "$outcome" = "pipeline-system" ]; then
    local comment_posted comment_epoch comment_since comments_json evidence_status
    comment_posted="$(echo "$state" | jq -r '.pipeline_system.close_comment_posted_at // empty')"
    if [ -z "$comment_posted" ]; then
      guarded_issue_comment "$n" "$pipeline_close_comment" || return 1
      state_merge "$n" '.pipeline_system.close_comment_posted_at = (now | todate)' || return 1
    else
      comment_epoch="$(agent_epoch "$comment_posted" 2>/dev/null || true)"
      [[ "$comment_epoch" =~ ^[0-9]+$ ]] || return 1
      comment_since="$(date -u -d "@$((comment_epoch - 86400))" +%Y-%m-%dT%H:%M:%SZ)" || return 1
      comments_json="$(gh api "repos/$REPO/issues/$n/comments?since=$comment_since&per_page=100" --paginate --slurp)" || return 1
      if issue_closure_evidence_valid "$REPO_DIR" "$n" pipeline-system \
        "$comments_json" "${REPO%%/*}" "$comment_epoch" "$(date +%s)"; then
        :
      else
        evidence_status=$?
        [ "$evidence_status" -eq 1 ] || return 1
        guarded_issue_comment "$n" "$pipeline_close_comment" || return 1
        state_merge "$n" '.pipeline_system.close_comment_posted_at = (now | todate)' || return 1
      fi
    fi
    local transition_filter=".run.outcome = $outcome_json | .run.needs_md = $needs_json | del(.advisor_admission_measure_only) | .run.previous_concluded_at = (.run.concluded_at // .run.previous_concluded_at) | .run.concluded_at = (now | todate) | .closed_by_pipeline = true | .pipeline_system.delivery_state = \"concluded\" | del(.pipeline_system.health_target, .pipeline_system.health_status, .pipeline_system.health_check_sha, .pipeline_system.health_checked_at, .pipeline_system.health_detail, .web_advisor_provider_job_id, .web_advisor_provider_job_started_at, .web_advisor_provider_job_episode_seq)"
    if [ -n "$expected_hold" ]; then
      (
        local f fd current
        f="$(state_file "$n")" || exit 1
        exec {fd}>"$f.lock" && flock -x "$fd" || exit 1
        current="$(state_read "$n")" || exit 1
        jq -e --argjson expected "$expected_hold" '.state == "on-hold" and (.hold | del(.aging_window)) == ($expected | del(.aging_window))' <<< "$current" >/dev/null || exit 1
        if [ "$issue_state" != "CLOSED" ]; then guarded_write gh issue close "$n" --repo "$REPO" || exit 1; fi
        issue_transition "$n" concluded conclude:pipeline-system "$transition_filter" 0 "" "" 0 "$expected_hold" __issue_transition_lock_held
      ) || return 1
    else
      if [ "$issue_state" != "CLOSED" ]; then guarded_write gh issue close "$n" --repo "$REPO" || return 1; fi
      issue_transition "$n" concluded conclude:pipeline-system "$transition_filter" || return 1
    fi
    return 0
  fi

  # Failed and draft outcomes remain immediate conclusions. They never wait
  # for a deploy that will not exist.
  local conclusion_filter=""
  [ "$outcome" != "not-completed" ] || conclusion_filter=" | .run.conclusion = $conclusion_json"
  local transition_filter=".run.outcome = $outcome_json | .run.needs_md = $needs_json$conclusion_filter | del(.advisor_admission_measure_only) | .run.previous_concluded_at = (.run.concluded_at // .run.previous_concluded_at) | .run.concluded_at = (now | todate) | del(.web_advisor_provider_job_id, .web_advisor_provider_job_started_at, .web_advisor_provider_job_episode_seq)"
  local close_now=0
  [ "$outcome" = "duplicate" ] && close_now=1
  if [ "$outcome" = duplicate ]; then
    issue_transition "$n" concluded conclude:duplicate "$transition_filter" || return 1
  else
    issue_transition "$n" concluded "conclude:$outcome" "$transition_filter" || return 1
  fi
  local close_note=""
  [ "$close_now" = "1" ] && close_note="

这张票已经关闭。如果验证下来还是不对，重新打开这张 issue 就行，机器人会当成新的一轮重新处理。"
  local outcome_note="这张票的这一轮无人值守处理结束了（结果：${outcome}）。"
  case "$mandatory_check_status" in
    blocked) outcome_note="这一轮处理结束：必要测试被运行环境阻断，没有运行完成。" ;;
    missing) outcome_note="这一轮处理结束：没有可核对的必要测试记录，不能按通过处理。" ;;
    deferred) outcome_note="这一轮处理结束：必要测试交给了合并请求检查，尚无同一代码版本的绿色结果。" ;;
    failed) outcome_note="这一轮处理结束：必要测试运行了，但没有通过。" ;;
  esac
  [ "$outcome" = "pipeline-system" ] && outcome_note="流水线系统改动已进入 live checkout。"
  guarded_issue_comment "$n" "$BOT_DISCLAIMER
${outcome_note}$needs_md$close_note" || return 1
  if [ "$close_now" = "1" ]; then
    guarded_write gh issue close "$n" --repo "$REPO" || return 1
    state_merge "$n" '.closed_by_pipeline = true | del(.web_advisor_provider_job_id, .web_advisor_provider_job_started_at, .web_advisor_provider_job_episode_seq)' || return 1
    return 0
  fi

  local failure_reason report_what report_impact report_action
  case "$mandatory_check_status" in
    blocked|missing|deferred)
      # The issue comment above carries this. No mail: the maintainer contract refused every attempt
      # (8 contract-rejected sends by 2026-10-04), and each refusal flipped mail-credential BROKEN.
      return 0
      ;;
    failed)
      check_report_json="$(conclusion_check_report "$mandatory_check_status")" || return 1
      report_what="$(jq -r '.what' <<< "$check_report_json")"
      report_impact="$(jq -r '.impact' <<< "$check_report_json")"
      report_action="$(jq -r '.action' <<< "$check_report_json")"
      notify_email_reporter "$n" "[example] 这一轮未能完成" \
        "$report_what" "$report_impact" "$report_action" || true
      return 0
      ;;
  esac
  failure_reason="$(recorded_failure_reason_from_state "$state")"
  [ -n "$failure_reason" ] || failure_reason="$needs_md"
  report_what="$(_maintainer_readable_or_fallback "$failure_reason" "这一轮没能改完，先停下了。")"
  notify_email_reporter "$n" "[example] 这一轮未能完成" \
    "$report_what" \
    "问题还在，用户暂时看不到变化。" \
    "不用现在操作；处理原因已记录在问题进展中。" || true
  return 0
}

# Rebuild the mail outbox from deployed issue state before each digest flush.
# The marker is written before GitHub close; failed queue writes stay retryable.
reconcile_maintainer_outcomes() {
  local state_file issue_num deployed_sha pending_files grep_status=0
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  # One jq per state file cost 164 s per tick over 1829 files (2026-10-08);
  # only files that mention the marker can be pending.
  pending_files="$(grep -lF maintainer_outcome_pending -- "$AGENT_HOME"/state/*.json 2>/dev/null)" || grep_status=$?
  if [ "$grep_status" -gt 1 ] && [ -n "$(compgen -G "$AGENT_HOME/state/*.json")" ]; then
    echo "reconcile_maintainer_outcomes: cannot scan state files; digest send deferred" >&2
    return 1
  fi
  while IFS= read -r state_file; do
    [ -f "$state_file" ] || continue
    deployed_sha="$(jq -r 'if .maintainer_outcome_pending == true then .deployed_sha // error("pending outcome has no deployed SHA") else empty end' "$state_file" 2>/dev/null)" || {
      echo "reconcile_maintainer_outcomes: cannot read $state_file; digest send deferred" >&2
      return 1
    }
    [ -n "$deployed_sha" ] || continue
    issue_num="${state_file##*/}"
    issue_num="${issue_num%.json}"
    if ! [[ "$issue_num" =~ ^[0-9]+$ ]]; then
      echo "reconcile_maintainer_outcomes: invalid issue state filename $state_file" >&2
      return 1
    fi
    if ! queue_maintainer_outcome "$issue_num" "$deployed_sha"; then
      echo "reconcile_maintainer_outcomes: could not queue deployed outcome for #$issue_num; digest send deferred" >&2
      return 1
    fi
    if ! state_merge "$issue_num" 'del(.maintainer_outcome_pending)'; then
      echo "reconcile_maintainer_outcomes: queued #$issue_num but could not clear retry marker; digest send deferred" >&2
      return 1
    fi
  done <<< "$pending_files"
}

# Shared post-merge bookkeeping for the implement leg and the orphan-PR
# sweeper. A pipeline-system PR already present in the live checkout can close
# through its own evidence path; other merges enter the release handoff.
conclude_merged_run() {
  local n="$1" pr_number="$2" merge_detail="${3:-}" expected_hold="${4:-}" merged_row merge_sha state pipeline_enabled merge_sha_json close_comment evidence_status
  if [ -n "$expected_hold" ]; then
    state="$(state_read "$n")" || return 1
    jq -e --argjson expected "$expected_hold" '.state == "on-hold" and (.hold | del(.aging_window)) == ($expected | del(.aging_window))' <<< "$state" >/dev/null || return 1
  fi
  if ! merged_row="$(merged_pr_main_row "$pr_number" "$n")"; then
    echo "conclude_merged_run: refusing PR #$pr_number for #$n -- only merged PRs targeting main can enter awaiting-release" >&2
    return 1
  fi
  merge_sha="${merged_row#*$'\t'}"
  state="$(state_read "$n")" || return 1
  if [ -n "$expected_hold" ] && ! jq -e --argjson expected "$expected_hold" '.state == "on-hold" and (.hold | del(.aging_window)) == ($expected | del(.aging_window))' <<< "$state" >/dev/null; then return 1; fi
  if jq -e '.tracker_parent == true or .state == "tracker"' <<< "$state" >/dev/null 2>&1; then
    echo "conclude_merged_run: #$n is tracker parent; recorded PR #$pr_number merge $merge_sha without changing aggregate or release state" >&2
    return 0
  fi
  merge_detail="${merge_detail:-PR #$pr_number auto-merged (squash). Waiting on Postsubmit validate before release.}"
  record_run_decision "$n" wrapper "Merged PR #$pr_number (squash)" 0
  state="$(state_read "$n")" || return 1
  pipeline_enabled="$(jq -r '.pipeline_system.enabled // false' <<< "$state")" || return 1
  if [ "$pipeline_enabled" = true ] && git -C "$REPO_DIR" merge-base --is-ancestor "$merge_sha" HEAD; then
    merge_sha_json="$(jq -n --arg sha "$merge_sha" '$sha')" || return 1
    state_merge "$n" ".pipeline_system.commit_sha = $merge_sha_json" || return 1
    close_comment="$BOT_DISCLAIMER
流水线系统改动已进入 live checkout。

Commit: $merge_sha

$merge_detail

这张票已经关闭。"
    if issue_closure_evidence_valid "$REPO_DIR" "$n" pipeline-system '[]' \
      "${REPO%%/*}" 0 "$(date +%s)" "$close_comment"; then
      conclude_run "$n" pipeline-system "PR #$pr_number merged as $merge_sha" "" "$expected_hold"
      return $?
    else
      evidence_status=$?
    fi
    [ "$evidence_status" -eq 1 ] || return "$evidence_status"
    echo "conclude_merged_run: pipeline-system close evidence refused for #$n; falling back to merged" >&2
  fi
  conclude_run "$n" merged "$merge_detail" "" "$expected_hold"
}

classify_pipeline_system_paths() {
  node --input-type=module - "$REPO_DIR" "$1" <<'NODE'
import { pathToFileURL } from 'node:url';
const root = process.argv[2];
const paths = JSON.parse(process.argv[3]);
const { evaluateDirectMainSystemWork } = await import(pathToFileURL(`${root}/scripts/branch-delivery-policy.mjs`));
const result = evaluateDirectMainSystemWork({
  sourceRef: 'main', targetRef: 'main', changedPaths: paths,
  commitMessages: ['[skip ci] classify already-landed work'],
});
console.log(result.allowed ? 'pipeline-system' : 'product');
NODE
}

route_pipeline_system_verification() {
  local n="$1" sha="$2" sha_json
  sha_json="$(jq -n --arg sha "$sha" '$sha')"
  issue_transition "$n" awaiting-pipeline-sync pipeline-system-verification \
    ".pipeline_system.enabled = true | .pipeline_system.commit_sha = $sha_json | .pipeline_system.delivery_state = \"awaiting-pipeline-sync\"" || return 1
  if git -C "$REPO_DIR" merge-base --is-ancestor "$sha" HEAD; then
    conclude_run "$n" pipeline-system "Existing pipeline-system change $sha is present in the live checkout."
  else
    guarded_issue_comment "$n" "$BOT_DISCLAIMER
An existing pipeline-system change is already merged to main.

Commit: $sha

The issue is waiting for the live checkout to sync before it closes."
  fi
}

# Route a fixed-point empty diff only when exact issue-linked main evidence
# proves the work already landed. Product changes enter release verification;
# pipeline-system changes wait for the live checkout sync. Return 1 only when
# no such change exists, and 2 when evidence could not be read safely.
route_existing_main_work() {
  local n="$1" worktree="$2" commit_line sha subject paths kind pr_list candidate pr_number pr_json merge_sha
  while IFS= read -r commit_line; do
    [ -n "$commit_line" ] || continue
    sha="${commit_line%%$'\t'*}"
    subject="${commit_line#*$'\t'}"
    # Delivery names the issue in its subject; a body that cites it as context
    # is not its delivery (0e6527851 closed issue 2873 that way).
    [[ "${subject,,}" =~ (#|issue[[:space:]]+)$n([^[:alnum:]_]|$) ]] || continue
    pipeline_system_close_comment_valid "$worktree" "$n" "close Commit: $sha" || continue
    paths="$(git -C "$worktree" diff-tree --no-commit-id --name-only -r "$sha" | jq -Rsc 'split("\n") | map(select(length > 0))')" || return 2
    kind="$(classify_pipeline_system_paths "$paths")" || return 2
    if [ "$kind" = pipeline-system ]; then
      # A pipeline fix may cite a product issue it was found on (issue 1254 was
      # closed twice by c205d6ad4). Only a pipeline-system issue is delivered by it.
      pipeline_system_route_status "$n" || { [ $? -eq 1 ] && continue; return 2; }
      route_pipeline_system_verification "$n" "$sha" || return 2
      return 0
    fi
  done < <(git -C "$worktree" log origin/main --format='%H%x09%s' --grep="(#|issue[[:space:]]+)$n([^[:alnum:]_]|$)" --extended-regexp --regexp-ignore-case)

  if ! pr_list="$(gh pr list --repo "$REPO" --state merged --search "$n in:title" --limit 100 \
      --json number,title,headRefName,baseRefName,mergeCommit)"; then
    return 2
  fi
  candidate="$(jq -c --arg n "$n" '[.[] | select(.baseRefName == "main" and (.headRefName == ("agent/issue-" + $n) or (.headRefName | test("(^|/)fix/" + $n + "($|[-/])")) or (.title | test("(\\(#|\\bissue )" + $n + "([^0-9]|$)"))))] | sort_by(.number) | last // empty' <<< "$pr_list")"
  # 2026-10-05: PR titles say "(issue N)" since the merged-PR full-text gate; matching only "(#N)" missed
  # PR 2258 for issue 2254, so implement re-ran an already-merged fix four times.
  [ -n "$candidate" ] || return 1
  pr_number="$(jq -r '.number' <<< "$candidate")"
  merge_sha="$(jq -r '.mergeCommit.oid // empty' <<< "$candidate")"
  [[ "$merge_sha" =~ ^[0-9a-f]{40,64}$ ]] || return 2
  git -C "$worktree" merge-base --is-ancestor "$merge_sha" origin/main || return 2
  pr_json="$(gh pr view "$pr_number" --repo "$REPO" --json files)" || return 2
  paths="$(jq -c '[.files[]?.path]' <<< "$pr_json")" || return 2
  kind="$(classify_pipeline_system_paths "$paths")" || return 2
  if [ "$kind" = pipeline-system ]; then
    pipeline_system_route_status "$n" || return "$(( $? == 1 ? 1 : 2 ))"
    route_pipeline_system_verification "$n" "$merge_sha" || return 2
  else
    conclude_merged_run "$n" "$pr_number" "Existing merged PR #$pr_number already contains this issue's change; waiting for release verification." || return 2
  fi
}

# is_on_hold <n> -- true (0) if #n carries the on-hold label OR the read
# itself failed. 2026-09-16 fix: this used to be `gh ... 2>/dev/null |
# grep -qx on-hold`, which throws away gh's own exit status inside the
# pipe -- a transient gh failure (network, rate limit, auth) produces the
# exact same empty stdout as "this issue genuinely has no labels", so
# `grep -qx` returned 1 (not on-hold) either way, and every caller took
# the permissive branch on an unreadable fact. Every caller of this
# function (issue-pipeline.sh's candidate-selection loops, run-advisor-
# batch.sh, run-recut.sh, sweep-acceptor-backlog.sh, sweep-parked-
# backlog.sh, this file's own sweep_reopened_issues()) uses the SAME
# direction -- true blocks the action -- so a read failure can safely fail
# closed the same way here: unknown must never look like "confirmed not on
# hold". See lessons/RULES.md's "unreadable fact treated as a permissive
# answer" entry.
declare -gA ISSUE_LABEL_SNAPSHOT_STATE=()
declare -gA ISSUE_LABEL_SNAPSHOT_IDS=()
declare -gA ISSUE_LABEL_SNAPSHOT_AT=()
declare -gA ISSUE_LABEL_VIEW_STATE=()
declare -gA ISSUE_LABEL_VIEW_LABELS=()
declare -gA ISSUE_LABEL_VIEW_AT=()
declare -gA ISSUE_LABEL_VIEW_ERROR=()
ISSUE_LABEL_BULK_QUERY_COUNT=0
ISSUE_LABEL_POINT_QUERY_COUNT=0

# Batch per-label reads and refresh within the existing GH call timeout. This
# caps staleness at one live-read bound; our own issue edits invalidate cache.
issue_label_cache_invalidate() {
  ISSUE_LABEL_SNAPSHOT_STATE=()
  ISSUE_LABEL_SNAPSHOT_IDS=()
  ISSUE_LABEL_SNAPSHOT_AT=()
  ISSUE_LABEL_VIEW_STATE=()
  ISSUE_LABEL_VIEW_LABELS=()
  ISSUE_LABEL_VIEW_AT=()
  ISSUE_LABEL_VIEW_ERROR=()
}

issue_label_snapshot_load() {
  local label="$1" ids issue count=0 age
  local ttl="${GH_CALL_TIMEOUT_SEC:-60}"
  if [ -n "${ISSUE_LABEL_SNAPSHOT_STATE[$label]:-}" ]; then
    age=$((SECONDS - ${ISSUE_LABEL_SNAPSHOT_AT[$label]:-0}))
    [ "$age" -lt "$ttl" ] && return 0
  fi

  ISSUE_LABEL_BULK_QUERY_COUNT=$((ISSUE_LABEL_BULK_QUERY_COUNT + 1))
  if ! ids="$(gh issue list --repo "$REPO" --state all --label "$label" --limit 1000 --json number -q '.[].number' 2>&1)"; then
    ISSUE_LABEL_SNAPSHOT_STATE[$label]=unavailable
    ISSUE_LABEL_SNAPSHOT_IDS[$label]=""
    ISSUE_LABEL_SNAPSHOT_AT[$label]="$SECONDS"
    return 0
  fi

  ISSUE_LABEL_SNAPSHOT_IDS[$label]=""
  while IFS= read -r issue; do
    [[ "$issue" =~ ^[0-9]+$ ]] || continue
    ISSUE_LABEL_SNAPSHOT_IDS[$label]+="${issue}"$'\n'
    count=$((count + 1))
  done <<< "$ids"
  ISSUE_LABEL_SNAPSHOT_STATE[$label]=complete
  [ "$count" -ge 1000 ] && ISSUE_LABEL_SNAPSHOT_STATE[$label]=truncated
  ISSUE_LABEL_SNAPSHOT_AT[$label]="$SECONDS"
}

issue_label_read_live() {
  local issue="$1" age ttl="${GH_CALL_TIMEOUT_SEC:-60}" labels
  if [ -n "${ISSUE_LABEL_VIEW_STATE[$issue]:-}" ]; then
    age=$((SECONDS - ${ISSUE_LABEL_VIEW_AT[$issue]:-0}))
    if [ "$age" -lt "$ttl" ]; then
      [ "${ISSUE_LABEL_VIEW_STATE[$issue]}" = loaded ]
      return $?
    fi
  fi

  ISSUE_LABEL_POINT_QUERY_COUNT=$((ISSUE_LABEL_POINT_QUERY_COUNT + 1))
  if ! labels="$(gh issue view "$issue" --repo "$REPO" --json labels -q '.labels[].name' 2>&1)"; then
    ISSUE_LABEL_VIEW_STATE[$issue]=failed
    ISSUE_LABEL_VIEW_ERROR[$issue]="$labels"
    ISSUE_LABEL_VIEW_LABELS[$issue]=""
    ISSUE_LABEL_VIEW_AT[$issue]="$SECONDS"
    return 1
  fi
  ISSUE_LABEL_VIEW_STATE[$issue]=loaded
  ISSUE_LABEL_VIEW_ERROR[$issue]=""
  ISSUE_LABEL_VIEW_LABELS[$issue]="$labels"
  ISSUE_LABEL_VIEW_AT[$issue]="$SECONDS"
  return 0
}

# cached_issue_has_label <issue> <label> -- 0 present, 1 absent, 2 unknown.
# Exactly-full batches may be truncated, so absent IDs fall back to a point read.
cached_issue_has_label() {
  local issue="$1" label="$2" state ids
  issue_label_snapshot_load "$label"
  state="${ISSUE_LABEL_SNAPSHOT_STATE[$label]}"
  ids="${ISSUE_LABEL_SNAPSHOT_IDS[$label]:-}"
  case $'\n'"$ids" in
    *$'\n'"$issue"$'\n'*) return 0 ;;
  esac
  [ "$state" = complete ] && return 1

  if ! issue_label_read_live "$issue"; then
    return 2
  fi
  grep -Fqx -- "$label" <<< "${ISSUE_LABEL_VIEW_LABELS[$issue]:-}"
}

# issue_on_hold_live <n> -- the merge-time hold read: the issue's own labels,
# never the bulk on-hold list. That list lags edits, so a merge right after
# `state_requeue N release-hold` read the released hold and refused (#2686,
# 2026-10-08). A failed read stays fail-closed (on hold).
issue_on_hold_live() {
  local labels
  if ! labels="$(gh issue view "$1" --repo "$REPO" --json labels -q '.labels[].name' 2>&1)"; then
    echo "issue_on_hold_live: gh issue view failed for #$1 -- treating as ON-HOLD (fail-closed): $labels" >&2
    return 0
  fi
  grep -Fqx -- on-hold <<< "$labels"
}

is_on_hold() {
  local status
  if cached_issue_has_label "$1" on-hold; then
    return 0
  else
    status=$?
  fi
  [ "$status" -eq 1 ] && return 1
  echo "is_on_hold: gh issue view failed for #$1 -- cannot confirm on-hold status, treating as ON-HOLD (fail-closed): ${ISSUE_LABEL_VIEW_ERROR[$1]:-unknown label state}" >&2
  ON_HOLD_QUERY_FAILURE_COUNT=$((ON_HOLD_QUERY_FAILURE_COUNT + 1))
  case " $ON_HOLD_QUERY_FAILURE_ISSUES " in
    *" $1 "*) ;;
    *) ON_HOLD_QUERY_FAILURE_ISSUES="${ON_HOLD_QUERY_FAILURE_ISSUES:+$ON_HOLD_QUERY_FAILURE_ISSUES }$1" ;;
  esac
  return 0
}

# has_label <n> <label> -- 0 if #n confirmed carries <label>, 1 if gh
# confirmed it does NOT, 2 if the read itself failed and presence could
# not be determined. 2026-09-16 fix (same root cause as is_on_hold()
# above, different shape): the old `gh ... 2>/dev/null | grep -qx` pipe
# collapsed "confirmed absent" and "gh failed" into the identical exit
# code 1. Unlike is_on_hold(), has_label()'s callers use it in BOTH
# directions -- issue-pipeline.sh's `has_label ... && continue` gates want
# presence to BLOCK the action, run-recut.sh's `has_label needs-recut ||`
# wants presence to be REQUIRED to proceed -- so a single boolean cannot
# fail closed for both directions at once. This returns the third state
# explicitly (exit 2) instead of collapsing it into 1; every caller must
# check for it and refuse rather than treat a non-zero exit as "confirmed
# absent" (run-recut.sh's `||` already refuses on ANY non-zero, so it
# needed no call-site change; issue-pipeline.sh's `&&`-style gates did --
# see their own comments).
has_label() {
  local status
  if cached_issue_has_label "$1" "$2"; then
    return 0
  else
    status=$?
  fi
  [ "$status" -eq 1 ] && return 1
  echo "has_label: gh issue view failed for #$1 while checking for label \"$2\" -- cannot confirm, returning unknown (not \"absent\")" >&2
  return 2
}

# merged_pr_main_row <pr-number> [issue-number] -> <pr-number><TAB><merge-sha>
# Only a merged PR targeting main can enter release state. A PR merged into
# another feature branch is not proof its code reached production.
merged_pr_main_row() {
  local pr_number="$1" n="${2:-}" pr_json row merge_evidence
  [[ "$pr_number" =~ ^[0-9]+$ ]] || return 1
  pr_json="$(gh pr view "$pr_number" --repo "$REPO" --json number,state,baseRefName,mergeCommit,mergedAt)" || return 1
  row="$(jq -er --arg p "$pr_number" '
    select((.number | tostring) == $p and .state == "MERGED" and .baseRefName == "main" and (.mergeCommit.oid // "") != "")
    | "\(.number)\t\(.mergeCommit.oid)"
  ' <<< "$pr_json")" || return 1
  if [ -n "$n" ]; then
    merge_evidence="$(jq -c '{number,merge_sha:.mergeCommit.oid,merged_at:.mergedAt}' <<< "$pr_json")" || return 1
    state_merge "$n" ".run.evidence.pr_number = $(jq -n --arg p "$pr_number" '$p') | .run.evidence.merged_pr = $merge_evidence | if (($merge_evidence.merged_at // \"\") | type == \"string\" and length > 0) then .run.merged_at = $merge_evidence.merged_at else del(.run.merged_at) end" || return 1
    efficiency_metrics_sync_issue_lifecycle "$n"
  fi
  printf '%s\n' "$row"
}

# merged_pr_for_issue <issue-number> -> <pr-number><TAB><merge-sha>
#
# conclude_merged_run records the exact PR number before it moves the issue to
# awaiting-release. Resolve through that durable ticket-to-PR link; release
# identity must not be re-inferred from a body mention or branch name.
merged_pr_for_issue() {
  local n="$1" state pr_number
  state="$(state_read "$n")" || return 1
  jq -e '(.state == "awaiting-release") and (.run.outcome == "merged")
    and (if (.run | has("merged_at")) then ((.run.merged_at // "") | type == "string" and length > 0) else true end)
    and (.deploy_state == "pending" or .deploy_state == "deployed")' \
    <<< "$state" >/dev/null || return 1
  pr_number="$(jq -r '.run.evidence.pr_number // empty' <<< "$state")"
  [[ "$pr_number" =~ ^[0-9]+$ ]] || return 1
  merged_pr_main_row "$pr_number" "$n"
}

# One safe exit rule for every worktree owner.
worktree_lifecycle_finish() {
  local wt="${1:-}" repo_dir="${2:-$REPO_DIR}" helper
  [ -n "$wt" ] || return 0
  helper="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/worktree-lifecycle.sh"
  bash "$helper" finish "$repo_dir" "$wt" "$$"
}

worktree_lifecycle_manifest() {
  local action="$1" name="$2" head="$3" detail="${4:-}" repo_dir="${5:-$REPO_DIR}" helper
  helper="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/worktree-lifecycle.sh"
  bash "$helper" record "$repo_dir" "$action" "$name" "$head" "$detail"
}

# sweep_reopened_issues -- called once per tick (issue-pipeline.sh, before
# section (a)), the same "settle transient state before dispatching new
# work" spot read_needs_info_email_replies() already runs in.
#
# A production-proven close needs the same correction path: a human Reopen
# returns it to triage, while failed outcomes remain open and never enter this
# sweep. A reopened issue must not sit dead on a
# terminal label nothing candidate-selects on (every other section below
# queries a DIFFERENT specific label -- needs-triage, ready-for-agent, ...
# -- so `concluded`/`wontfix`/`duplicate` alone is invisible to all of
# them).
#
# Every `gh issue close` this pipeline calls also stamps
# `.closed_by_pipeline = true` on that issue's own state (conclude_run()
# above, run-triage.sh's wontfix/duplicate branch). The marker, not a stage
# label, discovers reopens: a human may replace the terminal label before
# this sweep runs. `concluded` alone is NOT a safe reopen signal by itself;
# pr-open/not-completed outcomes can carry it while open, so require the
# marker and confirm each candidate with a live issue read.
sweep_reopened_issues() {
  local open_ids n current_state state_json
  local -a open_issue_ids=()
  open_ids="$(gh issue list --repo "$REPO" --limit 1000 --state open --json number -q '.[].number')" || {
    echo 'sweep_reopened_issues: could not list open issues' >&2
    return 1
  }
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || {
      echo 'sweep_reopened_issues: open issue list has invalid shape' >&2
      return 1
    }
    open_issue_ids+=("$n")
  done <<< "$open_ids"
  # ponytail: GH open-issue list caps at 1000; paginate if the repository reaches that many open issues.
  if ((${#open_issue_ids[@]} >= 1000)); then
    echo 'sweep_reopened_issues: open issue list reached 1000-record cap' >&2
    return 1
  fi
  for n in "${open_issue_ids[@]}"; do
    state_json="$(state_read "$n")" || return 1
    jq -e '.closed_by_pipeline == true' <<< "$state_json" >/dev/null 2>&1 || continue
    is_on_hold "$n" && continue
    # Search-index state can lag close/reopen events; confirm each candidate
    # against the issue resource before applying the durable-marker transition.
    current_state="$(gh issue view "$n" --repo "$REPO" --json state -q '.state' 2>/dev/null || echo "")"
    [ "$current_state" = "OPEN" ] || continue
    echo "issue-pipeline: #$n was closed by this pipeline and is open again -- reopened, re-entering as needs-triage" >&2
    issue_transition "$n" needs-triage reopened-by-human \
      'del(.closed_by_pipeline, .released, .deploy_state, .deployed_sha, .run.evidence.real_user_path)' || return 1
    guarded_issue_comment "$n" "$BOT_DISCLAIMER
这张票之前被流水线自动关闭过，现在被重新打开了——按现在的规则，这算是新的一轮，重新排进分诊，不需要人工干预。"
  done
}

# Maintainer-authored product issues are test/demo work unless pipeline evidence
# says a script created them. The bot uses the maintainer's GitHub account, so
# author alone is not enough to classify its generated issues.
MAINTAINER_TEST_CANDIDATE_FILTER='
    (((.author.login // .user.login // "") | ascii_downcase) == ($maintainer | ascii_downcase))
    and (($maintainer | length) > 0)
    and (([.labels[]?.name] | any(. == "pipeline-system" or . == "supervisor-created")) | not)
    and (((.title // "") | ascii_downcase | test("^(\\[recut\\]|\\[prerequisite\\]|\\[supervisor\\]|recut:|prerequisite:|pipeline brief:)")) | not)
    and ((.title // "") | contains("concluded-root-prerequisite-") | not)
    and ((.body // "") | contains($bot_marker) | not)
    and ((.body // "") | contains($recut_marker) | not)
    and ((.body // "") | contains("本票是流水线把 #") | not)
    and ((.body // "") | contains("这张票范围太大，流水线拆成了") | not)
    and ([.comments[]?.body // ""] | all(contains($bot_marker) | not))
'
maintainer_test_issue_candidate() {
  local issue_json="$1" roster="${ZF_AGENT_RECIPIENTS_FILE:-$AGENT_HOME/recipients.json}" maintainer_login
  [ -f "$roster" ] || return 1
  maintainer_login="$(jq -r '.maintainer_login // empty' "$roster" 2>/dev/null)" || return 1
  [ -n "$maintainer_login" ] || return 1
  jq -e --arg maintainer "$maintainer_login" --arg bot_marker "$BOT_COMMENT_MARKER" \
    --arg recut_marker "$RECUT_CHILD_MARKER" "$MAINTAINER_TEST_CANDIDATE_FILTER" \
    <<< "$issue_json" >/dev/null 2>&1
}

issue_has_maintainer_test_label() {
  jq -e 'any(.labels[]?; .name == "maintainer-test")' <<< "$1" >/dev/null 2>&1
}

issue_is_maintainer_test() {
  issue_has_maintainer_test_label "$1" || maintainer_test_issue_candidate "$1"
}

MAINTAINER_TEST_LABEL_READY=0
ensure_maintainer_test_label() {
  local existing
  [ "$MAINTAINER_TEST_LABEL_READY" = 1 ] && return 0
  existing="$(gh label list --repo "$REPO" --limit 200 --json name -q '.[].name' 2>/dev/null)" || return 1
  if ! grep -qx -- maintainer-test <<< "$existing"; then
    if ! guarded_write gh label create maintainer-test --repo "$REPO" --color 5319E7 \
        --description "Maintainer-filed test and demo issue" >/dev/null; then
      existing="$(gh label list --repo "$REPO" --limit 200 --json name -q '.[].name' 2>/dev/null)" || return 1
      grep -qx -- maintainer-test <<< "$existing" || return 1
    fi
  fi
  MAINTAINER_TEST_LABEL_READY=1
}

label_maintainer_test_issue() {
  local issue_json="$1" n
  issue_has_maintainer_test_label "$issue_json" && return 0
  maintainer_test_issue_candidate "$issue_json" || return 1
  n="$(jq -er '.number | select(type == "number" and . > 0)' <<< "$issue_json")" || return 2
  ensure_maintainer_test_label || return 2
  guarded_write gh issue edit "$n" --repo "$REPO" --add-label maintainer-test >/dev/null
}

label_maintainer_test_candidates() {
  local issues="$1" live_issue_json n candidates maintainer_login
  local roster="${ZF_AGENT_RECIPIENTS_FILE:-$AGENT_HOME/recipients.json}"
  jq -e 'type == "array" and all(.[]; type == "object" and (.labels | type == "array"))' \
    <<< "$issues" >/dev/null || return 1
  [ -f "$roster" ] || { printf '%s\n' "$issues"; return 0; }
  maintainer_login="$(jq -r '.maintainer_login // empty' "$roster" 2>/dev/null)" || return 1
  # Same predicate as point classification; batch the unchanged local gates.
  candidates="$(jq -c --arg maintainer "$maintainer_login" --arg bot_marker "$BOT_COMMENT_MARKER" \
    --arg recut_marker "$RECUT_CHILD_MARKER" \
    "[.[] | select(any(.labels[]?; .name == \"maintainer-test\") | not) | select($MAINTAINER_TEST_CANDIDATE_FILTER)]" \
    <<< "$issues" | python3 -c '
import json, pathlib, sys
states = pathlib.Path(sys.argv[1])
for issue in json.load(sys.stdin):
    try:
        checked = json.loads((states / (str(issue["number"]) + ".json")).read_text()).get("maintainer_test_checked") is True
    except (OSError, ValueError, AttributeError):
        checked = False
    if not checked:
        print(issue["number"])
' "$STATE_DIR")" || return 1
  while IFS= read -r n; do
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || continue
    if ! live_issue_json="$(gh_timeout 30s issue view "$n" --repo "$REPO" \
        --json number,title,body,author,comments,labels,state 2>/dev/null)"; then
      # A transient read failure (gateway 504) skips this issue for one tick;
      # failing the whole candidate list aborted the scheduler tick (2026-09-27).
      echo "issue-pipeline: cannot re-read #$n to classify maintainer-test origin; skipping it this tick" >&2
      continue
    fi
    [ "$(jq -r '.state // empty' <<< "$live_issue_json")" = OPEN ] || continue
    if ! maintainer_test_issue_candidate "$live_issue_json"; then
      state_merge "$n" '.maintainer_test_checked = true' >/dev/null 2>&1 || true
      continue
    fi
    if ! label_maintainer_test_issue "$live_issue_json"; then
      echo "issue-pipeline: failed to apply maintainer-test label to #$n" >&2
      return 1
    fi
    issues="$(jq -c --argjson n "$n" 'map(if .number == $n then .labels += [{name:"maintainer-test"}] else . end)' <<< "$issues")" || return 1
  done <<< "$candidates"
  printf '%s\n' "$issues"
}

# --- 批次 STATE（#4363）-------------------------------------------------------
# 每批工作的父票正文带一段机器可读 STATE（完成标准、关键路径、各 ticket 的延迟成本
# 等级），格式见 docs/agents/issue-pipeline.md「批次 STATE 与延迟成本排序」。队列排序
# 只认标签（生产事故 > 关键路径 > 功能 > 遗留）；本 sweep 周期性把 STATE 同步成
# critical-path / legacy 标签，选择站点因此不需要额外读父票。STATE 没列到的票不动。
BATCH_STATE_SWEEP_SECONDS="${BATCH_STATE_SWEEP_SECONDS:-3600}"
DELAY_COST_LABEL_READY=0
ensure_delay_cost_labels() {
  local existing
  [ "$DELAY_COST_LABEL_READY" = 1 ] && return 0
  existing="$(gh label list --repo "$REPO" --limit 200 --json name -q '.[].name' 2>/dev/null)" || return 1
  if ! grep -qx -- critical-path <<< "$existing"; then
    if ! guarded_write gh label create critical-path --repo "$REPO" --color D93F0B \
        --description "On the current batch STATE critical path; sorts ahead of features" >/dev/null; then
      existing="$(gh label list --repo "$REPO" --limit 200 --json name -q '.[].name' 2>/dev/null)" || return 1
      grep -qx -- critical-path <<< "$existing" || return 1
    fi
  fi
  if ! grep -qx -- legacy <<< "$existing"; then
    if ! guarded_write gh label create legacy --repo "$REPO" --color 8B949E \
        --description "Legacy or backlog cleanup per the batch STATE; sorts after features" >/dev/null; then
      existing="$(gh label list --repo "$REPO" --limit 200 --json name -q '.[].name' 2>/dev/null)" || return 1
      grep -qx -- legacy <<< "$existing" || return 1
    fi
  fi
  DELAY_COST_LABEL_READY=1
}

# batch_state_band_map <issues-json> → 每行 "issue<TAB>critical|legacy|feature"。
# issues-json 是 open issue 数组（含 body/labels）；父票 = 正文含 zf-batch-state
# 标记的票。STATE 里 critical_path 列表和 delay_cost=critical 都进关键路径；
# 解析失败的父票跳过（stderr 一行），不让一张坏父票停掉整个 sweep。
batch_state_band_map() {
  jq -r '
    def state_blocks($body):
      [$body | scan("<!-- zf-batch-state\\s*(\\{.*?\\})\\s*-->") | .[0]] ;
    # gh api --paginate --slurp 交付的是页数组；直接喂平铺数组也要能解析。
    [ .[] | if type == "array" then .[] else . end
      | select(type == "object" and has("number") and (has("pull_request") | not)) ] as $issues
    | ([$issues[] | select((.body // "") | contains("zf-batch-state"))
        | .number as $parent
        | ([state_blocks(.body)[] | try fromjson catch null | select(type == "object")] | last) as $state
        | if $state == null then
            "invalid-parent:\($parent)"
          else
            (($state.delay_cost // {}) | to_entries | map({key: (.key | tostring), value: (.value | tostring)})) as $graded
            | (($state.critical_path // []) | map({key: (. | tostring), value: "critical"})) as $pathed
            | ([$graded, $pathed] | flatten | reduce .[] as $e ({}; .[$e.key] = $e.value)) as $bands
            | ($bands | keys[]) as $n | "\($n)\t\($bands[$n])"
          end ] | unique) as $entries
    | ($entries[] | select(startswith("invalid-parent:"))),
      ($entries[] | select(startswith("invalid-parent:") | not))
  ' <<< "$1" 2>/dev/null
}

sweep_batch_state() {
  local issue_pages bands n band names epoch_file="$AGENT_HOME/state/batch-state.epoch" now last
  local scan_complete=1
  [ "${DRY_RUN:-0}" != 1 ] || return 0
  now="$(date +%s)" || return 1
  if [ -r "$epoch_file" ]; then
    IFS= read -r last 2>/dev/null < "$epoch_file" || last=""
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    [ $(( now - last )) -ge "$BATCH_STATE_SWEEP_SECONDS" ] || return 0
  fi
  if ! issue_pages="$(gh api --paginate --slurp "repos/$REPO/issues?state=open&per_page=100")"; then
    echo "sweep_batch_state: could not list open issues; retrying next tick" >&2
    return 1
  fi
  if ! bands="$(batch_state_band_map "$issue_pages")"; then
    echo "sweep_batch_state: could not derive delay-cost bands; retrying next tick" >&2
    return 1
  fi
  local -A desired=()
  while IFS=$'\t' read -r n band; do
    if [[ "$n" == invalid-parent:* ]]; then
      echo "sweep_batch_state: ${n#invalid-parent:} carries an unparseable batch STATE; skipped" >&2
      continue
    fi
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || continue
    case "$band" in critical|legacy|feature) desired["$n"]="$band" ;; esac
  done <<< "$bands"
  [ "${#desired[@]}" -gt 0 ] || { printf '%s\n' "$now" > "$epoch_file"; return 0; }
  ensure_delay_cost_labels || { echo "sweep_batch_state: delay-cost labels unavailable; retrying next tick" >&2; return 1; }
  while IFS=$'\t' read -r n names_json; do
    band="${desired[$n]:-}"
    [ -n "$band" ] || continue
    names="$(jq -r '.[]' <<< "$names_json" 2>/dev/null)" || { scan_complete=0; continue; }
    local -a edit_args=()
    case "$band" in
      critical)
        grep -qx -- critical-path <<< "$names" || edit_args+=(--add-label critical-path)
        if grep -qx -- legacy <<< "$names"; then edit_args+=(--remove-label legacy); fi ;;
      legacy)
        grep -qx -- legacy <<< "$names" || edit_args+=(--add-label legacy)
        if grep -qx -- critical-path <<< "$names"; then edit_args+=(--remove-label critical-path); fi ;;
      feature)
        if grep -qx -- critical-path <<< "$names"; then edit_args+=(--remove-label critical-path); fi
        if grep -qx -- legacy <<< "$names"; then edit_args+=(--remove-label legacy); fi ;;
    esac
    [ "${#edit_args[@]}" -gt 0 ] || continue
    if ! guarded_write gh issue edit "$n" --repo "$REPO" "${edit_args[@]}" >/dev/null; then
      echo "sweep_batch_state: failed to sync delay-cost labels on #$n; retrying next tick" >&2
      scan_complete=0
    fi
  done < <(jq -r '[.[][] | select(type == "object" and has("number") and (has("pull_request") | not)) | "\(.number)\t\([.labels[]?.name] | tojson)"] | .[]' <<< "$issue_pages" 2>/dev/null)
  issue_label_cache_invalidate
  [ "$scan_complete" = 1 ] || return 1
  printf '%s\n' "$now" > "$epoch_file"
}

# sweep_unlabeled_issues -- rescue open issues that carry no pipeline state.
# Derive the state-label filter from ALL_STATE_LABELS; category labels remain
# untouched. The REST issue list is paginated and includes pull requests, so
# filter those out and re-read each candidate before mutation.
sweep_unlabeled_issues() {
  local candidates issue_pages n issue_json issue_after_write issue_state recut_status state_labels_json lane_match_status maintainer_test maintainer_login roster intake_since candidate_branch source_issue
  local rescued=0 scan_complete=1 mutation_failed=0 state_label marker="$AGENT_HOME/unlabeled-issue-sweep-alerted"
  local inbox="$AGENT_HOME/supervisor-inbox"
  local -a edit_args=()

  state_labels_json="$(printf '%s\n' "${ALL_STATE_LABELS[@]}" | jq -R . | jq -cs .)" || return 1
  roster="${ZF_AGENT_RECIPIENTS_FILE:-$AGENT_HOME/recipients.json}"
  maintainer_login="$(jq -r '.maintainer_login // empty' "$roster" 2>/dev/null || true)"
  if ! issue_pages="$(gh api --paginate --slurp "repos/$REPO/issues?state=open&per_page=100")"; then
    echo "sweep_unlabeled_issues: could not list open issues; leaving alert state unchanged" >&2
    return 1
  fi
  # The pipeline files issues under the maintainer account too, so "authored by
  # the maintainer" matched 203 of 210 open issues and every tick re-read each one
  # with comments (17+ min, 2026-09-27). A maintainer test issue is recognised when
  # it is new: only issues created inside the intake window qualify, and one
  # already judged (maintainer_test_checked in local state) is not re-read.
  intake_since="$(date -u -d "-${ZF_MAINTAINER_TEST_INTAKE_HOURS:-48} hours" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  if ! candidates="$(jq -r --argjson states "$state_labels_json" --arg maintainer "$maintainer_login" --arg since "$intake_since" '
    if type != "array" or any(.[]; type != "array") then error("invalid paginated issue response")
    else
      (add // [])[]
      | select(type == "object" and (has("pull_request") | not) and .state == "open")
      | [.labels[]?.name] as $names
      | if all($states[]; . as $state | ($names | index($state)) == null) then "\(.number)\tunlabeled"
        elif ($maintainer != "") and ((.user.login // "") | ascii_downcase) == ($maintainer | ascii_downcase)
          and (($names | index("maintainer-test")) == null) and ((.created_at // "") >= $since) then "\(.number)\tmaintainer"
        else empty end
    end
  ' <<< "$issue_pages")"; then
    echo "sweep_unlabeled_issues: could not filter paginated issues; leaving alert state unchanged" >&2
    return 1
  fi
  issue_label_cache_invalidate

  while IFS=$'\t' read -r n candidate_branch; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    if [ "$candidate_branch" = maintainer ] \
      && state_read "$n" 2>/dev/null | jq -e '.maintainer_test_checked == true' >/dev/null 2>&1; then
      continue
    fi
    if is_on_hold "$n"; then
      [ "${ISSUE_LABEL_VIEW_STATE[$n]:-}" = failed ] && scan_complete=0
      continue
    fi
    if ! issue_json="$(gh issue view "$n" --repo "$REPO" --json number,state,labels,title,body,author,comments 2>/dev/null)"; then
      echo "sweep_unlabeled_issues: cannot re-read #$n; skipping" >&2
      scan_complete=0
      continue
    fi
    if ! jq -e 'type == "object" and (.state == "OPEN" or .state == "CLOSED") and (.labels | type == "array")' \
      <<< "$issue_json" >/dev/null; then
      echo "sweep_unlabeled_issues: unreadable issue response for #$n; skipping" >&2
      scan_complete=0
      continue
    fi
    [ "$(jq -r '.state' <<< "$issue_json")" = OPEN ] || continue
    if jq -e 'any(.labels[]?; .name == "on-hold")' <<< "$issue_json" >/dev/null; then continue; fi
    maintainer_test=0
    if maintainer_test_issue_candidate "$issue_json" && ! issue_has_maintainer_test_label "$issue_json"; then
      if ! ensure_maintainer_test_label; then
        echo "sweep_unlabeled_issues: cannot ensure maintainer-test label for #$n; skipping" >&2
        scan_complete=0
        continue
      fi
      maintainer_test=1
    fi
    if jq -e --argjson states "$state_labels_json" \
      '[.labels[]?.name] as $names | any($states[]; . as $state | ($names | index($state)) != null)' \
      <<< "$issue_json" >/dev/null; then
      if [ "$maintainer_test" = 1 ] && ! label_maintainer_test_issue "$issue_json"; then
        echo "sweep_unlabeled_issues: failed to label maintainer-test issue #$n; skipping" >&2
        scan_complete=0
      elif [ "$candidate_branch" = maintainer ]; then
        state_merge "$n" '.maintainer_test_checked = true' >/dev/null 2>&1 || true
      fi
      continue
    fi
    lane_match_status=0
    pipeline_system_issue_matches "$issue_json" || lane_match_status=$?
    case "$lane_match_status" in
      0)
        if [ "$(roadmap_switch_value)" = true ] \
          && ! roadmap_place_issue "$ZF_ROADMAP_TREE_CACHE_FILE" "$n" "$issue_json"; then
          echo "sweep_unlabeled_issues: failed to place pipeline-system issue #$n in roadmap" >&2
          mutation_failed=1
          continue
        fi
        if ! prepare_pipeline_system_issue "$n" "$issue_json"; then
          echo "sweep_unlabeled_issues: failed to admit pipeline-system issue #$n; leaving it unlabeled" >&2
          mutation_failed=1
        fi
        continue
        ;;
      1) ;;
      *) echo "sweep_unlabeled_issues: cannot classify #$n; leaving it unlabeled" >&2; scan_complete=0; continue ;;
    esac
    if ! issue_state="$(state_read "$n")"; then
      echo "sweep_unlabeled_issues: unreadable local state for #$n; skipping" >&2
      scan_complete=0
      continue
    fi
    if ! recut_status="$(jq -er '
      if type != "object" then "invalid"
      elif .tracker_parent == true or .state == "tracker" then "tracker"
      elif ((.recut_children // []) | type) != "array" then "invalid"
      elif ((.recut_children // []) | length) > 0 then "umbrella"
      else "ordinary" end
    ' <<< "$issue_state")"; then
      echo "sweep_unlabeled_issues: unreadable local state for #$n; skipping" >&2
      scan_complete=0
      continue
    fi
    case "$recut_status" in
      tracker|umbrella) continue ;;
      invalid) scan_complete=0; continue ;;
    esac

    source_issue="$(roadmap_source_issue "$issue_json")"
    if ! issue_transition "$n" needs-triage unlabeled-rescue . 0 "$issue_json" "$source_issue"; then
      if issue_after_write="$(gh_timeout 30s issue view "$n" --repo "$REPO" \
          --json state,labels 2>/dev/null)" \
        && jq -e '.state == "OPEN" and any(.labels[]?; .name == "needs-triage")' \
          <<< "$issue_after_write" >/dev/null; then
        rescued=$((rescued + 1))
      fi
      echo "sweep_unlabeled_issues: failed to rescue #$n; reporting prior rescues" >&2
      mutation_failed=1
      scan_complete=0
      break
    fi
    if [ "$maintainer_test" = 1 ] && ! label_maintainer_test_issue "$issue_json"; then
      echo "sweep_unlabeled_issues: failed to label maintainer-test issue #$n; skipping" >&2
      mutation_failed=1
      scan_complete=0
      break
    fi
    rescued=$((rescued + 1))
  done <<< "$candidates"

  if [ "${DRY_RUN:-0}" = "1" ]; then
    [ "$rescued" -gt 0 ] && echo "issue-pipeline: unlabeled-issue-sweep would-rescue=$rescued" >&2
    return 0
  fi
  if [ "$rescued" -gt 0 ] && [ ! -f "$marker" ]; then
    supervisor_inbox_append unlabeled-issue-sweep "appear rescued=$rescued" || return 1
    touch "$marker"
  elif [ "$rescued" -eq 0 ] && [ "$scan_complete" -eq 1 ] && [ -f "$marker" ]; then
    supervisor_inbox_append unlabeled-issue-sweep clear || return 1
    rm -f "$marker"
  fi
  [ "$mutation_failed" -eq 0 ] || return 1
}

# Keep quarantined terminal work in an owned parked state, not `concluded`.
conclusion_hold() {
  local n="$1" owner="$2" label
  state_merge "$n" ".run.conclusion.owner = $(jq -cn --arg owner "$owner" '$owner')" || return 1
  local -a hold_args=(--holder "$owner" --release "conclusion blocker is reviewed by $owner" --expires 24h --kind conclusion)
  for label in "${ALL_STATE_LABELS[@]}"; do
    [ "$label" = on-hold ] || hold_args+=(--remove-label "$label")
  done
  hold_issue "$n" "${hold_args[@]}"
}

conclusion_requeue_comment_once() {
  local n="$1" episode marker comments reason comment_status
  episode="$(state_read "$n" | jq -r '.run.concluded_at // "unknown"')"
  marker="<!-- zf-conclusion-requeue issue=$n episode=$episode -->"
  comments="$(gh issue view "$n" --repo "$REPO" --json comments)" || return 1
  jq -e 'type == "object" and (.comments | type == "array")' <<< "$comments" >/dev/null || return 1
  if jq -e --arg marker "$marker" 'any(.comments[]?; (.body // "") | contains($marker))' <<< "$comments" >/dev/null; then
    return 0
  else
    comment_status=$?
    [ "$comment_status" -eq 1 ] || return 1
  fi
  reason="$(state_read "$n" | jq -r '.run.conclusion.reason // .run.conclusion.signature // .run.needs_md // "infrastructure precondition recovered"')"
  guarded_issue_comment "$n" "$BOT_DISCLAIMER
基础设施前置条件已恢复，这张票已自动重新入队。原因：$reason

$marker"
}

# Why reconcile_blocking_issue_root last failed: one line the blocker-root
# sweep copies into its supervisor-inbox alert. Set at the deepest point that
# knows why; a callee's reason outranks its caller's (set-if-empty), so the
# sweep never blames a phase for a failure one level deeper already explained.
# Empty while a reconcile succeeds, so only the sweep's failure branch reads it.
BLOCKER_ROOT_FAIL_REASON=""
blocker_root_fail() {
  [ -n "${BLOCKER_ROOT_FAIL_REASON:-}" ] || BLOCKER_ROOT_FAIL_REASON="$*"
  return 1
}

# Reconcile an open issue that still blocks open work. A completed recut
# parent is an umbrella; move its outgoing edges to its live children. A
# not-completed conclusion gets one automatic exit, chosen from its durable
# reason. Each new conclusion episode gets a fresh attempt budget; a repeated
# conclusion in that episode or after actual recut children escalates once.
reconcile_blocking_issue_root() {
  local issue_json="$1" open_issues_json="$2" n issue_state state owner_state dependents_json has_state_label
  local children_json child child_state dependent dependent_json existing_child_edges recut_status
  local exit_count recut_parent=0 episode reason latest_reason reason_text action reason_class escalated_episode blockers pipeline_system_status=0
  local last_episode last_action delivery_failed_episode retry_failed_route=0 thread_id question thread_json inbox state_labels_json child_list pr_number
  local terminal_candidate conclusion_owned_hold conclusion_json conclusion_class="" conclusion_route="" conclusion_owner="" conclusion_signature conclusion_reason expected_scope comment_marker matching_scope scope_decision risk_class_escalation
  local recut_reason recut_reason_text recut_reason_file recut_reason_json attempts_before_reset reset_record reset_reason reset_reason_file prerequisite_index prerequisite_number prerequisite_state prerequisite_record prerequisite_disqualified prerequisite_state_reason prerequisite_reason_file prerequisite_repeat_status
  local prerequisite_marker prerequisite_title prerequisite_body prerequisite_body_file prerequisite_url prerequisite_json issue_title
  local -a edit_args=() live_children=()

  BLOCKER_ROOT_FAIL_REASON=""
  if ! jq -e 'type == "object" and (.number | type) == "number" and (.blocking.nodes | type) == "array"' \
    <<< "$issue_json" >/dev/null 2>&1; then
    echo "reconcile_blocking_issue_root: invalid issue graph row" >&2
    blocker_root_fail "invalid issue graph row passed to reconcile_blocking_issue_root"
    return 2
  fi
  n="$(jq -r '.number' <<< "$issue_json")"
  issue_state="$(jq -r '.state // empty | ascii_downcase' <<< "$issue_json")"
  [ "$issue_state" = open ] || return 0
  dependents_json="$(jq -c '[.blocking.nodes[] | select((.state | ascii_downcase) == "open") | .number | select(type == "number")]' <<< "$issue_json")" \
    || { blocker_root_fail "could not extract open dependents from the graph row for #$n"; return 2; }
  state="$(state_read "$n")" || { blocker_root_fail "state read failed for #$n"; return 1; }
  # Only these fields: the whole state can pass the 128 KiB per-argument limit.
  owner_state="$(jq -c '{run:{conclusion:{route:.run.conclusion.route,owner:.run.conclusion.owner}},hold:{kind:.hold.kind}}' <<< "$state")" \
    || { blocker_root_fail "state projection failed for #$n"; return 1; }
  terminal_candidate="$(jq -r --argjson owner_state "$owner_state" 'any(.labels[]?; .name == "concluded") or (any(.labels[]?; .name == "on-hold") and (($owner_state.run.conclusion.route // "") == "requeue"))' <<< "$issue_json")"
  # A conclusion hold is this function's own (conclusion_hold, or a backfilled record of one).
  # Any other hold belongs to its holder and hold_sweep: requeueing it here was suppressed by
  # the hold guard and repeated every tick, ~4.5s and a history entry each (2026-09-30).
  conclusion_owned_hold="$(jq -r --argjson owner_state "$owner_state" 'any(.labels[]?; .name == "on-hold")
    and (($owner_state.hold.kind // "") == "conclusion"
      or (($owner_state.hold.kind // "") == "backfill" and ($owner_state.run.conclusion.owner // "") == "issue-pipeline"))' <<< "$issue_json")"
  if ! jq -e 'type == "object" and has("recut_children")' <<< "$state" >/dev/null 2>&1; then
    # The observed silent failure (#2511/#2520, 2026-10-08 07:37-07:38Z): a
    # transient gh api sub_issues failure fails this read closed. The root
    # stays for the next tick by design; the reason must still reach the inbox.
    native_parent_subissues_json "$n" >/dev/null \
      || { blocker_root_fail "native sub-issue read unavailable for #$n"; return 1; }
  fi
  if children_json="$(recut_parent_children_json "$n" "$state")"; then
    reconcile_recut_parent_children "$n" "$children_json" "$open_issues_json" \
      || { blocker_root_fail "recut umbrella reconcile failed for #$n"; return 1; }
    return 0
  else
    recut_status=$?
    [ "$recut_status" -ne 2 ] || { blocker_root_fail "recut evidence read failed (status $recut_status) for #$n"; return 1; }
  fi
  if [ "$conclusion_owned_hold" != true ] && jq -e 'any(.labels[]?; .name == "on-hold")' <<< "$issue_json" >/dev/null; then
    return 0
  fi
  [ "$(jq 'length' <<< "$dependents_json")" -gt 0 ] || [ "$terminal_candidate" = true ] || return 0
  pipeline_system_route_status "$n" "$issue_json" fresh || pipeline_system_status=$?
  case "$pipeline_system_status" in
    0)
      pipeline_system_enabled=true
      if [ "$terminal_candidate" != true ] && [ "$(jq -r '.model_policy.step // empty' <<< "$state")" = conclude ]; then
        return 0
      fi
      if [ "$terminal_candidate" != true ]; then
        pipeline_system_return_to_implement "$n" && return 0
        blocker_root_fail "pipeline-system return-to-implement failed for #$n"
        return 1
      fi
      ;;
    1) pipeline_system_enabled=false ;;
    *)
      echo "reconcile_blocking_issue_root: cannot classify lane for #$n; keeping root unchanged" >&2
      blocker_root_fail "cannot classify pipeline-system lane for #$n"
      return 1
      ;;
  esac

  if [ "$terminal_candidate" = true ]; then
    if [ "$pipeline_system_status" = 0 ]; then
      state_merge "$n" '.pipeline_system.enabled = true' || { blocker_root_fail "pipeline-system state flag write failed for #$n"; return 1; }
      state="$(state_read "$n")" || { blocker_root_fail "state re-read failed for #$n"; return 1; }
    fi
    conclusion_class="$(jq -r '.run.conclusion.class // empty' <<< "$state")"
    conclusion_route="$(jq -r '.run.conclusion.route // empty' <<< "$state")"
    conclusion_signature="$(jq -r '.run.conclusion.signature // empty' <<< "$state")"
    risk_class_escalation="$(jq -r '.model_policy.failure.stage == "risk-class"
      and .model_policy.failure.transition == "conclude"
      and .model_policy.failure.early_stop.reason == "same-failure"
      and .model_policy.failure.early_stop.advisor_seen == false' <<< "$state")"
    if [ "$pipeline_system_status" = 0 ] && [ "$conclusion_class" = ticket ] \
      && [ "$risk_class_escalation" = true ]; then
      # The implement gate already recorded the refusal in the persistent
      # model-policy ladder. route_to_advisor holds it for the supervisor
      # instead of opening another implement run.
      state_merge_attempt_transition "$n" '.attempts = 0 | .run.conclusion.signature = "risk-class-refusal"' \
        || { blocker_root_fail "risk-class admission reset failed for #$n"; return 1; }
      route_to_advisor "$n" concluded true "$issue_json" \
        || { blocker_root_fail "risk-class advisor route failed for #$n"; return 1; }
      if state_read "$n" | jq -e '.hold.kind == "pipeline-system-risk-class"' >/dev/null; then
        state_merge "$n" '.run.conclusion.route = "on-hold" | .run.conclusion.owner = "supervisor"' \
          || { blocker_root_fail "risk-class hold write failed for #$n"; return 1; }
      fi
      return 0
    fi
    if [ "$pipeline_system_status" = 0 ] && [ "$conclusion_class" = ticket ] \
      && [ "$conclusion_signature" != pipeline-system-delivery-failed ]; then
      conclusion_json="$(jq -cn --arg reason "$(jq -r '.run.conclusion.reason // .run.needs_md // empty' <<< "$state")" \
        '{class:"ticket",route:"requeue",owner:"issue-pipeline",signature:"pipeline-system-requeue",reason:$reason}')" \
        || { blocker_root_fail "pipeline-system requeue conclusion build failed for #$n"; return 1; }
      state_merge "$n" ".run.conclusion = $conclusion_json" \
        || { blocker_root_fail "pipeline-system requeue conclusion write failed for #$n"; return 1; }
      state="$(state_read "$n")" || { blocker_root_fail "state re-read failed for #$n"; return 1; }
      conclusion_route=requeue
    fi
    if [ "$(jq -r '.run.outcome // empty' <<< "$state")" = merged ]; then
      conclusion_json='{"class":"completed","route":"awaiting-release","owner":"release","signature":"merged"}'
      pr_number="$(jq -r '.run.evidence.pr_number // empty' <<< "$state")"
      state_merge "$n" ".run.conclusion = $conclusion_json" \
        || { blocker_root_fail "merged conclusion write failed for #$n"; return 1; }
      mark_awaiting_release "$n" "$pr_number" || { blocker_root_fail "awaiting-release mark failed for #$n (pr=$pr_number)"; return 1; }
      return 0
    fi
    if ! [[ "$conclusion_class" =~ ^(infrastructure|pipeline-defect|ticket)$ ]] \
      || ! [[ "$conclusion_route" =~ ^(requeue|recut|needs-info|close-not-planned)$ ]]; then
      conclusion_json="$(conclusion_classification_for_state "$n" "$state" "$(jq -r '.run.needs_md // empty' <<< "$state")")" \
        || { blocker_root_fail "conclusion classification failed for #$n"; return 1; }
      conclusion_class="$(jq -r '.class' <<< "$conclusion_json")"
      conclusion_route="$(jq -r '.route' <<< "$conclusion_json")"
      issue_transition "$n" concluded conclude:reconcile ".run.conclusion = $conclusion_json" \
        || { blocker_root_fail "concluded transition failed for #$n"; return 1; }
      state="$(state_read "$n")" || { blocker_root_fail "state re-read failed for #$n"; return 1; }
    fi
    conclusion_owner="$(jq -r '.run.conclusion.owner // empty' <<< "$state")"
    conclusion_signature="$(jq -r '.run.conclusion.signature // "unknown"' <<< "$state")"
    conclusion_reason="$(jq -r '.run.conclusion.reason // .run.needs_md // empty' <<< "$state")"
    if [ "$conclusion_route" = close-not-planned ]; then
      guarded_issue_comment "$n" "$BOT_DISCLAIMER
这项工作已按不计划实施处理。原因：$conclusion_reason" \
        || { blocker_root_fail "close-not-planned comment failed for #$n"; return 1; }
      issue_transition "$n" wontfix close-not-planned '.closed_by_pipeline = true | .run.conclusion.owner = "closed"' \
        || { blocker_root_fail "close-not-planned transition failed for #$n"; return 1; }
      guarded_write gh issue close "$n" --repo "$REPO" \
        || { blocker_root_fail "close-not-planned issue close failed for #$n"; return 1; }
      return 0
    fi
    if [ "$conclusion_class" = pipeline-defect ]; then
      supervisor_inbox_append_once "conclusion-pipeline-defect signature=$conclusion_signature" \
        "conclusion-pipeline-defect signature=$conclusion_signature issue=#$n route=requeue" \
        || { blocker_root_fail "pipeline-defect inbox append failed for #$n"; return 1; }
      if [ "$(jq -r '.state // empty' <<< "$state")" = on-hold ] \
        && [ "$conclusion_owner" = supervisor-inbox ]; then
        return 0
      fi
      conclusion_hold "$n" supervisor-inbox || { blocker_root_fail "pipeline-defect hold failed for #$n"; return 1; }
      return 0
    fi
    if [ "$conclusion_route" = requeue ]; then
      expected_scope="$(selection_scope_json <<< "$state")" || expected_scope='[]'
      matching_scope="$(jq -r '.run.conclusion.scope // empty' <<< "$state")"
      scope_decision=clear
      if [ -n "$matching_scope" ]; then
        scope_decision="$(quarantine_decision "$matching_scope")" \
          || { blocker_root_fail "quarantine decision failed for #$n (scope $matching_scope)"; return 1; }
      fi
      if stage_unit_active implement "$n" || [ "$scope_decision" = open ] \
        || ! stage_dispatch_allowed implement "$expected_scope"; then
        if [ "$(jq -r '.state // empty' <<< "$state")" = on-hold ] \
          && [ "$conclusion_owner" = issue-pipeline ]; then
          return 0
        fi
        conclusion_hold "$n" issue-pipeline || { blocker_root_fail "conclusion hold failed for #$n"; return 1; }
        return 0
      fi
      [ "$scope_decision" != canary ] || quarantine_mark_canary "$matching_scope" \
        || { blocker_root_fail "canary quarantine mark failed for #$n"; return 1; }
      if [ "$conclusion_owner" = release ]; then
        return 0
      fi
      if [ "$conclusion_class" = infrastructure ]; then
        conclusion_requeue_comment_once "$n" || { blocker_root_fail "infrastructure requeue comment failed for #$n"; return 1; }
      fi
      if [ "$conclusion_owned_hold" = true ]; then
        state_requeue "$n" release-hold hold-requeue \
          || { blocker_root_fail "release-hold requeue failed for #$n"; return 1; }
      else
        state_requeue "$n" "" conclusion-requeue \
          || { blocker_root_fail "conclusion requeue failed for #$n"; return 1; }
      fi
      if [ "$pipeline_system_status" = 0 ]; then
        state_merge "$n" '.run.conclusion.owner = "issue-pipeline"' \
          || { blocker_root_fail "conclusion owner write failed for #$n"; return 1; }
      else
        state_merge "$n" '.run.conclusion.owner = "implement"' \
          || { blocker_root_fail "conclusion owner write failed for #$n"; return 1; }
      fi
      return 0
    fi
    if [ -z "$(jq -r '.run.outcome // empty' <<< "$state")" ]; then
      state_merge "$n" '.run.outcome = "not-completed" | .run.outcome_inferred = true | .run.needs_md = (.run.needs_md // "No terminal outcome was recorded; please confirm the intended result.")' \
        || { blocker_root_fail "outcome inference write failed for #$n"; return 1; }
      state="$(state_read "$n")" || { blocker_root_fail "state re-read failed for #$n"; return 1; }
    fi
  fi
  if jq -e 'any(.labels[]?; .name == "concluded")' <<< "$issue_json" >/dev/null; then
    if [ "$(jq -r '.run.outcome // empty' <<< "$state")" != not-completed ]; then
      return 0
    fi
    episode="$(jq -r '.run.concluded_at // "unknown"' <<< "$state")"
    exit_count="$(jq -r '.concluded_blocker_recovery.auto_exits // 0 | if type == "number" then . else 0 end' <<< "$state")"
    last_episode="$(jq -r '.concluded_blocker_recovery.last_episode // empty' <<< "$state")"
    last_action="$(jq -r '.concluded_blocker_recovery.last_action // empty' <<< "$state")"
    delivery_failed_episode="$(jq -r '.concluded_blocker_recovery.question_delivery_failed_episode // empty' <<< "$state")"
    # Count exits by conclusion timestamp, not across the issue's lifetime.
    if [ "$exit_count" -ge 1 ] && [ "$last_action" = needs-advisor ] \
      && ! jq -e '(.recut_children | type) == "array" and (.recut_children | length > 0)' <<< "$state" >/dev/null; then
      retry_failed_route=1
    elif jq -e '(.recut_children | type) == "array" and (.recut_children | length) > 0' <<< "$state" >/dev/null \
      || { [ "$exit_count" -ge 1 ] && [ "$last_episode" = "$episode" ]; }; then
        inbox="$AGENT_HOME/supervisor-inbox"
        escalated_episode="$(jq -r '.concluded_blocker_recovery.escalated_episode // empty' <<< "$state")"
        if [ "$escalated_episode" != "$episode" ] && ! grep -Fq "concluded-blocker-recovery issue=#$n " "$inbox" 2>/dev/null; then
          blockers="$(jq -r 'map(tostring) | join(",")' <<< "$dependents_json")" \
            || { blocker_root_fail "dependents extraction failed for #$n escalation"; return 1; }
          supervisor_inbox_append concluded-blocker-recovery \
            "issue=#$n episode=$episode reason=repeat-after-recut blockers=$blockers" \
            || { blocker_root_fail "repeat-conclusion escalation inbox append failed for #$n"; return 1; }
          state_merge "$n" ".concluded_blocker_recovery.supervisor_escalated_at = (now | todate) | .concluded_blocker_recovery.escalated_episode = $(jq -cn --arg episode "$episode" '$episode')" \
            || { blocker_root_fail "repeat-conclusion escalation write failed for #$n"; return 1; }
          echo "issue-pipeline: blocker-root issue=#$n class=repeat action=supervisor-escalation blockers=$blockers" >&2
          BLOCKING_ROOT_GRAPH_CHANGED=1
        fi
        return 0
    fi
  elif [ "$(jq -r '.run.outcome // empty' <<< "$state")" = not-completed ] \
    && [ "$(jq -r '.concluded_blocker_recovery.auto_exits // 0' <<< "$state")" -ge 1 ] \
    && ! jq -e '(.recut_children | type) == "array" and (.recut_children | length > 0)' <<< "$state" >/dev/null \
    && { \
      { jq -e 'any(.labels[]?; .name == "needs-recut")' <<< "$issue_json" >/dev/null \
        && [ "$(jq -r '.concluded_blocker_recovery.last_action // empty' <<< "$state")" = needs-recut ]; } \
      || { jq -e 'any(.labels[]?; .name == "needs-advisor")' <<< "$issue_json" >/dev/null \
        && [ "$(jq -r '.concluded_blocker_recovery.last_action // empty' <<< "$state")" = needs-advisor ]; } \
    }; then
    episode="$(jq -r '.run.concluded_at // "unknown"' <<< "$state")"
    exit_count="$(jq -r '.concluded_blocker_recovery.auto_exits // 0' <<< "$state")"
    last_episode="$(jq -r '.concluded_blocker_recovery.last_episode // empty' <<< "$state")"
    last_action="$(jq -r '.concluded_blocker_recovery.last_action // empty' <<< "$state")"
    delivery_failed_episode="$(jq -r '.concluded_blocker_recovery.question_delivery_failed_episode // empty' <<< "$state")"
    if [ "$last_action" = needs-recut ] && [ "$last_episode" != "$episode" ]; then
      return 0
    fi
    [ "$last_action" = needs-advisor ] && [ "$delivery_failed_episode" = "$episode" ] \
      || retry_failed_route=1
  fi

  if [ "$(jq -r '.run.outcome // empty' <<< "$state")" = not-completed ] \
    && { jq -e 'any(.labels[]?; .name == "concluded")' <<< "$issue_json" >/dev/null \
      || [ "$retry_failed_route" = 1 ]; }; then
    recut_reason="$(jq -r '.recut_refused_reason // empty' <<< "$state")"
    if [ -z "$recut_reason" ] && [ -n "$(jq -r '.recut_refused_at // empty' <<< "$state")" ]; then
      # Legacy refusals predate the durable reason field; recover the latest
      # matching comment once, then keep using the normal state file.
      recut_reason="$(gh issue view "$n" --repo "$REPO" --json comments | jq -r '
        [ .comments[]?.body // ""
          | select(contains("流水线尝试把这张票拆成可独立交付的小票，但没能做到："))
          | split("流水线尝试把这张票拆成可独立交付的小票，但没能做到：")[1]
          | split("\n\n")[0]
          | select(length > 0)
        ] | last // ""
      ')" || { blocker_root_fail "legacy refusal comment read failed for #$n"; return 1; }
      if [ -n "$recut_reason" ]; then
        recut_reason_file="$(jq_arg_file "$recut_reason")" \
          || { blocker_root_fail "legacy refusal reason temp file failed for #$n"; return 1; }
        if ! recut_reason_json="$(jq -cn --rawfile reason "$recut_reason_file" '$reason')"; then
          rm -f -- "$recut_reason_file"
          blocker_root_fail "legacy refusal reason json build failed for #$n"
          return 1
        fi
        if ! state_merge "$n" ".recut_refused_reason = $recut_reason_json"; then
          rm -f -- "$recut_reason_file"
          blocker_root_fail "legacy refusal reason write failed for #$n"
          return 1
        fi
        if ! state="$(jq --rawfile reason "$recut_reason_file" '.recut_refused_reason = $reason' <<< "$state")"; then
          rm -f -- "$recut_reason_file"
          blocker_root_fail "legacy refusal reason merge into local state failed for #$n"
          return 1
        fi
        rm -f -- "$recut_reason_file"
      fi
    fi
    latest_reason="$(jq -r '
      [(.model_policy.failure // null), ((.model_policy.failures // [])[-1] // null), (.model_policy.retry_note // null)]
      | map(select(type == "object" and (.reason // "") != ""))
      | sort_by(.recorded_at // "") | last.reason // empty
    ' <<< "$state")"
    reason="$(jq -r '[.run.needs_md, .last_failure_reason] | map(select(type == "string" and length > 0)) | first // empty' <<< "$state")"
    if [[ "$reason" =~ ^(Implement dispatch reached its 4-attempt cap|Four implement attempts failed|Configured model escalation exhausted) ]] && [ -n "$latest_reason" ]; then
      reason="$latest_reason"
    fi
    [ -n "$reason" ] || reason="$latest_reason"
    reason_text="$(printf '%s' "$reason" | tr '[:upper:]' '[:lower:]')"
    if [[ "$reason_text" =~ previous[[:space:]](model|implement)[[:space:]]unit[[:space:]]ended[[:space:]](without[[:space:]]recording[[:space:]]a[[:space:]]result|with[[:space:]]systemd[[:space:]]result=(oom-kill|timeout|watchdog|start-limit-hit))|previous[[:space:]](model|implement)[[:space:]]unit[[:space:]]has[[:space:]]no[[:space:]]persisted[[:space:]]systemd[[:space:]]result|ci[[:space:]-]+runner[[:space:]]capacity|ci[[:space:]-]+deadline|merge-lock[[:space:]]contention|provider[[:space:]]quota|provider[[:space:]]outage|network[[:space:]]fault|docker[[:space:]]hub[[:space:]]dns/connect[[:space:]]timeout|checkout[[:space:]]step[[:space:]]failed[[:space:]]before[[:space:]]project[[:space:]]checks ]]; then
      reason_class=infrastructure
      action=ready-for-agent
    elif [ "$(jq -r '.review_verdict // empty' <<< "$state")" = INPUT_INCOMPLETE ] \
      || [[ "$reason_text" =~ p[0-3]/l[0-4][[:space:]]path|product[[:space:]]decision|input[_[:space:]-]+incomplete|missing[[:space:]].*decision ]]; then
      reason_class=product-decision
      action=needs-info
    elif [ -n "$reason" ]; then
      reason_class=real-failure
      action=needs-recut
    else
      reason_class=unrecorded-reason
      action=needs-info
    fi

    if [ "$(jq -r '.run.conclusion.class // empty' <<< "$state")" = ticket ]; then
      case "$(jq -r '.run.conclusion.route // empty' <<< "$state")" in
        needs-info) reason_class=product-decision; action=needs-info ;;
        recut) reason_class=real-failure; action=needs-recut ;;
      esac
    fi

    recut_reason_text="$(printf '%s' "$recut_reason" | tr '[:upper:]' '[:lower:]')"
    if [ -n "$recut_reason" ] && [ "$retry_failed_route" != 1 ]; then
      if [[ "$recut_reason_text" =~ (not[[:space:]]found|does[[:space:]]not[[:space:]]exist|no[[:space:]]|未找到|不存在|没有|尚无|缺少) ]] \
        && [[ "$recut_reason_text" =~ (implementation|persistence|storage|finalizer|writer|实现|持久化|存储|原生|事件) ]] \
        && ! [[ "$recut_reason_text" =~ 子票|child|索引|超过|上限|成环|循环 ]]; then
        reason_class=missing-prerequisite
        action=prerequisite
      elif [[ "$recut_reason_text" =~ risk_class=|level=|权限阶段|permission[[:space:]]stage|not.*too[[:space:]]big ]]; then
        reason_class=product-decision
        action=needs-info
      else
        reason_class=unresolved-recut
        action=needs-info
      fi
    elif [ -n "$(jq -r '.recut_refused_at // empty' <<< "$state")" ] && [ "$retry_failed_route" != 1 ]; then
      reason_class=unresolved-recut
      action=needs-info
    fi

    if [ "$retry_failed_route" = 1 ]; then
      if [ "$last_action" = needs-advisor ]; then
        reason_class=product-decision
        action=needs-info
      elif [ "$action" != needs-info ]; then
        return 0
    fi
  fi

  if [ "$action" = prerequisite ]; then
    prerequisite_marker="concluded-root-prerequisite-$n"
    prerequisite_index="$(gh issue list --repo "$REPO" --state all --limit 1000 \
      --search "in:title $prerequisite_marker" --json number,title,body,state,labels,stateReason)" \
      || { blocker_root_fail "prerequisite issue search failed for #$n"; return 1; }
    if ! jq -e 'type == "array" and all(.[]; (.number | type) == "number")' \
      <<< "$prerequisite_index" >/dev/null; then
      echo "reconcile_blocking_issue_root: invalid prerequisite search result for #$n" >&2
      blocker_root_fail "invalid prerequisite search result for #$n"
      return 1
    fi
    prerequisite_number="$(jq -r --arg marker "$prerequisite_marker" \
      '[.[] | select((.title // "") | contains($marker))] | first.number // empty' \
      <<< "$prerequisite_index")"
    prerequisite_state="$(jq -r --argjson number "${prerequisite_number:-0}" \
      '[.[] | select(.number == $number)][0].state // empty | ascii_downcase' \
      <<< "$prerequisite_index")"
    prerequisite_record="$(jq -c --argjson number "${prerequisite_number:-0}" \
      '[.[] | select(.number == $number)][0] // {}' <<< "$prerequisite_index")"
    prerequisite_disqualified="$(jq -r \
      'any(.labels[]?; .name == "duplicate" or .name == "concluded")' \
      <<< "$prerequisite_record")"
    prerequisite_state_reason="$(jq -r '.stateReason // empty' <<< "$prerequisite_record")"
    if [ "$prerequisite_state" = closed ] \
      && { [ "$prerequisite_disqualified" = true ] || [ "$prerequisite_state_reason" = NOT_PLANNED ]; }; then
      reason_class=unresolved-recut
      action=needs-info
    elif [ "$prerequisite_state" = closed ] && [ -n "$prerequisite_number" ]; then
      prerequisite_reason_file="$(jq_arg_file "$recut_reason")" \
        || { blocker_root_fail "prerequisite repeat-check temp file failed for #$n"; return 1; }
      if jq -e --argjson prerequisite "$prerequisite_number" --rawfile reason "$prerequisite_reason_file" '
          .concluded_blocker_recovery.prerequisite_issue == $prerequisite
          and .concluded_blocker_recovery.attempts_reset.reason_class == "missing-prerequisite"
          and .concluded_blocker_recovery.attempts_reset.reason == $reason
          and (.concluded_blocker_recovery.attempts_reset.action == "ready-for-agent"
            or .concluded_blocker_recovery.attempts_reset.action == "prerequisite")
        ' <<< "$state" >/dev/null; then
        reason_class=unresolved-recut
        action=needs-info
      else
        prerequisite_repeat_status=$?
        if [ "$prerequisite_repeat_status" -ne 1 ]; then
          rm -f -- "$prerequisite_reason_file"
          blocker_root_fail "prerequisite repeat-check jq failed (status $prerequisite_repeat_status) for #$n"
          return 1
        fi
      fi
      rm -f -- "$prerequisite_reason_file"
    fi
  fi

  case "$action" in
      ready-for-agent)
        state_requeue "$n" "" conclusion-requeue \
          || { blocker_root_fail "conclusion requeue failed for #$n"; return 1; }
        ;;
      needs-recut)
        route_to_recut "$n" "$issue_json" \
          || { blocker_root_fail "recut route failed for #$n"; return 1; }
        ;;
      prerequisite)
        if [ -z "$prerequisite_number" ]; then
          # A stable issue title makes create retry-safe if linking or state
          # persistence failed after GitHub accepted the first create.
          issue_title="$(jq -r '.title // ("issue #" + (.number|tostring))' <<< "$issue_json")"
          prerequisite_title="前置能力 [$prerequisite_marker]: $issue_title"
          prerequisite_body="## 背景

父票：#$n

拆分记录显示，父票进入 guarded implement 前缺少以下能力：

$recut_reason

## 验收条件

- 在父票要求的真实路径中实现上述缺失能力，不以模拟入口代替生产调用方。
- 加入最小正向与拒绝/持久化回读测试，覆盖父票已有的租户、身份、撤权和幂等边界。
- 父票解除本依赖后可直接消费此能力；不把未实现部分写成已完成。"
          prerequisite_body_file="$(jq_arg_file "$prerequisite_body")" \
            || { blocker_root_fail "prerequisite body temp file failed for #$n"; return 1; }
          if [ "${DRY_RUN:-0}" = 1 ]; then
            guarded_write gh issue create --repo "$REPO" --title "$prerequisite_title" \
              --body-file "$prerequisite_body_file" --label enhancement --label needs-triage --parent "$n" || {
                rm -f -- "$prerequisite_body_file"
                blocker_root_fail "prerequisite issue create failed for #$n (dry-run)"
                return 1
              }
            rm -f -- "$prerequisite_body_file"
            echo "issue-pipeline: blocker-root issue=#$n class=missing-prerequisite action=prerequisite (dry-run)" >&2
            return 0
          fi
          if [ "$(roadmap_switch_value)" = true ]; then
            prerequisite_url="$(guarded_write gh issue create --repo "$REPO" --title "$prerequisite_title" \
              --body-file "$prerequisite_body_file" --label enhancement)" || prerequisite_url=""
          else
            prerequisite_url="$(guarded_write gh issue create --repo "$REPO" --title "$prerequisite_title" \
              --body-file "$prerequisite_body_file" --label enhancement --label needs-triage --parent "$n")" || prerequisite_url=""
          fi
          if [ -z "$prerequisite_url" ]; then
            rm -f -- "$prerequisite_body_file"
            blocker_root_fail "prerequisite issue create failed for #$n"
            return 1
          fi
          rm -f -- "$prerequisite_body_file"
          prerequisite_number="${prerequisite_url##*/}"
          [[ "$prerequisite_number" =~ ^[0-9]+$ ]] || {
            echo "reconcile_blocking_issue_root: prerequisite issue create returned no issue number for #$n" >&2
            blocker_root_fail "prerequisite issue create returned no issue number for #$n (got '${prerequisite_number:-empty}')"
            return 1
          }
          if [ "$(roadmap_switch_value)" = true ]; then
            prerequisite_json="$(jq -cn --argjson number "$prerequisite_number" --arg title "$prerequisite_title" \
              --arg body "$prerequisite_body" '{number:$number,title:$title,body:$body,state:"OPEN",labels:[{name:"enhancement"}]}')" \
              || { blocker_root_fail "prerequisite roadmap intake JSON failed for #$n"; return 1; }
            issue_transition "$prerequisite_number" needs-triage prerequisite-created . 0 "$prerequisite_json" "$n" \
              || { blocker_root_fail "prerequisite roadmap placement or triage label failed for #$n"; return 1; }
          fi
          prerequisite_state=open
        fi
        if [ "$prerequisite_state" = closed ]; then
          action=ready-for-agent
          state_requeue "$n" "" conclusion-requeue \
            ".concluded_blocker_recovery.prerequisite_issue = $prerequisite_number" \
            || { blocker_root_fail "prerequisite-closed requeue failed for #$n"; return 1; }
        else
          guarded_write gh issue edit "$n" --repo "$REPO" --add-blocked-by "$prerequisite_number" \
            || { blocker_root_fail "prerequisite blocking-edge write failed for #$n -> #$prerequisite_number"; return 1; }
          issue_transition "$n" ready-for-agent conclusion-requeue \
            ".concluded_blocker_recovery.prerequisite_issue = $prerequisite_number" \
            || { blocker_root_fail "prerequisite requeue transition failed for #$n"; return 1; }
        fi
        ;;
      needs-info)
        if [ -n "$recut_reason" ]; then
          question="拆分未能继续：$recut_reason。请明确可接受的产品范围或权限阶段；流水线会按回复继续。"
        elif [ -n "$(jq -r '.recut_refused_at // empty' <<< "$state")" ]; then
          question="拆分拒绝原因无法从记录中恢复。请说明可接受的产品范围或所需前置能力；流水线会按回复继续。"
        else
          question="这项任务的产品预期还需要补充。请回复预期的用户操作、系统应产生的结果，以及没有更多细节时可接受的默认行为；流水线会收到回复后继续。"
        fi
        thread_id="$(jq -r 'if .needs_info_origin == "concluded-blocker-recovery" then .needs_info_thread_id // empty else empty end' <<< "$state")"
        if [ -z "$thread_id" ] && [ "$delivery_failed_episode" != "$episode" ]; then
          thread_id="$(notify_reporter_question "$n" "[example] #$n 需要确认产品预期" "$question")" || true
        fi
        if [ -n "$thread_id" ]; then
          thread_json="$(jq -cn --arg thread "$thread_id" '$thread')"
          issue_transition "$n" needs-info blocker-recovery-needs-info \
            ".needs_info_origin = \"concluded-blocker-recovery\" | .needs_info_thread_id = $thread_json | del(.concluded_blocker_recovery.question_delivery_failed_episode)" \
            || { blocker_root_fail "needs-info transition failed for #$n"; return 1; }
          guarded_issue_comment "$n" "$BOT_DISCLAIMER
$question" || { blocker_root_fail "needs-info comment failed for #$n"; return 1; }
          action=needs-info
        else
          # A rejected or otherwise undelivered question cannot leave a ticket
          # waiting for a reply nobody received. Send it to the advisor batch.
          if [ "$delivery_failed_episode" != "$episode" ]; then
            state_merge "$n" ".concluded_blocker_recovery.question_delivery_failed_episode = $(jq -cn --arg episode "$episode" '$episode')" \
              || { blocker_root_fail "question-delivery-failed episode write failed for #$n"; return 1; }
          fi
          if jq -e 'any(.labels[]?; .name == "needs-advisor")' <<< "$issue_json" >/dev/null; then
            issue_transition "$n" needs-advisor blocker-recovery-advisor \
              || { blocker_root_fail "advisor transition failed for #$n"; return 1; }
          else
            # This is a new conclusion episode with its own budget; the
            # advisor admission must not see the spent implement attempts and
            # refuse (issue 1943 stopped every root sweep for 15h, 2026-10-03).
            state_merge_attempt_transition "$n" '.attempts = 0' \
              || { blocker_root_fail "advisor admission reset failed for #$n"; return 1; }
            route_to_advisor "$n" concluded true "$issue_json" \
              || { blocker_root_fail "advisor route failed for #$n"; return 1; }
          fi
          action=needs-advisor
        fi
        ;;
    esac
    if [ "$conclusion_class" = ticket ]; then
      case "$action" in
        ready-for-agent)
          conclusion_route=requeue
          conclusion_owner=implement
          [ "$pipeline_system_status" != 0 ] || conclusion_owner=issue-pipeline
          ;;
        needs-recut) conclusion_route=recut; conclusion_owner=recut ;;
        prerequisite) conclusion_route=requeue; conclusion_owner=issue-pipeline ;;
        needs-info) conclusion_route=needs-info; conclusion_owner=reporter ;;
        needs-advisor) conclusion_route=needs-info; conclusion_owner=advisor ;;
      esac
      state_merge "$n" ".run.conclusion.route = $(jq -cn --arg route "$conclusion_route" '$route') | .run.conclusion.owner = $(jq -cn --arg owner "$conclusion_owner" '$owner')" \
        || { blocker_root_fail "conclusion route write failed for #$n"; return 1; }
    fi
    attempts_before_reset="$(jq -r '.attempts // 0 | if type == "number" then . else 0 end' <<< "$state")"
    reset_reason="${recut_reason:-$reason}"
    reset_reason_file="$(jq_arg_file "$reset_reason")" \
      || { blocker_root_fail "attempt-reset reason temp file failed for #$n"; return 1; }
    if ! reset_record="$(jq -cn --argjson from "$attempts_before_reset" --arg reason_class "$reason_class" \
      --arg action "$action" --rawfile reason "$reset_reason_file" --arg episode "$episode" \
      '{from:$from,to:0,reason_class:$reason_class,action:$action,reason:$reason,episode:$episode,at:(now|todate)}')"; then
      rm -f -- "$reset_reason_file"
      blocker_root_fail "attempt-reset record build failed for #$n"
      return 1
    fi
    rm -f -- "$reset_reason_file"
    if [ "$retry_failed_route" = 1 ]; then
      state_merge_attempt_transition "$n" ".attempts = 0 | .concluded_blocker_recovery.attempts_reset = $reset_record | .concluded_blocker_recovery.last_action = $(jq -cn --arg action "$action" '$action')" \
        || { blocker_root_fail "attempt-reset write failed for #$n (retry route)"; return 1; }
    else
      state_merge_attempt_transition "$n" ".attempts = 0 | .concluded_blocker_recovery.attempts_reset = $reset_record | .concluded_blocker_recovery.auto_exits = (if (.concluded_blocker_recovery.last_episode // \"\") == $(jq -cn --arg episode "$episode" '$episode') then (.concluded_blocker_recovery.auto_exits // 0) else ((.concluded_blocker_recovery.auto_exits // 0) + 1) end) | .concluded_blocker_recovery.last_episode = $(jq -cn --arg episode "$episode" '$episode') | .concluded_blocker_recovery.last_action = $(jq -cn --arg action "$action" '$action')" \
        || { blocker_root_fail "attempt-reset write failed for #$n"; return 1; }
    fi
    echo "issue-pipeline: blocker-root issue=#$n class=$reason_class action=$action blockers=$(jq -r 'map(tostring)|join(",")' <<< "$dependents_json")" >&2
    BLOCKING_ROOT_GRAPH_CHANGED=1
    return 0
  fi

  return 0
}

# Return top terminal blockers and number of ready tickets held by each.
issue_blocker_root_summary() {
  local open_issues_json="$1" label="${2:-ready-for-agent}"
  jq -r --arg lane_label "$label" '
    def roots($graph; $issue; $seen):
      if ($seen | index($issue)) != null then [$issue]
      elif $graph[$issue] == null then [$issue]
      else
        [$graph[$issue].blockedBy.nodes[]? | select((.state | ascii_downcase) == "open") | (.number | tostring)] as $parents
        | if ($parents | length) == 0 then [$issue]
          else [$parents[] as $parent | roots($graph; $parent; $seen + [$issue])[]] | unique
          end
      end;
    . as $issues
    | ($issues | map({key:(.number | tostring),value:.}) | from_entries) as $graph
    | [$issues[] as $ticket
       | select(any($ticket.labels[]?; .name == $lane_label))
       | select(any($ticket.blockedBy.nodes[]?; (.state | ascii_downcase) == "open"))
       | roots($graph; ($ticket.number | tostring); [])[] as $root
       | {root:$root,ticket:$ticket.number}]
    | group_by(.root)
    | map({root:.[0].root,title:($graph[.[0].root].title // ""),count:length})
    | sort_by([-.count, (.root | tonumber)])[:5]
    | map("#\(.root)\(if .title == "" then "" else " \(.title | gsub("[\\t\\r\\n]"; " "))" end):\(.count)") | join(",")
  ' <<< "$open_issues_json"
}

# Refresh only after a mutation: recut-parent edges may expose a concluded
# child that was not a blocker when the first snapshot was taken.
# The sweep is recovery, not latency-critical: at ~1.5s per root it took 300-530s per tick from
# 2026-10-04 12:35Z and starved implement for 8 hours. It stops at its budget and resumes after the last
# root it reconciled on the next tick, so every root is still visited.
BLOCKER_ROOT_SWEEP_BUDGET_SECONDS="${BLOCKER_ROOT_SWEEP_BUDGET_SECONDS:-150}"
sweep_blocking_issue_roots() {
  local pass graph_json issue_json n state_file_path has_open_dependents sweep_failed=0
  local snapshot_only="${1:-}"
  local cursor_file="$AGENT_HOME/blocker-root-sweep.cursor" cursor=0 last_done=""
  local roots_done=0 roots_total=0
  local sweep_deadline=$((SECONDS + BLOCKER_ROOT_SWEEP_BUDGET_SECONDS))
  OPEN_ISSUE_BLOCKER_GRAPH_JSON='[]'
  OPEN_ISSUE_BLOCKER_GRAPH_STATUS=unknown
  cursor="$(cat "$cursor_file" 2>/dev/null || true)"
  [[ "$cursor" =~ ^[0-9]+$ ]] || cursor=0
  for pass in 1 2; do
    if ! graph_json="$(gh issue list --repo "$REPO" --state open --limit 1000 \
      --json number,title,state,labels,author,blockedBy,blocking)"; then
      echo "sweep_blocking_issue_roots: open issue dependency graph unreadable" >&2
      return 1
    fi
    if ! jq -e 'type == "array" and all(.[]; type == "object" and (.number | type) == "number")' \
      <<< "$graph_json" >/dev/null; then
      echo "sweep_blocking_issue_roots: open issue dependency graph malformed" >&2
      return 1
    fi
    OPEN_ISSUE_BLOCKER_GRAPH_JSON="$graph_json"
    OPEN_ISSUE_BLOCKER_GRAPH_STATUS=available
    [ "$snapshot_only" != "--snapshot-only" ] || return 0
    roots_total="$(jq '[.[] | select((.state | ascii_downcase) == "open")] | length' <<< "$graph_json")"
    roots_done=0
    BLOCKING_ROOT_GRAPH_CHANGED=0
    while IFS= read -r issue_json; do
      [ -n "$issue_json" ] || continue
      if [ "$SECONDS" -ge "$sweep_deadline" ]; then
        [ -z "$last_done" ] || printf '%s\n' "$last_done" > "$cursor_file"
        echo "sweep_blocking_issue_roots: budget ${BLOCKER_ROOT_SWEEP_BUDGET_SECONDS}s spent; resuming after #${last_done:-$cursor} next tick" >&2
        return "$sweep_failed"
      fi
      n="$(jq -r '.number' <<< "$issue_json")"
      has_open_dependents=0
      jq -e 'any(.blocking.nodes[]?; (.state | ascii_downcase) == "open")' <<< "$issue_json" >/dev/null && has_open_dependents=1
      if [ "$has_open_dependents" = 0 ]; then
        state_file_path="$(state_file "$n")"
        if { [ ! -r "$state_file_path" ] || ! jq -e '
          ((.recut_children | type) == "array" and (.recut_children | length) > 0)
          or .native_subissue_parent == true
        ' "$state_file_path" >/dev/null 2>&1; } \
          && ! jq -e 'any(.labels[]?; .name == "concluded" or .name == "on-hold")' <<< "$issue_json" >/dev/null; then
          last_done="$n"
          roots_done=$((roots_done + 1))
          continue
        fi
      fi
      if ! gh_tick_attempt_timeout_sec >/dev/null; then
        printf '%s\n' "${last_done:-$cursor}" > "$cursor_file"
        echo "blocker-root sweep: tick gh deadline exhausted after ${roots_done}/${roots_total} roots; resuming at #${n} next tick" >&2
        return "$sweep_failed"
      fi
      # One root that fails must not starve every root after it.
      if ! reconcile_blocking_issue_root "$issue_json" "$graph_json"; then
        sweep_failed=1
        supervisor_inbox_append_once "blocker-root-failed issue=#$n" \
          "blocker-root-failed issue=#$n reason=${BLOCKER_ROOT_FAIL_REASON:-reconcile_blocking_issue_root exited non-zero without recording a reason}; the sweep continued with the remaining roots" || true
      fi
      last_done="$n"
      roots_done=$((roots_done + 1))
    done < <(jq -c --argjson cursor "$cursor" '[.[] | select((.state | ascii_downcase) == "open")] | sort_by(.number)
      | (map(select(.number > $cursor)) + map(select(.number <= $cursor)))[]' <<< "$graph_json")
    rm -f "$cursor_file"
    cursor=0
    [ "$BLOCKING_ROOT_GRAPH_CHANGED" = 1 ] || break
  done
  return "$sweep_failed"
}

# Gate 4's predicate (run-implement.sh): is $2 (one changed path) inside the
# JSON array $1 of expected-package prefixes — exact match, or "$item/..."?
# 2026-09-12 bug this replaced: `any(.[]; $p == . or ($p | startswith(. +
# "/")))` looked right but the `$p |` pipe inside the condition rebinds `.`
# to $p for everything downstream, so `startswith(. + "/")` silently became
# `startswith($p + "/")` — always false. Binding the array element to its
# own variable ($item) before ever piping $p avoids the shadowing. See
# lib.test.sh for the regression test (a file under a declared package
# passes; a file outside it fails).
# 2026-09-14 (#1178/PR #1186): triage pinned expected_packages down to
# sub-package paths ("packages/example-pack/src",
# "packages/example-pack/tests") for an issue that legitimately also
# needed a third path in the SAME package
# (.../example-pack/runtime/hooks/) — this
# gate correctly rejected it as "outside expected_packages", parking a
# green, on-scope PR (#1186) on a human. lessons/RULES.md V77: a file set
# handed to an implementer up front is a CONCLUSION of finding the right
# seam, not a constraint issued before anyone has looked at the code —
# triage writes expected_packages before an implementer has chosen which
# files inside a package to touch, so it can only ever know the package,
# not the eventual sub-paths.
#
# Fixed by widening $expected_json to package granularity right here,
# inside the shared predicate, rather than at the one call site
# (run-triage.sh) that writes expected_packages, and rather than telling
# the model in prompts/triage.md to only ever write package-level paths.
# Two reasons this seam, not those:
# 1. The merge gate continues to funnel through this one function. Scheduler
#    collision reads now first choose optional exact expected_paths, but their
#    legacy fallback still calls this normalizer, so old/unknown state keeps
#    this same package-wide protection.
# 2. It is retroactive. #1178 was triaged and its narrow expected_packages
#    already persisted to its state file *before* this fix existed; a
#    write-time fix in run-triage.sh only protects tickets triaged after it
#    ships and does nothing for #1178 itself — it would still need a full
#    re-triage, not just the existing resume path (eef6058b3) picking the
#    already-open, already-green PR #1186 back up. Normalizing on read
#    means the very next gate check (this one) already sees it correctly,
#    with no re-triage and no state-file surgery.
# Prompt-only compliance was rejected outright, independent of the above:
# this codebase's own measured rate for it is under 2%
# (a standing project ruling on this exact pattern
# enforce rules with hooks, not prose).
#
# This repo's package boundary is `packages/<name>` — pnpm-workspace.yaml
# only globs `packages/*`, no other top-level directory is package-shaped —
# so any expected_json entry nested under one is widened to it; a bare
# `packages/<name>` or a path outside `packages/` entirely (e.g.
# `docs/agents`) passes through unchanged. `$path` (the second argument,
# never widened) needs no such treatment: widening only the `expected_json`
# side is sufficient, because a longer `$path` is already captured by the
# `startswith($item + "/")` check once $item is the package root.
#
# Widening also makes expected_packages_collide()'s concurrent-PR collision
# check catch MORE overlap, not less — it was already comparing prefixes
# through this same function, so a coarser prefix only ever matches a
# superset of what a narrower one matched. Two tickets both scoped to the
# same package now serialize via finish-first even if their real diffs
# would never have touched the same file, which is the conservative
# direction to be wrong in, not the dangerous one. A path outside every
# (now package-level) expected package still fails this gate exactly as
# before — this narrows what counts as "outside", it does not remove the
# gate.
# 2026-09-15 (#1215): an advisor-written entry of "templates/levels/" (a
# trailing slash, not a packages/-rooted path so the widening step above
# never touches it) made path_in_expected_packages's own
# startswith($item + "/") check require "templates/levels//" -- a path that
# cannot occur -- so a diff that was genuinely inside the declared scope
# read as outside it. The gate's own rejection message printed the exact
# entry that should have matched ("outside expected_packages
# [\"packages/example-service\",\"templates/levels/\"]"), and nobody read it
# for hours: it correctly re-routed #1215 to a second advisor episode (which
# then hit an unrelated deadlock, since fixed, and froze), stranded its
# already-green PR #1240 open, and open_pr_file_collision() -- same shared
# normalization, comparing at package granularity for legacy state -- then
# blocked #1144 and #1177 from ever being offered as candidates while #1240
# sat there.
#
# Fixed by stripping trailing slash(es) before the existing packages/
# widening runs, in this one shared function every consumer above already
# funnels through for its merge-gate and legacy scheduling fallback -- not in
# the jq
# expression at path_in_expected_packages's call site, and not by asking
# run-triage.sh/advisor.md to never emit a trailing slash, for the same
# "single seam, retroactive, prompt compliance measures <2%" reasons
# already argued above for the packages/ widening.
#
# select(length > 0) after stripping also drops an entry that was only
# slashes (e.g. "/"), so it can't survive as an inert empty-string
# comparison. Everything else considered and deliberately NOT handled,
# because advisor.schema.json's expected_packages_addendum and
# triage.schema.json's expected_packages are free-text arrays but every
# real producer (triage.md's own worked examples, #1215's actual payload)
# only ever writes bare "packages/<name>" or "<dir>/<subdir>" forms:
# - A leading "./" or leading "/" — no prompt example or observed payload
#   has ever emitted one; nothing here would generate it. Adding a strip
#   for it would be a defense against an input that cannot occur, not a
#   fix for one that did.
# - A duplicate entry after normalization — already handled by the
#   trailing `| unique` below, which runs after the slash-strip, so
#   ["templates/levels","templates/levels/"] still collapses to one entry
#   exactly like the pre-existing packages/ widening case does.
# `$path` (the second argument to path_in_expected_packages) still needs no
# equivalent treatment, same as the widening comment above already argues:
# a real diff path from `git diff --name-only` / `gh pr view --json files`
# never carries a trailing slash.
normalize_expected_packages() {
  echo "$1" | jq -c '
    map(sub("/+$"; "") | select(length > 0))
    | [.[] | if test("^packages/[^/]+/") then (split("/")[0:2] | join("/")) else . end]
    | unique
  '
}

# Collision scheduling may use triage's optional exact paths, but merge gate
# 4 remains deliberately package-wide. Unknown/legacy state has no exact
# paths, so it takes the existing normalized package scope rather than gaining
# unprotected concurrency.
selection_scope_json() {
  local state_json
  state_json="$(cat)"
  if echo "$state_json" | jq -e '(.expected_paths? | type) == "array" and (.expected_paths | length) > 0' >/dev/null 2>&1; then
    echo "$state_json" | jq -c '.expected_paths'
  else
    normalize_expected_packages "$(echo "$state_json" | jq -c '.expected_packages // []')"
  fi
}

# declared_write_surface_missing <paths-json> <repo-root> -- true only when
# every explicitly declared path is absent from the checkout.
declared_write_surface_missing() {
  local paths_json="$1" repo_root="${2:-${REPO_DIR:-}}" path
  MISSING_WRITE_SURFACE_PATHS=""
  if ! jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and length > 0)' <<< "$paths_json" >/dev/null 2>&1; then
    MISSING_WRITE_SURFACE_PATHS="声明范围无法解析"
    return 0
  fi
  if [ -z "$repo_root" ] || [ ! -d "$repo_root" ]; then
    MISSING_WRITE_SURFACE_PATHS="仓库范围无法读取"
    return 0
  fi
  while IFS= read -r path; do
    case "$path" in
      /*|..|../*|*/../*|*/..)
        MISSING_WRITE_SURFACE_PATHS="声明范围无法安全检查"
        return 0
        ;;
    esac
    if [ -e "$repo_root/$path" ]; then
      return 1
    fi
    MISSING_WRITE_SURFACE_PATHS="${MISSING_WRITE_SURFACE_PATHS:+$MISSING_WRITE_SURFACE_PATHS, }$path"
  done < <(jq -r '.[]' <<< "$paths_json")
  return 0
}

issue_body_file_paths_json() {
  local include_key_files="${2:-false}"
  local paths
  paths="$(printf '%s\n' "${1:-}" | awk -v include_key_files="$include_key_files" '
    {
      lower = tolower($0)
      key_heading = lower ~ /^[[:space:]]*#{1,6}[[:space:]]*key files( and symbols)?[[:space:]]*$/
      scope_heading = lower ~ /^[[:space:]]*#{1,6}[[:space:]]*(fix|target|affected|implementation)[ -]*(paths|files)[[:space:]]*$/
      if ((include_key_files == "true" && key_heading) || scope_heading) { active = 1; next }
      if (lower ~ /^[[:space:]]*#{1,6}[[:space:]]/) { active = 0; next }
      key_label = lower ~ /^[[:space:]]*key files( and symbols)?[[:space:]]*:/
      scope_label = lower ~ /^[[:space:]]*(fix|target|affected|implementation)[ -]*(paths|files)[[:space:]]*:/
      if ((include_key_files == "true" && key_label) || scope_label) { active = 1; sub(/^[^:]*:[[:space:]]*/, ""); print; next }
      if (active && lower ~ /^[[:space:]]*[[:alpha:]][[:alnum:] _-]*:[[:space:]]*$/) { active = 0; next }
      if (active) print
    }
  ' | grep -Eo '(\.github/workflows|\.agents|\.claude|lessons|packages|apps|scripts|engine|docs|infra|deploy|templates|migrations)/[[:alnum:]_.-]+(/[[:alnum:]_.-]+)*|Dockerfile([.][[:alnum:]_-]+)?|package\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml|package-lock\.json' | LC_ALL=C sort -u || true)"
  printf '%s\n' "$paths" | jq -Rsc 'split("\n") | map(select(length > 0))'
}

# issue_change_surface_json <state-json> <body> <labels-json> -> scoped paths.
# Triage paths/packages stay authoritative; key files and package labels fill
# gaps without widening ordinary collision scheduling.
issue_change_surface_json() {
  local state="$1" body="$2" labels="$3" body_paths expected_paths expected_packages label_paths
  if ! jq -e 'type == "object" and ((.expected_paths // []) | type == "array") and ((.expected_packages // []) | type == "array")' <<< "$state" >/dev/null 2>&1 \
    || ! jq -e 'type == "array"' <<< "$labels" >/dev/null 2>&1; then
    echo '[]'
    return 0
  fi
  body_paths="$(issue_body_file_paths_json "$body" true)" || { echo '[]'; return 0; }
  expected_paths="$(jq -c '.expected_paths // []' <<< "$state")"
  expected_packages="$(normalize_expected_packages "$(jq -c '.expected_packages // []' <<< "$state")")" || { echo '[]'; return 0; }
  label_paths="$(jq -c '
    [ .[]? | (.name // .) | select(type == "string")
      | try capture("^(package|pkg):(?<path>[A-Za-z0-9._/-]+)$").path catch empty
      | if startswith("packages/") or startswith("apps/") then . else "packages/" + . end
    ] | unique
  ' <<< "$labels")" || { echo '[]'; return 0; }
  jq -cn --argjson p "$expected_paths" --argjson e "$expected_packages" \
    --argjson b "$body_paths" --argjson l "$label_paths" '($p + $e + $b + $l) | unique'
}

issue_body_mentions_product_scope() {
  local text="${1:-}"
  grep -Eiq '(^|[^[:alnum:]_])(packages|apps)/' <<< "$text" && return 0
  grep -Eiq '(^|[^[:alnum:]_./-])[[:alnum:]_.-]+\.(ts|tsx|sql|mjs)([^[:alnum:]_.-]|$)' <<< "$text"
}

issue_is_parent_tracker() {
  jq -e '
    type == "object" and (
      ((.subIssuesSummary.total // .subIssues.totalCount // ((.subIssues.nodes // []) | length) // 0)
        > (.subIssuesSummary.completed // 0))
      or any(.blockedBy.nodes[]?; ((.state // "") | ascii_downcase) == "open")
    )
  ' <<< "${1:-}" >/dev/null 2>&1
}

issue_intake_parent_reason() { # issue number, fetched issue JSON -> reason; 1=leaf, 2=parent lookup unavailable
  local n="$1" json="$2" title body child state sub_issues
  title="$(jq -r '.title // ""' <<< "$json")"
  body="$(jq -r '.body // ""' <<< "$json")"
  if grep -Eiq '(^|[^[:alnum:]_-])(spec|specification)([^[:alnum:]_-]|$)' <<< "$title" \
      || grep -Eiq '^[[:space:]]*(#{1,6}[[:space:]]*)?(spec|specification)([[:space:]:#_-]|$)' <<< "$body" \
      || grep -Eiq '(^|[^[:alnum:]_])(this issue|this ticket)[[:space:]]+is[[:space:]]+(a[[:space:]]+)?(spec|specification)([^[:alnum:]_-]|$)' <<< "$body" \
      || { grep -Eiq 'ADR[[:space:]_-]*[0-9]+' <<< "$title" \
        && grep -Eiq 'pilot|试点' <<< "$title"; } \
      || grep -Eiq '^[[:space:]]*(#{1,6}[[:space:]]*)?ADR[[:space:]_-]*[0-9]+[[:space:]]+(pilot|试点)([[:space:][:punct:]]|$)' <<< "$body"; then
    printf 'spec/ADR pilot\n'
    return 0
  fi

  while IFS= read -r child; do
    [[ "$child" =~ ^[1-9][0-9]*$ && "$child" != "$n" ]] || continue
    state="$(gh issue view "$child" --json state --jq .state 2>/dev/null)" || return 2
    case "$state" in
      OPEN|open) printf 'task list references open child #%s\n' "$child"; return 0 ;;
      CLOSED|closed) ;;
      *) return 2 ;;
    esac
  done < <(printf '%s\n' "$body" \
    | awk '/^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+\[[ xX]\][[:space:]]/ { print }' \
    | { grep -Eo '(#[1-9][0-9]*|/issues/[1-9][0-9]*)' || [[ $? == 1 ]]; } \
    | sed -E 's#^.*/issues/##; s/^#//' | sort -u)

  if jq -e '((.subIssuesSummary.total // 0) > 0) or ((.subIssues.totalCount // 0) > 0) or (((.subIssues.nodes // []) | length) > 0)' \
      <<< "$json" >/dev/null; then
    printf 'has GitHub sub-issues\n'
    return 0
  fi
  if jq -e 'has("subIssuesSummary") or has("subIssues")' <<< "$json" >/dev/null; then
    return 1
  fi
  if ! sub_issues="$(gh api "repos/$REPO/issues/$n/sub_issues?per_page=100" 2>/dev/null)" \
      || ! jq -e 'type == "array"' <<< "$sub_issues" >/dev/null; then
    return 2
  fi
  if jq -e 'length > 0' <<< "$sub_issues" >/dev/null; then
    printf 'has GitHub sub-issues\n'
    return 0
  fi
  return 1
}

issue_body_is_direct_main_lane() {
  local text="${1:-}" paths
  if issue_body_mentions_product_scope "$text"; then return 1; fi
  paths="$(issue_body_file_paths_json "$text")" || return 1
  jq -e 'type == "array" and length > 0' <<< "$paths" >/dev/null 2>&1 || return 1
  [ "$(node "$REPO_DIR/scripts/branch-delivery-policy.mjs" --classify-path-set "$paths" 2>/dev/null)" = eligible ]
}

selection_scope_roots_json() {
  jq -c '[.[]? | split("/") as $parts | if ($parts | length) > 2 then ($parts[0:2] | join("/")) else ($parts | join("/")) end] | unique' <<< "$1"
}

package_scope_add_root() {
  local issue="$1" root="$2" current
  [ -n "$root" ] || return 0
  current=" ${PACKAGE_SCOPE_ISSUES[$root]:-} "
  [[ "$current" == *" $issue "* ]] && return 0
  PACKAGE_SCOPE_ISSUES[$root]="${PACKAGE_SCOPE_ISSUES[$root]:-}${PACKAGE_SCOPE_ISSUES[$root]:+ }$issue"
  PACKAGE_SCOPE_COUNT[$root]=$(( ${PACKAGE_SCOPE_COUNT[$root]:-0} + 1 ))
}

package_scope_add_issue() {
  local issue="$1" scope_json="$2" root
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    package_scope_add_root "$issue" "$root"
  done < <(selection_scope_roots_json "$scope_json" | jq -r '.[]')
}

package_scope_is_full() {
  local issue="$1" scope_json="$2" cap="$3" root count current
  PACKAGE_SCOPE_BLOCKING_ROOT=""
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    count=${PACKAGE_SCOPE_COUNT[$root]:-0}
    current=" ${PACKAGE_SCOPE_ISSUES[$root]:-} "
    [[ "$current" == *" $issue "* ]] && count=$((count - 1))
    if [ "$count" -ge "$cap" ]; then
      PACKAGE_SCOPE_BLOCKING_ROOT="$root"
      return 0
    fi
  done < <(selection_scope_roots_json "$scope_json" | jq -r '.[]')
  return 1
}

# Exact prefix predicate for the scheduler's already-selected scope. Unlike
# path_in_expected_packages(), this intentionally does not widen a supplied
# expected_paths entry to its package; that widening remains merge gate 4.
path_in_selection_scope() {
  local scope_json="$1" path="$2"
  echo "$scope_json" | jq -e --arg p "$path" \
    '[.[]? | . as $item | ($p == $item or ($p | startswith($item + "/")))] | any' > /dev/null
}

selection_scope_has_exact_path() {
  echo "$1" | jq -e --arg p "$2" 'any(.[]?; . == $p)' >/dev/null
}

shared_collision_path() {
  case "$1" in
    package.json|*/package.json|pnpm-lock.yaml|*/pnpm-lock.yaml|package-lock.json|*/package-lock.json|yarn.lock|*/yarn.lock|*/src/index.ts|*/src/index.tsx|*/src/index.js|*/src/index.mjs|packages/*/index.ts|packages/*/index.tsx|packages/*/index.js|packages/*/index.mjs) return 0 ;;
    *) return 1 ;;
  esac
}

path_in_expected_packages() {
  local expected_json path
  expected_json="$(normalize_expected_packages "$1")"
  path="$2"
  echo "$expected_json" | jq -e --arg p "$path" \
    '[.[] | . as $item | ($p == $item or ($p | startswith($item + "/")))] | any' > /dev/null
}

# 2026-09-12 issue #1098: the triage model returned risk_class=P2 together
# with state=ready-for-agent in the SAME response — directly contradicting
# prompts/triage.md's own rule that ready-for-agent requires P0/P1. run-
# triage.sh applied the label verbatim; the only thing that stopped an
# unauthorized implement dispatch was a human manually flipping the
# AGENT_PIPELINE repo variable back to `triage`. The autonomy set (which
# risk_class/level/phase combinations may ever reach ready-for-agent) is the
# maintainer's safety boundary, and enforcing it with prose inside a prompt
# measures under 2% compliance (a standing project ruling on
# this exact pattern: enforce rules with hooks, not prose) — so it is
# re-derived here in code from the same three fields the prompt's own rule
# is defined over, independent of whatever state the model claims.
#
# Only ever narrows: a $state that isn't already ready-for-agent is returned
# unchanged, because this gate exists to catch an over-admission, never to
# grant autonomy the model itself withheld. Unrecognized or empty risk_class/
# level fails closed (falls through to the `*` case below), the same
# fail-closed shape run-triage.sh already uses for a garbage/unset
# AGENT_PHASE. Phase 3's L2 admission still requires the GitNexus impact
# check described in prompts/triage.md step 5 — that check runs inside the
# model's own triage pass (it has no way to invoke gitnexus from here), so
# this function only re-checks the level/phase shape, not the impact result.
# Same fail-closed pattern run-triage.sh has always used for AGENT_PHASE:
# unset, unreadable, or any value other than 2/3 falls back to 2, the
# conservative default, never 3. Shared (2026-09-12 review, item 1) so
# run-triage.sh's per-run read and issue-pipeline.sh's dispatch-time gate
# recomputation (section (c), below) read this exactly the same way and can
# never drift onto two different fallback values.
read_agent_phase() {
  local phase
  phase="$(gh variable get AGENT_PHASE --repo "$REPO" 2>/dev/null || echo 2)"
  case "$phase" in
    2|3) echo "$phase" ;;
    *) echo 2 ;;
  esac
}

enforce_autonomy_gate() {
  local state="$1" risk_class="$2" level="$3" phase="$4"
  if [ "$state" != "ready-for-agent" ]; then
    echo "$state"
    return 0
  fi
  case "$risk_class" in
    P0|P1) ;;
    *) echo "ready-for-human"; return 0 ;;
  esac
  case "$level" in
    L0|L1) ;;
    L2) [ "$phase" = "3" ] || { echo "ready-for-human"; return 0; } ;;
    *) echo "ready-for-human"; return 0 ;;
  esac
  echo "ready-for-agent"
}

# 2026-09-13 issues #1130-#1137: a Mac-side /wayfinder -> to-spec -> to-tickets
# run stamps ready-for-agent on every ticket it creates, with no triage ever
# having run -- these issues have NO state file at all. issue-pipeline.sh's
# section (c) used to read risk_class/level straight off state_read()'s
# default ({"attempts":0}, both fields empty) and hand that to
# enforce_autonomy_gate(), which fails closed on empty fields exactly the
# same way it fails closed on a genuinely oversized P2/L3 issue -- both
# landed on ready-for-human plus an email telling the maintainer something was
# "outside the permitted range" and asking him to adjust permissions, which
# is not actionable for an issue nobody ever measured. "Not yet measured" and
# "measured and too big" are different situations and need different
# destinations; this function is what tells them apart.
#
# Deliberately three-way, not a boolean: "no state file" and "a state file
# that exists but was never classified" (an attempts-only file left by a
# failed prior triage or implement-dispatch attempt -- state_bump_attempts()
# only ever touches .attempts, never risk_class/level) are both genuinely
# UNmeasured and route the same way (see issue-pipeline.sh's call site). A
# state file that fails to parse as JSON at all is real corruption and is
# kept as its own "malformed" outcome on purpose, NOT folded into
# "unmeasured": routing corruption straight back into needs-triage risks (a)
# state_merge()'s own read-modify-write of the SAME file next time triage
# runs on it, under this script's `set -e -o pipefail`, and (b), if the
# corruption is a symptom of a real bug in whatever wrote it rather than a
# one-off, silently re-triaging the same broken file forever with no human
# ever told -- exactly the loop this whole gate exists to avoid. "Malformed"
# instead falls through to the existing gate unchanged: empty risk_class/
# level (the same defaults a missing key already produced before this fix)
# hit enforce_autonomy_gate's `*` branch, landing on ready-for-human -- an
# existing terminal state, not a new silent loop.
# A state file that DOES carry both keys is "measured" regardless of
# whether the values are admissible -- that judgment is enforce_autonomy_
# gate's job, not this function's; garbage values there already fail closed.
triage_unmeasured_issue_ids() {
  python3 -c '
import json, pathlib, sys
states = pathlib.Path(sys.argv[1])
for issue in sys.stdin.read().split():
    if not issue.isdecimal() or int(issue) <= 0:
        continue
    path = states / (issue + ".json")
    if not path.is_file():
        print(issue)
        continue
    try:
        state = json.loads(path.read_text())
    except (OSError, ValueError):
        continue  # Same malformed exclusion as triage_classification_status.
    if not isinstance(state, dict) or not ("risk_class" in state and "level" in state):
        print(issue)
' "$STATE_DIR" <<< "$1"
}

triage_classification_status() {
  local f="$1"
  [ -f "$f" ] || { echo unmeasured; return 0; }
  jq -e . "$f" >/dev/null 2>&1 || { echo malformed; return 0; }
  if jq -e 'has("risk_class") and has("level")' "$f" >/dev/null 2>&1; then
    echo measured
  else
    echo unmeasured
  fi
}

# Open blockers labeled awaiting-release or released are clear for implement;
# every other open blocker still blocks.
MERGED_BLOCKER_LABELS=(awaiting-release released)

merged_blocker_labels_json() {
  jq -cn --args '$ARGS.positional' "${MERGED_BLOCKER_LABELS[@]}"
}

has_merged_blocker_label_name() {
  local label_names_json="$1" merged_labels_json
  merged_labels_json="$(merged_blocker_labels_json)" || return 1
  jq -e --argjson merged_labels "$merged_labels_json" \
    'any(.[]; . as $label | $merged_labels | index($label) != null)' \
    <<< "$label_names_json" >/dev/null 2>&1
}

open_blocker_ids_from_rest_json() {
  local blockers_json="$1" merged_labels_json
  merged_labels_json="$(merged_blocker_labels_json)" || return 1
  jq -r --argjson merged_labels "$merged_labels_json" '
    [.[] | select(.state == "open")
     | select((any(.labels[]?.name; . as $label | $merged_labels | index($label) != null)) | not)
     | .number
    ] | join(", ")
  ' <<< "$blockers_json"
}

OPEN_BLOCKER_SNAPSHOT_ACTIVE=0
declare -gA OPEN_BLOCKER_SNAPSHOT_STATE=()
declare -gA OPEN_BLOCKER_SNAPSHOT_IDS=()

# The live REST fallback: one `gh api` call per issue when the batch snapshot
# is unavailable or incomplete. Fails CLOSED (returns
# 0/blocked) on ANY failure -- a missing/erroring dependencies endpoint (the
# feature could be unavailable, or a transient gh/network hiccup) must not
# silently wave through an issue whose real blocker state is unknown. This
# used to fail open on the reasoning that getting it wrong in the permissive
# direction "costs at most one burned implement attempt" -- that argument is
# rejected: issue #1163 carries 13 open blockers, and one transient API
# failure landing on top of one hand-applied `ready-for-agent` label was
# enough for this function to wave it straight through, starting an
# implement dispatch to build against contracts that thirteen prerequisite
# tickets have not delivered. That is not "one burned attempt," it is
# building on an undelivered foundation.
#
# Failing closed here is still safe for the caller: it leaves the issue
# ready-for-agent, records this gate and either blocker IDs or read failure in
# the existing tick ledger, then retries next tick. A permanent unreadable
# dependency state therefore becomes visible rather than turning into a
# permissive dispatch.
has_open_blocker() {
  local n="$1" blockers_json
  OPEN_BLOCKER_IDS=""
  OPEN_BLOCKER_QUERY_FAILED=0
  if [ "$OPEN_BLOCKER_SNAPSHOT_ACTIVE" = 1 ]; then
    case "${OPEN_BLOCKER_SNAPSHOT_STATE[$n]:-fallback}" in
      blocked)
        OPEN_BLOCKER_IDS="${OPEN_BLOCKER_SNAPSHOT_IDS[$n]:-}"
        return 0
        ;;
      clear) return 1 ;;
    esac
  fi
  if ! blockers_json="$(gh api "repos/$REPO/issues/$n/dependencies/blocked_by" 2>/dev/null)"; then
    OPEN_BLOCKER_QUERY_FAILED=1
    return 0
  fi
  OPEN_BLOCKER_IDS="$(open_blocker_ids_from_rest_json "$blockers_json" 2>/dev/null || true)"
  [ -n "$OPEN_BLOCKER_IDS" ]
}

prose_blocker_references() {
  sed -e 's#/#\n#g' -e 's#;#\n#g' -e 's#；#\n#g' -e 's#。#\n#g' \
    | grep -iE 'blocked[[:space:]-]+by|depends[[:space:]]+on|dependent[[:space:]]+on|prerequisite|pre-requisite|prereq|blocking|blocks|requires|前置|依赖|阻塞' \
    | grep -oE '#[0-9]+' | tr -d '#' | sort -nu || true
}

PROSE_BLOCKER_SNAPSHOT_ACTIVE=0
declare -gA PROSE_BLOCKER_VIEW_CACHE=()

# has_open_prose_blocker <issue> <title/body/brief text> -- check explicit
# prose prerequisites that are not linked in GitHub's native dependency graph.
has_open_prose_blocker() {
  local n="$1" text="${2:-}" references blocker blocker_state blocker_view label_names_json query_failed=0
  local -a blocked_ids=()
  OPEN_BLOCKER_IDS=""
  OPEN_BLOCKER_QUERY_FAILED=0
  # Split clauses first so a keyword binds only the issue in its own clause: issue 2681's
  # "#2568（建档出口依赖）/ #2493 B1（…本票先收口…）" blocked on #2493 (2026-10-08).
  references="$(prose_blocker_references <<< "$text")"
  for blocker in $references; do
    [ "$blocker" = "$n" ] && continue
    if ! [[ "$blocker" =~ ^[0-9]+$ ]]; then
      query_failed=1
      blocked_ids+=("$blocker")
      continue
    fi
    blocker_view="${PROSE_BLOCKER_VIEW_CACHE[$blocker]:-}"
    if [ "$PROSE_BLOCKER_SNAPSHOT_ACTIVE" != 1 ] || [ -z "$blocker_view" ]; then
      blocker_view="$(gh issue view "$blocker" --repo "$REPO" --json state,labels \
        -q '{state: .state, labels: [.labels[].name]}' 2>/dev/null)" || blocker_view='!unavailable!'
      [ "$PROSE_BLOCKER_SNAPSHOT_ACTIVE" != 1 ] || PROSE_BLOCKER_VIEW_CACHE[$blocker]="$blocker_view"
    fi
    if [ "$blocker_view" = '!unavailable!' ]; then
      query_failed=1
      blocked_ids+=("$blocker")
      continue
    fi
    if ! blocker_state="$(jq -r '.state // empty' <<< "$blocker_view" 2>/dev/null)"; then
      query_failed=1
      blocked_ids+=("$blocker")
      continue
    fi
    case "$blocker_state" in
      OPEN|open)
        if ! label_names_json="$(jq -c '.labels // []' <<< "$blocker_view" 2>/dev/null)"; then
          query_failed=1
          blocked_ids+=("$blocker")
        elif ! has_merged_blocker_label_name "$label_names_json"; then
          blocked_ids+=("$blocker")
        fi
        ;;
      # A prose dependency may name a pull request; gh reports a merged one as MERGED (2026-10-03: issues
      # 1598 and 1607 sat 31 hours behind merged PRs 1567 and 1605, treated as unreadable).
      CLOSED|closed|MERGED|merged) ;;
      *) query_failed=1; blocked_ids+=("$blocker") ;;
    esac
  done
  for blocker in "${blocked_ids[@]}"; do
    OPEN_BLOCKER_IDS="${OPEN_BLOCKER_IDS:+$OPEN_BLOCKER_IDS, }$blocker"
  done
  OPEN_BLOCKER_QUERY_FAILED="$query_failed"
  [ "$query_failed" -eq 1 ] || [ "${#blocked_ids[@]}" -gt 0 ]
}

# --- the ladder: provenance, rungs, guarded admission ----------------------
# 2026-09-15 maintainer ruling: high-risk work may proceed through the configured
# review and advisor path instead of being stopped at admission.
# enforce_autonomy_gate() above stays exactly what it is -- a pure admission
# predicate for the STANDARD rung -- but a refusal is no longer an outcome.
# The rungs, each entered only when the one below cannot admit:
#   0 standard  P0/P1 with L0/L1 (L2 at phase 3): work implements and reviews.
#               risk-class.mjs + gate 4 + CI + head-SHA pin.
#   1 advisor   any refusal or judgment call: advisor re-measures impact on a
#               fresh index against the symbols actually modified, corrects
#               the classification or rules on the engineering question.
#   2 recut     categorically oversized (P2, or L3/L4) or a durable-write
#               footprint: split on the write/read boundary into children
#               that each climb from rung 0 on their own merits.
#   3 guarded   cannot be split (recut refused, or the advisor judged every
#               piece still needs the risky part): admit_guarded() below --
#               policy-resolved implementation + independent review, merge conditions
#               (counter-example tests, untouched functions) carried in the
#               brief for both to enforce.
# The honest terminal is not a rung: a ticket that exhausts rung 3's four
# attempts reaches needs-owner via give_up_on_issue() with a REPORT of what
# every rung measured -- not a question. ready-for-human is reserved for
# the advisor's own `maintainer` verdict (a product/business fact only the
# maintainer holds) and nothing else in this pipeline applies it for risk.

# What a `/to-tickets` ticket looks like on the wire, so the pipeline can
# tell it from a raw bug report without a new label or a schema change.
# The manifest-managed to-tickets skill (.agents/skills/to-tickets/SKILL.md,
# issue-template) writes `## What to build`; the issue form
# (.github/ISSUE_TEMPLATE/bug-report.yml) never does. run-recut.sh's own
# children ALSO carry `## What to build` (prompts/recut.md), and those are
# deliberately born needs-triage for a fresh measurement -- so recut stamps
# every child with RECUT_CHILD_MARKER (its `## Parent` sentence) and the
# predicate excludes it. Measured against #1193-#1208 (18 tickets the
# maintainer cut on 2026-09-15): every body has the heading; every raw report
# on the tracker lacks it.
RECUT_CHILD_MARKER="会走正常的分诊流程判定风险等级和处理方式"

# parent_issue_supplement_md <issue-body> <repo> -- return the referenced
# parent's `补充决定` section when present; parent reads are best-effort.
parent_issue_supplement_md() {
  local issue_body="${1:-}" repo="${2:-${REPO:-}}"
  local parent_number parent_json parent_body section

  parent_number="$(awk '
    /^##[[:space:]]+Parent([[:space:][:punct:]]|$)/ { in_parent=1; print; next }
    in_parent && /^##[[:space:]]/ { exit }
    in_parent { print }
  ' <<< "$issue_body" | grep -oE '#[0-9]+' | sed -n '1p' | tr -d '#')" || true
  [ -n "$parent_number" ] || return 0
  if ! parent_json="$(gh issue view "$parent_number" --repo "$repo" --json body 2>/dev/null)"; then
    return 0
  fi
  if ! parent_body="$(jq -r '.body // empty' <<< "$parent_json" 2>/dev/null)"; then
    return 0
  fi

  section="$(awk '
    !found && /^#{1,6}[[:space:]].*补充决定/ { found=1 }
    found {
      if (printed && /^##[[:space:]]/) exit
      line=$0
      remaining=6000-chars
      if (remaining <= 0) exit
      if (length(line)+1 > remaining) {
        if (remaining > 1) printf "%s\n", substr(line, 1, remaining-1)
        exit
      }
      print line
      chars += length(line)+1
      printed=1
      if (chars >= 6000) exit
    }
  ' <<< "$parent_body")" || return 0
  [ -n "$section" ] || return 0
  printf '### Parent spec #%s — 补充决定 (overrides the spec body)\n\n%s\n' \
    "$parent_number" "$section"
}

# issue_is_precut <body> -- true iff this ticket was cut upstream by
# /to-tickets (Mac or here) and is therefore agent-ready by construction.
# The ask-matt skill states the rule plainly: "Tickets that /to-tickets
# produced are already agent-ready, so don't triage them." For a precut
# ticket run-triage.sh runs in measure-only mode: it keeps the model's
# measurements (risk_class, level, expected_packages, entry_surface,
# brief_md) and discards the model's `state` -- the state is decided by
# ladder_state() below, which can only ever be a rung, never a stop.
issue_is_precut() {
  local body="$1"
  grep -qE '^(## What to build[[:space:]]*|\*\*What to build:\*\*.*)$' <<< "$body" || return 1
  ! grep -qF -- "$RECUT_CHILD_MARKER" <<< "$body"
}

# ladder_state <risk_class> <level> <phase> -- the state for a ticket that
# is agent-ready by provenance (precut) or by a human's explicit label: the
# standard rung if enforce_autonomy_gate() admits it, otherwise the advisor
# rung. Never ready-for-human, never needs-info: "the machine may refine a
# classification but never use it to stop." Pure; same fail-closed shape as
# the gate it wraps (garbage/empty fields -> needs-advisor, never admission).
ladder_state() {
  local risk_class="$1" level="$2" phase="$3"
  if [ "$(enforce_autonomy_gate ready-for-agent "$risk_class" "$level" "$phase")" = "ready-for-agent" ]; then
    echo ready-for-agent
  else
    echo needs-advisor
  fi
}

# state_is_guarded <n> -- did admit_guarded() admit this issue? Read by
# issue-pipeline.sh's implement dispatch to record the guarded admission.
state_is_guarded() {
  state_read "$1" | jq -e '.guarded == true' >/dev/null 2>&1
}

# strip_brief_banner <text> -- shared by guarded_brief() and
# advisor_superseded_brief() below (V112/V113/V116, lessons/RULES.md).
# Both functions prepend a banner ("current truth" + a "\n---\n\n" separator)
# in front of whatever brief_md they are handed. Called again on the SAME
# ticket -- a second guarded episode, a second misclassification correction,
# or one of each -- the old code prepended onto whatever was already there,
# so every call stacked another full banner without ever removing the
# previous one. Two real tickets (#1204, #1206) accumulated 31 and 29
# stacked banners this way, brief_md growing from a normal 5-8K to
# 65-68K/47-49K bytes and eventually overrunning state_merge's own
# argv-size fix (state_merge()'s own 2026-09-15 comment, above).
#
# Detection: both banner texts are hardcoded literals that always begin with
# one of these two prefixes and always end in the same "\n---\n\n" separator
# immediately before the nested content -- these are the ONLY two producers
# of a brief_md prepend in this codebase (grep 'guarded_brief\|advisor_
# superseded_brief' confirms it). If $1 starts with either prefix, it
# already carries a banner (of either kind -- a ticket can legitimately go
# guarded once, get corrected once, then go guarded again, so this strips
# EITHER, not just the caller's own). If $1 does NOT start with either
# prefix, it has no banner yet (first admission ever, or genuinely original
# brief_md) and is returned unchanged -- this branch is required, not an
# optimization: unconditionally stripping through some "---" would silently
# truncate an ordinary brief whose own prose happens to contain a markdown
# horizontal rule, discarding a real ruling instead of a stale one.
#
# 2026-09-16 correction: the first version of this function used bash's
# `${var##*pattern}` (greedy prefix strip -- jump straight to the LAST
# occurrence of the separator ANYWHERE in the string) to unwrap however many
# layers had accumulated in one pass. That is wrong whenever the TRUE
# original content beneath the banner(s) itself contains a "\n---\n\n" --
# an ordinary markdown horizontal rule, which real triage briefs do use --
# because the last occurrence in the whole string is then inside the real
# content, not at the true outermost boundary, and greedy-stripping through
# it discards real brief text along with the banner. Caught live backfilling
# #1202 (6 genuinely stacked banners): the greedy version cut its 2,762-byte
# original core down to 1,270 bytes, silently eating real content, because
# the core itself contains one more "---" of its own. Fixed by walking
# forward one layer at a time instead of jumping to the last separator:
# peel with the NON-greedy `${var#*pattern}` (first occurrence) and re-check
# the prefix after each peel, stopping the instant what remains is not
# itself banner-prefixed -- so the walk only ever consumes text that is
# actually a banner layer, never a coincidental "---" sitting in real
# content past the last real banner. Re-verified against #1204/#1206 (still
# 6,276/4,206 bytes) and #1202 (now correctly 2,762 bytes, not 1,270).
GUARDED_BANNER_PREFIX='**这张票按「加强看护」'
SUPERSEDED_BANNER_PREFIX='**顾问已改判'

strip_brief_banner() {
  local text="$1" sep=$'\n---\n\n'
  while true; do
    case "$text" in
      "$GUARDED_BANNER_PREFIX"*|"$SUPERSEDED_BANNER_PREFIX"*) : ;;
      *) break ;;
    esac
    case "$text" in
      *"$sep"*) text="${text#*"$sep"}" ;;
      *) break ;; # banner prefix with no separator -- malformed/truncated; stop rather than eat everything
    esac
  done
  printf '%s' "$text"
}

# guarded_brief <old_brief_md> <risk_class> <level> <merge_conditions_md>
# Same shape and reason as run-advisor.sh's advisor_superseded_brief(): the
# stored brief_md is what run-implement.sh feeds the model verbatim, and a
# brief written before this admission may still conclude "needs a human"
# (#1144, measured). The banner states the CURRENT truth and the merge
# conditions both implementer and reviewer must honor -- but it now REPLACES
# any banner already on the front of $old_brief (strip_brief_banner(),
# above) instead of stacking on top of it; see that function's comment for
# why (V112/V113/V116).
guarded_brief() {
  local old_brief risk="$2" level="$3" conditions="$4"
  old_brief="$(strip_brief_banner "$1")"
  echo "**这张票按「加强看护」（guarded）进入无人值守流水线（$(date -u +%Y-%m-%dT%H:%M:%SZ)）。** 它没能拆成低风险的小票，也不在常规准入范围内（risk_class=${risk:-未测量}, level=${level:-未测量}）；实现与独立评审仍分别解析持久化策略中的角色，不切换模型。下面这份简报里如果出现「维持 ready-for-human」「不会自动写代码」「需要人工」这类结论，那是本次准入之前的旧结论，已经不成立，以本段为准。

**合并前必须满足的条件（实现者必须把它们做进 diff，评审者必须逐条核对）：**

${conditions:-（顾问未给出额外条件；至少：每一条持久化写路径都要有反例测试——另一租户看不到、另一员工看不到、被撤销的用户看不到、重放不重复写入。）}

---

$old_brief"
}

# admit_guarded <n> <risk_class> <level> <reason_md> <merge_conditions_md>
# Rung 3. Called by run-advisor.sh (an `advised` verdict on a classification
# the gate still refuses) and by run-recut.sh (a refusal: the ticket could
# not be split). Writes the guarded contract into the state file -- read by
# issue-pipeline.sh (model swap) and, once run-implement.sh honors it, by
# the implement leg (counter-example test verification, durable-write
# footprint admission) -- supersedes the stored brief, comments, and applies
# exactly one state label. risk_class/level may be empty (an untriaged
# recut parent): then they are left unset, triage_classification_status()
# reads "unmeasured", and the scheduler measures it first, guarded flag
# intact. Every write here is guarded_write/state_merge, so AGENT_DRY_RUN=1
# prints instead of mutating.
admit_guarded() {
  local n="$1" risk="$2" level="$3" reason="$4" conditions="$5" child_status=1
  # $6, optional (default "[]"): required_test_paths JSON array -- the
  # mechanical (git-diff-checkable) form of $conditions' own prose, read by
  # run-implement.sh's guarded-merge admission path. Optional so run-recut.sh's
  # own call site (which predates this field) and lib.test.sh's existing
  # 5-arg fixture keep working unchanged.
  local required_test_paths="${6:-[]}"
  local old_brief new_brief patch comment_body
  if recut_parent_has_open_child "$n" "${OPEN_ISSUE_BLOCKER_GRAPH_JSON:-[]}" "" 0; then child_status=0; else child_status=$?; fi
  case "$child_status" in
    0) echo "admit_guarded: keeping parent #$n out of ready-for-agent while children remain open" >&2; return 0 ;;
    2) echo "admit_guarded: cannot verify children for #$n; refusing ready-for-agent" >&2; return 1 ;;
  esac
  # loop_break_check() side effect only (never gates this admission) -- see
  # its own comment above route_to_advisor(). This is the OTHER shared
  # writer in the ready-for-agent<->needs-advisor pair the same check
  # watches there.
  loop_break_check "$n" ready-for-agent needs-advisor
  [ "$LOOP_BREAK_ESCALATED" = 1 ] && return 0
  old_brief="$(state_read "$n" | jq -r '.brief_md // empty')"
  new_brief="$(guarded_brief "$old_brief" "$risk" "$level" "$conditions")"
  # $new_brief/$reason/$conditions are untrusted-size (an accumulating
  # brief_md, a route_note, an advisor's merge_conditions_md) -- jq_arg_file()
  # per value, not --arg, for the same reason state_merge's own $filter had
  # to stop going through argv (see that function's comment).
  local brief_file reason_file conditions_file
  brief_file="$(jq_arg_file "$new_brief")"
  reason_file="$(jq_arg_file "$reason")"
  conditions_file="$(jq_arg_file "$conditions")"
  patch="$(jq -n --arg r "$risk" --arg l "$level" --rawfile b "$brief_file" --rawfile g "$reason_file" --rawfile c "$conditions_file" --argjson rtp "$required_test_paths" \
    '{guarded: true, guard_reason: $g, merge_conditions_md: $c, required_test_paths: $rtp, brief_md: $b, guarded_at: (now | todate)}
     + (if $r != "" then {risk_class: $r} else {} end)
     + (if $l != "" then {level: $l} else {} end)')"
  rm -f "$brief_file" "$reason_file" "$conditions_file"
  issue_transition "$n" ready-for-agent guarded-admission ". + $patch" || return 1
  comment_body="$BOT_DISCLAIMER
**这张票按「加强看护」（guarded）进入无人值守流水线。** 它没能拆成低风险的小票，也不在常规准入范围内；实现和评审都使用持久化策略的 work role。

原因：$reason

合并前必须满足：

${conditions:-（顾问未给出额外条件；至少：每一条持久化写路径都要有反例测试——另一租户看不到、另一员工看不到、被撤销的用户看不到、重放不重复写入。）}"
  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run] gh issue comment %s --repo %s --body %s\n' "$n" "$REPO" "$comment_body" >&2
  else
    guarded_issue_comment "$n" "$comment_body"
  fi
  return 0
}

# --- advisor leg helpers shared between run-advisor.sh (one ticket) and ----
# --- run-advisor-batch.sh (many tickets in one call) -----------------------
# Both moved here 2026-09-16 when the batch sweep was built: they were
# originally local to run-advisor.sh, but the batch leg needs the identical
# POLICY (what counts as a risky footprint, how a corrected classification
# supersedes a stale brief) applied to every ticket it rules on, and a
# second hand-copy of either is exactly the kind of drift risk-class.mjs's
# own pattern list already suffered once (see advisor_footprint_risky()'s
# own comment below) -- one source of truth, imported by both legs, not
# retyped by the second one.

# --- The hard footprint gate: enforced here in bash, never trusted to the --
# --- prompt. See enforce_autonomy_gate() comment (#1098) for the documented
# --- incident behind "prompt prose is not enforcement": a model returned a
# --- self-contradicting risk_class/state pair in the same response and the
# --- wrapper applied it verbatim until this exact pattern was re-derived in
# --- code. This is that same discipline applied to a second, independent
# --- gate.
#
# enforce_autonomy_gate() only re-checks risk_class/level/phase -- it says
# nothing about the DIFF'S FOOTPRINT. risk-class.mjs is the pipeline's other
# P2/L4 gate: it classifies by actual changed paths and runs twice inside the
# implement leg (run-implement.sh, right before push and again right before
# merge). An issue the advisor waves through on a clean risk_class/level
# alone can still get implemented, reviewed, and only THEN bounced by
# risk-class.mjs -- strictly worse than parking it up front. expected_
# packages (declared by the original triage run) is the only pre-
# implementation footprint signal there is, so this checks it against
# risk-class.mjs's own rules by CALLING classify(), never by restating its
# patterns here.
#
# This function deliberately keeps no hand-copied list of risk-class.mjs's
# patterns: that second copy drifts. It has exactly one source of truth for what
# counts as risky, imported, not re-typed. See risk-class.mjs itself for the
# live pattern list -- do not restate it here or in prompts/advisor.md/
# prompts/advisor-batch.md.
#
# What this function actually proves, and what it does NOT: it catches
# expected_packages entries declared with enough precision to already match
# a current risk-class.mjs pattern (a trailing "/" is appended to each
# candidate so `^prefix/`-anchored patterns can match a bare declared path
# the way they'd match a real file beneath it). It CANNOT catch a purely
# package-granularity declaration ("packages/foo") against a pattern that
# only matches a specific subdirectory of that package, and it cannot catch
# a filename-anywhere pattern (ledger, rls|policy, Dockerfiles, .env, ...)
# that a package-level declaration gives no visibility into at all.
# Clearing this check is therefore NOT proof an issue is safe -- it is a
# best-effort pre-filter on top of the real, authoritative gate, which stays
# in run-implement.sh, unchanged and un-bypassed by this leg. risk-class.
# mjs's own pattern coverage is being audited and fixed separately; this
# function inherits whatever it says, automatically, with no edit here.
advisor_footprint_risky() {
  local expected_json="$1" count lib_dir
  count="$(echo "$expected_json" | jq 'length' 2>/dev/null || echo 0)"
  [ "${count:-0}" -gt 0 ] 2>/dev/null || return 0

  # risk-class.mjs has its own `if (import.meta.url === file://${process.
  # argv[1]})` CLI self-invocation guard -- passing its own path as argv[1]
  # here would make THAT condition true (argv[1] would equal the very file
  # being imported) and fire its CLI block as an unwanted side effect of the
  # import. An env var, not an argv position, sidesteps the collision
  # entirely rather than depending on argument order never accidentally
  # matching that guard again. lib_dir (not SCRIPT_DIR, a caller-only
  # variable this file must not depend on) is this file's OWN directory --
  # risk-class.mjs always lives right next to lib.sh, by construction.
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  RISK_CLASS_MODULE="$lib_dir/risk-class.mjs" node --input-type=module -e '
    const { classify } = await import(process.env.RISK_CLASS_MODULE);
    const pkgs = JSON.parse(process.argv[1]);
    const candidates = pkgs.map((p) => (p.endsWith("/") ? p : p + "/"));
    process.exit(classify(candidates).length > 0 ? 0 : 1);
  ' "$expected_json"
}

# advisor_superseded_brief <old_brief_md> <new_risk_class> <new_level>
#
# 2026-09-15: measured live the same night this leg was built -- a manual
# advisor pass corrected risk_class/level and the GitHub label on seven
# tickets via state_merge, but never touched `.state` or the STORED
# brief_md's own narrative conclusion. run-implement.sh reads brief_md
# verbatim as the model's own instructions (`BRIEF="$(state_read "$N" | jq
# -r '.brief_md')"`) -- so issue #1144's brief still concluded "the outcome
# is unchanged: ready-for-human" and told the implementer in plain language
# this ticket would not be auto-implemented, while an autonomous implement
# run was dispatched for it anyway: the model was told, in the same prompt,
# both to implement the ticket and that it would not be implemented.
# Whether that specific contradiction caused that run's own failure (it
# failed at the dirty-worktree check before the transcript could confirm
# either way) is NOT claimed here -- the incoherence is a defect on its own
# terms regardless of what it caused. The state file holds both
# machine-readable fields and human-readable narrative generated from them;
# correcting a field without correcting the narrative leaves the narrative
# lying, and the narrative is what the model actually reads. Every write
# path that changes classification owns both.
#
# This does not parse or strip whatever the old brief_md's own stale
# conclusion says -- fragile against arbitrary prior wording, and this
# function has no way to know what shape that conclusion took. It prepends
# an unambiguous, hard-to-miss supersession banner instead, so a stale
# "this needs a human"/"will not be implemented automatically" sentence
# below it is explicitly overridden, not silently left standing.
#
# 2026-09-16: this used to prepend onto $old_brief UNCONDITIONALLY, same bug
# as guarded_brief() above and same fix -- strip_brief_banner() first, so a
# second (or twelfth) misclassification correction replaces the previous
# banner instead of stacking on it. See strip_brief_banner()'s own comment
# (above guarded_brief()) for why this strips either banner kind, not just
# this function's own.
advisor_superseded_brief() {
  local old_brief new_risk="$2" new_level="$3" conditions="${4:-}"
  old_brief="$(strip_brief_banner "$1")"
  echo "**顾问已改判（$(date -u +%Y-%m-%dT%H:%M:%SZ)），这张票现在按无人值守处理。** 下面这份分诊简报是改判前写的，当前真实状态是 risk_class=$new_risk, level=$new_level, state=ready-for-agent——简报正文里如果出现「维持 ready-for-human」「不会自动写代码」「需要人工」这类结论，那是改判前的旧结论，已经不成立，以这一行为准。
$([ -n "$conditions" ] && printf '\n**顾问给出的合并条件（实现者必须做进 diff，评审者必须逐条核对）：**\n\n%s\n' "$conditions")
---

$old_brief"
}

# advisor_prune_own_comments <issue_json> -- drop this pipeline's own past
# comments from `gh issue view`'s .comments before any of it reaches an
# advisor prompt.
#
# Extracted 2026-09-19 from run-advisor-batch.sh, where it was built
# 2026-09-16 after a live sizing failure: a batch prompt measured
# 1,104,128 characters against Codex's own 1,048,576-character input cap,
# root-caused to two tickets stuck the same night in a label-flip loop
# (state_merge()'s own 2026-09-15 comment) that had each racked up 90+ of
# this pipeline's OWN restated comments (guarded-brief banners, relabel
# notices, advisor rulings -- ~90% of their comment bytes) -- the advisor
# was mostly being shown itself talking to itself. Moved here so
# run-advisor.sh's single-ticket leg can apply the identical rule instead
# of feeding the model its own past chatter on every dispatch, unmeasured
# only because one ticket's own noise rarely alone trips the batch leg's
# hard input cap -- it was never free, just not the call that failed loud.
#
# comment_is_bot()'s own $BOT_DISCLAIMER prefix test (above) is reused
# verbatim, not reinvented: every comment this pipeline posts itself starts
# with the literal $BOT_DISCLAIMER text, so filtering on that prefix can
# only drop the pipeline's own restated noise, never a genuine reporter/
# human comment -- including a GitHub "quote reply" that copies a bot
# comment's $BOT_COMMENT_MARKER into a human's own new comment underneath
# it (see comment_is_bot()'s own comment for exactly why this is a prefix
# test and not a marker-presence test).
#
# `(. // [])` before map(): a ticket with zero comments, or an $issue_json
# missing `.comments` entirely, must trim to an empty list, not crash the
# caller's `set -e` -- both are ordinary inputs (a freshly opened ticket
# has no comments yet), not malformed ones.
#
# <<< not --arg/--argjson for the big side of this: $issue_json is
# untrusted-size (a long human thread) -- same MAX_ARG_STRLEN concern
# jq_arg_file()'s own comment documents, same reason run-advisor-batch.sh's
# own ticket-assembly loop routes through it instead of argv.
advisor_prune_own_comments() {
  local issue_json="$1"
  [ -n "$issue_json" ] || issue_json='{}'
  jq -c --arg prefix "$BOT_DISCLAIMER" \
    '.comments |= ((. // []) | map(select((.body // "") | startswith($prefix) | not)))' \
    <<< "$issue_json"
}

# advisor_current_brief_md <prior_state_json> -- cut prior_state.brief_md
# down to only its current (most recent) classification narrative before
# any of it reaches an advisor prompt.
#
# Extracted 2026-09-19 from run-advisor-batch.sh (built 2026-09-16, same
# incident as advisor_prune_own_comments() above): advisor_superseded_
# brief() PREPENDS a fresh banner every time a ticket is re-classified, and
# that banner tells the reader in plain language that any stale conclusion
# below it no longer applies -- so only the text before the first such
# banner boundary ("\n---\n\n", the exact string advisor_superseded_
# brief() joins on) is this ticket's current, authoritative narrative. Two
# real tickets had 30 and 29 stacked banners (65,137 and 47,985 chars of
# brief_md, measured) -- an ever-growing chain of text the pipeline itself
# had already marked superseded. A ticket classified once, the common
# case, has no such boundary at all and this is a no-op.
#
# This is deliberately NOT strip_brief_banner() (above): that function
# peels a banner OFF to recover the original content underneath (so a NEW
# banner can be prepended in its place) -- the opposite direction from what
# a prompt needs, which is the newest banner's own "current truth"
# statement and nothing stale beneath it.
#
# `if . == null` guards a ticket with no brief_md yet (never triaged, or a
# fresh episode) -- left unchanged (null), not coerced into a crash or a
# stray "null" string.
advisor_current_brief_md() {
  local prior_json="$1"
  [ -n "$prior_json" ] || prior_json='{}'
  jq -c '.brief_md |= (if . == null then . else (split("\n---\n\n")[0]) end)' \
    <<< "$prior_json"
}

# advisor_pending_orphan_candidates -- every issue number under $STATE_DIR
# whose local state still carries an unresolved .pending_advisor_verdict.
# The scheduler also uses this list for roadmap parents removed from the
# fresh batch even while their GitHub label still says needs-advisor.
# 2026-09-19: closes the recovery gap left after advisor_persist_pending()/
# the atomic-completion write (advisor-core.sh, c8d802867): if a verdict's
# Apply sequence swaps the GitHub label away from needs-advisor but a LATER
# step in that same Apply run fails before the final atomic completion
# write, the ticket is stuck -- .pending_advisor_verdict sits in its local
# state forever, but issue-pipeline.sh's ordinary candidate query (`gh issue
# list --label needs-advisor`) can never find it again, because the label
# it keys on is already gone.
#
# "Present" already means "this exact episode's Apply never finished": the
# SAME state_merge call that ever clears .pending_advisor_verdict either
# finishes the episode (sets advisor_ruled_at, advisor-core.sh's own
# atomic-completion comment) or starts a fresh one (route_to_advisor()/
# give_up_on_issue(), which clear it in the same call as advisor_ruled_at) --
# so nothing else ever leaves it sitting on disk once an episode is done.
# No episode-seq cross-check needed here: advisor_resume_check() (advisor-
# core.sh) already re-validates that atomically against the CURRENT episode
# the moment a dispatch actually picks this ticket back up; this function's
# only job is surfacing the candidate, not re-deciding its eligibility.
#
# Reads state files directly (same $STATE_DIR/*.json glob idiom count_
# recent_loop_escalations()/sweep-brief-banners.sh already use above and in
# their own files), not a GitHub query -- this IS the recovery path for a
# ticket whose GitHub label already moved off needs-advisor while its local
# pending marker is still sitting there, so a query keyed on that label
# would miss it by definition. A state file that fails to parse (jq -e
# itself failing) is skipped, not fatal to the rest of the scan -- one
# corrupt file must not hide every other ticket's own orphaned verdict.
# One issue number per line, numerically sorted for a deterministic
# dispatch order across ticks.
advisor_pending_orphan_candidates() {
  local f
  [ -d "$STATE_DIR" ] || return 0
  for f in "$STATE_DIR"/*.json; do
    [ -f "$f" ] || continue
    jq -e '.pending_advisor_verdict != null' "$f" >/dev/null 2>&1 || continue
    basename "$f" .json
  done | sort -n
}

# One batch job belongs to the advisor queue, not to any one issue. Keep its
# job id, member snapshots, and byte-budget deferrals in one atomic local
# record so a later tick can poll exactly the job it started. Per-issue state
# deliberately keeps only normal pending verdicts: run-advisor.sh must never
# mistake a batch NDJSON response for its one-ticket JSON job.
ADVISOR_BATCH_STATE_FILE="${ADVISOR_BATCH_STATE_FILE:-$AGENT_HOME/advisor-batch.json}"

advisor_batch_state_read() {
  if [ -f "$ADVISOR_BATCH_STATE_FILE" ]; then
    cat "$ADVISOR_BATCH_STATE_FILE"
  else
    echo '{}'
  fi
}

advisor_batch_state_write() {
  local json="$1" tmp
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] advisor batch state -> $ADVISOR_BATCH_STATE_FILE" >&2
    return 0
  fi
  if ! jq -e . >/dev/null 2>&1 <<< "$json"; then
    echo "advisor_batch_state_write: refusing invalid JSON for $ADVISOR_BATCH_STATE_FILE" >&2
    return 1
  fi
  mkdir -p "$(dirname "$ADVISOR_BATCH_STATE_FILE")"
  tmp="$(mktemp "${ADVISOR_BATCH_STATE_FILE}.tmp.XXXXXX")" || return 1
  if ! printf '%s\n' "$json" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$ADVISOR_BATCH_STATE_FILE"
}

advisor_batch_state_transform() {
  local filter="$1" filter_file updated
  filter_file="$(mktemp)" || return 1
  printf '%s\n' "$filter" > "$filter_file"
  if ! updated="$(advisor_batch_state_read | jq -f "$filter_file")"; then
    rm -f "$filter_file"
    return 1
  fi
  rm -f "$filter_file"
  advisor_batch_state_write "$updated"
}

advisor_batch_job_json() {
  advisor_batch_state_read | jq -c '.job // empty'
}

advisor_batch_job_active() {
  advisor_batch_state_read | jq -e '(.job.job_id? // "") | (type == "string" and length > 0)' >/dev/null
}

advisor_batch_state_set_job() {
  local job_json="$1" job_file updated
  job_file="$(jq_arg_file "$job_json")"
  if ! updated="$(advisor_batch_state_read | jq --slurpfile job "$job_file" '. + {job: $job[0]}')"; then
    rm -f "$job_file"
    return 1
  fi
  rm -f "$job_file"
  advisor_batch_state_write "$updated"
}

advisor_batch_state_clear_job() {
  advisor_batch_state_transform 'del(.job)'
}

advisor_batch_deferred_candidates() {
  local n state
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    state="$(state_read "$n")"
    echo "$state" | jq -e 'has("advisor_ruled_at") or (.state // "") == "concluded"' >/dev/null 2>&1 && continue
    echo "$n"
  done < <(advisor_batch_state_read | jq -r '.deferred_issue_ids[]? | select(type == "number")')
}

advisor_batch_defer_issues() {
  local ids_file updated
  [ "$#" -gt 0 ] || return 0
  ids_file="$(mktemp)" || return 1
  printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)' > "$ids_file"
  if ! updated="$(advisor_batch_state_read | jq --slurpfile ids "$ids_file" \
    '.deferred_issue_ids = (((.deferred_issue_ids // []) + $ids[0]) | unique)')"; then
    rm -f "$ids_file"
    return 1
  fi
  rm -f "$ids_file"
  advisor_batch_state_write "$updated"
}

advisor_batch_lock_file() {
  echo "$AGENT_HOME/locks/advisor-batch.lock"
}

# --- systemic environmental faults: ledger, quarantine, probe, canary --------
# 2026-09-15. The implement leg now classifies a test-gate failure whose
# OUTPUT is environmental (no Docker, connection refused, a missing binary)
# as not-the-diff's-fault and stops charging the ticket an attempt -- with a
# per-ISSUE cap. That granularity is wrong for the failure it was built for:
# tonight's two faults (no Docker, no git author identity) hit every ticket
# that reached the relevant step, so per-issue counters would have had each
# ticket independently burn its strikes and independently give up, in
# parallel, and nothing would have noticed one cause was destroying the
# whole queue. A human watched and hand-held eight tickets -- the exact
# intervention this pipeline exists to remove. Model failures now use
# provider holds for quota and issue-scoped backoff otherwise; environmental
# faults need their own shared ledger and quarantine.
#
# The shape chosen, and why not a broad pause:
#   1. LEDGER  record_env_fault() -- every wrapper that proves a failure was
#      environmental appends one line, keyed by a SIGNATURE (what broke,
#      e.g. env:git-identity, env:test-gate:docker) and a SCOPE (which
#      class of ticket it hits: a stage, or a stage plus one package
#      directory). No issue counter: the ledger is the counter.
#   2. DETECT  env_fault_is_systemic() -- the same signature from >=2
#      distinct issues, or >=3 hits, inside an hour. Pure over the file.
#   3. QUARANTINE the SCOPE, never the pipeline. issue-pipeline.sh stops
#      dispatching only that stage (or only tickets whose expected_packages
#      touch that package); triage, advisor, recut keep preparing the
#      backlog. This is what "quarantine the affected class" means here: a
#      package whose integration tests need Docker does not stop a
#      docs-only ticket in another package.
#   4. REPAIR  env_fault_repair() -- the most dangerous rung, so the
#      tightest bound: an explicit allowlist of signatures whose fix is
#      DERIVABLE by the machine without a secret or a human value, run at
#      most once per quarantine, only appending never overwriting, and
#      immediately re-probed. Exactly one entry today (git identity from
#      the authenticated GitHub account, GitHub's own noreply form, written
#      to the EnvironmentFile outside version control). Docker cannot be
#      installed by this pipeline and has no entry.
#   5. WAKE-UP has a defined exit, always -- the PAUSE lesson (a pause with
#      no defined exit is the slow version of parking): a signature with a
#      known PROBE lifts the moment the probe passes; every signature also
#      gets a CANARY -- one dispatch allowed through after 15 minutes,
#      doubling to a 4-hour cap -- and a canary that is not followed by a
#      new fault line within a grace period lifts the quarantine.
#   6. RECORD  quarantine and canary state locally. HEALTH and the env-fault
#      ledger carry the current status; automatic probes lift it on recovery.
# Attempts: issue-pipeline.sh bumps `.attempts` at implement dispatch. An
# environmental fault normally must not be charged (lessons/RULES.md V79),
# so record_env_fault() refunds that bump for stage=implement by default.
# A real wall-clock timeout passes refund_attempt=0: model work really ran.
ENV_FAULT_DIR="$AGENT_HOME/env-faults"
QUARANTINE_DIR="$AGENT_HOME/quarantine"
ENV_FAULT_WINDOW_SECONDS=$((60 * 60))
ENV_FAULT_SYSTEMIC_DISTINCT_ISSUES=2
ENV_FAULT_SYSTEMIC_TOTAL_HITS=3
QUARANTINE_CANARY_INITIAL_SECONDS=$((15 * 60))
QUARANTINE_CANARY_MAX_SECONDS=$((4 * 60 * 60))
QUARANTINE_CANARY_GRACE_SECONDS=$((30 * 60))
QUARANTINE_NOTIFICATION_WINDOW_SECONDS="${QUARANTINE_NOTIFICATION_WINDOW_SECONDS:-3600}"
QUARANTINE_NOTIFICATION_DIR="$AGENT_HOME/quarantine-notifications"

# One safe file name per signature/scope: anything outside [A-Za-z0-9._:@-]
# becomes `_`, so a signature built from a log pattern cannot escape the
# directory or collide on a slash.
env_fault_key() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._:@-' '_'
}

# quarantine_scope <stage> [package_dir] -> "implement" or "implement@packages/foo"
quarantine_scope() {
  local stage="$1" pkg="${2:-}"
  if [ -n "$pkg" ]; then echo "$stage@$pkg"; else echo "$stage"; fi
}

# record_env_fault <signature> <stage> <issue> <detail> [package_dir] [now] [refund_attempt]
record_env_fault() {
  agent_pipeline_write_guard record_env_fault "$AGENT_HOME" "$ENV_FAULT_DIR" || return 1
  local signature="$1" stage="$2" n="$3" detail="$4" pkg="${5:-}" now="${6:-$(date +%s)}" refund_attempt="${7:-1}" f
  f="$ENV_FAULT_DIR/$(env_fault_key "$signature").log"
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] record_env_fault $signature stage=$stage issue=$n scope=$(quarantine_scope "$stage" "$pkg") detail=$detail" >&2
    return 0
  fi
  mkdir -p "$ENV_FAULT_DIR"
  printf '%s\t%s\t%s\t%s\t%s\n' "$now" "$(quarantine_scope "$stage" "$pkg")" "$n" "$signature" "${detail//[$'\t\n']/ }" >> "$f"
  if [ "$stage" = "implement" ] && [ "$refund_attempt" = "1" ]; then
    refund_implement_attempt "$n"
  fi
}

CODEX_CONFIG_PROBE_OUTPUT=""
CODEX_CONFIG_PROBE_STATUS=0
codex_config_probe() {
  local status=0
  CODEX_CONFIG_PROBE_OUTPUT="$(timeout 10s codex features list 2>&1)" || status=$?
  CODEX_CONFIG_PROBE_STATUS="$status"
  return "$status"
}

# 2026-10-03: `inherit = "core"` under [shell_environment_policy] hid GH_TOKEN and the
# proxy from every hand agent shell; gh said "not logged in" and pushes failed all day.
codex_config_hides_env() {
  local file="${CODEX_HOME:-$HOME/.codex}/config.toml"
  [ -f "$file" ] || return 1
  awk '/^[[:space:]]*\[/ { s = ($0 ~ /^[[:space:]]*\[shell_environment_policy\][[:space:]]*$/) }
    s && /^[[:space:]]*inherit[[:space:]]*=[[:space:]]*"(core|none)"/ { f = 1 }
    END { exit !f }' "$file"
}

codex_config_error_detail() {
  local output="$1" text
  if jq -e 'type == "object"' >/dev/null 2>&1 <<< "$output"; then
    text="$(jq -r '[.result, .error, .detail] | map(select(type == "string")) | join("\n")' <<< "$output")"
  else
    text="$output"
  fi
  printf '%s\n' "$text" \
    | grep -iE 'Error loading config\.toml|failed to load .*configuration|config\.toml:[0-9]+:[0-9]+:|TOML parse error|duplicate key' \
    | head -n 3 \
    | tr '\r\n\t' '   ' \
    | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' \
    || true
}

codex_config_parse_error() {
  local detail
  detail="$(codex_config_error_detail "$1")"
  [ -n "$detail" ]
}

codex_config_fast_failure() {
  local output="$1" elapsed="" text="$1"
  if jq -e 'type == "object"' >/dev/null 2>&1 <<< "$output"; then
    elapsed="$(jq -r '.codex_elapsed_seconds // empty' <<< "$output")"
    text="$(jq -r '[.result, .error, .detail] | map(select(type == "string")) | join("\n")' <<< "$output")"
  else
    elapsed="$(sed -nE 's/^codex-exec-elapsed-seconds=([0-9]+)$/\1/p' <<< "$output" | tail -n 1)"
  fi
  [[ "$elapsed" =~ ^[0-9]+$ ]] && (( elapsed < 10 )) && codex_config_parse_error "$text"
}

record_codex_config_fault() {
  local n="$1" stage="$2" output="$3" refund_attempt="${4:-1}" detail
  detail="$(codex_config_error_detail "$output")"
  [ -n "$detail" ] || detail="$(sed -n '1,3p' <<< "$output" | tr '\r\n\t' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
  record_env_fault env:codex-config-invalid "$stage" "${n:-0}" "$detail" "" "" 0 || return 1
  if [[ "$n" =~ ^[1-9][0-9]*$ ]] && [ "$DRY_RUN" != 1 ]; then
    [ "$refund_attempt" = 0 ] || state_unbump_attempts "$n" || return 1
    [ "$stage" = advisor ] || state_merge "$n" '.model_policy.active.config_fault = true' || return 1
  fi
  supervisor_inbox_append_once env:codex-config-invalid \
    "env:codex-config-invalid stage=$stage issue=${n:-0} $detail"
}

record_codex_runtime_fault() {
  local signature="$1" stage="$2" n="${3:-0}" detail="$4"
  record_env_fault "$signature" "$stage" "$n" "$detail" "" "" 0 || return 1
  supervisor_inbox_append_once "$signature" "$signature stage=$stage issue=$n $detail"
}

codex_dispatch_preflight() {
  local stage="${1:-dispatch}" detail signature
  if codex_config_probe; then
    if [ -e "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" ] && codex_probe_ok; then
      # Scheduler entry precedes issue backoff filtering, so legacy held issues cannot starve recovery.
      codex_provider_recovery_probe_if_due "$(model_policy identity work)" || true
    fi
    return 0
  fi
  if codex_config_parse_error "$CODEX_CONFIG_PROBE_OUTPUT"; then
    record_codex_config_fault 0 "$stage" "$CODEX_CONFIG_PROBE_OUTPUT" 0 || return 1
    echo "env:codex-config-invalid stage=$stage: $(codex_config_error_detail "$CODEX_CONFIG_PROBE_OUTPUT")" >&2
    return 1
  fi
  detail="$(printf '%s\n' "$CODEX_CONFIG_PROBE_OUTPUT" | sed -n '1,3p' | tr '\r\n\t' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
  [ -n "$detail" ] || detail="codex features list exited $CODEX_CONFIG_PROBE_STATUS"
  if model_call_missing_agent_binary "$CODEX_CONFIG_PROBE_OUTPUT" "" "" unknown; then
    signature=env:codex-binary-missing
  else
    signature=env:codex-features-probe-failed
  fi
  record_codex_runtime_fault "$signature" "$stage" 0 "$detail" || return 1
  echo "$signature stage=$stage issue=0 $detail" >&2
  return 1
}

codex_runtime_self_repair() {
  local user_bin bundle name link bundled old_target stamp
  user_bin="$(codex_runtime_user_bin_dir)"
  bundle="$(codex_runtime_bundle_dir)"
  [ -d "$user_bin" ] && [ -n "$bundle" ] || return 0
  for name in codex rg; do
    link="$user_bin/$name"
    bundled="$bundle/$name"
    [[ -L "$link" && ! -e "$link" && -x "$bundled" ]] || continue
    case "$name" in
      codex) timeout 10s "$bundled" features list >/dev/null 2>&1 || continue ;;
      rg) timeout 5s "$bundled" --version >/dev/null 2>&1 || continue ;;
    esac
    old_target="$(readlink "$link" 2>/dev/null || true)"
    ln -sfn -- "$bundled" "$link" || return 1
    hash -r 2>/dev/null || true
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    supervisor_inbox_append_once "codex-runtime-repair:$name:$stamp:$$" \
      "codex-runtime-repair binary=$name link=$link old_target=$old_target new_target=$bundled" || return 1
  done
}

# Config faults stay closed for the exact role configuration, with no timed
# canary. The role marker shares one fault across tickets and stages using it.
model_config_fault_file() { printf '%s/model-config-%s.json\n' "$AGENT_HOME" "$(env_fault_key "$1")"; }

model_config_fault_blocked() {
  local role="$1" identity="$2" f config
  f="$(model_config_fault_file "$role")"
  [ -f "$f" ] || return 1
  config="$(model_policy_effective_live_json "$MODEL_POLICY_FILE" 2>/dev/null | jq -c --arg role "$role" '.roles[$role]')" || return 0
  if jq -e --arg identity "$identity" --argjson config "$config" \
    '.identity == $identity and .config == $config' "$f" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# record_model_config_fault <issue> <stage> <role> <identity> <detail> [refund_attempt=1]
record_model_config_fault() {
  local n="$1" stage="$2" role="$3" identity="$4" detail="$5" refund_attempt="${6:-1}" config f lock_fd signature
  if codex_config_parse_error "$detail"; then
    record_codex_config_fault "$n" "$stage" "$detail" "$refund_attempt"
    return $?
  fi
  config="$(model_policy_effective_live_json "$MODEL_POLICY_FILE" 2>/dev/null | jq -c --arg role "$role" '.roles[$role]')" || return 1
  f="$(model_config_fault_file "$role")"
  signature="env:model-config:$role:$identity"
  mkdir -p "$AGENT_HOME/locks"
  exec {lock_fd}>"$AGENT_HOME/locks/model-config-$(env_fault_key "$role").lock"
  flock "$lock_fd"
  if ! model_config_fault_blocked "$role" "$identity"; then
    if [ "$DRY_RUN" != 1 ]; then
      jq -n --arg role "$role" --arg identity "$identity" --argjson config "$config" \
        '{role:$role,identity:$identity,config:$config}' > "$f.tmp" && mv "$f.tmp" "$f" || { unlock_fd "$lock_fd"; return 1; }
    fi
    record_env_fault "$signature" "$stage" "$n" "model configuration failure for $role/$identity: ${detail:0:500}" "" "" 0 || { unlock_fd "$lock_fd"; return 1; }
    [ "$DRY_RUN" = 1 ] || quarantine_supervisor_notice "$stage" open "$signature role=$role identity=$identity" || true
  fi
  unlock_fd "$lock_fd"
  if [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
    [ "$refund_attempt" = 0 ] || state_unbump_attempts "$n"
    [ "$stage" = advisor ] || state_merge "$n" '.model_policy.active.config_fault = true'
  fi
}

# gh_failure_is_transient <gh_stderr_text> -- true (0) iff the text names a
# network/infra shape (DNS, TLS, a timeout, a connection reset, a 5xx or 429
# from api.github.com) rather than a genuine `gh` refusal (a 404, a
# permissions error, a malformed query/mutation). Built from a live case
# (zf-advisor-1205, 2026-09-15): `Post "https://api.github.com/graphql":
# net/http: TLS handshake timeout` crashed run-advisor.sh's own apply block
# under `set -e` -- unlike the SAME script's initial `gh issue view` call
# (which already routes any failure through record_env_fault(), because at
# that point in the run nothing has been charged to the ticket yet to
# refund), the later `gh issue comment`/`gh issue edit`/`notify_email_
# verbatim` calls that actually apply a verdict had no such handling at all
# and just died. Matches on the error TEXT, not on which `gh` subcommand or
# which stage called it, because the identical subcommand (gh issue
# comment/edit) can fail either way and only the text says which -- a 404 or
# a permissions error must stay a real failure (this pattern deliberately
# does NOT match any 4xx), never get treated as an environment fault that
# quietly drops a verdict a real `model call` call already paid for.
#
# `timed out after [0-9]+s` (2026-09-15, the #1204 incident): gh()'s own
# bounded-timeout message, added alongside it -- a caller like
# apply_gh_write() that captures `gh`'s stdout+stderr and checks this
# function must classify gh()'s own timeout the same way it already
# classifies the network-error text `gh` prints on its own, or the exact
# failure this function exists to catch (a transient network fault killing
# an already-computed verdict) would be misclassified as "a real failure"
# specifically because it was CAUGHT rather than left to hang.
gh_failure_is_transient() {
  grep -qiE 'TLS handshake timeout|i/o timeout|connection reset|connection refused|dial tcp|context deadline exceeded|Temporary failure in name resolution|Could not resolve host|net/http: |HTTP 5[0-9][0-9]|HTTP 429|too many requests|Gateway Timeout|Service Unavailable|Bad Gateway|unexpected EOF|timed out after [0-9]+s' <<< "$1"
}

# env_fault_lines_since <signature> <since_epoch> -> the ledger lines newer
# than $since (tab-separated: epoch, scope, issue, signature, detail).
env_fault_lines_since() {
  local f since="$2"
  f="$ENV_FAULT_DIR/$(env_fault_key "$1").log"
  [ -f "$f" ] || return 0
  awk -F'\t' -v s="$since" '$1 > s' "$f"
}

# env_fault_is_systemic <signature> [now] [window] -> true iff, within the
# window, the signature hit >= ENV_FAULT_SYSTEMIC_DISTINCT_ISSUES distinct
# issues OR >= ENV_FAULT_SYSTEMIC_TOTAL_HITS times at all (one ticket
# re-dispatched into the same wall three times is the same evidence as
# three tickets hitting it once).
env_fault_is_systemic() {
  local signature="$1" now="${2:-$(date +%s)}" window="${3:-$ENV_FAULT_WINDOW_SECONDS}" lines distinct total
  lines="$(env_fault_lines_since "$signature" "$((now - window))")"
  [ -n "$lines" ] || return 1
  distinct="$(printf '%s\n' "$lines" | cut -f3 | sort -u | wc -l)"
  total="$(printf '%s\n' "$lines" | wc -l)"
  [ "$distinct" -ge "$ENV_FAULT_SYSTEMIC_DISTINCT_ISSUES" ] || [ "$total" -ge "$ENV_FAULT_SYSTEMIC_TOTAL_HITS" ]
}

# env_fault_latest_scope <signature> -> the scope on the newest ledger line.
env_fault_latest_scope() {
  local f
  f="$ENV_FAULT_DIR/$(env_fault_key "$1").log"
  [ -f "$f" ] && tail -n 1 "$f" | cut -f2
}

# env_fault_probe <signature> -> 0 the fault is gone, 1 still present, 2 no
# probe known (canary only). Config probes read the dispatched unit's
# EnvironmentFile, not this process's environment (V86); web session probes hold
# the shared transport lease and inspect the existing account target.
env_fault_probe() {
  local env_file="${ENV_FAULT_ENV_FILE:-$AGENT_HOME/env}" tab_status=0 df_line total_kb avail_kb free_gib required_kb
  case "$1" in
    env:network-timeout)
      # A failed per-call read is not proof the whole stage is offline. Use
      # an independent, bounded GitHub API request to confirm the shared
      # dependency is still unavailable before opening a stage quarantine.
      command -v curl >/dev/null 2>&1 || return 2
      if curl -fsS --connect-timeout 3 --max-time 8 https://api.github.com/meta >/dev/null 2>&1; then
        return 0
      fi
      return 1
      ;;
    env:leg-not-executable:*)
      [ -x "$REPO_DIR/engine/run-${1#env:leg-not-executable:}.sh" ]
      ;;
    env:codex-sandbox-probe)
      codex_probe_ok
      ;;
    env:git-identity)
      grep -qE '^ZF_AGENT_GIT_USER_NAME=.+' "$env_file" 2>/dev/null \
        && grep -qE '^ZF_AGENT_GIT_USER_EMAIL=.+' "$env_file" 2>/dev/null
      ;;
    env:test-gate:docker)
      docker info >/dev/null 2>&1
      ;;
    env:codex-binary-missing|env:codex-features-probe-failed)
      codex_config_probe
      ;;
    env:ci-runner-capacity|env:build-capacity)
      # Match the CI runner's capped disk floor and the shared build gate.
      df_line="$(timeout 35 ssh -o BatchMode=yes -o ConnectTimeout=15 cihost 'df -Pk /' 2>/dev/null \
        | awk 'NR == 2 && $2 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ { print $2, $4; exit }')" || return 2
      read -r total_kb avail_kb <<< "$df_line"
      [[ "${total_kb:-}" =~ ^[0-9]+$ && "${avail_kb:-}" =~ ^[0-9]+$ ]] || return 2
      required_kb="$(ci_runner_disk_capped_kb "$total_kb")" || return 2
      if [ "$1" = env:ci-runner-capacity ]; then
        [ "$avail_kb" -ge "$required_kb" ] || return 1
        return 0
      fi
      free_gib=$((avail_kb / 1024 / 1024))
      [ "$free_gib" -ge "$BUILD_CAPACITY_GATE_GIB" ] || return 1
      return 0
      ;;
    env:main-ci-red)
      ci_main_latest_completed_push_verdict
      ;;
    env:web-advisor-provider:*)
      # Provider seam: the web advisor's own transport health checks live in
      # providers/web-advisor-provider.sh and return 0/1/2; unknown families report
      # no probe.
      web_advisor_provider_env_fault_probe "$1"
      ;;
    *) return 2 ;;
  esac
}

# env_fault_repair <signature> -> 0 repaired (caller re-probes), 1 no repair
# allowlisted, 2 repair failed, 75 transport lease busy (retry on next tick). Grow
# the allowlist only with repairs derivable without a human's choice.
env_fault_repair() {
  local env_file="${ENV_FAULT_ENV_FILE:-$AGENT_HOME/env}" login id name tab_status=0
  case "$1" in
    env:git-identity)
      # The pipeline commits as the maintainer's own GitHub account by his
      # explicit decision; GitHub's noreply form (<id>+<login>@users.noreply.
      # github.com) is that account's own attribution address, derivable
      # from the authenticated session, and never a real mailbox. Written
      # ONLY when the key is absent -- a value a human already set is
      # never overwritten -- and only outside version control.
      login="$(gh api user -q '.login' 2>/dev/null)" || return 2
      id="$(gh api user -q '.id' 2>/dev/null)" || return 2
      name="$(gh api user -q '.name // .login' 2>/dev/null)" || name="$login"
      [ -n "$login" ] && [ -n "$id" ] || return 2
      if [ "$DRY_RUN" = "1" ]; then
        echo "[dry-run] env_fault_repair env:git-identity -> append ZF_AGENT_GIT_USER_NAME/EMAIL to $env_file" >&2
        return 0
      fi
      grep -qE '^ZF_AGENT_GIT_USER_NAME=.+' "$env_file" 2>/dev/null \
        || printf 'ZF_AGENT_GIT_USER_NAME=%s\n' "$name" >> "$env_file"
      grep -qE '^ZF_AGENT_GIT_USER_EMAIL=.+' "$env_file" 2>/dev/null \
        || printf 'ZF_AGENT_GIT_USER_EMAIL=%s+%s@users.noreply.github.com\n' "$id" "$login" >> "$env_file"
      return 0
      ;;
    env:codex-binary-missing)
      codex_runtime_self_repair || return 2
      return 0
      ;;
    env:codex-sandbox-probe)
      # 10-28: the marker went missing and nothing re-ran the probe, so recut stayed quarantined.
      bash "$REPO_DIR/engine/probe-codex-sandbox.sh" >/dev/null 2>&1 || return 2
      return 0
      ;;
    env:web-advisor-provider:*)
      # Provider seam: only the web advisor's tab-unresponsive family has a
      # machine repair (providers/web-advisor-provider.sh); other families report no
      # repair allowlisted here.
      web_advisor_provider_env_fault_repair "$1"
      ;;
    *) return 1 ;;
  esac
}

quarantine_file() { echo "$QUARANTINE_DIR/$(env_fault_key "$1").json"; }

# quarantine_notification_should_send <scope> <edge> <now> -- allow one
# quarantine edge notification per scope/window, retaining edge count locally.
quarantine_notification_should_send() {
  agent_pipeline_write_guard quarantine_notification_should_send "$AGENT_HOME" "$QUARANTINE_NOTIFICATION_DIR" || return 1
  local scope="$1" edge="$2" now="$3" f since edges
  f="$QUARANTINE_NOTIFICATION_DIR/$(env_fault_key "quarantine:$scope").json"
  if [ -f "$f" ]; then
    since="$(jq -r '.since // 0' "$f" 2>/dev/null || echo 0)"
    case "$since" in ''|*[!0-9]*) since=0 ;; esac
    if [ "$since" -gt 0 ] && [ $((now - since)) -lt "$QUARANTINE_NOTIFICATION_WINDOW_SECONDS" ]; then
      edges="$(jq -r '.edges // 0' "$f" 2>/dev/null || echo 0)"
      case "$edges" in ''|*[!0-9]*) edges=0 ;; esac
      if ! jq --arg edge "$edge" --argjson edges "$((edges + 1))" --argjson now "$now" \
        '.edges = $edges | .last_edge = $edge | .last_edge_at = $now' "$f" > "$f.tmp" || ! mv "$f.tmp" "$f"; then
        rm -f "$f.tmp"
        echo "quarantine_notification_should_send: could not update $f -- suppressing repeat notification" >&2
      fi
      return 1
    fi
  fi
  mkdir -p "$QUARANTINE_NOTIFICATION_DIR"
  if ! jq -n --arg scope "$scope" --arg edge "$edge" --argjson now "$now" \
    '{scope: $scope, since: $now, edges: 1, last_edge: $edge, last_edge_at: $now}' > "$f.tmp" || ! mv "$f.tmp" "$f"; then
    rm -f "$f.tmp"
    echo "quarantine_notification_should_send: could not create $f -- suppressing notification" >&2
    return 1
  fi
  return 0
}

# quarantine_supervisor_notice <scope> <edge> <detail> -- records one internal
# quarantine notice. Quarantine is pipeline state, never maintainer mail.
quarantine_supervisor_notice() {
  local scope="$1" edge="$2" detail="$3"
  if ! supervisor_inbox_append pipeline-quarantine "scope=$scope edge=$edge detail=$detail"; then
    echo "quarantine_supervisor_notice: could not queue notice in $AGENT_HOME/supervisor-inbox" >&2
    return 1
  fi
}

# The supervisor empties the inbox after reading it, so the inbox alone
# forgets what was already sent; supervisor-inbox.once remembers each key
# for 24 hours (the same trace re-alerted after every wake, 2026-09-29).
supervisor_inbox_append_once() {
  agent_pipeline_write_guard supervisor_inbox_append_once "$AGENT_HOME/supervisor-inbox" "$AGENT_HOME/supervisor-inbox.once" || return 1
  local key="$1" message="$2" inbox="$AGENT_HOME/supervisor-inbox" lock_fd status=0 now cutoff
  local once="$AGENT_HOME/supervisor-inbox.once"
  local kind
  message="${message//$'\n'/ }"
  message="${message//$'\r'/ }"
  message="${message//$'\t'/ }"
  if [ "$DRY_RUN" = 1 ]; then
    echo "[dry-run] supervisor inbox: $message" >&2
    return 0
  fi
  mkdir -p "$(dirname "$inbox")" || return 1
  exec {lock_fd}>>"$inbox.lock" || return 1
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  now="$(date +%s)"
  cutoff=$((now - 86400))
  if ! grep -Fq -- "$key" "$inbox" 2>/dev/null \
    && ! awk -F '\t' -v c="$cutoff" -v k="$key" '$1 >= c && $2 == k { found = 1 } END { exit !found }' "$once" 2>/dev/null; then
    kind="${message%% *}"
    if supervisor_inbox_append "$kind" "$message"; then
      { awk -F '\t' -v c="$cutoff" '$1 >= c' "$once" 2>/dev/null; printf '%s\t%s\n' "$now" "$key"; } > "$once.tmp" \
        && mv -f -- "$once.tmp" "$once" || status=$?
    else
      status=$?
    fi
  fi
  flock -u "$lock_fd"
  exec {lock_fd}>&-
  return "$status"
}

supervisor_hand_owner_status() {
  (($# == 2)) || return 2
  local name="$1" worktree="$2" roster="$AGENT_HOME/night/agents.txt"
  local codex_pid lib_dir row row_name row_worktree ticket
  SUPERVISOR_HAND_OWNER_DETAIL=""
  SUPERVISOR_HAND_OWNER_ERROR=""

  if declare -F land_queue_owner_ticket >/dev/null && ticket="$(land_queue_owner_ticket "$name" "$worktree")"; then
    SUPERVISOR_HAND_OWNER_DETAIL="land queue owns ticket $ticket"
    return 0
  fi

  if [[ -e "$roster" && ! -r "$roster" ]]; then
    SUPERVISOR_HAND_OWNER_ERROR="cannot read running-agent roster $roster"
    return 2
  fi

  if ! declare -F hand_agent_worktree_pid >/dev/null; then
    lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 2
    source "$lib_dir/night/hand-agent-watchdog.sh" || return 2
  fi
  if codex_pid="$(hand_agent_worktree_pid "$worktree")"; then
    SUPERVISOR_HAND_OWNER_DETAIL="live Codex process $codex_pid on $worktree"
    return 0
  fi
  if [ -r "$roster" ]; then
    while IFS= read -r row || [ -n "$row" ]; do
      IFS=$'\t' read -r _ row_name _ _ row_worktree _ <<< "$row"
      [[ "$row_name" == "$name" && -n "$row_worktree" && "$row_worktree" != "$worktree" ]] || continue
      if codex_pid="$(hand_agent_worktree_pid "$row_worktree")"; then
        SUPERVISOR_HAND_OWNER_DETAIL="live Codex process $codex_pid on $row_worktree"
        return 0
      fi
    done < "$roster"
  fi
  return 1
}

supervisor_hand_read_failure_is_transient() {
  grep -Fq 'gh: transient read failed after bounded retry:' "$1" 2>/dev/null
}

supervisor_hand_issue_findings() {
  local state="$1" brief brief_file status=0
  brief="$(advisor_current_brief_md "$state" | jq -r '.brief_md // ""')" || return 1
  brief_file="$(jq_arg_file "$brief")" || return 1
  jq -r --rawfile brief "$brief_file" '
    def section($heading; $value):
      ($value // "" | tostring) as $text
      | select($text != "")
      | "### \($heading)\n\($text)";
    [
      section("Current triage and root-cause brief"; $brief),
      section("Latest pipeline failure or root cause"; .last_failure_reason),
      section("Latest review evidence"; .last_failure_tail),
      section("Repeated review findings"; .run.evidence.review_repeat_recut),
      section("Latest advisor finding"; (.advisor_last_verdict.material // .pending_advisor_verdict.result // .advisor_decision // .model_policy.advisor_decision)),
      section("Advisor merge conditions"; .merge_conditions_md),
      section("Hold release condition"; .hold.release_condition),
      section("External deliverable"; .external_deliverable),
      section("Ops acceptance after release"; .ops_acceptance_after_release),
      section("Latest recut finding"; .recut_refused_reason)
    ] | join("\n\n")
  ' <<< "$state" || status=$?
  rm -f "$brief_file"
  return "$status"
}

# An ops acceptance must verify the deployed SHA and stays held for the supervisor.
supervisor_ops_acceptance_handoff() (
  local n="$1" state="$2" reason="$3" expected_hold="${4:-}" sha location condition lock_fd f
  if [ -n "$expected_hold" ]; then
    f="$(state_file "$n")" || return 1
    exec {lock_fd}>"$f.lock" || return 1
    flock -x "$lock_fd" || return 1
    state="$(state_read "$n")" || return 1
    jq -e --argjson expected "$expected_hold" '.state == "on-hold" and (.hold | del(.aging_window)) == ($expected | del(.aging_window))' <<< "$state" >/dev/null || return 1
  fi
  sha="$(jq -r '.deployed_sha // .ops_acceptance_after_release.release_sha // "unknown"' <<< "$state")" || return 1
  location="$(jq -r '.ops_acceptance_after_release.location // "unknown"' <<< "$state")" || return 1
  condition="$(jq -r '.hold.release_condition // "verify deployed SHA"' <<< "$state")" || return 1
  supervisor_inbox_append_once "ops-acceptance-after-release issue=#$n sha=$sha" \
    "ops-acceptance-after-release issue=#$n status=sha-$sha deployed_sha=$sha location=$location condition=$condition reason=$reason"
)

# Transfer the existing hold brief to the issue before making it schedulable.
# The episode marker makes a failed transition safe to retry on the next tick.
scheduler_requeue_issue() {
  local n="$1" reason="$2" issue_json="${3:-}" context="${4:-}" state findings hold_id marker body owner_status=0 prs rescue_refs
  local hold_kind start_ref="" start_sha="" patch="${7:-.}" matched_pr pr_handoff handoff_data transition_reason="${6:-pipeline-requeue}"
  local old_worktree="${8:-}" expected_hold="${9:-}" old_head old_status hand_name default_tree recorded_tree candidate
  SCHEDULER_REQUEUE_RESULT=failed
  state="$(state_read "$n")" || return 1
  if [ -n "$expected_hold" ] && ! jq -e --argjson expected "$expected_hold" '.state == "on-hold" and (.hold | del(.aging_window)) == ($expected | del(.aging_window))' <<< "$state" >/dev/null; then
    echo "scheduler_requeue_issue: hold for #$n changed before handoff; retry from the current hold" >&2
    return 1
  fi
  if [ -z "$issue_json" ]; then
    issue_json="$(gh issue view "$n" --repo "$REPO" --json state,comments)" || return 1
  fi
  # A previously closed issue must not be made schedulable by a stale handoff.
  if ! jq -e '(.state // "OPEN" | ascii_upcase) == "OPEN"' <<< "$issue_json" >/dev/null; then
    SCHEDULER_REQUEUE_RESULT=closed
    return 0
  fi
  if [ "$(jq -r '.hold.kind // empty' <<< "$state")" = ops-acceptance-after-release ]; then
    supervisor_ops_acceptance_handoff "$n" "$state" "$reason" "$expected_hold" || return 1
    SCHEDULER_REQUEUE_RESULT=held
    return 0
  fi
  if [ "$(jq -r '.state // empty' <<< "$state")" = on-hold ]; then
    supervisor_hold_owner_state "$n" "$(jq -r '.hold.kind // empty' <<< "$state")" || owner_status=$?
    (( owner_status == 0 )) || return 1
    case "$SUPERVISOR_HOLD_OWNER_STATE" in
      queued|running|worktree-live|waiting|blocked) SCHEDULER_REQUEUE_RESULT=owned; return 0 ;;
      none) ;;
      *) return 1 ;;
    esac
  fi
  findings="$(supervisor_hand_issue_findings "$state")" || return 1
  prs="$(gh pr list --repo "$REPO" --head "agent/issue-$n" --state open --json number,url,headRefName)" || return 1
  jq -e 'type == "array"' <<< "$prs" >/dev/null || return 1
  matched_pr="$(jq -r --arg branch "agent/issue-$n" '[.[] | select(.headRefName == $branch)] | length' <<< "$prs")" || return 1
  pr_handoff="$(jq -c --arg branch "agent/issue-$n" '[.[] | select(.headRefName == $branch)][0] // {} | if .number then {open_pr:.number,open_branch:.headRefName} else {} end' <<< "$prs")" || return 1
  hold_kind="$(jq -r '.hold.kind // empty' <<< "$state")" || return 1
  # Include remote rescues created by other checkouts for every handoff kind.
  git_fetch_hand_bounded "$REPO_DIR" "$n" "$([ "$matched_pr" -eq 0 ] || printf 'agent/issue-%s' "$n")" || return 1
  hold_id="${5:-$(jq -r '.hold.created_at // .hold.expires_at // .run.implement_started_at // .state_changed_at // .requeued_at // "unheld"' <<< "$state")}" || return 1
  rescue_refs="$(git -C "$REPO_DIR" for-each-ref --sort=-committerdate --format='%(refname:short)' refs/remotes/origin/rescued/ \
    | awk -v issue="(issue-|hand-)$n" '$0 ~ (issue "([^0-9]|$)") {print}')" || return 1
  if [ -n "$rescue_refs" ]; then
    start_ref="${rescue_refs%%$'\n'*}"
    start_sha="$(git -C "$REPO_DIR" rev-parse --verify "$start_ref^{commit}")" || return 1
    handoff_data="$(jq -cn --arg episode "$hold_id" --arg ref "${start_ref#origin/}" --arg sha "$start_sha" --argjson pr "$pr_handoff" '{episode:$episode,start_ref:$ref,start_sha:$sha} + $pr')"
  else
    handoff_data="$(jq -cn --arg episode "$hold_id" --argjson pr "$pr_handoff" '{episode:$episode} + $pr')"
  fi
  if [ -z "$old_worktree" ]; then
    hand_name="$(jq -r '.hold.holder // empty' <<< "$state")"
    [[ "$hand_name" == hand-* ]] || hand_name="hand-$n"
    default_tree="${ZF_WORKTREE_ROOT:-${HOME:?HOME is not set}/wt}/$hand_name"
    recorded_tree="$(agent_latest_worktree_for_hand "$REPO_DIR" "$hand_name" "$AGENT_HOME/night/hand-registry/$hand_name.json" "$AGENT_HOME/night/$hand_name.report" "$default_tree" 0 2>/dev/null || true)"
    if [ -n "$recorded_tree" ]; then
      old_worktree="$recorded_tree"
    elif [ -e "$default_tree" ]; then
      supervisor_inbox_append_once "handoff-worktree-unusable:$hand_name" \
        "handoff-worktree-unusable issue=#$n worktree=$default_tree" || return 1
      return 1
    fi
  fi
  if [ -d "$old_worktree" ]; then
    agent_worktree_is_usable "$REPO_DIR" "$old_worktree" || return 1
    old_head="$(git -C "$old_worktree" rev-parse --verify HEAD)" || return 1
    old_status="$(git -C "$old_worktree" status --porcelain=v1 --untracked-files=all)" || return 1
    handoff_data="$(jq -c --arg path "$old_worktree" --arg sha "$old_head" --argjson dirty "$([ -n "$old_status" ] && printf true || printf false)" \
      '. + {worktree:$path,worktree_sha:$sha,worktree_dirty:$dirty}' <<< "$handoff_data")" || return 1
  else
    for candidate in "hand/$n" "hand-$n"; do
      old_head="$(git -C "$REPO_DIR" rev-parse --verify "$candidate^{commit}" 2>/dev/null || true)"
      [[ "$old_head" =~ ^[0-9a-f]{40}$ ]] || continue
      git -C "$REPO_DIR" merge-base --is-ancestor "$old_head" origin/main 2>/dev/null && continue
      handoff_data="$(jq -c --arg sha "$old_head" '. + {worktree:"",worktree_sha:$sha,worktree_dirty:false}' <<< "$handoff_data")" || return 1
      break
    done
  fi
  patch+=" | .scheduler_handoff = $handoff_data"
  context+="
Existing PRs: $(jq -c '.' <<< "$prs")
Rescued refs (newest first): ${rescue_refs:-none}"
  marker="<!-- zf-scheduler-handoff issue=$n hold=$hold_id -->"
  if ! hold_comment_has_marker "$issue_json" "$marker"; then
    body="$BOT_DISCLAIMER
The scheduler will resume this issue: $reason.

$findings
$context
$marker"
    guarded_issue_comment "$n" "$body" || return 1
  fi
  if [ "$(jq -r '.state // empty' <<< "$state")" = on-hold ]; then
    state_requeue "$n" release-hold hold-requeue "$patch" "${expected_hold:-$(jq -c '.hold' <<< "$state")}" || return $?
  elif [ "$(jq -r '.state // empty' <<< "$state")" != ready-for-agent ]; then
    state_requeue "$n" "" "$transition_reason" "$patch" || return $?
  else
    state_merge "$n" "$patch" || return $?
  fi
  SCHEDULER_REQUEUE_RESULT=requeued
}

# quarantine_open <scope> <signature> <detail> <hit_count> [now] -- creates
# the quarantine (no-op if one is already open for the scope) and queues one
# supervisor notice per scope/window, not one for every open/lift edge.
quarantine_open() {
  local scope="$1" signature="$2" detail="$3" hits="$4" now="${5:-$(date +%s)}" f
  agent_pipeline_write_guard quarantine_open "$AGENT_HOME" "$QUARANTINE_DIR" || return 1
  f="$(quarantine_file "$scope")"
  [ -f "$f" ] && return 0
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] quarantine_open scope=$scope signature=$signature hits=$hits" >&2
    return 0
  fi
  mkdir -p "$QUARANTINE_DIR"
  # $detail can carry a gate log tail (run-implement.sh's record_env_fault
  # calls, up to 80 lines of build/test output) -- jq_arg_file(), not --arg.
  local detail_file
  detail_file="$(jq_arg_file "$detail")"
  jq -n --arg s "$scope" --arg sig "$signature" --rawfile d "$detail_file" --argjson now "$now" --argjson hits "$hits" \
    --argjson first "$QUARANTINE_CANARY_INITIAL_SECONDS" \
    '{scope: $s, signature: $sig, detail: $d, since: $now, hits: $hits, canaries: 0, next_canary_at: ($now + $first), last_canary_at: null, repair_tried: false}' \
    > "$f.tmp" && mv "$f.tmp" "$f"
  rm -f "$detail_file"
  quarantine_notification_should_send "$scope" open "$now" || return 0
  quarantine_supervisor_notice "$scope" open "$signature hits=$hits $detail" || return 0
}

# quarantine_lift <scope> <why> [now]
quarantine_lift() {
  local scope="$1" why="$2" now="${3:-$(date +%s)}" f signature lock_fd episode_id
  agent_pipeline_write_guard quarantine_lift "$AGENT_HOME" "$QUARANTINE_DIR" || return 1
  f="$(quarantine_file "$scope")"
  [ -f "$f" ] || return 0
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] quarantine_lift scope=$scope why=$why" >&2
    return 0
  fi
  signature="$(jq -r '.signature // empty' "$f" 2>/dev/null || true)"
  if [ "$signature" = env:main-ci-red ]; then
    mkdir -p "$AGENT_HOME/locks" || return 1
    exec {lock_fd}>"$AGENT_HOME/locks/main-ci-red.lock" || return 1
    flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
    [ -f "$f" ] || { unlock_fd "$lock_fd"; return 0; }
    episode_id="$(main_ci_red_episode_ensure_open_event "$f")" || { unlock_fd "$lock_fd"; return 1; }
    main_ci_red_episode_append_lift "$f" "$episode_id" "$why" "$now" || { unlock_fd "$lock_fd"; return 1; }
    rm -f "$f" || { unlock_fd "$lock_fd"; return 1; }
    unlock_fd "$lock_fd"
  else
    rm -f "$f"
  fi
  quarantine_notification_should_send "$scope" lift "$now" || return 0
  quarantine_supervisor_notice "$scope" lift "$why" || return 0
}

# quarantine_decision <scope> [now] -> "clear" (no quarantine), "canary"
# (quarantined, but a probe dispatch is due now), "open" (blocked).
quarantine_decision() {
  local scope="$1" now="${2:-$(date +%s)}" f next signature
  f="$(quarantine_file "$scope")"
  [ -f "$f" ] || { echo clear; return 0; }
  signature="$(jq -r '.signature // empty' "$f" 2>/dev/null)"
  # Capacity gates and operator pauses (ops:*) lift on their own condition, never
  # on a timed probe: the 2026-10-02 advisor pause would have re-sent answered
  # tickets to the web advisor at its first canary.
  case "$signature" in
    env:ci-runner-capacity|env:build-capacity|env:main-ci-red|ops:*) echo open; return 0 ;;
  esac
  next="$(jq -r '.next_canary_at // 0' "$f" 2>/dev/null || echo 0)"
  if [ "$now" -ge "$next" ]; then echo canary; else echo open; fi
}

# Open main-red quarantine records only paths proved by the failing run. A
# pre-scope or unparseable episode remains a full implement block.
main_ci_red_episode_file() {
  echo "$QUARANTINE_DIR/main-ci-red-episodes.jsonl"
}

main_ci_red_episode_has_open() {
  local episode_id="$1" file
  file="$(main_ci_red_episode_file)"
  [ -f "$file" ] && jq -s -e --arg id "$episode_id" 'any(.[]; .event == "open" and .episode_id == $id)' "$file" >/dev/null 2>&1
}

main_ci_red_episode_has_lift() {
  local episode_id="$1" file
  file="$(main_ci_red_episode_file)"
  [ -f "$file" ] && jq -s -e --arg id "$episode_id" 'any(.[]; .event == "lift" and .episode_id == $id)' "$file" >/dev/null 2>&1
}

main_ci_red_episode_append_open() {
  local record_file="$1" snapshot="$2" file
  file="$(main_ci_red_episode_file)"
  mkdir -p "$QUARANTINE_DIR" || return 1
  jq -cn --slurpfile r "$record_file" --argjson snapshot "$snapshot" '
    $r[0] as $r
    | {event:"open", episode_id:$r.episode_id, opened_at:$r.since,
       recorded_at:($snapshot.captured_at // $r.since), quarantine_signature:$r.signature,
       detail:$r.detail, failed_run_ids:[$r.main_run_ids[]? | select(. != 0)],
       failed_signatures:($r.failed_test_ids // []), blocked_paths:($r.blocked_paths // []),
       blocked_epics:($r.blocked_epics // []), scope_known:($r.scope_known == true),
       full_block:($r.full_block == true), candidate_snapshot:$snapshot}
  ' >> "$file"
}

main_ci_red_episode_append_scope() {
  local record_file="$1" detail="$2" now="$3" event="${4:-extend}" file detail_file status
  file="$(main_ci_red_episode_file)"
  detail_file="$(jq_arg_file "$detail")" || return 1
  jq -cn --slurpfile r "$record_file" --rawfile detail "$detail_file" --arg event "$event" --argjson now "$now" '
    $r[0] as $r
    | {event:$event, episode_id:$r.episode_id, recorded_at:$now, detail:$detail,
       failed_run_ids:[$r.main_run_ids[]? | select(. != 0)],
       failed_signatures:($r.failed_test_ids // []), blocked_paths:($r.blocked_paths // []),
       blocked_epics:($r.blocked_epics // []), scope_known:($r.scope_known == true),
       full_block:($r.full_block == true)}
  ' >> "$file"
  status=$?
  rm -f "$detail_file"
  return "$status"
}

main_ci_red_episode_append_lift() {
  local record_file="$1" episode_id="$2" why="$3" now="$4" file tmp status
  main_ci_red_episode_has_lift "$episode_id" && return 0
  file="$(main_ci_red_episode_file)"
  tmp="$(jq_arg_file "$why")" || return 1
  jq -cn --slurpfile r "$record_file" --rawfile reason "$tmp" --arg id "$episode_id" --argjson now "$now" '
    $r[0] as $r
    | {event:"lift", episode_id:$id, lifted_at:$now, reason:$reason,
       failed_run_ids:[$r.main_run_ids[]? | select(. != 0)],
       failed_signatures:($r.failed_test_ids // [])}
  ' >> "$file"
  status=$?
  rm -f "$tmp"
  return "$status"
}

# Legacy active quarantines predate the episode ledger. Preserve their known
# open/lift edge, but never invent the candidate snapshot they did not retain.
main_ci_red_episode_ensure_open_event() {
  local record_file="$1" record episode_id since run_id tmp
  record="$(cat -- "$record_file")" || return 1
  episode_id="$(jq -r '.episode_id // empty' <<< "$record")"
  if [ -z "$episode_id" ]; then
    since="$(jq -r '.since // 0' <<< "$record")"
    run_id="$(jq -r '[.main_run_ids[]? | select(. != 0)][0] // empty' <<< "$record")"
    if [ -z "$run_id" ]; then
      run_id="$(sed -nE 's/.*main ci\.yml push run ([1-9][0-9]*).*/\1/p' <<< "$(jq -r '.detail // ""' <<< "$record")" | head -n 1)"
    fi
    [ -n "$run_id" ] || run_id=unknown
    episode_id="main-ci-red-$since-$run_id"
    tmp="$record_file.tmp.$$"
    jq --arg id "$episode_id" '.episode_id = $id' "$record_file" > "$tmp" \
      && mv -f "$tmp" "$record_file" || { rm -f "$tmp"; return 1; }
  fi
  if ! main_ci_red_episode_has_open "$episode_id"; then
    main_ci_red_episode_append_open "$record_file" \
      '{"status":"unknown","captured_at":null,"candidates":[]}' || return 1
  fi
  printf '%s\n' "$episode_id"
}

main_ci_red_candidate_snapshot() {
  local issues roadmap_flat='' snapshot_status=complete rows_file issue issue_id state body labels surface
  local expected_paths expected_packages package_labels epic scope_known
  if ! issues="$(gh issue list --repo "$REPO" --limit 1000 --label ready-for-agent --state open \
    --json number,body,labels 2>/dev/null)" \
    || ! jq -e 'type == "array" and all(.[]; (.number | type) == "number" and (.labels | type) == "array")' \
      >/dev/null 2>&1 <<< "$issues"; then
    jq -cn '{status:"unknown",captured_at:null,candidates:[]}'
    return 0
  fi
  [ "$(jq 'length' <<< "$issues")" -lt 1000 ] || snapshot_status=truncated
  if [ -n "${ZF_ROADMAP_TREE_CACHE_FILE:-}" ] && [ -r "$ZF_ROADMAP_TREE_CACHE_FILE" ]; then
    roadmap_flat="$(roadmap_flatten "$(cat -- "$ZF_ROADMAP_TREE_CACHE_FILE")" 2>/dev/null || true)"
  fi
  rows_file="$(mktemp)" || { jq -cn '{status:"unknown",captured_at:null,candidates:[]}'; return 0; }
  while IFS= read -r issue; do
    issue_id="$(jq -r '.number' <<< "$issue")"
    [[ "$issue_id" =~ ^[1-9][0-9]*$ ]] || { snapshot_status=unknown; continue; }
    state="$(state_read "$issue_id" 2>/dev/null || echo '{}')"
    body="$(jq -r '.body // ""' <<< "$issue")"
    labels="$(jq -c '.labels // []' <<< "$issue")"
    surface="$(issue_change_surface_json "$state" "$body" "$labels" 2>/dev/null || echo '[]')"
    expected_paths="$(jq -c 'if (.expected_paths | type) == "array" then .expected_paths else "UNKNOWN" end' <<< "$state" 2>/dev/null || echo '"UNKNOWN"')"
    expected_packages="$(jq -c 'if (.expected_packages | type) == "array" then .expected_packages else "UNKNOWN" end' <<< "$state" 2>/dev/null || echo '"UNKNOWN"')"
    package_labels="$(jq -c '[.[]?.name | select(startswith("pkg:") or startswith("package:"))] | unique' <<< "$labels" 2>/dev/null || echo '[]')"
    epic=UNKNOWN
    if [ -n "$roadmap_flat" ]; then
      epic="$(jq -r --argjson n "$issue_id" '
        . as $nodes
        | [$nodes[] | select(.number == $n)][0] as $ticket
        | if $ticket == null then "NONE"
          else ([ $nodes[] | select(.number == $ticket.parent and .depth == 2 and (.labels | index("roadmap-epic") != null)) ][0].number // "NONE" | tostring)
          end
      ' <<< "$roadmap_flat" 2>/dev/null || echo UNKNOWN)"
    fi
    scope_known=false
    if jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and length > 0 and (startswith("/") | not) and ((split("/") | index("..")) == null))' \
      >/dev/null 2>&1 <<< "$surface"; then scope_known=true; fi
    jq -cn --argjson issue_id "$issue_id" --argjson expected_paths "$expected_paths" \
      --argjson expected_packages "$expected_packages" --argjson package_labels "$package_labels" \
      --argjson surface "$surface" --argjson scope_known "$scope_known" --arg epic "$epic" '
      {issue_id:$issue_id,expected_paths:$expected_paths,expected_packages:$expected_packages,
       package_labels:$package_labels,roadmap_epic:(if $epic == "UNKNOWN" then "UNKNOWN" elif $epic == "NONE" then null else ($epic | tonumber) end),
       surface:$surface,scope_known:$scope_known}
    ' >> "$rows_file" || snapshot_status=unknown
  done < <(jq -c '.[]' <<< "$issues")
  jq -sc --arg status "$snapshot_status" --argjson captured_at "$(date +%s)" \
    '{status:$status,captured_at:$captured_at,candidates:.}' "$rows_file"
  local status=$?
  rm -f "$rows_file"
  return "$status"
}

main_ci_red_scope_extend() {
  local run_id="$1" paths_json="$2" test_ids_json="$3" candidate_surface="$4" epic="${5:-}" detail="$6" upgrade="${7:-false}"
  local f had_record known lock_fd tmp detail_file candidate_snapshot episode_id prior_episode_id prior_scope current_scope
  local had_delta=0 wrote_open=0 episode_since episode_run
  f="$(quarantine_file implement)"
  had_record=0
  [ -f "$f" ] && had_record=1
  [ "$upgrade" != true ] || [ "$had_record" = 1 ] || return 1
  quarantine_open implement env:main-ci-red "$detail" 1 || return 1
  candidate_snapshot='{"status":"unknown","captured_at":null,"candidates":[]}'
  if [ "$had_record" = 0 ] && [ "$upgrade" != true ]; then
    candidate_snapshot="$(main_ci_red_candidate_snapshot)" || candidate_snapshot='{"status":"unknown","captured_at":null,"candidates":[]}'
  fi
  if ! jq -e 'type == "array" and all(.[]; type == "string")' <<< "$test_ids_json" >/dev/null 2>&1; then test_ids_json='[]'; fi
  if jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and length > 0 and (startswith("/") | not) and ((split("/") | index("..")) == null))' \
    <<< "$paths_json" >/dev/null 2>&1 \
    && jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and length > 0)' <<< "$test_ids_json" >/dev/null 2>&1; then
    known=true
  else
    known=false
    paths_json='[]'
    test_ids_json='[]'
  fi
  if ! jq -e 'type == "array" and all(.[]; type == "string")' <<< "$candidate_surface" >/dev/null 2>&1; then candidate_surface='[]'; fi
  mkdir -p "$AGENT_HOME/locks" || return 1
  exec {lock_fd}>"$AGENT_HOME/locks/main-ci-red.lock" || return 1
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  prior_episode_id="$(jq -r '.episode_id // empty' "$f" 2>/dev/null || true)"
  prior_scope="$(jq -c '{scope_known:(.scope_known // null),full_block:(.full_block // false),blocked_paths:(.blocked_paths // []),blocked_epics:(.blocked_epics // []),failed_test_ids:(.failed_test_ids // []),main_run_ids:(.main_run_ids // [])}' "$f")"
  episode_id="$prior_episode_id"
  if [ -z "$episode_id" ]; then
    episode_since="$(jq -r '.since // 0' "$f")"
    episode_run="$(jq -r --argjson run "$run_id" '[.main_run_ids[]? | select(. != 0)][0] // $run' "$f")"
    [[ "$episode_run" =~ ^[1-9][0-9]*$ ]] || episode_run=unknown
    episode_id="main-ci-red-$episode_since-$episode_run"
  fi
  tmp="$f.tmp.$$"
  detail_file="$(jq_arg_file "$detail")" || { unlock_fd "$lock_fd"; return 1; }
  if ! jq --argjson new "$((1 - had_record))" --argjson known "$known" \
    --argjson paths "$paths_json" --argjson tests "$test_ids_json" \
    --argjson run "$run_id" --arg epic "$epic" --rawfile detail "$detail_file" \
    --argjson surface "$candidate_surface" --argjson upgrade "$upgrade" --arg episode "$episode_id" '
    def overlaps($left; $right):
      any($left[]; . as $a | any($right[]; . as $b |
        $a == $b or ($a | startswith($b + "/")) or ($b | startswith($a + "/"))));
    if $upgrade and .detail != $detail then error("main-red quarantine changed during scope upgrade") else . end
    | . as $record
    | ($record.blocked_paths // []) as $old_paths
    | (($old_paths + $paths) | unique) as $all_paths
    | (if ($epic | test("^[1-9][0-9]*$")) and $known and overlaps($all_paths; $surface)
       then ((($record.blocked_epics // []) + [$epic]) | unique)
       else ($record.blocked_epics // []) end) as $epics
    | .scope_known = (if $upgrade and $known then true elif has("scope_known") then (.scope_known == true and $known) else ($new == 1 and $known) end)
    | .full_block = ((.full_block // false) or ($known | not) or ($new == 0 and ($record.scope_known? == null) and ($upgrade | not)))
    | .blocked_paths = $all_paths
    | .failed_test_ids = ((.failed_test_ids // []) + $tests | unique)
    | .main_run_ids = ((.main_run_ids // []) + [$run] | unique)
    | .blocked_epics = $epics
    | .episode_id = (.episode_id // $episode)
  ' "$f" > "$tmp"; then
    rm -f "$tmp"
    rm -f "$detail_file"
    unlock_fd "$lock_fd"
    return 1
  fi
  rm -f "$detail_file"
  if ! mv -f "$tmp" "$f"; then
    rm -f "$tmp"
    unlock_fd "$lock_fd"
    return 1
  fi
  current_scope="$(jq -c '{scope_known:(.scope_known // null),full_block:(.full_block // false),blocked_paths:(.blocked_paths // []),blocked_epics:(.blocked_epics // []),failed_test_ids:(.failed_test_ids // []),main_run_ids:(.main_run_ids // [])}' "$f")"
  [ "$current_scope" = "$prior_scope" ] || had_delta=1
  episode_id="$(jq -r '.episode_id' "$f")"
  if ! main_ci_red_episode_has_open "$episode_id"; then
    main_ci_red_episode_append_open "$f" "$candidate_snapshot" || { unlock_fd "$lock_fd"; return 1; }
    wrote_open=1
  fi
  if [ "$wrote_open" = 0 ] && [ "$had_delta" = 1 ]; then
    main_ci_red_episode_append_scope "$f" "$detail" "$(date +%s)" || { unlock_fd "$lock_fd"; return 1; }
  fi
  unlock_fd "$lock_fd"
}

# Upgrade old main-red records once from their recorded failed run. Any missing
# log, issue surface, or test path leaves the legacy full-lane block in place.
main_ci_red_hydrate_scope() {
  local f detail run_id fault_file issue log test_ids paths issue_json surface flat epic
  f="$(quarantine_file implement)"
  [ -f "$f" ] || return 1
  detail="$(jq -r 'select(.signature == "env:main-ci-red" and .scope_known == null and (.full_block // false) != true) | .detail // empty' "$f" 2>/dev/null)"
  [ -n "$detail" ] || return 1
  run_id="$(sed -nE 's/.*main ci\.yml push run ([0-9]+).*/\1/p' <<< "$detail" | head -n 1)"
  [[ "$run_id" =~ ^[1-9][0-9]*$ ]] || {
    main_ci_red_scope_extend 0 '[]' '[]' '[]' '' "$detail" || true
    return 1
  }
  fault_file="$ENV_FAULT_DIR/$(env_fault_key env:main-ci-red).log"
  issue="$(awk -F '\t' -v d="$detail" '$4 == "env:main-ci-red" && $5 == d { number=$3 } END { print number }' "$fault_file" 2>/dev/null)"
  if [[ ! "$issue" =~ ^[1-9][0-9]*$ ]] \
    || ! log="$(gh run view "$run_id" --repo "$REPO" --log-failed 2>/dev/null)" \
    || ! issue_json="$(gh issue view "$issue" --repo "$REPO" --json body,labels 2>/dev/null)"; then
    main_ci_red_scope_extend "$run_id" '[]' '[]' '[]' '' "$detail" || true
    return 1
  fi
  test_ids="$(ci_failed_test_ids "$log" | cut -f2- | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')"
  paths="$(ci_failed_test_scope_from_log "$log")"
  surface="$(issue_change_surface_json "$(state_read "$issue")" \
    "$(jq -r '.body // ""' <<< "$issue_json")" "$(jq -c '.labels // []' <<< "$issue_json")")"
  epic=""
  if [ -n "${ZF_ROADMAP_TREE_CACHE_FILE:-}" ] && [ -r "$ZF_ROADMAP_TREE_CACHE_FILE" ]; then
    flat="$(roadmap_flatten "$(cat -- "$ZF_ROADMAP_TREE_CACHE_FILE")" 2>/dev/null || echo '[]')"
    epic="$(jq -r --argjson n "$issue" '
      . as $nodes | ($nodes[] | select(.number == $n)) as $ticket
      | [$nodes[] | select(.number == $ticket.parent and .depth == 2 and (.labels | index("roadmap-epic") != null))][0].number // empty
    ' <<< "$flat" 2>/dev/null || true)"
  fi
  main_ci_red_scope_extend "$run_id" "$paths" "$test_ids" "$surface" "$epic" "$detail" true
}

# main_ci_red_candidate_allowed <surface-json> [roadmap-epic] -> 0 only when
# both sides have known scope and neither paths/packages nor epic overlap.
main_ci_red_candidate_allowed() {
  local surface="${1:-[]}" epic="${2:-}" f
  f="$(quarantine_file implement)"
  [ -f "$f" ] || return 0
  [ "$(jq -r '.signature // empty' "$f" 2>/dev/null)" = env:main-ci-red ] || return 0
  if jq -e '.scope_known == null and (.full_block // false) != true' "$f" >/dev/null 2>&1; then
    main_ci_red_hydrate_scope || return 1
  fi
  f="$(quarantine_file implement)"
  jq -e --argjson surface "$surface" --arg epic "$epic" '
    def safe_path:
      type == "string" and length > 0 and (startswith("/") | not)
      and ((split("/") | index("..")) == null);
    def overlaps($left; $right):
      any($left[]; . as $a | any($right[]; . as $b |
        $a == $b or ($a | startswith($b + "/")) or ($b | startswith($a + "/"))));
    .scope_known == true
    and (.full_block // false) != true
    and (.blocked_paths | type == "array" and length > 0 and all(.[]; safe_path))
    and ($surface | type == "array" and length > 0 and all(.[]; safe_path))
    and ((.blocked_epics // []) | if length == 0 then true else ($epic != "" and index($epic) == null) end)
    and (overlaps(.blocked_paths; $surface) | not)
  ' "$f" >/dev/null 2>&1
}

# Count distinct tickets actually started during scoped main-red quarantine.
# Failed PRs count only when they later repeat a test id recorded at dispatch.
main_ci_red_record_dispatch() {
  local issue="$1" surface="${2:-[]}" epic="${3:-}" f lock_fd tmp
  f="$(quarantine_file implement)"
  [ -f "$f" ] || return 0
  [ "$(jq -r '.signature // empty' "$f" 2>/dev/null)" = env:main-ci-red ] || return 0
  if ! main_ci_red_candidate_allowed "$surface" "$epic"; then
    STAGE_DISPATCH_BLOCKING_SCOPES=implement
    return 1
  fi
  mkdir -p "$AGENT_HOME/locks" || return 1
  exec {lock_fd}>"$AGENT_HOME/locks/main-ci-red.lock" || return 1
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  tmp="$f.tmp.$$"
  if ! jq --arg issue "$issue" --argjson surface "$surface" --arg epic "$epic" '
    def overlaps($left; $right):
      any($left[]; . as $a | any($right[]; . as $b |
        $a == $b or ($a | startswith($b + "/")) or ($b | startswith($a + "/"))));
    select(.scope_known == true and (.full_block // false) != true
      and (.blocked_paths | type == "array" and length > 0)
      and ($surface | type == "array" and length > 0)
      and ((.blocked_epics // []) | if length == 0 then true else ($epic != "" and index($epic) == null) end)
      and (overlaps(.blocked_paths; $surface) | not))
    | (.failed_test_ids // []) as $tests
    | .scoped_dispatches = ((.scoped_dispatches // []) | if any(.[]; .issue == $issue)
      then map(if .issue == $issue then .test_ids = (((.test_ids // []) + $tests) | unique) else . end)
      else . + [{issue:$issue,test_ids:$tests}] end)
  ' "$f" > "$tmp"; then
    rm -f "$tmp"
    unlock_fd "$lock_fd"
    return 1
  fi
  if ! mv -f "$tmp" "$f"; then
    rm -f "$tmp"
    unlock_fd "$lock_fd"
    return 1
  fi
  unlock_fd "$lock_fd"
}

main_ci_red_record_same_signature_failure() {
  local issue="$1" test_id="$2" f lock_fd tmp prior_full_block current_full_block episode_id
  f="$(quarantine_file implement)"
  [ -f "$f" ] || return 0
  [ "$(jq -r '.signature // empty' "$f" 2>/dev/null)" = env:main-ci-red ] || return 0
  mkdir -p "$AGENT_HOME/locks" || return 1
  exec {lock_fd}>"$AGENT_HOME/locks/main-ci-red.lock" || return 1
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  prior_full_block="$(jq -r '.full_block // false' "$f")"
  tmp="$f.tmp.$$"
  if ! jq --arg issue "$issue" --arg test "$test_id" '
    if any(.scoped_dispatches[]?; .issue == $issue and ((.test_ids // []) | index($test) != null)) then
      .same_signature_failures = (((.same_signature_failures // []) + [$issue]) | unique)
    else . end
    | ((.scoped_dispatches // []) | map(.issue) | unique | length) as $runs
    | ((.same_signature_failures // []) | length) as $failures
    # One repeat at the five-ticket minimum is 20%; it triggers quickly without
    # letting a single low-sample miss trip the global fallback.
    | if $runs >= 5 and ($failures / $runs) > 0.10 then .full_block = true else . end
  ' "$f" > "$tmp"; then
    rm -f "$tmp"
    unlock_fd "$lock_fd"
    return 1
  fi
  if ! mv -f "$tmp" "$f"; then
    rm -f "$tmp"
    unlock_fd "$lock_fd"
    return 1
  fi
  current_full_block="$(jq -r '.full_block // false' "$f")"
  if [ "$prior_full_block" != true ] && [ "$current_full_block" = true ]; then
    episode_id="$(jq -r '.episode_id // empty' "$f")"
    if [ -n "$episode_id" ]; then
      main_ci_red_episode_append_scope "$f" 'same-signature failure threshold tripped' "$(date +%s)" fallback \
        || { unlock_fd "$lock_fd"; return 1; }
    fi
  fi
  unlock_fd "$lock_fd"
}

# quarantine_mark_canary <scope> [now] -- one dispatch was let through;
# the next canary is due after an exponentially longer wait (capped), so a
# second candidate this same tick already sees "open".
quarantine_mark_canary() {
  local scope="$1" now="${2:-$(date +%s)}" f canaries wait
  agent_pipeline_write_guard quarantine_mark_canary "$AGENT_HOME" "$QUARANTINE_DIR" || return 1
  f="$(quarantine_file "$scope")"
  [ -f "$f" ] || return 0
  [ "$DRY_RUN" = "1" ] && { echo "[dry-run] quarantine_mark_canary scope=$scope" >&2; return 0; }
  canaries="$(jq -r '.canaries // 0' "$f")"
  wait=$((QUARANTINE_CANARY_INITIAL_SECONDS * (1 << (canaries + 1))))
  [ "$wait" -gt "$QUARANTINE_CANARY_MAX_SECONDS" ] && wait="$QUARANTINE_CANARY_MAX_SECONDS"
  jq --argjson now "$now" --argjson wait "$wait" \
    '.canaries = ((.canaries // 0) + 1) | .last_canary_at = $now | .next_canary_at = ($now + $wait)' \
    "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# quarantine_scopes_for <stage> <expected_packages_json> -> every quarantine
# scope that would block this dispatch: the stage-wide one, plus any
# package-scoped one whose package the candidate's expected_packages touch
# (same prefix rule as gate 4, via path_in_expected_packages).
quarantine_scopes_for() {
  local stage="$1" expected_json="${2:-[]}" f scope pkg
  echo "$stage"
  [ -d "$QUARANTINE_DIR" ] || return 0
  for f in "$QUARANTINE_DIR"/*.json; do
    [ -f "$f" ] || continue
    scope="$(jq -r '.scope // empty' "$f" 2>/dev/null)"
    case "$scope" in
      "$stage@"*) pkg="${scope#*@}" ;;
      *) continue ;;
    esac
    path_in_expected_packages "$expected_json" "$pkg" && echo "$scope"
  done
}

# stage_dispatch_allowed <stage> [expected_packages_json] [now] [red_surface_json] [roadmap_epic] -> 0 if the
# scheduler may dispatch this candidate now (marking a canary when that is
# what lets it through), 1 if a quarantine blocks it. Logs once per
# blocked candidate.
stage_dispatch_allowed() {
  local stage="$1" expected_json="${2:-[]}" now="${3:-$(date +%s)}" red_surface="${4:-${2:-[]}}" epic="${5:-}" scope decision blocked=0
  local -a canary_scopes=()
  STAGE_DISPATCH_BLOCKING_SCOPES=""
  while IFS= read -r scope; do
    [ -z "$scope" ] && continue
    if [ "$stage" = implement ] && [ "$scope" = implement ] \
      && [ "$(jq -r '.signature // empty' "$(quarantine_file implement)" 2>/dev/null)" = env:main-ci-red ]; then
      if main_ci_red_candidate_allowed "$red_surface" "$epic"; then
        continue
      fi
      blocked=1
      STAGE_DISPATCH_BLOCKING_SCOPES="${STAGE_DISPATCH_BLOCKING_SCOPES:+$STAGE_DISPATCH_BLOCKING_SCOPES、}$scope"
      continue
    fi
    decision="$(quarantine_decision "$scope" "$now")"
    case "$decision" in
      clear) ;;
      canary) canary_scopes+=("$scope") ;;
      open)
        blocked=1
        STAGE_DISPATCH_BLOCKING_SCOPES="${STAGE_DISPATCH_BLOCKING_SCOPES:+$STAGE_DISPATCH_BLOCKING_SCOPES、}$scope" ;;
    esac
  done < <(quarantine_scopes_for "$stage" "$expected_json")
  if [ "$blocked" = "1" ]; then
    echo "issue-pipeline: $stage dispatch blocked by an open quarantine (env fault); see $QUARANTINE_DIR" >&2
    return 1
  fi
  for scope in "${canary_scopes[@]:-}"; do
    [ -z "$scope" ] && continue
    echo "issue-pipeline: $stage dispatch let through as a canary for quarantine $scope" >&2
    quarantine_mark_canary "$scope" "$now"
  done
  return 0
}

# legs_executable_check -- once per tick, before reconcile_quarantines: is
# every leg's wrapper actually executable in the checkout this tick runs
# from? 2026-09-15 01:06:32, zf-advisor-1131.service: the advisor leg's
# first-ever automatic dispatch died at `status=203/EXEC` -- run-advisor.sh
# had been committed without its executable bit, so systemd could not spawn
# it, before a line of its logic ran; every needs-advisor ticket would have
# failed identically every tick, and a failed unit looks the same whether
# the leg refused the ticket or never ran. A leg that cannot execute is an
# OUTAGE: it opens a stage quarantine under a signature with a probe (the
# mode bit itself), which lifts on the tick after the fix lands, and records
# the fault locally -- distinguishable from a verdict by construction.
legs_executable_check() {
  local stage script
  # run-release.sh is not shipped: release is a hook here, not a leg.
  for stage in triage advisor recut; do
    script="$REPO_DIR/engine/run-$stage.sh"
    [ -x "$script" ] && continue
    echo "issue-pipeline: leg $stage cannot execute -- $script is not executable (git mode bit); this is an outage, not a verdict" >&2
    quarantine_open "$stage" "env:leg-not-executable:$stage" "$script is not executable in the checkout this tick runs from (the file's git mode bit is missing)" 1
  done
}

# reconcile_quarantines [now] -- once per tick, before any dispatch:
#   (a) open a quarantine for every signature that turned systemic since
#       its scope was last quarantined (or was never);
#   (b) for every open quarantine: probe -> lift; else repair once ->
#       re-probe -> lift; else if a canary went through and no new fault
#       followed within the grace period -> lift ("canary survived"). An
#       advisor canary is asynchronous: its pending web-advisor-provider job must be
#       polled before silence can count as survival.
reconcile_quarantines() {
  local now="${1:-$(date +%s)}" f signature scope hits detail last_canary repair_tried newer probe_rc repair_rc
  if [ -d "$ENV_FAULT_DIR" ]; then
    for f in "$ENV_FAULT_DIR"/*.log; do
      [ -f "$f" ] || continue
      signature="$(tail -n 1 "$f" | cut -f4)"
      [ -n "$signature" ] || continue
      # These signatures are opened at the observed gate and lifted by their
      # live probe. Generic history replay would reopen a recovered episode.
      case "$signature" in
        env:model-config:*|env:ci-runner-capacity|env:build-capacity|env:main-ci-red|env:provider-outage|env:unit-memory-cap|env:ci-checkout|env:docker-hub-dns) continue ;;
      esac
      env_fault_is_systemic "$signature" "$now" || continue
      if [ "$signature" = "env:network-timeout" ]; then
        # Require both repeated ticket failures and a current API probe
        # failure. A successful or unavailable probe keeps the timeout at
        # per-call scope; unknown is not evidence for blocking a whole stage.
        probe_rc=0
        env_fault_probe "$signature" || probe_rc=$?
        [ "$probe_rc" -eq 1 ] || continue
      fi
      scope="$(env_fault_latest_scope "$signature")"
      [ -n "$scope" ] || continue
      hits="$(env_fault_lines_since "$signature" "$((now - ENV_FAULT_WINDOW_SECONDS))" | wc -l)"
      detail="$(tail -n 1 "$f" | cut -f5)"
      quarantine_open "$scope" "$signature" "$detail" "$hits" "$now"
    done
  fi
  [ -d "$QUARANTINE_DIR" ] || return 0
  for f in "$QUARANTINE_DIR"/*.json; do
    [ -f "$f" ] || continue
    scope="$(jq -r '.scope // empty' "$f")"
    signature="$(jq -r '.signature // empty' "$f")"
    last_canary="$(jq -r '.last_canary_at // empty' "$f")"
    repair_tried="$(jq -r '.repair_tried // false' "$f")"
    [ -n "$scope" ] && [ -n "$signature" ] || continue
    # `|| probe_rc=$?` on purpose: the callers run under `set -e`, and a
    # bare probe returning 1 ("still broken", the common case) would
    # otherwise abort the whole tick.
    probe_rc=0
    env_fault_probe "$signature" || probe_rc=$?
    case "$probe_rc" in
      0) quarantine_lift "$scope" "探测通过（$signature 已不再出现）" "$now"; continue ;;
      1)
        if [ "$repair_tried" != "true" ]; then
          repair_rc=0
          env_fault_repair "$signature" || repair_rc=$?
          if [ "$repair_rc" -ne 75 ]; then
            jq '.repair_tried = true' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
          fi
          if [ "$repair_rc" = "0" ]; then
            probe_rc=0
            env_fault_probe "$signature" || probe_rc=$?
            if [ "$probe_rc" = "0" ]; then
              quarantine_lift "$scope" "机器自动修复后探测通过（$signature）" "$now"
              continue
            fi
          fi
        fi
        ;;
      *) ;;
    esac
    if [ -n "$last_canary" ] && [ "$((now - last_canary))" -ge "$QUARANTINE_CANARY_GRACE_SECONDS" ]; then
      # A dispatched advisor web job has not tested recovery until its own
      # result is consumed. The scheduler admits that poll independently of
      # this quarantine; until then, silence only means nobody has learned
      # whether the canary passed.
      if [ "$scope" = "advisor" ] && [ -n "$(web_advisor_provider_job_candidates)" ]; then
        continue
      fi
      newer="$(env_fault_lines_since "$signature" "$last_canary" | wc -l)"
      if [ "$newer" -eq 0 ]; then
        quarantine_lift "$scope" "试探派发后 $((QUARANTINE_CANARY_GRACE_SECONDS / 60)) 分钟内没有再出现同一故障（$signature）" "$now"
        continue
      fi
    fi
  done
}

# Every dispatched role records spend after its call. The ledger is reporting
# only; policy, not spend data, controls identity and escalation.

SPEND_DIR="$AGENT_HOME/spend"
CODEX_PROBE_MARKER="$AGENT_HOME/codex-probe-passed"

spend_file_for_day() { echo "$SPEND_DIR/$(date -u -d "@$1" +%Y-%m-%d).log"; }

# issue_spend_budget_status <issue> [now] -> clear|over|unknown<TAB>calls<TAB>tokens.
# The sixth ledger field is a floor when older producers left it empty. Batch
# rows count once for every member issue because each member paid for that call.
ISSUE_CALL_BUDGET_THRESHOLD="${ISSUE_CALL_BUDGET_THRESHOLD:-10}"
ISSUE_TOKEN_BUDGET_THRESHOLD="${ISSUE_TOKEN_BUDGET_THRESHOLD:-2200000}"
issue_spend_budget_status() {
  local n="$1" now="${2:-$(date +%s)}" since today yesterday rows="" file contents result status calls tokens
  [[ "$n" =~ ^[1-9][0-9]*$ && "$now" =~ ^[0-9]+$ \
    && "$ISSUE_CALL_BUDGET_THRESHOLD" =~ ^[1-9][0-9]*$ \
    && "$ISSUE_TOKEN_BUDGET_THRESHOLD" =~ ^[1-9][0-9]*$ ]] || return 2
  since=$((now - 86400))
  today="$(spend_file_for_day "$now")"
  yesterday="$(spend_file_for_day "$since")"
  if [ -e "$SPEND_DIR" ] && { [ ! -d "$SPEND_DIR" ] || [ ! -r "$SPEND_DIR" ] || [ ! -x "$SPEND_DIR" ]; }; then
    printf 'unknown\t0\t0\n'
    return 0
  fi
  for file in "$today" "$yesterday"; do
    [ -e "$file" ] || continue
    if [ ! -f "$file" ] || ! contents="$(cat "$file" 2>/dev/null)"; then
      printf 'unknown\t0\t0\n'
      return 0
    fi
    rows+="$contents"$'\n'
  done
  result="$(awk -F '\t' -v issue="$n" -v since="$since" \
    -v call_threshold="$ISSUE_CALL_BUDGET_THRESHOLD" \
    -v token_threshold="$ISSUE_TOKEN_BUDGET_THRESHOLD" '
    function matches(field, issue, rest, count, ids, i) {
      if (field == issue) return 1
      if (substr(field, 1, 6) != "batch:") return 0
      rest = substr(field, 7)
      count = split(rest, ids, ",")
      for (i = 1; i <= count; i++) if (ids[i] == issue) return 1
      return 0
    }
    matches($4, issue) && $1 ~ /^[0-9]+$/ && $1 >= since {
      calls++
      if (NF >= 6 && $6 != "") {
        if ($6 !~ /^[0-9]+$/) bad=1
        else tokens += $6
      }
    }
    END {
      if (bad) print "unknown\t" calls+0 "\t" tokens+0
      else if (calls >= call_threshold || tokens >= token_threshold)
        print "over\t" calls+0 "\t" tokens+0
      else print "clear\t" calls+0 "\t" tokens+0
    }
  ' <<< "$rows")" || return 1
  IFS=$'\t' read -r status calls tokens <<< "$result"
  printf '%s\t%s\t%s\n' "$status" "${calls:-0}" "${tokens:-0}"
}

ISSUE_SPEND_BUDGET_MARKER='<!-- zf-issue-spend-budget-routed'
hold_issue_spend_budget() {
  local n="$1" window_end="$2" edit_label
  local -a edit_args=(--holder issue-spend-budget \
    --release "24-hour spend window ends at $window_end; budget can be checked again then" \
    --expires "$window_end" --kind spend-budget)
  for edit_label in "${ALL_STATE_LABELS[@]}"; do
    [ "$edit_label" = on-hold ] || edit_args+=(--remove-label "$edit_label")
  done
  hold_issue "$n" "${edit_args[@]}" || return 1
  # 2026-10-05: issue 2498, the only frontier of 27 wayfinder tickets, sat in
  # this hold unseen until the maintainer asked. The hold waits on a person, so
  # it rings the supervisor.
  supervisor_inbox_append_once "spend-budget-hold issue=#$n" \
    "spend-budget-hold issue=#$n until=$window_end -- no dispatch before then; hand-dispatch, rehold or let it wait"
}

route_issue_spend_budget() {
  local n="$1" calls="$2" tokens="$3" state prior prior_epoch now_epoch now_at window_end repeat_count
  local risk level route_text marker budget_json hold_status
  [[ "$calls" =~ ^[0-9]+$ && "$tokens" =~ ^[0-9]+$ ]] || return 64
  state="$(state_read "$n")" || return 1
  prior="$(jq -r '.issue_spend_budget.routed_at // empty' <<< "$state")" || return 1
  now_epoch="$(date -u +%s)" || return 1
  repeat_count=0
  if [ -n "$prior" ]; then
    prior_epoch="$(agent_epoch -u "$prior" 2>/dev/null)" || {
      echo "route_issue_spend_budget: invalid prior window for #$n" >&2
      return 1
    }
    if (( now_epoch < prior_epoch + 86400 )); then
      window_end="$(jq -r '.issue_spend_budget.window_end // empty' <<< "$state")" || return 1
      if [ -z "$window_end" ]; then
        window_end="$(date -u -d "@$((prior_epoch + 86400))" +%Y-%m-%dT%H:%M:%SZ)" || return 1
      fi
      if has_label "$n" on-hold; then
        return 0
      else
        hold_status=$?
      fi
      [ "$hold_status" -eq 1 ] || return "$hold_status"
      hold_issue_spend_budget "$n" "$window_end" || return 1
      return 0
    fi
    repeat_count="$(jq -r '(.issue_spend_budget.repeat_count // 0) + 1' <<< "$state")" || return 1
  fi
  now_at="$(date -u -d "@$now_epoch" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  window_end="$(date -u -d "@$((now_epoch + 86400))" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  marker="$ISSUE_SPEND_BUDGET_MARKER issue=$n window=$now_epoch -->"
  if (( repeat_count > 0 )); then
    hold_issue_spend_budget "$n" "$window_end" || return 1
    route_text="预算在前一窗口已触发；本次为重复触发，继续暂停至窗口结束。"
  else
    risk="$(jq -r '.risk_class // empty' <<< "$state")"
    level="$(jq -r '.level // empty' <<< "$state")"
    if [ -n "$risk" ] && [ -n "$level" ] && recut_categorically_oversized "$risk" "$level" \
      && ! jq -e '(.recut_children | type) == "array" and (.recut_children | length > 0)' <<< "$state" >/dev/null 2>&1; then
      route_to_recut "$n" || return 1
      route_text="已转入范围拆分流程。"
    else
      hold_issue_spend_budget "$n" "$window_end" || return 1
      route_text="已暂停自动派发，等待人工处理。"
    fi
  fi
  budget_json="$(jq -cn --arg at "$now_at" --arg time_end "$window_end" \
    --argjson calls "$calls" --argjson tokens "$tokens" --argjson repeat "$repeat_count" \
    '{routed_at:$at,window_end:$time_end,calls:$calls,tokens:$tokens,repeat_count:$repeat,repeated:($repeat > 0)}')" || return 1
  state_merge "$n" ".issue_spend_budget = ((.issue_spend_budget // {}) + $budget_json)" || return 1
  guarded_issue_comment "$n" "$BOT_DISCLAIMER
$marker
24 小时预算已达到上限：$calls 次模型调用（上限 $ISSUE_CALL_BUDGET_THRESHOLD），$tokens 个 token（上限 $ISSUE_TOKEN_BUDGET_THRESHOLD）。$route_text"
}

# Stop additional phases inside one implement run after its last permitted
# call. The current call is already in the ledger before this is checked.
issue_spend_budget_guard() {
  local n="$1" phase="$2" result status calls tokens
  result="$(issue_spend_budget_status "$n")" || return 1
  IFS=$'\t' read -r status calls tokens <<< "$result"
  case "$status" in
    clear) return 0 ;;
    over)
      route_issue_spend_budget "$n" "$calls" "$tokens" >/dev/null || return 1
      echo "run-implement: #$n reached model-call budget before $phase; stopping this run" >&2
      return 78
      ;;
    *)
      echo "run-implement: #$n spend ledger unreadable before $phase; stopping this run" >&2
      return 79
      ;;
  esac
}

# record_premium_spend <role> <model> <issue> <cost_usd|""> [now] [tokens|""] [note|""]
# One row is one model call, recorded after it returns. The first five fields
# remain the original epoch/role/model/issue/cost contract; tokens is appended
# as field 6 so old readers can continue to read field 4. Optional field 7 is
# an observation such as a web advisor model fallback. A Codex call has no
# invented USD value: its measured token count goes in field 6 instead.
# An unobserved cost is marked in field 5, leaving the token field numeric or
# empty for existing readers. Codex cost stays blank when its token usage exists.
record_premium_spend() {
  local role="$1" model="$2" n="$3" cost="${4:-}" now="${5:-$(date +%s)}" tokens="${6:-}" note="${7:-}" row
  if [ -z "$cost" ] && { [ -z "$tokens" ] || [[ "$model" != codex:* ]]; }; then
    cost=unobservable
  fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] record_premium_spend $role $model #$n cost=${cost:-?} tokens=${tokens:-?} note=${note:-?}" >&2
    return 0
  fi
  mkdir -p "$SPEND_DIR"
  row="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$now" "$role" "$model" "$n" "$cost" "$tokens")"
  [ -z "$note" ] || row+=$'\t'"$note"
  printf '%s\n' "$row" >> "$(spend_file_for_day "$now")"
}

# model_cost_usd <model call json output> -> total_cost_usd or empty.
model_cost_usd() {
  echo "$1" | jq -r '.total_cost_usd // empty' 2>/dev/null
}

# codex_tokens_used <transcript text or file> -> the last complete Codex
# usage count, normalized to decimal digits, or empty. Codex prints the
# literal marker on one line and its count on the immediately following line;
# an unrelated number elsewhere in a transcript is not usage. A killed or
# timed-out run normally has no complete pair, so empty is intentional and
# must never be turned into zero by a ledger caller.
codex_tokens_used() {
  local source="$1" text tokens
  if [ -f "$source" ]; then
    text="$(cat "$source" 2>/dev/null || true)"
  else
    text="$source"
  fi
  tokens="$(awk '
    /^[[:space:]]*tokens used[[:space:]]*$/ {
      waiting=1
      next
    }
    waiting {
      if ($0 ~ /^[[:space:]]*[0-9][0-9,]*[[:space:]]*$/) {
        value=$0
        gsub(/[[:space:],]/, "", value)
        last=value
      }
      waiting=0
    }
    END {
      if (last != "") print last
    }
  ' <<< "$text")"
  if [ -n "$tokens" ]; then
    printf '%s\n' "$tokens"
  else
    jq -Rr 'fromjson? | select(.type == "turn.completed") | .usage | [(.input_tokens - ([.cached_input_tokens, 0] | max)), .output_tokens] | map(if . < 0 then 0 else . end) | add' 2>/dev/null <<< "$text" | tail -n 1
  fi
}

# zcode_tokens_used <stream text or file> -> the raw token total (input side plus output)
# of the last {"type":"result"} line's usage, or empty. One result line closes one zcode
# invocation, so its counters are that run's own total, not a cumulative snapshot. Cache
# reads and cache creation are input-side tokens and count toward the total, matching
# usage_reader.Usage.raw for the Anthropic-style counters.
zcode_tokens_used() {
  local source="$1" text
  if [ -f "$source" ]; then
    text="$(cat "$source" 2>/dev/null || true)"
  else
    text="$source"
  fi
  jq -Rr 'fromjson? | select(.type == "result") | .usage // empty
    | [(.input_tokens // 0), (.cache_read_input_tokens // 0), (.cache_creation_input_tokens // 0), (.output_tokens // 0)] | add' \
    2>/dev/null <<< "$text" | tail -n 1
}

# Codex quota is shared across work and production model roles. Keep work
# below the production-only reserve; active launches reserve their existing
# per-issue token ceiling so concurrent hand dispatch cannot spend the same
# remaining allowance repeatedly.
# 2026-10-11: the first default (8M/day, each hand reserving the whole 6M work share) refused every hand
# dispatch once real use reached 32M by noon with no provider hold. The provider quota hold is the hard cap
# (maintainer 2026-09-25: quota ample, concurrency by memory); this budget only keeps the production reserve.
CODEX_DAILY_TOKEN_BUDGET="${CODEX_DAILY_TOKEN_BUDGET:-200000000}"
CODEX_PRODUCTION_TOKEN_RESERVE="${CODEX_PRODUCTION_TOKEN_RESERVE:-20000000}"
CODEX_BUDGET_RESERVATION_TOKENS="${CODEX_BUDGET_RESERVATION_TOKENS:-2200000}"
CODEX_PRODUCTION_RESERVATION_TOKENS="${CODEX_PRODUCTION_RESERVATION_TOKENS:-1000000}"
CODEX_HAND_DISPATCH_RESERVATION_TOKENS="${CODEX_HAND_DISPATCH_RESERVATION_TOKENS:-6000000}"
CODEX_BUDGET_DIR="$AGENT_HOME/codex-budget"
CODEX_BUDGET_RESERVATIONS_FILE="$CODEX_BUDGET_DIR/reservations.tsv"

_codex_budget_proc_start_ticks() {
  local line rest ticks
  [ -r "/proc/$1/stat" ] || return 1
  IFS= read -r line < "/proc/$1/stat" || return 1
  rest="${line##*) }"
  ticks="$(awk '{print $20}' <<< "$rest")"
  [[ "$ticks" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$ticks"
}

_codex_budget_reservation_live() {
  local pid="$1" ticks="$2" expires="$3" now="$4" current_ticks
  if [ "$pid" = 0 ]; then
    [[ "$expires" =~ ^[0-9]+$ ]] && (( now < expires ))
    return
  fi
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$ticks" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  current_ticks="$(_codex_budget_proc_start_ticks "$pid" 2>/dev/null || true)"
  [ "$current_ticks" = "$ticks" ]
}

_codex_budget_actual_usage() {
  local now="$1" file production_identity
  file="$(spend_file_for_day "$now")"
  production_identity="$(model_policy identity production 2>/dev/null || true)"
  awk -F '\t' -v production_identity="$production_identity" '
    $3 ~ /^codex:/ && $6 ~ /^[0-9]+$/ {
      total += $6
      if ($2 == "production" || $3 == production_identity) production += $6
      else work += $6
    }
    END { printf "%.0f\t%.0f\t%.0f\n", total, work, production }
  ' "$file" 2>/dev/null || printf '0\t0\t0\n'
}

_codex_budget_reservation_usage() {
  local now="$1" exclude_id="${2:-}" id role tokens pid ticks expires
  local work=0 production=0
  if [ -r "$CODEX_BUDGET_RESERVATIONS_FILE" ]; then
    while IFS=$'\t' read -r id role tokens pid ticks expires; do
      [ -n "$id" ] && [ "$id" != "$exclude_id" ] || continue
      [[ "$tokens" =~ ^[0-9]+$ ]] || continue
      _codex_budget_reservation_live "$pid" "$ticks" "$expires" "$now" || continue
      case "$role" in
        work) work=$((work + tokens)) ;;
        production) production=$((production + tokens)) ;;
      esac
    done < "$CODEX_BUDGET_RESERVATIONS_FILE"
  fi
  printf '%s\t%s\n' "$work" "$production"
}

_codex_budget_valid_config() {
  [[ "$CODEX_DAILY_TOKEN_BUDGET" =~ ^[1-9][0-9]*$ \
    && "$CODEX_PRODUCTION_TOKEN_RESERVE" =~ ^[0-9]+$ \
    && "$CODEX_PRODUCTION_TOKEN_RESERVE" -lt "$CODEX_DAILY_TOKEN_BUDGET" \
    && "$CODEX_BUDGET_RESERVATION_TOKENS" =~ ^[1-9][0-9]*$ \
    && "$CODEX_PRODUCTION_RESERVATION_TOKENS" =~ ^[1-9][0-9]*$ \
    && "$CODEX_HAND_DISPATCH_RESERVATION_TOKENS" =~ ^[1-9][0-9]*$ ]]
}

# codex_budget_status [now] -> verdict, actual used/limit, UTC-day projection,
# per-role totals, active reservations, and last account reset in TSV order.
codex_budget_status() {
  local now="${1:-$(date +%s)}" usage used work production reservations reserved
  local elapsed midnight projected verdict reset=unknown marker until production_reserve
  [[ "$now" =~ ^[0-9]+$ ]] && _codex_budget_valid_config || return 2
  usage="$(_codex_budget_actual_usage "$now")"
  IFS=$'\t' read -r used work production <<< "$usage"
  reservations="$(_codex_budget_reservation_usage "$now")"
  IFS=$'\t' read -r work_reserved production_reserved <<< "$reservations"
  reserved=$((work_reserved + production_reserved))
  midnight="$(date -u -d "$(date -u -d "@$now" +%F) 00:00:00" +%s)" || return 2
  elapsed=$((now - midnight))
  (( elapsed > 0 )) || elapsed=1
  projected="$(awk -v used="$used" -v elapsed="$elapsed" 'BEGIN { printf "%.0f", used * 86400 / elapsed }')"
  if (( used >= CODEX_DAILY_TOKEN_BUDGET )); then
    verdict=BROKEN
  elif (( used * 10 >= CODEX_DAILY_TOKEN_BUDGET * 7 )); then
    verdict=SLOW
  else
    verdict=OK
  fi
  marker="$(_quota_marker_file codex 2>/dev/null || true)"
  if [ -n "$marker" ] && [ -r "$marker" ]; then
    until="$(cat "$marker" 2>/dev/null || true)"
    if [[ "$until" =~ ^[0-9]+$ ]]; then reset="$(date -u -d "@$until" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"; fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$verdict" "$used" "$CODEX_DAILY_TOKEN_BUDGET" "$projected" \
    "$work" "$production" "$reserved" "$reset"
}

# codex_budget_reserve <work|production> <id> [tokens] [provisional=0]
# Provisional leases expire after 15 minutes unless the launched child adopts.
codex_budget_reserve() {
  local role="$1" id="$2" tokens="${3:-}" provisional="${4:-0}" now="${5:-$(date +%s)}" model_identity="${6:-}"
  local usage used work production reservations work_reserved production_reserved total_reserved work_limit
  local pid ticks expires tmp lock_fd until marker traffic_monitor
  [[ "$role" = work || "$role" = production ]] || return 2
  [[ "$id" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 2
  [[ "$now" =~ ^[0-9]+$ ]] && _codex_budget_valid_config || return 2
  if [ -z "$model_identity" ]; then model_identity="$(model_policy identity "$role")" || return 2; fi
  [[ "$model_identity" == codex:* ]] || return 2
  if codex_model_capacity_held "$model_identity" "$now"; then
    echo "codex budget: model capacity hold active for $model_identity" >&2
    return 75
  fi
  traffic_monitor="$(dirname -- "${BASH_SOURCE[0]}")/network-traffic.py"
  if [[ "$role" == work && -r "$traffic_monitor" ]]; then
    python3 -B "$traffic_monitor" admit --home "$AGENT_HOME" || return $?
  fi
  if [ -z "$tokens" ]; then
    if [ "$role" = production ]; then tokens="$CODEX_PRODUCTION_RESERVATION_TOKENS"; else tokens="$CODEX_BUDGET_RESERVATION_TOKENS"; fi
  fi
  [[ "$tokens" =~ ^[1-9][0-9]*$ ]] || return 2
  if [ -e "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" ]; then
    codex_probe_ok || return 75
    codex_provider_recovery_probe_if_due "$model_identity" || return 75
  fi
  mkdir -p "$AGENT_HOME/locks" "$CODEX_BUDGET_DIR" || return 2
  exec {lock_fd}>"$AGENT_HOME/locks/codex-budget.lock" || return 2
  flock "$lock_fd" || { unlock_fd "$lock_fd"; return 2; }
  if provider_quota_exhausted codex; then
    marker="$(_quota_marker_file codex)"
    until="$(cat "$marker" 2>/dev/null || true)"
    echo "codex budget: provider quota hold active until $(date -u -d "@$until" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" >&2
    unlock_fd "$lock_fd"
    return 75
  fi
  usage="$(_codex_budget_actual_usage "$now")"
  IFS=$'\t' read -r used work production <<< "$usage"
  reservations="$(_codex_budget_reservation_usage "$now" "$id")"
  IFS=$'\t' read -r work_reserved production_reserved <<< "$reservations"
  total_reserved=$((work_reserved + production_reserved))
  work_limit=$((CODEX_DAILY_TOKEN_BUDGET - CODEX_PRODUCTION_TOKEN_RESERVE))
  if { [ "$role" = work ] && (( work + work_reserved + tokens > work_limit )); } \
    || (( used + total_reserved + tokens > CODEX_DAILY_TOKEN_BUDGET )); then
    echo "codex budget: refusing $role dispatch; used=$used/$CODEX_DAILY_TOKEN_BUDGET work=$work/$work_limit reserved=$total_reserved request=$tokens" >&2
    unlock_fd "$lock_fd"
    return 75
  fi
  if [ "$provisional" = 1 ]; then
    pid=0; ticks=0; expires=$((now + 900))
  else
    pid="$$"
    ticks="$(_codex_budget_proc_start_ticks "$pid" 2>/dev/null || true)"
    [[ "$ticks" =~ ^[0-9]+$ ]] || { unlock_fd "$lock_fd"; return 2; }
    expires=0
  fi
  tmp="$(mktemp "$CODEX_BUDGET_DIR/reservations.XXXXXX")" || { unlock_fd "$lock_fd"; return 2; }
  if [ -r "$CODEX_BUDGET_RESERVATIONS_FILE" ]; then
    while IFS=$'\t' read -r existing_id existing_role existing_tokens existing_pid existing_ticks existing_expires; do
      [ -n "$existing_id" ] && [ "$existing_id" != "$id" ] || continue
      _codex_budget_reservation_live "$existing_pid" "$existing_ticks" "$existing_expires" "$now" \
        && printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$existing_id" "$existing_role" "$existing_tokens" "$existing_pid" "$existing_ticks" "$existing_expires" >> "$tmp"
    done < "$CODEX_BUDGET_RESERVATIONS_FILE"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$role" "$tokens" "$pid" "$ticks" "$expires" >> "$tmp"
  mv -f -- "$tmp" "$CODEX_BUDGET_RESERVATIONS_FILE" || { rm -f -- "$tmp"; unlock_fd "$lock_fd"; return 2; }
  unlock_fd "$lock_fd"
}

codex_budget_adopt() {
  local id="$1" pid="${2:-$$}" now="${3:-$(date +%s)}" ticks tmp lock_fd found=0
  [[ "$id" =~ ^[A-Za-z0-9_.:-]+$ && "$pid" =~ ^[1-9][0-9]*$ && "$now" =~ ^[0-9]+$ ]] || return 2
  ticks="$(_codex_budget_proc_start_ticks "$pid" 2>/dev/null || true)"
  [[ "$ticks" =~ ^[0-9]+$ ]] || return 1
  [ -r "$CODEX_BUDGET_RESERVATIONS_FILE" ] || return 1
  exec {lock_fd}>"$AGENT_HOME/locks/codex-budget.lock" || return 2
  flock "$lock_fd" || { unlock_fd "$lock_fd"; return 2; }
  tmp="$(mktemp "$CODEX_BUDGET_DIR/reservations.XXXXXX")" || { unlock_fd "$lock_fd"; return 2; }
  while IFS=$'\t' read -r existing_id role tokens old_pid old_ticks expires; do
    [ -n "$existing_id" ] || continue
    if [ "$existing_id" = "$id" ]; then
      printf '%s\t%s\t%s\t%s\t%s\t0\n' "$id" "$role" "$tokens" "$pid" "$ticks" >> "$tmp"
      found=1
    else
      _codex_budget_reservation_live "$old_pid" "$old_ticks" "$expires" "$now" \
        && printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$existing_id" "$role" "$tokens" "$old_pid" "$old_ticks" "$expires" >> "$tmp"
    fi
  done < "$CODEX_BUDGET_RESERVATIONS_FILE"
  if [ "$found" -eq 1 ]; then mv -f -- "$tmp" "$CODEX_BUDGET_RESERVATIONS_FILE"; else rm -f -- "$tmp"; fi
  unlock_fd "$lock_fd"
  [ "$found" -eq 1 ]
}

codex_budget_release() {
  local id="${1:-}" tmp lock_fd
  [ -n "$id" ] || return 0
  [ -r "$CODEX_BUDGET_RESERVATIONS_FILE" ] || return 0
  exec {lock_fd}>"$AGENT_HOME/locks/codex-budget.lock" || return 2
  flock "$lock_fd" || { unlock_fd "$lock_fd"; return 2; }
  tmp="$(mktemp "$CODEX_BUDGET_DIR/reservations.XXXXXX")" || { unlock_fd "$lock_fd"; return 2; }
  awk -F '\t' -v id="$id" '$1 != id' "$CODEX_BUDGET_RESERVATIONS_FILE" > "$tmp" \
    && mv -f -- "$tmp" "$CODEX_BUDGET_RESERVATIONS_FILE" || { rm -f -- "$tmp"; unlock_fd "$lock_fd"; return 2; }
  unlock_fd "$lock_fd"
}

# premium_call_is_quota_refused <call_output> <exit_status> -- true (0) iff
# the call contains a provider usage-limit error or normalized HTTP
# 429 error. Provider capacity and overload errors use the outage classifier below
# and stay on the same model rung;
# everything else is a real failure -- "a genuine error still fails" is the
# other half of the same 2026-09-15 ruling that removed the local budget
# check, so a schema violation or a crash at whichever rung answered must
# surface as this run's own failure, never get silently retried on a weaker
# or unrelated model as if it were a refusal.
#
# Matches on TEXT, the same discipline as gh_failure_is_transient() above:
# known refusal shapes only, never a bare nonzero exit (a `codex exec`
# timeout or a malformed response is a real failure, not a refusal).
# $call_output is whatever the caller already has on hand -- model call's own
# JSON (`.api_error_status`, `.subtype`, `.result`) from a provider response, or
# run_codex_json()'s normalized `{is_error, result}` (its own `result` field
# already carries the captured codex transcript on failure -- see below) for
# a Codex call. One detector, because both are read the same way once
# normalized.
premium_call_provider_outage_kind() {
  local output="$1" api_status
  if grep -qiE 'failed to connect to websocket|proxy connection failed: HTTP CONNECT failed with status 50[234]|workspace routing discovery failed' <<< "$output"; then
    echo network-egress
    return 0
  fi
  if awk 'tolower($0) ~ /websocket closed by server before response\.completed|stream disconnected/ { closed=1 } closed && tolower($0) ~ /401 unauthorized/ { found=1 } END { exit found ? 0 : 1 }' <<< "$output"; then
    echo websocket-401
    return 0
  fi
  if grep -qi 'websocket closed by server before response.completed' <<< "$output"; then
    echo websocket-closed
    return 0
  fi
  if grep -qi 'stream disconnected' <<< "$output"; then
    echo stream-disconnected
    return 0
  fi
  api_status="$(jq -r 'if type == "object" then .api_error_status // empty else empty end' 2>/dev/null <<< "$output" || true)"
  case "$api_status" in 400|401|403|404|422) return 1 ;; esac
  if [[ "$api_status" =~ ^5[0-9][0-9]$ ]] || grep -qiE '(unexpected status|HTTP)[[:space:]:]+5[0-9][0-9]' <<< "$output"; then
    echo provider-5xx
    return 0
  fi
  if grep -qiE 'selected[[:space:]]+model[^[:cntrl:]]*capacity|(^|[^[:alnum:]_])at[[:space:]]+capacity([^[:alnum:]_]|$)|overload(ed)?(_error)?' <<< "$output"; then
    echo provider-capacity
    return 0
  fi
  if grep -qF 'Reconnecting... 5/5' <<< "$output" \
    && ! grep -qiE 'codex-final-output-present=(true|1)|"model_output_present"[[:space:]]*:[[:space:]]*true|response\.output_text\.delta' <<< "$output"; then
    echo reconnect-exhausted
    return 0
  fi
  return 1
}

codex_usage_limit_text_for_matching() {
  local text="$1" apostrophe="'"
  printf '%s' "${text//’/$apostrophe}"
}

premium_call_is_quota_refused() {
  local output="$1" status="${2:-1}" api_status envelope events
  [ "$status" -ne 0 ] && [ "$status" -lt 129 ] || return 1
  # A provider outage must never become the thirty-minute quota circuit.
  [ -z "$(premium_call_provider_outage_kind "$output" || true)" ] || return 1
  api_status="$(jq -r 'if type == "object" then .api_error_status // empty else empty end' 2>/dev/null <<< "$output" || true)"
  [ "$api_status" = 429 ] && return 0
  envelope="$(jq -r 'select(type == "object" and .is_error == true) | .result | select(type == "string")' 2>/dev/null <<< "$output" || true)"
  [ -z "$envelope" ] || output="$envelope"
  # Only CLI error events, never item.completed agent messages or quoted JSON.
  events="$(jq -Rr 'fromjson? | if .type == "error" then .message elif .type == "turn.failed" then .error.message else empty end | select(type == "string")' 2>/dev/null <<< "$output" || true)"
  [ -z "$events" ] || output="$events"
  # GNU grep's [’] bracket expression does not reliably match under the
  # pipeline's LC_ALL=C. Normalize the CLI's typographic apostrophe first.
  output="$(codex_usage_limit_text_for_matching "$output")"
  # Actual CLI display shapes (openai/codex rust-v0.162.1 protocol/src/error.rs).
  grep -qiE "^(ERROR: )?You've hit your usage limit(\.| for )|^ERROR: unexpected status 429 Too Many Requests: (Rate limit reached|You've hit your usage limit)" <<< "$output"
}

# Session logs mix agent prose and provider diagnostics. Read only bounded,
# anchored CLI errors; codex-error is a broad log label, not provider evidence.
codex_session_error_output() {
  tail -c 16000 -- "$1" 2>/dev/null | jq -Rr '
    if test("^[^ ]+ codex-provider-error ") then sub("^[^ ]+ codex-provider-error "; "ERROR: ")
    else fromjson? | if .type == "error" then .message elif .type == "turn.failed" then .error.message else empty end
      | select(type == "string") | "ERROR: " + . end' 2>/dev/null || true
}

codex_session_error_kind() {
  local output="$1" status="${2:-1}" kind
  kind="$(premium_call_provider_outage_kind "$output" || true)"
  if [ -n "$kind" ]; then
    echo "$kind"
    return 0
  fi
  if premium_call_is_quota_refused "$output" "$status"; then
    echo quota-429
    return 0
  fi
  return 1
}

codex_session_failure() {
  local log_file="$1" status="$2" caller="$3" model="$4" signal="${5:-}" output kind
  [ "$status" -ne 0 ] && [ "$status" -lt 129 ] && [ -z "$signal" ] || return 0
  output="$(codex_session_error_output "$log_file")"
  [ -n "$output" ] || return 0
  kind="$(codex_session_error_kind "$output" "$status" || true)"
  if [ "$kind" != quota-429 ] && [ -n "$kind" ]; then
    note_codex_provider_outage "session:$caller:${log_file##*/}" "$kind" "$caller" "$model"
  elif [ "$kind" = quota-429 ]; then
    if ! [[ "${ZF_HAND_PROVIDER_RETRY:-}" =~ ^[01]$ ]]; then
      note_provider_quota_exhausted codex "" "$output"
    fi
  fi
  return 0
}

# Classify the invocation, not an advisor's semantic verdict. Valid JSON
# zero values remain data; empty/non-object output is not a successful call.
# Missing verdict fields still go through the caller's fail-closed schema path.
model_call_is_configuration_error() {
  local output="$1" status="$2" api_status
  [ "$status" -eq 124 ] && return 1
  [ "$status" -eq 64 ] && return 0
  codex_config_fast_failure "$output" && return 0
  api_status="$(jq -r 'if type == "object" then .api_error_status // empty else empty end' 2>/dev/null <<< "$output" || true)"
  case "$api_status" in 400|401|403|404|422) return 0 ;; esac
  grep -qiE '((unexpected status|HTTP|status code)[[:space:]:]+(400|401|403|404|422)([^0-9]|$))|(unrecognized|invalid) model|(unsupported|unexpected|unrecognized|unknown) (model|identity|argument|option|flag)|model slug|may not exist or you may not have access' <<< "$output"
}

model_call_missing_agent_binary() {
  local output="$1" status="${2:-}" provider="${3:-}" model="${4:-unknown}"
  if [[ "$status" == 127 && "$model" != unknown && "$provider" =~ ^(codex|web-advisor-provider)$ ]]; then
    return 0
  fi
  grep -Eiq \
    '(codex|agent[- ]tool).{0,120}(no such file or directory|enoent|command not found)|(no such file or directory|enoent|command not found).{0,120}(codex|agent[- ]tool)|model_call_exit_status=127|codex_exit_status.{0,4}127|agent[- ]tool.{0,120}(exit|status|code).{0,8}127|tool call.{0,120}(exit|status|code).{0,8}127' \
    <<< "$output"
}

model_call_failure_kind() {
  local output="$1" status="$2" api_status provider_kind
  if [ "$status" = 127 ] || model_call_missing_agent_binary "$output" "$status" "" ""; then
    echo transient
    return 0
  fi
  if [ "$status" -eq 124 ]; then
    echo transient
    return 0
  fi
  if [ "$status" -eq 0 ] && jq -e 'type == "object" and .is_error != true and .is_error != "true"' >/dev/null 2>&1 <<< "$output"; then
    echo none
    return 0
  fi
  api_status="$(jq -r 'if type == "object" then .api_error_status // empty else empty end' 2>/dev/null <<< "$output" || true)"
  case "$api_status" in
    400|401|403|404|422) echo execution; return 0 ;;
  esac
  provider_kind="$(premium_call_provider_outage_kind "$output" || true)"
  if [ "$provider_kind" = provider-capacity ]; then
    echo transient
    return 0
  fi
  # A structured status outranks incidental words in the error narrative.
  case "$api_status" in
    429) echo quota; return 0 ;;
    500|502|503|504) echo transient; return 0 ;;
  esac
  if model_call_is_configuration_error "$output" "$status"; then
    echo execution
    return 0
  fi
  if premium_call_is_quota_refused "$output" "$status"; then
    echo quota
  elif [ "$status" -eq 124 ] || gh_failure_is_transient "$output"; then
    echo transient
  elif ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$output"; then
    echo malformed
  else
    echo execution
  fi
}

# resolve_guarded_reviewer <identity> [fallback] -> a policy-approved identity.
resolve_guarded_reviewer() {
  local id="$1" fallback="${2:-$(model_policy identity work)}"
  model_policy_identity_allowed "$fallback" || fallback="$(model_policy identity work)"
  model_policy_identity_allowed "$id" || { echo "$fallback"; return 0; }
  case "$id" in
    codex:*)
      if [ ! -f "$CODEX_PROBE_MARKER" ]; then
        echo "guarded reviewer $id requested but $CODEX_PROBE_MARKER is absent -- engine/probe-codex-sandbox.sh has not passed on this box; using $fallback" >&2
        echo "$fallback"
      elif codex_quota_exhausted; then
        # 2026-09-17: a second, different reason to refuse the same identity.
        # The probe gate above is about safety and is unchanged. This one is
        # availability: while the Codex account-wide usage-limit window is
        # open, dispatching a Codex reviewer buys a guaranteed refusal, and
        # each refusal that reaches run-advisor.sh's ladder end writes the
        # PAUSE file and stops the WHOLE pipeline for an hour -- so one
        # provider outage was idling unrelated issue work too.
        echo "guarded reviewer $id requested but the Codex quota window is closed until $(date -d "@$(cat "$CODEX_EXHAUSTED_MARKER_FILE" 2>/dev/null || echo 0)" '+%H:%M:%S' 2>/dev/null) -- using $fallback" >&2
        echo "$fallback"
      else
        echo "$id"
      fi
      ;;
    *) echo "$id" ;;
  esac
}

# codex_probe_ok -- true (0) iff a Codex identity is admitted on this box
# right now. Same predicate resolve_guarded_reviewer() applies to a single
# identity, exposed standalone for a caller (run-advisor.sh's ladder) that
# needs to decide UP FRONT whether to include the whole Codex sub-ladder at
# all, not resolve one identity.
codex_probe_ok() { [ -f "$CODEX_PROBE_MARKER" ]; }

# The advisor role uses the configured web session. Failures follow the
# persisted transition policy; there is no model-switch fallback.
#
# The advisor's transport (config variables, the sync/async call machinery,
# health checks, fault classification) is an optional provider module,
# sourced only when present. This distribution ships none.
_AGENT_WEB_ADVISOR_PROVIDER="$_AGENT_LIB_DIR/providers/web-advisor-provider.sh"
[[ -r "$_AGENT_WEB_ADVISOR_PROVIDER" ]] && source "$_AGENT_WEB_ADVISOR_PROVIDER"
if ! declare -F web_advisor_provider_usable >/dev/null; then
  # No provider module is installed (a distribution dropped
  # providers/web-advisor-provider.sh). Every entry point the pipeline calls fails closed
  # instead of dying on "command not found", which under set -e would kill
  # the whole tick: nothing is dispatched or polled, model calls report an
  # unsupported provider (exit 64, which callers already classify as a
  # configuration fault through pause_for_backoff), and the dispatch gate
  # records one env fault.
  WEB_ADVISOR_PROVIDER_JOB_DIR="$AGENT_HOME/web-advisor-provider-jobs"
  WEB_ADVISOR_PROVIDER_JOB_TIMEOUT_SECONDS=0
  web_advisor_provider_unavailable() { echo "web-advisor-provider advisor provider is not installed" >&2; return 64; }
  web_advisor_provider_job_ids() { :; }
  web_advisor_provider_job_candidates() { :; }
  reconcile_stale_web_advisor_provider_jobs() { :; }
  web_advisor_provider_per_ticket_topic() { :; }
  web_advisor_provider_clear_job_state() {
    state_merge "$1" 'del(.web_advisor_provider_job_id, .web_advisor_provider_job_started_at, .web_advisor_provider_job_episode_seq)'
  }
  web_advisor_provider_usable() { return 1; }
  web_advisor_provider_env_fault_probe() { return 2; }
  web_advisor_provider_env_fault_repair() { return 1; }
  record_web_advisor_provider_fault() {
    record_env_fault env:web-advisor-provider:not-installed advisor "$1" "$2" "" "${3:-}"
  }
  web_advisor_provider_dispatch_allowed() {
    stage_dispatch_allowed advisor "[]" "${1:-$(date +%s)}" || return 1
    record_web_advisor_provider_fault 0 "no web-advisor-provider advisor provider is installed; advisor dispatch refused"
    return 1
  }
  web_advisor_provider_dispatch_async() { web_advisor_provider_unavailable; }
  web_advisor_provider_dispatch_ndjson_async() { web_advisor_provider_unavailable; }
  web_advisor_provider_normalize_batch_json() { web_advisor_provider_unavailable; }
  run_web_advisor_provider_ndjson() { web_advisor_provider_unavailable; }
  # Status 2 is "still running": a leftover job marker ages out through
  # run-advisor.sh's ceiling branch (env fault, marker cleared).
  web_advisor_provider_poll() { return 2; }
  run_web_advisor_provider_json() {
    jq -nc '{is_error: true, subtype: "unsupported_model_provider", result: "web-advisor-provider advisor provider is not installed"}'
    return 64
  }
fi

# run_codex_json <cwd> <model> <effort> <schema_file> <prompt_file> -- runs
# `codex exec` with the same containment flags probe-codex-sandbox.sh
# measured (--sandbox read-only, --cd, --skip-git-repo-check, --ephemeral),
# constrained to $schema_file via --output-schema, fed $prompt_file on
# stdin, and normalizes its result to the shared {is_error, structured_output}
# envelope consumed by pipeline callers.
# total_cost_usd is never set (Codex reports tokens, not USD -- see
# model_cost_usd above) so that field reads empty for a Codex response,
# exactly like an absent field. This is the pipeline's one Codex runner --
# see run-advisor.sh's own comment on why it lives here instead of being
# built a second time wherever else a `codex:` identity is dispatched.
#
# Model and effort are separate Codex arguments; every caller gets both from
# the persistent role policy.
run_codex_json() {
  local cwd="$1" model="$2" effort="$3" schema_file="$4" prompt_file="$5" service_tier
  local -a service_tier_args=()
  local out_file transcript status=0 body result_text tokens_used timeout_seconds started_at elapsed timeout_detail model_output_present=false
  model_policy_require_implementer_identity "codex:$model:$effort" || { jq -nc '{is_error: true, subtype: "unsupported_model_identity", result: "identity does not match the work role"}'; return 64; }
  service_tier="$(model_policy tier "codex:$model:$effort")" || return $?
  [ -z "$service_tier" ] || service_tier_args=(-c "service_tier=\"$service_tier\"")
  timeout_seconds="${CODEX_JSON_TIMEOUT_SECONDS:-2700}"
  out_file="$(mktemp)"; transcript="$(mktemp)"
  # `|| status=$?`, not `set +e; ...; set -e`: the latter toggles a GLOBAL
  # shell option, which leaks into the caller's own shell for any caller
  # that invokes this as a bare statement (not shielded by a command-
  # substitution subshell) -- 2026-09-15, found while adding run_codex_
  # implement() below (see its own comment): a caller running under
  # `set -e` that calls this function as a bare statement would have its
  # OWN `set -e` silently re-armed by this function's internal `set -e`
  # just before `return`, then killed on the spot the moment that return
  # carries a nonzero status -- no log, no fail_attempt bookkeeping, the
  # exact failure mode this file's own callers already guard against for
  # every model call. `cmd || status=$?` is the exempted-by-`||` bash
  # idiom instead: self-contained, works identically whether or not the
  # caller has `set -e` active, and never mutates shared shell state.
  started_at="$(date +%s)"
  pipeline_execution_run timeout "${timeout_seconds}s" codex exec \
    --sandbox "$CODEX_SANDBOX_MODE" --cd "$cwd" --skip-git-repo-check --ephemeral \
    -m "$model" -c model_reasoning_effort="$effort" "${service_tier_args[@]}" \
    -c mcp_servers.gitnexus.enabled=false \
    --output-schema "$schema_file" --output-last-message "$out_file" \
    - < "$prompt_file" > "$transcript" 2>&1 || status=$?
  elapsed=$(( $(date +%s) - started_at ))
  if [ "$status" -eq 124 ]; then
    timeout_detail="codex exec timed out after ${timeout_seconds}s (elapsed ${elapsed}s)"
    printf '%s\n' "$timeout_detail" >> "$transcript"
    echo "$timeout_detail" >&2
  fi
  body="$(cat "$out_file" 2>/dev/null || true)"
  [ -s "$out_file" ] && model_output_present=true
  tokens_used="$(codex_tokens_used "$transcript")"
  if [ "$status" -eq 0 ] && echo "$body" | jq -e . >/dev/null 2>&1; then
    # $body is codex's own structured output -- unbounded (an advisor
    # ruling, a review report, ...). It's already on disk as $out_file, so
    # --slurpfile reads it straight from there instead of round-tripping
    # through argv via --argjson; --slurpfile always binds an array, hence
    # $so[0] here (see jq_arg_file()'s own comment in lib.sh).
    jq -nc --slurpfile so "$out_file" --arg tokens "$tokens_used" \
      '{is_error: false, structured_output: $so[0], tokens_used: $tokens}'
  else
    # 2026-09-16 P0 fix, measured against
    # $HOME/.zenoforge/logs/advisor-1327-20260917T033841Z.log: this
    # used to be `head -c 2000`, which keeps the START of the transcript --
    # codex's own banner (`model:`, `sandbox:`, `session id:`), the echoed
    # user prompt, and any bubblewrap/skill/`hook:` warnings -- and throws
    # away the END, which is where codex actually writes its error. That
    # log's own `result` field was exactly 1900 chars of banner + echoed
    # prompt with `tokens_used` empty and the words "quota"/"usage limit"
    # nowhere in it, even though the real transcript that run captured ended
    # in `ERROR: You've hit your usage limit ... try again at Sep 19th, 2026
    # 1:10 AM.` -- invisible to premium_call_is_quota_refused() (below)
    # purely because of which end got kept. `tail -c 2000` matches the
    # existing `tail -c 4000` precedent in run-implement.sh's own IMPLEMENT_LOG
    # quota-refusal check, which is exactly why that leg never had this bug
    # and only the implement leg ever wrote CODEX_EXHAUSTED_MARKER_FILE
    # before this fix (GitHub issue #1350). The model identity that failed is
    # already reported separately by the caller's own fail_attempt() message
    # (the candidate/IMPLEMENT_MODEL string is interpolated there), so losing
    # the banner here costs nothing.
    result_text="$(tail -c 2000 "$transcript" 2>/dev/null)"
    jq -nc --arg result "$result_text" --arg status "$status" --arg tokens "$tokens_used" --arg elapsed "$elapsed" \
      --argjson output_present "$model_output_present" \
      '{is_error: true, subtype: "codex_exec_failure", result: $result, codex_exit_status: ($status|tonumber), tokens_used: $tokens, model_output_present: $output_present, codex_elapsed_seconds: ($elapsed|tonumber)}'
  fi
  rm -f "$out_file" "$transcript"
  return "$status"
}

# zcode_extract_json_object <raw reply> -- the last parseable JSON object in
# zcode's final message: a fenced ```json block wins (the prompt asks for
# exactly one), otherwise the last balanced top-level object. No candidate
# prints nothing (caller fails closed).
zcode_extract_json_object() {
  printf '%s' "$1" | node -e '
let text = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => { text += chunk; });
process.stdin.on("end", () => {
  if (text.length > 2000000) text = text.slice(-2000000);
  const fences = [...text.matchAll(/```(?:json)?\s*(\{[\s\S]*?\})\s*```/g)];
  for (let i = fences.length - 1; i >= 0; i--) {
    try {
      const value = JSON.parse(fences[i][1]);
      if (value && typeof value === "object") { process.stdout.write(JSON.stringify(value)); return; }
    } catch {}
  }
  let best = null;
  for (let start = text.indexOf("{"); start >= 0; start = text.indexOf("{", start + 1)) {
    let depth = 0, inString = false, escaped = false;
    for (let i = start; i < text.length; i++) {
      const ch = text[i];
      if (inString) {
        if (escaped) escaped = false;
        else if (ch === "\\") escaped = true;
        else if (ch === "\"") inString = false;
        continue;
      }
      if (ch === "\"") inString = true;
      else if (ch === "{") depth++;
      else if (ch === "}") {
        depth--;
        if (depth === 0) {
          try {
            const value = JSON.parse(text.slice(start, i + 1));
            if (value && typeof value === "object") best = value;
          } catch {}
          break;
        }
      }
    }
  }
  if (best) process.stdout.write(JSON.stringify(best));
});
'
}

# run_zcode_json <cwd> <identity> <timeout_minutes> <schema_file> <prompt_file>
# -- the pipeline's one zcode runner for structured JSON-verdict calls (the
# cross-provider review). zcode has no schema-enforced output mode, so the
# JSON contract rides in the prompt itself (the same approach the web advisor
# takes) and the final message is parsed here: a reply without exactly one
# valid object fails CLOSED as is_error, exactly like a codex exec failure,
# so every downstream consumer sees the same {is_error, structured_output}
# envelope. Invocation shape reuses the hand-agent dispatch
# (engine/night/dispatch.sh): prompt through -p, --cwd, --mode yolo,
# NODE_USE_ENV_PROXY=1 for proxied egress. Model and effort come from the
# policy-resolved review identity; nothing here names a model.
run_zcode_json() {
  local cwd="$1" identity="$2" timeout_minutes="$3" schema_file="$4" prompt_file="$5"
  local zcode_id model effort status=0 started_at elapsed timeout_detail out_file transcript reply verdict_json
  model_policy_require_role_identity review "$identity" || {
    jq -nc '{is_error: true, subtype: "unsupported_model_identity", result: "identity does not match the review role"}'
    return 64
  }
  zcode_id="${identity#zcode:}"
  if [[ "$zcode_id" != *:* ]]; then
    jq -nc --arg identity "$identity" '{is_error: true, subtype: "unsupported_model_identity", result: ("zcode identity needs model:effort: " + $identity)}'
    return 64
  fi
  model="${zcode_id%:*}"
  effort="${zcode_id#*:}"
  out_file="$(mktemp)"
  transcript="$(mktemp)"
  # The schema rides in the prompt (fenced, like web_advisor_provider_build_
  # question) because zcode enforces nothing itself.
  {
    echo 'You are this pipeline'"'"'s independent cross-provider reviewer. Reply with EXACTLY one fenced code block, language "json", containing a single JSON object that validates against the JSON Schema given below -- no text before or after that one code block, no other commentary.'
    echo
    echo 'JSON Schema:'
    echo '```json'
    cat "$schema_file"
    echo '```'
    echo
    cat "$prompt_file"
  } > "$transcript"
  started_at="$(date +%s)"
  NODE_USE_ENV_PROXY=1 timeout "${timeout_minutes}m" zcode -p "$(cat "$transcript")" \
    --cwd "$cwd" --mode yolo > "$out_file" 2>&1 || status=$?
  elapsed=$(( $(date +%s) - started_at ))
  if [ "$status" -eq 124 ]; then
    timeout_detail="zcode review timed out after $((timeout_minutes * 60))m (elapsed ${elapsed}s)"
    printf '%s\n' "$timeout_detail" >> "$out_file"
    echo "$timeout_detail" >&2
  fi
  reply="$(cat "$out_file" 2>/dev/null || true)"
  verdict_json="$(zcode_extract_json_object "$reply")"
  if [ "$status" -eq 0 ] && [ -n "$verdict_json" ] \
    && jq -e 'type == "object" and (.verdict | type) == "string" and (.verdict | IN("READY", "NOT_READY", "INPUT_INCOMPLETE")) and (.report_md | type) == "string"' \
      <<< "$verdict_json" >/dev/null 2>&1; then
    jq -nc --argjson so "$verdict_json" '{is_error: false, structured_output: $so, tokens_used: ""}'
  else
    result_text="$(tail -c 2000 "$out_file" 2>/dev/null)"
    jq -nc --arg result "$result_text" --arg status "$status" --arg elapsed "$elapsed" \
      '{is_error: true, subtype: "zcode_exec_failure", result: $result, zcode_exit_status: ($status|tonumber), zcode_elapsed_seconds: ($elapsed|tonumber)}'
    [ "$status" -ne 0 ] || status=1
  fi
  rm -f "$out_file" "$transcript"
  return "$status"
}

# #1457 dispatch seam for the batch call. Identity selection stays outside
# this helper; it only routes an already-selected provider prefix and refuses
# anything that is not the web advisor transport this batch contract needs.
run_model_advisor_batch_async() {
  local identity="$1" job_id="$2" prompt_file="$3"
  [ "$identity" = "$(model_policy identity advisor)" ] || {
    echo "run_model_advisor_batch_async: identity is not the configured advisor role" >&2
    return 64
  }
  case "$identity" in
    web:*) web_advisor_provider_dispatch_ndjson_async "$job_id" "$prompt_file" ;;
    *)
      echo "run_model_advisor_batch_async: unsupported provider identity '$identity' for batch advisor" >&2
      return 64
      ;;
  esac
}

# run_codex_text <cwd> <model> <effort> <timeout_minutes> <prompt_file>
# <transcript_file> -- same sandboxing as run_codex_json() above (--sandbox
# read-only, --cd, --skip-git-repo-check, --ephemeral), but WITHOUT
# --output-schema and without normalizing to {is_error, structured_output}:
# prints whatever `codex exec` wrote to --output-last-message, verbatim, on
# stdout, and returns codex's own exit status -- unconditionally, on
# success or failure. Combined stdout+stderr goes to <transcript_file>
# (caller-owned: create it, read it for diagnostics if stdout comes back
# empty, clean it up) rather than into a mktemp this function hides, since a
# caller here has nowhere else to route a real error otherwise -- there is
# no {is_error, result} envelope to carry it in.
#
# The one caller (run-advisor-batch.sh) asks the model for NDJSON, one JSON
# object per line, not a single document a schema could validate as a
# whole: --output-schema validates the ENTIRE response as one JSON value, so
# a response a model's own output-token budget cuts off partway would fail
# closed on everything, discarding rulings that were already complete
# before the cutoff -- exactly what that leg's own "never all-or-nothing"
# requirement exists to avoid at a size (dozens of structured rulings out)
# nothing calling run_codex_json() has ever carried. This function does no
# interpretation at all; the caller parses its own NDJSON line by line and
# decides what "failed" means for each line independently -- a complete
# line that happens to arrive after a status!=0 (codex hit its own timeout
# or was killed mid-stream, but had already flushed --output-last-message)
# is still a line worth trying to parse, so this always prints whatever the
# output file holds, never conditioned on `status`.
run_codex_text() {
  local cwd="$1" model="$2" effort="$3" timeout_minutes="$4" prompt_file="$5" transcript_file="$6" service_tier
  local -a service_tier_args=()
  local out_file status=0 started_at elapsed timeout_detail
  model_policy_require_implementer_identity "codex:$model:$effort" || return $?
  service_tier="$(model_policy tier "codex:$model:$effort")" || return $?
  [ -z "$service_tier" ] || service_tier_args=(-c "service_tier=\"$service_tier\"")
  out_file="$(mktemp)"
  # `|| status=$?`, not `set +e; ...; set -e` -- see run_codex_json()'s own
  # comment above for why: this function is always called from inside a
  # `$(...)` capture (its payload IS its stdout), which already shields the
  # caller's shell from this toggle regardless, but matching the sibling
  # function's idiom keeps the two functions safe to read the same way.
  started_at="$(date +%s)"
  pipeline_execution_run timeout "${timeout_minutes}m" codex exec \
    --sandbox "$CODEX_SANDBOX_MODE" --cd "$cwd" --skip-git-repo-check --ephemeral \
    -m "$model" -c model_reasoning_effort="$effort" "${service_tier_args[@]}" \
    -c mcp_servers.gitnexus.enabled=false \
    --output-last-message "$out_file" \
    - < "$prompt_file" > "$transcript_file" 2>&1 || status=$?
  elapsed=$(( $(date +%s) - started_at ))
  [ "$status" -eq 0 ] || printf 'codex-exec-elapsed-seconds=%s\n' "$elapsed" >> "$transcript_file"
  if [ "$status" -eq 124 ]; then
    timeout_detail="codex exec timed out after $((timeout_minutes * 60))s (elapsed ${elapsed}s)"
    printf '%s\n' "$timeout_detail" >> "$transcript_file"
    echo "$timeout_detail" >&2
  fi
  if [ -s "$out_file" ]; then
    printf '\ncodex-final-output-present=true\n' >> "$transcript_file"
  else
    printf '\ncodex-final-output-present=false\n' >> "$transcript_file"
  fi
  cat "$out_file" 2>/dev/null
  rm -f "$out_file"
  return "$status"
}

# run_codex_implement <cwd> <model> <effort> <prompt_file> <log_file> -- runs
# `codex exec` for a FREEFORM code-editing task (the implement/repair role:
# read the brief, write files, run local commands, `git commit`), not a
# structured-JSON decision -- see run_codex_json() above for that shape.
# Runs with `--sandbox "$CODEX_SANDBOX_MODE" --cd <cwd>` (danger-full-access by default since 2026-10-06): Codex should write only
# under <cwd> (matches the model call implement call's own `--add-dir "$WT"`
# plus its cwd -- the one directory the model may write into).
#
# 2026-09-18 (issue #1347, containment follow-up): network access IS on for
# this call -- `-c sandbox_workspace_write.network_access=true` below -- so
# database-backed integration tests (loopback Postgres, testcontainers) can
# run. That grant used to live in ~/.codex/config.toml (global, every codex
# invocation on this box); it is scoped to just this one call site now, so
# the advisor leg, the guarded-review leg, and the maintainer's own interactive
# `codex` sessions stay network-denied by default. Confirmed live (no model
# call spent): `codex exec --strict-config -c
# sandbox_workspace_write.network_access=true` flips the startup banner from
# "sandbox: workspace-write [workdir, /tmp, $TMPDIR]" to "... (network
# access enabled)" with no grant in config.toml at all, so the per-invocation
# `-c` is sufficient on its own -- config.toml does not need the section
# back.
#
# Network denial used to BE this function's whole containment story (the
# comment this replaces said so). It no longer is: with the sandbox open,
# `env -u GH_TOKEN -u GITHUB_TOKEN` strips this pipeline's own GitHub
# credentials from just this child process before exec -- GH_TOKEN reaches
# this shell via the systemd unit's `EnvironmentFile=` (~/.zenoforge/env)
# and would otherwise be reachable from inside an unattended, now
# network-enabled Codex run. The wrapper (run-implement.sh) deliberately
# performs every `gh`/`git push` operation itself outside the sandbox, and
# the prompt text it builds for `codex:*` models says plainly that Codex
# cannot reach `gh` and should not try (see run-implement.sh's
# `case "$IMPLEMENT_MODEL" in codex:*)` block, in the `{ ... } >
# "$PROMPT_FILE"` section) -- that was never conditioned on the
# sandbox denying network, so stripping the credential here changes nothing
# the model is supposed to do, only what an off-script attempt could reach.
# Checked: the wrapper's own environment (systemd unit + ~/.zenoforge/env)
# never sets GH_ENTERPRISE_TOKEN or GITHUB_ENTERPRISE_TOKEN, so there is
# nothing enterprise-flavored to strip here today.
#
# `--sandbox workspace-write` otherwise still applies -- Codex may still
# only write under <cwd>, /tmp, and $TMPDIR, same as before. This is a
# Codex-CLI-enforced filesystem boundary, not a container/VM/restricted OS
# user. It does not create a separate control-surface admission rule.
#
# Combined stdout+stderr goes to <log_file> -- the same capture shape the
# model call implement/repair call sites already use (IMPLEMENT_LOG/
# REPAIR_LOG) -- and this returns codex's own exit status, the same
# contract those call sites already branch on ($STATUS -ne 0 ->
# fail_attempt()). No --output-schema here (there is no structured verdict
# to conform to for a code-writing pass); the caller's own downstream gates
# (git diff --check, run_package_gates, the independent code review) are
# what actually verify the result, exactly as they already do for a
# model call implement pass -- this function does not weaken or replace any
# of them.
run_codex_implement() {
  local cwd="$1" model="$2" effort="$3" prompt_file="$4" log_file="$5" timeout_minutes="${6:-120}" caller="${7:-unknown}" status=0 service_tier
  local -a service_tier_args=()
  local started_at elapsed timeout_detail out_file transcript_empty=true diagnostic signal_name issue stage model_identity
  MODEL_CALL_EXIT_STATUS=""
  MODEL_CALL_EXIT_CLASS=""
  MODEL_CALL_LOG_PATH="$log_file"
  MODEL_CALL_CALLER="$caller"
  MODEL_CALL_STAGE="${caller##*:}"
  MODEL_CALL_TERMINATION_SOURCE=""
  MODEL_CALL_TERMINATION_EVIDENCE=""
  MODEL_CALL_TRANSCRIPT_EMPTY=false
  model_policy_require_implementer_identity "codex:$model:$effort" || { printf 'run_codex_implement: model identity does not match the work role\n' > "$log_file"; return 64; }
  service_tier="$(model_policy tier "codex:$model:$effort")" || return $?
  [ -z "$service_tier" ] || service_tier_args=(-c "service_tier=\"$service_tier\"")
  out_file="$(mktemp)"
  # `|| status=$?`, not `set +e; ...; set -e` -- see run_codex_json()'s own
  # comment above for why: this function is always called as a bare
  # statement (it has no meaningful stdout to capture via command
  # substitution, unlike run_codex_json()), so an internal `set -e` toggle
  # here would leak directly into run-implement.sh's own shell the moment
  # this returns nonzero, killing the whole script before fail_attempt()
  # ever runs -- confirmed live while writing this function's own test in
  # lib.test.sh. `env -u GH_TOKEN -u GITHUB_TOKEN` sits between `timeout` and
  # `codex` (not around the whole pipeline) so it only strips those two vars
  # from codex's own child environment -- this function's caller, and this
  # shell, keep them.
  started_at="$(date +%s)"
  pipeline_execution_run timeout "${timeout_minutes}m" env -u GH_TOKEN -u GITHUB_TOKEN codex exec \
    --sandbox "$CODEX_SANDBOX_MODE" --cd "$cwd" --skip-git-repo-check --ephemeral \
    -m "$model" -c model_reasoning_effort="$effort" "${service_tier_args[@]}" \
    -c sandbox_workspace_write.network_access=true \
    -c mcp_servers.gitnexus.enabled=false \
    --output-last-message "$out_file" \
    - < "$prompt_file" > "$log_file" 2>&1 || status=$?
  elapsed=$(( $(date +%s) - started_at ))
  if [ -s "$log_file" ] || [ -s "$out_file" ]; then transcript_empty=false; fi
  [ "$status" -eq 0 ] || printf 'codex-exec-elapsed-seconds=%s\n' "$elapsed" >> "$log_file"
  MODEL_CALL_EXIT_STATUS="$status"
  MODEL_CALL_EXIT_CLASS="$(model_call_exit_class "$status")"
  MODEL_CALL_TRANSCRIPT_EMPTY="$transcript_empty"
  issue="${N:-unknown}"
  stage="${caller##*:}"
  [ -n "$stage" ] || stage=unknown
  model_identity="codex:$model:$effort"
  if [ "$status" -eq 124 ]; then
    MODEL_CALL_TERMINATION_SOURCE=timeout_wrapper
    MODEL_CALL_TERMINATION_EVIDENCE="timeout returned exit 124 after ${elapsed}s"
  elif [ "$MODEL_CALL_EXIT_CLASS" = signal_termination ]; then
    signal_name="$(model_call_signal_name "$status")"
    model_call_capture_termination_source "$issue"
    MODEL_CALL_TERMINATION_EVIDENCE="signal=$signal_name; $MODEL_CALL_TERMINATION_EVIDENCE"
  else
    MODEL_CALL_TERMINATION_SOURCE=process_exit
    MODEL_CALL_TERMINATION_EVIDENCE="codex exec returned exit $status"
  fi
  if [ "$status" -eq 124 ]; then
    timeout_detail="codex implement timed out after $((timeout_minutes * 60))s (elapsed ${elapsed}s)"
    printf '%s\n' "$timeout_detail" >> "$log_file"
    echo "$timeout_detail" >&2
  fi
  if [ "$status" -ne 0 ]; then
    signal_name=""
    if [ "$MODEL_CALL_EXIT_CLASS" = signal_termination ]; then
      signal_name=" signal=$(model_call_signal_name "$status")"
    fi
    diagnostic="model_call_exit_status=$status termination_class=$MODEL_CALL_EXIT_CLASS$signal_name issue=$issue stage=$stage caller=$caller provider=codex model=$model_identity timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ) termination_source=$MODEL_CALL_TERMINATION_SOURCE termination_evidence=$MODEL_CALL_TERMINATION_EVIDENCE log_path=$log_file transcript_empty=$transcript_empty"
    printf '%s\n' "$diagnostic" >> "$log_file"
    printf '%s\n' "$diagnostic" >&2
  fi
  if [ -s "$out_file" ]; then
    printf '\ncodex-final-output-present=true\ncodex-final-message-begin\n' >> "$log_file"
    jq -Rrs 'if length > 4000 then .[-4000:] else . end' "$out_file" >> "$log_file"
    # Keep bounded check-block markers from the full final message after the
    # display tail, so the caller can route blocked runs before cleanup.
    awk '/^BLOCKED-CHECKS:[[:space:]]*[^[:space:]]/ && count < 10 { print substr($0, 1, 500); count++ }' "$out_file" >> "$log_file"
    printf '\n' >> "$log_file"
  else
    printf '\ncodex-final-output-present=false\n' >> "$log_file"
  fi
  rm -f "$out_file"
  return "$status"
}

# Provider dispatch ----------------------------------------------------------
run_model_json() {
  local cwd="$1" identity="$2" timeout_minutes="$3" schema_file="$4" prompt_file="$5" settings_file="$6" role="${7:-work}"
  local codex_id
  timeout_minutes="$(model_timeout_for_attempt "$timeout_minutes" "${N:-}")"
  model_policy_require_stage_identity "$role" "$identity" || {
    jq -nc --arg role "$role" '{is_error: true, subtype: "unsupported_model_identity", result: ("identity does not match the " + $role + " role")}'
    return 64
  }
  case "$identity" in
    codex:*)
      codex_id="${identity#codex:}"
      if [[ "$codex_id" != *:* ]]; then
        jq -nc --arg identity "$identity" '{is_error: true, subtype: "unsupported_model_identity", result: ("codex identity needs model:effort: " + $identity)}'
        return 64
      fi
      ( CODEX_JSON_TIMEOUT_SECONDS=$((timeout_minutes * 60)) run_codex_json "$cwd" "${codex_id%:*}" "${codex_id#*:}" "$schema_file" "$prompt_file" )
      ;;
    zcode:*)
      ( run_zcode_json "$cwd" "$identity" "$timeout_minutes" "$schema_file" "$prompt_file" )
      ;;
    web:*)
      ( WEB_ADVISOR_PROVIDER_TIMEOUT_SECONDS=$((timeout_minutes * 60)) run_web_advisor_provider_json "$schema_file" "$prompt_file" )
      ;;
    *)
      jq -nc '{is_error: true, subtype: "unsupported_model_provider", result: "provider is not allowed for this stage"}'
      return 64
      ;;
  esac
}

run_model_text() {
  local cwd="$1" identity="$2" timeout_minutes="$3" prompt_file="$4" transcript_file="$5" settings_file="$6"
  local codex_id
  model_policy_require_implementer_identity "$identity" || return $?
  case "$identity" in
    codex:*)
      codex_id="${identity#codex:}"
      [[ "$codex_id" == *:* ]] || { echo "run_model_text: codex identity needs model:effort: $identity" >&2; return 64; }
      run_codex_text "$cwd" "${codex_id%:*}" "${codex_id#*:}" "$timeout_minutes" "$prompt_file" "$transcript_file"
      ;;
    web:*)
      echo "run_model_text: web provider does not support raw text calls" >&2
      return 64
      ;;
    *) echo "run_model_text: unsupported provider identity" >&2; return 64 ;;
  esac
}

run_model_implement() {
  local cwd="$1" identity="$2" timeout_minutes="$3" prompt_file="$4" log_file="$5" settings_file="$6" caller="${7:-unknown}"
  local codex_id
  MODEL_CALL_EXIT_STATUS=""
  MODEL_CALL_EXIT_CLASS=""
  MODEL_CALL_LOG_PATH="$log_file"
  MODEL_CALL_CALLER="$caller"
  MODEL_CALL_STAGE="${caller##*:}"
  MODEL_CALL_TERMINATION_SOURCE=""
  MODEL_CALL_TERMINATION_EVIDENCE=""
  MODEL_CALL_TRANSCRIPT_EMPTY=false
  timeout_minutes="$(model_timeout_for_attempt "$timeout_minutes" "${N:-}")"
  if ! model_policy_require_implementer_identity "$identity"; then
    printf 'run_model_implement: model identity does not match the work role\n' > "$log_file"
    return 64
  fi
  case "$identity" in
    codex:*)
      codex_id="${identity#codex:}"
      if [[ "$codex_id" != *:* ]]; then
        printf 'run_model_implement: codex identity needs model:effort: %s\n' "$identity" > "$log_file"
        return 64
      fi
      run_codex_implement "$cwd" "${codex_id%:*}" "${codex_id#*:}" "$prompt_file" "$log_file" "$timeout_minutes" "$caller"
      ;;
    web:*)
      printf 'run_model_implement: web provider cannot perform workspace-write implementation\n' > "$log_file"
      return 64
      ;;
    *) printf 'run_model_implement: unsupported provider identity\n' > "$log_file"; return 64 ;;
  esac
}

# --- recut leg (engine/run-recut.sh) --------------------------------
# Rung 2 of the ladder above. A ticket enforce_autonomy_gate() refuses at
# EVERY phase (P2 risk_class, or L3/L4 level) is not handed to a human; the
# gate is the maintainer's boundary for the STANDARD rung and this pipeline
# never widens that rung. The first fix for an oversized ticket is a smaller
# ticket: recut cuts one oversized ticket into children small enough for
# enforce_autonomy_gate to admit on their own merits, decided by a fresh
# triage run on each child, never hand-stamped by recut itself. A ticket
# recut cannot split goes UP to rung 3 (admit_guarded), not out to a human.

# The guard that decides whether a ticket is the KIND recut is for: pure
# re-derivation from enforce_autonomy_gate() itself (never a reimplementation
# of its P0/P1/L3/L4 cases), same "narrows, never grants" contract that
# function's own callers already rely on -- run-recut.sh calls this instead
# of inlining a second copy of the P0/P1/L3/L4 logic that could drift from
# the real gate. True iff NEITHER phase 2 nor phase 3 would ever admit this
# risk_class/level combination -- a ticket admissible at phase 3 (e.g.
# P1/L2) is merely phase-gated, a policy dial the maintainer can turn by
# raising AGENT_PHASE, not a shape problem cutting into children would fix.
recut_categorically_oversized() {
  local risk_class="$1" level="$2"
  [ "$(enforce_autonomy_gate ready-for-agent "$risk_class" "$level" 2)" != "ready-for-agent" ] &&
    [ "$(enforce_autonomy_gate ready-for-agent "$risk_class" "$level" 3)" != "ready-for-agent" ]
}

# The hard "never fabricate" gate. Of 23 tickets hand-cut on 2026-09-14, 3
# produced slices that were pure invention -- freshly-declared types with no
# callers -- because the domain had zero real implementation; those were
# closed on the spot. Prompt-only compliance measured under 2% on this
# codebase, so this re-verifies every file and symbol a proposed child
# claims to touch against the ACTUAL checkout on disk -- $3, always the
# just-created `origin/main` worktree, never the model's own claim -- rather
# than trusting the model's own domain_verified flag. $1: JSON array of file
# paths (relative to the checkout root). $2: JSON array of symbol/type/
# function/table names. True only if every file in $1 exists under $3, AND
# every symbol in $2 greps (literal, not regex) somewhere inside at least
# one of those same files -- a symbol that only appears in an unrelated file
# is exactly the "invented, no real caller" shape this exists to catch. An
# empty files array with a non-empty symbols array always fails (nothing to
# grep), which is correct: a slice cannot name a symbol without also naming
# where it lives.
recut_slice_verified() {
  local files_json="$1" symbols_json="$2" dir="$3" f s found
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -f "$dir/$f" ] || return 1
  done < <(echo "$files_json" | jq -r '.[]?')
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    found=0
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      grep -qF -- "$s" "$dir/$f" 2>/dev/null && { found=1; break; }
    done < <(echo "$files_json" | jq -r '.[]?')
    [ "$found" = "1" ] || return 1
  done < <(echo "$symbols_json" | jq -r '.[]?')
  return 0
}

# Small, dedicated predicate purely so lib.test.sh can pin the child cap in
# isolation, the same way cap_slots_remaining() above is tested apart from
# any live systemctl/gh call. $1: how many children the model proposed. $2:
# the cap. True iff there is at least one child (an empty batch is refused
# by run-recut.sh's own domain_verified/children-empty check, not this) and
# no more than the cap -- a tracker flooded with auto-generated tickets is a
# worse outcome than the parked ticket recut started from.
recut_child_count_ok() {
  local count="$1" cap="$2"
  [ "$count" -ge 1 ] && [ "$count" -le "$cap" ]
}

# `gh issue create --blocked-by` needs its blockers to already exist as real
# issue numbers, but recut's own proposed children only know each other by
# 0-based array INDEX (no real numbers exist until creation) -- so children
# must be created in an order where every blocker already exists. Kahn's
# algorithm, tiny N (bounded by the child cap): topologically orders $1 (the
# JSON `children` array; each item need only carry its own
# `blocked_by_child_indices`), printing one 0-based index per line in a safe
# creation order. Returns non-zero and prints nothing if the declared edges
# contain a cycle -- gh has no way to satisfy a blocker that doesn't exist
# yet, and run-recut.sh voids the whole batch on this rather than silently
# dropping an edge.
recut_topo_order() {
  local children_json="$1" count placed_json="[]" i j ready pass
  local -a order=()
  count="$(echo "$children_json" | jq 'length')"
  [ "$count" -eq 0 ] && return 0
  for ((pass = 0; pass < count; pass++)); do
    for ((i = 0; i < count; i++)); do
      echo "$placed_json" | jq -e --argjson i "$i" 'index($i) != null' > /dev/null && continue
      ready=1
      while IFS= read -r j; do
        [ -z "$j" ] && continue
        echo "$placed_json" | jq -e --argjson j "$j" 'index($j) != null' > /dev/null || { ready=0; break; }
      done < <(echo "$children_json" | jq -r ".[$i].blocked_by_child_indices[]?")
      if [ "$ready" = "1" ]; then
        order+=("$i")
        placed_json="$(echo "$placed_json" | jq --argjson i "$i" '. + [$i]')"
      fi
    done
  done
  [ "${#order[@]}" -eq "$count" ] || return 1
  printf '%s\n' "${order[@]}"
}

# 2026-09-13 #1098: run-triage.sh's ISSUE_JSON gives the model the full
# comment history but nothing about what actually happened to a PR that
# history mentions -- a PR's own state (closed, branch deleted) changes
# without ever posting a new issue comment, so a stale "PR #1099 left open,
# needs a human" comment from hours earlier still reads as current. The
# model cannot check for itself: `gh` is denied in prompts/agent-
# settings.json. Live proof: #1098's triage run read exactly that stale
# comment and returned state=finish-first citing PR #1099, which by then was
# CLOSED with its branch (`agent/issue-1098`) deleted -- and issue-
# pipeline.sh's section (c0) sends a finish-first issue with no colliding
# open PR/expected_packages straight back to needs-triage, so the very next
# triage run reads the same stale comment and returns finish-first again.
# An infinite loop, not a one-off.
#
# This function only renders; run-triage.sh gathers $2 with live `gh pr
# list`/`gh api .../branches/..` calls (outside the model's sandbox) before
# ever building the prompt. $2 is a JSON array of {number, state, isDraft,
# headRefName, branch_exists} -- branch_exists is the one signal a comment
# cannot carry, because it is derived from the CURRENT remote, not from
# anything anyone wrote. $3 is "1" when those `gh` queries themselves
# succeeded, "0" on any failure -- a failure must say so plainly and let
# triage proceed on its other evidence (issue thread, code reading), never
# render an empty block indistinguishable from "confirmed zero PRs".
render_pr_state_block() {
  local n="$1" prs_json="$2" query_ok="${3:-1}"
  echo "## Live pull request state for issue #$n (queried live via gh by the wrapper, not read from the thread)"
  if [ "$query_ok" != "1" ]; then
    echo "PR query failed. Treat live PR state as unknown for this run -- proceed with triage on the evidence above; a \`gh\` hiccup here is not a reason to withhold or grant any state."
    return 0
  fi
  local count
  count="$(echo "$prs_json" | jq 'length' 2>/dev/null || echo 0)"
  if [ "$count" -eq 0 ]; then
    echo "No open, closed, or merged pull request currently references issue #$n (checked head branch \`agent/issue-$n\` and any PR whose title or body mentions \`#$n\`)."
    return 0
  fi
  echo "$prs_json" | jq -r '
    .[] | "- PR #\(.number): \(.state)" +
      (if .isDraft then " (draft)" else "" end) +
      ", head branch `\(.headRefName)`, branch " +
      (if .branch_exists then "still exists on the remote" else "deleted from the remote" end)
  '
}

# 2026-09-12 defect 2: run-implement.sh's CI poll treated any check with
# bucket=="skipping" as a failure. Every PR in this repo always carries
# `skipping` rows, because ci.yml's push-triggered and pull_request-triggered
# workflow runs each skip the other's jobs (GitHub still reports both run's
# rows on the PR) — measured live on PR #1099: pass:5, skipping:7, fail:0,
# cancel:0, which the old `bucket=="skipping"` check classified `fail`,
# meaning no agent PR could ever merge. Dropping `skipping` from the failure
# condition outright would open a real hole instead: ci.yml:378's
# pr-touched-packages job (and the repo's four other PR-gate jobs) each carry
# an `if:` condition, and a bad edit there that makes a job skip on every PR
# would then sail through unnoticed.
#
# REQUIRED_PR_CHECKS pins the aggregate gates (alls-green rows, #4484); a future rename
# without updating the definition still fails CLOSED.
REQUIRED_PR_CHECKS=("required-pr-checks.json unreadable")
if _agent_required_pr_checks="$(jq -ce '
  select((.required | type) == "array" and (.required | length) > 0)
' "$_AGENT_LIB_DIR/mac-autopilot/required-pr-checks.json" 2>/dev/null)"; then
  mapfile -t REQUIRED_PR_CHECKS < <(jq -r '.required[]' <<< "$_agent_required_pr_checks")
fi
unset _agent_required_pr_checks _AGENT_LIB_DIR

# One row per check name on the PR's current head, via the shared
# pr-required-aggregate.mjs --latest-checks reduction: SKIPPED rows are
# dropped and superseded same-name runs collapse to the newest run (the
# semantics live in that module). `gh pr checks` exposes the Actions run id
# in its link; PR statusCheckRollup rows carry a start/creation timestamp.
pr_latest_check_rows() {
  local lib_dir
  lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  node "$lib_dir/ci/pr-required-aggregate.mjs" --latest-checks <<< "$1"
}

# Classifies a `gh pr checks --json name,bucket[,link]` array ($1) into one
# of: pass / pending / fail, after discarding superseded same-name runs. Order matters:
#   1. any bucket=="fail"/"cancel" ANYWHERE fails the whole rollup immediately
#      -- no reason to keep waiting on an unrelated still-pending check once
#      something has definitively failed.
#   2. any bucket=="pending" left (on anything) means CI is still running --
#      keep waiting.
#   3. otherwise, every name in REQUIRED_PR_CHECKS must have at least one
#      pass row. The required rows are the always-concluding aggregates
#      (#4484): each one already rolls up its workflow's gates (pass, or a
#      legitimate skip), so no per-gate enumeration happens here anymore.
#      Missing rows fail closed; skipped rows never reach this far (the
#      --latest-checks reduction above drops them). Non-required check names
#      (this repo has no branch protection, so `gh pr checks` returns whatever
#      ran) are otherwise ignored -- see lib.test.sh for fixtures plus
#      real-failure, missing-required, skipped, and pending cases.
pr_checks_outcome() {
  local checks_json="$1" name rows latest_checks
  latest_checks="$(pr_latest_check_rows "$checks_json" 2>/dev/null)" || { echo "fail"; return 0; }
  checks_json="$latest_checks"
  if echo "$checks_json" | jq -e '.[] | select(.bucket=="fail" or .bucket=="cancel")' > /dev/null 2>&1; then
    echo "fail"
    return 0
  fi
  if echo "$checks_json" | jq -e '.[] | select(.bucket=="pending")' > /dev/null 2>&1; then
    echo "pending"
    return 0
  fi
  for name in "${REQUIRED_PR_CHECKS[@]}"; do
    rows="$(echo "$checks_json" | jq --arg n "$name" '[.[] | select(.name==$n)]')"
    if ! echo "$rows" | jq -e '.[] | select(.bucket=="pass")' > /dev/null 2>&1; then
      echo "fail"
      return 0
    fi
  done
  echo "pass"
}

# risk_class_hits_for_paths <newline-separated-paths>
#
# classifyWithKind() (risk-class.mjs), given an explicit path list instead
# of a git range -- risk-class.mjs's own CLI entrypoint always re-derives
# the path list itself via `git diff --name-only <range>` in cwd, which
# needs a real local checkout with that range available. The unattended
# merge sweeper has neither: it only ever has the file list GitHub itself
# already returned (`gh pr view --json files`). Same rule list, same
# classification, one source of truth (risk-class.mjs) -- just fed from
# whichever path source the caller actually has. lib_dir (not SCRIPT_DIR,
# a caller-only variable this file must not depend on -- see
# advisor_footprint_risky() above) is this file's OWN directory; risk-
# class.mjs always lives right next to lib.sh, by construction.
risk_class_hits_for_paths() {
  local paths="$1" lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  RISK_CLASS_MODULE="$lib_dir/risk-class.mjs" node --input-type=module -e '
    const { classifyWithKind } = await import(process.env.RISK_CLASS_MODULE);
    const fs = await import("node:fs");
    const paths = fs.readFileSync(0, "utf8").split("\n").filter(Boolean);
    console.log(JSON.stringify(classifyWithKind(paths)));
  ' <<< "$paths"
}

# ci_run_is_retryable_infra_failure <run_id> [issue] [pr] [allow-flake-retry]
#
# Exit 0 for a known open flake or known transient transport failure, 1 for a
# real failure, and 2 when GitHub cannot classify it. Checkout failures are
# visible in job steps. Container image pulls fail before steps exist, so
# inspect failed logs for the observed Docker Hub DNS/connect timeout signature
# instead of treating every pre-step failure as retryable. Both the live CI
# poll and unattended sweeper share this classifier.
ci_flake_state_lock() {
  mkdir -p "$STATE_DIR/locks" || return 1
  exec {CI_FLAKE_LOCK_FD}>"$STATE_DIR/locks/ci-flake-signatures.lock" || return 1
  flock "$CI_FLAKE_LOCK_FD"
}

ci_flake_state_unlock() {
  [[ "${CI_FLAKE_LOCK_FD:-}" =~ ^[0-9]+$ ]] || return 0
  flock -u "$CI_FLAKE_LOCK_FD"
  exec {CI_FLAKE_LOCK_FD}>&-
  unset CI_FLAKE_LOCK_FD
}

ci_flake_state_ensure_unlocked() {
  CI_FLAKE_STATE_FILE="$STATE_DIR/ci-flake-signatures.json"
  mkdir -p "$STATE_DIR" || return 1
  if [[ -e "$CI_FLAKE_STATE_FILE" ]]; then
    jq -e '.version == 1 and (.signatures | type == "array") and (.occurrences | type == "array")' \
      "$CI_FLAKE_STATE_FILE" >/dev/null 2>&1
    return $?
  fi
  # One-time migration from the old model-policy list; active lookups use this state file.
  local seed tmp
  seed="$(jq -c '.hand_loop_breaker.known_flakes // []' "$MODEL_POLICY_DEFAULT")" || return 1
  tmp="$(mktemp "$CI_FLAKE_STATE_FILE.XXXXXX")" || return 1
  if ! jq -n --argjson signatures "$seed" '{version:1,signatures:$signatures,occurrences:[]}' > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 600 "$tmp" && mv -f -- "$tmp" "$CI_FLAKE_STATE_FILE"
}

ci_flake_state_write_unlocked() {
  local state="$1" tmp
  jq -e '.version == 1 and (.signatures | type == "array") and (.occurrences | type == "array")' \
    <<< "$state" >/dev/null 2>&1 || return 1
  tmp="$(mktemp "$CI_FLAKE_STATE_FILE.XXXXXX")" || return 1
  printf '%s\n' "$state" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" && mv -f -- "$tmp" "$CI_FLAKE_STATE_FILE"
}

ci_flake_log_has_failure_marker() {
  local log
  log="$(sed -E 's/\x1B\[[0-9;?]*[[:alpha:]]//g' <<< "$1")"
  grep -Eiq '(^|[[:space:]])FAIL([[:space:]]|$)|not ok[[:space:]]+[0-9]+[[:space:]]+-|^[[:space:]]*FAILED([[:space:]]|$)|[1-9][0-9,]*[[:space:]]+failed([[:space:](]|$)|failed[[:space:]]*\([1-9][0-9,]*\)' <<< "$log"
}

ci_flake_log_passed_tests() {
  grep -Eiq '(Test Files|Tests?)[[:space:]]+[0-9][0-9,]*[[:space:]]+passed([[:space:](]|$)' <<< "$1"
}

ci_flake_log_unhandled_error() {
  grep -Eiq '[1-9][0-9,]*[[:space:]]+unhandled[[:space:]]+errors?' <<< "$1"
}

ci_flake_error_signature() {
  sed -E 's/\x1B\[[0-9;?]*[[:alpha:]]//g' <<< "$1" | awk '
    function clean(s) {
      sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s)
      gsub(/[[:space:]]+/, " ", s)
      return substr(s, 1, 240)
    }
    {
      line=$0
      if (match(line, /[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][[:space:]]+[^[:space:]].*/)) {
        print clean(substr(line, RSTART, RLENGTH)); exit
      }
      if (match(line, /(Unhandled Rejection|[[:alpha:]_]*Error):[[:space:]].*/)) {
        value=substr(line, RSTART, RLENGTH)
        sub(/^(Unhandled Rejection|[[:alpha:]_]*Error):[[:space:]]*/, "", value)
        print clean(value); exit
      }
    }
  '
}

ci_flake_record_matches_log() {
  local log="$1" record="$2" failed_test_id="${3:-}"
  local signature requires_passed test_name bound bound_seconds
  signature="$(jq -r '.signature // empty' <<< "$record")"
  requires_passed="$(jq -r '.requires_passed_tests // false' <<< "$record")"
  test_name="$(jq -r '.test // empty' <<< "$record")"
  bound="$(jq -r '.bound_ms // empty' <<< "$record")"
  if [[ -n "$signature" ]] && grep -Fq -- "$signature" <<< "$log"; then
    if [[ "$requires_passed" == true ]]; then
      ci_flake_log_passed_tests "$log" && ! ci_flake_log_has_failure_marker "$log" || return 1
    fi
    return 0
  fi
  [[ -n "$test_name" ]] && grep -Fq -- "$test_name" <<< "$log" || return 1
  [[ -z "$failed_test_id" || "$failed_test_id" == *"$test_name"* ]] || return 1
  if [[ -n "$bound" ]]; then
    [[ "$bound" =~ ^[1-9][0-9]*$ ]] || return 1
    bound_seconds=$((bound / 1000))
    grep -Eiq "$bound[[:space:]]?ms|${bound_seconds}[[:space:]]?s(ec(ond)?s?)?" <<< "$log" || return 1
  fi
}

# Return 0 + CI_FLAKE_MATCH_RECORD for open issue, 1 for no record,
# 2 for unreadable GitHub state, 3 when only closed matching issues exist.
ci_flake_find_open_match_unlocked() {
  local log="$1" failed_test_id="${2:-}" gh_cmd="${3:-gh}" record issue state_json state closed_match=0
  CI_FLAKE_MATCH_RECORD=""
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    ci_flake_record_matches_log "$log" "$record" "$failed_test_id" || continue
    issue="$(jq -r '.issue // empty' <<< "$record")"
    [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 2
    state_json="$("$gh_cmd" issue view "$issue" --repo "$REPO" --json state 2>/dev/null)" || return 2
    state="$(jq -r '.state // "" | ascii_upcase' <<< "$state_json" 2>/dev/null)" || return 2
    case "$state" in
      OPEN) CI_FLAKE_MATCH_RECORD="$record"; return 0 ;;
      CLOSED) closed_match=1 ;;
      *) return 2 ;;
    esac
  done < <(jq -c '.signatures[]?' "$CI_FLAKE_STATE_FILE")
  (( closed_match == 1 )) && return 3
  return 1
}

ci_flake_add_match() {
  local matches="$1" record="$2" job_name="$3" issue
  issue="$(jq -r '.issue' <<< "$record")" || return 1
  jq -cn --argjson matches "$matches" --argjson record "$record" --arg job "$job_name" --arg issue "$issue" \
    'if any($matches[]; (.issue|tostring) == $issue) then $matches else $matches + [$record + {job_name:$job}] end'
}

ci_flake_report_new_signature_unlocked() {
  local signature="$1" run_id="$2" pr_number="$3" job_name="$4" log="$5"
  local hash title marker issues issue created state_json issue_state excerpt body state created_url first_run issue_json
  hash="$(printf '%s' "$signature" | sha256sum | awk '{print substr($1,1,12)}')" || return 2
  title="CI 间歇失败：测试计数全通过后出现未处理错误 [$hash]"
  marker="<!-- ci-flake-signature $hash -->"
  issues="$(gh issue list --repo "$REPO" --state all --limit 1000 --search "$hash" --json number,title 2>/dev/null)" || return 2
  issue="$(jq -r --arg title "$title" '[.[] | select(.title==$title)][0].number // empty' <<< "$issues")" || return 2
  created=0; first_run=""
  if [[ -z "$issue" ]]; then
    excerpt="$(sed -E 's/\x1B\[[0-9;?]*[[:alpha:]]//g' <<< "$log" | awk '/Test Files|Tests? [0-9]+|unhandled error|57P01|Error:/ { print; n++; if (n==8) exit }')"
    body="CI job 在所有测试通过后因 Vitest 未处理错误退出失败。

观察：run $run_id，PR #$pr_number，job $job_name，$(date -u +%Y-%m-%dT%H:%M:%SZ)。
签名：$signature

证据：
$excerpt

验收：定位并修复未处理错误根因；添加回归证据，区分真实测试失败与测试结束后的进程错误。

$marker
<!-- zenoforge-agent-comment -->"
    if [ "$(roadmap_switch_value)" = true ]; then
      created_url="$(guarded_write gh issue create --repo "$REPO" --title "$title" --label pipeline-system --body "$body")" || return 2
    else
      created_url="$(guarded_write gh issue create --repo "$REPO" --title "$title" --label pipeline-system --label ready-for-agent --body "$body")" || return 2
    fi
    if [[ "$created_url" =~ /issues/([1-9][0-9]*)$ ]]; then issue="${BASH_REMATCH[1]}"; else return 2; fi
    if [ "$(roadmap_switch_value)" = true ]; then
      issue_json="$(printf '%s' "$body" | jq -Rsc --argjson number "$issue" --arg title "$title" \
        '{number:$number,title:$title,body:.,state:"OPEN",labels:[{name:"pipeline-system"}]}')" || return 2
      issue_transition "$issue" needs-triage ci-flake-created . 0 "$issue_json" || return 2
    fi
    created=1; first_run="$run_id"
  fi
  state_json="$(gh issue view "$issue" --repo "$REPO" --json state 2>/dev/null)" || return 2
  issue_state="$(jq -r '.state // "" | ascii_upcase' <<< "$state_json")" || return 2
  [[ "$issue_state" == OPEN || "$issue_state" == CLOSED ]] || return 2
  state="$(jq --arg signature "$signature" --argjson issue "$issue" --arg run "$first_run" \
    'if any(.signatures[]?; .issue==$issue and .signature==$signature) then .
     else .signatures += [{issue:$issue,signature:$signature,requires_passed_tests:true,first_run:$run}] end' \
    "$CI_FLAKE_STATE_FILE")" || return 2
  ci_flake_state_write_unlocked "$state" || return 2
  CI_FLAKE_MATCH_RECORD="$(jq -cn --arg signature "$signature" --argjson issue "$issue" --arg run "$first_run" \
    '{issue:$issue,signature:$signature,requires_passed_tests:true,first_run:$run}')" || return 2
  CI_FLAKE_NEW_ISSUE_CREATED="$created"
  [[ "$issue_state" == OPEN ]] && return 0
  return 3
}

ci_flake_record_occurrences_unlocked() {
  local matches="$1" run_id="$2" pr_number="$3" record issue existing marker at jobs body state
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    issue="$(jq -r '.issue' <<< "$record")" || return 1
    existing="$(jq -r --argjson issue "$issue" --arg run "$run_id" --arg pr "$pr_number" \
      'any(.occurrences[]?; .issue==$issue and .run_id==$run and .pr==$pr)' "$CI_FLAKE_STATE_FILE")" || return 1
    [[ "$existing" == true ]] && continue
    marker="<!-- ci-flake-occurrence issue=$issue run=$run_id pr=$pr_number -->"
    at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jobs="$(jq -r --argjson issue "$issue" '[.[] | select(.issue==$issue) | .job_name] | unique | join(", ")' <<< "$matches")" || return 1
    body="Known CI flake occurrence: run $run_id, PR #$pr_number, job(s) $jobs, $at.
Run: https://github.com/$REPO/actions/runs/$run_id
$marker"
    guarded_write gh issue comment "$issue" --repo "$REPO" --body "$body" || return 1
    state="$(jq --argjson issue "$issue" --arg run "$run_id" --arg pr "$pr_number" --arg at "$at" \
      '.occurrences += [{issue:$issue,run_id:$run,pr:$pr,at:$at}]' "$CI_FLAKE_STATE_FILE")" || return 1
    ci_flake_state_write_unlocked "$state" || return 1
  done < <(jq -c 'unique_by(.issue)[]' <<< "$matches")
}

# Retry only registered, open signatures. New all-passed/unhandled-error
# signatures create one issue and leave their first occurrence blocking.
ci_flake_retry_failed_run() {
  local run_id="$1" issue="$2" pr_number="$3" allow_retry="$4" jobs="$5"
  local failed_jobs job_line job_id job_name log failed_ids failed_test_id match_status record first_run signature
  local status=1 matches='[]' attempt
  CI_FLAKE_CLASSIFICATION=real; CI_FLAKE_REASON=""
  # ponytail: serialize GitHub lookups under one lock; use per-signature locks if contention matters.
  ci_flake_state_lock || return 2
  if ! ci_flake_state_ensure_unlocked; then status=2
  else
    failed_jobs="$(jq -r '[.[]? | select(.conclusion=="failure")] | .[] | [.databaseId,.name] | @tsv' <<< "$jobs")" || status=2
    if [[ -n "$failed_jobs" ]]; then
      status=0
      while IFS=$'\t' read -r job_id job_name; do
        [[ "$job_id" =~ ^[1-9][0-9]*$ && -n "$job_name" ]] || { status=2; break; }
        log="$(gh run view "$run_id" --job "$job_id" --log-failed --repo "$REPO" 2>/dev/null)" || { status=2; break; }
        failed_ids="$(ci_failed_test_ids "$log")"
        if ci_flake_log_has_failure_marker "$log"; then
          [[ -n "$failed_ids" ]] || { status=1; break; }
          while IFS=$'\t' read -r _ failed_test_id; do
            [[ -n "$failed_test_id" ]] || continue
            match_status=0; ci_flake_find_open_match_unlocked "$log" "$failed_test_id" || match_status=$?
            case "$match_status" in
              0)
                first_run="$(jq -r '.first_run // empty' <<< "$CI_FLAKE_MATCH_RECORD")"
                [[ "$first_run" != "$run_id" ]] || { status=3; break; }
                matches="$(ci_flake_add_match "$matches" "$CI_FLAKE_MATCH_RECORD" "$job_name")" || { status=2; break; }
                ;;
              1|3) status=1; break ;;
              *) status=2; break ;;
            esac
          done <<< "$failed_ids"
          [[ "$status" == 0 ]] || break
        else
          match_status=0; ci_flake_find_open_match_unlocked "$log" || match_status=$?
          case "$match_status" in
            0)
              first_run="$(jq -r '.first_run // empty' <<< "$CI_FLAKE_MATCH_RECORD")"
              if [[ "$first_run" == "$run_id" ]]; then status=3; break; fi
              matches="$(ci_flake_add_match "$matches" "$CI_FLAKE_MATCH_RECORD" "$job_name")" || { status=2; break; }
              ;;
            1)
              if ci_flake_log_passed_tests "$log" && ci_flake_log_unhandled_error "$log"; then
                signature="$(ci_flake_error_signature "$log")"
                [[ -n "$signature" ]] || { status=1; break; }
                match_status=0; ci_flake_report_new_signature_unlocked "$signature" "$run_id" "$pr_number" "$job_name" "$log" || match_status=$?
                case "$match_status" in
                  0)
                    first_run="$(jq -r '.first_run // empty' <<< "$CI_FLAKE_MATCH_RECORD")"
                    if [[ "$first_run" == "$run_id" || "$CI_FLAKE_NEW_ISSUE_CREATED" == 1 ]]; then status=3; break; fi
                    matches="$(ci_flake_add_match "$matches" "$CI_FLAKE_MATCH_RECORD" "$job_name")" || { status=2; break; }
                    ;;
                  3) status=1; break ;;
                  *) status=2; break ;;
                esac
              else status=1; break
              fi
              ;;
            3) status=1; break ;;
            *) status=2; break ;;
          esac
        fi
      done <<< "$failed_jobs"
    fi
  fi
  if [[ "$status" == 0 ]]; then
    if [[ ! "$issue" =~ ^[1-9][0-9]*$ || ! "$pr_number" =~ ^[1-9][0-9]*$ ]]; then status=2
    else
      attempt="$(gh run view "$run_id" --repo "$REPO" --json attempt -q .attempt 2>/dev/null)" || attempt=""
      if [[ "$attempt" != 1 || "$allow_retry" != 1 ]]; then
        status=1; CI_FLAKE_CLASSIFICATION=exhausted; CI_FLAKE_REASON="known flake has no remaining run attempt"
      elif ! ci_flake_record_occurrences_unlocked "$matches" "$run_id" "$pr_number"; then status=2
      elif ! guarded_write gh run rerun "$run_id" --repo "$REPO" --failed; then status=2
      else
        CI_FLAKE_CLASSIFICATION=rerun; CI_FLAKE_REASON="known flake rerun once"; status=0
      fi
    fi
  elif [[ "$status" == 3 ]]; then
    CI_FLAKE_CLASSIFICATION=new-signature; CI_FLAKE_REASON="new all-passed/unhandled-error signature filed"
  elif [[ "$status" == 2 ]]; then CI_FLAKE_CLASSIFICATION=unknown
  fi
  ci_flake_state_unlock || true
  return "$status"
}

ci_flake_log_matches_open_issue() {
  local log="$1" gh_cmd="${2:-gh}" match_status=1 failed_ids failed_test_id
  ci_flake_state_lock || return 2
  if ! ci_flake_state_ensure_unlocked; then match_status=2
  elif ci_flake_log_has_failure_marker "$log"; then
    failed_ids="$(ci_failed_test_ids "$log")"
    if [[ -n "$failed_ids" ]]; then
      match_status=0
      while IFS=$'\t' read -r _ failed_test_id; do
        [[ -n "$failed_test_id" ]] || continue
        ci_flake_find_open_match_unlocked "$log" "$failed_test_id" "$gh_cmd" || match_status=$?
        [[ "$match_status" == 0 ]] || break
      done <<< "$failed_ids"
    fi
  else
    match_status=0
    ci_flake_find_open_match_unlocked "$log" "" "$gh_cmd" || match_status=$?
  fi
  ci_flake_state_unlock || true
  return "$match_status"
}

ci_run_is_retryable_infra_failure() {
  local run_id="$1" issue="${2:-0}" pr_number="${3:-0}" allow_flake_retry="${4:-0}" jobs checkout_failed capacity_gate_failed failed_step_count failed_job_without_steps logs capacity_f capacity_since seen now lock_fd flake_status=0
  CI_RETRYABLE_INFRA_REASON=""
  CI_RETRYABLE_INFRA_KIND=""
  [ -n "$run_id" ] || return 1
  jobs="$(gh run view "$run_id" --repo "$REPO" --json jobs -q '.jobs' 2>/dev/null)" || return 2
  checkout_failed="$(jq -r '[.[]? | .steps[]? | select((.name | startswith("Run actions/checkout")) and .conclusion=="failure")] | length > 0' <<< "$jobs")" || return 2
  if [ "$checkout_failed" = true ]; then
    CI_RETRYABLE_INFRA_REASON="GitHub Actions checkout step failed before project checks"
    CI_RETRYABLE_INFRA_KIND=transport
    record_env_fault env:ci-checkout infrastructure "$issue" "$CI_RETRYABLE_INFRA_REASON" "" "" 0 || true
    return 0
  fi
  capacity_gate_failed="$(jq -r '[.[]? | .steps[]? | select(.name=="Ensure CI runner has capacity before dependency install" and .conclusion=="failure")] | length > 0' <<< "$jobs")" || return 2
  if [ "$capacity_gate_failed" = true ]; then
    CI_RETRYABLE_INFRA_REASON="CI runner capacity gate failed: Ensure CI runner has capacity before dependency install"
    CI_RETRYABLE_INFRA_KIND=capacity
    mkdir -p "$AGENT_HOME/locks"
    exec {lock_fd}>"$AGENT_HOME/locks/ci-runner-capacity.lock"
    flock "$lock_fd"
    capacity_f="$(quarantine_file implement)"
    capacity_since="$(jq -r 'select(.signature == "env:ci-runner-capacity") | .since // 0' "$capacity_f" 2>/dev/null || echo 0)"
    case "$capacity_since" in ''|*[!0-9]*) capacity_since=0 ;; esac
    seen=0
    if [ "$capacity_since" -gt 0 ]; then
      seen="$(awk -F '\t' -v since="$capacity_since" -v issue="$issue" \
        '$1 >= since && $3 == issue && $4 == "env:ci-runner-capacity" { found=1 } END { print found+0 }' \
        "$ENV_FAULT_DIR/$(env_fault_key env:ci-runner-capacity).log" 2>/dev/null || echo 0)"
    fi
    if [ "$seen" -eq 0 ]; then
      now="$(date +%s)"
      record_env_fault env:ci-runner-capacity implement "$issue" "$CI_RETRYABLE_INFRA_REASON" "" "$now" || true
      quarantine_open implement env:ci-runner-capacity "$CI_RETRYABLE_INFRA_REASON" 1 "$now"
    fi
    unlock_fd "$lock_fd"
    return 0
  fi
  ci_flake_retry_failed_run "$run_id" "$issue" "$pr_number" "$allow_flake_retry" "$jobs" || flake_status=$?
  case "$flake_status" in
    0) CI_RETRYABLE_INFRA_REASON="$CI_FLAKE_REASON"; CI_RETRYABLE_INFRA_KIND=flake; return 0 ;;
    3) return 1 ;;
  esac
  failed_step_count="$(jq -r '[.[]? | .steps[]? | select(.conclusion=="failure")] | length' <<< "$jobs")" || return 2
  [ "$failed_step_count" -gt 0 ] && return 1
  failed_job_without_steps="$(jq -r '[.[]? | select(.conclusion=="failure" and ((.steps // []) | length == 0))] | length' <<< "$jobs")" || return 2
  [ "$failed_job_without_steps" -gt 0 ] || return 2
  logs="$(gh run view "$run_id" --repo "$REPO" --log-failed 2>/dev/null)" || return 2
  if grep -Fq 'Docker pull failed with exit code' <<< "$logs" \
    && grep -Eq 'failed to resolve reference "docker\.io/[^\"]+"' <<< "$logs" \
    && grep -Eq 'dial tcp .*: i/o timeout' <<< "$logs"; then
    CI_RETRYABLE_INFRA_REASON="Docker Hub DNS/connect timeout before job steps"
    CI_RETRYABLE_INFRA_KIND=transport
    record_env_fault env:docker-hub-dns infrastructure "$issue" "$CI_RETRYABLE_INFRA_REASON" "" "" 0 || true
    return 0
  fi
  return 2
}

# ci_failed_test_ids <failed-log> -> stable identifiers for supported test runners.
ci_failed_test_ids() {
  awk '
    function clean(value) {
      gsub(/\r/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/[[:space:]]+/, " ", value)
      return value
    }
    BEGIN { esc = sprintf("%c", 27) }
    {
      line = $0
      # GitHub job logs keep the runner colours; vitest wraps FAIL in them.
      gsub(esc "\\[[0-9;]*[A-Za-z]", "", line)
      if (match(line, /FAIL[[:space:]]+[^[:space:]]+[[:space:]]*>[[:space:]]+[^[:space:]].*/)) {
        id = substr(line, RSTART, RLENGTH)
        sub(/^.*FAIL[[:space:]]+/, "", id)
        print "vitest\t" clean(id)
      } else if (match(line, /not ok [0-9]+ - .+/)) {
        id = substr(line, RSTART, RLENGTH)
        sub(/^.*not ok [0-9]+ - /, "", id)
        print "node\t" clean(id)
      } else if (match(line, /FAILED[[:space:]]+.+/)) {
        id = substr(line, RSTART, RLENGTH)
        sub(/^.*FAILED[[:space:]]+/, "", id)
        sub(/[[:space:]]+-[[:space:]].*$/, "", id)
        print "pytest\t" clean(id)
      }
    }
  ' <<< "$1" | sort -u
}

# ci_failed_test_scope_from_log <failed-log> -> JSON paths for failing suites
# plus source files whose focused gate includes those suites. Empty scope
# makes main-red quarantine stay lane-wide.
ci_failed_test_scope_from_log() {
  local scope
  scope="$(printf '%s' "$1" | node --input-type=module -e '
    import fs from "node:fs";
    const repo = process.argv[1];
    const log = fs.readFileSync(0, "utf8").replace(/\u001b\[[0-9;]*[A-Za-z]/g, "");
    const tests = new Set();
    const pathPattern = /((?:\.github\/workflows|packages|apps|scripts|tests)\/[A-Za-z0-9._/-]+\.(?:(?:test|spec)\.(?:ts|tsx|js|jsx|mjs|cjs|sh|py)|(?:test_[A-Za-z0-9._-]+|[A-Za-z0-9._-]+_test)\.py))(?:[:][0-9]+(?::[0-9]+)?)?/;
    let failedContext = false;
    for (const line of log.split(/\r?\n/)) {
      if (/\bFAIL(?:ED)?\b/.test(line) || /\bnot ok [0-9]+\b/.test(line)) failedContext = true;
      const relevant = /\bFAIL(?:ED)?\b/.test(line) || /\bnot ok [0-9]+\b/.test(line)
        || (failedContext && /location:/.test(line));
      if (relevant) {
        const match = line.match(pathPattern);
        if (match) tests.add(match[1].replace(/^\.\//, ""));
      }
      if (/^\s*(?:ok|PASS|✓)\b/.test(line)) failedContext = false;
    }
    let sources = [];
    const mappedTests = new Set();
    try {
      const { RELATED_TESTS } = await import(`file://${repo}/engine/focused-test-paths.mjs`);
      for (const [source, suites] of RELATED_TESTS) {
        for (const suite of suites) {
          if (!tests.has(suite)) continue;
          sources.push(source);
          mappedTests.add(suite);
        }
      }
    } catch {}
    const packageRoots = [...tests].flatMap((test) =>
      /^(packages|apps)\/[^/]+\//.test(test) ? [test.split("/").slice(0, 2).join("/")] : []);
    if ([...tests].some((test) => !mappedTests.has(test) && !/^(packages|apps)\/[^/]+\//.test(test))) {
      process.stdout.write("[]");
    } else {
      process.stdout.write(JSON.stringify([...new Set([...tests, ...packageRoots, ...sources])].sort()));
    }
  ' "$REPO_DIR" 2>/dev/null)" || scope='[]'
  jq -ce 'if type == "array" and all(.[]; type == "string" and length > 0) then unique else [] end' <<< "$scope" 2>/dev/null || echo '[]'
}

# Query completed runs so queued work cannot bury the last verdict. One page
# bounds the read; no usable verdict in that page remains unknown.
ci_main_completed_push_runs() {
  local cache_window_start response workflow="${1:-ci.yml}" read_timeout="${2:-}"
  cache_window_start="$(ci_main_actions_cache_window_start)" || return 1
  response="$(
    # HEALTH gets one request, no retry, and an independent deadline.
    if [ -n "$read_timeout" ]; then
      main_gh() { gh_timeout -k 1 "$read_timeout" "$@"; }
    fi
    main_gh api -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
    "repos/$REPO/actions/workflows/$workflow/runs?branch=main&status=completed&per_page=50&page=1&created=%3E%3D${cache_window_start}" \
    2>/dev/null)" || return 1
  jq -e 'type == "object" and (.workflow_runs | type == "array")' \
    <<< "$response" >/dev/null 2>&1 || return 1
  jq 'if type == "array" then .[] else . end
    | .workflow_runs |= map(select(.event == "push" or .event == "workflow_dispatch"))' <<< "$response"
}

# Shared verdict selector for merge admission, main-red recovery and revalidation.
# Optional cutoff preserves the verdict that existed when a PR run started.
ci_main_latest_completed_push_run() {
  local runs="$1" before="${2:-}"
  jq -ce --arg before "$before" '
    [(if type == "array" then .[] else . end) | .workflow_runs[]?
      | select(.status == "completed" and (.conclusion | type == "string" and length > 0)
        and .conclusion != "cancelled" and .conclusion != "skipped"
        and ($before == "" or .created_at <= $before))]
    | sort_by([.created_at, .id, .run_attempt]) | last // empty
    | . + {verdict_age_seconds: (try ((now - (.created_at | fromdateiso8601)) | floor) catch null)}
    ' <<< "$runs" 2>/dev/null
}

# Return 0 only for a known success, 1 for a known non-success, 2 when GitHub
# cannot establish the newest verdict.
ci_main_latest_completed_push_verdict() {
  local runs="${1:-}" run conclusion
  [ -n "$runs" ] || runs="$(ci_main_completed_push_runs)" || return 2
  run="$(ci_main_latest_completed_push_run "$runs")" || return 2
  conclusion="$(jq -r '.conclusion' <<< "$run")" || return 2
  [ "$conclusion" = success ] && return 0
  return 1
}

# GitHub exposes both a mergeability result and a merge-state summary. The
# sweeper accepts only an affirmative mergeability result with a state that is
# not conflicted, blocked, draft, or still being calculated. BEHIND is safe:
# GitHub can merge a branch that is behind main, while a conflict state cannot.
pr_mergeability_is_safe() {
  local pr_json="$1" mergeable merge_state
  mergeable="$(echo "$pr_json" | jq -r '.mergeable // empty' 2>/dev/null)" || return 1
  merge_state="$(echo "$pr_json" | jq -r '.mergeStateStatus // empty' 2>/dev/null)" || return 1
  [ "$mergeable" = "MERGEABLE" ] || return 1
  case "$merge_state" in
    CLEAN|BEHIND|UNSTABLE) return 0 ;;
    *) return 1 ;;
  esac
}

# A PR's updatedAt is the last GitHub-side edit to its metadata. Requiring
# this to predate the grace cutoff means a live but slow run, or a teammate
# who just touched the PR, gets a full chance to finish before rescue.
pr_untouched_for_grace() {
  local updated_at="$1" grace_seconds="$2" now="${3:-$(date +%s)}" updated_epoch
  updated_epoch="$(agent_epoch "$updated_at" 2>/dev/null)" || return 1
  [ "$updated_epoch" -le $((now - grace_seconds)) ]
}

# the project hash ban("all agents/skills/workflows are forbidden
# from computing, generating, verifying, comparing, recording, displaying,
# or explaining any hash/checksum/digest/fingerprint ... including Git
# object IDs, in the course of upload/sync/archive/copy/commit/push/
# verify/deliver/deploy") bans exactly this. Prose alone did not hold it:
# run-triage.sh's `model call` triage brief for issue #1140 quoted a Git
# commit id the reporter had written in the issue body straight into
# `brief_md`, and the wrapper published it verbatim to the GitHub comment
# and (as of today) the reporter's email. Measuring the same live state
# files this function runs over (~/.zenoforge/state/1131.json and
# 1132.json) turned up two more, undetected until now: a short and a full
# 40-char id for a rejected local prototype commit, in both `brief_md` and
# `notes_md`. Defect 8, 2026-09-13.
#
# Neutralizes rather than deletes, same shape as scrub_closing_keywords()
# above: a matched token becomes the literal marker below so a reader can
# tell something was removed instead of silently seeing a gap.
#
# This is deliberately NOT a general `\b[0-9a-f]{7,40}\b` scrubber -- that
# was tried first, against a corpus of every real brief_md/notes_md in
# ~/.zenoforge/state/*.json plus a sample of open issue bodies (the exact
# text this function runs over), and it also caught: bare-digit dates
# (`20260811` -- digits are valid hex too; fixed by requiring at least one
# real a-f letter in the match, which no date ever has) and, by design even
# though neither happened to occur in the measured corpus, this repo's
# prefixed ids such as `t-XXXXXXXX` and full-UUID business/event ids quoted
# from ops docs, both excluded below. Schema identifiers like `source_image_sha256`/`preview_hash` (also
# in the measured corpus) were never at risk: they sit inside one larger
# `\w` run that includes non-hex letters, so `\b` never lands inside them.
#
# Known gap, not fixed here: a BARE business/event id of the same shape as
# a short Git SHA (`016bf172`, no surrounding UUID dashes and no `t-`
# prefix) is structurally indistinguishable from a real object id and WILL
# be scrubbed. This did not occur in the measured corpus -- only the
# `t-`-prefixed and full-UUID forms are protected below.
scrub_git_object_ids() {
  perl -CSD -pe '
    s{
      (?<!\bt-)                            # t-XXXXXXXX prefixed id
      (?<![0-9a-fA-F]-)                    # left half of a UUID hex group
      \b
      (?=[0-9a-fA-F]{7,40}\b)              # git short-SHA length .. full SHA-1 length
      ([0-9a-fA-F]*[a-fA-F][0-9a-fA-F]*)   # must contain a real hex letter -- excludes bare-digit dates
      \b
      (?!-[0-9a-fA-F])                     # right half of a UUID hex group
    }{[object-id-redacted]}gx
  '
}

# trim_quoted_reply <body> — cuts a reply's plain-text body at the first
# line that looks like the start of a quoted original message (a ">"
# continuation, an "On ... wrote:" header or its Chinese "...写道："
# equivalent, or a "-----Original Message-----" separator), so a relayed
# comment (issue-pipeline.sh's read_needs_info_email_replies()) shows only
# what the person actually typed, not the whole original question quoted
# back underneath it.
# ponytail: a fixed set of known quote markers, not a general quoted-text
# detector — an unusual mail client's own quote header can slip through
# uncut. Upgrade if a real relayed comment is ever seen with the original
# question still attached.
trim_quoted_reply() {
  # 2026-09-13: `[:：]` (an ASCII colon and the full-width Chinese one in one
  # bracket expression) followed by `$` silently never matches under mawk
  # (the `awk` this box actually has -- no gawk installed) whenever the
  # bracket expression is preceded by anything else in the pattern,
  # multi-byte or not -- confirmed live: `/写道[:：]$/` and even the
  # all-ASCII `/ab[:：]$/` both matched nothing, while `/写道(:|：)$/`
  # (alternation instead of a bracket class) matched correctly. Alternation
  # it is; a `[...]` class next to `$` is a proven trap on this awk, not a
  # style choice.
  awk '
    BEGIN { IGNORECASE = 1 }
    /^>/ { exit }
    /^On .+ wrote:[ \t]*$/ { exit }
    /(写道|wrote)(:|：)[ \t]*$/ { exit }
    /^-{2,}[ \t]*Original Message[ \t]*-{2,}$/ { exit }
    { print }
  ' <<< "$1"
}

# --- 2026-09-12: bounded-concurrency scheduler helpers ----------------------
# issue-pipeline.sh dispatches stage work via `systemd-run --user --unit
# zf-<stage>-<N> --collect` instead of running a wrapper script inline.
# The transient units ARE the ledger — no PID file, no lease file, no
# stale-PID reaper: `--collect` releases a unit's registration the instant
# the dispatched process exits, however it exits (normal, killed, crashed),
# which is exactly the bookkeeping a hand-rolled PID file would have to
# reimplement and could get wrong.

# "Is issue $2 already running at stage $1?" First-class in candidate
# selection for all three stages, not an afterthought: an implement run
# doesn't push for up to 2 hours and a triage run doesn't clear
# needs-triage until late in run-triage.sh, so a file-based check (an open
# PR, a stale label) can't see a still-running attempt — only the live unit
# can. Without this, a later tick would re-dispatch the same issue on top of
# an attempt that is merely still running, not stuck.
#
# 2026-09-16 fix: this used to be a bare `systemctl --user is-active
# --quiet ...`, so systemctl itself failing to even reach the user service
# manager (session bus down, XDG_RUNTIME_DIR missing) returned the SAME
# non-zero exit as "confirmed not active" -- every caller of this function
# (merge_agent_pr()'s two active-unit checks, the sweeper's CONFLICTING/
# active checks, every issue-pipeline.sh candidate loop, sweep-brief-
# banners.sh) uses the same direction, "active blocks the action", so an
# unreadable answer now fails closed the same way: treated as active,
# never treated as confirmed-inactive.
#
# Distinguishing the two needs no error-text pattern list (fragile across
# systemd versions): measured live on this box, `--quiet` suppresses
# is-active's normal state output entirely, success or not -- a query for a
# unit that plainly is not active prints NOTHING on stdout OR stderr (just
# a non-zero exit); a query that cannot even reach the service manager
# (session bus down) prints "Failed to connect ..." on stderr regardless of
# --quiet. So ANY output at all on a non-zero exit already means "systemctl
# itself is complaining", not "confirmed inactive" -- checking for that is
# simpler and more robust than matching the exact wording of a failure.
agent_memory_available_kib() {
  awk '$1 == "MemAvailable:" { print $2; found=1; exit } END { if (!found) exit 1 }' /proc/meminfo
}

agent_memory_floor_allows() {
  local stage="$1" floor_mib="${2:-2048}" available_kib floor_kib
  floor_kib=$((floor_mib * 1024))
  if ! available_kib="$(agent_memory_available_kib)" || [[ ! "$available_kib" =~ ^[0-9]+$ ]]; then
    echo "issue-pipeline: refusing $stage dispatch: cannot read MemAvailable (${floor_mib}MiB floor)" >&2
    return 1
  fi
  if [ "$available_kib" -lt "$floor_kib" ]; then
    echo "issue-pipeline: refusing $stage dispatch: MemAvailable $((available_kib / 1024))MiB is below ${floor_mib}MiB floor" >&2
    return 1
  fi
}

agent_implement_dispatch_resources_allow() {
  # Ruling crash-guard-is-memory-not-load: implement admission is memory only.
  # On 2026-10-08 a 4*nproc load check refused every implement tick at load
  # 50-62 (hand-agent tests and landing suites) with 5.7 GB free. Hand
  # dispatch keeps its own load refusal in night/dispatch.sh.
  agent_memory_floor_allows implement 3072
}

triage_single_unit_active() {
  local out
  if out="$(systemctl --user is-active --quiet "zf-triage-$1" 2>&1)"; then
    return 0
  fi
  if [ -n "$out" ]; then
    echo "triage_single_unit_active: systemctl --user is-active could not be queried for zf-triage-$1 -- treating as ACTIVE (fail-closed): $out" >&2
    return 0
  fi
  return 1
}

triage_batch_unit_active() {
  local out
  if ! out="$(systemctl --user list-units --no-legend --plain zf-triage-batch.service 2>&1)"; then
    if [ -n "$out" ]; then
      echo "triage_batch_unit_active: systemctl --user list-units could not be queried -- treating batch as ACTIVE (fail-closed): $out" >&2
      return 0
    fi
    return 1
  fi
  printf '%s\n' "$out" | awk '$1 == "zf-triage-batch.service" { found=1 } END { exit !found }'
}

stage_unit_active() {
  local out
  if [ "$1" = triage ] && [ "$2" = batch ]; then
    triage_batch_unit_active
    return $?
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    # A host without systemd (the cihost macOS CI runner, issue #3869 family) has no
    # transient units at all: nothing can be active, so requeue must proceed.
    # Treating the missing binary as a failed query kept every Mac-hosted requeue
    # pinned on-hold and red the concluded-root-unblock suite.
    return 1
  fi
  if out="$(systemctl --user is-active --quiet "zf-$1-$2" 2>&1)"; then
    return 0
  fi
  if [ -n "$out" ]; then
    echo "stage_unit_active: systemctl --user is-active could not be queried for zf-$1-$2 -- treating as ACTIVE (fail-closed), not confirmed-inactive: $out" >&2
    return 0
  fi
  if [ "$1" = triage ] && [ "$2" != batch ] && triage_batch_issue_active "$2"; then
    return 0
  fi
  return 1
}

# A batch is one transient unit, so its issue members need an explicit active
# snapshot for implement selection and single-issue triage checks. The file is
# only authoritative while the batch unit is active; a killed run cannot leave
# tickets stuck behind a stale marker.
triage_batch_issue_active() {
  local n="$1" marker="$AGENT_HOME/triage-batch-active.json"
  [ -f "$marker" ] || return 1
  jq -e --argjson n "$n" 'any(.issues[]?; . == $n)' "$marker" >/dev/null 2>&1 || return 1
  triage_batch_unit_active
}

# Validate one triage result against the checked-in schema using the schema's
# current required/types/enums/items rules. Missing or malformed external
# judgment is normalized to false on the validation copy, so it cannot strand
# an otherwise valid ticket outside the implement lane. jq remains the only
# runtime dependency.
triage_result_matches_schema() {
  local result_file="$1" schema_file="${2:-$(dirname -- "${BASH_SOURCE[0]}")/prompts/triage.schema.json}"
  jq -e --slurpfile schema "$schema_file" '
    def has_external_judgment:
      (.external_deliverable | type) == "object"
      and (.external_deliverable.required | type) == "boolean"
      and (.external_deliverable.location | type) == "string"
      and (.external_deliverable.reason | type) == "string"
      and (.external_deliverable | keys | sort) == ["location", "reason", "required"];
    def matches($s):
      . as $v
      | ((($s.type // null) == null) or
          (if $s.type == "integer" then
             ($v | type) == "number" and $v == ($v | floor)
           else
             ($v | type) == $s.type
           end))
      and ((($s.enum // null) == null) or any($s.enum[]; . == $v))
      and (if $s.minimum == null then true
           else ($v | type) == "number" and $v >= $s.minimum end)
      and (if ($v | type) == "object" then
             all(($s.required // [])[]; . as $key | ($v | has($key)))
             and (if $s.additionalProperties == false then
                    all(($v | keys[]); . as $key | (($s.properties // {}) | has($key)))
                  else true end)
             and all((($s.properties // {}) | to_entries[]);
                     . as $property |
                     if ($v | has($property.key)) then
                       $v[$property.key] | matches($property.value)
                     else true end)
           elif ($v | type) == "array" then
             if $s.items == null then true
             else all($v[]; matches($s.items)) end
           else true end);
    . as $input
    | (if has_external_judgment then $input
       else $input + {external_deliverable:{required:false,location:"",reason:""}}
       end) as $result
    | ($schema[0] as $contract | $result | matches($contract))
  ' "$result_file" >/dev/null 2>&1
}

# Stage occupancy for the cap check: how many zf-<stage>-* units are
# currently loaded at all (active, activating, or deactivating)? `--collect`
# means a finished unit is gone from this count the instant it exits, not
# lingering as "inactive" — the ledger self-cleans, nothing here prunes it.
#
# 2026-09-16 fix: the old `2>/dev/null | wc -l` discarded systemctl's own
# failure, so a session-bus outage read as "zero units loaded" -- the
# scheduler's cap arithmetic (cap_slots_remaining()) then saw every stage
# as empty and over-dispatched into an outage it could not even observe.
# Unlike stage_unit_active() above, `list-units` genuinely can print
# nothing on a NORMAL success too (zero matching units, the common case) --
# so the signal here is the exit code, not output emptiness: measured live,
# a real zero-match query exits 0, only a genuine manager-unreachable
# failure exits non-zero. On that failure this prints a huge sentinel count
# instead of 0: cap_slots_remaining() clamps `cap - count` at 0, so every
# caller sees zero free slots (fail closed) with no call-site change
# needed.
stage_unit_count() {
  local out
  if ! out="$(systemctl --user list-units --no-legend --plain "zf-$1-*" 2>&1)"; then
    echo "stage_unit_count: systemctl --user list-units could not be queried for stage $1 -- treating occupancy as FULL (fail-closed), not zero: $out" >&2
    echo 999999999
    return 1
  fi
  # `grep -c .` exits 1 when it counts zero lines. Zero running units is a
  # legitimate answer here, not an error, but that exit status used to be this
  # function's own -- and a BARE assignment (`x=$(stage_unit_count ...)`)
  # inherits the command substitution's status, so under `set -e` an idle
  # stage killed the caller outright. The five call sites in
  # issue-pipeline.sh survived only because they pass this through as an
  # ARGUMENT to cap_slots_remaining, where the outer command's status wins;
  # local metrics' bare-assignment site, so it was the one that died -- and
  # only on an idle stage, which is why this sat latent.
  # A real grep failure (exit 2+) still fails closed like the systemctl one
  # above; only the count-was-zero exit is absorbed.
  local count status=0
  # The autopilot release train runs as zf-release-train.service; it delegates to the release slice and is
  # not a release slot. Counting it made RELEASE_CAP=1 always full (2026-10-22: every candidate
  # gate=capacity slots-exhausted while only the train ran).
  count="$(printf '%s\n' "$out" | grep -vc -e '^$' -e '^zf-release-train\.service')" || status=$?
  if [ "$status" -gt 1 ]; then
    echo "stage_unit_count: grep failed (exit $status) counting units for stage $1 -- treating occupancy as FULL (fail-closed), not zero" >&2
    echo 999999999
    return 1
  fi
  printf '%s\n' "${count:-0}"
}

# A freshness-blocked triage result stays in its current label. Keep it out of
# both triage selection pools until the shared GitNexus refresh window opens,
# so a priority:top ticket cannot consume the only slot on every timer tick.
triage_retry_deferred() {
  local n="$1" now="$2" retry_after
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  retry_after="$(state_read "$n" | jq -r '.triage_retry_after_epoch // 0')"
  [[ "$retry_after" =~ ^[0-9]+$ ]] || return 1
  [ "$retry_after" -gt "$now" ]
}

# Return the last three completed analyze exit codes only when all failed.
gitnexus_recent_analyze_failure_codes() {
  local memory_log="${1:-$AGENT_HOME/night/gitnexus-analyze-memory.tsv}"
  [ -r "$memory_log" ] || return 1
  awk -F '\t' '
    $1 == "run" {
      if ($7 ~ /^[0-9]+$/ && ($7 + 0) > 0) {
        codes = codes (codes == "" ? "" : ",") $7
        consecutive++
        if (consecutive > 3) {
          sub(/^[^,]*,/, "", codes)
          consecutive = 3
        }
      } else {
        codes = ""
        consecutive = 0
      }
    }
    END {
      if (consecutive >= 3) print codes
      else exit 1
    }
  ' "$memory_log"
}

# Record the first failed L2 freshness window for an unchanged issue. Return 0
# while its bounded deferral remains active, 1 after expiry, and 2 on state or
# clock failure.
triage_freshness_deferral_active() {
  local n="$1" issue_updated_at="$2" now="${3:-$(date +%s)}" prior_updated_at since updated_at_json age failure_codes
  TRIAGE_FRESHNESS_DEFERRAL_SKIP_REASON=""
  if failure_codes="$(gitnexus_recent_analyze_failure_codes)"; then
    TRIAGE_FRESHNESS_DEFERRAL_SKIP_REASON="last 3 GitNexus analyze runs failed (exit codes $failure_codes)"
    return 1
  fi
  [[ "$now" =~ ^[0-9]+$ && -n "$issue_updated_at" ]] || return 2
  prior_updated_at="$(state_read "$n" | jq -r '.triage_freshness_deferred_issue_updated_at // empty')" || return 2
  since="$(state_read "$n" | jq -r '.triage_freshness_deferred_since_epoch // empty')" || return 2
  if [ "$prior_updated_at" != "$issue_updated_at" ] || ! [[ "$since" =~ ^[0-9]+$ ]]; then
    since="$now"
    updated_at_json="$(jq -nc --arg value "$issue_updated_at" '$value')" || return 2
    state_merge "$n" ". + {triage_freshness_deferred_issue_updated_at: $updated_at_json, triage_freshness_deferred_since_epoch: $since}" || return 2
  fi
  age=$((now - since))
  (( age < TRIAGE_FRESHNESS_MAX_DEFER_SECONDS ))
}

# An unchanged issue stays out of the batch while its bounded deferral is
# active. Once expired, send it through triage with the L2 gate fail-closed.
triage_freshness_redefer_unchanged_issue() {
  local n="$1" issue_snapshot_file="$2" freshness_note="$3" issue_updated_at prior_updated_at live_issue_json live_updated_at now retry_after
  local active_status failure_codes
  [[ "$freshness_note" == "NOT confirmed"* ]] || return 1
  issue_updated_at="$(jq -r '.updatedAt // empty' "$issue_snapshot_file" 2>/dev/null)" || return 1
  [ -n "$issue_updated_at" ] || return 1
  prior_updated_at="$(state_read "$n" | jq -r '.triage_freshness_deferred_issue_updated_at // empty')"
  [ "$issue_updated_at" = "$prior_updated_at" ] || return 1
  if failure_codes="$(gitnexus_recent_analyze_failure_codes)"; then
    echo "run-triage-batch: #$n freshness deferral skipped: last 3 GitNexus analyze runs failed (exit codes $failure_codes); triaging with the phase-3 L2 gate closed" >&2
    return 1
  fi
  if ! live_issue_json="$(gh_timeout 30s issue view "$n" --repo "$REPO" --json updatedAt 2>/dev/null)"; then
    echo "run-triage-batch: #$n could not confirm unchanged issue version; keeping it in this batch" >&2
    return 1
  fi
  live_updated_at="$(jq -r '.updatedAt // empty' <<< "$live_issue_json" 2>/dev/null)" || return 1
  [ "$live_updated_at" = "$issue_updated_at" ] || return 1
  now="$(date +%s)" || return 1
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  if triage_freshness_deferral_active "$n" "$issue_updated_at" "$now"; then
    :
  else
    active_status=$?
    if [ "$active_status" -eq 1 ]; then
      echo "run-triage-batch: #$n freshness deferral expired; triaging with the phase-3 L2 gate closed" >&2
      return 1
    fi
    return 2
  fi
  retry_after=$((now + GITNEXUS_REFRESH_MIN_INTERVAL_SECONDS))
  state_merge "$n" ". + {triage_retry_after_epoch: $retry_after}" || return 2
  echo "run-triage-batch: #$n unchanged after prior L2 freshness deferral; freshness still unconfirmed, retry after $retry_after" >&2
  return 0
}

# Issue numbers behind every currently active zf-<stage>-* unit, one per
# line. Used to derive (never store) implement's package-exclusion set — see
# expected_packages_collide() below.
stage_active_issues() {
  systemctl --user list-units --no-legend --plain "zf-$1-*" 2>/dev/null \
    | awk '{print $1}' | sed -E "s/^zf-$1-([0-9]+)\\.service\$/\\1/"
}

# How many more of this stage's cap are free right now? Clamped at 0 so a
# cap lowered below the current in-flight count never goes negative and
# wraps a `for`-loop's `[ "$slots" -le 0 ] && break` guard into "unlimited."
cap_slots_remaining() {
  local cap="$1" count="$2" slots
  slots=$((cap - count))
  [ "$slots" -lt 0 ] && slots=0
  echo "$slots"
}

# Does any currently OPEN agent/issue-* PR's actual changed files overlap $1
# (selection scope: optional exact paths or normalized packages, JSON array)?
# $2 is the raw `gh pr list ... -q '.[] |
# select(...)'` stream (multiple JSON objects, not one array — jq handles
# that as separate inputs either way) already computed once per tick. This
# is the one window stage_unit_active() can't see: a wrapper that already
# exited, leaving its PR open.
# 2026-09-12 bug this replaces: `grep -qF "$pkg"` was a raw substring match,
# so an expected_packages entry of "packages/example-service" collided with an
# unrelated PR touching "packages/example-service-admin/...". Use the
# selection scope's exact prefix rule instead of grepping for a substring.
OPEN_PR_FILE_COLLISION_CACHE_SOURCE=""
OPEN_PR_FILE_COLLISION_CACHE_JSON='[]'
OPEN_PR_FILE_COLLISION_CACHE_READY=0
OPEN_PR_FILE_COLLISION_CACHE_COMPLETE=0

# Both scheduler and HEALTH share only identity-bound details; checks stay fresh.
open_pr_snapshot_read() {
  python3 "$(dirname -- "${BASH_SOURCE[0]}")/open-pr-snapshot.py" --repo "$REPO" \
    --cache "${NIGHT:-$AGENT_HOME/night}/pr-details-cache.json" "$@"
}

load_open_pr_file_collision_cache() {
  local prs_stream="$1" snapshot
  if [ "$OPEN_PR_FILE_COLLISION_CACHE_READY" = 1 ] \
    && [ "$OPEN_PR_FILE_COLLISION_CACHE_SOURCE" = "$prs_stream" ]; then
    return 0
  fi
  if ! snapshot="$(jq -sc '[.[] | if type == "array" then .[] else . end]' <<< "$prs_stream")"; then
    OPEN_PR_FILE_COLLISION_CACHE_SOURCE="$prs_stream"
    OPEN_PR_FILE_COLLISION_CACHE_JSON='[]'
    OPEN_PR_FILE_COLLISION_CACHE_READY=1
    OPEN_PR_FILE_COLLISION_CACHE_COMPLETE=0
    return 1
  fi
  OPEN_PR_FILE_COLLISION_CACHE_SOURCE="$prs_stream"
  OPEN_PR_FILE_COLLISION_CACHE_JSON="$snapshot"
  OPEN_PR_FILE_COLLISION_CACHE_READY=1
  if jq -e 'all(.[]; (.files | type == "array"))' <<< "$snapshot" >/dev/null 2>&1; then
    OPEN_PR_FILE_COLLISION_CACHE_COMPLETE=1
  else
    OPEN_PR_FILE_COLLISION_CACHE_COMPLETE=0
  fi
}

open_pr_file_collision() {
  local expected_json="$1" open_prs_stream="$2" exclude_head_ref="${3:-}" pr_json pr f files head_ref
  OPEN_PR_FILE_COLLISION_PR=""
  OPEN_PR_FILE_COLLISION_PATH=""
  OPEN_PR_FILE_COLLISION_OWNER=""
  OPEN_PR_FILE_COLLISION_UPDATED_AT=""

  if load_open_pr_file_collision_cache "$open_prs_stream" \
    && [ "$OPEN_PR_FILE_COLLISION_CACHE_COMPLETE" = 1 ]; then
    local collision
    collision="$(jq -r --argjson expected "$expected_json" --arg exclude "$exclude_head_ref" '
      def in_scope($path):
        any($expected[]?; . as $item | ($path == $item or ($path | startswith($item + "/"))));
      def shared_path($path):
        $path == "package.json" or ($path | endswith("/package.json"))
        or $path == "pnpm-lock.yaml" or ($path | endswith("/pnpm-lock.yaml"))
        or $path == "package-lock.json" or ($path | endswith("/package-lock.json"))
        or $path == "yarn.lock" or ($path | endswith("/yarn.lock"))
        or ($path | endswith("/src/index.ts")) or ($path | endswith("/src/index.tsx"))
        or ($path | endswith("/src/index.js")) or ($path | endswith("/src/index.mjs"))
        or ($path | test("^packages/.+/index\\.(ts|tsx|js|mjs)$"));
      first(
        .[] as $pr
        | ($pr.headRefName // "") as $head
        | select($exclude == "" or $head != $exclude)
        | $pr.files[]? as $file
        | (if ($file | type) == "object" then ($file.path // "") else $file end) as $path
        | select(($path | type) == "string" and $path != "")
        | select(in_scope($path))
        | select((shared_path($path) | not) or any($expected[]?; . == $path))
        | [($pr.number // "" | tostring), $path,
           (if ($head | test("^agent/issue-[0-9]+$")) then ($head | sub("^agent/issue-"; "")) else "" end),
           ($pr.updatedAt // "")] | join("\u001f")
      ) // empty
    ' <<< "$OPEN_PR_FILE_COLLISION_CACHE_JSON")"
    if [ -n "$collision" ]; then
      IFS=$'\037' read -r OPEN_PR_FILE_COLLISION_PR OPEN_PR_FILE_COLLISION_PATH \
        OPEN_PR_FILE_COLLISION_OWNER OPEN_PR_FILE_COLLISION_UPDATED_AT <<< "$collision"
      return 0
    fi
    return 1
  fi

  while IFS= read -r pr_json; do
    [ -n "$pr_json" ] || continue
    pr="$(echo "$pr_json" | jq -r '.number // empty' 2>/dev/null)"
    [ -n "$pr" ] || continue
    head_ref="$(echo "$pr_json" | jq -r '.headRefName // empty' 2>/dev/null)"
    [ -n "$exclude_head_ref" ] && [ "$head_ref" = "$exclude_head_ref" ] && continue
    # issue-pipeline.sh supplies the list snapshot so a candidate census does
    # not issue the same GitHub files query once for every candidate. Other
    # callers without files keep the live lookup behavior.
    if echo "$pr_json" | jq -e '.files | type == "array"' >/dev/null 2>&1; then
      files="$(echo "$pr_json" | jq -r '.files[] | if type == "object" then .path // empty else . end')"
    else
      files="$(gh pr view "$pr" --repo "$REPO" --json files -q '.files[].path')"
    fi
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      if path_in_selection_scope "$expected_json" "$f"; then
        if shared_collision_path "$f" && ! selection_scope_has_exact_path "$expected_json" "$f"; then
          continue
        fi
        OPEN_PR_FILE_COLLISION_PR="$pr"
        OPEN_PR_FILE_COLLISION_PATH="$f"
        if [[ "$head_ref" =~ ^agent/issue-([0-9]+)$ ]]; then
          OPEN_PR_FILE_COLLISION_OWNER="${BASH_REMATCH[1]}"
        fi
        OPEN_PR_FILE_COLLISION_UPDATED_AT="$(echo "$pr_json" | jq -r '.updatedAt // empty' 2>/dev/null)"
        return 0
      fi
    done <<< "$files"
  done <<< "$open_prs_stream"
  return 1
}

# 2026-09-12 bug this replaces: the old finish-first collision branch
# (issue-pipeline.sh) labeled an issue finish-first on a transient overlap
# with another in-flight implement run and nothing in the codebase ever
# removed that label again — an issue parked there permanently. A
# still-running implement dispatch has no PR yet (up to 2 hours before it
# ever pushes), so a file-based scan of open PRs can't see it either. This
# derives the exclusion set instead of storing anything: true (collides) if
# any candidate selection-scope entry ($1, optional exact paths or normalized
# packages) overlaps an in-flight run's selection scope ($2, built by the
# caller from stage_active_issues plus each state file). Compare both prefix
# directions: exact paths can be siblings in one package, while a legacy
# package scope still contains all of its descendants.
expected_packages_collide() {
  local candidate_json="$1" union_json="$2" candidate active
  EXPECTED_SCOPE_COLLISION_CANDIDATE=""
  EXPECTED_SCOPE_COLLISION_ACTIVE=""
  while IFS= read -r candidate; do
    [ -z "$candidate" ] && continue
    while IFS= read -r active; do
      [ -z "$active" ] && continue
      if [ "$candidate" = "$active" ] \
        || [[ "$candidate" == "$active/"* ]] \
        || [[ "$active" == "$candidate/"* ]]; then
        EXPECTED_SCOPE_COLLISION_CANDIDATE="$candidate"
        EXPECTED_SCOPE_COLLISION_ACTIVE="$active"
        return 0
      fi
    done < <(echo "$union_json" | jq -r '.[]?')
  done < <(echo "$candidate_json" | jq -r '.[]?')
  return 1
}

# Defect (d), 2026-09-12: which issue numbers does a merge-commit range
# actually cover? Every agent PR's merge-commit subject is `fix(#N): ...`
# (run-implement.sh's MERGE_SUBJECT, itself the PR title it sets at create
# time) — used by run-release.sh to relabel every issue a failed deploy's
# image build actually included, not just the one that happened to trigger
# the run. A human-authored commit in the range matches nothing here and is
# deliberately NOT returned — it maps to no tracked issue, so the caller
# names it "unattributed" in its comment instead of silently dropping it.
issue_numbers_in_range() {
  local range="$1" dir="${2:-$REPO_DIR}"
  git -C "$dir" log --format=%s "$range" \
    | sed -nE 's/^fix\(#([0-9]+)\):.*/\1/p'
}

# Defect (d), 2026-09-12: a failed deploy must never auto-retry its own SHA.
# True (blocked) if $1 (a would-be deploy target SHA) equals the recorded
# failed SHA in $DEPLOY_BLOCKED_FILE — exact equality only. Since the
# 2026-10-26 fix-forward ruling a descendant is the fix-forward commit and
# MAY release; the previous descendant-blocking (and the culprit-revert
# escape hatch) required a manual marker clear for every fix (release 4061,
# seven attempts for one batch). $2 (marker file) defaults to the real one
# and exists only so lib.test.sh can point this at a throwaway path instead.
# No function clears the marker.
# Defect 2, 2026-09-13: run-release.sh's fresh-install bootstrap for
# $OLD_DEPLOYED_SHA (no production Deployment record yet) must diff from THIS
# release's own triggering merge commit's parent, never from current
# origin/main HEAD's parent -- the two are only the same SHA at the instant
# this PR's own merge lands. The moment any other commit reaches main after
# that (another queued issue, an unrelated [skip ci] commit), $DEPLOYED_SHA
# (origin/main HEAD) and $MERGE_SHA (the PR actually being released) diverge,
# and diffing from $DEPLOYED_SHA^ silently excludes the triggering PR's own
# commit from the range changed-images.mjs computes -- reproduced live for
# issue #1098: the buggy range printed no changed images at all and the
# script took the "nothing to deploy" exit, when the correct range printed
# example-admin. Pure (one git call, no state): given $1 = the merge SHA
# being released (never current HEAD), prints its parent. $2 defaults to the
# real $REPO_DIR so lib.test.sh can point this at a throwaway repo instead.
bootstrap_old_deployed_sha() {
  local merge_sha="$1" dir="${2:-$REPO_DIR}"
  git -C "$dir" rev-parse "$merge_sha^"
}

deploy_is_blocked() {
  local candidate_sha="$1" marker_file="${2:-$DEPLOY_BLOCKED_FILE}" blocked_sha
  # 2026-10-26 maintainer ruling (fix-forward, no resident users): the marker
  # blocks ONLY the exact SHA that failed. A descendant is the fix-forward
  # commit and may release; the ancestor semantics below used to block every
  # descendant, so each fix needed a manual marker clear (release 4061, seven
  # attempts). The recorded culprit-revert escape hatch is gone with them.
  [ -f "$marker_file" ] || return 1
  read -r blocked_sha < "$marker_file" || [ -n "${blocked_sha:-}" ] || return 1
  [ -n "$blocked_sha" ] || return 1
  [ "$blocked_sha" = "$candidate_sha" ]
}

# 2026-09-12 defect 4: run-implement.sh's merge-queue wait used to poll
# `node scripts/branch-delivery-preflight.mjs --mode release` (which calls
# verify-branch-promotion-evidence.mjs) as its "is main green" circuit
# breaker. Measured two independent reasons that predicate can never pass
# under the systemd unit's own environment (engine/systemd/
# zenoforge-agent.service's EnvironmentFile + proxy vars, not just an interactive
# shell):
#   1. Node's global `fetch` ignores HTTP(S)_PROXY entirely (a known Node
#      limitation; fixed only by the experimental NODE_USE_ENV_PROXY=1). This
#      box has no direct outbound path — confirmed live under the exact env
#      the unit sets: `fetch('https://api.github.com/')` throws
#      "TypeError: fetch failed" without NODE_USE_ENV_PROXY=1, returns 200
#      with it.
#   2. Even with that fixed, verify-branch-promotion-evidence.mjs requires a
#      workflow run for the EXACT current `origin/main` SHA. GitHub never
#      creates a workflow run at all for a `[skip ci]` commit (its own
#      native push/pull_request skip, not something ci.yml configures) — and
#      this repo's dev-system fast lane (CONTRIBUTING.md) means 22 of the
#      last 30 commits on main carry `[skip ci]`. Confirmed live:
#      `gh api repos/$REPO/actions/runs?head_sha=<a [skip ci] HEAD>` returns
#      zero runs, vs one for the last non-skip-ci commit. An exact-SHA check
#      structurally can never see evidence for those SHAs.
#
# main_merge_clear() asks the optimistic merge question: is there a completed,
# non-cancelled PUSH-triggered ci.yml failure on `main`? A pending tip does not
# erase the last completed verdict, and no completed verdict leaves the gate
# open. A `[skip ci]` commit produces no run, so the last real push remains
# authoritative until a later verdict arrives. It uses `gh api`, not node's
# fetch: gh is already proxy-env-aware under the systemd unit environment.
#
# Deliberately does NOT touch scripts/verify-branch-promotion-evidence.mjs or
# scripts/branch-delivery-preflight.mjs: run-release.sh's own `--mode
# release` call gates an actual production deploy, where "evidence for the
# EXACT SHA being shipped" is a stricter and correctly different bar than
# "has main produced a completed red verdict" — the question this merge
# gate exists to answer. The two predicates diverge on purpose.
#
# --- The main-red bisect state machine (#4356, #4477) -----------------------
#
# One bounded step per tick (issue-pipeline.sh's maintenance runs this). The
# states, and what advances them:
#
#   rerun-requested  session opened; the red run's failed jobs were rerun
#                    once through `gh run rerun --failed` in its source
#                    workflow. When that run
#                    re-completes green the red is FLAKY (recorded, terminal,
#                    no revert); when it re-completes red, the window is
#                    deterministic and the bisect starts.
#   bisecting       midpoint probes of (last_green..red]: reuse any existing
#                    completed verdict from the source workflow for that SHA,
#                    otherwise dispatch that workflow on a train/bisect-* ref.
#                    ci.yml receives source_sha for its Postsubmit probe;
#                    pipeline-suites.yml runs the suite on the train ref.
#                    Green midpoint moves the green bound up,
#                    red midpoint moves the red bound down; a one-commit
#                    window names the culprit.
#   culprit-found   culprit commit's `fix(#N):` subject names the ticket.
#                    No owner (or an un-revertable commit) -> unattributed.
#   revert-open     dedicated revert PR `agent/revert-main-<issue>-<sha12>`
#                    carries the git-revert trailer; sweep-merges.sh admits
#                    only this matching PR through the red gate after its
#                    checks are green. A Postsubmit red keeps ordinary merges
#                    held until a later Postsubmit verdict is green; a
#                    suites-only red does not change that gate. The ticket is
#                    reopened with the culprit evidence at the same step.
#   reverted        the revert PR merged; the existing Postsubmit merge gate
#                   still owns ordinary merge admission.
#   flaky           terminal record of a red that reran green.
#   unattributed    terminal: no culprit could be named. A Postsubmit red
#                   stays behind its merge gate; every unattributed red sends
#                   one supervisor event for human follow-up.
MAIN_RED_PROBE_DISPATCH_ATTEMPTS=2
MAIN_RED_PROBE_RETRY_DELAY_SECONDS=600
MAIN_RED_REVERT_ATTEMPTS=3

main_red_session_file() {
  local sha="$1"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s/%s.json\n' "$MAIN_RED_DIR" "$sha"
}

main_red_session_read_for_file() {
  local file="$1"
  jq -ce 'select(type == "object"
    and (.red_sha | type == "string" and test("^[0-9a-f]{40}$"))
    and (.status | IN("rerun-requested", "bisecting", "culprit-found", "revert-open", "reverted", "flaky", "unattributed")))' \
    "$file" 2>/dev/null
}

main_red_session_read() {
  local sha="$1" file
  file="$(main_red_session_file "$sha")" || return 1
  jq -ce --arg sha "$sha" 'select(type == "object" and .red_sha == $sha
    and (.status | IN("rerun-requested", "bisecting", "culprit-found", "revert-open", "reverted", "flaky", "unattributed")))' \
    "$file" 2>/dev/null
}

# Persist one session transition atomically. The filter is an internal jq
# update supplied by the state machine; the session identity and status are
# always overwritten from validated arguments.
main_red_session_write() {
  local sha="$1" status="$2" update file tmp now filter
  if [ "$#" -ge 3 ]; then update="$3"; else update="."; fi
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  case "$status" in
    rerun-requested|bisecting|culprit-found|revert-open|reverted|flaky|unattributed) ;;
    *) return 1 ;;
  esac
  file="$(main_red_session_file "$sha")" || return 1
  mkdir -p "$MAIN_RED_DIR" || return 1
  tmp="$(mktemp "$MAIN_RED_DIR/.${sha}.XXXXXX")" || return 1
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || { rm -f -- "$tmp"; return 1; }
  filter="$update | .red_sha = \$sha | .status = \$status | .updated_at = \$now"
  if [ -e "$file" ]; then
    jq --arg sha "$sha" --arg status "$status" --arg now "$now" \
      'if type != "object" or .red_sha != $sha then error("main-red session SHA mismatch") else . end
       | '"$filter" \
      "$file" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  else
    jq -n --arg sha "$sha" --arg status "$status" --arg now "$now" \
      '{red_sha:$sha,status:$status,created_at:$now,updated_at:$now}' \
      | jq --arg sha "$sha" --arg status "$status" --arg now "$now" "$filter" \
      > "$tmp" || { rm -f -- "$tmp"; return 1; }
  fi
  chmod 600 "$tmp" && mv -f -- "$tmp" "$file"
}

# Admit merges when the latest usable completed main verdict is green or no
# completed verdict exists. A GitHub read failure is different from an empty
# history and remains fail-closed. Preserve a red run for the sanctioned
# fix-forward assessor.
main_merge_clear() {
  local runs run conclusion
  MAIN_RELEASE_RUN_JSON='{}'
  MAIN_MERGE_CLEAR_REASON=""
  if ! runs="$(ci_main_completed_push_runs)"; then
    MAIN_MERGE_CLEAR_REASON="could not read completed main Postsubmit runs"
    echo "$MAIN_MERGE_CLEAR_REASON" >&2
    return 1
  fi
  if ! run="$(ci_main_latest_completed_push_run "$runs")"; then
    if jq -e '[.workflow_runs[]? | select(.status == "completed"
        and (.conclusion | type == "string" and length > 0)
        and .conclusion != "cancelled" and .conclusion != "skipped")] | length == 0' \
      <<< "$runs" >/dev/null 2>&1; then
      MAIN_MERGE_CLEAR_REASON="no completed main Postsubmit verdict"
      return 0
    fi
    MAIN_MERGE_CLEAR_REASON="could not select the latest completed main Postsubmit verdict"
    echo "$MAIN_MERGE_CLEAR_REASON" >&2
    return 1
  fi
  MAIN_RELEASE_RUN_JSON="$run"
  conclusion="$(jq -r '.conclusion // empty' <<< "$run" 2>/dev/null)" || conclusion=""
  if [ "$conclusion" = success ]; then return 0; fi
  MAIN_MERGE_CLEAR_REASON="latest completed push-triggered run on main concluded $conclusion"
  echo "$MAIN_MERGE_CLEAR_REASON" >&2
  return 1
}

main_red_log() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_DIR/main-red.log" 2>/dev/null || true
}

# Latest completed, non-cancelled verdict for one SHA across main push runs
# and train-branch workflow_dispatch probes, in the workflow the red session
# is running (a suites red is probed with Pipeline suites, not Postsubmit).
# Echoes "success" | "failure" | "pending" (a newer non-completed run exists
# for the SHA) | "none" (no usable verdict). rc 2 on an unreadable answer.
main_red_probe_verdict() {
  local sha="$1" workflow="${2:-ci.yml}" cache_window_start runs
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 2
  case "$workflow" in ci.yml|pipeline-suites.yml) ;; *) return 2 ;; esac
  cache_window_start="$(ci_main_actions_cache_window_start)" || return 2
  runs="$(main_gh api "repos/$REPO/actions/runs?head_sha=$sha&per_page=100&page=1&created=%3E%3D${cache_window_start}" \
    -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' 2>/dev/null)" || return 2
  jq -r --arg sha "$sha" --arg path ".github/workflows/$workflow" '
    [.workflow_runs[]?
      | select(.head_sha == $sha and .path == $path
        and (.event == "push" or .event == "workflow_dispatch"))]
    | sort_by([.created_at // "", .id // 0, .run_attempt // 0]) as $all
    | if ($all | length) == 0 then "none"
      elif ($all | last | .status) != "completed" then "pending"
      else ([$all[] | select(.status == "completed" and .conclusion != "cancelled" and .conclusion != "skipped")]
        | last | .conclusion // "none")
      end' <<< "$runs" 2>/dev/null || return 2
}

# Push a train ref at the midpoint and dispatch the red's own workflow on
# it. The ref must point at exactly the probe SHA: ci.yml's postsubmit job
# only runs a workflow_dispatch whose source_sha input equals the ref head;
# pipeline-suites.yml takes no inputs and runs the full suite for a train
# dispatch, which is how a suites-only red reproduces at a midpoint.
main_red_dispatch_probe() {
  local mid_sha="$1" red_sha="$2" workflow="${3:-ci.yml}" branch="train/bisect-${2:0:12}"
  if ! guarded_write git -C "$REPO_DIR" push -q origin "+${mid_sha}:refs/heads/$branch"; then
    return 1
  fi
  if [ "$workflow" = pipeline-suites.yml ]; then
    guarded_write gh workflow run pipeline-suites.yml --repo "$REPO" --ref "$branch" || return 1
  elif ! guarded_write gh workflow run ci.yml --repo "$REPO" --ref "$branch" -f "source_sha=$mid_sha"; then
    return 1
  fi
  main_red_log "probe dispatched sha=${mid_sha:0:12} workflow=$workflow branch=$branch red=${red_sha:0:12}"
}

main_red_supervisor_event() {
  local red_sha="$1" detail="$2"
  supervisor_inbox_append main-red-bisect "red=${red_sha:0:12} $detail" >/dev/null 2>&1 \
    || echo "main-red-bisect: supervisor event unwritten: red=${red_sha:0:12} $detail" >&2
}

# Reopen the culprit's ticket with the bisect evidence and route it back to
# implementation. state_requeue resets attempts and labels; a ticket the
# merge had already closed is reopened first so the lane transition lands on
# an open issue.
main_red_reopen_ticket() {
  local issue="$1" culprit="$2" red_sha="$3" run_id="$4" revert_pr="$5" state
  state="$(gh issue view "$issue" --repo "$REPO" --json state -q .state 2>/dev/null)" || return 1
  if [ "$state" = "CLOSED" ]; then
    guarded_write gh issue reopen "$issue" --repo "$REPO" || return 1
  fi
  guarded_issue_comment "$issue" "$BOT_DISCLAIMER

main 的自动化验证变红，二分定位到本 ticket 的合入提交是罪魁，已自动回滚。

- 罪魁提交：$culprit
- 首红 SHA：$red_sha（run $run_id，同一 SHA 重跑一次仍红，排除 flaky）
- 回滚 PR：#$revert_pr
- 证据：engine 的 main-red 会话（$AGENT_HOME/main-red/）

请基于回滚合入后的 origin/main 重新应用改动并修复根因，先让对应主线验证通过再重新交付。" || return 1
  state_requeue "$issue" "" "main-red-revert" || return 1
  main_red_log "ticket #$issue reopened after culprit ${culprit:0:12}"
}

# The dedicated revert PR for a bisected culprit uses the shared deploy
# rollback helper, pushed from a throwaway worktree so the live checkout is
# never touched. The returned head is pinned in the red session before the
# sweeper may admit that PR through the red gate.
main_red_open_revert_pr() {
  local issue="$1" culprit="$2" red_sha="$3" run_id="$4" branch url pr head lib_dir
  [ "$DRY_RUN" != 1 ] || return 1
  branch="agent/revert-main-$issue-${culprit:0:12}"
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  declare -F open_deploy_revert_pr >/dev/null 2>&1 || source "$lib_dir/deploy-culprit.sh"
  url="$(open_deploy_revert_pr "$issue" "$culprit" "$red_sha" main "$run_id")" || return 1
  pr="$(grep -oE '/pull/[0-9]+' <<< "$url" | grep -oE '[0-9]+$' | tail -1)"
  [[ "$pr" =~ ^[1-9][0-9]*$ ]] || return 1
  git_fetch_bounded "$REPO_DIR" main "$branch" >/dev/null 2>&1 || return 1
  head="$(git -C "$REPO_DIR" rev-parse "origin/$branch" 2>/dev/null)" || return 1
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || return 1
  main_red_session_write "$red_sha" culprit-found ".revert_head = \"$head\"" || return 1
  printf '%s\n' "$pr"
}

main_red_step_session() { # sha run_json run_history ; advances one session by one step
  local red_sha="$1" run="$2"
  local red_run_id session status green_sha red_created history lo hi count mid verdict culprit issue
  history="$3"
  local subject subject_json attempts age issue_pr pr_state
  local workflow
  workflow="$(jq -r '.red_workflow // "ci.yml"' 2>/dev/null <<< "$run")"
  case "$workflow" in ci.yml|pipeline-suites.yml) ;; *) return 0 ;; esac
  red_run_id="$(jq -r '.id // empty' <<< "$run")"
  session="$(main_red_session_read "$red_sha" 2>/dev/null || true)"
  if [ -z "$session" ]; then
    # First red at this SHA: rerun the failed jobs once. A rerun already in
    # flight removes the run from the completed list, so the next completed
    # sighting of this SHA is the rerun's own verdict.
    if ! guarded_write gh run rerun "$red_run_id" --failed --repo "$REPO"; then
      echo "main-red-bisect: same-SHA rerun request failed for run $red_run_id; retrying next tick" >&2
      return 0
    fi
    red_created="$(jq -r '.created_at // empty' <<< "$run")"
    green_sha="$(jq -r --arg red_created "$red_created" --arg workflow "$workflow" '
      [.workflow_runs[]?
        | select(.red_workflow == $workflow and .status == "completed" and .conclusion == "success"
          and .created_at <= $red_created)]
      | sort_by([.created_at // "", .id // 0, .run_attempt // 0])
      | last | .head_sha // empty' <<< "$history" 2>/dev/null)" || green_sha=""
    if ! main_red_session_write "$red_sha" rerun-requested \
      ".red_run_id = \"${red_run_id}\" | .green_sha = \"${green_sha:-}\" | .red_workflow = \"$workflow\""; then
      echo "main-red-bisect: could not open a session for $red_sha" >&2
      return 0
    fi
    main_red_log "red ${red_sha:0:12} run=$red_run_id: same-SHA rerun requested (flaky check)"
    return 0
  fi
  status="$(jq -r '.status' <<< "$session")"
  case "$status" in
    rerun-requested)
      # Reached only while the latest completed verdict is still this red:
      # the rerun finished red, so the window is deterministic. (A rerun
      # that goes green leaves the latest verdict green and is closed as
      # flaky by the sweep's own pass below, never here.) A missing or
      # non-ancestor baseline cannot anchor a bisect.
      green_sha="$(jq -r '.green_sha // empty' <<< "$session")"
      if ! [[ "$green_sha" =~ ^[0-9a-f]{40}$ ]] \
        || ! git -C "$REPO_DIR" merge-base --is-ancestor "$green_sha" "$red_sha" 2>/dev/null; then
        main_red_session_write "$red_sha" unattributed || return 0
        main_red_supervisor_event "$red_sha" "status=unattributed reason=no-green-baseline run=$red_run_id"
        return 0
      fi
      main_red_session_write "$red_sha" bisecting \
        ".lo = \"$green_sha\" | .hi = \"$red_sha\" | .probe = null" || return 0
      main_red_log "red ${red_sha:0:12}: rerun stayed red; bisecting ${green_sha:0:12}..${red_sha:0:12}"
      return 0
      ;;
    bisecting)
      green_sha="$(jq -r '.green_sha // empty' <<< "$session")"
      workflow="$(jq -r '.red_workflow // "ci.yml"' <<< "$session")"
      lo="$(jq -r '.lo // .green_sha // empty' <<< "$session")"
      hi="$(jq -r '.hi // .red_sha // empty' <<< "$session")"
      if ! git -C "$REPO_DIR" merge-base --is-ancestor "$green_sha" "$red_sha" 2>/dev/null \
        || ! git -C "$REPO_DIR" rev-parse -q --verify "${lo}^{commit}" >/dev/null 2>&1 \
        || ! git -C "$REPO_DIR" rev-parse -q --verify "${hi}^{commit}" >/dev/null 2>&1; then
        return 0
      fi
      count="$(git -C "$REPO_DIR" rev-list --count "$lo..$hi" 2>/dev/null)" || return 0
      if [ "$count" -le 1 ]; then
        main_red_session_write "$red_sha" culprit-found ".culprit = \"${hi}\" | del(.probe)"
        main_red_log "red ${red_sha:0:12}: bisect named culprit ${hi:0:12}"
        return 0
      fi
      mid="$(git -C "$REPO_DIR" rev-list --reverse "$lo..$hi" 2>/dev/null | sed -n "$(( (count + 1) / 2 ))p")"
      [[ "$mid" =~ ^[0-9a-f]{40}$ ]] || return 0
      if [ "$(jq -r '.probe.sha // empty' <<< "$session")" != "$mid" ]; then
        verdict="$(main_red_probe_verdict "$mid" "$workflow")" || return 0
        case "$verdict" in
          success)
            main_red_session_write "$red_sha" bisecting ".lo = \"$mid\" | .probe = null" || return 0
            main_red_log "red ${red_sha:0:12}: midpoint ${mid:0:12} green (reused verdict); window shrinks"
            return 0
            ;;
          failure)
            main_red_session_write "$red_sha" bisecting ".hi = \"$mid\" | .probe = null" || return 0
            main_red_log "red ${red_sha:0:12}: midpoint ${mid:0:12} red (reused verdict); window shrinks"
            return 0
            ;;
          pending)
            main_red_session_write "$red_sha" bisecting ".probe = {sha:\"$mid\",attempts:0}" || return 0
            return 0
            ;;
          none)
            attempts="$(jq -r '.probe.attempts // 0' <<< "$session")"
            main_red_session_write "$red_sha" bisecting ".probe = {sha:\"$mid\",attempts:0}" || return 0
            ;;
        esac
        session="$(main_red_session_read "$red_sha" 2>/dev/null || true)"
      fi
      # A probe is either newly recorded or already in flight for this mid.
      attempts="$(jq -r '.probe.attempts // 0' <<< "$session")"
      verdict="$(main_red_probe_verdict "$mid" "$workflow")" || return 0
      case "$verdict" in
        success)
          main_red_session_write "$red_sha" bisecting ".lo = \"$mid\" | .probe = null" || return 0
          main_red_log "red ${red_sha:0:12}: midpoint ${mid:0:12} green; window shrinks"
          ;;
        failure)
          main_red_session_write "$red_sha" bisecting ".hi = \"$mid\" | .probe = null" || return 0
          main_red_log "red ${red_sha:0:12}: midpoint ${mid:0:12} red; window shrinks"
          ;;
        pending)
          ;;
        none)
          age=$(( $(date +%s) - $(stat -c %Y "$(main_red_session_file "$red_sha")" 2>/dev/null || echo 0) ))
          if [ "$attempts" -ge "$MAIN_RED_PROBE_DISPATCH_ATTEMPTS" ]; then
            main_red_session_write "$red_sha" unattributed || return 0
            main_red_supervisor_event "$red_sha" "status=unattributed reason=probe-dispatch-exhausted mid=${mid:0:12}"
          elif [ "$attempts" -eq 0 ] || [ "$age" -ge "$MAIN_RED_PROBE_RETRY_DELAY_SECONDS" ]; then
            main_red_session_write "$red_sha" bisecting ".probe.attempts = (($attempts // 0) + 1)" || return 0
            if ! main_red_dispatch_probe "$mid" "$red_sha" "$workflow"; then
              echo "main-red-bisect: midpoint dispatch failed for $mid (attempt $((attempts + 1))/$MAIN_RED_PROBE_DISPATCH_ATTEMPTS)" >&2
            fi
          fi
          ;;
      esac
      ;;
    culprit-found)
      culprit="$(jq -r '.culprit // empty' <<< "$session")"
      [[ "$culprit" =~ ^[0-9a-f]{40}$ ]] || return 0
      if git -C "$REPO_DIR" log origin/main --format=%H --grep="This reverts commit ${culprit}." 2>/dev/null | grep -q .; then
        main_red_session_write "$red_sha" reverted
        main_red_log "red ${red_sha:0:12}: culprit ${culprit:0:12} already reverted on main"
        return 0
      fi
      subject="$(git -C "$REPO_DIR" log -1 --format=%s "$culprit" 2>/dev/null)" || return 0
      if ! [[ "$subject" =~ ^fix\(#([0-9]+)\): ]]; then
        main_red_session_write "$red_sha" unattributed
        main_red_supervisor_event "$red_sha" "status=unattributed reason=no-owner-issue culprit=${culprit:0:12} subject=\"$subject\""
        return 0
      fi
      issue="${BASH_REMATCH[1]}"
      subject_json="$(jq -cn --arg value "$subject" '$value')" || return 0
      attempts="$(jq -r '.revert_attempts // 0' <<< "$session")"
      if [ "$attempts" -ge "$MAIN_RED_REVERT_ATTEMPTS" ]; then
        main_red_session_write "$red_sha" unattributed
        main_red_supervisor_event "$red_sha" "status=unattributed reason=revert-pr-failed culprit=${culprit:0:12} issue=$issue"
        return 0
      fi
      main_red_session_write "$red_sha" culprit-found '.revert_attempts = ((.revert_attempts // 0) + 1)'
      if ! issue_pr="$(main_red_open_revert_pr "$issue" "$culprit" "$red_sha" "$red_run_id")" \
        || ! [[ "$issue_pr" =~ ^[0-9]+$ ]]; then
        echo "main-red-bisect: revert PR for ${culprit:0:12} could not be opened (attempt $((attempts + 1))/$MAIN_RED_REVERT_ATTEMPTS)" >&2
        return 0
      fi
      main_red_session_write "$red_sha" revert-open ".issue = $issue | .revert_pr = $issue_pr | .culprit_subject = $subject_json"
      if main_red_reopen_ticket "$issue" "$culprit" "$red_sha" "$red_run_id" "$issue_pr"; then
        main_red_session_write "$red_sha" revert-open '.ticket_reopened = true'
      else
        echo "main-red-bisect: ticket #$issue reopen/comment failed; retrying next tick" >&2
      fi
      main_red_log "red ${red_sha:0:12}: culprit ${culprit:0:12} (issue #$issue) -> revert PR #$issue_pr; ticket reopened"
      ;;
    revert-open)
      issue="$(jq -r '.issue // empty' <<< "$session")"
      culprit="$(jq -r '.culprit // empty' <<< "$session")"
      if [ "$(jq -r '.ticket_reopened // false' <<< "$session")" != true ] \
        && [[ "$issue" =~ ^[0-9]+$ && "$culprit" =~ ^[0-9a-f]{40}$ ]]; then
        if main_red_reopen_ticket "$issue" "$culprit" "$red_sha" "$red_run_id" "$(jq -r '.revert_pr // empty' <<< "$session")"; then
          main_red_session_write "$red_sha" revert-open '.ticket_reopened = true'
        fi
      fi
      issue_pr="$(jq -r '.revert_pr // empty' <<< "$session")"
      [[ "$issue_pr" =~ ^[0-9]+$ ]] || return 0
      pr_state="$(gh pr view "$issue_pr" --repo "$REPO" --json state -q .state 2>/dev/null)" || return 0
      case "$pr_state" in
        MERGED)
          main_red_session_write "$red_sha" reverted
          main_red_log "red ${red_sha:0:12}: revert PR #$issue_pr merged; existing Postsubmit merge gate remains authoritative"
          ;;
        CLOSED)
          main_red_session_write "$red_sha" unattributed
          main_red_supervisor_event "$red_sha" "status=unattributed reason=revert-pr-closed-unmerged pr=$issue_pr"
          ;;
      esac
      ;;
    reverted|flaky|unattributed)
      # Terminal records; a later green Postsubmit clears the existing
      # ci.yml merge gate.
      ;;
  esac
}

# Read both main validation workflows for recovery. A direct-main [skip ci]
# commit can run Pipeline suites without creating a newer ci.yml/Postsubmit run.
main_red_completed_runs() {
  local postsubmit suites
  postsubmit="$(ci_main_completed_push_runs ci.yml)" || return 1
  suites="$(ci_main_completed_push_runs pipeline-suites.yml)" || return 1
  jq -cn --argjson postsubmit "$postsubmit" --argjson suites "$suites" '
    {workflow_runs:
      ([$postsubmit.workflow_runs[]? | . + {red_workflow:"ci.yml"}]
       + [$suites.workflow_runs[]? | . + {red_workflow:"pipeline-suites.yml"}])}'
}

main_red_latest_failed_run() {
  jq -ce '
    [.workflow_runs[]?
      | select(.status == "completed"
        and (.conclusion | type == "string" and length > 0)
        and .conclusion != "cancelled" and .conclusion != "skipped")]
    | sort_by(.red_workflow)
    | group_by(.red_workflow)
    | map(sort_by([.created_at // "", .id // 0, .run_attempt // 0]) | last)
    | map(select(.conclusion == "failure"))
    | sort_by([.created_at // "", .id // 0, .run_attempt // 0])
    | last // empty' <<< "$1" 2>/dev/null
}

# While manually paused, discover a main red and wake the supervisor without
# creating a session or starting the rerun/bisect/revert state machine.
main_red_paused_discovery() {
  local runs run sha workflow run_id
  runs="$(main_red_completed_runs)" || return 1
  run="$(main_red_latest_failed_run "$runs")" || return 0
  sha="$(jq -r '.head_sha // empty' <<< "$run")"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 0
  workflow="$(jq -r '.red_workflow // "ci.yml"' <<< "$run")"
  run_id="$(jq -r '.id // empty' <<< "$run")"
  supervisor_inbox_append_once "main-red-paused:$workflow:$sha" \
    "main-red-bisect red=${sha:0:12} status=paused workflow=$workflow run=$run_id"
}

# The tick's maintenance entry point: if the latest completed main validation
# run is red, advance that red's session by one bounded step;
# then close any rerun-requested session whose same-SHA rerun went green
# (that red was flaky and the latest verdict is green again, so the step
# path above can no longer see it).
main_red_bisect_sweep() {
  local runs run verdict sha session_file session red_sha rerun_verdict workflow
  if ! runs="$(main_red_completed_runs)"; then
    echo "main-red-bisect: could not read the completed main verdict list" >&2
    return 0
  fi
  if run="$(main_red_latest_failed_run "$runs")" && [ -n "$run" ]; then
    verdict="$(jq -r '.conclusion // empty' 2>/dev/null <<< "$run")"
    sha="$(jq -r '.head_sha // empty' 2>/dev/null <<< "$run")"
    if [ "$verdict" = failure ] && [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      # Sessions compare commits; the red SHA must be present locally.
      git_fetch_bounded "$REPO_DIR" main >/dev/null 2>&1 || true
      if ! git -C "$REPO_DIR" rev-parse -q --verify "${sha}^{commit}" >/dev/null 2>&1; then
        echo "main-red-bisect: red SHA $sha is not present after fetch; retrying next tick" >&2
        return 0
      fi
      main_red_step_session "$sha" "$run" "$runs"
    fi
  fi
  [ -d "$MAIN_RED_DIR" ] || return 0
  while IFS= read -r session_file; do
    [ -n "$session_file" ] || continue
    session="$(main_red_session_read_for_file "$session_file" 2>/dev/null || true)"
    [ "$(jq -r '.status // empty' <<< "$session" 2>/dev/null)" = rerun-requested ] || continue
    red_sha="$(jq -r '.red_sha // empty' <<< "$session")"
    [[ "$red_sha" =~ ^[0-9a-f]{40}$ ]] || continue
    workflow="$(jq -r '.red_workflow // "ci.yml"' <<< "$session")"
    rerun_verdict="$(main_red_probe_verdict "$red_sha" "$workflow")" || continue
    if [ "$rerun_verdict" = success ]; then
      main_red_session_write "$red_sha" flaky
      main_red_log "red ${red_sha:0:12}: same-SHA rerun went green; recorded flaky, no revert"
    fi
  done < <(printf '%s\n' "$MAIN_RED_DIR"/*.json)
  return 0
}

main_gh() {
  if declare -F gh_q >/dev/null 2>&1; then gh_q "$@"; else gh "$@"; fi
}

# Moving ten-year bound defeats the observed TLS-proxy cache; a century bound
# hid real runs. Use the same supported window for every mutable Actions list.
ci_main_actions_cache_window_start() {
  date -u -d '10 years ago' '+%Y-%m-%dT%H:%M:%SZ'
}

# Exact-tip Postsubmit evidence is shared by build admission and HEALTH. The
# completed-run history can lag, so resolve current main and the CI run through
# their SHA-scoped Actions endpoints instead of borrowing a prior verdict.
ci_main_current_commit() {
  local timeout="${1:-}" response
  response="$(
    if [ -n "$timeout" ]; then
      main_gh() { gh_timeout -k 1 "$timeout" "$@"; }
    fi
    main_gh api "repos/$REPO/commits/main" \
      -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' 2>/dev/null
  )" || return 1
  jq -e 'type == "object" and (.sha | type == "string" and test("^[0-9a-f]{40}$"))
    and (.commit.committer.date | type == "string")' <<< "$response" >/dev/null 2>&1 || return 1
  printf '%s\n' "$response"
}

ci_main_commit_for_sha() {
  local sha="$1" timeout="${2:-}" response
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  response="$(
    if [ -n "$timeout" ]; then
      main_gh() { gh_timeout -k 1 "$timeout" "$@"; }
    fi
    main_gh api "repos/$REPO/commits/$sha" 2>/dev/null
  )" || return 1
  jq -e --arg sha "$sha" 'type == "object" and .sha == $sha
    and (.commit.message | type == "string")' <<< "$response" >/dev/null 2>&1 || return 1
  printf '%s\n' "$response"
}

postsubmit_request_recovery_dir() {
  if [[ -n "${RELEASE_RECOVERY_DIR:-}" ]]; then
    printf '%s\n' "$RELEASE_RECOVERY_DIR"
  else
    local agent_home="${AGENT_HOME:-${ZF_HOME:-${HOME:?HOME is not set}/.zenoforge}}"
    printf '%s/release-recovery\n' "$agent_home"
  fi
}

postsubmit_request_record_file() {
  local sha="$1" recovery_dir
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  recovery_dir="$(postsubmit_request_recovery_dir)" || return 1
  printf '%s/postsubmit/%s.json\n' "$recovery_dir" "$sha"
}

postsubmit_request_record_state() {
  local sha="$1" record
  record="$(postsubmit_request_record_file "$sha")" || return 2
  [ -e "$record" ] || return 1
  [ -r "$record" ] || return 2
  jq -er --arg sha "$sha" '
    if type == "object" and .source_sha == $sha and
      (.status | IN("dispatching", "requested", "queued", "in_progress", "completed", "dispatch-failed"))
    then .status else error("invalid Postsubmit request record") end' \
    "$record" 2>/dev/null || return 2
}

_postsubmit_request_record_write_locked() {
  local sha="$1" status="$2" run_id="$3" conclusion="$4" record tmp now
  record="$(postsubmit_request_record_file "$sha")" || return 1
  mkdir -p "${record%/*}" || return 1
  tmp="$record.tmp.$BASHPID"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  if [ -e "$record" ]; then
    jq --arg sha "$sha" --arg status "$status" --arg run_id "$run_id" \
      --arg conclusion "$conclusion" --arg now "$now" \
      'if type != "object" or .source_sha != $sha then error("Postsubmit request source SHA mismatch") else . end
       | .status=$status | .run_id=$run_id | .conclusion=$conclusion | .updated_at=$now
       | if $status == "dispatching" then
           (.dispatch_attempts // 0) as $attempts
           | if ($attempts | type) == "number" and $attempts >= 0 and $attempts == ($attempts | floor)
             then .dispatch_attempts=$attempts+1 else error("invalid Postsubmit dispatch attempt count") end
         else . end' \
      "$record" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  else
    jq -n --arg sha "$sha" --arg status "$status" --arg run_id "$run_id" \
      --arg conclusion "$conclusion" --arg now "$now" \
      '{source_sha:$sha, status:$status, run_id:$run_id, conclusion:$conclusion,
        dispatch_attempts:(if $status == "dispatching" then 1 else 0 end),
        dispatched_at:$now, updated_at:$now}' > "$tmp" || { rm -f -- "$tmp"; return 1; }
  fi
  mv -f -- "$tmp" "$record"
}

postsubmit_request_record_write() (
  local sha="$1" status="$2" run_id="$3" conclusion="$4" recovery_dir lock_file lock_fd
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  recovery_dir="$(postsubmit_request_recovery_dir)" || return 1
  lock_file="$recovery_dir/postsubmit/.locks/$sha.lock"
  mkdir -p "${lock_file%/*}" || return 1
  exec {lock_fd}> "$lock_file" || return 1
  flock -x "$lock_fd" || return 1
  _postsubmit_request_record_write_locked "$sha" "$status" "$run_id" "$conclusion"
)

# Claim a per-SHA Postsubmit dispatch across every entry point before calling
# GitHub. Return 0 for the winner, 1 when another request owns the SHA or its
# retry window/cap has not opened, and 2 when the durable record is invalid.
postsubmit_request_dispatch_claim() (
  local sha="$1" retry_delay_seconds="${2:-600}" max_attempts="${3:-3}"
  local allow_requested_retry="${4:-0}" recovery_dir record lock_file lock_fd
  local state attempts updated_at updated_epoch now_epoch age
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 2
  [[ "$retry_delay_seconds" =~ ^[0-9]+$ && "$max_attempts" =~ ^[1-9][0-9]*$ ]] || return 2
  [[ "$allow_requested_retry" == 0 || "$allow_requested_retry" == 1 ]] || return 2
  recovery_dir="$(postsubmit_request_recovery_dir)" || return 2
  record="$(postsubmit_request_record_file "$sha")" || return 2
  lock_file="$recovery_dir/postsubmit/.locks/$sha.lock"
  mkdir -p "${lock_file%/*}" "${record%/*}" || return 2
  exec {lock_fd}> "$lock_file" || return 2
  flock -x "$lock_fd" || return 2
  if [ -e "$record" ]; then
    if ! jq -e --arg sha "$sha" 'type == "object" and .source_sha == $sha
      and (.status | IN("dispatching", "requested", "queued", "in_progress", "completed", "dispatch-failed"))' \
      "$record" >/dev/null 2>&1; then
      return 2
    fi
    state="$(jq -r '.status' "$record")" || return 2
    case "$state" in
      dispatch-failed|dispatching) ;;
      requested)
        [ "$allow_requested_retry" = 1 ] || return 1
        ;;
      *) return 1 ;;
    esac
    attempts="$(jq -er '(.dispatch_attempts // 0) as $n
      | if ($n | type) == "number" and $n >= 0 and $n == ($n | floor)
        then $n else error("invalid Postsubmit dispatch attempt count") end' "$record" 2>/dev/null)" || return 2
    if [ "$attempts" -ge "$max_attempts" ]; then return 1; fi
    updated_at="$(jq -er '.updated_at | select(type == "string" and length > 0)' "$record" 2>/dev/null)" || return 2
    updated_epoch="$(date -u -d "$updated_at" +%s 2>/dev/null)" || return 2
    now_epoch="$(date -u +%s)" || return 2
    age=$((now_epoch - updated_epoch))
    if [ "$age" -lt "$retry_delay_seconds" ]; then return 1; fi
  fi
  _postsubmit_request_record_write_locked "$sha" dispatching "" "" || return 2
)

ci_main_postsubmit_run_history_for_sha() {
  local sha="$1" timeout="${2:-}" runs selected cache_window_start
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 2
  cache_window_start="$(ci_main_actions_cache_window_start)" || return 2
  runs="$(
    if [ -n "$timeout" ]; then
      main_gh() { gh_timeout -k 1 "$timeout" "$@"; }
    fi
    main_gh api "repos/$REPO/actions/runs?head_sha=$sha&per_page=100&page=1&created=%3E%3D${cache_window_start}" \
      -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' 2>/dev/null
  )" || return 2
  jq -e 'type == "object" and (.workflow_runs | type == "array")' <<< "$runs" >/dev/null 2>&1 || return 2
  selected="$(jq -c --arg sha "$sha" '
    [.workflow_runs[]?
      | select(.head_branch == "main" and .head_sha == $sha
        and (.event == "push" or .event == "workflow_dispatch")
        and .path == ".github/workflows/ci.yml")]
    | sort_by([.created_at // "", .id // 0, .run_attempt // 0])' <<< "$runs")" || return 2
  [ "$selected" != "[]" ] || return 1
  printf '%s\n' "$selected"
}

ci_main_postsubmit_run_for_sha() {
  local sha="$1" timeout="${2:-}" runs
  if runs="$(ci_main_postsubmit_run_history_for_sha "$sha" "$timeout")"; then :; else
    return $?
  fi
  jq -c 'last' <<< "$runs"
}

ci_main_postsubmit_job_for_run() {
  local run_id="$1" timeout="${2:-}" jobs selected
  [[ "$run_id" =~ ^[0-9]+$ ]] || return 2
  jobs="$(
    if [ -n "$timeout" ]; then
      main_gh() { gh_timeout -k 1 "$timeout" "$@"; }
    fi
    main_gh api "repos/$REPO/actions/runs/$run_id/jobs?per_page=100&page=1" \
      -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' 2>/dev/null
  )" || return 2
  jq -e 'type == "object" and (.jobs | type == "array")' <<< "$jobs" >/dev/null 2>&1 || return 2
  selected="$(jq -c '[.jobs[]? | select(.name == "Postsubmit validate")]
    | sort_by(.id // 0) | last // {status:"missing",conclusion:"missing"}' <<< "$jobs")" || return 2
  printf '%s\n' "$selected"
}

ci_main_postsubmit_green_run_for_sha() {
  local sha="$1" history="${2:-}" latest run_id jobs
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 2
  if [ -z "$history" ]; then
    if history="$(ci_main_postsubmit_run_history_for_sha "$sha")"; then :; else return $?; fi
  fi
  jq -e 'type == "array"' <<< "$history" >/dev/null 2>&1 || return 2
  latest="$(jq -c --arg sha "$sha" '
    [.[]
      | select(.head_branch == "main" and .head_sha == $sha
        and (.event == "push" or .event == "workflow_dispatch")
        and .path == ".github/workflows/ci.yml")]
    | sort_by([.created_at // "", .id // 0, .run_attempt // 0])
    | last // empty' <<< "$history")" || return 2
  [ -n "$latest" ] || return 1
  jq -e '.status == "completed" and .conclusion == "success"' <<< "$latest" >/dev/null 2>&1 || return 1
  run_id="$(jq -r '.id // empty' <<< "$latest")"
  [[ "$run_id" =~ ^[0-9]+$ ]] || return 2
  jobs="$(ci_main_postsubmit_job_for_run "$run_id")" || return 2
  if jq -e '.status == "completed" and .conclusion == "success"' <<< "$jobs" >/dev/null 2>&1; then
    printf '%s\n' "$latest"
    return 0
  fi
  return 1
}

ci_main_postsubmit_green_for_sha() {
  local sha="$1" history="${2:-}" green_run
  if green_run="$(ci_main_postsubmit_green_run_for_sha "$sha" "$history")"; then
    return 0
  else
    return $?
  fi
}

main_fix_forward_carried_capacity_check() {
  local checks_json="$1" expected_head="$2" link link_path run_id job_id run_json check_name
  local aggregate="Required CI gates"
  [[ "$expected_head" =~ ^[0-9a-f]{40}$ ]] || return 1
  checks_json="$(pr_latest_check_rows "$checks_json")" || return 1
  jq -e --arg touched "Touched packages PR gate" --arg aggregate "$aggregate" '
    type == "array"
    and all(.[]; (.name | type == "string") and (.bucket | type == "string"))
    and ([.[] | select(.bucket == "pending" or .bucket == "cancel")] | length == 0)
    and ([.[] | select(.name == $touched)] | length == 1)
    and ([.[] | select(.name == $aggregate and .bucket == "fail")] | length == 1)
    and ([.[] | select(.bucket == "fail") | .name] | sort) == ([$aggregate, $touched] | sort)
    and ([.[] | select(.bucket == "fail")][0].link | type == "string" and length > 0)
  ' <<< "$checks_json" >/dev/null 2>&1 || return 1

  # "Required CI gates" is a pure rollup whose needs include "Touched packages PR gate":
  # when Touched's failure is the accepted capacity exception, the aggregate's red is that
  # same failure counted twice, so it is exempted alongside Touched here. Everything else
  # in the shared required definition (delivery policy, Required contract gates) must pass.
  for check_name in "${REQUIRED_PR_CHECKS[@]}"; do
    [[ "$check_name" == "Touched packages PR gate" || "$check_name" == "$aggregate" ]] && continue
    jq -e --arg name "$check_name" 'any(.[]; .name == $name and .bucket == "pass")' <<< "$checks_json" >/dev/null 2>&1 || return 1
  done
  # The aggregate is red when Touched is red, so this narrow exception must inspect its other
  # children: the carried-capacity exception is valid only when the remaining CI gates passed.
  for check_name in "NUL bytes & lone negative assertions" "Example pack PR gate" "Repo-path regression PR gate"; do
    jq -e --arg name "$check_name" 'any(.[]; .name == $name and .bucket == "pass")' <<< "$checks_json" >/dev/null 2>&1 || return 1
  done

  link="$(jq -r '[.[] | select(.name == "Touched packages PR gate" and .bucket == "fail")][0].link // empty' <<< "$checks_json")" || return 1
  [[ "$link" == "https://github.com/$REPO/actions/runs/"* ]] || return 1
  link_path="${link#https://github.com/$REPO/actions/runs/}"
  [[ "$link_path" =~ ^([1-9][0-9]*)/job/([1-9][0-9]*)$ ]] || return 1
  run_id="${BASH_REMATCH[1]}"
  job_id="${BASH_REMATCH[2]}"
  run_json="$(main_gh run view "$run_id" --repo "$REPO" --json headSha,status,conclusion,jobs -q '{headSha,status,conclusion,jobs}' 2>/dev/null)" || return 1
  jq -e --arg head "$expected_head" --argjson job_id "$job_id" '
    .headSha == $head and .status == "completed" and .conclusion == "failure"
    and ([.jobs[]? | select(.databaseId == $job_id)] | length == 1)
    and ([.jobs[]? | select(.databaseId == $job_id)][0] as $job
      | $job.conclusion == "failure"
      and ([$job.steps[]? | select(.conclusion == "failure")] as $failed
        | ($failed | length) == 1
          and $failed[0].name == "Ensure CI runner has capacity before dependency install")
      and ([$job.steps[]? | select(.name == "Run touched package gates in Dagger"
          or .name == "Run touched Postsubmit integration gates in Dagger"
          or .name == "Run changed integration tests in Dagger"
          or .name == "Test Example Agent hook consumer")] as $source
        | ($source | length) > 0 and all($source[]; .conclusion == "skipped")))
    and all(.jobs[]?; .conclusion != "failure" or .databaseId == $job_id)
  ' <<< "$run_json" >/dev/null 2>&1
}

main_fix_forward_carried_pr_registered() {
  local pr_number="$1" registry_path remote_command registry result script_dir
  [[ "$pr_number" =~ ^[1-9][0-9]*$ && -n "${DEPLOY_HOST:-}" ]] || return 2
  registry_path="${DEPLOY_DIR:-/srv/app}/release-drift-carried.tsv"
  printf -v remote_command 'path=%q; if [ ! -e "$path" ] && [ ! -L "$path" ]; then exit 0; fi; [ -r "$path" ] || exit 44; cat -- "$path"' "$registry_path"
  registry="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$DEPLOY_HOST" "$remote_command")" || return 2
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  result="$(bash "$script_dir/release-drift-carried.sh" --contains-pr "$pr_number" <<< "$registry")" || return 2
  jq -e '.unknown == false and .approved == true' <<< "$result" >/dev/null 2>&1
}

main_fix_forward_carried_checks_still_valid() {
  main_fix_forward_carried_capacity_check "$2" "$3" && main_fix_forward_carried_pr_registered "$1"
}

main_fix_forward_carried_exception_for_pr() {
  local pr_number="$1"
  main_merge_clear >/dev/null 2>&1 && return 1
  main_fix_forward_prepare_for_pr "$pr_number" || return 1
  [[ "$MAIN_FIX_FORWARD_REASON" == carried-hotpatch:* ]]
}

main_release_jobs_for_fix_forward() {
  local run_id="$1" jobs
  [[ "$run_id" =~ ^[1-9][0-9]*$ ]] || return 1
  jobs="$(main_gh api "repos/$REPO/actions/runs/$run_id/jobs?per_page=100" \
    -q '{total_count, jobs:[.jobs[] | {name, conclusion}]}')" || return 1
  jq -e 'type == "object" and (.total_count | type == "number")
    and (.jobs | type == "array") and (.total_count == (.jobs | length))
    and all(.jobs[]; (.name | type == "string" and length > 0)
      and (.conclusion == "success" or .conclusion == "skipped" or .conclusion == "failure"))' \
    <<< "$jobs" >/dev/null 2>&1 || return 1
  printf '%s\n' "$jobs"
}

main_current_sha() {
  local cache_window_start sha
  cache_window_start="$(date -u -d '10 years ago' '+%Y-%m-%dT%H:%M:%SZ')" || return 1
  sha="$(main_gh api -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
    "repos/$REPO/commits?sha=main&per_page=1&since=$cache_window_start" -q '.[0].sha')" || return 1
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$sha"
}

main_fix_forward_assess() {
  local run_json="$1" jobs_json="$2" main_sha="$3" base_sha="$4"
  local checks_json="$5" reserved_run_id="$6" run_id job_name check_name
  local main_jobs pr_jobs refuse="" carried_capacity_exception=0
  local -a failed_jobs=() covered_checks=()

  if ! jq -e 'type == "object" and (.id | tostring | test("^[1-9][0-9]*$"))
    and .status == "completed" and .conclusion == "failure"' <<< "$run_json" >/dev/null 2>&1; then
    refuse="latest completed main verdict is not a failure"
  else
    run_id="$(jq -r '.id | tostring' <<< "$run_json")"
    if [[ "$reserved_run_id" == "$run_id" ]]; then
      refuse="fix-forward already used for main run $run_id"
    elif ! [[ "$main_sha" =~ ^[0-9a-f]{40}$ && "$base_sha" =~ ^[0-9a-f]{40}$ ]] \
      || [[ "$base_sha" != "$main_sha" ]]; then
      refuse="PR base is not the current main tip"
    elif [[ "$(pr_checks_outcome "$checks_json")" != pass ]]; then
      if [[ "${7:-0}" == 1 && "${8:-0}" == 1 ]] && jq -e '.total_count == (.jobs | length) and [.jobs[] | select(.conclusion == "failure") | .name] == ["Postsubmit validate"]' <<< "$jobs_json" >/dev/null 2>&1; then
        carried_capacity_exception=1
      else
        refuse="PR required checks are not all green"
      fi
    elif ! jq -e 'type == "object" and (.total_count | type == "number")
      and (.jobs | type == "array") and (.total_count == (.jobs | length))
      and (.jobs | length > 0)
      and all(.jobs[]; (.name | type == "string" and length > 0)
        and (.conclusion == "success" or .conclusion == "skipped" or .conclusion == "failure"))
      and any(.jobs[]; .conclusion == "failure")' <<< "$jobs_json" >/dev/null 2>&1; then
      refuse="main failure jobs are unreadable or incomplete"
    else
      mapfile -t failed_jobs < <(jq -r '.jobs[] | select(.conclusion == "failure") | .name' <<< "$jobs_json")
      for job_name in "${failed_jobs[@]}"; do
        if [[ "$job_name" == "Postsubmit validate" ]]; then
          if [[ "$carried_capacity_exception" == 1 ]]; then
            continue
          fi
          if ! jq -e 'any(.[]; .name == "Touched packages PR gate" and .bucket == "pass")' \
            <<< "$checks_json" >/dev/null 2>&1; then
            refuse="main red on $job_name is not covered by passing PR checks"
            break
          fi
          covered_checks+=("Touched packages PR gate")
          # The aggregate already proved the regression gates green-or-legitimately-skipped
          # (#4484); covering a Postsubmit-validate failure now means Touched + Required CI gates.
          if jq -e --arg name "Required CI gates" \
            'any(.[]; .name == $name and .bucket == "pass")' <<< "$checks_json" >/dev/null 2>&1; then
            covered_checks+=("Required CI gates")
          else
            refuse="main red on $job_name lacks a passing repository regression gate"
            break
          fi
        elif jq -e --arg name "$job_name" \
          'any(.[]; .name == $name and .bucket == "pass")' <<< "$checks_json" >/dev/null 2>&1; then
          covered_checks+=("$job_name")
        else
          refuse="main red on $job_name is not covered by passing PR checks"
          break
        fi
      done
    fi
  fi

  if [[ -n "$refuse" ]]; then
    jq -cn --arg reason "$refuse" '{eligible:false,reason:$reason}'
    return 0
  fi
  main_jobs="$(jq -r '[.jobs[] | select(.conclusion == "failure") | .name]
    | reduce .[] as $name ([]; if index($name) then . else . + [$name] end) | join(", ")' <<< "$jobs_json")"
  if [[ "$carried_capacity_exception" == 1 ]]; then
    pr_jobs="PR checks green except Touched packages PR gate (shared runner-capacity failure; source validation did not run)"
    jq -cn --arg run_id "$run_id" --arg main_jobs "$main_jobs" --arg pr_jobs "$pr_jobs" '{eligible:true,run_id:$run_id,main_jobs:$main_jobs,pr_jobs:$pr_jobs,reason:("carried-hotpatch: main red on " + $main_jobs + "; " + $pr_jobs)}'
    return 0
  fi
  pr_jobs="$(printf '%s\n' "${covered_checks[@]}" | jq -rRsc 'split("\n") | map(select(length > 0))
    | reduce .[] as $name ([]; if index($name) then . else . + [$name] end) | join(", ")')"
  jq -cn --arg run_id "$run_id" --arg main_jobs "$main_jobs" --arg pr_jobs "$pr_jobs" \
    '{eligible:true,run_id:$run_id,main_jobs:$main_jobs,pr_jobs:$pr_jobs,
      reason:("fix-forward: main red on " + $main_jobs + "; PR checks green on " + $pr_jobs)}'
}

main_fix_forward_reserved_run() {
  local path="$STATE_DIR/merge-fix-forward.json"
  [[ -e "$path" ]] || return 0
  jq -er 'select(type == "object" and (.run_id | type == "string" and test("^[1-9][0-9]*$"))) | .run_id' \
    "$path" 2>/dev/null
}

main_fix_forward_reserve() {
  local run_id="$1" main_sha="$2" pr_number="$3" path="$STATE_DIR/merge-fix-forward.json" tmp
  [[ "$run_id" =~ ^[1-9][0-9]*$ && "$main_sha" =~ ^[0-9a-f]{40}$ \
    && "$pr_number" =~ ^[1-9][0-9]*$ ]] || return 1
  mkdir -p "$STATE_DIR" || return 1
  tmp="$(mktemp "$STATE_DIR/.merge-fix-forward.XXXXXX")" || return 1
  if ! jq -cn --arg run_id "$run_id" --arg main_sha "$main_sha" --arg pr "$pr_number" \
    '{run_id:$run_id,main_sha:$main_sha,pr_number:$pr}' > "$tmp" \
    || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
  return 0
}

main_fix_forward_prepare_for_pr() {
  local pr_number="$1" run_id current_pr checks jobs main_sha reserved assessment
  MAIN_FIX_FORWARD_REASON=""
  MAIN_FIX_FORWARD_RUN_ID=""
  MAIN_FIX_FORWARD_MAIN_SHA=""
  MAIN_FIX_FORWARD_PR_JSON=""
  MAIN_FIX_FORWARD_CHECKS=""
  if ! jq -e '.status == "completed" and .conclusion == "failure"
    and (.id | tostring | test("^[1-9][0-9]*$"))' <<< "$MAIN_RELEASE_RUN_JSON" >/dev/null 2>&1; then
    MAIN_FIX_FORWARD_REASON="latest completed main verdict is not a failure"
    return 1
  fi
  run_id="$(jq -r '.id | tostring' <<< "$MAIN_RELEASE_RUN_JSON")"
  if ! jobs="$(main_release_jobs_for_fix_forward "$run_id")" \
    || ! main_sha="$(main_current_sha)" \
    || ! current_pr="$(gh pr view "$pr_number" --repo "$REPO" \
      --json baseRefOid,headRefOid,mergeable,mergeStateStatus,updatedAt,files,isDraft 2>/dev/null)" \
    || ! checks="$(gh pr checks "$pr_number" --repo "$REPO" --json name,bucket,link 2>/dev/null)" \
    || ! reserved="$(main_fix_forward_reserved_run)"; then
    MAIN_FIX_FORWARD_REASON="could not verify current main, PR checks, or fix-forward reservation"
    return 1
  fi
  assessment="$(main_fix_forward_assess "$MAIN_RELEASE_RUN_JSON" "$jobs" "$main_sha" \
    "$(jq -r '.baseRefOid // empty' <<< "$current_pr")" "$checks" "$reserved")"
  if [[ "$(jq -r '.reason // empty' <<< "$assessment")" == "PR required checks are not all green" ]] \
    && main_fix_forward_carried_capacity_check "$checks" "$(jq -r '.headRefOid // empty' <<< "$current_pr")" \
    && main_fix_forward_carried_pr_registered "$pr_number"; then
    assessment="$(main_fix_forward_assess "$MAIN_RELEASE_RUN_JSON" "$jobs" "$main_sha" "$(jq -r '.baseRefOid // empty' <<< "$current_pr")" "$checks" "$reserved" 1 1)"
  fi
  MAIN_FIX_FORWARD_REASON="$(jq -r '.reason // "fix-forward eligibility unavailable"' <<< "$assessment")"
  if ! jq -e '.eligible == true' <<< "$assessment" >/dev/null 2>&1; then
    return 1
  fi
  MAIN_FIX_FORWARD_RUN_ID="$(jq -r '.run_id' <<< "$assessment")"
  MAIN_FIX_FORWARD_MAIN_SHA="$main_sha"
  MAIN_FIX_FORWARD_PR_JSON="$current_pr"
  MAIN_FIX_FORWARD_CHECKS="$checks"
}

# 2026-09-13 fix: a real race, not a residual risk — the merge-queue wait
# once polled for a green main and then called `gh pr merge` with nothing
# holding the two steps together, so two concurrent runs could both merge
# off the same stale green. The mutex closed that.
#
# 2026-10-28 (#4356, optimistic merging): the mutex no longer has a CI wait
# to protect. It surrounds only the `gh pr merge` API call in
# merge_pr_and_reconcile(); every gate read and other mutation runs outside
# it. A red main blocks ordinary merges until the revert's Postsubmit is
# green; sweep-merges.sh admits only the matching revert PR while red.
# guarded_pr_merge() still pins the exact head and treats an already-merged
# PR as done.
#
# 2026-09-12 review, item 2: this used to block with plain `flock 8` (no
# -w), same "hung stage holds its cap slot forever" shape as the other four
# gaps in the same review — a run stuck waiting here forever (the other
# holder itself wedged, e.g. mid `gh pr merge` hang) pins an implement slot
# permanently, and nothing pages anyone.
# MERGE_LOCK_WAIT_SECONDS bounds it instead: 70 minutes, comfortably above
# the worst observed legitimate hold (a `gh` call wedged behind the proxy
# for 14+ minutes, ci.yml's own record), so a timeout here really does mean
# "wedged," not "still working." A timed-out wait is a normal outcome, not a
# crash — callers treat it like any other merge-gate refusal, not a bare
# non-zero exit under `set -e`.
#
# acquire_merge_lock() blocks (bounded by $2/MERGE_LOCK_WAIT_SECONDS) until
# it gets fd 8 on $MERGE_LOCK_FILE (or $1, for lib.test.sh to point at a
# throwaway file instead) — fd 8 specifically so it can never collide with
# issue-pipeline.sh's own fd 9 tick-decision lock even if somehow held in
# the same process (they never are; different processes entirely, but a
# fixed, distinct fd per lock is the same discipline that lock already
# uses). Released explicitly by release_merge_lock() immediately after the
# merge API call — and released anyway, automatically, if the holding
# process dies before calling it, because closing an fd releases its flock;
# the OS does this on any process exit, `set -e` included, so there is no
# code path that can leak this lock forever the way a hand-rolled "touch a
# marker file" lock could.
MERGE_LOCK_WAIT_SECONDS=$((70 * 60))

acquire_merge_lock() {
  local lock_file="${1:-$MERGE_LOCK_FILE}" wait_seconds="${2:-$MERGE_LOCK_WAIT_SECONDS}"
  exec 8>"$lock_file"
  flock -w "$wait_seconds" 8
}

# Hands that work product tickets (held-ticket hands, PR owners) follow the implement lane: a cap of 0
# pauses them. Every automatic product-hand dispatcher calls this.
product_hands_paused() { [ "${AGENT_IMPLEMENT_CAP:-8}" = 0 ]; }

release_merge_lock() {
  flock -u 8 2>/dev/null || true
}

# GitNexus' index is shared by triage and advisor units. One dedicated checkout
# is indexed per AGENT_HOME, so keep both the mutex and refresh markers there.
# Refresh at most once per 30 minutes; analysis runs on cihost so WSL only needs
# the standing 3 GiB safety floor. Only the units that read
# the graph (triage/advisor) refresh it. The scheduler never drains implement
# or hand dispatch for it: on 2026-10-08 that drain paused implement 30 min
# per stale cycle while its own in-tick refresh failed every time.
GITNEXUS_REFRESH_LOCK_WAIT_SECONDS=20
GITNEXUS_REFRESH_MIN_INTERVAL_SECONDS=$((30 * 60))
TRIAGE_FRESHNESS_MAX_DEFER_SECONDS="${TRIAGE_FRESHNESS_MAX_DEFER_SECONDS:-$((2 * 60 * 60))}"

gitnexus_refresh_minimum_available_kb() {
  printf '%s\n' "$((3 * 1024 * 1024))"
}

gitnexus_cihost_index_refresh() {
  local helper="${GITNEXUS_CIHOST_INDEX_SCRIPT:-${BASH_SOURCE[0]%/*}/gitnexus-cihost-index.sh}"
  timeout 40m bash "$helper" refresh "$@"
}

gitnexus_available_memory_kb() {
  local key value unit
  while read -r key value unit; do
    if [ "$key" = "MemAvailable:" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  done < /proc/meminfo
  return 1
}

gitnexus_index_matches_origin_main() {
  local repo_dir="$1" origin_main_sha indexed indexed_at indexed_epoch now age commits_behind
  origin_main_sha="$(git -C "$repo_dir" rev-parse origin/main 2>/dev/null || echo unknown)"
  [[ "$origin_main_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  indexed="$(jq -r '.lastCommit // empty' "$repo_dir/.gitnexus/meta.json" 2>/dev/null)" || return 1
  [[ -n "$indexed" ]] && git -C "$repo_dir" merge-base --is-ancestor "$indexed" "$origin_main_sha" 2>/dev/null || return 1
  commits_behind="$(git -C "$repo_dir" rev-list --count "$indexed..$origin_main_sha" 2>/dev/null)" || return 1
  [[ "$commits_behind" =~ ^[0-9]+$ ]] && (( commits_behind <= 20 )) || return 1
  indexed_at="$(jq -r '.indexedAt // empty' "$repo_dir/.gitnexus/meta.json" 2>/dev/null)" || return 1
  indexed_epoch="$(agent_epoch -u "$indexed_at" 2>/dev/null)" || return 1
  now="$(date +%s 2>/dev/null)" || return 1
  age=$((now - indexed_epoch))
  (( age >= 0 )) || age=0
  (( age <= 3600 ))
}

gitnexus_product_lag() {
  local repo_dir="$1" now="${2:-$(date +%s)}" origin indexed count first_missed first_epoch age
  GITNEXUS_PRODUCT_LAG_COMMITS=unknown
  GITNEXUS_PRODUCT_LAG_HOURS=unknown
  GITNEXUS_PRODUCT_LAG_AGE_SECONDS=unknown
  GITNEXUS_PRODUCT_LAG_INDEXED_SHA=""
  GITNEXUS_PRODUCT_LAG_ORIGIN_SHA=""
  GITNEXUS_PRODUCT_LAG_FIRST_MISSED_SHA=""
  GITNEXUS_PRODUCT_LAG_FIRST_MISSED_EPOCH=""
  origin="$(git -C "$repo_dir" rev-parse --verify -q refs/remotes/origin/main 2>/dev/null)" || return 1
  indexed="$(jq -r '.lastCommit // empty' "$repo_dir/.gitnexus/meta.json" 2>/dev/null)" || return 1
  [ -n "$indexed" ] || return 1
  git -C "$repo_dir" merge-base --is-ancestor "$indexed" "$origin" 2>/dev/null || return 1
  GITNEXUS_PRODUCT_LAG_INDEXED_SHA="$indexed"
  GITNEXUS_PRODUCT_LAG_ORIGIN_SHA="$origin"
  if git -C "$repo_dir" diff --quiet "$indexed" "$origin" -- packages migrations; then
    GITNEXUS_PRODUCT_LAG_COMMITS=0
    GITNEXUS_PRODUCT_LAG_HOURS=0
    GITNEXUS_PRODUCT_LAG_AGE_SECONDS=0
    return 0
  fi
  count="$(git -C "$repo_dir" rev-list --count "$indexed..$origin" -- packages migrations 2>/dev/null)" || return 1
  first_missed="$(git -C "$repo_dir" log --reverse --format=%H "$indexed..$origin" -- packages migrations 2>/dev/null | sed -n '1p')" || return 1
  first_epoch="$(git -C "$repo_dir" show -s --format=%ct "$first_missed" 2>/dev/null)" || return 1
  [[ "$count" =~ ^[0-9]+$ && "$first_epoch" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || return 1
  age=$((now - first_epoch))
  (( age >= 0 )) || age=0
  GITNEXUS_PRODUCT_LAG_COMMITS="$count"
  GITNEXUS_PRODUCT_LAG_HOURS=$((age / 3600))
  GITNEXUS_PRODUCT_LAG_AGE_SECONDS="$age"
  GITNEXUS_PRODUCT_LAG_FIRST_MISSED_SHA="$first_missed"
  GITNEXUS_PRODUCT_LAG_FIRST_MISSED_EPOCH="$first_epoch"
}

# zcode-cli rewrites its argv to "zcode-cli" (2026-10-07), so zcode hand agents are found by
# the environment dispatch.sh gives them. Prints "<pid>\t<agent name>", one line per agent
# (its lowest PID), for agents whose ZF_REPO_DIR is under <worktree root>; optional <name>.
# ponytail: a codex agent running a command with "zcode" in its argv can be listed for a moment.
hand_zcode_agents() {
  local root="$1" name="${2:-}" pid
  for pid in $(pgrep -f zcode 2>/dev/null | sort -n); do
    tr '\0' '\n' 2>/dev/null < "/proc/$pid/environ" \
      | awk -v pid="$pid" -v root="$root" -v want="$name" -F= '
          $1 == "ZF_REPO_DIR" && index($0, "ZF_REPO_DIR=" root) == 1 { under = 1 }
          $1 == "ZF_AGENT_NAME" { agent = substr($0, 18) }
          END { if (under && agent != "" && (want == "" || agent == want)) print pid "\t" agent }'
    # A zcode launched without that environment is still known by its original argv.
    [ -n "$name" ] || tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline" \
      | awk -v pid="$pid" -v root="$root" '$0 ~ /zcode[^[:space:]]* -p / && index($0, "--cwd " root) > 0 { print pid "\tpid:" pid }'
  done | awk -F'\t' '!seen[$1]++ && !seen[$2]++'
}

hand_agent_process_count() {
  local worktree_root="${1:-${ZF_WORKTREE_ROOT:-$HOME/wt}/}" codex_count zcode_count
  local worktrees scope="${2:-all}" pid worktree production_rows production_worktrees="" unit_name
  local -a records
  worktrees="$(hand_codex_worktrees "$worktree_root")" || return 1
  if [ "$scope" = ordinary-hand ] || [ "$scope" = finishing ]; then
    if [ "$scope" = finishing ]; then
      printf '%s' "$production_worktrees" | awk 'NF && !seen[$0]++ {n++} END {print n+0}'
      return 0
    fi
    # Pipeline issue units have their own cap; production admission uses memory/load guards.
    worktrees="$(awk -v root="${worktree_root%/}/" '
      { name=substr($0,length(root)+1) }
      name !~ /^issue-[0-9]+$/ { print }' <<< "$worktrees")"
    records=("${ZF_NIGHT_DIR:-$AGENT_HOME/night}"/hand-registry/*.json)
    production_rows="$(jq -rs '
      .[] | select(.role == "production" and (.pid | type == "number") and (.worktree | type == "string"))
      | [.pid,.worktree] | @tsv' "${records[@]}" 2>/dev/null || true)"
    while IFS=$'\t' read -r pid worktree; do
      [ -n "$pid" ] || continue
      if hand_codex_pid_matches "$pid" "$worktree"; then
        production_worktrees+="$worktree"$'\n'
      fi
    done <<< "$production_rows"
    worktrees="$(awk 'FILENAME==ARGV[1] { if (NF) production[$0]=1; next } !($0 in production)' \
      <(printf '%s' "$production_worktrees") <(printf '%s\n' "$worktrees"))"
  fi
  codex_count="$(awk 'NF {n++} END {print n+0}' <<< "$worktrees")"
  zcode_count="$(hand_zcode_agents "$worktree_root" | wc -l)"
  echo $((codex_count + zcode_count))
}

# gitnexus_refresh_index_once <repo_dir> <expected_index_sha|target> <freshness_function>
# Returns success only when freshness is confirmed before or after refresh.
# GITNEXUS_REFRESH_OUTPUT carries analyzer/lock details for the existing
# non-fatal "NOT confirmed fresh" fallback at each caller.
gitnexus_refresh_index_once() {
  local repo_dir="$1" expected_sha="$2" freshness_function="$3" target_sha
  local lock_file="$AGENT_HOME/gitnexus-analyze.lock"
  local attempt_file="$AGENT_HOME/gitnexus-analyze-attempt"
  local throttle_file="$AGENT_HOME/gitnexus-analyze-last-start"
  local live_marker="$AGENT_HOME/gitnexus-analyze-guard-live-since"
  local memory_log="$AGENT_HOME/night/gitnexus-analyze-memory.tsv"
  local attempt_key lock_fd status=1 now available_kb previous_attempt previous_refresh
  local run_id sample_file sample_marker sampler_pid sampler_parent_pid sampler_status minimum_kb sample_kb wrapper_minimum_kb
  local analyzer_status ended_at freshness_checked_at indexed_at indexed_sha indexed_epoch index_age origin_main_sha commits_behind freshness_evidence
  local failure_detail failure_pair refresh_line
  GITNEXUS_REFRESH_OUTPUT=""

  if ! declare -F "$freshness_function" >/dev/null || [ -z "$expected_sha" ] || [ "$expected_sha" = "unknown" ]; then
    GITNEXUS_REFRESH_OUTPUT="checkout SHA or freshness check unavailable"
    return 1
  fi
  if ! mkdir -p "$AGENT_HOME" || ! exec {lock_fd}>"$lock_file"; then
    GITNEXUS_REFRESH_OUTPUT="could not open GitNexus refresh lock"
    return 1
  fi
  if ! flock -w "$GITNEXUS_REFRESH_LOCK_WAIT_SECONDS" "$lock_fd"; then
    GITNEXUS_REFRESH_OUTPUT="GitNexus refresh lock wait timed out after ${GITNEXUS_REFRESH_LOCK_WAIT_SECONDS}s"
    exec {lock_fd}>&-
    return 1
  fi

  if [ ! -s "$live_marker" ]; then
    date +%s > "$live_marker" 2>/dev/null || true
  fi

  # The origin-main path targets its remote ref; checkout HEAD may lag behind it.
  if [ "$freshness_function" = "gitnexus_index_matches_origin_main" ]; then
    target_sha="$(git -C "$repo_dir" rev-parse --verify refs/remotes/origin/main 2>/dev/null || echo unknown)"
  else
    target_sha="$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || echo unknown)"
  fi
  if [ "$target_sha" = "unknown" ]; then
    GITNEXUS_REFRESH_OUTPUT="checkout SHA unavailable"
  else
    attempt_key="$repo_dir $target_sha"
  fi

  if [ "$target_sha" = "unknown" ]; then
    :
  elif "$freshness_function" "$repo_dir" "$expected_sha"; then
    GITNEXUS_REFRESH_OUTPUT="index freshness already confirmed for $expected_sha"
    status=0
  else
    now="$(date +%s 2>/dev/null || true)"
    if ! [[ "$now" =~ ^[0-9]+$ ]]; then
      GITNEXUS_REFRESH_OUTPUT="clock unavailable; deferring GitNexus refresh"
    else
      previous_refresh="$(cat "$throttle_file" 2>/dev/null || true)"
      if [[ "$previous_refresh" =~ ^[0-9]+$ ]] \
        && (( now - previous_refresh < GITNEXUS_REFRESH_MIN_INTERVAL_SECONDS )); then
        GITNEXUS_REFRESH_OUTPUT="refresh deferred by latest-wins throttle (${GITNEXUS_REFRESH_MIN_INTERVAL_SECONDS}s)"
      else
        available_kb="$(gitnexus_available_memory_kb 2>/dev/null || true)"
        wrapper_minimum_kb="$(gitnexus_refresh_minimum_available_kb 2>/dev/null || true)"
        if ! [[ "$wrapper_minimum_kb" =~ ^[0-9]+$ ]]; then
          GITNEXUS_REFRESH_OUTPUT="WSL GitNexus refresh memory floor unavailable; deferring refresh"
        elif ! [[ "$available_kb" =~ ^[0-9]+$ ]]; then
          GITNEXUS_REFRESH_OUTPUT="MemAvailable unavailable; deferring GitNexus refresh"
        elif (( available_kb < wrapper_minimum_kb )); then
          GITNEXUS_REFRESH_OUTPUT="MemAvailable $((available_kb / 1024))MB < 3072MB; deferring remote GitNexus refresh"
        else
          previous_attempt="$(cat "$attempt_file" 2>/dev/null || true)"
          if ! mkdir -p "$AGENT_HOME/night"; then
            GITNEXUS_REFRESH_OUTPUT="could not open GitNexus memory log directory"
          elif ! sample_file="$(mktemp "$AGENT_HOME/night/gitnexus-analyze-min.XXXXXX" 2>/dev/null)"; then
            GITNEXUS_REFRESH_OUTPUT="could not record GitNexus memory sample"
          elif ! sample_marker="$(mktemp "$AGENT_HOME/night/gitnexus-analyze-running.XXXXXX" 2>/dev/null)"; then
            rm -f "$sample_file"
            GITNEXUS_REFRESH_OUTPUT="could not start GitNexus memory sample"
          elif ! printf '%s\n' "$attempt_key" > "$attempt_file"; then
            rm -f "$sample_file" "$sample_marker"
            GITNEXUS_REFRESH_OUTPUT="could not record GitNexus refresh attempt"
          elif ! printf '%s\n' "$now" > "$throttle_file"; then
            if [ -n "$previous_attempt" ]; then printf '%s\n' "$previous_attempt" > "$attempt_file"; else rm -f "$attempt_file"; fi
            rm -f "$sample_file" "$sample_marker"
            GITNEXUS_REFRESH_OUTPUT="could not record GitNexus refresh throttle"
          elif ! printf '%s\n' "$available_kb" > "$sample_file"; then
            if [ -n "$previous_attempt" ]; then printf '%s\n' "$previous_attempt" > "$attempt_file"; else rm -f "$attempt_file"; fi
            if [ -n "$previous_refresh" ]; then printf '%s\n' "$previous_refresh" > "$throttle_file"; else rm -f "$throttle_file"; fi
            rm -f "$sample_file" "$sample_marker"
            GITNEXUS_REFRESH_OUTPUT="could not record GitNexus memory baseline"
          else
            run_id="${BASHPID:-$$}-$now"
            if ! printf 'start\t%s\t%s\t%s\n' "$run_id" "$now" "$target_sha" >> "$memory_log"; then
              if [ -n "$previous_attempt" ]; then printf '%s\n' "$previous_attempt" > "$attempt_file"; else rm -f "$attempt_file"; fi
              if [ -n "$previous_refresh" ]; then printf '%s\n' "$previous_refresh" > "$throttle_file"; else rm -f "$throttle_file"; fi
              rm -f "$sample_file" "$sample_marker"
            GITNEXUS_REFRESH_OUTPUT="could not log GitNexus refresh start"
            else
              sampler_parent_pid="${BASHPID:-$$}"
              (
                minimum_kb="$available_kb"
                sample_write_failed=0
                while [ -e "$sample_marker" ] && kill -0 "$sampler_parent_pid" 2>/dev/null; do
                  sample_kb="$(gitnexus_available_memory_kb 2>/dev/null || true)"
                  if [[ "$sample_kb" =~ ^[0-9]+$ ]] && (( sample_kb < minimum_kb )); then
                    minimum_kb="$sample_kb"
                    if ! printf '%s\n' "$minimum_kb" > "$sample_file"; then sample_write_failed=1; fi
                  fi
                  sleep 1
                done
                printf '%s\n' "$minimum_kb" > "$sample_file" || sample_write_failed=1
                (( sample_write_failed == 0 ))
              ) &
              sampler_pid=$!

              if GITNEXUS_REFRESH_OUTPUT="$(gitnexus_cihost_index_refresh "$repo_dir" "$target_sha" 2>&1)"; then
                analyzer_status=0
              else
                analyzer_status=$?
              fi
              rm -f "$sample_marker"
              if wait "$sampler_pid"; then sampler_status=0; else sampler_status=$?; fi
              minimum_kb="$(cat "$sample_file" 2>/dev/null || echo "$available_kb")"
              rm -f "$sample_file"
              ended_at="$(date +%s 2>/dev/null || echo "$now")"
              failure_detail=none
              if [ "$analyzer_status" -ne 0 ]; then
                failure_detail=""
                while IFS= read -r refresh_line; do
                  if [[ "$refresh_line" =~ gitnexus-refresh[[:space:]]stage=([a-z0-9-]+)[[:space:]]exit=([0-9]+) ]]; then
                    failure_pair="stage=${BASH_REMATCH[1]} exit=${BASH_REMATCH[2]}"
                    failure_detail="${failure_detail:+$failure_detail; }$failure_pair"
                  fi
                done <<< "$GITNEXUS_REFRESH_OUTPUT"
                if [ -z "$failure_detail" ]; then
                  failure_detail="stage=remote-index-refresh exit=$analyzer_status"
                  GITNEXUS_REFRESH_OUTPUT="${GITNEXUS_REFRESH_OUTPUT:+$GITNEXUS_REFRESH_OUTPUT$'\n'}gitnexus-refresh stage=remote-index-refresh exit=$analyzer_status"
                fi
                GITNEXUS_REFRESH_OUTPUT="${GITNEXUS_REFRESH_OUTPUT:+$GITNEXUS_REFRESH_OUTPUT$'\n'}GitNexus refresh failure: $failure_detail"
              fi
              printf 'run\t%s\t%s\t%s\t%s\t%s\t%s\t%s\trefresh-audit-v1\t%s\n' \
                "$run_id" "$ended_at" "$target_sha" "$available_kb" "$minimum_kb" \
                "$analyzer_status" "$sampler_status" "$failure_detail" >> "$memory_log" || true

              if [ "$sampler_status" -ne 0 ]; then
                GITNEXUS_REFRESH_OUTPUT="${GITNEXUS_REFRESH_OUTPUT:+$GITNEXUS_REFRESH_OUTPUT; }WSL MemAvailable sample did not cover the full refresh"
              elif ! [[ "$minimum_kb" =~ ^[0-9]+$ ]] || (( minimum_kb < wrapper_minimum_kb )); then
                GITNEXUS_REFRESH_OUTPUT="${GITNEXUS_REFRESH_OUTPUT:+$GITNEXUS_REFRESH_OUTPUT; }WSL MemAvailable fell below 3072MB during refresh"
              elif [ "$analyzer_status" -eq 0 ] && "$freshness_function" "$repo_dir" "$expected_sha"; then
                freshness_checked_at="$(date +%s 2>/dev/null || echo "$ended_at")"
                [[ "$freshness_checked_at" =~ ^[0-9]+$ ]] || freshness_checked_at="$ended_at"
                indexed_at="$(jq -r '.indexedAt // empty' "$repo_dir/.gitnexus/meta.json" 2>/dev/null || true)"
                indexed_sha="$(jq -r '.lastCommit // empty' "$repo_dir/.gitnexus/meta.json" 2>/dev/null || true)"
                indexed_epoch="$(agent_epoch -u "$indexed_at" 2>/dev/null || true)"
                index_age=unknown
                if [[ "$indexed_epoch" =~ ^[0-9]+$ ]]; then
                  index_age=$((freshness_checked_at - indexed_epoch))
                  (( index_age >= 0 )) || index_age=0
                fi
                origin_main_sha="$(git -C "$repo_dir" rev-parse --verify -q refs/remotes/origin/main 2>/dev/null || echo unknown)"
                commits_behind=unknown
                if [[ "$indexed_sha" =~ ^[0-9a-f]{40}$ && "$origin_main_sha" =~ ^[0-9a-f]{40}$ ]] \
                  && git -C "$repo_dir" merge-base --is-ancestor "$indexed_sha" "$origin_main_sha" 2>/dev/null; then
                  commits_behind="$(git -C "$repo_dir" rev-list --count "$indexed_sha..$origin_main_sha" 2>/dev/null || echo unknown)"
                  [[ "$commits_behind" =~ ^[0-9]+$ ]] || commits_behind=unknown
                fi
                freshness_evidence=0
                if { [[ "$index_age" =~ ^[0-9]+$ ]] && (( index_age <= 3600 )); } \
                  || { [[ "$commits_behind" =~ ^[0-9]+$ ]] && (( commits_behind <= 20 )); }; then
                  freshness_evidence=1
                fi
                if (( freshness_evidence == 1 )); then
                  status=0
                  printf 'confirmed\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "$run_id" "$freshness_checked_at" "$expected_sha" "$indexed_at" "$indexed_sha" \
                    "$index_age" "$commits_behind" "$origin_main_sha" >> "$memory_log" || true
                else
                  GITNEXUS_REFRESH_OUTPUT="${GITNEXUS_REFRESH_OUTPUT:+$GITNEXUS_REFRESH_OUTPUT; }refreshed index freshness metadata could not be recorded"
                fi
              elif [ -z "$GITNEXUS_REFRESH_OUTPUT" ]; then
                GITNEXUS_REFRESH_OUTPUT="remote refresh completed but index freshness was not confirmed"
              fi
            fi
          fi
        fi
      fi
    fi
  fi

  flock -u "$lock_fd" 2>/dev/null || true
  exec {lock_fd}>&-
  return "$status"
}

# gitnexus_refresh_health_detail <memory_log> <now_epoch>
# Keep refresh freshness visible in HEALTH without turning a stale index
# into a page. Legacy run rows predate explicit confirmation records.
gitnexus_refresh_health_detail() {
  local memory_log="$1" now="$2" detail status=0 minimum_kb
  if ! [[ "$now" =~ ^[0-9]+$ ]]; then
    now="$(date +%s)"
  fi
  minimum_kb="$(gitnexus_refresh_minimum_available_kb)"
  if [ ! -r "$memory_log" ]; then
    printf 'last-confirmed-age-sec=unknown last-refresh-exit=unknown refresh-samples=0/20 refresh-successes=0 refresh-rate=unknown refresh-target=95%% refresh-memory-floor-violations=0\n'
    return 0
  fi
  if detail="$(awk -F '\t' -v now="$now" -v floor="$minimum_kb" '
    # Only tagged rows carry the per-refresh metadata required by this audit.
    $1 == "run" {
      if ($7 ~ /^[0-9]+$/) last_exit = $7
      if ($7 == 0 && $3 ~ /^[0-9]+$/) legacy_confirmed = $3
      if ($9 == "refresh-audit-v1") {
        attempts++
        ids[attempts] = $2
        run_exit[$2] = $7
        min_available[$2] = $6
        sampler_exit[$2] = $8
      }
    }
    $1 == "confirmed" && $3 ~ /^[0-9]+$/ {
      confirmed = $3
      if ($7 ~ /^[0-9]+$/) confirmed_age[$2] = $7
      if ($8 ~ /^[0-9]+$/) confirmed_behind[$2] = $8
      confirmed_ids[$2] = 1
    }
    END {
      refreshed = confirmed
      if (refreshed == "") refreshed = legacy_confirmed
      if (refreshed ~ /^[0-9]+$/) {
        age = now - refreshed
        if (age < 0) age = 0
      } else {
        age = "unknown"
      }
      if (last_exit == "") last_exit = "unknown"
      first = attempts - 19
      if (first < 1) first = 1
      samples = attempts - first + 1
      for (i = first; i <= attempts; i++) {
        id = ids[i]
        if (sampler_exit[id] != "0" || min_available[id] !~ /^[0-9]+$/ || min_available[id] < floor) memory_violations++
        fresh = (confirmed_age[id] ~ /^[0-9]+$/ && confirmed_age[id] <= 3600) \
          || (confirmed_behind[id] ~ /^[0-9]+$/ && confirmed_behind[id] <= 20)
        if (run_exit[id] == 0 && sampler_exit[id] == 0 \
          && min_available[id] ~ /^[0-9]+$/ && min_available[id] >= floor \
          && confirmed_ids[id] && fresh) successes++
      }
      rate = "unknown"
      if (samples >= 20) rate = int(successes * 100 / samples) "%"
      printf "last-confirmed-age-sec=%s last-refresh-exit=%s refresh-samples=%d/20 refresh-successes=%d refresh-rate=%s refresh-target=95%% refresh-memory-floor-violations=%d\n", age, last_exit, samples, successes, rate, memory_violations
      if (memory_violations > 0 || (samples >= 20 && successes * 100 < samples * 95)) exit 1
    }
  ' "$memory_log")"; then
    :
  else
    status=$?
  fi
  printf '%s' "$detail"
  return "$status"
}

# gitnexus_index_health <repo_dir> <memory_log> <now_epoch>
# A missing or unverifiable index stays UNKNOWN; stale indexed data stays visible to HEALTH.
gitnexus_index_health() {
  local repo_dir="$1" memory_log="$2" now="$3" indexed_at indexed_epoch indexed origin age behind failure_codes refresh_detail
  local refresh_quality_status=0
  GITNEXUS_INDEX_HEALTH_STATE=UNKNOWN
  GITNEXUS_INDEX_HEALTH_DETAIL="index-age-sec=unknown commits-behind=unknown refresh-failure-streak=unknown"
  [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s 2>/dev/null || true)"
  [[ "$now" =~ ^[0-9]+$ ]] || return 0
  if refresh_detail="$(gitnexus_refresh_health_detail "$memory_log" "$now")"; then
    :
  else
    refresh_quality_status=$?
  fi
  failure_codes="$(gitnexus_recent_analyze_failure_codes "$memory_log" 2>/dev/null || true)"
  if [[ -n "$failure_codes" ]]; then
    GITNEXUS_INDEX_HEALTH_STATE=BROKEN
    GITNEXUS_INDEX_HEALTH_DETAIL="index-age-sec=unknown commits-behind=unknown refresh-failure-streak=3+ exit-codes=$failure_codes $refresh_detail"
  elif (( refresh_quality_status != 0 )); then
    GITNEXUS_INDEX_HEALTH_STATE=BROKEN
    GITNEXUS_INDEX_HEALTH_DETAIL="index-age-sec=unknown commits-behind=unknown refresh-failure-streak=below-3 refresh-quality=below-target-or-memory-floor $refresh_detail"
  else
    GITNEXUS_INDEX_HEALTH_DETAIL="index-age-sec=unknown commits-behind=unknown refresh-failure-streak=below-3 $refresh_detail"
  fi
  indexed_at="$(jq -r '.indexedAt // empty' "$repo_dir/.gitnexus/meta.json" 2>/dev/null)" || return 0
  indexed="$(jq -r '.lastCommit // empty' "$repo_dir/.gitnexus/meta.json" 2>/dev/null)" || return 0
  origin="$(git -C "$repo_dir" rev-parse --verify -q refs/remotes/origin/main 2>/dev/null)" || return 0
  [[ -n "$indexed" ]] && git -C "$repo_dir" merge-base --is-ancestor "$indexed" "$origin" 2>/dev/null || return 0
  indexed_epoch="$(agent_epoch -u "$indexed_at" 2>/dev/null)" || return 0
  behind="$(git -C "$repo_dir" rev-list --count "$indexed..$origin" 2>/dev/null)" || return 0
  [[ "$behind" =~ ^[0-9]+$ ]] || return 0
  age=$((now - indexed_epoch))
  (( age >= 0 )) || age=0
  GITNEXUS_INDEX_HEALTH_STATE=OK
  GITNEXUS_INDEX_HEALTH_DETAIL="index-age-sec=$age commits-behind=$behind refresh-failure-streak=below-3 $refresh_detail"
  if [[ -n "$failure_codes" ]]; then
    GITNEXUS_INDEX_HEALTH_STATE=BROKEN
    GITNEXUS_INDEX_HEALTH_DETAIL="index-age-sec=$age commits-behind=$behind refresh-failure-streak=3+ exit-codes=$failure_codes $refresh_detail"
  elif (( refresh_quality_status != 0 )); then
    GITNEXUS_INDEX_HEALTH_STATE=BROKEN
    GITNEXUS_INDEX_HEALTH_DETAIL="index-age-sec=$age commits-behind=$behind refresh-failure-streak=below-3 refresh-quality=below-target-or-memory-floor $refresh_detail"
  elif (( age > 7200 || behind > 50 )); then
    GITNEXUS_INDEX_HEALTH_STATE=STUCK
  fi
}

# rebase_agent_pr_onto_main <head_ref> <base_sha>
#
# `main` moves fast enough that agent PRs go CONFLICTING before anyone
# fixes them (#1287 was rebased by hand and went CONFLICTING again within
# the hour) -- this is the unattended sweeper's only automatic write onto
# a PR branch, so it is deliberately narrow: attempt a rebase onto current
# origin/main in a scratch worktree that touches neither $REPO_DIR's own
# checkout nor any worktree a live implement/triage/release leg might be
# using ($HOME/wt/issue-<n>, ensure_worktree()'s own convention in
# run-implement.sh -- a distinct mktemp path never collides with it), and
# NEVER runs `git rebase --continue`/resolves anything: a real content
# conflict aborts the rebase immediately and this returns 1, unresolved,
# for the caller to log and leave exactly like any other refusal. Includes
# lessons/RULES.md's own append-only tail -- deliberately NOT special-
# cased. A clever auto-union-merge for "both sides only appended" risks
# silently dropping one side's lesson entry; refusing and leaving it for a
# human/the next attended attempt is the same "prefer refusing to
# guessing" discipline this whole gate follows, not an oversight.
#
# Pushes with --force-with-lease pinned to $base_sha (the exact tip the
# caller last observed) so a push landing between the caller's read and
# this call is refused by git itself, not silently overwritten -- on top
# of the grace-period check every sweep already applies before it gets
# this far.
#
# Return: 0 rebased and pushed (a NEW head SHA -- CI has to run again on
# it, so the caller must not attempt a merge this tick); 1 a real conflict
# (left alone, unresolved); 2 an infra/git failure (fetch/worktree/push),
# same "leave it, try again next tick" shape as any other transient
# failure in this file.
rebase_agent_pr_onto_main() {
  local head_ref="$1" base_sha="$2" scratch
  scratch="$(mktemp -d)"
  if ! git_fetch_bounded "$REPO_DIR" main "$head_ref" \
    || ! git -C "$REPO_DIR" worktree add -q --detach "$scratch" "origin/$head_ref" 2>/dev/null; then
    worktree_lifecycle_finish "$scratch" "$REPO_DIR" || true
    rmdir "$scratch" 2>/dev/null || true
    return 2
  fi
  git -C "$scratch" config user.name "${ZF_AGENT_GIT_USER_NAME:-zenoforge-agent}"
  git -C "$scratch" config user.email "${ZF_AGENT_GIT_USER_EMAIL:-zenoforge-agent@users.noreply.github.com}"

  local result=0
  if git -C "$scratch" rebase origin/main >/dev/null 2>&1; then
    if ! ZF_PUSH_GUARD_OVERRIDE_REASON=conflict-sweeper-conflicting-pr guarded_write git -C "$scratch" push origin \
      "HEAD:refs/heads/$head_ref" "--force-with-lease=refs/heads/$head_ref:$base_sha"; then
      result=2
    fi
  else
    git -C "$scratch" rebase --abort >/dev/null 2>&1 || true
    result=1
  fi

  worktree_lifecycle_finish "$scratch" "$REPO_DIR" || result=2
  return "$result"
}

# merge_agent_pr <issue> <pr> <match-head-commit> [unattended] [grace-seconds] [log]
#
# The one merge path shared by a live implement run and the orphan-PR
# sweeper. It owns the optimistic main gate (main_merge_clear: no completed
# red, no wait for a green tip -- #4356), the ready-for-review transition
# (every pipeline PR opens as a draft; GitHub refuses to merge one), the
# explicit squash subject/body, and the GitHub-side head guard. For an
# unattended rescue it also rechecks the PR's mergeability, required
# checks, and implement-unit liveness before the merge, so the sweeper never
# relies on a stale scan made before another tick or run changed the state.
# The lock-time head is pinned through guarded_pr_merge(), and persisted READY
# review evidence must name that same head before the PR is marked ready.
#
# Sets MERGE_GATE_FAILURE_KIND and MERGE_GATE_FAILURE_REASON on refusal. The
# caller decides whether that refusal is a normal retry (the sweeper) or the
# implement leg's existing escalation path; this function never parks an
# issue or changes its labels.
merge_agent_pr() {
  local n="$1" pr_number="$2" match_head_commit="$3" unattended="${4:-0}"
  local grace_seconds="${5:-0}" merge_wait_log="${6:-$LOG_DIR/merge-wait-$n.log}"
  local merge_subject merge_body
  local fix_forward=0 fix_forward_reason="" fix_forward_expected_head=""
  local current_pr_json current_checks current_checks_outcome review_state review_verdict reviewed_head_sha
  local expected_packages_json changed_path
  local risk_class_hits_json risk_class_admitted required_test_paths_json required_path

  MERGE_GATE_FAILURE_KIND=""
  MERGE_GATE_FAILURE_REASON=""
  MERGE_GATE_FAILURE_HEAD=""

  if [ "$unattended" = "1" ] && stage_unit_active implement "$n"; then
    MERGE_GATE_FAILURE_KIND="active"
    MERGE_GATE_FAILURE_REASON="the implement unit is still active"
    return 1
  fi

  # Optimistic merge gate (#4356): merging needs no completed red
  # Postsubmit on main, checked once, with no CI wait and no lock held. A
  # pending tip does not close the gate; a completed red blocks ordinary PRs
  # until a later green verdict. The matching main-red revert has its own
  # guarded path. The fix-forward path stays the one sanctioned exception
  # (2026-10-26 ruling): main_merge_clear() leaves the red run in
  # MAIN_RELEASE_RUN_JSON for main_fix_forward_prepare_for_pr() to assess.
  if main_merge_clear 2>"$merge_wait_log"; then
    :
  elif main_fix_forward_prepare_for_pr "$pr_number"; then
    fix_forward=1
    fix_forward_reason="$MAIN_FIX_FORWARD_REASON"
  else
    MERGE_GATE_FAILURE_KIND="main"
    MERGE_GATE_FAILURE_REASON="main has a red Postsubmit verdict: ${MAIN_MERGE_CLEAR_REASON}; fix-forward refused: ${MAIN_FIX_FORWARD_REASON}"
    return 1
  fi

  if [ "$unattended" = "1" ]; then
    if ! current_pr_json="$(gh pr view "$pr_number" --repo "$REPO" \
      --json mergeable,mergeStateStatus,updatedAt,files,isDraft,headRefOid 2>/dev/null)"; then
      MERGE_GATE_FAILURE_KIND="pr-state"
      MERGE_GATE_FAILURE_REASON="could not re-read the PR's mergeability"
      return 1
    fi
    MERGE_GATE_FAILURE_HEAD="$(echo "$current_pr_json" | jq -r '.headRefOid // empty' 2>/dev/null)" || MERGE_GATE_FAILURE_HEAD=""
    if [[ ! "$MERGE_GATE_FAILURE_HEAD" =~ ^[0-9a-f]{40}$ ]] \
      || { [[ -n "$match_head_commit" ]] && [ "$MERGE_GATE_FAILURE_HEAD" != "$match_head_commit" ]; }; then
      MERGE_GATE_FAILURE_KIND="pr-state"
      MERGE_GATE_FAILURE_REASON="the PR head changed since it was last observed"
      return 1
    fi
    match_head_commit="$MERGE_GATE_FAILURE_HEAD"
    if [[ "$fix_forward" == 1 && "$fix_forward_reason" == carried-hotpatch:* ]]; then
      fix_forward_expected_head="$(jq -r '.headRefOid // empty' <<< "$MAIN_FIX_FORWARD_PR_JSON")"
      if [[ ! "$fix_forward_expected_head" =~ ^[0-9a-f]{40}$ ]] \
        || [ "$MERGE_GATE_FAILURE_HEAD" != "$fix_forward_expected_head" ] \
        || { [[ -n "$match_head_commit" ]] && [ "$match_head_commit" != "$fix_forward_expected_head" ]; }; then
        MERGE_GATE_FAILURE_KIND="pr-state"
        MERGE_GATE_FAILURE_REASON="the PR head changed before carried-hotpatch merge validation"
        return 1
      fi
      match_head_commit="$fix_forward_expected_head"
    fi
    if [ "$grace_seconds" -gt 0 ] && ! pr_untouched_for_grace \
      "$(echo "$current_pr_json" | jq -r '.updatedAt // empty')" "$grace_seconds"; then
      MERGE_GATE_FAILURE_KIND="recent"
      MERGE_GATE_FAILURE_REASON="the PR was touched during the merge wait and no longer satisfies the grace period"
      return 1
    fi
    if ! pr_mergeability_is_safe "$current_pr_json"; then
      MERGE_GATE_FAILURE_KIND="pr-state"
      MERGE_GATE_FAILURE_REASON="the PR no longer reports a conflict-free mergeable state"
      return 1
    fi

    if ! current_checks="$(gh pr checks "$pr_number" --repo "$REPO" \
      --json name,bucket,link 2>/dev/null)"; then
      MERGE_GATE_FAILURE_KIND="checks"
      MERGE_GATE_FAILURE_REASON="could not re-read the PR's required checks"
      return 1
    fi
    current_checks_outcome="$(pr_checks_outcome "$current_checks")"
    if [ "$current_checks_outcome" != "pass" ]; then
      if [[ "$fix_forward" != 1 || "$fix_forward_reason" != carried-hotpatch:* ]] \
        || ! main_fix_forward_carried_checks_still_valid "$pr_number" "$current_checks" "$MERGE_GATE_FAILURE_HEAD"; then
        MERGE_GATE_FAILURE_KIND="checks"
        MERGE_GATE_FAILURE_REASON="the PR's required checks are $current_checks_outcome"
        return 1
      fi
    fi

    if stage_unit_active implement "$n"; then
      MERGE_GATE_FAILURE_KIND="active"
      MERGE_GATE_FAILURE_REASON="the implement unit became active before merge"
      return 1
    fi

    # Gate 2 (risk-class.mjs re-check, run-implement.sh's own name for
    # it), re-checked here for the rescue path only -- same reasoning as
    # gate 4 just below: an attended call already ran this in run-
    # implement.sh's own gated auto-merge section BEFORE ever reaching
    # this function, so re-running it here unconditionally would double-
    # check every ordinary merge for nothing. An unattended call has no
    # such prior check.
    #
    # lessons/RULES.md V117 / orphan-pr-sweeper-missing-ready-for-review-
    # step's own residual note, item (b) (2026-09-16): this gate did not
    # exist at all in the unattended branch before today -- a PR the
    # attended path would refuse to merge on a P2/L4 hit, the sweeper
    # merged unconditionally. Same classification, same shared source
    # (risk_class_hits_for_paths(), above -- risk-class.mjs's own
    # classifyWithKind()), but a NARROWER admission than run-implement.sh's
    # own guarded_risk_class_admissible(): this branch can confirm
    # required_test_paths are present in the diff (a pure path check), but
    # it has no access to the reviewer's own report text
    # (REVIEW_REPORT_MD is a run-implement.sh in-memory variable, never
    # persisted to state), so it cannot verify a touched .sql file's
    # flagged statements were reviewer-justified the way that function's
    # own SQL branch does. Any .sql path in the diff is therefore treated
    # as unverifiable and refused here, same discipline that function
    # already applies when `git show` itself fails to read a file's
    # content: can't verify it, don't admit it. ponytail: narrower
    # unattended admission than the attended gate; widen this if
    # REVIEW_REPORT_MD (or an equivalent SQL-justification record) is ever
    # persisted to state.
    risk_class_hits_json="$(risk_class_hits_for_paths "$(echo "$current_pr_json" | jq -r '.files[].path')")"
    if [ "$(echo "$risk_class_hits_json" | jq 'length')" -gt 0 ]; then
      risk_class_admitted=0
      if state_is_guarded "$n" \
        && ! echo "$current_pr_json" | jq -r '.files[].path' | grep -qE '\.sql$'; then
        required_test_paths_json="$(state_read "$n" | jq -c '.required_test_paths // []')"
        if [ "$(echo "$required_test_paths_json" | jq 'length')" -gt 0 ]; then
          risk_class_admitted=1
          while IFS= read -r required_path; do
            [ -z "$required_path" ] && continue
            echo "$current_pr_json" | jq -r '.files[].path' | grep -qxF -- "$required_path" \
              || { risk_class_admitted=0; break; }
          done < <(echo "$required_test_paths_json" | jq -r '.[]')
        fi
      fi
      if [ "$risk_class_admitted" -eq 1 ]; then
        echo "merge-sweeper: guarded risk-class hit(s) admitted to merge for issue #$n (no .sql touched; required_test_paths present)" >&2
      else
        MERGE_GATE_FAILURE_KIND="risk-class"
        MERGE_GATE_FAILURE_REASON="the diff still touches a P2/L4 path: $(echo "$risk_class_hits_json" | jq -c '.')"
        return 1
      fi
    fi

    # Gate 4 (run-implement.sh's own name for it), re-checked here for the
    # rescue path only. An attended call (unattended=0, the live implement
    # leg) already ran path_in_expected_packages() over its own local diff
    # BEFORE ever reaching this function -- see run-implement.sh's gated
    # auto-merge section -- so re-running it here unconditionally would
    # double-check every ordinary merge for nothing. An unattended call has
    # no such prior check: it is picking up a diff nobody in this process
    # ever looked at, from a run that may have died before it reached its
    # own gate 4, or that pushed a repair commit after gate 4 last ran (see
    # run-implement.sh's "a change made during the repair pass" comment on
    # its own merge-time risk-class recheck -- the same drift window applies
    # here). Reads expected_packages from the issue's own state file (the
    # same field run-implement.sh's $EXPECTED_PACKAGES_JSON reads) and the
    # PR's current file list from the same current_pr_json already fetched
    # above -- no worktree, no second `gh pr view` call.
    #
    # A missing or empty expected_packages ([] -- state_read()'s own
    # default when the file doesn't exist, same as an explicit empty array)
    # is not treated as "nothing to check": path_in_expected_packages()
    # already returns false for every path against an empty array, so this
    # falls through to the same refusal as a real out-of-scope file, logged
    # exactly like one. That is deliberate, not a missing case: an
    # unattended merge with no declared scope to verify against is exactly
    # what gate 4 exists to refuse, and refusing it here (logged every tick
    # by the merge caller, same as every other refusal reason it
    # already produces) is what keeps it from ever landing unverified,
    # without inventing a second silent-park failure mode of its own.
    expected_packages_json="$(state_read "$n" | jq -c '.expected_packages // []')"
    while IFS= read -r changed_path; do
      [ -z "$changed_path" ] && continue
      if ! path_in_expected_packages "$expected_packages_json" "$changed_path"; then
        MERGE_GATE_FAILURE_KIND="blast-radius"
        MERGE_GATE_FAILURE_REASON="diff touches $changed_path, outside expected_packages $expected_packages_json"
        return 1
      fi
    done < <(echo "$current_pr_json" | jq -r '.files[].path')
  fi

  if [ "$fix_forward" = "1" ] && [ "$unattended" != "1" ]; then
    current_pr_json="$MAIN_FIX_FORWARD_PR_JSON"
    current_checks="$MAIN_FIX_FORWARD_CHECKS"
    MERGE_GATE_FAILURE_HEAD="$(jq -r '.headRefOid // empty' <<< "$current_pr_json")"
    if [[ ! "$match_head_commit" =~ ^[0-9a-f]{40}$ ]] \
      || [ "$MERGE_GATE_FAILURE_HEAD" != "$match_head_commit" ]; then
      MERGE_GATE_FAILURE_KIND="pr-state"
      MERGE_GATE_FAILURE_REASON="the PR head changed during the fix-forward wait"
      return 1
    fi
    if ! pr_mergeability_is_safe "$current_pr_json"; then
      MERGE_GATE_FAILURE_KIND="pr-state"
      MERGE_GATE_FAILURE_REASON="the PR no longer reports a conflict-free mergeable state"
      return 1
    fi
    current_checks_outcome="$(pr_checks_outcome "$current_checks")"
    if [ "$current_checks_outcome" != "pass" ]; then
      if [[ "$fix_forward_reason" != carried-hotpatch:* ]] \
        || ! main_fix_forward_carried_checks_still_valid "$pr_number" "$current_checks" \
          "$(jq -r '.headRefOid // empty' <<< "$current_pr_json")"; then
        MERGE_GATE_FAILURE_KIND="checks"
        MERGE_GATE_FAILURE_REASON="the PR's required checks are $current_checks_outcome"
        return 1
      fi
    fi
  fi

  # 2026-09-16 fix: is_on_hold() was checked at SCHEDULING time (issue-
  # pipeline.sh's own candidate loops) but never here, at the action itself
  # -- this is the ONE merge path shared by the live implement leg and the
  # unattended orphan-PR sweeper, and neither caller checked it either. A
  # human can put a ticket on-hold at any point during this function's own
  # gate reads or during the sweeper's own polling interval between ticks --
  # checked as late as possible, right before the first real mutation below,
  # so a hold applied mid-gate still catches it. Fails closed the same
  # direction is_on_hold()'s own callers already do: unknown (a failed read)
  # reads as on-hold, not as clear.
  #
  if issue_on_hold_live "$n"; then
    MERGE_GATE_FAILURE_KIND="on-hold"
    MERGE_GATE_FAILURE_REASON="#$n is on-hold -- refusing to merge"
    return 1
  fi

  if [ "$unattended" = "1" ]; then
    # The orphan sweeper has no in-memory reviewer result; require the
    # persisted fixed-SHA verdict to match the exact head pinned for merge.
    review_state="$(state_read "$n" 2>/dev/null)" || review_state=""
    review_verdict="$(jq -r '.run.evidence.review_verdict // empty' <<< "$review_state" 2>/dev/null)" || review_verdict=""
    reviewed_head_sha="$(jq -r '.run.evidence.reviewed_head_sha // empty' <<< "$review_state" 2>/dev/null)" || reviewed_head_sha=""
    if [ "$review_verdict" != "READY" ] || [ "$reviewed_head_sha" != "$MERGE_GATE_FAILURE_HEAD" ]; then
      MERGE_GATE_FAILURE_KIND="review"
      MERGE_GATE_FAILURE_REASON="the stored product review is not READY for the exact PR head"
      return 1
    fi
  fi

  # Defect (2026-09-15, live): `gh pr ready` used to exist in exactly ONE
  # place in the whole pipeline -- run-implement.sh's own happy path (its
  # early "checks just went green" comment block) -- so this function,
  # the ONE merge path shared by that live leg and the orphan-PR sweeper,
  # could reach guarded_pr_merge() below on a still-draft PR whenever it
  # was called from the sweeper (which never goes through run-implement.sh
  # at all). GitHub then refused the merge outright: "GraphQL: Pull
  # Request is still a draft (mergePullRequest)". Reproduced live against
  # #1298/#1286, both sitting MERGEABLE/CLEAN with every required check
  # green. Moving the call here means no caller of merge_agent_pr() -- the
  # attended implement leg or the unattended sweeper -- can reach the
  # merge below without it.
  #
  # Idempotent, verified live 2026-09-15 against #1298: a second `gh pr
  # ready` on an already-ready PR exits 0 and prints "already ready for
  # review" rather than erring, so calling it here unconditionally is
  # harmless even though run-implement.sh's own earlier call (still
  # present, see its comment) already did it for the attended path by the
  # time execution reaches here.
  if [ "$DRY_RUN" = "1" ] && [ "$unattended" = "1" ] \
    && [ "$(echo "$current_pr_json" | jq -r '.isDraft // false' 2>/dev/null)" = "true" ]; then
    # Not a faithful prediction: a real run's `gh pr ready` right below
    # would actually clear draft status before the merge attempted further
    # down, but AGENT_DRY_RUN=1 performs no real writes, so it cannot know
    # whether that write would succeed -- the exact blind spot that let
    # this defect ship invisibly (the old dry-run path never even printed
    # this step, because it didn't exist yet). Said explicitly here so
    # nobody reads the "[dry-run] gh pr merge ..." line two below as a
    # guarantee.
    echo "[dry-run] PR #$pr_number is currently draft -- the gh pr ready call below is assumed to succeed; dry-run does not verify it" >&2
  fi
  guarded_write gh pr ready "$pr_number" --repo "$REPO"

  if ! merge_subject="$(gh pr view "$pr_number" --repo "$REPO" --json title -q .title | scrub_closing_keywords)"; then
    MERGE_GATE_FAILURE_KIND="merge"
    MERGE_GATE_FAILURE_REASON="could not read the PR title for the squash merge"
    return 1
  fi
  merge_body="Ref #$n — not a GitHub closing keyword on purpose: an issue closes only after recorded production verification, never on merge."
  if [ "$fix_forward" = "1" ]; then
    if main_merge_clear 2>>"$merge_wait_log"; then
      if [[ "$fix_forward_reason" == carried-hotpatch:* ]] && [[ "$(pr_checks_outcome "$current_checks")" != pass ]]; then
        MERGE_GATE_FAILURE_KIND="checks"
        MERGE_GATE_FAILURE_REASON="main recovered, but the carried PR's Touched packages check is still failed"
        return 1
      fi
      fix_forward=0
    elif ! main_fix_forward_prepare_for_pr "$pr_number"; then
      MERGE_GATE_FAILURE_KIND="main"
      MERGE_GATE_FAILURE_REASON="$MAIN_FIX_FORWARD_REASON"
      return 1
    else
      fix_forward_reason="$MAIN_FIX_FORWARD_REASON"
      fix_forward_expected_head="$match_head_commit"
      [ -n "$fix_forward_expected_head" ] || fix_forward_expected_head="$MERGE_GATE_FAILURE_HEAD"
      if [ "$(jq -r '.headRefOid // empty' <<< "$MAIN_FIX_FORWARD_PR_JSON")" != "$fix_forward_expected_head" ] \
        || ! pr_mergeability_is_safe "$MAIN_FIX_FORWARD_PR_JSON"; then
        MERGE_GATE_FAILURE_KIND="pr-state"
        MERGE_GATE_FAILURE_REASON="the PR head or mergeability changed during fix-forward validation"
        return 1
      fi
      if [ "$unattended" = "1" ] && [ "$grace_seconds" -gt 0 ] \
        && ! pr_untouched_for_grace \
          "$(jq -r '.updatedAt // empty' <<< "$MAIN_FIX_FORWARD_PR_JSON")" "$grace_seconds"; then
        MERGE_GATE_FAILURE_KIND="recent"
        MERGE_GATE_FAILURE_REASON="the PR was touched during the merge wait and no longer satisfies the grace period"
        return 1
      fi
      if [ "$unattended" = "1" ] && stage_unit_active implement "$n"; then
        MERGE_GATE_FAILURE_KIND="active"
        MERGE_GATE_FAILURE_REASON="the implement unit became active before merge"
        return 1
      fi
      if issue_on_hold_live "$n"; then
        MERGE_GATE_FAILURE_KIND="on-hold"
        MERGE_GATE_FAILURE_REASON="#$n is on-hold -- refusing to merge"
        return 1
      fi
      if [ "$DRY_RUN" != "1" ] \
        && ! main_fix_forward_reserve "$MAIN_FIX_FORWARD_RUN_ID" "$MAIN_FIX_FORWARD_MAIN_SHA" "$pr_number"; then
        MERGE_GATE_FAILURE_KIND="main"
        MERGE_GATE_FAILURE_REASON="could not reserve the single fix-forward merge for this main run"
        return 1
      fi
    fi
  fi
  if ! guarded_pr_merge "$pr_number" "$merge_subject" "$merge_body" "$match_head_commit"; then
    if [ "${PR_MERGE_LOCK_FAILED:-0}" = "1" ]; then
      MERGE_GATE_FAILURE_KIND="lock"
      MERGE_GATE_FAILURE_REASON="could not acquire the merge lock within $((MERGE_LOCK_WAIT_SECONDS / 60)) minutes"
    else
      MERGE_GATE_FAILURE_KIND="merge"
      MERGE_GATE_FAILURE_REASON="the shared GitHub merge operation refused the PR"
    fi
    return 1
  fi

  if [ "$fix_forward" = "1" ]; then
    printf '%s\n' "$fix_forward_reason" >> "$merge_wait_log" 2>/dev/null || true
    if [ "$DRY_RUN" != "1" ] \
      && ! guarded_write gh issue comment "$n" --repo "$REPO" --body "$BOT_DISCLAIMER
$fix_forward_reason"; then
      printf 'merge_agent_pr: merged PR #%s but could not add fix-forward reason to issue #%s\n' \
        "$pr_number" "$n" >> "$merge_wait_log" 2>/dev/null || true
    fi
  fi

  return 0
}

# 2026-09-12 review, item 4: notify.sh's send_email() returns 0 on every
# failure BY DESIGN (a notification must never fail the pipeline run it's
# reporting on) — which also means a permanently broken alert channel is
# indistinguishable from a quiet week with nothing to report. The
# Application Default Credentials notify.sh mints tokens from are an
# `authorized_user` refresh token from an OAuth client whose consent screen
# may still be in "Testing" mode, in which case that refresh token expires
# after 7 days with no warning anywhere in this pipeline. One heartbeat a
# day makes silence itself the alert.
CODEX_EXHAUSTED_MARKER_FILE="$AGENT_HOME/codex-exhausted-until"
CODEX_PROVIDER_FAILURE_THRESHOLD=3
CODEX_PROVIDER_FAILURE_WINDOW_SECONDS=900
CODEX_PROVIDER_BACKOFF_SECONDS=90
CODEX_PROVIDER_FAILURE_EVENTS_FILE="$AGENT_HOME/codex-provider-outage-events.log"
CODEX_PROVIDER_PROBE_REQUIRED_FILE="$CODEX_EXHAUSTED_MARKER_FILE.probe-required"
CODEX_PROVIDER_PROBE_NOTICE_FILE="$CODEX_EXHAUSTED_MARKER_FILE.probe-notice-sent"
# Model capacity is scoped to the selected Codex model; provider-wide
# markers remain for quota, authentication, and transport outages.
codex_model_capacity_marker_file() {
  local value="$1" model
  case "$value" in codex:*) value="${value#codex:}" ;; esac
  model="${value%%:*}"
  [[ "$model" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  printf '%s.model-%s.capacity\n' "$CODEX_EXHAUSTED_MARKER_FILE" "$model"
}
codex_model_capacity_held() {
  local marker until now="${2:-$(date +%s)}"
  marker="$(codex_model_capacity_marker_file "$1")" || return 1
  [ -r "$marker" ] || return 1
  until="$(cat "$marker" 2>/dev/null || true)"
  [[ "$until" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || return 1
  (( now < until ))
}
codex_model_capacity_hold() {
  local marker until="${2:-$(( $(date +%s) + CODEX_PROVIDER_BACKOFF_SECONDS ))}" tmp
  [[ "$until" =~ ^[0-9]+$ ]] || return 2
  marker="$(codex_model_capacity_marker_file "$1")" || return 1
  mkdir -p "${marker%/*}" || return 1
  tmp="$marker.tmp.$$"
  printf '%s\n' "$until" > "$tmp" && mv -f -- "$tmp" "$marker"
}
# Each provider's quota marker is independent, so recovery in one provider
# cannot clear another provider's active hold.
WEB_ADVISOR_PROVIDER_EXHAUSTED_MARKER_FILE="$AGENT_HOME/web-advisor-provider-exhausted-until"
ZCODE_EXHAUSTED_MARKER_FILE="$AGENT_HOME/zcode-exhausted-until"
# _quota_marker_file <provider> -- codex|web-advisor-provider|zcode -> that provider's
# marker path above. A lookup, not string interpolation (`$AGENT_HOME/$1-...`),
# so a typo'd or unknown provider name fails loudly (empty stdout, nonzero
# status) instead of silently minting a THIRD marker path nothing reads.
_quota_marker_file() {
  case "$1" in
    codex) printf '%s\n' "$CODEX_EXHAUSTED_MARKER_FILE" ;;
    web-advisor-provider) printf '%s\n' "$WEB_ADVISOR_PROVIDER_EXHAUSTED_MARKER_FILE" ;;
    zcode) printf '%s\n' "$ZCODE_EXHAUSTED_MARKER_FILE" ;;
    *) return 1 ;;
  esac
}
# Provider-wide quota holds are recorded separately from issue-local model
# failures, so an account outage does not consume an issue's attempts.
#
# The damage was not the refusal, it was the bookkeeping. issue-pipeline.sh
# bumps a ticket's attempt counter at DISPATCH time, and the quota branches
# in run-implement.sh/run-advisor.sh only suppressed the backoff pause, not
# the attempt, for whichever provider they already recognized. So a refusal
# that the ticket had nothing to do with still spent one of its four
# attempts, and at four the ticket concludes `not-completed` and leaves an
# issue comment saying the pipeline could not do the work.
#
# So: record the outage, and refuse to dispatch that provider's work into it
# rather than spending attempts discovering it one ticket at a time. The
# marker is a deadline in epoch seconds; an absent, empty or non-numeric
# file means "not exhausted" (fail OPEN here on purpose -- the cost of a
# wrong "not exhausted" is one wasted dispatch, while a wrong "exhausted"
# would idle that provider's whole leg on a corrupt file).
PREMIUM_QUOTA_BACKOFF_SECONDS=$((60 * 30))

# parse_quota_reset_epoch <refusal_text> -- best-effort epoch seconds for a
# reset deadline STATED INSIDE the refusal, or nothing (status 1) if none
# was found or it did not parse.
#   Codex:  "...try again at Sep 19th, 2026 1:10 AM."
# A 26-hour wall against a fixed 30-minute backoff means dozens of re-probes
# that each cost nothing (the hold still works) but still burn a tick --
# parsing the stated deadline turns that into one hold that expires exactly
# when the provider says it will.
#
# Fails SAFE in both directions on purpose: the caller (note_provider_quota_
# exhausted, below) only trusts a parsed epoch that is still in the future;
# anything else -- no match, `date -d` rejecting the extracted text, a
# TZ database miss, a parsed time already in the past -- falls back to
# PREMIUM_QUOTA_BACKOFF_SECONDS instead of "no hold". A wrong SHORT guess
# just re-probes a bit early (the refund/re-detect loop below is unharmed by
# that); this function must never produce a wrong LONG guess that jams a
# provider closed past its real reset, which is why it only ever returns a
# value it parsed from the text, never a guessed/derived one.
parse_quota_reset_epoch() {
  local text="$1" when epoch
  # Codex shape: strip the ordinal suffix (1st/2nd/3rd/4th/...) -- `date -d`
  # rejects it but parses everything else unchanged.
  when="$(grep -oiE 'try again at ([A-Za-z]+ [0-9]{1,2}(st|nd|rd|th)?, [0-9]{4} )?[0-9]{1,2}:[0-9]{2} ?[AaPp][Mm]' <<< "$text" \
    | head -n1 | sed -E 's/^try again at //I; s/([0-9]+)(st|nd|rd|th)/\1/')"
  if [ -n "$when" ]; then
    epoch="$(agent_epoch "$when" 2>/dev/null || true)"
    [ -n "$epoch" ] && { echo "$epoch"; return 0; }
  fi
  return 1
}

# provider_quota_exhausted <codex|web-advisor-provider> -> exit 0 while that provider's
# recorded hold is still in force. Expiry only permits a probe; it is not
# proof the provider recovered, so the outage notification state stays until
# an actual non-refused call reports success below.
provider_quota_exhausted() {
  local provider="$1" marker until now
  marker="$(_quota_marker_file "$provider")" || return 1
  [ -f "$marker" ] || return 1
  until="$(cat "$marker" 2>/dev/null || true)"
  case "$until" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s)"
  [ "$now" -lt "$until" ]
}

provider_quota_provider_for_model() {
  case "$1" in
    codex|codex:*) echo codex ;;
    web:*) echo web-advisor-provider ;;
    zcode|zcode:*) echo zcode ;;
    *) return 1 ;;
  esac
}

# The hold stays a single bare epoch marker, because dispatch readers already
# consume that interface. This sibling marker records that the provider
# outage is active; it survives an expired deadline until a real successful
# provider call confirms recovery.
provider_quota_alert_marker_file() {
  local marker
  marker="$(_quota_marker_file "$1")" || return 1
  printf '%s.alerted\n' "$marker"
}

provider_quota_lock_file() {
  case "$1" in
    codex|web-advisor-provider|zcode) printf '%s/locks/provider-quota-%s.lock\n' "$AGENT_HOME" "$1" ;;
    *) return 1 ;;
  esac
}

provider_quota_write_until() {
  local provider="$1" until="$2" marker tmp
  marker="$(_quota_marker_file "$provider")" || return 1
  tmp="$(mktemp "${marker}.tmp.XXXXXX")" || return 1
  if ! printf '%s\n' "$until" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$marker"
}

# provider_quota_recovered <codex|web-advisor-provider> -- call only after a real,
# non-refused provider result. The lock serializes the local outage marker
# transition, so concurrent successful units record recovery once.
provider_quota_recovered() {
  local provider="$1" marker alert_marker lock_file lock_fd recovered=0
  marker="$(_quota_marker_file "$provider")" || return 1
  alert_marker="$(provider_quota_alert_marker_file "$provider")" || return 1
  lock_file="$(provider_quota_lock_file "$provider")" || return 1
  exec {lock_fd}>"$lock_file"
  flock "$lock_fd"
  if [ -f "$alert_marker" ]; then
    rm -f "$marker" "$alert_marker"
    recovered=1
    echo "provider_quota_recovered: $provider dispatch resumed" >&2
  fi
  unlock_fd "$lock_fd"
  [ "$recovered" = "1" ]
}

# note_provider_quota_exhausted <codex|web-advisor-provider> <issue|""> [refusal_text] --
# record the outage for that provider, and give back the attempt this
# ticket was charged at dispatch. A quota window is not the ticket's
# failure and must not count toward its give-up budget. $refusal_text, when
# given, is tried through parse_quota_reset_epoch() first; any failure to
# extract or parse it falls back to the fixed PREMIUM_QUOTA_BACKOFF_SECONDS
# (see that parser's own comment for why the fallback direction matters).
note_provider_quota_exhausted() {
  local provider="$1" n="${2:-}" refusal_text="${3:-}" normalized_refusal marker alert_marker lock_file lock_fd until parsed now reset_at
  marker="$(_quota_marker_file "$provider")" || { echo "note_provider_quota_exhausted: unknown provider '$provider'" >&2; return 1; }
  alert_marker="$(provider_quota_alert_marker_file "$provider")" || return 1
  lock_file="$(provider_quota_lock_file "$provider")" || return 1
  parsed=""
  [ -n "$refusal_text" ] && parsed="$(parse_quota_reset_epoch "$refusal_text" 2>/dev/null || true)"
  now="$(date +%s)"
  if [ -n "$parsed" ] && [ "$parsed" -gt "$now" ] 2>/dev/null; then
    until="$parsed"
  else
    until=$(( now + PREMIUM_QUOTA_BACKOFF_SECONDS ))
  fi
  exec {lock_fd}>"$lock_file"
  flock "$lock_fd"
  provider_quota_write_until "$provider" "$until" || {
    unlock_fd "$lock_fd"
    return 1
  }
  normalized_refusal="$(codex_usage_limit_text_for_matching "$refusal_text")"
  if [ "$provider" = codex ] && grep -qiE "you've hit your usage limit" <<< "$normalized_refusal"; then
    reset_at="$(date -u -d "@$until" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    record_env_fault env:codex-usage-limit infrastructure "${n:-0}" \
      "Codex account usage limit; reset=$reset_at" "" "$now" 0 || {
      unlock_fd "$lock_fd"
      return 1
    }
  fi
  if [ ! -f "$alert_marker" ]; then
    printf '%s\n' "$until" > "$alert_marker"
    echo "note_provider_quota_exhausted: $provider unavailable until $(date -d "@$until" '+%Y-%m-%d %H:%M:%S %Z')" >&2
  fi
  unlock_fd "$lock_fd"
  echo "note_provider_quota_exhausted: $provider refused on quota -- holding $provider dispatch until $(date -d "@$until" '+%H:%M:%S') and not charging this attempt" >&2
  [ -n "$n" ] && state_unbump_attempts "$n"
  return 0
}

# codex_quota_exhausted -- thin, signature-preserving wrapper over the generic
# provider_quota_exhausted above; $CODEX_EXHAUSTED_MARKER_FILE keeps meaning
# exactly what it always meant.
codex_quota_exhausted() {
  local identity="${1:-}"
  if [ -e "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" ]; then
    codex_probe_ok || return 0
    identity="${identity:-$(model_policy identity work)}" || return 0
    codex_provider_recovery_probe_if_due "$identity" || return 0
  fi
  provider_quota_exhausted codex
}
# note_codex_provider_outage <issue|session:key> <kind> <caller> <model> [now] --
# keep issue retries local; capacity holds its model, shared outages trip the
# Codex-wide circuit after three distinct issues in the observed window.
note_codex_provider_outage() {
  local n="$1" kind="$2" caller="$3" model="$4" now="${5:-$(date +%s)}"
  local until_epoch timestamp retry_json kind_json lock_file lock_fd tmp distinct seen_until
  [[ "$n" =~ ^[1-9][0-9]*$ || "$n" == session:* ]] || return 0
  [[ "$now" =~ ^[0-9]+$ ]] || return 0
  until_epoch=$((now + CODEX_PROVIDER_BACKOFF_SECONDS))
  record_env_fault env:provider-outage infrastructure "$n" \
    "Codex provider outage kind=$kind caller=$caller model=$model" "" "$now" 0 || true
  timestamp="$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  retry_json="$(jq -cn --arg issue "$n" --arg kind "$kind" --arg caller "$caller" \
    --arg model "$model" --arg timestamp "$timestamp" --argjson until "$until_epoch" \
    '{reason:("Codex provider outage (" + $kind + ")"),issue:$issue,provider:"codex",model:$model,caller:$caller,timestamp:$timestamp,until_epoch:$until}')" || return 1
  kind_json="$(jq -cn --arg kind "$kind" '$kind')" || return 1
  if [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
    state_merge "$n" ".model_policy = (.model_policy // {}) | .model_policy.active = (.model_policy.active // {}) | .model_policy.active.provider_outage = true | .model_policy.active.provider_outage_kind = $kind_json | .model_failure_backoff = $retry_json" || return 1
  fi

  if [ "$kind" = provider-capacity ]; then
    if codex_model_capacity_hold "$model" "$until_epoch"; then
      echo "note_codex_provider_outage: model capacity hold opened for $model" >&2
    fi
    return 0
  fi

  # Issue egress failures share their own circuit; standalone sessions need a retry deadline.
  [ "$kind" != network-egress ] || [[ "$n" == session:* ]] || return 0

  mkdir -p "$AGENT_HOME/locks"
  lock_file="$(provider_quota_lock_file codex)" || return 1
  exec {lock_fd}>"$lock_file" || return 1
  flock "$lock_fd" || { unlock_fd "$lock_fd"; return 1; }
  tmp="$(mktemp "${CODEX_PROVIDER_FAILURE_EVENTS_FILE}.tmp.XXXXXX")" || { unlock_fd "$lock_fd"; return 1; }
  if [ -f "$CODEX_PROVIDER_FAILURE_EVENTS_FILE" ]; then
    awk -F '\t' -v cutoff="$((now - CODEX_PROVIDER_FAILURE_WINDOW_SECONDS))" \
      '$1 ~ /^[0-9]+$/ && $1 >= cutoff && ($2 ~ /^[1-9][0-9]*$/ || $2 ~ /^session:/) { print }' \
      "$CODEX_PROVIDER_FAILURE_EVENTS_FILE" > "$tmp" || { rm -f "$tmp"; unlock_fd "$lock_fd"; return 1; }
  fi
  mv -f "$tmp" "$CODEX_PROVIDER_FAILURE_EVENTS_FILE" || { rm -f "$tmp"; unlock_fd "$lock_fd"; return 1; }
  if ! awk -F '\t' -v issue="$n" '$2 == issue { found=1 } END { exit found ? 0 : 1 }' "$CODEX_PROVIDER_FAILURE_EVENTS_FILE"; then
    printf '%s\t%s\t%s\n' "$now" "$n" "$kind" >> "$CODEX_PROVIDER_FAILURE_EVENTS_FILE" || { unlock_fd "$lock_fd"; return 1; }
  fi
  distinct="$(awk -F '\t' -v cutoff="$((now - CODEX_PROVIDER_FAILURE_WINDOW_SECONDS))" \
    '$1 ~ /^[0-9]+$/ && $1 >= cutoff && ($2 ~ /^[1-9][0-9]*$/ || $2 ~ /^session:/) { issues[$2]=1 } END { for (issue in issues) count++; print count+0 }' \
    "$CODEX_PROVIDER_FAILURE_EVENTS_FILE")"
  if [ "$distinct" -ge "$CODEX_PROVIDER_FAILURE_THRESHOLD" ]; then
    seen_until="$(cat "$CODEX_EXHAUSTED_MARKER_FILE" 2>/dev/null || true)"
    if ! [[ "$seen_until" =~ ^[0-9]+$ ]] || [ "$seen_until" -le "$now" ]; then
      provider_quota_write_until codex "$until_epoch" || { unlock_fd "$lock_fd"; return 1; }
    fi
    if [ ! -e "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" ]; then
      printf '%s\n' "$((now + CODEX_PROVIDER_BACKOFF_SECONDS))" > "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" || { unlock_fd "$lock_fd"; return 1; }
      rm -f "$CODEX_PROVIDER_PROBE_NOTICE_FILE"
      supervisor_inbox_append codex-provider-outage \
        "circuit=open distinct_issues=$distinct window=$CODEX_PROVIDER_FAILURE_WINDOW_SECONDS""s backoff=$CODEX_PROVIDER_BACKOFF_SECONDS""s" || { unlock_fd "$lock_fd"; return 1; }
      echo "note_codex_provider_outage: circuit opened after $distinct distinct issues; Codex held for ${CODEX_PROVIDER_BACKOFF_SECONDS}s before bare probe" >&2
    elif ! provider_quota_exhausted codex; then
      provider_quota_write_until codex "$until_epoch" || { unlock_fd "$lock_fd"; return 1; }
    fi
  fi
  unlock_fd "$lock_fd"
}

# Run a tiny read-only Codex call every 90s during an outage. No issue prompt
# or ticket context crosses this probe; only a completed response clears hold.
codex_provider_recovery_probe_if_due() {
  local identity="$1" spec model effort now due lock_file lock_fd probe_out probe_log status=0 kind="" timestamp service_tier issue probe_succeeded=0 timeout_seconds
  local -a service_tier_args=()
  [ -e "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" ] || return 0
  # An actual quota refusal must never be cleared by an availability probe.
  if [ -e "$CODEX_EXHAUSTED_MARKER_FILE.alerted" ] && provider_quota_exhausted codex; then return 1; fi
  case "$identity" in codex:*) spec="${identity#codex:}" ;; *) return 0 ;; esac
  [[ "$spec" == *:* ]] || return 1
  model="${spec%:*}"
  effort="${spec##*:}"
  [ -n "$model" ] && [ -n "$effort" ] || return 1
  timeout_seconds="${CODEX_JSON_TIMEOUT_SECONDS:-2700}"
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || return 1
  service_tier="$(model_policy tier "$identity")" || return $?
  [ -z "$service_tier" ] || service_tier_args=(-c "service_tier=\"$service_tier\"")
  mkdir -p "$AGENT_HOME/locks"
  lock_file="$(provider_quota_lock_file codex)" || return 1
  exec {lock_fd}>"$lock_file" || return 1
  flock "$lock_fd" || { unlock_fd "$lock_fd"; return 1; }
  if [ ! -e "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" ]; then
    unlock_fd "$lock_fd"
    return 0
  fi
  if [ -e "$CODEX_EXHAUSTED_MARKER_FILE.alerted" ] && provider_quota_exhausted codex; then
    unlock_fd "$lock_fd"
    return 1
  fi
  now="$(date +%s)"
  due="$(cat "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" 2>/dev/null || true)"
  # Empty legacy latches probe immediately instead of inheriting the old thirty-minute deadline.
  if [[ "$due" =~ ^[0-9]+$ ]] && [ "$now" -lt "$due" ]; then
    unlock_fd "$lock_fd"
    return 1
  fi
  probe_out="$(mktemp)" || { unlock_fd "$lock_fd"; return 1; }
  probe_log="$(mktemp)" || { rm -f "$probe_out"; unlock_fd "$lock_fd"; return 1; }
  pipeline_execution_run timeout "${timeout_seconds}s" env -u GH_TOKEN -u GITHUB_TOKEN codex exec \
    --sandbox "$CODEX_SANDBOX_MODE" --cd "$REPO_DIR" --skip-git-repo-check --ephemeral \
    -m "$model" -c model_reasoning_effort=low "${service_tier_args[@]}" \
    -c mcp_servers.gitnexus.enabled=false \
    --output-last-message "$probe_out" - \
    <<< 'Reply with exactly: OK.' > "$probe_log" 2>&1 || status=$?
  now="$(date +%s)"
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ "$status" -eq 0 ] && [ -s "$probe_out" ]; then
    probe_succeeded=1
  elif [ "$status" -eq 124 ]; then
    rm -f "$CODEX_PROVIDER_PROBE_REQUIRED_FILE"
    rm -f "$probe_out" "$probe_log"
    unlock_fd "$lock_fd"
    echo "codex_provider_recovery_probe_if_due: bare probe timed out; recovery latch cleared without extending provider hold" >&2
    return 0
  else
    kind="$(premium_call_provider_outage_kind "$(cat "$probe_log" 2>/dev/null || true)" || true)"
    if [ -z "$kind" ] && grep -qiE '401 Unauthorized|Incorrect API key|invalid_api_key' "$probe_log"; then
      kind="authentication/configuration"
    fi
    if [ "$kind" = provider-capacity ]; then
      codex_model_capacity_hold "$model" "$((now + CODEX_PROVIDER_BACKOFF_SECONDS))" || {
        rm -f "$probe_out" "$probe_log"
        unlock_fd "$lock_fd"
        return 1
      }
      probe_succeeded=1
    fi
  fi
  if [ "$probe_succeeded" = 1 ]; then
    # Clear only outage backoffs proven older than this successful probe; preserve other failure holds.
    while read -r issue; do
      state_merge "$issue" "if .model_failure_backoff.provider == \"codex\" and (.model_failure_backoff.reason // \"\" | startswith(\"Codex provider outage (\")) and (.model_failure_backoff.timestamp // \"\") <= \"$timestamp\" then del(.model_failure_backoff) else . end" || {
        rm -f "$probe_out" "$probe_log"; unlock_fd "$lock_fd"; return 1;
      }
    done < <(awk -F '\t' '$2 ~ /^[1-9][0-9]*$/ { issues[$2]=1 } END { for (issue in issues) print issue }' "$CODEX_PROVIDER_FAILURE_EVENTS_FILE" 2>/dev/null)
    rm -f "$CODEX_EXHAUSTED_MARKER_FILE" "$CODEX_EXHAUSTED_MARKER_FILE.alerted" \
      "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" "$CODEX_PROVIDER_PROBE_NOTICE_FILE"
    : > "$CODEX_PROVIDER_FAILURE_EVENTS_FILE"
    rm -f "$probe_out" "$probe_log"
    unlock_fd "$lock_fd"
    if [ "$kind" = provider-capacity ]; then
      echo "codex_provider_recovery_probe_if_due: provider responded; model capacity held for $model, provider hold cleared" >&2
    else
      echo "codex_provider_recovery_probe_if_due: bare Codex probe passed; provider hold cleared" >&2
    fi
    return 0
  fi
  kind="${kind:-probe-unclassified}"
  printf '%s\n' "$((now + CODEX_PROVIDER_BACKOFF_SECONDS))" > "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" || {
    rm -f "$probe_out" "$probe_log"
    unlock_fd "$lock_fd"
    return 1
  }
  provider_quota_write_until codex "$((now + CODEX_PROVIDER_BACKOFF_SECONDS))" || {
    rm -f "$probe_out" "$probe_log"
    unlock_fd "$lock_fd"
    return 1
  }
  if [ "$kind" = "authentication/configuration" ] || [ "$kind" = "probe-unclassified" ]; then
    if [ ! -e "$CODEX_PROVIDER_PROBE_NOTICE_FILE" ]; then
      supervisor_inbox_append codex-provider-recovery-probe \
        "failed kind=$kind; dispatch remains held" || { rm -f "$probe_out" "$probe_log"; unlock_fd "$lock_fd"; return 1; }
      : > "$CODEX_PROVIDER_PROBE_NOTICE_FILE"
    fi
  fi
  rm -f "$probe_out" "$probe_log"
  unlock_fd "$lock_fd"
  echo "codex_provider_recovery_probe_if_due: bare probe failed kind=$kind status=$status; dispatch held for ${CODEX_PROVIDER_BACKOFF_SECONDS}s" >&2
  return 1
}

# One tick's latest decision lives beside the issue state; every invocation
# also emits a structured-enough journal line. state_merge keeps this
# bookkeeping from refreshing state_changed_at, so a stuck ticket stays stale.
# --- implement dispatch streak (2026-10-08) ----------------------------------
# One line in $AGENT_HOME/night/implement-dispatch-streak:
#   ticks=<K> open=<tick|none> gate=<last gate>
# K counts consecutive scheduler ticks that reached implement with a free slot
# and ready candidates but dispatched nothing. A tick opens the streak before
# any implement work, so a tick killed before its summary (02:24Z and 02:44Z
# on 2026-10-08, TimeoutStartSec) still counts; the next open names that kill.
implement_dispatch_streak_file() {
  printf '%s\n' "${IMPLEMENT_DISPATCH_STREAK_FILE:-$AGENT_HOME/night/implement-dispatch-streak}"
}

implement_dispatch_streak_read() {
  local file line ticks=0 open=none gate=none field
  file="$(implement_dispatch_streak_file)"
  IFS= read -r line 2>/dev/null < "$file" || line=""
  for field in $line; do
    case "$field" in
      ticks=*) ticks="${field#ticks=}" ;;
      open=*) open="${field#open=}" ;;
      gate=*) gate="${field#gate=}" ;;
    esac
  done
  [[ "$ticks" =~ ^[0-9]+$ ]] || ticks=0
  printf '%s %s %s\n' "$ticks" "${open:-none}" "${gate:-none}"
}

implement_dispatch_streak_write() {
  local file tmp
  file="$(implement_dispatch_streak_file)"
  mkdir -p "${file%/*}" || return 1
  tmp="$file.tmp.$$"
  printf 'ticks=%s open=%s gate=%s\n' "$1" "$2" "$3" > "$tmp" && mv -f -- "$tmp" "$file"
}

# implement_dispatch_streak_open <tick>
implement_dispatch_streak_open() {
  local tick="$1" ticks open gate
  read -r ticks open gate <<< "$(implement_dispatch_streak_read)"
  [ "$open" = none ] || gate=tick-ended-before-implement-summary
  implement_dispatch_streak_write "$((ticks + 1))" "$tick" "$gate"
}

# implement_dispatch_streak_close <dispatched> <free slots at start> <candidates> <top gate>
implement_dispatch_streak_close() {
  local dispatched="$1" slots="$2" candidates="$3" gate="${4:-none}" ticks open old_gate
  read -r ticks open old_gate <<< "$(implement_dispatch_streak_read)"
  [ "$open" != none ] || ticks=$((ticks + 1))
  if [ "${dispatched:-0}" -gt 0 ] || [ "${slots:-0}" -le 0 ] || [ "${candidates:-0}" -le 0 ]; then
    ticks=0
  fi
  implement_dispatch_streak_write "$ticks" none "${gate// /_}"
}

# Ticks with free implement capacity and ready work but no dispatch before
# HEALTH calls the stage STUCK. Measured 2026-10-01..08: healthy ticks run
# 14-18 min apart and every no-dispatch run of 3+ ticks was this starvation
# class (budget-exhausted, 2026-10-04 and 2026-10-08), so 3 ticks is ~45 min.
IMPLEMENT_NO_DISPATCH_STUCK_TICKS="${IMPLEMENT_NO_DISPATCH_STUCK_TICKS:-3}"

# implement_dispatch_stall_detail <active> <cap> <ready>: prints the STUCK
# detail and returns 0 when implement has free slots and ready work but has not
# dispatched for IMPLEMENT_NO_DISPATCH_STUCK_TICKS ticks; returns 1 otherwise.
implement_dispatch_stall_detail() {
  local active="$1" cap="$2" ready="$3" ticks open gate
  [[ "$active" =~ ^[0-9]+$ && "$cap" =~ ^[0-9]+$ && "$ready" =~ ^[0-9]+$ ]] || return 1
  (( ready > 0 && active < cap )) || return 1
  read -r ticks open gate <<< "$(implement_dispatch_streak_read)"
  (( ticks >= IMPLEMENT_NO_DISPATCH_STUCK_TICKS )) || return 1
  printf 'no implement dispatch for %s ticks with %s/%s active and %s ready; gate=%s\n' \
    "$ticks" "$active" "$cap" "$ready" "$gate"
}

record_implement_tick_decision() {
  local n="$1" tick="$2" outcome="$3" gate="$4" reason="$5" object="$6" record reason_file
  reason_file="$(jq_arg_file "$reason")"
  record="$(jq -cn --arg tick "$tick" --arg outcome "$outcome" --arg gate "$gate" \
    --rawfile reason "$reason_file" --arg object "$object" \
    '{tick:$tick, outcome:$outcome, gate:$gate, reason:$reason, object:$object, recorded_at:(now | todate)}')"
  rm -f "$reason_file"
  state_merge "$n" ".implement_tick_decision = $record" || return 1
  printf 'issue-pipeline: implement-decision tick=%s issue=#%s outcome=%s gate=%s object=%s reason=%s\n' \
    "$tick" "$n" "$outcome" "$gate" "$object" "$reason" >&2
}

record_advisor_tick_decision() {
  local n="$1" tick="$2" outcome="$3" gate="$4" reason="$5" object="$6" record reason_file
  reason_file="$(jq_arg_file "$reason")"
  record="$(jq -cn --arg tick "$tick" --arg outcome "$outcome" --arg gate "$gate" \
    --rawfile reason "$reason_file" --arg object "$object" \
    '{tick:$tick, outcome:$outcome, gate:$gate, reason:$reason, object:$object, recorded_at:(now | todate)}')"
  rm -f "$reason_file"
  state_merge "$n" ".advisor_tick_decision = $record" || return 1
  printf 'issue-pipeline: advisor-decision tick=%s issue=#%s outcome=%s gate=%s object=%s reason=%s\n' \
    "$tick" "$n" "$outcome" "$gate" "$object" "$reason" >&2
}

record_triage_tick_decision() {
  local n="$1" tick="$2" outcome="$3" gate="$4" reason="$5" object="$6" record reason_file
  reason_file="$(jq_arg_file "$reason")"
  record="$(jq -cn --arg tick "$tick" --arg outcome "$outcome" --arg gate "$gate" \
    --rawfile reason "$reason_file" --arg object "$object" \
    '{tick:$tick, outcome:$outcome, gate:$gate, reason:$reason, object:$object, recorded_at:(now | todate)}')"
  rm -f "$reason_file"
  state_merge "$n" ".triage_tick_decision = $record" || return 1
  printf 'issue-pipeline: triage-decision tick=%s issue=#%s outcome=%s gate=%s object=%s reason=%s\n' \
    "$tick" "$n" "$outcome" "$gate" "$object" "$reason" >&2
}

# Count issue-local loop escalations for supervisor HEALTH records.
count_recent_loop_escalations() {
  local cutoff f n=0
  cutoff="$(date -u -d '-24 hours' +%Y-%m-%dT%H:%M:%SZ)"
  [ -d "$STATE_DIR" ] || { echo 0; return; }
  for f in "$STATE_DIR"/*.json; do
    [ -f "$f" ] || continue
    if jq -e --arg c "$cutoff" '(.loop_escalated_at // "") >= $c' "$f" >/dev/null 2>&1; then
      n=$((n + 1))
    fi
  done
  echo "$n"
}

# =============================================================================
# Advisor execution claims + per-run worktree lifecycle (2026-09-20)
#
# Kept in a separate section from advisor verdict handling so the per-ticket
# claim lifecycle stays easy to find and review.
#
# The gap this closes: nothing today actually stops the automated per-tick
# dispatch (issue-pipeline.sh's `zf-advisor-$n` unit), a manual
# `run-advisor.sh <N>`, and a manual `run-advisor-batch.sh` sweep from all
# working advisor judgment at once. `stage_unit_active advisor "$n"`
# (existing, used by run-advisor-batch.sh's own candidate loop above) only
# catches a systemd-dispatched run currently alive for that ONE ticket -- it
# has no opinion on a hand-run `run-advisor.sh`/`run-advisor-batch.sh`
# invoked directly from a shell, and a GitHub label is not a mutex either
# (can lag, get raced, get read stale). These primitives are wired into the
# two advisor entry points below; every stage exit uses worktree_lifecycle_finish().
#
# --- Per-ticket claim -------------------------------------------------------
# One lock per issue (locks/issue-N.lock), acquired right after a ticket is
# selected and right before its judgment snapshot is read, released as soon
# as that ticket's processing for this round is done. Claims are independent
# across tickets; this is the only advisor execution lock now.
#
# Both non-blocking (try once, skip on failure -- "someone else already has
# it" is not an error, is not charged as an attempt, and must not create a
# worktree).
#
# --- Reuse check performed before writing this ------------------------------
# grepped this whole directory for `flock`/lock-helper functions first, per
# the design review's own instruction to reuse rather than invent. Found
# two: issue-pipeline.sh's own tick-decision lock (`exec 9>"$LOCK_FILE";
# flock -n 9 || exit 0`, inlined there, not a function) and this file's
# acquire_merge_lock()/release_merge_lock() above (blocking with a bound,
# one FIXED fd (8), one FIXED lock file (MERGE_LOCK_FILE), built for
# one shared merge API mutation -- `gh pr merge` itself). Neither fits here unmodified: both assume a
# single hardcoded fd for a singleton lock, but advisor batch callers can
# hold one claim per ticket in the same process. try_lock_nonblocking()
# below is the reusable helper; it still
# shares acquire_merge_lock()'s fundamental flock discipline (fd closes ->
# lock releases, even on the holder's own unclean exit, no hand-rolled
# "touch a marker file" cleanup needed) instead of reinventing it.
#
# try_lock_nonblocking <lock_file> <out_fd_var>
#   Non-blocking flock acquire on a FRESHLY, dynamically allocated fd
#   (bash's `exec {fd}>file` form -- picks a free descriptor itself, never
#   a fixed number the way LOCK_FILE's fd 9 / MERGE_LOCK_FILE's fd 8 above
#   are, both true singletons by design). On success, the fd number is
#   written into the CALLER's variable named by <out_fd_var> (via
#   `printf -v`, not echoed) and this returns 0. On failure (already held
#   elsewhere) it closes what it opened, writes nothing, and returns 1 --
#   the caller never even sees an fd number to leak.
#
#   MUST be called as a bare statement (`try_lock_nonblocking ... FDVAR` or
#   `if try_lock_nonblocking ... FDVAR; then`), NEVER via command
#   substitution (`x=$(try_lock_nonblocking ...)`). Command substitution
#   forks a subshell; the open, locked fd this function creates lives only
#   in that subshell's own process, which is already gone by the time the
#   substitution finishes capturing output -- the caller would be left
#   holding a "lock" that was silently released the instant it was
#   acquired. Proven live while building this: an earlier draft did exactly
#   that and a second, independent lock attempt against the same file
#   succeeded immediately afterward, when it should have blocked. (Same
#   reason acquire_merge_lock() above is always called bare, never
#   `x=$(acquire_merge_lock)`.)
try_lock_nonblocking() {
  local lock_file="$1" __out_fd_var="$2" __fd
  # Bash resolves printf -v targets through this function's locals first.
  # Reject every local name, so an out-variable can never be shadowed here
  # and leave a lock fd stranded in this helper instead of its caller.
  case "$__out_fd_var" in
    lock_file|__out_fd_var|__fd)
      echo "try_lock_nonblocking: output variable $__out_fd_var is reserved" >&2
      return 2
      ;;
  esac
  mkdir -p -- "$(dirname -- "$lock_file")"
  exec {__fd}>"$lock_file"
  if flock -n "$__fd"; then
    printf -v "$__out_fd_var" '%s' "$__fd"
    return 0
  fi
  exec {__fd}>&-
  return 1
}

# unlock_fd <fd> -- releases a try_lock_nonblocking() lock and closes its
# fd. An empty fd is a quiet cleanup-trap no-op; a non-empty fd that cannot
# unlock or close must fail loudly, or a leaked lease becomes invisible.
# Keep stderr attached: a bare `exec` redirection permanently changes the
# caller's descriptor.
unlock_fd() {
  local __fd="${1:-}"
  [ -n "$__fd" ] || return 0
  if ! flock -u "$__fd"; then
    echo "unlock_fd: failed to unlock fd $__fd" >&2
    return 1
  fi
  if ! exec {__fd}>&-; then
    echo "unlock_fd: failed to close fd $__fd" >&2
    return 1
  fi
}

# run_with_fd_closed <fd...> -- <command...>
#   File-descriptor hygiene for exactly one shape of bug: a long-running
#   child started WHILE a try_lock_nonblocking() lock is held (a long-running
#   model invocation, in particular) inherits open fds by
#   default in bash (`exec N>file`-opened fds carry no close-on-exec flag
#   unless told to). flock's lock lives on the OPEN FILE DESCRIPTION, not
#   on the process that created it -- released only once EVERY fd
#   referencing it, in EVERY process, is closed. A model call spawned
#   without this would keep its own inherited copy of the fd open for as
#   long as the model runs, holding the lock long after this run's own
#   unlock_fd() call, even though the run that "released" it has moved on.
#   This is not hypothetical for this codebase: the 2026-09-15 #1204
#   incident (gh()/git_fetch_bounded()'s own comment, near the top of this
#   file) was precisely a hung CHILD process holding a lock fd its parent
#   no longer controlled, for 2h25m, invisible to every non-blocking probe
#   after it.
#
#   Runs <command...> in a subshell with every listed fd closed FIRST -- the
#   subshell's own fd table is a copy of the parent's, so closing it there
#   never touches the parent's still-open, still-locked fd (proven live:
#   a fresh in-process fd opened against the same lock file right after a
#   run_with_fd_closed() call still blocks, confirming the parent's hold
#   survives). The parent must still call unlock_fd() itself when done.
run_with_fd_closed() {
  local -a fds=()
  local fd
  while [ "$#" -gt 0 ] && [ "${1:-}" != "--" ]; do
    fds+=("$1")
    shift
  done
  [ "${1:-}" = "--" ] && shift
  (
    for fd in "${fds[@]}"; do
      { exec {fd}>&-; } 2>/dev/null
    done
    "$@"
  )
}

# A web session is shared by automation. This is a
# process-owned flock lease, never a stale marker: closing the fd (including
# on a crash) releases it. The blocking form intentionally reuses the merge
# queue's existing bound instead of adding another wait policy.
WEB_SESSION_LEASE_FILE="${WEB_SESSION_LEASE_FILE:-$AGENT_HOME/web-session.lock}"
WEB_SESSION_LEASE_WAIT_SECONDS="${WEB_SESSION_LEASE_WAIT_SECONDS:-$MERGE_LOCK_WAIT_SECONDS}"

try_acquire_web_session_lease() {
  local __out_fd_var="$1" lock_file="${WEB_SESSION_LEASE_FILE:-$AGENT_HOME/web-session.lock}"
  try_lock_nonblocking "$lock_file" "$__out_fd_var"
}

acquire_web_session_lease() {
  local __out_fd_var="$1" wait_seconds="${2:-${WEB_SESSION_LEASE_WAIT_SECONDS:-$MERGE_LOCK_WAIT_SECONDS}}" \
    lock_file="${WEB_SESSION_LEASE_FILE:-$AGENT_HOME/web-session.lock}" fd
  mkdir -p -- "$(dirname -- "$lock_file")"
  exec {fd}>"$lock_file"
  if flock -w "$wait_seconds" "$fd"; then
    printf -v "$__out_fd_var" '%s' "$fd"
    return 0
  fi
  exec {fd}>&-
  return 1
}

web_session_lease_available() {
  # Dispatch checks honor a timed operator reservation; direct lease users,
  # including a waiting lease holder, still contend only on the flock.
  local fd="" reserved_until="" reserved_by="" reservation_file="$AGENT_HOME/locks/web-session-reserved-until"
  if [ -r "$reservation_file" ] \
    && IFS=' ' read -r reserved_until reserved_by < "$reservation_file" \
    && [[ "$reserved_until" =~ ^[0-9]+$ && -n "$reserved_by" ]] \
    && (( 10#$reserved_until > $(date +%s) )); then
    return 1
  fi
  try_acquire_web_session_lease fd || return 1
  unlock_fd "$fd"
}

ADVISOR_LOCKS_DIR="$AGENT_HOME/locks"

# advisor_ticket_lock_file <issue_number> -- same one-line-echo shape as
# state_file() near the top of this file, for the same reason: one place
# defines the path convention, every caller (and every test) derives it the
# same way instead of hand-building "$ADVISOR_LOCKS_DIR/issue-$n.lock" at
# each call site.
advisor_ticket_lock_file() { echo "$ADVISOR_LOCKS_DIR/issue-$1.lock"; }

# --- Per-run advisor worktree lifecycle -------------------------------------
# The concrete bug this replaces: run-advisor-batch.sh used to `rm -rf` and
# recreate ONE FIXED directory ($HOME/wt/advisor-batch) at the start of
# every run. Two runs that ever overlapped (a manual re-run started before
# the first finished, or ever will once a scheduler dispatches this
# automatically) would silently destroy whatever the other had checked out
# mid-flight. Worse, a crashed prior run's worktree -- exactly the kind of
# thing worth inspecting after a failure -- gets deleted by the NEXT run's
# own startup, before anyone gets to look at it. A unique, per-run directory
# makes "two runs never step on each other's checkout" true by construction
# instead of by luck of timing, the same shift LOCK_FILE-style mutexes make
# for concurrent access generally.
#
# advisor_owner_isolated_checkout <repo_dir> -> true only in a node-owner episode checkout.
advisor_owner_isolated_checkout() {
local repo_dir="${1:-$REPO_DIR}" branch
branch="$(git -C "$repo_dir" branch --show-current 2>/dev/null)" || return 1
[[ "$branch" == node-auto-owner/* ]]
}

# advisor_worktree_new <need_worktree> [ref] [repo_dir]
#   need_worktree: "1" to actually create one, anything else ("0", unset)
#   to skip -- prints nothing, returns 0, nothing to clean up either. A
#   pure pending-advisor-verdict resume (reading back an already-persisted
#   ruling, applying its GitHub side effects) needs no fresh source
#   checkout at all; only a NEW judgment pass does. This function does not
#   decide which one a given run is -- that decision belongs to the caller
#   (the resume-vs-fresh-pass logic lives in run-advisor.sh's own verdict
#   persistence, a parallel change to this one) -- it only takes the
#   decision as a precondition.
#
#   On success: prints the new worktree's absolute path on stdout, returns
#   0 (safe to capture via command substitution -- unlike the locks above,
#   `git worktree add`'s effect is on-disk/in `.git`, not an open fd tied
#   to this shell's own process, so nothing is lost across a subshell).
#   On `git worktree add` failure: prints nothing, returns 1 -- the caller
#   records its own env fault (record_env_fault), the same as the call
#   site this replaces already did; this function has no ticket/stage
#   context of its own to attach one.
#
#   Directory: $HOME/wt/advisor-run-<id>, never $HOME/wt/advisor-batch or
#   any other fixed name. <id> is $INVOCATION_ID (systemd sets this per
#   unit-start already, unique by construction) when running under
#   systemd, else a kernel-random id from /proc/sys/kernel/random/uuid --
#   deliberately NOT a hash of anything. CLAUDE.md's project-level rule
#   against computing/recording a hash for this kind of identifier exists
#   because of a real incident (scrub_git_object_ids()'s own comment above:
#   a Git commit id quoted straight into a published comment/email, twice,
#   undetected); a content hash would also just be the wrong tool here even
#   ignoring that rule -- two runs against the identical origin/main tip
#   would hash identically and collide on exactly the one property
#   ("distinguishes THIS run's directory from any other's") this id needs.
advisor_worktree_new() {
local need_worktree="${1:-0}" ref="${2:-origin/main}" repo_dir="${3:-$REPO_DIR}" id wt WT_ADD_OUTPUT origin_main_sha requested_sha
  [ "$need_worktree" = "1" ] || return 0
if advisor_owner_isolated_checkout "$repo_dir"; then
  origin_main_sha="$(git -C "$repo_dir" rev-parse --verify -q 'refs/remotes/origin/main^{commit}' 2>/dev/null || true)"
  requested_sha="$(git -C "$repo_dir" rev-parse --verify -q "$ref^{commit}" 2>/dev/null || true)"
  if [[ "$ref" == origin/main || ( -n "$origin_main_sha" && "$requested_sha" == "$origin_main_sha" ) ]]; then
    echo "advisor_worktree_new: refusing origin/main for node-owner checkout $repo_dir" >&2
    return 1
  fi
fi
  # 2026-09-20: $INVOCATION_ID alone is NOT unique per call -- systemd mints
  # one per UNIT START, so two calls inside one unit computed the same path
  # and the second `git worktree add` died with "already exists". It only
  # ever showed up on CI (the self-hosted runner runs under systemd, so the
  # variable is set there; an interactive shell has none), and it was
  # invisible for three runs because unlock_fd() had detached stderr by
  # then. Keep the invocation id as a PREFIX -- it is what ties a directory
  # back to the unit that made it -- and add a per-call component after it.
  id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)"
  [ -n "$id" ] || id="$$-$RANDOM-$(date -u +%s%N)"
  [ -z "${INVOCATION_ID:-}" ] || id="$INVOCATION_ID-$id"
  wt="${ZF_WORKTREE_ROOT:-$HOME/wt}/advisor-run-$id"
  if ! WT_ADD_OUTPUT="$(git -C "$repo_dir" worktree add "$wt" "$ref" 2>&1)"; then
    echo "advisor_worktree_new: git worktree add failed for $wt @ $ref: $WT_ADD_OUTPUT" >&2
    return 1
  fi
  echo "$wt"
}

# comms-format.sh: the maintainer-communication formatter (maintainer timezone,
# Chinese-output gate inputs, local artifact paths) loaded before notify.sh
# so its pre-send checks exist by the time mail is built.
# shellcheck source=./comms-format.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/comms-format.sh"

# notify_email()/notify_maintainer()/resolve_recipients(): see notify.sh. Sourced
# last (not first) purely so every function/variable above already exists by
# the time a script that sources lib.sh runs anything — notify.sh itself only
# depends on REPO and AGENT_HOME, both set at the top of this file, so load
# order relative to them doesn't matter either way.
# shellcheck source=./notify.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/notify.sh"

# Strip run-specific noise before comparing implement failures. Keep this a
# readable canonical string, not a digest: logs remain inspectable in state.
failure_fingerprint() {
  local text="${1:-}"
  [ "$#" -lt 2 ] || text+=$'\n'"$2"
  printf '%s' "$text" | LC_ALL=C sed -E \
    -e 's#(/tmp|/var/tmp)/[^/[:space:]]+#<tmp-dir>#g' \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})?/<timestamp>/Ig' \
    -e 's/[0-9]{8}T[0-9]{6}Z?/<timestamp>/Ig' \
    -e 's/((timestamp|sampled[-_]at|recorded[-_]at|created[-_]at|time)[[:space:]_=-]+)[0-9]{10,13}/\1<timestamp>/Ig' \
    -e 's/(^|[^[:alnum:]_])[[:xdigit:]]{7,40}([^[:alnum:]_]|$)/\1<hash>\2/g' \
    -e 's/(elapsed|duration([_-]?(sec|ms))?|took)([[:space:]_=:.-]+)[0-9]+([.][0-9]+)?[[:space:]]*(milliseconds?|msecs?|ms|seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h)?/\1=<duration>/Ig' \
    -e 's/[0-9]+([.][0-9]+)?[[:space:]]*(milliseconds?|msecs?|ms|seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h)/<duration>/Ig' \
    -e 's/(issue[[:space:]]+)#[0-9]+/\1#<issue>/Ig' \
    -e 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

# Persist the shared latest implement-failure record and legacy prompt fields.
# reset_streak=1 is reserved for refunded/transient provider failures.
IMPLEMENT_FAILURE_STREAK=0
record_implement_failure() {
  local n="$1" reason="$2" evidence="$3" status="${4:-}" stage="${5:-implement}" reset_streak="${6:-0}"
  local prior old_reason old_evidence old_streak fingerprint reason_file evidence_file fingerprint_file reason_json evidence_json record_json
  prior="$(state_read "$n")" || return 1
  old_reason="$(jq -r '.last_failure_reason // ""' <<< "$prior")"
  old_evidence="$(jq -r '.last_failure_tail // ""' <<< "$prior")"
  old_streak="$(jq -r '.same_failure_streak // 0' <<< "$prior")"
  IMPLEMENT_FAILURE_STREAK="$(same_failure_streak "$old_reason" "$old_evidence" "$reason" "$evidence" "$old_streak")" || return 1
  [ "$reset_streak" != 1 ] || IMPLEMENT_FAILURE_STREAK=0
  fingerprint="$(failure_fingerprint "$reason" "$evidence")" || return 1
  reason_file="$(jq_arg_file "$reason")" || return 1
  evidence_file="$(jq_arg_file "$evidence")" || { rm -f -- "$reason_file"; return 1; }
  fingerprint_file="$(jq_arg_file "$fingerprint")" || { rm -f -- "$reason_file" "$evidence_file"; return 1; }
  reason_json="$(jq -n --rawfile value "$reason_file" '$value')" || { rm -f -- "$reason_file" "$evidence_file" "$fingerprint_file"; return 1; }
  evidence_json="$(jq -n --rawfile value "$evidence_file" '$value')" || { rm -f -- "$reason_file" "$evidence_file" "$fingerprint_file"; return 1; }
  record_json="$(jq -nc --arg stage "$stage" --arg status "$status" \
    --argjson streak "$IMPLEMENT_FAILURE_STREAK" --rawfile reason "$reason_file" \
    --rawfile evidence "$evidence_file" --rawfile fingerprint "$fingerprint_file" \
    '{stage:$stage,status:(if ($status|test("^-?[0-9]+$")) then ($status|tonumber) else null end),reason:$reason,evidence:$evidence,fingerprint:$fingerprint,same_failure_streak:$streak,recorded_at:(now|todate)}')" \
    || { rm -f -- "$reason_file" "$evidence_file" "$fingerprint_file"; return 1; }
  rm -f -- "$reason_file" "$evidence_file" "$fingerprint_file"
  state_merge "$n" ".implement_failure = $record_json | .last_failure_reason = $reason_json | .last_failure_tail = $evidence_json | .last_failure_attempt = (.attempts // 0) | .same_failure_streak = $IMPLEMENT_FAILURE_STREAK | del(.model_policy.active)"
}

# Every pipeline child sources lib.sh; disabled profiling needs no helper file.
ZF_PIPELINE_CALL_PROFILE_ENABLED=0
if [ -n "${ZF_PIPELINE_CALL_PROFILE_FILE:-}" ]; then
  # shellcheck source=./call-profile.sh
  source "${BASH_SOURCE[0]%/*}/call-profile.sh"
fi
