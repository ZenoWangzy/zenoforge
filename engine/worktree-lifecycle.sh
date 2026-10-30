#!/usr/bin/env bash
set -euo pipefail

AGENT_HOME="${AGENT_HOME:-${ZF_HOME:-${HOME:?HOME is not set}/.zenoforge}}"
NIGHT="${ZF_NIGHT_DIR:-$AGENT_HOME/night}"
WORKTREE_ROOT="${ZF_WORKTREE_ROOT:-$HOME/wt}"
MANIFEST="${ZF_WORKTREE_CLEANUP_MANIFEST:-$NIGHT/worktree-cleanup-manifest.txt}"
AGENTS_FILE="${ZF_HAND_AGENTS_FILE:-$NIGHT/agents.txt}"
REPO=""
REPO_ROOT=""
_WORKTREE_LIFECYCLE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
[[ -r "$_WORKTREE_LIFECYCLE_DIR/night/hand-exit-handoff.sh" ]] && source "$_WORKTREE_LIFECYCLE_DIR/night/hand-exit-handoff.sh"
REPO_NAME=""
ACTIVE_UNITS=""
ACTIVE_UNIT_PIDS=""
PROCESS_ARGS=""
PROCESS_CWDS_LOADED=0
declare -A PROCESS_CWD_PIDS=()
PR_ROWS=""
PR_READABLE=0
PR_ITEM_TOTAL=0
PR_ITEM_UNREADABLE=0
PR_STATE_RESULT=""
declare -A PR_BRANCH_READABLE=()
declare -A PR_HEAD_READABLE=()
declare -A PR_ITEM_COUNTED=()
PR_ROW_FIELDS='def valid_pr: type == "object" and (.number | type == "number" and . > 0 and . == floor) and (.updated_at | type == "string") and (.head.ref | type == "string") and (.head.sha | type == "string") and (.base.ref | type == "string") and (.state == "open" or .state == "closed") and (.merged_at == null or (.merged_at | type == "string")) and (.merge_commit_sha == null or (.merge_commit_sha | type == "string")); if type != "array" then error("expected pull request array") elif any(.[]; (valid_pr | not)) then error("expected pull request rows with state fields") else .[] | [.number,.updated_at,.head.ref,.head.sha,.base.ref,.state,(.merged_at // ""),(.merge_commit_sha // "")] | @tsv end'
ORIGIN_REFRESHED=0
ORIGIN_QUARANTINED_REFS=()
ORIGIN_QUARANTINED_OIDS=()
CALLER_PID=""
ALL_REPOS=()
MAIN_PATCH_IDS=""
REAP_PROGRESS_PREFIX=""
REAP_PROGRESS_CURSOR=0
REAP_SWEEP_PATHS=()
REAP_WORKTREE_BRANCH_INDEX_READY=0
declare -A REAP_WORKTREE_BRANCH_PATHS=()
HAND_OWNER_BRANCH_INDEX_READY=0
declare -A HAND_OWNER_BRANCHES=()
RESCUE_WORKTREE_INVENTORY_READY=0
RESCUE_WORKTREE_ROOTS=()
RESCUE_WORKTREE_PATHS=()
RESCUE_WORKTREE_BRANCHES=()
RESCUE_WORKTREE_LOCKED=()
declare -A RESCUE_WORKTREE_HEAD_INDEX=()
declare -A REPO_CONTAINS_CACHE=()
declare -A RESCUE_ISSUE_STATES=()
declare -A RESCUE_ISSUE_POINT_LOOKED_UP=()
declare -A RESCUE_ISSUE_COUNTED=()
RESCUE_ISSUE_STATES_LOADED=0
RESCUE_ISSUE_TOTAL=0
RESCUE_ISSUE_READABLE=0
RESCUE_ISSUE_UNREADABLE=0
HAND_RESUME_STATE=not-hand

usage() {
  echo "usage: $0 finish|finish-dispatch <repo> <worktree> | watch <repo> <worktree> <pid> <start-ticks> | reap <repo> | stats <repo> | owner-live <repo> <worktree> [caller-pid] | record <repo> <action> <name> <head> [detail] | release-cleanup <repo> <issue> <release-sha>" >&2
  exit 2
}

say() { printf 'worktree-lifecycle: %s\n' "$*" >&2; }

quarantine_missing_local_branch_refs() {
  local ref_records worktrees ref oid
  ORIGIN_QUARANTINED_REFS=()
  ORIGIN_QUARANTINED_OIDS=()
  ref_records="$(git -C "$REPO" for-each-ref --format='%(refname) %(objectname)' refs/heads)" || {
    say "origin fetch refused; local branch refs unreadable"
    return 1
  }
  [ -n "$ref_records" ] || return 0
  worktrees="$(git -C "$REPO" worktree list --porcelain)" || {
    say "origin fetch refused; worktree ownership unreadable"
    return 1
  }
  while IFS=' ' read -r ref oid; do
    [ -n "$ref" ] || continue
    [[ "$ref" == refs/heads/* && "$oid" =~ ^[0-9a-f]{40,64}$ ]] || {
      say "origin fetch refused; malformed local branch ref record"
      return 1
    }
    git -C "$REPO" cat-file -e "$oid^{commit}" 2>/dev/null && continue
    if grep -Fqx -- "branch $ref" <<< "$worktrees"; then
      say "origin fetch refused; broken local branch $ref is checked out; missing commit $oid"
      return 1
    fi
    manifest_record quarantined-broken-ref "$ref" "$oid" "missing-commit-object before origin fetch" || {
      say "origin fetch refused; could not record broken local branch $ref"
      return 1
    }
    if ! git -C "$REPO" update-ref -d "$ref" "$oid"; then
      say "origin fetch refused; broken local branch $ref changed during quarantine"
      return 1
    fi
    ORIGIN_QUARANTINED_REFS+=("$ref")
    ORIGIN_QUARANTINED_OIDS+=("$oid")
    say "quarantined missing-object local branch ref $ref=$oid"
  done <<< "$ref_records"
}

restore_quarantined_local_branch_refs() {
  local i ref oid zero_oid
  for ((i=0; i<${#ORIGIN_QUARANTINED_REFS[@]}; i++)); do
    ref="${ORIGIN_QUARANTINED_REFS[$i]}"
    oid="${ORIGIN_QUARANTINED_OIDS[$i]}"
    if ! git -C "$REPO" cat-file -e "$oid^{commit}" 2>/dev/null \
      || ! git -C "$REPO" rev-list --quiet "$oid" >/dev/null 2>&1; then
      say "left quarantined local branch ref $ref; origin did not restore complete commit $oid"
      continue
    fi
    printf -v zero_oid '%*s' "${#oid}" ''
    zero_oid="${zero_oid// /0}"
    if git -C "$REPO" update-ref "$ref" "$oid" "$zero_oid"; then
      say "restored local branch ref $ref=$oid after object recovery"
    else
      say "left concurrent local branch ref unchanged while restoring $ref"
    fi
  done
  ORIGIN_QUARANTINED_REFS=()
  ORIGIN_QUARANTINED_OIDS=()
}

refresh_origin() {
  local attempt status
  [ "$ORIGIN_REFRESHED" = 1 ] && return 0
  quarantine_missing_local_branch_refs || return 1
  for attempt in 1 2; do
    if timeout -k "${LIFECYCLE_GIT_KILL_AFTER_SECONDS:-10}" "${LIFECYCLE_GIT_TIMEOUT_SECONDS:-90}" \
      git -C "$REPO" fetch --quiet --no-tags --prune origin; then
      restore_quarantined_local_branch_refs
      ORIGIN_REFRESHED=1
      return 0
    else
      status=$?
    fi
    if [ "$attempt" -eq 2 ] || [ "$status" -eq 137 ]; then
      restore_quarantined_local_branch_refs
      say "origin fetch failed after $attempt attempt(s) (exit $status)"
      return 1
    fi
    if [ "$status" -eq 124 ]; then
      say "origin fetch timed out (exit $status); retrying once"
    else
      say "origin fetch failed (exit $status); retrying once"
    fi
    sleep 2
  done
}

pid_live() {
  local pid="$1" stat_line rest state
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null || return 1
  IFS= read -r stat_line < "/proc/$pid/stat" 2>/dev/null || return 1
  rest="${stat_line##*) }"
  read -r state _ <<< "$rest"
  [ "$state" != Z ]
}

pid_start_ticks() {
  local pid="$1" stat_line rest
  IFS= read -r stat_line < "/proc/$pid/stat" 2>/dev/null || return 1
  rest="${stat_line##*) }"
  awk '{print $20}' <<< "$rest"
}

manifest_record() {
  local action="$1" name="$2" head="$3" detail="${4:-}"
  mkdir -p -- "$(dirname -- "$MANIFEST")" || return 1
  exec 9>>"$MANIFEST" || return 1
  flock -x 9 || return 1
  if [ ! -s "$MANIFEST" ]; then
    printf 'time_utc\taction\tname\thead_sha\tdetail\n' >&9 || return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$action" "$name" "$head" "$detail" >&9 || return 1
  flock -u 9 || true
  exec 9>&-
}

record_kept_worktree() {
  local target="$1" head="$2" reason="$3"
  [[ "$head" =~ ^[0-9a-f]{40,64}$ ]] || return 0
  manifest_record kept-worktree "$(basename -- "$target")" "$head" "path=$target;reason=$reason"
}

reap_path_audit() {
  local type="$1" path="$2" owner="$3" dirty="$4" stash="$5" pr="$6" ancestry="$7"
  local disposition="$8" recoverable="$9" reason="${10}" head="${11}" age="${12}"
  [ "$age" = yes ] || return 0
  manifest_record reap-path-audit "$(basename -- "$path")" "$head" \
    "type=$type;path=$path;age-over-24h=yes;owner=$owner;dirty=$dirty;stash=$stash;pr=$pr;ancestry=$ancestry;disposition=$disposition;recoverable=$recoverable;reason=$reason" || return 1
  say "reap-path type=$type path=$path owner=$owner dirty=$dirty stash=$stash pr=$pr ancestry=$ancestry disposition=$disposition recoverable=$recoverable reason=$reason head=$head age-over-24h=yes"
}

record_external() {
  local action="$1" name="$2" head="$3" detail="${4:-}"
  [[ "$action" =~ ^[a-z][a-z0-9-]*$ && -n "$name" && "$head" =~ ^[0-9a-f]{40,64}$ ]] || return 2
  [[ "$name$detail" != *$'\t'* && "$name$detail" != *$'\n'* && "$name$detail" != *$'\r'* ]] || return 2
  manifest_record "$action" "$name" "$head" "$detail"
}

hand_file_mtime_ns() {
  local stamp value
  stamp="$(stat -c %y -- "$1" 2>/dev/null || true)"
  [ -n "$stamp" ] || return 1
  value="$(date -d "$stamp" +%s%N 2>/dev/null || true)"
  [[ "$value" =~ ^[0-9]{19}$ ]] || return 1
  printf '%s\n' "$value"
}

# Return 0 only when a hand run still needs its worktree for resume.
# Roster order is authoritative; owner and blocked-agent records cover rows
# already removed by the exit watcher.
hand_worktree_resume_decision() {
  local target="$1" head="$2" row row_pid row_name row_model row_effort row_worktree row_brief row_report row_log
  local row_attempt row_started row_role row_ticks row_issues row_nodes context=0 source="" name="" report="" started_ns=""
  local owner owner_target owner_report owner_started owner_mtime owner_best=0 ledger="$NIGHT/blocked-hand-agents.json"
  local ledger_entry ledger_report ledger_started ledger_blocked_at ledger_dependency ledger_fields report_mtime_ns=0
  local status_line="" report_status="" status_current=0 expiry_anchor_ns=0 anchor_seconds now_seconds expiry_seconds
  HAND_RESUME_STATE=not-hand
  [ -d "$target" ] || return 1
  target="$(realpath -m -- "$target")"

  if [ -r "$AGENTS_FILE" ]; then
    while IFS= read -r row || [ -n "$row" ]; do
      [[ "$row" == *$'\t'* ]] || continue
      IFS=$'\x1f' read -r row_pid row_name row_model row_effort row_worktree row_brief row_report row_log \
        row_attempt row_started row_role row_ticks row_issues row_nodes \
        <<< "${row//$'\t'/$'\x1f'}"
      [ "$row_worktree" = "$target" ] || continue
      context=1
      source=roster
      name="$row_name"
      report="$row_report"
      started_ns="$row_started"
    done < "$AGENTS_FILE"
  fi

  if [ "$context" = 0 ]; then
    for owner in "$NIGHT"/.hand-owner-*; do
      [ -f "$owner" ] || continue
      IFS= read -r owner_target < "$owner" || true
      [ "$(realpath -m -- "$owner_target")" = "$target" ] || continue
      owner_report="$(sed -n '4p' "$owner" 2>/dev/null || true)"
      owner_started="$(sed -n '5p' "$owner" 2>/dev/null || true)"
      if ! [[ "$owner_started" =~ ^[0-9]{19}$ ]]; then
        owner_mtime="$(hand_file_mtime_ns "$owner" 2>/dev/null || true)"
        [[ "$owner_mtime" =~ ^[0-9]{19}$ ]] && owner_started="$owner_mtime"
      fi
      if [[ "$owner_started" =~ ^[0-9]{19}$ ]] && (( owner_started >= owner_best )); then
        context=1
        source=owner
        owner_best="$owner_started"
        name=""
        report="$owner_report"
        started_ns="$owner_started"
      fi
    done
  fi

  if [ -s "$ledger" ] && { [ "$context" = 0 ] || { [ "$source" = owner ] && [ -z "$report" ]; }; }; then
    ledger_entry="$(jq -cer --arg target "$target" \
      '[.[] | select(.worktree == $target)] | sort_by([.blocked_at // 0, .attempt // 0]) | last // empty' \
      "$ledger" 2>/dev/null || true)"
    if [ -n "$ledger_entry" ]; then
      ledger_fields="$(jq -r '[.report // "", (.attempt_started_at_ns // ""), (.blocked_at // 0 | tostring), (.dependency // "")] | @tsv' <<< "$ledger_entry")"
      IFS=$'\x1f' read -r ledger_report ledger_started ledger_blocked_at ledger_dependency \
        <<< "${ledger_fields//$'\t'/$'\x1f'}"
      if [ "$context" = 0 ]; then
        context=1
        source=ledger
        report="$ledger_report"
        started_ns="$ledger_started"
      elif [ -z "$report" ]; then
        report="$ledger_report"
        [[ "$started_ns" =~ ^[0-9]{19}$ ]] || started_ns="$ledger_started"
      fi
    fi
  fi
  [ "$context" = 1 ] || return 1

  if [ -z "$report" ] && [ "$source" = roster ] && [ -n "$name" ]; then
    report="$NIGHT/$name-report.md"
  fi
  case "$report" in "~/"*) report="$HOME/${report:2}" ;; esac
  if [ -n "$report" ] && [ -f "$report" ]; then
    report_mtime_ns="$(hand_file_mtime_ns "$report" 2>/dev/null || true)"
    [[ "$report_mtime_ns" =~ ^[0-9]{19}$ ]] || report_mtime_ns=0
    # The first STATUS line is the report contract, as the bell and supervisor read it. 2026-10-03:
    # hand-2252 wrote BLOCKED-ON first and FOLLOWUP last; reading the last line removed its worktree.
    status_line="$(grep -m1 -E '^STATUS(:|[[:space:]])' "$report" 2>/dev/null || true)"
    case "$status_line" in
      'STATUS:'*) report_status="${status_line#STATUS:}" ;;
      'STATUS '*) report_status="${status_line#STATUS }" ;;
    esac
    report_status="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<< "$report_status")"
  fi

  if [[ "$started_ns" =~ ^[0-9]{19}$ && "$report_mtime_ns" =~ ^[0-9]{19}$ ]]; then
    if (( report_mtime_ns >= started_ns )); then status_current=1; else report_status=""; fi
  elif [ "$source" = ledger ] && [ -n "$ledger_dependency" ]; then
    report_status="BLOCKED-ON $ledger_dependency"
  else
    report_status=""
  fi
  if [[ -n "$name" ]] && hand_addendum_pending_for_report "$name" "$report"; then
    HAND_RESUME_STATE=pending
    record_kept_worktree "$target" "$head" "resume-pending:addendum" || true
    return 0
  fi
  if [ "$status_current" = 1 ] && [[ "$report_status" =~ ^FOLLOWUP\(.*\)$ ]] && [ -r "$ledger" ]; then
    ledger_entry="$(jq -cer --arg target "$target" \
      '[.[] | select(.worktree == $target and ((.dependency // "") | startswith("followup ")))] | last // empty' \
      "$ledger" 2>/dev/null || true)"
    if [ -n "$ledger_entry" ]; then
      HAND_RESUME_STATE=pending
      record_kept_worktree "$target" "$head" "resume-pending:$report_status" || true
      return 0
    fi
  fi
  if [ "$status_current" = 1 ] \
    && { [ "$report_status" = DONE ] || [[ "$report_status" =~ ^FOLLOWUP\(.*\)$ ]]; }; then
    HAND_RESUME_STATE=terminal
    return 1
  fi
  [ -n "$report_status" ] || report_status=none
  report_status="${report_status//$'\t'/ }"
  report_status="${report_status//$'\n'/ }"

  [[ "$started_ns" =~ ^[0-9]{19}$ ]] && expiry_anchor_ns="$started_ns"
  if [[ "$report_mtime_ns" =~ ^[0-9]{19}$ ]] && (( report_mtime_ns > expiry_anchor_ns )); then
    expiry_anchor_ns="$report_mtime_ns"
  fi
  if [ "$expiry_anchor_ns" -eq 0 ] && [[ "${ledger_blocked_at:-}" =~ ^[0-9]+$ ]] && (( ledger_blocked_at > 0 )); then
    expiry_anchor_ns="$((ledger_blocked_at * 1000000000))"
  fi
  expiry_seconds="${REAP_STALE_SECONDS:-86400}"
  [[ "$expiry_seconds" =~ ^[0-9]+$ ]] || expiry_seconds=86400
  now_seconds="$(date +%s)"
  if [ "$expiry_anchor_ns" -gt 0 ]; then
    anchor_seconds=$((expiry_anchor_ns / 1000000000))
    if (( now_seconds - anchor_seconds > expiry_seconds )); then
      HAND_RESUME_STATE=expired
      return 1
    fi
  fi

  HAND_RESUME_STATE=pending
  record_kept_worktree "$target" "$head" "resume-pending:$report_status" || true
  return 0
}

repo_contains() {
  local head="$1"
  [ "${REPO_CONTAINS_CACHE[$head]:-}" = 1 ] && return 0
  git -C "$REPO" for-each-ref --contains="$head" --format='%(refname)' refs/remotes/origin 2>/dev/null \
    | awk 'END { exit NR > 0 ? 0 : 1 }' && REPO_CONTAINS_CACHE[$head]=1
}

merged_pr_content_is_reachable() {
  local branch="$1" head="$2" pr_branch pr_head base state merged merge_commit
  [ -n "$branch" ] || return 1
  while IFS=$'\t' read -r pr_branch pr_head base state merged merge_commit; do
    [ "$pr_branch" = "$branch" ] && [ "$pr_head" = "$head" ] \
      && [ "$base" = main ] && [ "$state" = closed ] && [ -n "$merged" ] \
      && [ -n "$merge_commit" ] || continue
    git -C "$REPO" merge-base --is-ancestor "$merge_commit" origin/main 2>/dev/null && return 0
  done <<< "$PR_ROWS"
  return 1
}

# Direct landings rebase the branch, so main holds the same patches under new SHAs.
patches_in_main() {
  local cherry
  cherry="$(git -C "$REPO" cherry origin/main "$1" 2>/dev/null)" || return 1
  ! grep -q '^+' <<< "$cherry"
}

head_content_is_preserved() {
  local branch="$1" head="$2"
  repo_contains "$head" || patches_in_main "$head" || merged_pr_content_is_reachable "$branch" "$head"
}

rescue_ref_for() {
  local name="$1" head="$2" slug
  if [[ "$name" =~ ^agent/issue-([0-9]+)$ ]]; then
    printf 'refs/heads/rescued/agent-issue-%s-%s\n' "${BASH_REMATCH[1]}" "$head"
    return 0
  fi
  slug="$(sed -E 's#[^A-Za-z0-9._-]+#-#g; s#^-+##; s#-+$##' <<< "${name:-worktree}")"
  slug="${slug:0:72}"
  printf 'refs/heads/rescued/%s\n' "${slug:-worktree}"
}

push_rescue() {
  local name="$1" head="$2" rescue_ref remote_head base_ref
  rescue_ref="$(rescue_ref_for "$name" "$head")"
  remote_head="$(git -C "$REPO" ls-remote origin "$rescue_ref" 2>/dev/null | awk 'NR==1{print $1}')"
  if [ -n "$remote_head" ] && [ "$remote_head" != "$head" ]; then
    if [[ "$name" =~ ^agent/issue-[0-9]+$ ]]; then
      manifest_record kept-unrescued "$name" "$head" "rescue-ref-head-mismatch:$rescue_ref" || true
      say "kept $name at $head; issue rescue ref already points elsewhere ($rescue_ref)"
      return 1
    fi
    base_ref="$rescue_ref"
    rescue_ref="${base_ref}-${head:0:12}"
  fi
  if ! git -C "$REPO" push origin "$head:$rescue_ref" >/dev/null; then
    manifest_record kept-unrescued "$name" "$head" "rescue-push-failed:$rescue_ref" || true
    say "kept $name at $head; rescue push failed"
    return 1
  fi
  remote_head="$(git -C "$REPO" ls-remote origin "$rescue_ref" 2>/dev/null | awk 'NR==1{print $1}')"
  if [ "$remote_head" != "$head" ]; then
    say "kept $name at $head; rescue ref readback mismatch ($rescue_ref)"
    return 1
  fi
  git -C "$REPO" update-ref "refs/remotes/origin/${rescue_ref#refs/heads/}" "$head" || return 1
  manifest_record rescued "${name:-worktree}" "$head" "origin/${rescue_ref#refs/heads/}" || return 1
  say "rescued $name at $head to origin/${rescue_ref#refs/heads/}"
}

registered_worktree_record() {
  local target="$1" records line in_tree=0
  records="$(git -C "$REPO" worktree list --porcelain)" || return 1
  local found_path="" found_head="" found_branch="" found_locked=0 found_lock_reason=""
  while IFS= read -r line; do
    case "$line" in
      'worktree '*)
        if [ "$in_tree" = 1 ] && [ "$found_path" = "$target" ]; then
          printf '%s\t%s\t%s\t%s\t%s\n' "$found_head" "${found_branch:-(detached)}" "$found_locked" "$found_lock_reason" "$found_path"
          return 0
        fi
        in_tree=1; found_path="${line#worktree }"; found_head=""; found_branch=""; found_locked=0; found_lock_reason=""
        ;;
      'HEAD '*) [ "$in_tree" = 1 ] && found_head="${line#HEAD }" ;;
      'branch '*) [ "$in_tree" = 1 ] && found_branch="${line#branch refs/heads/}" ;;
      locked*)
        if [ "$in_tree" = 1 ]; then
          found_locked=1
          found_lock_reason="${line#locked}"
          found_lock_reason="${found_lock_reason# }"
        fi
        ;;
      '')
        if [ "$in_tree" = 1 ] && [ "$found_path" = "$target" ]; then
          printf '%s\t%s\t%s\t%s\t%s\n' "$found_head" "${found_branch:-(detached)}" "$found_locked" "$found_lock_reason" "$found_path"
          return 0
        fi
        in_tree=0
        ;;
    esac
  done <<< "$records"
  if [ "$in_tree" = 1 ] && [ "$found_path" = "$target" ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$found_head" "${found_branch:-(detached)}" "$found_locked" "$found_lock_reason" "$found_path"
    return 0
  fi
  return 1
}

primary_worktree_path() {
  git -C "$REPO" worktree list --porcelain \
    | awk '/^worktree / { print substr($0, 10); exit }'
}

remove_local_branch() {
  local branch="$1" head="$2" branch_head
  [ -n "$branch" ] && [ "$branch" != main ] || return 0
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || return 0
  branch_head="$(git -C "$REPO" rev-parse --verify "refs/heads/$branch" 2>/dev/null || true)"
  [ "$branch_head" = "$head" ] || { say "left local branch $branch; its head moved from $head"; return 2; }
  if ! head_content_is_preserved "$branch" "$head"; then
    say "left local branch $branch; $head has no origin or merged-PR ref"
    return 2
  fi
  manifest_record removing-local-branch "$branch" "$head" || return 1
  if git -C "$REPO" branch -d -- "$branch" >/dev/null 2>&1; then
    manifest_record removed-local-branch "$branch" "$head" || return 1
    say "removed local branch $branch at $head"
    return 0
  fi
  # -D is allowed only after clean status and exact origin/merged-PR proof.
  branch_head="$(git -C "$REPO" rev-parse --verify "refs/heads/$branch" 2>/dev/null || true)"
  if [ "$branch_head" = "$head" ] && head_content_is_preserved "$branch" "$head"; then
    if git -C "$REPO" branch -D -- "$branch" >/dev/null 2>&1; then
      manifest_record removed-local-branch "$branch" "$head" "safety-checked-remote-ref" || return 1
      say "removed local branch $branch at $head (remote ref verified)"
      return 0
    fi
  fi
  say "left local branch $branch; Git refused safe deletion"
  return 2
}

record_pipeline_resume_checkpoint() {
  local branch="$1" head="$2" issue rescue_ref state head_json lib_path lifecycle_repo="$REPO"
  [[ "$branch" =~ ^agent/issue-([0-9]+)$ ]] || return 0
  issue="${BASH_REMATCH[1]}"
  rescue_ref="refs/remotes/origin/rescued/agent-issue-$issue-$head"
  [ "$(git -C "$REPO" rev-parse --verify "$rescue_ref" 2>/dev/null || true)" = "$head" ] || return 0
  if ! declare -F state_merge_attempt_transition >/dev/null; then
    lib_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"
    # shellcheck source=./lib.sh
    source "$lib_path"
    REPO="$lifecycle_repo"
  fi
  state="$(state_read "$issue")" || return 1
  jq -e 'type == "object"' <<< "$state" >/dev/null 2>&1 || return 1
  head_json="$(jq -n --arg sha "$head" '$sha')" || return 1
  if jq -e '.pipeline_system.enabled == true' <<< "$state" >/dev/null 2>&1; then
    state_merge_attempt_transition "$issue" ".pipeline_system.resume_artifact_sha = $head_json" || return 1
  elif jq -e '.model_policy.repair_resume.head_sha? != null' <<< "$state" >/dev/null 2>&1; then
    state_merge "$issue" ".model_policy.repair_resume.head_sha = $head_json" || return 1
  else
    return 0
  fi
  say "recorded issue #$issue resume checkpoint at $head"
}

finish_worktree() {
  local target="$1" record_resume="${2:-0}" record head branch locked lock_reason lock_status worktree_root status rescue_name primary
  [ -n "$target" ] || return 0
  target="$(realpath -m -- "$target")"
  if [ "$#" -ge 4 ]; then primary="$4"; else primary="$(primary_worktree_path)"; fi
  if [ "$target" = "$REPO_ROOT" ] || [ "$target" = "$primary" ]; then
    say "refused primary checkout $target"
    return 2
  fi
  if [ "$#" -ge 3 ]; then record="$3"; else record="$(registered_worktree_record "$target" 2>/dev/null || true)"; fi
  if [ -z "$record" ]; then
    [ -e "$target" ] || return 0
    head="$(git -C "$target" rev-parse --verify HEAD 2>/dev/null || true)"
    record_kept_worktree "$target" "$head" unregistered-path || true
    say "kept unregistered path $target"
    return 2
  fi
  IFS=$'\t' read -r head branch locked lock_reason _ <<< "$record"
  if [ "$locked" = 1 ]; then
    if ! load_live_state; then
      record_kept_worktree "$target" "$head" lock-owner-inventory-unreadable || true
      say "kept $target; lock owner inventory unreadable"
      return 2
    fi
    worktree_lock_state "$target" "$lock_reason" || lock_status=$?
    case "${lock_status:-0}" in
      0)
        record_kept_worktree "$target" "$head" live-lock-owner || true
        say "kept locked worktree $target; owner is live"
        return 2
        ;;
      1)
        if ! git -C "$REPO" worktree unlock "$target"; then
          record_kept_worktree "$target" "$head" unlock-refused || true
          say "kept locked worktree $target; unlock refused"
          return 2
        fi
        say "released dead or expired worktree lock $target"
        ;;
      *)
        record_kept_worktree "$target" "$head" lock-owner-unknown || true
        say "kept locked worktree $target; owner state unknown or lock younger than 24h"
        return 2
        ;;
    esac
    lock_status=""
  fi
  if [ -d "$target" ]; then
    if ! worktree_root="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)" || [ "$(realpath -m -- "$worktree_root")" != "$target" ]; then
      record_kept_worktree "$target" "$head" unreadable-worktree || true
      say "kept unreadable worktree $target"
      return 2
    fi
    head="$(git -C "$target" rev-parse --verify HEAD 2>/dev/null)" || {
      record_kept_worktree "$target" "$head" unreadable-head || true
      say "kept $target; HEAD unreadable"
      return 2
    }
    if ! load_live_state; then
      record_kept_worktree "$target" "$head" owner-inventory-unreadable || true
      say "kept $target; owner inventory unreadable"
      return 2
    fi
    if worktree_owner_live "$target"; then
      record_kept_worktree "$target" "$head" live-process || true
      say "kept $target; live process still uses it"
      return 2
    fi
    if hand_worktree_resume_decision "$target" "$head"; then
      say "kept hand worktree $target; resume pending"
      return 2
    fi
    status="$(git -C "$target" status --porcelain=v1 --untracked-files=all 2>/dev/null)" || {
      record_kept_worktree "$target" "$head" git-status-failed || true
      say "kept $target; git status failed"
      return 2
    }
    if [ -n "$status" ]; then
      record_kept_worktree "$target" "$head" uncommitted-or-untracked || true
      say "kept $target; uncommitted or untracked files remain"
      return 2
    fi
    branch="$(git -C "$target" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    rescue_name="${branch:-$(basename -- "$target")}"
  else
    record_kept_worktree "$target" "$head" missing-path || true
    say "kept stale worktree entry $target; missing entries need explicit inventory"
    return 2
  fi
  # Removal never waits on the network. Local origin refs already prove a pushed or landed head; only
  # commits no local origin ref holds need a fetch and a rescue push, and without origin they stay.
  # 2026-10-21/22: a fetch-first gate kept every finished triage, advisor and hand worktree whenever
  # the proxy stalled (419 kept, 0 removed by run-end cleanup in 26 h; 287 left under ~/wt).
  if ! head_content_is_preserved "$branch" "$head"; then
    refresh_origin || {
      record_kept_worktree "$target" "$head" unique-commits-origin-unreachable || true
      say "kept $target; $head has commits no local origin ref holds and origin fetch failed"
      return 2
    }
    if ! head_content_is_preserved "$branch" "$head"; then
      push_rescue "$rescue_name" "$head" || {
        record_kept_worktree "$target" "$head" rescue-failed || true
        return 2
      }
    fi
  fi
  if [ "$record_resume" = 1 ] && ! record_pipeline_resume_checkpoint "$branch" "$head"; then
    record_kept_worktree "$target" "$head" resume-checkpoint-write-failed || true
    say "kept $target; resume checkpoint write failed"
    return 2
  fi
  manifest_record removing-worktree "$(basename -- "$target")" "$head" "path=$target" || return 1
  if ! git -C "$REPO" worktree remove "$target"; then
    record_kept_worktree "$target" "$head" remove-refused || true
    say "kept $target; ordinary git worktree remove refused"
    return 2
  fi
  manifest_record removed-worktree "$(basename -- "$target")" "$head" "path=$target" || return 1
  say "removed worktree $target at $head"
  remove_local_branch "$branch" "$head" || true
}

clone_is_clean() {
  local target="$1" status stash
  local timeout_seconds="${LIFECYCLE_GIT_TIMEOUT_SECONDS:-${WORKTREE_REAP_GIT_TIMEOUT_SECONDS:-12}}"
  local kill_after_seconds="${LIFECYCLE_GIT_KILL_AFTER_SECONDS:-2}"
  CLONE_CLEAN_REASON=unreadable-status
  CLONE_STASH_DETAIL=unknown
  if ! status="$(timeout -k "$kill_after_seconds" "$timeout_seconds" \
    git -C "$target" status --porcelain=v1 --untracked-files=all 2>/dev/null)"; then
    return 2
  fi
  if [ -n "$status" ]; then
    CLONE_CLEAN_REASON=dirty
    CLONE_STASH_DETAIL=not-checked
    return 1
  fi
  CLONE_CLEAN_REASON=unreadable-stash
  if ! stash="$(timeout -k "$kill_after_seconds" "$timeout_seconds" \
    git -C "$target" stash list 2>/dev/null)"; then
    return 2
  fi
  if [ -n "$stash" ]; then
    CLONE_CLEAN_REASON=stashed
    CLONE_STASH_DETAIL="${stash%%:*}"
    return 1
  fi
  CLONE_CLEAN_REASON=clean
  CLONE_STASH_DETAIL=none
  return 0
}

finish_clone() {
  local caller_repo="$REPO"
  local target="$1" top status head branch rescue_name live_checkout caller_repo_root="$REPO_ROOT"
  local origin_preverified="${2:-0}" REPO REPO_ROOT ORIGIN_REFRESHED=0
  local clean_status
  target="$(realpath -m -- "$target")"
  live_checkout="$(realpath -m -- "$AGENT_HOME/checkout")"
  if [ "$target" = "$caller_repo_root" ] || [ "$target" = "$live_checkout" ]; then
    say "refused live checkout $target"
    return 2
  fi
  [ -d "$target/.git" ] || { say "kept non-clone path $target"; return 2; }
  top="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null || true)"
  [ "$(realpath -m -- "$top")" = "$target" ] || { say "kept non-root clone path $target"; return 2; }
  load_live_state || { say "kept clone $target; owner inventory unreadable"; return 2; }
  if worktree_owner_live "$target"; then say "kept clone $target; live owner still uses it"; return 2; fi
  if clone_is_clean "$target"; then
    :
  else
    clean_status=$?
    if [ "$clean_status" -eq 2 ]; then
      say "kept clone $target; git status or stash list failed or timed out"
      return 2
    fi
    head="$(git -C "$target" rev-parse --verify HEAD 2>/dev/null || true)"
    record_kept_worktree "$target" "$head" dirty-clone || true
    say "kept clone $target; uncommitted files or stash remain"
    return 2
  fi
  head="$(git -C "$target" rev-parse --verify HEAD 2>/dev/null)" || { say "kept clone $target; HEAD unreadable"; return 2; }
  branch="$(git -C "$target" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  rescue_name="${branch:-$(basename -- "$target")}"
  if [ "$origin_preverified" = 1 ]; then
    REPO="$caller_repo"
    if ! head_content_is_preserved "$branch" "$head"; then
      REPO="$target"
      REPO_ROOT="$target"
      refresh_origin || { record_kept_worktree "$target" "$head" origin-fetch-failed || true; say "kept clone $target; origin fetch failed"; return 2; }
      if ! head_content_is_preserved "$branch" "$head"; then
        push_rescue "$rescue_name" "$head" || { record_kept_worktree "$target" "$head" rescue-failed || true; return 2; }
      fi
    fi
  else
    REPO="$target"
    REPO_ROOT="$target"
    head_content_is_preserved "$branch" "$head" \
      || refresh_origin || { record_kept_worktree "$target" "$head" unique-commits-origin-unreachable || true; say "kept clone $target; unique commits and origin fetch failed"; return 2; }
    if ! head_content_is_preserved "$branch" "$head"; then
      push_rescue "$rescue_name" "$head" || { record_kept_worktree "$target" "$head" rescue-failed || true; return 2; }
    fi
  fi
  manifest_record removing-clone "$(basename -- "$target")" "$head" "path=$target" || return 1
  rm -rf -- "$target" || { record_kept_worktree "$target" "$head" remove-refused || true; return 2; }
  manifest_record removed-clone "$(basename -- "$target")" "$head" "path=$target" || return 1
  say "removed clone $target at $head"
}

finish_dispatch() {
  local target="$1" record
  target="$(realpath -m -- "$target")"
  record="$(registered_worktree_record "$target" 2>/dev/null || true)"
  if [ -n "$record" ]; then
    finish_worktree "$target"
  else
    finish_clone "$target"
  fi
}

load_live_state() {
  local record active_names active_pid_lines active_pid owner owner_pid owner_branch
  local -a active_unit_names=()
  ACTIVE_UNITS="$(timeout "${LIFECYCLE_SYSTEMCTL_TIMEOUT_SECONDS:-20}" systemctl --user list-units --state=active --no-legend --plain 'zf-*' 'sup-land-*' 2>/dev/null)" || return 1
  ACTIVE_UNIT_PIDS=""
  active_names="$(awk 'NF {print $1}' <<< "$ACTIVE_UNITS")"
  if [ -n "$active_names" ]; then
    while IFS= read -r record; do [ -n "$record" ] && active_unit_names+=("$record"); done <<< "$active_names"
    active_pid_lines="$(timeout "${LIFECYCLE_SYSTEMCTL_TIMEOUT_SECONDS:-20}" systemctl --user show --property=MainPID --value "${active_unit_names[@]}" 2>/dev/null)" || return 1
    while IFS= read -r active_pid; do
      active_pid="${active_pid#MainPID=}"
      [[ "$active_pid" =~ ^[1-9][0-9]*$ ]] && ACTIVE_UNIT_PIDS+="$active_pid"$'\n'
    done <<< "$active_pid_lines"
  fi
  PROCESS_ARGS="$(ps -eo pid=,args= 2>/dev/null)" || return 1
  HAND_OWNER_BRANCHES=()
  HAND_OWNER_BRANCH_INDEX_READY=0
  for owner in "$NIGHT"/.hand-owner-*; do
    [ -f "$owner" ] || continue
    owner_pid="${owner##*.hand-owner-}"
    owner_branch="$(sed -n '3p' "$owner" 2>/dev/null || true)"
    [ -n "$owner_branch" ] && pid_live "$owner_pid" && HAND_OWNER_BRANCHES["$owner_branch"]=1
  done
  HAND_OWNER_BRANCH_INDEX_READY=1
  if [ -e "$AGENTS_FILE" ] && [ ! -r "$AGENTS_FILE" ]; then return 1; fi
  PROCESS_CWDS_LOADED=0
  PROCESS_CWD_PIDS=()
}

load_process_cwds() {
  local entry pid cwd ancestor
  [ "$PROCESS_CWDS_LOADED" = 1 ] && return 0
  PROCESS_CWDS_LOADED=1
  # One find replaces one readlink process per PID; reaper checks many owner paths per pass.
  while IFS= read -r -d '' entry; do
    [[ "$entry" == *' -> '* ]] || continue
    pid="${entry#/proc/}"
    pid="${pid%%/cwd -> *}"
    cwd="${entry#* -> }"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
    cwd="${cwd% (deleted)}"
    [ -n "$cwd" ] || continue
    ancestor="$cwd"
    while [[ "$ancestor" == /* ]]; do
      PROCESS_CWD_PIDS["$ancestor"]="${PROCESS_CWD_PIDS["$ancestor"]:-} $pid"
      [ "$ancestor" != / ] || break
      ancestor="${ancestor%/*}"
      [ -n "$ancestor" ] || ancestor=/
    done
  done < <(find /proc/[0-9]*/cwd -maxdepth 0 -type l -printf '%p -> %l\0' 2>/dev/null)
}

unit_is_active() {
  local unit="$1" recorded_lock_owner="${2:-0}" main_pid
  awk -v unit="$unit" '$1 == unit { found=1 } END { exit !found }' <<< "$ACTIVE_UNITS" || return 1
  if [[ "$CALLER_PID" =~ ^[1-9][0-9]*$ && "$recorded_lock_owner" != 1 ]]; then
    main_pid="$(timeout 5 systemctl --user show --property=MainPID --value "$unit" 2>/dev/null || true)"
    caller_pid_or_ancestor "$main_pid" && return 1
  fi
  return 0
}

caller_pid_or_ancestor() {
  local candidate="$1" current="$CALLER_PID" stat_line rest state parent
  [[ "$candidate" =~ ^[1-9][0-9]*$ && "$current" =~ ^[1-9][0-9]*$ ]] || return 1
  while [[ "$current" =~ ^[1-9][0-9]*$ ]]; do
    [ "$candidate" = "$current" ] && return 0
    [ "$current" -gt 1 ] || break
    IFS= read -r stat_line < "/proc/$current/stat" 2>/dev/null || break
    rest="${stat_line##*) }"
    read -r state parent _ <<< "$rest"
    [[ "$parent" =~ ^[1-9][0-9]*$ && "$parent" != "$current" ]] || break
    current="$parent"
  done
  return 1
}

worktree_lock_state() {
  local target="$1" reason="$2" unit owner_pid owner_ticks current_ticks locked_file created age now has_owner=0
  if [[ "$reason" =~ (^|[[:space:]:])unit=([^[:space:]]+) ]]; then
    unit="${BASH_REMATCH[2]}"
    if [[ "$unit" != zf-worktree-cleanup-* ]]; then
      has_owner=1
      unit_is_active "$unit" 1 && return 0
      if [[ "$unit" != *.service && "$unit" != *.scope ]]; then
        unit_is_active "$unit.service" 1 && return 0
        unit_is_active "$unit.scope" 1 && return 0
      fi
    fi
  fi
  if [[ "$reason" =~ (^|[[:space:]:])owner_pid=([0-9]+) ]]; then
    owner_pid="${BASH_REMATCH[2]}"
  else
    owner_pid=""
  fi
  if [[ "$reason" =~ (^|[[:space:]:])owner_start_ticks=([0-9]+) ]]; then
    owner_ticks="${BASH_REMATCH[2]}"
  else
    owner_ticks=""
  fi
  if [[ "$owner_pid" =~ ^[1-9][0-9]*$ && "$owner_ticks" =~ ^[0-9]+$ ]]; then
    has_owner=1
    if pid_live "$owner_pid"; then
      current_ticks="$(pid_start_ticks "$owner_pid" 2>/dev/null || true)"
      [ "$current_ticks" = "$owner_ticks" ] && return 0
    fi
  fi
  if [ "$has_owner" = 1 ]; then
    return 1
  fi
  locked_file="$(git -C "$target" rev-parse --git-path locked 2>/dev/null)" || return 2
  [[ "$locked_file" = /* ]] || locked_file="$target/$locked_file"
  created="$(stat -c %Y -- "$locked_file" 2>/dev/null || true)"
  [[ "$created" =~ ^[0-9]+$ ]] || return 2
  now="$(date +%s)"
  age=$((now - created))
  [ "$age" -ge "${REAP_STALE_SECONDS:-86400}" ] && return 1
  return 2
}

cwd_owner_live() {
  local target="$1" pid
  load_process_cwds
  for pid in ${PROCESS_CWD_PIDS["$target"]:-}; do
    caller_pid_or_ancestor "$pid" && continue
    cleanup_watcher_pid "$pid" && continue
    pid_live "$pid" && return 0
  done
  return 1
}

cleanup_watcher_pid() {
  local wanted="$1" row pid args
  while IFS= read -r row; do
    read -r pid args <<< "$row"
    [ "$pid" = "$wanted" ] || continue
    [[ "$args" == *"worktree-lifecycle.sh watch "* ]] && return 0
  done <<< "$PROCESS_ARGS"
  return 1
}

process_owner_live() {
  local target="$1" row pid owner_worktree args
  if [ -r "$AGENTS_FILE" ]; then
    while IFS= read -r row || [ -n "$row" ]; do
      IFS=$'\t' read -r pid _ _ _ owner_worktree _ <<< "$row"
      if [ "$owner_worktree" = "$target" ] && ! caller_pid_or_ancestor "$pid" && pid_live "$pid"; then return 0; fi
    done < "$AGENTS_FILE"
  fi
  for row in "$NIGHT"/.hand-owner-*; do
    [ -f "$row" ] || continue
    pid="${row##*.hand-owner-}"
    IFS= read -r owner_worktree < "$row" || true
    if [ "$owner_worktree" = "$target" ] && ! caller_pid_or_ancestor "$pid" && pid_live "$pid"; then return 0; fi
  done
  cwd_owner_live "$target" && return 0
  while IFS= read -r row; do
    read -r pid args <<< "$row"
    [[ "$args" == *"worktree-lifecycle.sh watch "* ]] && continue
    if [[ "$args" != *"--cd $target"* && "$args" != *"--cd=$target"* \
      && "$args" != *"night/dispatch.sh $target "* ]]; then
      [[ "$args" == *"$target"* ]] || continue
      grep -Fxq -- "$pid" <<< "$ACTIVE_UNIT_PIDS" || continue
    fi
    caller_pid_or_ancestor "$pid" && continue
    [[ "$args" == *"--cd $target"* || "$args" == *"--cd=$target"* ]] && pid_live "$pid" && return 0
    if grep -Fxq -- "$pid" <<< "$ACTIVE_UNIT_PIDS" && [[ "$args" == *"$target"* ]] && pid_live "$pid"; then
      return 0
    fi
    if [[ "$args" == *"night/dispatch.sh $target "* ]] && pid_live "$pid"; then
      return 0
    fi
  # Every match above needs $target in the args; prefilter instead of a bash pass over ~600 processes per worktree.
  done <<< "$(grep -F -- "$target" <<< "$PROCESS_ARGS")"
  return 1
}

branch_unit_live() {
  local branch="$1" issue="" base unit
  case "$branch" in
    agent/issue-*) issue="${branch#agent/issue-}"; base=implement ;;
    triage-*) issue="${branch#triage-}"; base=triage ;;
    advisor-*) issue="${branch#advisor-}"; base=advisor ;;
    recut-*) issue="${branch#recut-}"; base=recut ;;
    *) return 1 ;;
  esac
  [[ "$issue" =~ ^[0-9]+$ ]] || return 1
  unit="zf-$base-$issue.service"
  unit_is_active "$unit"
}

worktree_owner_live() {
  local target="$1" basename pid invocation unit
  process_owner_live "$target" && return 0
  if grep -Fq -- "$target" <<< "$ACTIVE_UNITS"; then return 0; fi
  basename="$(basename -- "$target")"
  case "$basename" in
    issue-[0-9]*) unit_is_active "zf-implement-${basename#issue-}.service" && return 0 ;;
    triage-[0-9]*) unit_is_active "zf-triage-${basename#triage-}.service" && return 0 ;;
    advisor-[0-9]*) unit_is_active "zf-advisor-${basename#advisor-}.service" && return 0 ;;
    recut-[0-9]*) unit_is_active "zf-recut-${basename#recut-}.service" && return 0 ;;
    triage-batch-run-[0-9]*)
      # run-triage-batch.sh names the tree after its own PID.
      pid="${basename#triage-batch-run-}"
      [[ "$pid" =~ ^[1-9][0-9]*$ ]] && ! caller_pid_or_ancestor "$pid" && pid_live "$pid" && return 0
      ;;
    advisor-run-*)
      # advisor_worktree_new() prefixes the unit's InvocationID: only that invocation owns the tree.
      # Any active advisor unit used to hold every advisor-run tree, so they piled up while batches ran.
      if [[ "$basename" =~ ^advisor-run-([0-9a-f]{32})(-|$) ]]; then
        invocation="${BASH_REMATCH[1]}"
        while read -r unit _; do
          [[ "$unit" =~ ^zf-advisor(-batch|-[0-9]+)\.service$ ]] || continue
          [ "$(timeout 5 systemctl --user show --property=InvocationID --value "$unit" 2>/dev/null || true)" = "$invocation" ] \
            && unit_is_active "$unit" && return 0
        done <<< "$ACTIVE_UNITS"
        return 1
      fi
      unit_is_active "zf-advisor-batch.service" && return 0
      awk '$1 ~ /^zf-advisor-[0-9]+\\.service$/ { found=1 } END { exit !found }' <<< "$ACTIVE_UNITS" && return 0
      ;;
    tmp.*)
      unit_is_active "zf-merge-sweeper.service" && return 0
      awk '$1 ~ /^zf-implement-[0-9]+\\.service$/ { found=1 } END { exit !found }' <<< "$ACTIVE_UNITS" && return 0
      ;;
  esac
  return 1
}

branch_owner_live() {
  local branch="$1" path active_branch owner pid owner_branch
  [ -n "$branch" ] || return 1
  if branch_unit_live "$branch"; then return 0; fi
  if [ "$HAND_OWNER_BRANCH_INDEX_READY" = 1 ]; then
    [ -n "${HAND_OWNER_BRANCHES[$branch]:-}" ] && return 0
    return 1
  fi
  for owner in "$NIGHT"/.hand-owner-*; do
    [ -f "$owner" ] || continue
    pid="${owner##*.hand-owner-}"
    owner_branch="$(sed -n '3p' "$owner" 2>/dev/null || true)"
    if [ "$owner_branch" = "$branch" ] && pid_live "$pid"; then return 0; fi
  done
  if [ "$REAP_WORKTREE_BRANCH_INDEX_READY" = 1 ]; then
    path="${REAP_WORKTREE_BRANCH_PATHS[$branch]:-}"
    if [ -n "$path" ] && [ -d "$path" ]; then
      active_branch="$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
      [ "$active_branch" = "$branch" ] && worktree_owner_live "$path" && return 0
    fi
    return 1
  fi
  while IFS= read -r line; do
    [[ "$line" == 'worktree '* ]] || continue
    path="${line#worktree }"
    active_branch="$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [ "$active_branch" = "$branch" ] && worktree_owner_live "$path"; then
      return 0
    fi
  done < <(git -C "$REPO" worktree list --porcelain)
  return 1
}

pr_state_for() {
  local branch="$1" head="$2" pr_branch pr_sha base state merged merge_commit open=0 terminal="" readable=0
  if [ "$PR_READABLE" = 1 ]; then
    readable=1
  elif [ -n "$branch" ]; then
    if [[ -z "${PR_BRANCH_READABLE[$branch]+x}" ]]; then
      pr_load_point_rows "$branch" ""
    fi
    [ "${PR_BRANCH_READABLE[$branch]:-0}" = 1 ] && readable=1
  else
    if [[ -z "${PR_HEAD_READABLE[$head]+x}" ]]; then
      pr_load_point_rows "" "$head"
    fi
    [ "${PR_HEAD_READABLE[$head]:-0}" = 1 ] && readable=1
  fi
  if [ "$readable" != 1 ]; then PR_STATE_RESULT=UNKNOWN; return 0; fi
  while IFS=$'\t' read -r pr_branch pr_sha base state merged merge_commit; do
    if [ -n "$branch" ]; then
      [ "$pr_branch" = "$branch" ] || continue
    elif [ "$pr_sha" != "$head" ]; then
      continue
    fi
    if [ "$state" = open ]; then open=1; continue; fi
    if [ "$pr_sha" = "$head" ]; then
      if [ -n "$merged" ]; then terminal=MERGED; else terminal=CLOSED; fi
    fi
  done <<< "$PR_ROWS"
  if [ "$open" = 1 ]; then PR_STATE_RESULT=OPEN; else PR_STATE_RESULT="${terminal:-NONE}"; fi
  return 0
}

count_pr_state_item() {
  local item="$1" state="$2"
  [ -n "$item" ] || return 0
  [[ -n "${PR_ITEM_COUNTED[$item]+x}" ]] && return 0
  PR_ITEM_COUNTED[$item]=1
  PR_ITEM_TOTAL=$((PR_ITEM_TOTAL + 1))
  [ "$state" != UNKNOWN ] || PR_ITEM_UNREADABLE=$((PR_ITEM_UNREADABLE + 1))
}

head_on_main() {
  git -C "$REPO" merge-base --is-ancestor "$1" origin/main 2>/dev/null
}

preserve_nonmerged_closed_head() {
  local branch="$1" head="$2" state="$3"
  if [ "$state" = CLOSED ] && ! head_on_main "$head"; then
    push_rescue "$branch" "$head"
  fi
}

prune_stale_worktree_records() {
  local records line archive_path in_tree=0 current_path="" current_head="" current_branch="" current_locked=0
  local current_safe=1 prune_blocked=0 i
  local -a stale_paths=() stale_heads=()
  records="$(git -C "$REPO" worktree list --porcelain)" || return 1
  while IFS= read -r line; do
    case "$line" in
      'worktree '*)
        if [ "$in_tree" = 1 ] && [ ! -d "$current_path" ]; then
          if [ "$current_path" = "$REPO_ROOT" ]; then
            say "skip primary worktree registration $current_path"
          else
            current_safe=1
            if [ -n "$current_head" ] && ! head_content_is_preserved "$current_branch" "$current_head"; then
              if ! push_rescue "${current_branch:-$(basename -- "$current_path")}" "$current_head"; then
                if ! archive_path="$(archive_rescue_patch "${current_branch:-$(basename -- "$current_path")}" "$current_head")"; then
                  say "kept stale worktree registration $current_path; rescue and archive failed"
                  current_safe=0
                  if [ "$current_locked" = 0 ]; then
                    if git -C "$REPO" worktree lock --reason worktree-lifecycle:preservation-failed "$current_path"; then
                      current_locked=1
                    else
                      say "could not lock stale registration $current_path; pruning blocked for safety"
                      prune_blocked=1
                    fi
                  fi
                else
                  manifest_record archived-missing-worktree-head "${current_branch:-$(basename -- "$current_path")}" "$current_head" "$archive_path" || return 1
                fi
              fi
            fi
            if [ "$current_safe" = 1 ]; then
              if [ "$current_locked" = 1 ] && ! git -C "$REPO" worktree unlock "$current_path"; then
                say "kept stale worktree registration $current_path; unlock failed"
              else
                stale_paths+=("$current_path"); stale_heads+=("$current_head")
              fi
            fi
          fi
        fi
        in_tree=1; current_path="${line#worktree }"; current_head=""; current_branch=""; current_locked=0
        ;;
      'HEAD '*) current_head="${line#HEAD }" ;;
      'branch '*) current_branch="${line#branch refs/heads/}" ;;
      locked*) current_locked=1 ;;
    esac
  done <<< "$records"
  if [ "$in_tree" = 1 ] && [ ! -d "$current_path" ]; then
    if [ "$current_path" = "$REPO_ROOT" ]; then
      say "skip primary worktree registration $current_path"
    else
      current_safe=1
      if [ -n "$current_head" ] && ! head_content_is_preserved "$current_branch" "$current_head"; then
        if ! push_rescue "${current_branch:-$(basename -- "$current_path")}" "$current_head"; then
          if ! archive_path="$(archive_rescue_patch "${current_branch:-$(basename -- "$current_path")}" "$current_head")"; then
            say "kept stale worktree registration $current_path; rescue and archive failed"
            current_safe=0
            if [ "$current_locked" = 0 ]; then
              if git -C "$REPO" worktree lock --reason worktree-lifecycle:preservation-failed "$current_path"; then
                current_locked=1
              else
                say "could not lock stale registration $current_path; pruning blocked for safety"
                prune_blocked=1
              fi
            fi
          else
            manifest_record archived-missing-worktree-head "${current_branch:-$(basename -- "$current_path")}" "$current_head" "$archive_path" || return 1
          fi
        fi
      fi
      if [ "$current_safe" = 1 ]; then
        if [ "$current_locked" = 1 ] && ! git -C "$REPO" worktree unlock "$current_path"; then
          say "kept stale worktree registration $current_path; unlock failed"
        else
          stale_paths+=("$current_path"); stale_heads+=("$current_head")
        fi
      fi
    fi
  fi
  [ "$prune_blocked" = 0 ] || return 0
  [ "${#stale_paths[@]}" -gt 0 ] || return 0
  for ((i=0; i<${#stale_paths[@]}; i++)); do
    manifest_record removing-worktree-registration "$(basename -- "${stale_paths[$i]}")" "${stale_heads[$i]}" "path=${stale_paths[$i]}" || return 1
  done
  git -C "$REPO" worktree prune --expire now || { say "stale worktree registration prune failed"; return 1; }
  for ((i=0; i<${#stale_paths[@]}; i++)); do
    manifest_record removed-worktree-registration "$(basename -- "${stale_paths[$i]}")" "${stale_heads[$i]}" "path=${stale_paths[$i]}" || return 1
    say "removed stale worktree registration ${stale_paths[$i]} at ${stale_heads[$i]}"
  done
  STALE_WORKTREE_RECORDS_REMOVED="${#stale_paths[@]}"
}

load_pr_rows() {
  local raw="" rows newest page=1 page_count query_output query_status query_error
  local cache="${WORKTREE_PR_ROWS_CACHE-${REAP_PROGRESS_PREFIX:+$REAP_PROGRESS_PREFIX.pr-rows}}"
  local timeout_seconds="${LIFECYCLE_GH_TIMEOUT_SECONDS:-90}"
  PR_ROWS=""
  PR_READABLE=0
  if [ -n "$cache" ] && [ -s "$cache" ]; then
    # The full list (1600 PRs, ~15s) outgrew the tick's reap slice: fetch only PRs updated since the
    # cache's newest row, newest first, stopping at the first page that reaches already-cached rows.
    newest="$(cut -f2 -- "$cache" | sort | tail -n1)"
  fi
  while :; do
    local url
    if [ -n "$cache" ] && [ -s "$cache" ]; then
      url="repos/$REPO_NAME/pulls?state=all&sort=updated&direction=desc&per_page=100&page=$page"
    else
      url="repos/$REPO_NAME/pulls?state=all&per_page=100&page=$page"
    fi
    if query_output="$(timeout "$timeout_seconds" gh api "$url" --jq "$PR_ROW_FIELDS" 2>&1)"; then
      rows="$query_output"
    else
      query_status=$?
      query_error="$(tr '\r\n\t' '   ' <<< "$query_output" | cut -c1-180)"
      query_error="PR page $page failed (exit $query_status): ${query_error:-no error output}"
      say "GitHub $query_error; falling back to per-item reads"
      return 0
    fi
    raw+="$rows"$'\n'
    page_count="$(grep -c . <<< "$rows" || true)"
    if [ -n "$cache" ] && [ -s "$cache" ]; then
      [ "$page_count" -ge 100 ] && [[ -n "$rows" && "$(tail -n1 <<< "$rows" | cut -f2)" > "$newest" ]] || break
    else
      [ "$page_count" -ge 100 ] || break
    fi
    page=$((page + 1))
  done
  if [ -n "$cache" ] && [ -s "$cache" ]; then
    raw="$(printf '%s\n' "$raw" | cat - "$cache" | awk -F'\t' 'NF >= 8 && !seen[$1]++')"
  fi
  raw="${raw%$'\n'}"
  if [ -n "$cache" ]; then
    if [ -n "$raw" ]; then printf '%s\n' "$raw" > "$cache.tmp.$$"; else : > "$cache.tmp.$$"; fi
    mv -f -- "$cache.tmp.$$" "$cache" || return 1
  fi
  PR_ROWS="$(cut -f3- <<< "$raw")"
  PR_READABLE=1
}

pr_load_point_rows() {
  local branch="$1" head="$2" url output rows status error owner remaining reserve timeout_seconds=2
  remaining="$(reap_budget_remaining_seconds)" || remaining=0
  reserve="$(reap_remote_batch_reserve_seconds)" || reserve=0
  if (( remaining <= reserve )); then
    if [ -n "$branch" ]; then
      PR_BRANCH_READABLE[$branch]=0
      say "GitHub PR state lookup deferred for branch $branch; remaining=${remaining}s reserve=${reserve}s"
    else
      PR_HEAD_READABLE[$head]=0
      say "GitHub PR state lookup deferred for commit $head; remaining=${remaining}s reserve=${reserve}s"
    fi
    return 0
  fi
  if [ -n "$branch" ]; then
    owner="${REPO_NAME%%/*}"
    if output="$(timeout "$timeout_seconds" gh api "repos/$REPO_NAME/pulls" \
      -f state=all -f "head=$owner:$branch" -F per_page=100 --jq "$PR_ROW_FIELDS" 2>&1)"; then
      PR_BRANCH_READABLE[$branch]=1
    else
      status=$?
      error="$(tr '\r\n\t' '   ' <<< "$output" | cut -c1-180)"
      PR_BRANCH_READABLE[$branch]=0
      say "GitHub PR state unreadable for branch $branch (exit $status): ${error:-query failed}"
      return 0
    fi
  else
    url="repos/$REPO_NAME/commits/$head/pulls?per_page=100"
    if output="$(timeout "$timeout_seconds" gh api "$url" --jq "$PR_ROW_FIELDS" 2>&1)"; then
      PR_HEAD_READABLE[$head]=1
    else
      status=$?
      error="$(tr '\r\n\t' '   ' <<< "$output" | cut -c1-180)"
      PR_HEAD_READABLE[$head]=0
      say "GitHub PR state unreadable for commit $head (exit $status): ${error:-query failed}"
      return 0
    fi
  fi
  if [ -n "$output" ]; then
    rows="$(cut -f3- <<< "$output")"
    PR_ROWS+="${PR_ROWS:+$'\n'}$rows"
  fi
}

rescue_issue_number() {
  local name="$1"
  if [[ "$name" =~ (^|[-/])issue-([0-9]+)([-/]|$) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  elif [[ "$name" =~ (^|/)([0-9]+)- ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  else
    return 1
  fi
}

load_rescue_issue_states() {
  local raw rows newest page=1 page_output page_count marker query_status issue_error issue_row_number issue_row_updated_at issue_row_state url
  local cache="${WORKTREE_ISSUE_ROWS_CACHE-${REAP_PROGRESS_PREFIX:+$REAP_PROGRESS_PREFIX.issue-rows}}"
  local fields='def valid_number: (.number | type == "number" and . > 0 and . == floor);
    def state: if (.state | type) == "string" then (.state | ascii_downcase) else "unknown" end;
    if type != "array" or any(.[]; (type != "object") or (valid_number | not) or ((.updated_at | type) != "string")) then
      error("expected issue array with number and updated_at")
    else "count\t\(length)", (.[] | [(.number | tostring), .updated_at, state] | @tsv) end'
  RESCUE_ISSUE_STATES=()
  RESCUE_ISSUE_BULK_ERROR=""
  if [ -n "$cache" ] && [ -s "$cache" ]; then
    newest="$(cut -f2 -- "$cache" | sort | tail -n1)"
    raw=""
    while :; do
      url="repos/$REPO_NAME/issues?state=all&sort=updated&direction=desc&per_page=100&page=$page"
      if page_output="$(timeout "${LIFECYCLE_GH_TIMEOUT_SECONDS:-90}" gh api "$url" --jq "$fields" 2>&1)"; then
        :
      else
        query_status=$?
        issue_error="$(tr '\r\n\t' '   ' <<< "$page_output" | cut -c1-180)"
        RESCUE_ISSUE_BULK_ERROR="issue page $page failed (exit $query_status): ${issue_error:-no error output}"
        RESCUE_ISSUE_STATES=()
        say "GitHub $RESCUE_ISSUE_BULK_ERROR; falling back to bounded per-issue reads"
        return 0
      fi
      IFS=$'\t' read -r marker page_count <<< "$page_output"
      if [ "$marker" != count ] || ! [[ "$page_count" =~ ^[0-9]+$ ]]; then
        RESCUE_ISSUE_BULK_ERROR="issue page $page has unreadable response shape"
        RESCUE_ISSUE_STATES=()
        say "GitHub $RESCUE_ISSUE_BULK_ERROR; falling back to bounded per-issue reads"
        return 0
      fi
      rows="${page_output#*$'\n'}"
      [ "$rows" != "$page_output" ] || rows=""
      raw+="$rows"$'\n'
      [ "$page_count" -ge 100 ] && [[ -n "$rows" && "$(tail -n1 <<< "$rows" | cut -f2)" > "$newest" ]] || break
      page=$((page + 1))
    done
    raw="$(printf '%s\n' "$raw" | cat - "$cache" | awk -F'\t' 'NF >= 3 && !seen[$1]++')"
  else
    raw=""
    while :; do
      url="repos/$REPO_NAME/issues?state=all&per_page=100&page=$page"
      if page_output="$(timeout "${LIFECYCLE_GH_TIMEOUT_SECONDS:-90}" gh api "$url" --jq "$fields" 2>&1)"; then
        :
      else
        query_status=$?
        issue_error="$(tr '\r\n\t' '   ' <<< "$page_output" | cut -c1-180)"
        RESCUE_ISSUE_BULK_ERROR="issue page $page failed (exit $query_status): ${issue_error:-no error output}"
        RESCUE_ISSUE_STATES=()
        say "GitHub $RESCUE_ISSUE_BULK_ERROR; falling back to per-issue reads"
        return 0
      fi
      IFS=$'\t' read -r marker page_count <<< "$page_output"
      if [ "$marker" != count ] || ! [[ "$page_count" =~ ^[0-9]+$ ]]; then
        RESCUE_ISSUE_BULK_ERROR="issue page $page has unreadable response shape"
        RESCUE_ISSUE_STATES=()
        say "GitHub $RESCUE_ISSUE_BULK_ERROR; falling back to per-issue reads"
        return 0
      fi
      rows="${page_output#*$'\n'}"
      [ "$rows" != "$page_output" ] || rows=""
      raw+="$rows"$'\n'
      [ "$page_count" -ge 100 ] || break
      page=$((page + 1))
    done
  fi
  if [ -n "$cache" ]; then
    if ! printf '%s\n' "$raw" > "$cache.tmp.$$" || ! mv -f -- "$cache.tmp.$$" "$cache"; then
      rm -f -- "$cache.tmp.$$"
      say "issue-state cache refresh failed; using fetched rows"
    fi
  fi
  while IFS=$'\t' read -r issue_row_number issue_row_updated_at issue_row_state; do
    [[ "$issue_row_number" =~ ^[0-9]+$ ]] || continue
    case "$issue_row_state" in open|closed) RESCUE_ISSUE_STATES[$issue_row_number]="$issue_row_state" ;; *) RESCUE_ISSUE_STATES[$issue_row_number]=unknown ;; esac
  done <<< "$raw"
}

rescue_issue_is_closed() {
  local number="$1" state issue_output issue_error issue_timeout=3 remaining reserve
  if [ "$RESCUE_ISSUE_STATES_LOADED" != 1 ]; then
    printf 'phase=worktree-reap:rescue-issue-query\n'
    RESCUE_ISSUE_STATES_LOADED=1
    if ! load_rescue_issue_states; then
      say "reap refused; GitHub issue state unreadable; rescue-ref sweep aborted; issue-expiry cleanup skipped"
      return 2
    fi
  fi
  state="${RESCUE_ISSUE_STATES[$number]:-unknown}"
  if [[ "$state" != open && "$state" != closed && -z "${RESCUE_ISSUE_POINT_LOOKED_UP[$number]+x}" ]]; then
    RESCUE_ISSUE_POINT_LOOKED_UP[$number]=1
    remaining="$(reap_budget_remaining_seconds)" || remaining=0
    reserve="$(reap_remote_batch_reserve_seconds)" || reserve=0
    if (( remaining <= reserve + issue_timeout )); then
      state=unknown
      say "GitHub issue state lookup deferred for #$number; remaining=${remaining}s reserve=${reserve}s query=${issue_timeout}s"
    elif issue_output="$(timeout "$issue_timeout" gh api "repos/$REPO_NAME/issues/$number" --jq '.state | ascii_downcase' 2>&1)"; then
      case "$issue_output" in open|closed) state="$issue_output" ;; *) state=unknown ;; esac
    else
      state=unknown
      issue_error="$(tr '\r\n\t' '   ' <<< "$issue_output" | cut -c1-180)"
      say "GitHub issue state unreadable for #$number: ${issue_error:-query failed}"
    fi
    RESCUE_ISSUE_STATES[$number]="$state"
  fi
  if [[ -z "${RESCUE_ISSUE_COUNTED[$number]+x}" ]]; then
    RESCUE_ISSUE_COUNTED[$number]=1
    RESCUE_ISSUE_TOTAL=$((RESCUE_ISSUE_TOTAL + 1))
    if [[ "$state" == open || "$state" == closed ]]; then
      RESCUE_ISSUE_READABLE=$((RESCUE_ISSUE_READABLE + 1))
    else
      RESCUE_ISSUE_UNREADABLE=$((RESCUE_ISSUE_UNREADABLE + 1))
    fi
  fi
  case "$state" in closed) return 0 ;; open) return 1 ;; *) return 2 ;; esac
}

load_main_patch_ids() {
  local index_dir="$REAP_PROGRESS_PREFIX.patchids" state_file commits_file ids_file
  local current_head indexed_head pending_head cursor total batch_end remaining reserve chunk_reserve
  local state_version state_cursor tmp_ids batch_ids batch_status loaded_pending_head=""
  local cache_existed=0 invalidated=0
  local -a state_lines=() pending_commits=() batch_commits=()
  state_file="$index_dir/state"
  commits_file="$index_dir/commits"
  ids_file="$index_dir/ids"
  [ -d "$index_dir" ] && cache_existed=1
  mkdir -p -- "$index_dir" || return 1

  if [ ! -f "$state_file" ]; then
    : > "$ids_file" || return 1
    main_patch_index_write_state "$index_dir" - - 0 || return 1
    if [ "$cache_existed" = 1 ]; then invalidated=1; fi
  else
    mapfile -t state_lines < "$state_file" || return 1
    if [ "${#state_lines[@]}" -ne 4 ] || [ "${state_lines[0]}" != v1 ] \
      || { [ "${state_lines[1]}" != - ] && ! [[ "${state_lines[1]}" =~ ^[0-9a-f]{40,64}$ ]]; } \
      || { [ "${state_lines[2]}" != - ] && ! [[ "${state_lines[2]}" =~ ^[0-9a-f]{40,64}$ ]]; } \
      || ! [[ "${state_lines[3]}" =~ ^[0-9]+$ ]] || [ ! -f "$ids_file" ]; then
      : > "$ids_file" || return 1
      rm -f -- "$commits_file" || return 1
      main_patch_index_write_state "$index_dir" - - 0 || return 1
      invalidated=1
    fi
  fi
  if [ "$invalidated" = 1 ]; then
    say "reap deferred; main patch index cache invalidated"
    printf 'progress=main-patch-index state=invalidated\n'
    return 3
  fi

  while :; do
    current_head="$(git -C "$REPO" rev-parse --verify refs/remotes/origin/main 2>/dev/null)" || return 1
    mapfile -t state_lines < "$state_file" || return 1
    state_version="${state_lines[0]}"
    indexed_head="${state_lines[1]}"
    pending_head="${state_lines[2]}"
    state_cursor="${state_lines[3]}"
    [[ "$state_version" = v1 && "$state_cursor" =~ ^[0-9]+$ ]] || return 1
    cursor=$((10#$state_cursor))

    if [ "$pending_head" != - ]; then
      if ! [[ "$pending_head" =~ ^[0-9a-f]{40,64}$ ]] || [ ! -f "$commits_file" ]; then
        : > "$ids_file" || return 1
        rm -f -- "$commits_file" || return 1
        main_patch_index_write_state "$index_dir" - - 0 || return 1
        say "reap deferred; incomplete main patch index state reset"
        printf 'progress=main-patch-index state=invalidated\n'
        return 3
      fi
      if [ "$pending_head" != "$current_head" ] \
        && ! git -C "$REPO" merge-base --is-ancestor "$pending_head" "$current_head" 2>/dev/null; then
        : > "$ids_file" || return 1
        rm -f -- "$commits_file" || return 1
        main_patch_index_write_state "$index_dir" - - 0 || return 1
        say "reap deferred; origin/main rewrote during patch indexing"
        printf 'progress=main-patch-index state=rewritten\n'
        return 3
      fi
    elif [ "$indexed_head" != - ]; then
      if [ "$indexed_head" = "$current_head" ]; then
        MAIN_PATCH_INDEXED_HEAD="$indexed_head"
        MAIN_PATCH_IDS="$(cat -- "$ids_file")" || return 1
        return 0
      fi
      if ! git -C "$REPO" merge-base --is-ancestor "$indexed_head" "$current_head" 2>/dev/null; then
        : > "$ids_file" || return 1
        rm -f -- "$commits_file" || return 1
        main_patch_index_write_state "$index_dir" - - 0 || return 1
        say "reap deferred; origin/main is not a descendant of the indexed snapshot"
        printf 'progress=main-patch-index state=rewritten\n'
        return 3
      fi
      main_patch_index_prepare_pending "$index_dir" "$current_head" "$indexed_head" || return $?
      continue
    else
      main_patch_index_prepare_pending "$index_dir" "$current_head" - || return $?
      continue
    fi

    if [ "$loaded_pending_head" != "$pending_head" ]; then
      mapfile -t pending_commits < "$commits_file" || return 1
      total="${#pending_commits[@]}"
      loaded_pending_head="$pending_head"
    fi
    if (( cursor > total )); then
      : > "$ids_file" || return 1
      rm -f -- "$commits_file" || return 1
      main_patch_index_write_state "$index_dir" - - 0 || return 1
      say "reap deferred; main patch index cursor exceeded its snapshot"
      printf 'progress=main-patch-index state=invalidated\n'
      return 3
    fi
    if (( cursor == total )); then
      indexed_head="$pending_head"
      main_patch_index_write_state "$index_dir" "$indexed_head" - 0 || return 1
      rm -f -- "$commits_file" || return 1
      loaded_pending_head=""
      continue
    fi

    reserve="$(reap_remote_batch_reserve_seconds)" || return 1
    chunk_reserve=$((LIFECYCLE_GIT_TIMEOUT_SECONDS + LIFECYCLE_GIT_KILL_AFTER_SECONDS))
    remaining="$(reap_budget_remaining_seconds)" || return 1
    if (( remaining <= reserve + chunk_reserve )); then
      say "reap deferred; main patch index at $cursor/$total, preserving $reserve seconds for remote lease/readback"
      printf 'progress=main-patch-index indexed=%s pending=%s cursor=%s total=%s remaining_seconds=%s reserve_seconds=%s\n' \
        "$indexed_head" "$pending_head" "$cursor" "$total" "$remaining" "$reserve"
      return 3
    fi

    batch_end=$((cursor + 64))
    (( batch_end > total )) && batch_end="$total"
    batch_commits=("${pending_commits[@]:cursor:batch_end-cursor}")
    if batch_ids="$(timeout -k "$LIFECYCLE_GIT_KILL_AFTER_SECONDS" "$LIFECYCLE_GIT_TIMEOUT_SECONDS" \
      bash -c 'set -o pipefail; repo="$1"; shift; git -C "$repo" show --binary --no-ext-diff --format="commit %H" -p "$@" | git -C "$repo" patch-id --stable | awk '\''{print $1}'\''' \
      _ "$REPO" "${batch_commits[@]}")"; then
      :
    else
      batch_status=$?
      say "reap deferred; patch-id batch timed out or failed at $cursor/$total (status=$batch_status)"
      printf 'progress=main-patch-index indexed=%s pending=%s cursor=%s total=%s state=batch-incomplete\n' \
        "$indexed_head" "$pending_head" "$cursor" "$total"
      return 3
    fi
    tmp_ids="$ids_file.tmp.$$"
    cat -- "$ids_file" > "$tmp_ids" || { rm -f -- "$tmp_ids"; return 1; }
    if [ -n "$batch_ids" ]; then printf '%s\n' "$batch_ids" >> "$tmp_ids" || { rm -f -- "$tmp_ids"; return 1; }; fi
    LC_ALL=C sort -u "$tmp_ids" -o "$tmp_ids" || { rm -f -- "$tmp_ids"; return 1; }
    mv -f -- "$tmp_ids" "$ids_file" || return 1
    cursor="$batch_end"
    main_patch_index_write_state "$index_dir" "$indexed_head" "$pending_head" "$cursor" || return 1
  done
}

main_patch_index_write_state() {
  local index_dir="$1" indexed_head="$2" pending_head="$3" cursor="$4" tmp
  tmp="$index_dir/state.tmp.$$"
  printf 'v1\n%s\n%s\n%s\n' "$indexed_head" "$pending_head" "$cursor" > "$tmp" \
    && mv -f -- "$tmp" "$index_dir/state" || { rm -f -- "$tmp"; return 1; }
}

main_patch_index_prepare_pending() {
  local index_dir="$1" pending_head="$2" base_head="$3" tmp status
  tmp="$index_dir/commits.tmp.$$"
  if [ "$base_head" = - ]; then
    if timeout -k "$LIFECYCLE_GIT_KILL_AFTER_SECONDS" "$LIFECYCLE_GIT_TIMEOUT_SECONDS" \
      git -C "$REPO" rev-list --no-merges "$pending_head" > "$tmp"; then
      :
    else
      status=$?
      rm -f -- "$tmp"
      say "reap deferred; could not list main patch-index commits (status=$status)"
      printf 'progress=main-patch-index pending=%s state=commit-list-incomplete\n' "$pending_head"
      return 3
    fi
  else
    if timeout -k "$LIFECYCLE_GIT_KILL_AFTER_SECONDS" "$LIFECYCLE_GIT_TIMEOUT_SECONDS" \
      git -C "$REPO" rev-list --no-merges "$pending_head" "^$base_head" > "$tmp"; then
      :
    else
      status=$?
      rm -f -- "$tmp"
      say "reap deferred; could not list main patch-index delta (status=$status)"
      printf 'progress=main-patch-index indexed=%s pending=%s state=delta-list-incomplete\n' "$base_head" "$pending_head"
      return 3
    fi
  fi
  mv -f -- "$tmp" "$index_dir/commits" || { rm -f -- "$tmp"; return 1; }
  if [ "$base_head" = - ]; then
    main_patch_index_write_state "$index_dir" - "$pending_head" 0 || return 1
  else
    main_patch_index_write_state "$index_dir" "$base_head" "$pending_head" 0 || return 1
  fi
  if [ ! -s "$index_dir/commits" ]; then
    main_patch_index_write_state "$index_dir" "$pending_head" - 0 || return 1
    rm -f -- "$index_dir/commits" || return 1
  fi
}

reap_budget_remaining_seconds() {
  local total="${REAP_OUTER_BUDGET_SECONDS:-180}" used="${SECONDS:-0}"
  (( used < total )) && printf '%s\n' "$((total - used))" || printf '0\n'
}

reap_remote_batch_reserve_seconds() {
  printf '%s\n' "$((3 * (LIFECYCLE_GIT_TIMEOUT_SECONDS + LIFECYCLE_GIT_KILL_AFTER_SECONDS) + 5))"
}

flush_remote_deletions() {
  local branches_name="$1" heads_name="$2" kinds_name="$3"
  local -n branches_ref="$branches_name" heads_ref="$heads_name" kinds_ref="$kinds_name"
  local reserve remaining remote_branch remote_head remote_delete_kind candidate_head candidate_ref
  local observed detail current_main has_rescue=0 i
  local -a lease_args=() refspecs=() checked_branches=() checked_heads=() checked_kinds=()
  local remote_after
  ((${#branches_ref[@]})) || return 0
  for remote_delete_kind in "${kinds_ref[@]}"; do
    [ "$remote_delete_kind" = rescue ] && has_rescue=1
  done

  reserve="$(reap_remote_batch_reserve_seconds)" || return 1
  remaining="$(reap_budget_remaining_seconds)" || return 1
  if (( remaining < reserve )); then
    for ((i=0; i<${#branches_ref[@]}; i++)); do
      if [ "${kinds_ref[$i]}" = rescue ]; then
        manifest_record kept-remote-rescue "${branches_ref[$i]}" "${heads_ref[$i]}" budget-reserve-unavailable || return 1
      else
        manifest_record kept-remote-branch "${branches_ref[$i]}" "${heads_ref[$i]}" budget-reserve-unavailable || return 1
      fi
    done
    say "reap deferred; remote deletion batch needs ${reserve}s for leased push/readback, remaining=${remaining}s"
    printf 'progress=remote-batch deferred=1 remaining_seconds=%s reserve_seconds=%s\n' "$remaining" "$reserve"
    return 3
  fi

  if [ "$has_rescue" = 1 ]; then
    current_main="$(git -C "$REPO" rev-parse --verify refs/remotes/origin/main 2>/dev/null)" || return 1
    if [ -z "${MAIN_PATCH_INDEXED_HEAD:-}" ] || [ "$MAIN_PATCH_INDEXED_HEAD" != "$current_main" ]; then
      for ((i=0; i<${#branches_ref[@]}; i++)); do
        if [ "${kinds_ref[$i]}" = rescue ]; then
          manifest_record kept-remote-rescue "${branches_ref[$i]}" "${heads_ref[$i]}" main-advanced-after-index || return 1
        fi
      done
      say "reap deferred; origin/main advanced beyond the rescue patch index"
      printf 'progress=main-patch-index state=main-advanced\n'
      return 3
    fi
  fi

  load_live_state || { say "reap refused; live-owner ledger became unreadable"; return 1; }
  load_reap_worktree_branch_index || { say "reap refused; worktree inventory became unreadable"; return 1; }
  if [ "$has_rescue" = 1 ]; then
    load_rescue_worktree_inventory || { say "reap refused; rescue worktree inventory became unreadable"; return 1; }
  fi
  for ((i=0; i<${#branches_ref[@]}; i++)); do
    remote_branch="${branches_ref[$i]}"
    remote_head="${heads_ref[$i]}"
    remote_delete_kind="${kinds_ref[$i]}"
    if [ "$remote_delete_kind" = rescue ] && rescue_head_is_live "$remote_head"; then
      manifest_record kept-remote-rescue "$remote_branch" "$remote_head" live-worktree || return 1
      skipped_live=$((skipped_live + 1))
      continue
    fi
    if [ "$remote_delete_kind" = branch ] && branch_owner_live "$remote_branch"; then
      manifest_record kept-remote-branch "$remote_branch" "$remote_head" live-owner || return 1
      skipped_live=$((skipped_live + 1))
      continue
    fi
    checked_branches+=("$remote_branch")
    checked_heads+=("$remote_head")
    checked_kinds+=("$remote_delete_kind")
  done
  branches_ref=("${checked_branches[@]}")
  heads_ref=("${checked_heads[@]}")
  kinds_ref=("${checked_kinds[@]}")
  ((${#branches_ref[@]})) || return 0

  # Recheck both budget and the rescue index after local owner/inventory reads.
  remaining="$(reap_budget_remaining_seconds)" || return 1
  if (( remaining < reserve )); then
    for ((i=0; i<${#branches_ref[@]}; i++)); do
      if [ "${kinds_ref[$i]}" = rescue ]; then
        manifest_record kept-remote-rescue "${branches_ref[$i]}" "${heads_ref[$i]}" budget-reserve-unavailable || return 1
      else
        manifest_record kept-remote-branch "${branches_ref[$i]}" "${heads_ref[$i]}" budget-reserve-unavailable || return 1
      fi
    done
    say "reap deferred; remaining time fell below remote mutation/readback reserve"
    printf 'progress=remote-batch deferred=1 remaining_seconds=%s reserve_seconds=%s\n' "$remaining" "$reserve"
    return 3
  fi
  if [ "$has_rescue" = 1 ]; then
    current_main="$(git -C "$REPO" rev-parse --verify refs/remotes/origin/main 2>/dev/null)" || return 1
    if [ "$MAIN_PATCH_INDEXED_HEAD" != "$current_main" ]; then
      for ((i=0; i<${#branches_ref[@]}; i++)); do
        if [ "${kinds_ref[$i]}" = rescue ]; then
          manifest_record kept-remote-rescue "${branches_ref[$i]}" "${heads_ref[$i]}" main-advanced-after-index || return 1
        fi
      done
      say "reap deferred; origin/main advanced beyond the rescue patch index"
      printf 'progress=main-patch-index state=main-advanced\n'
      return 3
    fi
  fi

  for ((i=0; i<${#branches_ref[@]}; i++)); do
    remote_branch="${branches_ref[$i]}"
    remote_head="${heads_ref[$i]}"
    lease_args+=("--force-with-lease=refs/heads/$remote_branch:$remote_head")
    refspecs+=(":refs/heads/$remote_branch")
  done
  if ! timeout -k "$LIFECYCLE_GIT_KILL_AFTER_SECONDS" "$LIFECYCLE_GIT_TIMEOUT_SECONDS" \
    git -C "$REPO" push --quiet "${lease_args[@]}" origin "${refspecs[@]}"; then
    say "some remote branch deletions were refused or timed out; verifying refs individually"
  fi
  remote_after="$(timeout -k "$LIFECYCLE_GIT_KILL_AFTER_SECONDS" "$LIFECYCLE_GIT_TIMEOUT_SECONDS" \
    git -C "$REPO" ls-remote --heads origin)" || {
    say "could not verify remote branch deletion results"
    return 1
  }
  for ((i=0; i<${#branches_ref[@]}; i++)); do
    remote_branch="${branches_ref[$i]}"
    remote_head="${heads_ref[$i]}"
    remote_delete_kind="${kinds_ref[$i]}"
    observed=""
    while read -r candidate_head candidate_ref; do
      [ "$candidate_ref" = "refs/heads/$remote_branch" ] || continue
      observed="$candidate_head"
    done <<< "$remote_after"
    if [ -z "$observed" ]; then
      if [ "$remote_delete_kind" = rescue ]; then
        manifest_record removed-remote-rescue "$remote_branch" "$remote_head" || return 1
      else
        manifest_record removed-remote-branch "$remote_branch" "$remote_head" || return 1
      fi
      removed_remote=$((removed_remote + 1))
      say "removed remote branch $remote_branch at $remote_head"
    else
      detail=delete-refused
      [ "$observed" = "$remote_head" ] || detail="head-changed:$observed"
      if [ "$remote_delete_kind" = rescue ]; then
        manifest_record kept-remote-rescue "$remote_branch" "$remote_head" "$detail" || return 1
      else
        manifest_record kept-remote-branch "$remote_branch" "$remote_head" "$detail" || return 1
      fi
      skipped_safe=$((skipped_safe + 1))
      say "left remote branch $remote_branch at $observed; $detail"
    fi
  done
  if ! timeout -k "$LIFECYCLE_GIT_KILL_AFTER_SECONDS" "$LIFECYCLE_GIT_TIMEOUT_SECONDS" \
    git -C "$REPO" fetch --quiet --no-tags --prune origin; then
    say "remote deletions verified but local remote refs could not be pruned"
    return 1
  fi
  branches_ref=()
  heads_ref=()
  kinds_ref=()
}

rescue_patch_equivalent() {
  local head="$1" patch_id status main_tree rescue_tree main_head="${MAIN_PATCH_INDEXED_HEAD:-origin/main}"
  local tree_output commit_rows patch_output line patch_found=0 patch_batch_start patch_batch_end
  local commit_metadata parent_list parent cache_key
  local -a tree_ids=() rescue_commits=() commit_fields=() rescue_patch_batch=() parent_ids=()
  if [[ -n "${rescue_patch_result[$head]+x}" ]]; then
    return "${rescue_patch_result[$head]}"
  fi
  if [ -n "${REAP_RESCUE_MAIN_TREE:-}" ]; then
    if ! commit_metadata="$(timeout -k "$LIFECYCLE_GIT_KILL_AFTER_SECONDS" "$LIFECYCLE_GIT_TIMEOUT_SECONDS" \
      git -C "$REPO" show -s --format='%T %P' "$head" 2>/dev/null)"; then
      return 2
    fi
    read -r rescue_tree parent_list <<< "$commit_metadata"
    [ -n "$rescue_tree" ] || return 2
    if [ "$rescue_tree" = "$REAP_RESCUE_MAIN_TREE" ]; then return 0; fi
    read -r -a parent_ids <<< "$parent_list"
    if [ "${#parent_ids[@]}" -eq 1 ]; then
      parent="${parent_ids[0]}"
      if [[ -z "${rescue_parent_on_main[$parent]+x}" ]]; then
        if timeout -k "$LIFECYCLE_GIT_KILL_AFTER_SECONDS" "$LIFECYCLE_GIT_TIMEOUT_SECONDS" \
          git -C "$REPO" merge-base --is-ancestor "$parent" "$main_head" 2>/dev/null; then
          rescue_parent_on_main["$parent"]=1
        else
          status=$?
          [ "$status" -eq 1 ] || return 2
          rescue_parent_on_main["$parent"]=0
        fi
      fi
      if [ "${rescue_parent_on_main[$parent]}" = 1 ]; then
        # Single-commit patch depends only on its main parent and tree.
        cache_key="$parent:$rescue_tree"
        if [[ -n "${rescue_single_patch_result[$cache_key]+x}" ]]; then
          return "${rescue_single_patch_result[$cache_key]}"
        fi
        patch_id="$(set -o pipefail; timeout -k "$LIFECYCLE_GIT_KILL_AFTER_SECONDS" "$LIFECYCLE_GIT_TIMEOUT_SECONDS" \
          git -C "$REPO" diff --binary --no-ext-diff "$parent" "$head" \
          | git -C "$REPO" patch-id --stable | awk 'NR == 1 {print $1}')" || return 2
        if [ -n "$patch_id" ] && grep -Fxq -- "$patch_id" <<< "$MAIN_PATCH_IDS"; then
          rescue_single_patch_result["$cache_key"]=0
          return 0
        fi
        rescue_single_patch_result["$cache_key"]=1
        return 1
      fi
    fi
  fi
  if timeout -k "$LIFECYCLE_GIT_KILL_AFTER_SECONDS" "$LIFECYCLE_GIT_TIMEOUT_SECONDS" \
    git -C "$REPO" merge-base --is-ancestor "$head" "$main_head" 2>/dev/null; then
    return 0
  else
    status=$?
    [ "$status" -eq 1 ] || return 2
  fi
  if ! tree_output="$(timeout -k "$LIFECYCLE_GIT_KILL_AFTER_SECONDS" "$LIFECYCLE_GIT_TIMEOUT_SECONDS" \
    git -C "$REPO" rev-parse "$main_head^{tree}" "$head^{tree}" 2>/dev/null)"; then
    return 2
  fi
  mapfile -t tree_ids <<< "$tree_output"
  [ "${#tree_ids[@]}" -eq 2 ] || return 2
  main_tree="${tree_ids[0]}"
  rescue_tree="${tree_ids[1]}"
  [ "$main_tree" != "$rescue_tree" ] || return 0
  patch_id="$(set -o pipefail; timeout -k "$LIFECYCLE_GIT_KILL_AFTER_SECONDS" "$LIFECYCLE_GIT_TIMEOUT_SECONDS" \
    git -C "$REPO" diff --binary --no-ext-diff "$main_head...$head" \
    | git -C "$REPO" patch-id --stable | awk 'NR == 1 {print $1}')" || return 2
  if [ -n "$patch_id" ] && grep -Fxq -- "$patch_id" <<< "$MAIN_PATCH_IDS"; then
    return 0
  fi
  if ! commit_rows="$(timeout -k "$LIFECYCLE_GIT_KILL_AFTER_SECONDS" "$LIFECYCLE_GIT_TIMEOUT_SECONDS" \
    git -C "$REPO" rev-list --parents --reverse "$head" "^$main_head")"; then
    return 2
  fi
  while IFS= read -r line; do
    read -r -a commit_fields <<< "$line"
    ((${#commit_fields[@]})) || continue
    ((${#commit_fields[@]} <= 2)) || return 1
    rescue_commits+=("${commit_fields[0]}")
  done <<< "$commit_rows"
  ((${#rescue_commits[@]} > 1)) || return 1
  for ((patch_batch_start=0; patch_batch_start<${#rescue_commits[@]}; patch_batch_start+=64)); do
    patch_batch_end=$((patch_batch_start + 64))
    (( patch_batch_end > ${#rescue_commits[@]} )) && patch_batch_end="${#rescue_commits[@]}"
    rescue_patch_batch=("${rescue_commits[@]:patch_batch_start:patch_batch_end-patch_batch_start}")
    if ! patch_output="$(timeout -k "$LIFECYCLE_GIT_KILL_AFTER_SECONDS" "$LIFECYCLE_GIT_TIMEOUT_SECONDS" \
      bash -c 'set -o pipefail; repo="$1"; shift; git -C "$repo" show --binary --no-ext-diff --format="commit %H" -p "$@" | git -C "$repo" patch-id --stable' \
      _ "$REPO" "${rescue_patch_batch[@]}")"; then
      return 2
    fi
    while read -r patch_id _; do
      [ -n "$patch_id" ] || continue
      patch_found=1
      grep -Fxq -- "$patch_id" <<< "$MAIN_PATCH_IDS" || return 1
    done <<< "$patch_output"
  done
  [ "$patch_found" = 1 ]
}

rescue_patch_batch_budget() {
  local reserve remaining chunk_reserve
  reserve="$(reap_remote_batch_reserve_seconds)" || return 1
  remaining="$(reap_budget_remaining_seconds)" || return 1
  chunk_reserve=$((LIFECYCLE_GIT_TIMEOUT_SECONDS + LIFECYCLE_GIT_KILL_AFTER_SECONDS))
  (( remaining > reserve + chunk_reserve ))
}

prepare_rescue_patch_equivalence() {
  local main_head="$1" head metadata_rows main_commits history_rows patch_output patch_id commit line tree pair
  local reserve remaining chunk_reserve batch_start batch_end parent_status commit_status
  local -a heads=() history_lines=() commit_fields=() metadata_ids=() patch_commits=() batch=()
  local -A seen=() metadata_seen=() main_commits_set=() main_patch_ids=() head_trees=() graph_trees=()
  local -A graph_status=() graph_patch_ids=() graph_pair_by_commit=() graph_pair_rep=()
  for head in "${rescue_candidate_heads[@]}"; do
    [[ "$head" =~ ^[0-9a-f]{40,64}$ && -z "${seen[$head]+x}" ]] || continue
    seen["$head"]=1
    heads+=("$head")
  done
  ((${#heads[@]})) || return 0
  printf 'progress=rescue-patch-batch candidates=%s\n' "${#heads[@]}"

  if ! rescue_patch_batch_budget; then
    say "rescue patch proof deferred; preserving remote lease/readback reserve"
    for head in "${heads[@]}"; do rescue_patch_result["$head"]=2; done
    return 0
  fi
  if ! history_rows="$(timeout -k "$LIFECYCLE_GIT_KILL_AFTER_SECONDS" "$LIFECYCLE_GIT_TIMEOUT_SECONDS" \
    git -C "$REPO" rev-list --parents --reverse --topo-order "${heads[@]}" "^$main_head" 2>/dev/null)"; then
    say "rescue history proof failed; retaining refs"
    for head in "${heads[@]}"; do [[ -n "${rescue_patch_result[$head]+x}" ]] || rescue_patch_result["$head"]=2; done
    return 0
  fi

  mapfile -t history_lines <<< "$history_rows"
  for line in "${history_lines[@]}"; do
    commit_fields=()
    read -r -a commit_fields <<< "$line"
    ((${#commit_fields[@]})) || continue
    commit="${commit_fields[0]}"
    [[ "$commit" =~ ^[0-9a-f]{40,64}$ ]] || continue
    if [[ -z "${metadata_seen[$commit]+x}" ]]; then
      metadata_seen["$commit"]=1
      metadata_ids+=("$commit")
    fi
    case "${#commit_fields[@]}" in
      1) graph_status["$commit"]=2 ;;
      2) ;;
      *) graph_status["$commit"]=1 ;;
    esac
  done
  for head in "${heads[@]}"; do
    if [[ -z "${metadata_seen[$head]+x}" ]]; then
      metadata_seen["$head"]=1
      metadata_ids+=("$head")
    fi
  done

  if ! rescue_patch_batch_budget; then
    say "rescue patch proof deferred; preserving remote lease/readback reserve"
    for head in "${heads[@]}"; do rescue_patch_result["$head"]=2; done
    return 0
  fi
  if ! metadata_rows="$(timeout -k "$LIFECYCLE_GIT_KILL_AFTER_SECONDS" "$LIFECYCLE_GIT_TIMEOUT_SECONDS" \
    git -C "$REPO" show -s --format='%H%x09%T%x09%P' "${metadata_ids[@]}" 2>/dev/null)"; then
    for head in "${heads[@]}"; do rescue_patch_result["$head"]=2; done
    return 0
  fi
  while IFS=$'\t' read -r commit tree _; do
    [[ "$commit" =~ ^[0-9a-f]{40,64}$ && "$tree" =~ ^[0-9a-f]{40,64}$ ]] || continue
    graph_trees["$commit"]="$tree"
    head_trees["$commit"]="$tree"
  done <<< "$metadata_rows"

  if ! rescue_patch_batch_budget; then
    say "rescue patch proof deferred; preserving remote lease/readback reserve"
    for head in "${heads[@]}"; do [[ -n "${rescue_patch_result[$head]+x}" ]] || rescue_patch_result["$head"]=2; done
    return 0
  fi
  if ! main_commits="$(timeout -k "$LIFECYCLE_GIT_KILL_AFTER_SECONDS" "$LIFECYCLE_GIT_TIMEOUT_SECONDS" \
    git -C "$REPO" rev-list "$main_head" 2>/dev/null)"; then
    for head in "${heads[@]}"; do rescue_patch_result["$head"]=2; done
    return 0
  fi
  while IFS= read -r commit; do
    [[ "$commit" =~ ^[0-9a-f]{40,64}$ ]] && main_commits_set["$commit"]=1
  done <<< "$main_commits"
  while IFS= read -r patch_id; do
    [[ "$patch_id" =~ ^[0-9a-f]{40,64}$ ]] && main_patch_ids["$patch_id"]=1
  done <<< "${MAIN_PATCH_IDS:-}"
  for head in "${heads[@]}"; do
    if [[ -n "${main_commits_set[$head]+x}" || "${head_trees[$head]:-}" = "$REAP_RESCUE_MAIN_TREE" ]]; then
      rescue_patch_result["$head"]=0
    fi
  done

  for line in "${history_lines[@]}"; do
    commit_fields=()
    read -r -a commit_fields <<< "$line"
    ((${#commit_fields[@]} == 2)) || continue
    commit="${commit_fields[0]}"
    [[ -n "${graph_trees[$commit]+x}" ]] || continue
    pair="${commit_fields[1]}:${graph_trees[$commit]}"
    graph_pair_by_commit["$commit"]="$pair"
    if [[ -z "${graph_pair_rep[$pair]+x}" ]]; then
      graph_pair_rep["$pair"]="$commit"
      patch_commits+=("$commit")
    fi
  done
  printf 'progress=rescue-patch-batch commits=%s\n' "${#patch_commits[@]}"

  local patch_complete=1
  for ((batch_start=0; batch_start<${#patch_commits[@]}; batch_start+=64)); do
    batch_end=$((batch_start + 64))
    (( batch_end > ${#patch_commits[@]} )) && batch_end="${#patch_commits[@]}"
    batch=("${patch_commits[@]:batch_start:batch_end-batch_start}")
    if ! rescue_patch_batch_budget; then
      patch_complete=0
      break
    fi
    if patch_output="$(timeout -k "$LIFECYCLE_GIT_KILL_AFTER_SECONDS" "$LIFECYCLE_GIT_TIMEOUT_SECONDS" \
      bash -c 'set -o pipefail; repo="$1"; shift; git -C "$repo" show --binary --no-ext-diff --format="commit %H" -p "$@" | git -C "$repo" patch-id --stable' \
      _ "$REPO" "${batch[@]}")"; then
      while read -r patch_id commit; do
        [[ "$patch_id" =~ ^[0-9a-f]{40,64}$ && -n "${graph_pair_by_commit[$commit]+x}" ]] || continue
        graph_patch_ids["${graph_pair_by_commit[$commit]}"]="$patch_id"
      done <<< "$patch_output"
    else
      patch_complete=0
      break
    fi
  done

  if [ "$patch_complete" = 1 ]; then
    for line in "${history_lines[@]}"; do
      commit_fields=()
      read -r -a commit_fields <<< "$line"
      ((${#commit_fields[@]})) || continue
      commit="${commit_fields[0]}"
      [[ -n "${graph_status[$commit]+x}" ]] && continue
      if ((${#commit_fields[@]} != 2)); then
        graph_status["$commit"]=2
        continue
      fi
      parent_status=0
      if [[ -z "${main_commits_set[${commit_fields[1]}]+x}" ]]; then
        parent_status="${graph_status[${commit_fields[1]}]:-2}"
      fi
      case "$parent_status" in
        1|2) graph_status["$commit"]="$parent_status" ;;
        *)
          pair="${graph_pair_by_commit[$commit]:-}"
          patch_id="${graph_patch_ids[$pair]:-}"
          if [ -z "$patch_id" ]; then
            graph_status["$commit"]=2
          elif [[ -n "${main_patch_ids[$patch_id]+x}" ]]; then
            graph_status["$commit"]=0
          else
            graph_status["$commit"]=1
          fi
          ;;
      esac
    done
  else
    say "rescue patch proof budget or batch failed; retaining unproven refs"
  fi

  for head in "${heads[@]}"; do
    [[ -n "${rescue_patch_result[$head]+x}" ]] && continue
    if [ "$patch_complete" = 1 ]; then
      commit_status="${graph_status[$head]:-2}"
    else
      commit_status=2
    fi
    # Individual patch IDs cannot prove a multi-commit rescue squashed on main.
    # Try its cumulative patch only after the batched proof did not match.
    pair="${graph_pair_by_commit[$head]:-}"
    if [ "$commit_status" = 1 ] && [ -n "${MAIN_PATCH_IDS:-}" ] \
      && [ -n "$pair" ] && [[ -z "${main_commits_set[${pair%%:*}]+x}" ]]; then
      if ! rescue_patch_batch_budget; then
        commit_status=2
      elif patch_id="$(set -o pipefail; timeout -k "$LIFECYCLE_GIT_KILL_AFTER_SECONDS" "$LIFECYCLE_GIT_TIMEOUT_SECONDS" \
        git -C "$REPO" diff --binary --no-ext-diff "$main_head...$head" \
        | git -C "$REPO" patch-id --stable | awk 'NR == 1 {print $1}')"; then
        if [ -n "$patch_id" ] && [[ -n "${main_patch_ids[$patch_id]+x}" ]]; then
          commit_status=0
        fi
      else
        commit_status=2
      fi
    fi
    rescue_patch_result["$head"]="$commit_status"
  done
}

archive_rescue_patch() {
  local branch="$1" head="$2" slug archive tmp status main_head="${MAIN_PATCH_INDEXED_HEAD:-origin/main}"
  slug="$(sed -E 's#[^A-Za-z0-9._-]+#-#g; s#^-+##; s#-+$##' <<< "$branch")"
  slug="${slug:0:96}"
  archive="$NIGHT/cleanup-archive/${slug:-rescued}-${head:0:12}.patch"
  tmp="$archive.tmp.$$"
  mkdir -p -- "$NIGHT/cleanup-archive" || return 1
  if timeout -k "${LIFECYCLE_GIT_KILL_AFTER_SECONDS:-2}" "${LIFECYCLE_GIT_TIMEOUT_SECONDS:-12}" \
    git -C "$REPO" format-patch --stdout --binary "$main_head..$head" >"$tmp"; then
    :
  else
    status=$?
    rm -f -- "$tmp"
    say "rescue patch archive failed for $branch at $head (git status=$status)"
    return 1
  fi
  if [ ! -s "$tmp" ]; then
    if timeout -k "${LIFECYCLE_GIT_KILL_AFTER_SECONDS:-2}" "${LIFECYCLE_GIT_TIMEOUT_SECONDS:-12}" \
      git -C "$REPO" format-patch --stdout --binary -1 "$head" >"$tmp"; then
      :
    else
      status=$?
      rm -f -- "$tmp"
      say "rescue patch archive failed for $branch at $head (git status=$status)"
      return 1
    fi
  fi
  [ -s "$tmp" ] || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$archive" || { rm -f -- "$tmp"; return 1; }
  printf '%s\n' "$archive"
}

rescue_worktree_inventory_add() {
  local source_repo="$1" path="$2" head="$3" branch="$4" locked="$5" index
  [ -n "$head" ] || return 0
  index="${#RESCUE_WORKTREE_PATHS[@]}"
  RESCUE_WORKTREE_ROOTS+=("$source_repo")
  RESCUE_WORKTREE_PATHS+=("$path")
  RESCUE_WORKTREE_BRANCHES+=("$branch")
  RESCUE_WORKTREE_LOCKED+=("$locked")
  RESCUE_WORKTREE_HEAD_INDEX["$head"]="${RESCUE_WORKTREE_HEAD_INDEX["$head"]:-} $index"
}

rescue_worktree_is_protected() {
  local rescue_head="$1" source_repo="$2" path="$3" head="$4" branch="$5" locked="$6"
  [ "$path" != "$source_repo" ] && [ "$head" = "$rescue_head" ] || return 1
  [ "$locked" = 1 ] || worktree_owner_live "$path" || branch_unit_live "$branch"
}

load_rescue_worktree_inventory() {
  local source_repo records line path="" head="" branch="" locked=0 in_tree=0
  RESCUE_WORKTREE_INVENTORY_READY=0
  RESCUE_WORKTREE_ROOTS=()
  RESCUE_WORKTREE_PATHS=()
  RESCUE_WORKTREE_BRANCHES=()
  RESCUE_WORKTREE_LOCKED=()
  RESCUE_WORKTREE_HEAD_INDEX=()
  for source_repo in "${ALL_REPOS[@]}"; do
    records="$(git -C "$source_repo" worktree list --porcelain)" || return 1
    while IFS= read -r line; do
      case "$line" in
        'worktree '*)
          [ "$in_tree" != 1 ] || rescue_worktree_inventory_add "$source_repo" "$path" "$head" "$branch" "$locked" || return 1
          in_tree=1; path="${line#worktree }"; head=""; branch=""; locked=0
          ;;
        'HEAD '*) head="${line#HEAD }" ;;
        'branch '*) branch="${line#branch refs/heads/}" ;;
        locked*) locked=1 ;;
        '')
          [ "$in_tree" != 1 ] || rescue_worktree_inventory_add "$source_repo" "$path" "$head" "$branch" "$locked" || return 1
          in_tree=0
          ;;
      esac
    done <<< "$records"
    [ "$in_tree" != 1 ] || rescue_worktree_inventory_add "$source_repo" "$path" "$head" "$branch" "$locked" || return 1
    in_tree=0
  done
  RESCUE_WORKTREE_INVENTORY_READY=1
}

rescue_head_is_live() {
  local rescue_head="$1" index source_repo path branch locked
  local -a indexes=()
  if [ "$RESCUE_WORKTREE_INVENTORY_READY" != 1 ]; then
    load_rescue_worktree_inventory || return 2
  fi
  read -r -a indexes <<< "${RESCUE_WORKTREE_HEAD_INDEX[$rescue_head]:-}"
  for index in "${indexes[@]}"; do
    source_repo="${RESCUE_WORKTREE_ROOTS[$index]}"
    path="${RESCUE_WORKTREE_PATHS[$index]}"
    branch="${RESCUE_WORKTREE_BRANCHES[$index]}"
    locked="${RESCUE_WORKTREE_LOCKED[$index]}"
    rescue_worktree_is_protected "$rescue_head" "$source_repo" "$path" "$rescue_head" "$branch" "$locked" && return 0
  done
  return 1
}

reap_progress_lock() {
  local common_dir key
  common_dir="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  common_dir="$(realpath -e -- "$common_dir")" || return 1
  key="$(printf '%s' "$common_dir" | sha256sum | awk '{print $1}')" || return 1
  mkdir -p -- "$NIGHT/worktree-reap" || return 1
  REAP_PROGRESS_PREFIX="$NIGHT/worktree-reap/$key"
  exec 8>>"$REAP_PROGRESS_PREFIX.lock" || return 1
  flock -n 8 || { say "reap deferred; another cleanup owns $common_dir"; return 3; }
}

reap_progress_init() {
  local path tmp snapshot="$REAP_PROGRESS_PREFIX.worktrees" cursor="$REAP_PROGRESS_PREFIX.cursor"
  if [ ! -f "$snapshot" ] || [ ! -f "$cursor" ]; then
    tmp="$snapshot.tmp.$$"
    : > "$tmp" || return 1
    for path in "$@"; do printf '%s\n' "$path" >> "$tmp" || return 1; done
    mv -f -- "$tmp" "$snapshot" || return 1
    tmp="$cursor.tmp.$$"
    printf '0\n' > "$tmp" && mv -f -- "$tmp" "$cursor" || return 1
  fi
  mapfile -t REAP_SWEEP_PATHS < "$snapshot" || return 1
  REAP_PROGRESS_CURSOR="$(cat -- "$cursor" 2>/dev/null || true)"
  if ! [[ "$REAP_PROGRESS_CURSOR" =~ ^[0-9]+$ ]]; then
    REAP_PROGRESS_CURSOR=0
    reap_progress_advance 0 || return 1
  else
    REAP_PROGRESS_CURSOR=$((10#$REAP_PROGRESS_CURSOR))
    if (( REAP_PROGRESS_CURSOR > ${#REAP_SWEEP_PATHS[@]} )); then
      REAP_PROGRESS_CURSOR=0
      reap_progress_advance 0 || return 1
    fi
  fi
}

reap_progress_advance() {
  local cursor="$1" tmp="$REAP_PROGRESS_PREFIX.cursor.tmp.$$"
  printf '%s\n' "$cursor" > "$tmp" && mv -f -- "$tmp" "$REAP_PROGRESS_PREFIX.cursor" || return 1
  REAP_PROGRESS_CURSOR="$cursor"
}

reap_progress_clear() {
  rm -f -- "$REAP_PROGRESS_PREFIX.worktrees" "$REAP_PROGRESS_PREFIX.cursor" \
    "$REAP_PROGRESS_PREFIX.owner-clones" "$REAP_PROGRESS_PREFIX.owner-clone-cursor" || return 1
  exec 8>&-
}

load_reap_worktree_branch_index() {
  local records line in_tree=0 path="" branch=""
  records="$(git -C "$REPO" worktree list --porcelain)" || return 1
  REAP_WORKTREE_BRANCH_PATHS=()
  while IFS= read -r line; do
    case "$line" in
      'worktree '*)
        if [ "$in_tree" = 1 ] && [ -n "$branch" ]; then REAP_WORKTREE_BRANCH_PATHS["$branch"]="$path"; fi
        in_tree=1; path="${line#worktree }"; branch=""
        ;;
      'branch '*) branch="${line#branch refs/heads/}" ;;
      '')
        if [ "$in_tree" = 1 ] && [ -n "$branch" ]; then REAP_WORKTREE_BRANCH_PATHS["$branch"]="$path"; fi
        in_tree=0
        ;;
    esac
  done <<< "$records"
  if [ "$in_tree" = 1 ] && [ -n "$branch" ]; then REAP_WORKTREE_BRANCH_PATHS["$branch"]="$path"; fi
  REAP_WORKTREE_BRANCH_INDEX_READY=1
}

reap_worktree_candidate() {
  local path="$1" head="$2" branch="$3" locked="$4" lock_reason="$5" primary="$6"
  local lock_status=0 state status stale index_file hand_resume_expired=0 inventory_record
  local marker_mtime age_over_24h=unknown now dirty_state=unknown ancestry=unknown pr_state=not-checked
  marker_mtime="$(stat -c %Y -- "$path/.git" 2>/dev/null || true)"
  if [[ "$marker_mtime" =~ ^[0-9]+$ ]]; then
    now="$(date +%s)"
    if (( now - marker_mtime > 86400 )); then age_over_24h=yes; else age_over_24h=no; fi
  fi
  if worktree_owner_live "$path" || branch_owner_live "$branch"; then
    reap_path_audit worktree "$path" live unknown "shared-${REAP_SHARED_STASH:-unknown}" not-checked not-checked kept "$path" live-owner "$head" "$age_over_24h"
    skipped_live=$((skipped_live + 1)); say "skip live worktree $path"; return 0
  fi
  if [ "$locked" = 1 ]; then
    lock_status=0
    worktree_lock_state "$path" "$lock_reason" || lock_status=$?
    case "$lock_status" in
      0)
        reap_path_audit worktree "$path" live unknown "shared-${REAP_SHARED_STASH:-unknown}" not-checked not-checked kept "$path" live-lock-owner "$head" "$age_over_24h"
        skipped_live=$((skipped_live + 1)); say "skip live worktree lock owner $path"; return 0
        ;;
      1)
        if ! git -C "$REPO" worktree unlock "$path"; then
          reap_path_audit worktree "$path" unknown unknown "shared-${REAP_SHARED_STASH:-unknown}" not-checked not-checked kept "$path" unlock-refused "$head" "$age_over_24h"
          skipped_safe=$((skipped_safe + 1)); say "skip locked worktree $path; unlock refused"; return 0
        fi
        say "released dead or expired worktree lock $path"
        # The inventory record handed to finish_worktree must not ask it to unlock a second time.
        locked=0
        ;;
      *)
        if hand_worktree_resume_decision "$path" "$head"; then
          reap_path_audit worktree "$path" unknown unknown "shared-${REAP_SHARED_STASH:-unknown}" not-checked not-checked kept "$path" resume-pending-lock-owner-unknown "$head" "$age_over_24h"
          skipped_safe=$((skipped_safe + 1)); say "skip resume-pending worktree $path; lock owner unknown"; return 0
        fi
        reap_path_audit worktree "$path" unknown unknown "shared-${REAP_SHARED_STASH:-unknown}" not-checked not-checked kept "$path" lock-owner-unknown "$head" "$age_over_24h"
        skipped_safe=$((skipped_safe + 1)); say "skip locked worktree $path; owner unknown or lock younger than 24h"; return 0
        ;;
    esac
  fi
  if [ ! -d "$path" ]; then
    reap_path_audit worktree "$path" not-live unknown "shared-${REAP_SHARED_STASH:-unknown}" not-checked not-checked kept "$path" missing-path "$head" "$age_over_24h"
    skipped_safe=$((skipped_safe + 1)); say "skip missing worktree entry $path"; return 0
  fi
  if hand_worktree_resume_decision "$path" "$head"; then
    reap_path_audit worktree "$path" not-live unknown "shared-${REAP_SHARED_STASH:-unknown}" not-checked not-checked kept "$path" resume-pending "$head" "$age_over_24h"
    skipped_safe=$((skipped_safe + 1)); say "skip resume-pending worktree $path"; return 0
  fi
  [ "$HAND_RESUME_STATE" = expired ] && hand_resume_expired=1
  stale=0
  index_file="$(git -C "$path" rev-parse --path-format=absolute --git-path index 2>/dev/null || true)"
  [ -n "$index_file" ] && [ $(( $(date +%s) - $(stat -c %Y -- "$index_file" 2>/dev/null || date +%s) )) -ge "${REAP_STALE_SECONDS:-86400}" ] && stale=1
  [ "$hand_resume_expired" = 1 ] && stale=1
  status="$(git -C "$path" status --porcelain=v1 --untracked-files=all 2>/dev/null)" || {
    reap_path_audit worktree "$path" not-live unknown "shared-${REAP_SHARED_STASH:-unknown}" not-checked not-checked kept "$path" status-unreadable "$head" "$age_over_24h"
    skipped_safe=$((skipped_safe + 1)); return 0
  }
  if [ -n "$status" ]; then dirty_state=yes; else dirty_state=no; fi
  # Linked worktrees share refs/stash; removing this clean tree leaves every stash reachable.
  # Past REAP_STALE_SECONDS, snapshot dirty files before finish_worktree rescues unique commits.
  if [ -n "$status" ]; then
    if [ "$stale" = 1 ] && git -C "$path" add -A >/dev/null 2>&1 \
      && git -C "$path" commit --no-verify -qm "rescue: uncommitted work in stale worktree" >/dev/null 2>&1; then
      head="$(git -C "$path" rev-parse --verify HEAD)"
      say "snapshotted stale dirty worktree $path at $head"
    else
      reap_path_audit worktree "$path" not-live yes "shared-${REAP_SHARED_STASH:-unknown}" not-checked not-checked kept "$path" dirty-not-snapshotted "$head" "$age_over_24h"
      skipped_safe=$((skipped_safe + 1)); say "skip dirty worktree $path"; return 0
    fi
  fi
  pr_state_for "$branch" "$head"
  state="$PR_STATE_RESULT"
  pr_state="$state"
  if [ "$age_over_24h" = yes ] || { [[ "$state" != MERGED && "$state" != CLOSED && "$state" != OPEN && "$state" != UNKNOWN ]]; }; then
    if head_on_main "$head"; then ancestry=on-main; else ancestry=off-main; fi
  fi
  count_pr_state_item "worktree:$path" "$state"
  if [ "$state" = UNKNOWN ]; then
    record_kept_worktree "$path" "$head" pr-state-unreadable || true
    reap_path_audit worktree "$path" not-live "$dirty_state" "shared-${REAP_SHARED_STASH:-unknown}" UNKNOWN "$ancestry" kept "$path" pr-state-unreadable "$head" "$age_over_24h"
    skipped_safe=$((skipped_safe + 1))
    say "skip worktree with unreadable PR state $path"
    return 0
  fi
  if [ "$state" = OPEN ]; then
    reap_path_audit worktree "$path" not-live "$dirty_state" "shared-${REAP_SHARED_STASH:-unknown}" OPEN "$ancestry" kept "$path" open-pr "$head" "$age_over_24h"
    skipped_safe=$((skipped_safe + 1)); say "skip open-PR worktree $path"; return 0
  fi
  case "$path" in
    */.claude/worktrees/agent-*)
      if [[ "$state" != MERGED && "$state" != CLOSED ]]; then
        reap_path_audit worktree "$path" not-live "$dirty_state" "shared-${REAP_SHARED_STASH:-unknown}" "$pr_state" "$ancestry" kept "$path" session-agent-without-terminal-pr "$head" "$age_over_24h"
        skipped_safe=$((skipped_safe + 1)); say "skip session-agent worktree without terminal PR $path"; return 0
      fi
      local created
      created="$(git -C "$path" show -s --format=%ct HEAD 2>/dev/null || true)"
      if ! [[ "$created" =~ ^[0-9]+$ ]] || [ $(( $(date +%s) - created )) -lt "${REAP_STALE_SECONDS:-86400}" ]; then
        reap_path_audit worktree "$path" not-live "$dirty_state" "shared-${REAP_SHARED_STASH:-unknown}" "$pr_state" "$ancestry" kept "$path" recent-session-agent "$head" "$age_over_24h"
        skipped_safe=$((skipped_safe + 1)); say "skip recent session-agent worktree $path"; return 0
      fi
      ;;
  esac
  if [[ "$state" != MERGED && "$state" != CLOSED ]] && [ "$ancestry" != on-main ]; then
    record_kept_worktree "$path" "$head" ambiguous-unmerged || true
    reap_path_audit worktree "$path" not-live "$dirty_state" "shared-${REAP_SHARED_STASH:-unknown}" "$pr_state" "$ancestry" kept "$path" ambiguous-unmerged "$head" "$age_over_24h"
    skipped_safe=$((skipped_safe + 1))
    say "skip ambiguous unmerged worktree $path head=$head pr=$state ancestry=off-main recoverable=$path"
    return 0
  fi
  load_live_state || {
    reap_path_audit worktree "$path" unknown "$dirty_state" "shared-${REAP_SHARED_STASH:-unknown}" "$pr_state" "$ancestry" kept "$path" owner-ledger-unreadable "$head" "$age_over_24h"
    say "reap refused; live-owner ledger became unreadable"
    return 1
  }
  if worktree_owner_live "$path" || branch_owner_live "$branch"; then
    reap_path_audit worktree "$path" live "$dirty_state" "shared-${REAP_SHARED_STASH:-unknown}" "$pr_state" "$ancestry" kept "$path" became-live "$head" "$age_over_24h"
    skipped_live=$((skipped_live + 1)); say "skip worktree that became live $path"; return 0
  fi
  printf -v inventory_record '%s\t%s\t%s\t%s\t%s' \
    "$head" "${branch:-(detached)}" "$locked" "$lock_reason" "$path"
  if finish_worktree "$path" 1 "$inventory_record" "$primary"; then
    removed_worktrees=$((removed_worktrees + 1))
    reap_path_audit worktree "$path" not-live "$dirty_state" "shared-${REAP_SHARED_STASH:-unknown}" "$pr_state" "$ancestry" removed origin-or-rescue safe "$head" "$age_over_24h"
  else
    skipped_safe=$((skipped_safe + 1))
    reap_path_audit worktree "$path" not-live "$dirty_state" "shared-${REAP_SHARED_STASH:-unknown}" "$pr_state" "$ancestry" kept "$path" lifecycle-refused "$head" "$age_over_24h"
  fi
}

reap_one() {
  local line path branch state remote_rows remote_ref remote_branch remote_head remote_created remote_after observed detail current_main remote_status
  local local_rows local_branch local_head attached attached_path primary worktree_records removed_worktrees=0 removed_clones=0 removed_local=0 removed_remote=0 skipped_live=0 skipped_safe=0
  local remote_delete_kind issue_number issue_state created now rescue_reason rescue_status archive_path patch_status rescue_prefix rescue_group rescue_issue rescue_issue_state rescue_latest_ref rescue_latest_at scoped_issue
  local skipped_unreadable=0 removed_rescues=0
  local remaining archive_reserve archive_timeout archive_budget archive_budget_reported=0
  local LIFECYCLE_SYSTEMCTL_TIMEOUT_SECONDS="${WORKTREE_REAP_SYSTEMCTL_TIMEOUT_SECONDS:-5}"
  local LIFECYCLE_GIT_TIMEOUT_SECONDS="${WORKTREE_REAP_GIT_TIMEOUT_SECONDS:-12}"
  local LIFECYCLE_GIT_KILL_AFTER_SECONDS=2
  local LIFECYCLE_GH_TIMEOUT_SECONDS="${WORKTREE_REAP_GH_TIMEOUT_SECONDS:-12}"
  local worktree_budget_seconds="${WORKTREE_REAP_BUDGET_SECONDS:-20}" max_worktrees="${WORKTREE_REAP_MAX_PER_RUN:-0}"
  local REAP_OUTER_BUDGET_SECONDS="${ZF_WORKTREE_REAP_TIMEOUT_SECONDS:-180}"
  local worktree_started processed_worktrees=0 current_index
  local shared_stash_rows
  local REAP_SHARED_STASH=unknown
  local -A rescue_issue_states=() rescue_newest_at=() rescue_newest_ref=()
  local -A rescue_parent_on_main=() rescue_single_patch_result=() rescue_patch_result=()
  local -A rescue_commit_tree=() rescue_commit_parents=() rescue_main_commit=() rescue_main_patch_id=()
  local -a rescue_candidate_heads=()
  local REAP_RESCUE_MAIN_TREE=""
  local -A current_indexes=()
  STALE_WORKTREE_RECORDS_REMOVED=0
  REPO_CONTAINS_CACHE=()
  RESCUE_ISSUE_STATES=()
  RESCUE_ISSUE_POINT_LOOKED_UP=()
  RESCUE_ISSUE_COUNTED=()
  RESCUE_ISSUE_STATES_LOADED=0
  RESCUE_ISSUE_TOTAL=0
  RESCUE_ISSUE_READABLE=0
  RESCUE_ISSUE_UNREADABLE=0
  RESCUE_ISSUE_BULK_ERROR=""
  PR_ROWS=""
  PR_READABLE=0
  PR_BRANCH_READABLE=()
  PR_HEAD_READABLE=()
  PR_ITEM_COUNTED=()
  PR_ITEM_TOTAL=0
  PR_ITEM_UNREADABLE=0
  REAP_WORKTREE_BRANCH_PATHS=()
  REAP_WORKTREE_BRANCH_INDEX_READY=0
  RESCUE_WORKTREE_INVENTORY_READY=0
  reap_progress_lock || return $?
  [[ "$worktree_budget_seconds" =~ ^[0-9]+$ && "$max_worktrees" =~ ^[0-9]+$ \
    && "$REAP_OUTER_BUDGET_SECONDS" =~ ^[0-9]+$ && "$LIFECYCLE_GIT_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
    say "reap refused; worktree budget and batch size must be nonnegative integers"
    return 1
  }
  worktree_budget_seconds=$((10#$worktree_budget_seconds))
  max_worktrees=$((10#$max_worktrees))
  REAP_OUTER_BUDGET_SECONDS=$((10#$REAP_OUTER_BUDGET_SECONDS))
  printf 'phase=worktree-reap:owner-ledger-read\n'
  load_live_state || { say "reap refused; live-owner ledger unreadable"; return 1; }
  printf 'phase=worktree-reap:origin-fetch\n'
  refresh_origin || return 1
  printf 'phase=worktree-reap:pr-list-query\n'
  load_pr_rows || { say "reap refused; GitHub PR state unreadable"; return 1; }
  if shared_stash_rows="$(timeout -k "$LIFECYCLE_GIT_KILL_AFTER_SECONDS" "$LIFECYCLE_GIT_TIMEOUT_SECONDS" \
    git -C "$REPO" stash list --format='%gd' 2>/dev/null)"; then
    if [ -n "$shared_stash_rows" ]; then REAP_SHARED_STASH=present; else REAP_SHARED_STASH=none; fi
  fi
  worktree_records="$(git -C "$REPO" worktree list --porcelain)" || return 1
  primary="$(primary_worktree_path)"
  local -a paths=() heads=() branches=() locks=() lock_reasons=() remote_delete_branches=() remote_delete_heads=() remote_delete_kinds=()
  local in_tree=0 current_path="" current_head="" current_branch="" current_locked=0 current_lock_reason="" i
  while IFS= read -r line; do
    case "$line" in
      'worktree '*)
        if [ "$in_tree" = 1 ]; then paths+=("$current_path"); heads+=("$current_head"); branches+=("$current_branch"); locks+=("$current_locked"); lock_reasons+=("$current_lock_reason"); fi
        in_tree=1; current_path="${line#worktree }"; current_head=""; current_branch=""; current_locked=0; current_lock_reason=""
        ;;
      'HEAD '*) current_head="${line#HEAD }" ;;
      'branch '*) current_branch="${line#branch refs/heads/}" ;;
      locked*) current_locked=1; current_lock_reason="${line#locked}"; current_lock_reason="${current_lock_reason# }" ;;
      '')
        if [ "$in_tree" = 1 ]; then paths+=("$current_path"); heads+=("$current_head"); branches+=("$current_branch"); locks+=("$current_locked"); lock_reasons+=("$current_lock_reason"); in_tree=0; fi
        ;;
    esac
  done <<< "$worktree_records"
  if [ "$in_tree" = 1 ]; then paths+=("$current_path"); heads+=("$current_head"); branches+=("$current_branch"); locks+=("$current_locked"); lock_reasons+=("$current_lock_reason"); fi
  for ((i=0; i<${#paths[@]}; i++)); do current_indexes["${paths[$i]}"]="$i"; done
  reap_progress_init "${paths[@]}" || return 1
  for ((i=0; i<${#paths[@]}; i++)); do
    branch="${branches[$i]}"
    [ -n "$branch" ] && REAP_WORKTREE_BRANCH_PATHS["$branch"]="${paths[$i]}"
  done
  REAP_WORKTREE_BRANCH_INDEX_READY=1
  (( REAP_PROGRESS_CURSOR == 0 )) || say "reap resumed worktree sweep at $REAP_PROGRESS_CURSOR/${#REAP_SWEEP_PATHS[@]}"
  worktree_started=$SECONDS
  printf 'phase=worktree-reap:worktree-sweep\n'
  for ((i=REAP_PROGRESS_CURSOR; i<${#REAP_SWEEP_PATHS[@]}; i++)); do
    if { (( max_worktrees > 0 && processed_worktrees >= max_worktrees )) \
      || (( worktree_budget_seconds > 0 && SECONDS - worktree_started >= worktree_budget_seconds )); }; then
      say "reap progress phase=worktrees processed=$processed_worktrees next=$i/${#REAP_SWEEP_PATHS[@]}"
      printf 'progress=worktrees next=%s total=%s removed_worktrees=%s skipped_live=%s skipped_safe=%s\n' \
        "$i" "${#REAP_SWEEP_PATHS[@]}" "$removed_worktrees" "$skipped_live" "$skipped_safe"
      return 3
    fi
    path="${REAP_SWEEP_PATHS[$i]}"
    if [ "$path" != "$primary" ] && [[ -n "${current_indexes[$path]+x}" ]]; then
      current_index="${current_indexes[$path]}"
      if ! reap_worktree_candidate "$path" "${heads[$current_index]}" "${branches[$current_index]}" \
        "${locks[$current_index]}" "${lock_reasons[$current_index]}" "$primary"; then
        return 1
      fi
    fi
    reap_progress_advance "$((i + 1))" || return 1
    processed_worktrees=$((processed_worktrees + 1))
  done
  reap_progress_advance "${#REAP_SWEEP_PATHS[@]}" || return 1

  printf 'phase=worktree-reap:stale-registration-prune\n'
  prune_stale_worktree_records || return 1

  printf 'phase=worktree-reap:local-branch-sweep\n'
  load_reap_worktree_branch_index || { say "reap refused; worktree inventory became unreadable"; return 1; }
  local_rows="$(git -C "$REPO" for-each-ref --format='%(refname:short) %(objectname)' refs/heads)" || return 1
  while read -r local_branch local_head; do
    if [ -z "$local_branch" ] || [ "$local_branch" = main ]; then continue; fi
    attached=0
    attached_path="${REAP_WORKTREE_BRANCH_PATHS[$local_branch]:-}"
    [ -n "$attached_path" ] && [ -d "$attached_path" ] && attached=1
    [ "$attached" = 0 ] || continue
    if branch_owner_live "$local_branch"; then skipped_live=$((skipped_live + 1)); continue; fi
    pr_state_for "$local_branch" "$local_head"
    state="$PR_STATE_RESULT"
    count_pr_state_item "local:$local_branch" "$state"
    if [ "$state" = UNKNOWN ]; then
      manifest_record kept-local-branch "$local_branch" "$local_head" pr-state-unreadable || return 1
      skipped_safe=$((skipped_safe + 1))
      say "skip local branch with unreadable PR state $local_branch"
      continue
    fi
    [ "$state" != OPEN ] || continue
    if [[ "$state" != MERGED && "$state" != CLOSED ]] && ! head_on_main "$local_head"; then
      manifest_record kept-local-branch "$local_branch" "$local_head" ambiguous-unmerged || true
      skipped_safe=$((skipped_safe + 1))
      say "skip ambiguous unmerged local branch $local_branch"
      continue
    fi
    if ! head_content_is_preserved "$local_branch" "$local_head"; then
      if ! push_rescue "$local_branch" "$local_head"; then skipped_safe=$((skipped_safe + 1)); continue; fi
    fi
    load_live_state || { say "reap refused; live-owner ledger became unreadable"; return 1; }
    if branch_owner_live "$local_branch"; then skipped_live=$((skipped_live + 1)); continue; fi
    if remove_local_branch "$local_branch" "$local_head"; then removed_local=$((removed_local + 1)); fi
  done <<< "$local_rows"

  printf 'phase=worktree-reap:remote-branch-sweep\n'
  remote_rows="$(git -C "$REPO" for-each-ref --format='%(refname) %(objectname) %(committerdate:unix)' refs/remotes/origin)" || return 1
  while read -r remote_ref remote_head remote_created; do
    [ -n "$remote_ref" ] || continue
    case "$remote_ref" in refs/remotes/origin/HEAD|refs/remotes/origin/main|refs/remotes/origin/rescued/*|refs/remotes/origin/pr/*) continue ;; esac
    remote_branch="${remote_ref#refs/remotes/origin/}"
    if branch_owner_live "$remote_branch"; then skipped_live=$((skipped_live + 1)); continue; fi
    local attached_to_kept=0
    attached_path="${REAP_WORKTREE_BRANCH_PATHS[$remote_branch]:-}"
    [ -n "$attached_path" ] && [ -d "$attached_path" ] && attached_to_kept=1
    [ "$attached_to_kept" = 0 ] || continue
    pr_state_for "$remote_branch" "$remote_head"
    state="$PR_STATE_RESULT"
    count_pr_state_item "remote:$remote_branch" "$state"
    if [ "$state" = UNKNOWN ]; then
      manifest_record kept-remote-branch "$remote_branch" "$remote_head" pr-state-unreadable || return 1
      skipped_safe=$((skipped_safe + 1))
      say "skip remote branch with unreadable PR state $remote_branch"
      continue
    fi
    [ "$state" != OPEN ] || continue
    if ! head_on_main "$remote_head" && [[ "$state" != MERGED && "$state" != CLOSED ]]; then continue; fi
    if ! preserve_nonmerged_closed_head "$remote_branch" "$remote_head" "$state"; then skipped_safe=$((skipped_safe + 1)); continue; fi
    manifest_record removing-remote-branch "$remote_branch" "$remote_head" || return 1
    remote_delete_branches+=("$remote_branch")
    remote_delete_heads+=("$remote_head")
    remote_delete_kinds+=(branch)
  done <<< "$remote_rows"

  if grep -q '^refs/remotes/origin/rescued/' <<< "$remote_rows"; then
    # Finish safe ordinary branch cleanup before the potentially large rescue
    # index. The shared lease/readback helper reserves enough time for the
    # mutation and verification before starting it.
    printf 'phase=worktree-reap:remote-lease-readback\n'
    if flush_remote_deletions remote_delete_branches remote_delete_heads remote_delete_kinds; then
      :
    else
      remote_status=$?
      return "$remote_status"
    fi
    printf 'phase=worktree-reap:main-patch-index\n'
    if load_main_patch_ids; then
      :
    else
      patch_status=$?
      if [ "$patch_status" -eq 3 ]; then return 3; fi
      say "reap refused; could not index origin/main patch ids"
      return 1
    fi
    current_main="$(git -C "$REPO" rev-parse --verify refs/remotes/origin/main 2>/dev/null)" || return 1
    if [ "$MAIN_PATCH_INDEXED_HEAD" != "$current_main" ]; then
      say "reap deferred; origin/main advanced beyond the completed rescue patch index"
      printf 'progress=main-patch-index state=main-advanced\n'
      return 3
    fi
    REAP_RESCUE_MAIN_TREE="$(timeout -k "$LIFECYCLE_GIT_KILL_AFTER_SECONDS" "$LIFECYCLE_GIT_TIMEOUT_SECONDS" \
      git -C "$REPO" rev-parse "$current_main^{tree}" 2>/dev/null)" || return 1
    while read -r remote_ref remote_head remote_created; do
      [[ "$remote_ref" == refs/remotes/origin/rescued/* ]] && rescue_candidate_heads+=("$remote_head")
    done <<< "$remote_rows"
    printf 'progress=rescue-patch-candidates=%s\n' "${#rescue_candidate_heads[@]}"
    prepare_rescue_patch_equivalence "$current_main"
    now="$(date +%s)"
    printf 'phase=worktree-reap:rescue-ref-sweep\n'
    while read -r remote_ref remote_head remote_created; do
      [[ "$remote_ref" =~ ^refs/remotes/origin/rescued/(agent-issue|issue)-([0-9]+)- ]] || continue
      rescue_prefix="${BASH_REMATCH[1]}"
      rescue_issue="${BASH_REMATCH[2]}"
      if [[ -z "${rescue_issue_states[$rescue_issue]+x}" ]]; then
        if rescue_issue_is_closed "$rescue_issue"; then
          rescue_issue_states[$rescue_issue]=closed
        else
          rescue_status=$?
          case "$rescue_status" in
            1) rescue_issue_states[$rescue_issue]=open ;;
            *) rescue_issue_states[$rescue_issue]=unknown ;;
          esac
        fi
      fi
      [ "${rescue_issue_states[$rescue_issue]}" = open ] || continue
      rescue_group="$rescue_prefix-$rescue_issue"
      created="$remote_created"
      [[ "$created" =~ ^[0-9]+$ ]] || continue
      rescue_latest_ref="${rescue_newest_ref[$rescue_group]:-}"
      rescue_latest_at="${rescue_newest_at[$rescue_group]:-0}"
      if [[ -z "$rescue_latest_ref" ]] || (( created > rescue_latest_at )) \
        || { (( created == rescue_latest_at )) && [[ "$remote_ref" > "$rescue_latest_ref" ]]; }; then
        rescue_newest_at[$rescue_group]="$created"
        rescue_newest_ref[$rescue_group]="$remote_ref"
      fi
    done <<< "$remote_rows"
    load_live_state || { say "reap refused; live-owner ledger became unreadable"; return 1; }
    load_rescue_worktree_inventory || { say "reap refused; rescue worktree inventory became unreadable"; return 1; }
    printf 'phase=worktree-reap:rescue-ref-sweep\n'
    while read -r remote_ref remote_head remote_created; do
      [[ "$remote_ref" == refs/remotes/origin/rescued/* ]] || continue
      remote_branch="${remote_ref#refs/remotes/origin/}"
      pr_state_for "" "$remote_head"
      state="$PR_STATE_RESULT"
      rescue_reason=""
      scoped_issue=0
      rescue_issue=""
      if [[ "$remote_branch" =~ ^rescued/(agent-issue|issue)-([0-9]+)- ]]; then
        scoped_issue=1
        rescue_prefix="${BASH_REMATCH[1]}"
        rescue_issue="${BASH_REMATCH[2]}"
        rescue_group="$rescue_prefix-$rescue_issue"
        rescue_issue_state="${rescue_issue_states[$rescue_issue]:-unknown}"
        case "$rescue_issue_state" in
          closed) rescue_reason=closed-issue ;;
          open)
            rescue_latest_ref="${rescue_newest_ref[$rescue_group]:-}"
            if [ -z "$rescue_latest_ref" ]; then
              manifest_record kept-remote-rescue "$remote_branch" "$remote_head" newest-check-failed || return 1
              skipped_safe=$((skipped_safe + 1))
              continue
            elif [ "$remote_ref" != "$rescue_latest_ref" ]; then
              rescue_reason=superseded-open-issue
            elif [ "$state" = OPEN ]; then
              manifest_record kept-remote-rescue "$remote_branch" "$remote_head" open-pr || return 1
              continue
            else
              if rescue_head_is_live "$remote_head"; then
                manifest_record kept-remote-rescue "$remote_branch" "$remote_head" live-worktree || return 1
                skipped_live=$((skipped_live + 1))
              else
                rescue_status=$?
                if [ "$rescue_status" -ne 1 ]; then
                  manifest_record kept-remote-rescue "$remote_branch" "$remote_head" worktree-inventory-unreadable || return 1
                  skipped_safe=$((skipped_safe + 1))
                else
                  manifest_record kept-remote-rescue "$remote_branch" "$remote_head" newest-open-issue || return 1
                fi
              fi
              continue
            fi
            ;;
          *)
            manifest_record kept-remote-rescue "$remote_branch" "$remote_head" issue-state-unreadable || return 1
            skipped_safe=$((skipped_safe + 1))
            skipped_unreadable=$((skipped_unreadable + 1))
            continue
            ;;
        esac
      elif issue_number="$(rescue_issue_number "$remote_branch")"; then
        if rescue_issue_is_closed "$issue_number"; then
          issue_state=closed
        else
          rescue_status=$?
          case "$rescue_status" in
            1) issue_state=open ;;
            *) issue_state=unknown ;;
          esac
        fi
        if [ "$issue_state" = unknown ]; then
          manifest_record kept-remote-rescue "$remote_branch" "$remote_head" issue-state-unreadable || return 1
          skipped_safe=$((skipped_safe + 1))
          skipped_unreadable=$((skipped_unreadable + 1))
          continue
        fi
        created="$remote_created"
        if [ "$issue_state" = closed ] && [[ "$created" =~ ^[0-9]+$ ]] \
          && [ $((now - created)) -ge 604800 ]; then
          rescue_reason=expired-closed-issue
        fi
      fi
      if [ -z "$rescue_reason" ]; then
        if [ "$state" = OPEN ]; then
          manifest_record kept-remote-rescue "$remote_branch" "$remote_head" open-pr || return 1
          continue
        fi
        if rescue_patch_equivalent "$remote_head"; then
          rescue_reason=patch-equivalent
        else
          patch_status=$?
          if [ "$patch_status" -gt 1 ]; then
            manifest_record kept-remote-rescue "$remote_branch" "$remote_head" patch-check-failed || return 1
            skipped_safe=$((skipped_safe + 1))
            continue
          fi
        fi
      fi
      [ -n "$rescue_reason" ] || continue
      count_pr_state_item "rescue:$remote_branch" "$state"
      if [ "$state" = UNKNOWN ]; then
        manifest_record kept-remote-rescue "$remote_branch" "$remote_head" pr-state-unreadable || return 1
        skipped_safe=$((skipped_safe + 1))
        say "skip rescue ref with unreadable PR state $remote_branch"
        continue
      fi
      if rescue_head_is_live "$remote_head"; then
        manifest_record kept-remote-rescue "$remote_branch" "$remote_head" live-worktree || return 1
        skipped_live=$((skipped_live + 1))
        continue
      else
        rescue_status=$?
        if [ "$rescue_status" -ne 1 ]; then
          manifest_record kept-remote-rescue "$remote_branch" "$remote_head" worktree-inventory-unreadable || return 1
          skipped_safe=$((skipped_safe + 1))
          continue
        fi
      fi
      current_main="$(git -C "$REPO" rev-parse --verify refs/remotes/origin/main 2>/dev/null)" || return 1
      if [ "$MAIN_PATCH_INDEXED_HEAD" != "$current_main" ]; then
        manifest_record kept-remote-rescue "$remote_branch" "$remote_head" main-advanced-after-index || return 1
        say "reap deferred; origin/main advanced while rescue refs were being checked"
        printf 'progress=main-patch-index state=main-advanced\n'
        return 3
      fi
      archive_timeout="$LIFECYCLE_GIT_TIMEOUT_SECONDS"
      archive_reserve="$(reap_remote_batch_reserve_seconds)" || return 1
      remaining="$(reap_budget_remaining_seconds)" || return 1
      archive_budget=$((archive_timeout + LIFECYCLE_GIT_KILL_AFTER_SECONDS + archive_reserve))
      if (( remaining <= archive_budget )); then
        manifest_record kept-remote-rescue "$remote_branch" "$remote_head" archive-budget-unavailable || return 1
        skipped_safe=$((skipped_safe + 1))
        if [ "$archive_budget_reported" = 0 ]; then
          say "rescue archive deferred; remaining=${remaining}s archive=${archive_timeout}s lease/readback-reserve=${archive_reserve}s"
          archive_budget_reported=1
        fi
        continue
      fi
      printf 'phase=worktree-reap:rescue-patch-archive\n'
      archive_path="$(archive_rescue_patch "$remote_branch" "$remote_head")" || {
        manifest_record kept-remote-rescue "$remote_branch" "$remote_head" archive-failed || return 1
        skipped_safe=$((skipped_safe + 1))
        continue
      }
      printf 'phase=worktree-reap:rescue-ref-sweep\n'
      manifest_record removing-remote-rescue "$remote_branch" "$remote_head" "reason=$rescue_reason;archive=$archive_path" || return 1
      remote_delete_branches+=("$remote_branch")
      remote_delete_heads+=("$remote_head")
      remote_delete_kinds+=(rescue)
    done <<< "$remote_rows"
  fi

  printf 'phase=worktree-reap:remote-lease-readback\n'
  for remote_delete_kind in "${remote_delete_kinds[@]}"; do
    [ "$remote_delete_kind" != rescue ] || removed_rescues=$((removed_rescues + 1))
  done
  if flush_remote_deletions remote_delete_branches remote_delete_heads remote_delete_kinds; then
    :
  else
    remote_status=$?
    return "$remote_status"
  fi
  reap_progress_clear || { say "reap completed but progress state could not be cleared"; return 1; }
  local reaped_total=$((removed_worktrees + removed_clones + STALE_WORKTREE_RECORDS_REMOVED + removed_local + removed_remote))
  if (( skipped_unreadable > 0 && RESCUE_ISSUE_TOTAL > 0 && RESCUE_ISSUE_UNREADABLE == RESCUE_ISSUE_TOTAL )); then
    say "reap failed; all rescue issue states unreadable; reaped=$reaped_total skipped-unreadable=$skipped_unreadable"
    return 1
  fi
  if (( PR_ITEM_TOTAL > 0 && PR_ITEM_UNREADABLE == PR_ITEM_TOTAL )); then
    say "reap failed; all PR item states unreadable; reaped=$reaped_total skipped-unreadable=$PR_ITEM_UNREADABLE"
    return 1
  fi
  printf 'removed_worktrees=%s removed_clones=%s removed_worktree_registrations=%s removed_local_branches=%s removed_remote_branches=%s skipped_live=%s skipped_safe=%s\n' \
    "$removed_worktrees" "$removed_clones" "$STALE_WORKTREE_RECORDS_REMOVED" "$removed_local" "$removed_remote" "$skipped_live" "$skipped_safe"
  if (( skipped_unreadable + PR_ITEM_UNREADABLE > 0 )); then
    printf 'SLOW reaped=%s skipped-unreadable=%s\n' "$reaped_total" "$((skipped_unreadable + PR_ITEM_UNREADABLE))"
  fi
}

reap() {
  local requested_repo="$REPO_ROOT" primary_repo="${ZF_PRIMARY_REPO_DIR:-$HOME/project/example}" root requested_common primary_common reap_status
  local -a roots=()
  requested_repo="$(git -C "$requested_repo" rev-parse --show-toplevel 2>/dev/null)" || return 1
  primary_repo="$(git -C "$primary_repo" rev-parse --show-toplevel 2>/dev/null)" || {
    say "reap refused; primary checkout unavailable: ${ZF_PRIMARY_REPO_DIR:-$HOME/project/example}"
    return 1
  }
  requested_common="$(git -C "$requested_repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  primary_common="$(git -C "$primary_repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  requested_common="$(realpath -e -- "$requested_common")" || return 1
  primary_common="$(realpath -e -- "$primary_common")" || return 1
  roots+=("$(realpath -e -- "$requested_repo")")
  if [ "$primary_common" != "$requested_common" ]; then
    roots+=("$(realpath -e -- "$primary_repo")")
  fi
  ALL_REPOS=("${roots[@]}")
  for root in "${roots[@]}"; do
    REPO="$root"
    REPO_ROOT="$root"
    REPO_NAME="${ZF_GH_REPO:-$REPO}"
    ORIGIN_REFRESHED=0
    PR_ROWS=""
    PR_READABLE=0
    MAIN_PATCH_IDS=""
    MAIN_PATCH_INDEXED_HEAD=""
    REPO_CONTAINS_CACHE=()
    RESCUE_ISSUE_STATES=()
    if reap_one; then
      :
    else
      reap_status=$?
      return "$reap_status"
    fi
  done
}

stats() {
  local worktree_list worktrees local_branches remote_branches stale=0 line path created now age primary
  local -A seen=()
  load_live_state || return 1
  worktree_list="$(git -C "$REPO" worktree list --porcelain)" || return 1
  worktrees="$(awk '/^worktree /{n++} END{print n+0}' <<< "$worktree_list")"
  primary="$(awk '/^worktree / {print substr($0, 10); exit}' <<< "$worktree_list")"
  local_branches="$(git -C "$REPO" for-each-ref --format='%(refname)' refs/heads | wc -l)"
  remote_branches="$(git -C "$REPO" for-each-ref --format='%(refname)' refs/remotes/origin | awk 'index($0, "/HEAD") == 0 {n++} END{print n+0}')"
  now="$(date +%s)"
  while IFS= read -r line; do
    [[ "$line" == 'worktree '* ]] || continue
    path="${line#worktree }"
    [ -f "$path/.git" ] || continue
    seen["$path"]=1
    [ "$path" != "$primary" ] || continue
    created="$(stat -c %Y -- "$path/.git" 2>/dev/null || true)"
    [[ "$created" =~ ^[0-9]+$ ]] || continue
    age=$((now - created))
    if [ "$age" -gt 86400 ] && ! worktree_owner_live "$path"; then stale=$((stale + 1)); fi
  done <<< "$worktree_list"
  printf 'worktrees=%s local_branches=%s remote_branches=%s stale_over_24h=%s\n' \
    "$worktrees" "$local_branches" "$remote_branches" "$stale"
}

# Repo-side exit hook for final FOLLOWUP reports. Record dependencies before
# finish_worktree decides whether the report is terminal: a dependency-backed
# owner keeps its worktree so the blocked-agent registry can resume it.
hand_exit_followup_dependencies() {
  local target="$1" row row_pid row_name row_model row_effort row_worktree row_brief row_report row_log
  local row_attempt row_started row_role row_ticks row_issues row_nodes
  local name="" report="" owned_issues="" pid="" role="" worktree="" brief="" log="" attempt=0 start_ticks="" owned_nodes=""
  local lib_path lifecycle_repo="$REPO"
  [ -r "$AGENTS_FILE" ] || return 0
  target="$(realpath -m -- "$target")"
  while IFS= read -r row || [ -n "$row" ]; do
    [[ "$row" == *$'\t'* ]] || continue
    IFS=$'\x1f' read -r row_pid row_name row_model row_effort row_worktree row_brief row_report row_log \
      row_attempt row_started row_role row_ticks row_issues row_nodes \
      <<< "${row//$'\t'/$'\x1f'}"
    [ "$row_worktree" = "$target" ] || continue
    name="$row_name"; report="$row_report"; owned_issues="$row_issues"; pid="$row_pid"
    role="$row_role"; worktree="$row_worktree"; brief="$row_brief"; log="$row_log"
    attempt="${row_attempt:-0}"; start_ticks="$row_ticks"; owned_nodes="$row_nodes"
  done < "$AGENTS_FILE"
  [ -n "$name" ] || return 0
  case "$report" in "~/*") report="$HOME/${report:2}" ;; esac
  [ -n "$report" ] || report="$NIGHT/$name-report.md"
  if ! declare -F hand_report_followup_dependencies >/dev/null; then
    lib_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"
    # shellcheck source=./lib.sh
    source "$lib_path"
  fi
  REPO="$REPO_NAME"
  hand_report_followup_dependencies "$name" "$report" "$owned_issues" "$pid" "$role" \
    "$worktree" "$brief" "$log" "$attempt" "$start_ticks" "$owned_nodes" \
    || say "hand exit FOLLOWUP dependency handling failed for $name"
  REPO="$lifecycle_repo"
}

# Repo-side exit hook for hand agents (run-recut.sh's guarded flow queues
# them as hand-<N>): when the watched pid dies, resolve the roster row's
# agent name, report, and owned issues BEFORE watch() drops that row, and let
# lib.sh's hand_report_blocked_on_dependency turn a report whose first line
# is `STATUS: BLOCKED-ON issue M` into a native dependency, one comment, and
# a release-hold requeue on the tied issue (2026-10-07: hand-1914 ended
# BLOCKED-ON issue 1131 and nothing repo-side acted on the report). Sourcing
# lib.sh overwrites this file's REPO (git path) with the gh slug -- same
# save/restore record_pipeline_resume_checkpoint already does.
hand_exit_blocked_on_dependency() {
  local target="$1" row row_pid row_name row_model row_effort row_worktree row_brief row_report row_log
  local row_attempt row_started row_role row_ticks row_issues row_nodes
  local name="" report="" owned_issues="" lib_path lifecycle_repo="$REPO"
  [ -r "$AGENTS_FILE" ] || return 0
  target="$(realpath -m -- "$target")"
  while IFS= read -r row || [ -n "$row" ]; do
    [[ "$row" == *$'\t'* ]] || continue
    IFS=$'\x1f' read -r row_pid row_name row_model row_effort row_worktree row_brief row_report row_log \
      row_attempt row_started row_role row_ticks row_issues row_nodes \
      <<< "${row//$'\t'/$'\x1f'}"
    [ "$row_worktree" = "$target" ] || continue
    name="$row_name"
    report="$row_report"
    owned_issues="$row_issues"
  done < "$AGENTS_FILE"
  [ -n "$name" ] || return 0
  case "$report" in "~/"*) report="$HOME/${report:2}" ;; esac
  [ -n "$report" ] || report="$NIGHT/$name-report.md"
  if ! declare -F hand_report_blocked_on_dependency >/dev/null; then
    lib_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"
    # shellcheck source=./lib.sh
    source "$lib_path"
  fi
  REPO="$REPO_NAME"
  hand_report_blocked_on_dependency "$name" "$report" "$owned_issues" \
    || say "hand exit BLOCKED-ON dependency handling failed for $name"
  REPO="$lifecycle_repo"
}

watch() {
  local target="$1" pid="$2" start_ticks="$3" current_ticks owner owner_target canonical_target
  while pid_live "$pid"; do
    if declare -F agent_reload_checkpoint >/dev/null; then agent_reload_checkpoint; fi
    current_ticks="$(pid_start_ticks "$pid" 2>/dev/null || true)"
    [ -n "$start_ticks" ] && [ "$current_ticks" != "$start_ticks" ] && break
    sleep 10
  done
  source "$_WORKTREE_LIFECYCLE_DIR/hand-completion-refill.sh"
  # A collected watcher can disappear after75: preserve its event first.
  hand_completion_event_publish "$pid" "$start_ticks" "$target" || return $?
  hand_completion_event_run "$REPO" "$HAND_COMPLETION_EVENT"
}

watch_cleanup() {
  local target="$1" pid="$2" start_ticks="$3" current_ticks owner owner_target canonical_target handoff_status=0
  # This internal entry also rejects direct calls before the original target is terminal.
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$start_ticks" =~ ^[0-9]+$ ]] || return 75
  if [[ -d "/proc/$pid" ]]; then
    current_ticks="$(pid_start_ticks "$pid" 2>/dev/null || true)"
    [[ -n "$current_ticks" ]] || return 75
    if [[ "$current_ticks" == "$start_ticks" ]] && pid_live "$pid"; then return 75; fi
  fi
  # A child the agent backgrounded (an ssh tunnel) keeps the transient scope
  # active after the agent exits, and an active scope reads as a live hold
  # owner (2026-10-08: a dead agent's tunnel held its scope for 5 hours).
  [ -z "${ZF_HAND_UNIT:-}" ] || systemctl --user stop "$ZF_HAND_UNIT" >/dev/null 2>&1 || true
  # Stamp the exit HEAD and uncommitted state before cleanup may remove the tree.
  if declare -F hand_registry_record_exit >/dev/null; then
    hand_registry_record_exit "$(realpath -m -- "$target")" "$pid" || say "hand registry exit stamp failed for $target"
  fi
  hand_exit_followup_dependencies "$target"
  finish_worktree "$target" || true
  hand_exit_blocked_on_dependency "$target"
  if [ -e "$AGENTS_FILE" ]; then
    local tmp="$AGENTS_FILE.tmp.$$"
    if awk -F '\t' -v pid="$pid" '$1 != pid' "$AGENTS_FILE" > "$tmp" && mv -- "$tmp" "$AGENTS_FILE"; then
      :
    else
      rm -f -- "$tmp"
    fi
  fi
  if declare -F hand_addendum_after_exit >/dev/null; then
    hand_addendum_after_exit "$(realpath -m -- "$target")" "$pid" \
      || { say "hand addendum exit handling failed for $target"; handoff_status=75; }
  fi
  if [ ! -e "$target" ]; then
    canonical_target="$(realpath -m -- "$target")"
    for owner in "$NIGHT"/.hand-owner-*; do
      [ -f "$owner" ] || continue
      IFS= read -r owner_target < "$owner" || true
      [ "$(realpath -m -- "$owner_target")" = "$canonical_target" ] && rm -f -- "$owner"
    done
  fi
  rm -f -- "$NIGHT/.hand-agent-cpu-$pid" "$NIGHT/.hand-agent-worktree-$pid" "$NIGHT/.hand-agent-worktree-time-$pid"
  return "$handoff_status"
}

# Contained in origin/main or the release by ancestry or, after a rebasing direct landing, by patch.
release_contains() {
  local head="$1" release="$2" base cherry
  for base in refs/remotes/origin/main "$release"; do
    git -C "$REPO" rev-parse --verify -q "$base^{commit}" >/dev/null || continue
    git -C "$REPO" merge-base --is-ancestor "$head" "$base" 2>/dev/null && return 0
    cherry="$(git -C "$REPO" cherry "$base" "$head" 2>/dev/null)" || continue
    grep -q '^+' <<< "$cherry" || return 0
  done
  return 1
}

# Maintainer rule: a fix released to production closes its issue and frees its workspace.
# The batch release path (run-release.sh) invokes this per closed issue: the issue's
# implement (issue-N, agent/issue-N, agent/fix-N-*, agent/auto-issue-N)
# and hand (hand-N) worktrees and local branches go when all their commits are in origin/main or the
# release. Worktree removal is finish_worktree, so owner, lock, resume and dirty gates match run end.
release_cleanup() {
  local issue="$1" release="$2" records line path="" head="" branch="" name ref removed=0 kept=0
  local -a paths=() path_heads=()
  local -A checked_out=()
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || usage
  git -C "$REPO" rev-parse --verify -q "$release^{commit}" >/dev/null || {
    say "release-cleanup #$issue refused; release $release is unknown locally"
    return 1
  }
  release_branch_matches() {
    case "$1" in
      "agent/issue-$issue"|"agent/auto-issue-$issue"|"agent/fix-$issue-"*|"hand-$issue") return 0 ;;
    esac
    return 1
  }
  records="$(git -C "$REPO" worktree list --porcelain)" || return 1
  while IFS= read -r line; do
    case "$line" in
      'worktree '*) path="${line#worktree }"; head=""; branch="" ;;
      'HEAD '*) head="${line#HEAD }" ;;
      'branch '*) branch="${line#branch refs/heads/}" ;;
      '')
        [ -n "$path" ] || continue
        [ -z "$branch" ] || checked_out["$branch"]=1
        name="$(basename -- "$path")"
        if [ "$(dirname -- "$path")" = "$(realpath -m -- "$WORKTREE_ROOT")" ] \
          && { [ "$name" = "issue-$issue" ] || [ "$name" = "hand-$issue" ] || release_branch_matches "$branch"; }; then
          paths+=("$path"); path_heads+=("$head")
        fi
        path=""
        ;;
    esac
  done <<< "$records"$'\n'
  local i
  for ((i=0; i<${#paths[@]}; i++)); do
    path="${paths[$i]}"; head="${path_heads[$i]}"
    if ! release_contains "$head" "$release"; then
      record_kept_worktree "$path" "$head" release-cleanup-commits-outside-main-and-release || true
      say "kept $path; $head has commits outside origin/main and release $release"
      kept=$((kept + 1))
      continue
    fi
    if finish_worktree "$path"; then removed=$((removed + 1)); else kept=$((kept + 1)); fi
  done
  while IFS=' ' read -r ref head; do
    [ -n "$ref" ] || continue
    branch="${ref#refs/heads/}"
    release_branch_matches "$branch" || continue
    # A checked-out branch goes with its worktree above, or stays with it.
    [ -z "${checked_out[$branch]:-}" ] || continue
    if ! release_contains "$head" "$release"; then
      say "left local branch $branch; $head has commits outside origin/main and release $release"
      kept=$((kept + 1))
      continue
    fi
    # git branch -d inside refuses a branch a worktree still has checked out.
    if remove_local_branch "$branch" "$head"; then removed=$((removed + 1)); else kept=$((kept + 1)); fi
  done < <(git -C "$REPO" for-each-ref --format='%(refname) %(objectname)' \
    "refs/heads/agent/issue-$issue" "refs/heads/agent/auto-issue-$issue" "refs/heads/agent/fix-$issue-*" \
    "refs/heads/hand-$issue")
  say "release-cleanup #$issue release=$release removed=$removed kept=$kept"
}

main() {
  local mode="${1:-}" repo_arg="${2:-}" owner_record owner_locked owner_lock_reason owner_lock_status
  case "$mode" in finish|finish-dispatch|watch|watch-cleanup|reap|stats|owner-live|record|release-cleanup) ;; *) usage ;; esac
  if [[ "$mode" == watch-cleanup ]] && ! python3 "$_WORKTREE_LIFECYCLE_DIR/execution-admission.py" inherited; then
    exec python3 "$_WORKTREE_LIFECYCLE_DIR/execution-admission.py" run -- bash "$0" "$@"
  fi
  [ -n "$repo_arg" ] || usage
  REPO="$(git -C "$repo_arg" rev-parse --show-toplevel 2>/dev/null)" || { say "repo unavailable: $repo_arg"; return 1; }
  REPO_ROOT="$(realpath -e -- "$REPO")"
  REPO_NAME="${ZF_GH_REPO:-$REPO}"
  case "$mode" in
    finish|finish-dispatch)
      [ "$#" -eq 3 ] || [ "$#" -eq 4 ] || usage
      if [ "$#" -eq 4 ]; then
        [[ "$4" =~ ^[1-9][0-9]*$ ]] || usage
        CALLER_PID="$4"
      fi
      if [ "$mode" = finish ]; then finish_worktree "$3"; else finish_dispatch "$3"; fi
      ;;
    watch) [ "$#" -eq 5 ] || usage; watch "$3" "$4" "$5" ;;
    watch-cleanup) [ "$#" -eq 5 ] || usage; watch_cleanup "$3" "$4" "$5" ;;
    reap) [ "$#" -eq 2 ] || usage; reap ;;
    release-cleanup) [ "$#" -eq 4 ] || usage; release_cleanup "$3" "$4" ;;
    stats) [ "$#" -eq 2 ] || usage; stats ;;
    record)
      if [ "$#" -lt 5 ] || [ "$#" -gt 6 ]; then usage; fi
      record_external "$3" "$4" "$5" "${6:-}"
      ;;
    owner-live)
      [ "$#" -eq 3 ] || [ "$#" -eq 4 ] || usage
      if [ "$#" -eq 4 ]; then
        [[ "$4" =~ ^[1-9][0-9]*$ ]] || usage
        CALLER_PID="$4"
      fi
      load_live_state || { say "owner check refused; live-owner ledger unreadable"; return 2; }
      owner_record="$(registered_worktree_record "$3" 2>/dev/null || true)"
      if [ -n "$owner_record" ]; then
        IFS=$'\t' read -r _ _ owner_locked owner_lock_reason _ <<< "$owner_record"
        if [ "$owner_locked" = 1 ]; then
          owner_lock_status=0
          worktree_lock_state "$3" "$owner_lock_reason" || owner_lock_status=$?
          if [[ "$owner_lock_reason" =~ (^|[[:space:]:])owner_pid=[1-9][0-9]*([[:space:]]|$) \
            && "$owner_lock_reason" =~ (^|[[:space:]:])owner_start_ticks=[0-9]+([[:space:]]|$) \
            && "$owner_lock_reason" =~ (^|[[:space:]:])unit=[^[:space:]]+ ]]; then
            case "$owner_lock_status" in
              0) return 0 ;;
              1) return 1 ;;
              *) return 2 ;;
            esac
          fi
        fi
      fi
      worktree_owner_live "$3" && return 0
      if [ "${owner_locked:-0}" = 1 ]; then
        owner_lock_status=0
        worktree_lock_state "$3" "$owner_lock_reason" || owner_lock_status=$?
        case "$owner_lock_status" in
          0) return 0 ;;
          2) return 2 ;;
        esac
      fi
      return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "${1:-}" == watch && -r "$_WORKTREE_LIFECYCLE_DIR/runtime-reload.sh" ]]; then
    source "$_WORKTREE_LIFECYCLE_DIR/runtime-reload.sh"
    agent_reload_init "$0" "$@"
    agent_reload_restore
  fi
  main "$@"
fi
