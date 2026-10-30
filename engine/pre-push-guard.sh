#!/usr/bin/env bash
set -uo pipefail

repo="${ZF_REPO:?ZF_REPO is not set}"
agent_home="${AGENT_HOME:-${ZF_HOME:-${HOME:-$HOME}/.zenoforge}}"
log_file="${ZF_PUSH_GUARD_LOG:-$agent_home/night/night.log}"
receipts_file=""

common_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$common_dir" && "$common_dir" != /* ]]; then common_dir="$PWD/$common_dir"; fi
if [[ -n "$common_dir" ]]; then
  common_dir="$(cd -- "$common_dir" 2>/dev/null && pwd -P)" || common_dir=""
  receipts_file="$common_dir/push-guard/repair-records.jsonl"
fi

record_event() {
  local event="$1" reason="$2" branch="${3:-}" local_sha="${4:-}" remote_sha="${5:-}"
  local pr="${6:-}" check="${7:-}" link="${8:-}" at line
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  line="$(printf '%s\0' "$at" "$event" "$reason" "$branch" "$local_sha" "$remote_sha" "$pr" "$check" "$link" \
    | jq -Rsc 'split("\u0000") | {at:.[0],event:.[1],reason:.[2],branch:.[3],local_sha:.[4],remote_sha:.[5],pr:.[6],check:.[7],link:.[8]}')"
  mkdir -p -- "$(dirname -- "$log_file")" 2>/dev/null || true
  if ! printf '%s\n' "$line" >> "$log_file" 2>/dev/null; then
    printf 'pre-push guard: could not append event log (%s)\n' "$event" >&2
  fi
}

allow_api_failure() {
  local event=api-unavailable reason=github-api-unavailable override_reason="${ZF_PUSH_GUARD_OVERRIDE_REASON:-}"
  if [[ -n "$override_reason" ]]; then
    event=override
    reason="$override_reason;github-api-unavailable"
  fi
  record_event "$event" "$reason" "${3:-}" "${1:-}" "${2:-}"
  printf 'pre-push guard: GitHub API unavailable; allowing push.\n' >&2
  exit 0
}

refuse() {
  local reason="$1" branch="$2" local_sha="$3" remote_sha="$4" pr="$5" check="${6:-}" link="${7:-}"
  record_event refusal "$reason" "$branch" "$local_sha" "$remote_sha" "$pr" "$check" "$link"
  exit 1
}

main_red_override_matches() {
  local branch="$1" remote_sha="$2" pr_number="$3" link="$4" run_id context_file result
  run_id="$(grep -oE '/runs/[0-9]+' <<< "$link" | head -1 | grep -oE '[0-9]+' || true)"
  [[ "$run_id" =~ ^[0-9]+$ && -s "$log_file" ]] || return 1
  context_file="$(mktemp 2>/dev/null)" || return 1
  if ! printf '%s\0' "$branch" "$remote_sha" "$pr_number" "run:$run_id" "$link" \
    | jq -Rsc 'split("\u0000") | {branch:.[0],remote_sha:.[1],pr:.[2],check:.[3],link:.[4]}' > "$context_file"; then
    rm -f -- "$context_file"
    return 1
  fi
  if result="$(grep -F '"reason":"main-red-stale-shared-failure"' "$log_file" \
    | jq -s -e --slurpfile wanted "$context_file" '
      ($wanted[0]) as $w | any(.[]; .event == "override" and .reason == "main-red-stale-shared-failure"
        and .branch == $w.branch and .remote_sha == $w.remote_sha and .pr == $w.pr
        and .check == $w.check and .link == $w.link)')"; then
    rm -f -- "$context_file"
    [[ "$result" == true ]]
    return
  fi
  rm -f -- "$context_file"
  return 1
}

hook_path="$common_dir/hooks/pre-push"
invoked_path="$(realpath -m -- "${BASH_SOURCE[0]}")"
if [[ -n "$common_dir" && "$invoked_path" == "$hook_path" ]]; then
  main_guard_tmp="$(mktemp 2>/dev/null || true)"
  if [[ -z "$main_guard_tmp" ]] \
    || ! git show origin/main:engine/pre-push-guard.sh > "$main_guard_tmp" 2>/dev/null \
    || ! cmp -s -- "$invoked_path" "$main_guard_tmp"; then
    rm -f -- "$invoked_path"
    [[ -z "$main_guard_tmp" ]] || rm -f -- "$main_guard_tmp"
    record_event hook-drift-removed live-hook-differs-from-origin-main
    exit 0
  fi
  rm -f -- "$main_guard_tmp"
fi

if [[ "${1:-}" == --record-override ]]; then
  reason="${ZF_PUSH_GUARD_OVERRIDE_REASON:-}"
  pr="${2:-}"
  run_id="${3:-}"
  failure_link="${4:-}"
  linked_run_id="$(grep -oE '/runs/[0-9]+' <<< "$failure_link" | head -1 | grep -oE '[0-9]+' || true)"
  if [[ "$reason" != main-red-stale-shared-failure || ! "$pr" =~ ^[0-9]+$ \
    || ! "$run_id" =~ ^[0-9]+$ || "$linked_run_id" != "$run_id" || ! "$failure_link" =~ ^https:// ]]; then
    record_event refusal invalid-main-red-override "" "" "" "$pr" "$run_id"
    printf 'pre-push guard: invalid main-red override declaration.\n' >&2
    exit 1
  fi
  branch="$(git branch --show-current 2>/dev/null || true)"
  local_sha="$(git rev-parse HEAD 2>/dev/null || true)"
  if ! pr_json="$(gh pr view "$pr" --repo "$repo" --json number,headRefName,headRefOid,baseRefName 2>/dev/null)" \
    || ! jq -e 'type == "object"' <<< "$pr_json" >/dev/null 2>&1; then
    record_event api-unavailable github-api-unavailable "$branch" "$local_sha" "" "$pr" "run:$run_id" "$failure_link"
    printf 'pre-push guard: GitHub API unavailable while recording main-red override; continuing.\n' >&2
    exit 0
  fi
  remote_branch="$(jq -r '.headRefName // empty' <<< "$pr_json")"
  remote_sha="$(jq -r '.headRefOid // empty' <<< "$pr_json")"
  base_branch="$(jq -r '.baseRefName // empty' <<< "$pr_json")"
  if [[ ! "$branch" =~ ^(agent/issue-.+|hand/.+|hand-.+)$ || "$branch" != "$remote_branch" \
    || "$base_branch" != main || ! "$remote_sha" =~ ^[0-9a-f]{40,64}$ ]]; then
    record_event refusal invalid-main-red-pr-state "$branch" "$local_sha" "$remote_sha" "$pr" "run:$run_id" "$failure_link"
    printf 'pre-push guard: main-red override does not match open main PR head.\n' >&2
    exit 1
  fi
  record_event override "$reason" "$branch" "$local_sha" "$remote_sha" "$pr" "run:$run_id" "$failure_link"
  exit 0
fi

while read -r local_ref local_sha remote_ref remote_sha; do
  [[ "$remote_ref" == refs/heads/* ]] || continue
  branch="${remote_ref#refs/heads/}"
  if [[ "$branch" == main && ! "$local_sha" =~ ^0+$ ]]; then
    # Docs [skip ci] pushes can bypass preflight; scan the outgoing commit, not the worktree.
    scan_dir="$(mktemp -d)" || refuse main-nul-scan-unavailable "$branch" "$local_sha" "$remote_sha" ""
    scan_status=0
    if [[ "$remote_sha" =~ ^0+$ ]]; then
      git ls-tree -r --name-only -z "$local_sha" > "$scan_dir/paths" || scan_status=$?
    else
      git diff --name-only --no-renames --diff-filter=ACMRT -z "$remote_sha" "$local_sha" > "$scan_dir/paths" || scan_status=$?
    fi
    scan_paths=()
    while IFS= read -r -d '' path; do scan_paths+=("$path"); done < "$scan_dir/paths"
    if ((scan_status == 0 && ${#scan_paths[@]} > 0)); then
      git show "$local_sha:scripts/check-nul-bytes.mjs" > "$scan_dir/check-nul-bytes.mjs" \
        && node "$scan_dir/check-nul-bytes.mjs" --ref "$local_sha" --files "${scan_paths[@]}" || scan_status=$?
    fi
    rm -rf -- "$scan_dir"
    if ((scan_status != 0)); then
      printf 'Push refused: NUL-byte scan failed for main range %s..%s.\n' "$remote_sha" "$local_sha" >&2
      refuse main-nul-scan-failed "$branch" "$local_sha" "$remote_sha" ""
    fi
    continue
  fi
  [[ "$branch" == agent/issue-* || "$branch" == hand/* || "$branch" == hand-* ]] || continue
  [[ "$local_sha" =~ ^0+$ || "$remote_sha" =~ ^0+$ ]] && continue

  override_reason="${ZF_PUSH_GUARD_OVERRIDE_REASON:-}"
  if [[ -n "$override_reason" && "$override_reason" != conflict-sweeper-conflicting-pr \
    && "$override_reason" != main-red-stale-shared-failure ]]; then
    refuse invalid-override "$branch" "$local_sha" "$remote_sha" "" "$override_reason"
  fi

  if ! pr_list="$(gh pr list --repo "$repo" --head "$branch" --state open \
    --json number,headRefName,headRefOid,baseRefName,mergeable,isDraft --limit 5 2>/dev/null)" \
    || ! jq -e 'type == "array"' <<< "$pr_list" >/dev/null 2>&1; then
    allow_api_failure "$local_sha" "$remote_sha" "$branch"
  fi
  pr_json="$(jq -c --arg branch "$branch" --arg sha "$remote_sha" \
    '[.[] | select(.headRefName == $branch and .baseRefName == "main" and .headRefOid == $sha)][0] // empty' \
    <<< "$pr_list")"
  pr="$(jq -r '.number // empty' <<< "${pr_json:-{}}" 2>/dev/null || true)"
  mergeable="$(jq -r '.mergeable // empty' <<< "${pr_json:-{}}" 2>/dev/null || true)"
  is_draft="$(jq -r '.isDraft // false' <<< "${pr_json:-{}}" 2>/dev/null || true)"
  if [[ -z "$pr_json" ]]; then
    if [[ -n "$override_reason" ]]; then refuse override-pr-not-found "$branch" "$local_sha" "$remote_sha" "" "$override_reason"; fi
    continue
  fi

  checks=""
  checks="$(gh pr checks "$pr" --repo "$repo" --json name,bucket,completedAt,link 2>/dev/null)" || true
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$repo_root" ]] || allow_api_failure "$local_sha" "$remote_sha" "$branch"
  checks="$(node "$repo_root/engine/ci/pr-required-aggregate.mjs" --latest-checks <<<"$checks" 2>/dev/null)" || checks=""
  if ! jq -e 'type == "array"' <<< "$checks" >/dev/null 2>&1; then
    allow_api_failure "$local_sha" "$remote_sha" "$branch"
  fi

  fresh_main_sha=""
  if jq -e 'any(.[]; .bucket == "fail")' <<< "$checks" >/dev/null 2>&1 \
    && git fetch --quiet origin main >/dev/null 2>&1; then
    fresh_main_sha="$(git rev-parse --verify 'origin/main^{commit}' 2>/dev/null || true)"
  fi
  missing_check=""
  main_red_override_used=0
  while IFS=$'\t' read -r check_name check_link completed_at; do
    [[ -n "$check_name" ]] || continue
    if ! [[ "$completed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || [[ -z "$check_link" ]]; then
      allow_api_failure "$local_sha" "$remote_sha" "$branch"
    fi
    receipt_contract="$(mktemp /tmp/zf-ci-receipt.XXXXXX.mjs 2>/dev/null || true)"
    receipt_matches=1
    if [[ -n "$receipt_contract" ]] \
      && git show origin/main:engine/ci-repair-receipt.mjs > "$receipt_contract" 2>/dev/null; then
      node "$receipt_contract" --match "$receipts_file" "$branch" "$remote_sha" "$local_sha" \
        "$check_link" "$check_name" "$completed_at" "$pr" "$fresh_main_sha" >/dev/null 2>&1 && receipt_matches=0
    fi
    [[ -z "$receipt_contract" ]] || rm -f -- "$receipt_contract"
    if [[ "$receipt_matches" != 0 ]]; then
      if main_red_override_matches "$branch" "$remote_sha" "$pr" "$check_link"; then
        record_event override main-red-stale-shared-failure "$branch" "$local_sha" "$remote_sha" "$pr" "$check_name" "$check_link"
        main_red_override_used=1
        continue
      fi
      missing_check="$check_name"
      missing_link="$check_link"
      missing_completed_at="$completed_at"
      break
    fi
  done < <(jq -r '.[] | select(.bucket == "fail") | [.name // "",.link // "",.completedAt // ""] | @tsv' <<< "$checks")

  if [[ -n "$missing_check" ]]; then
    run_id="$(grep -oE '/runs/[0-9]+' <<< "$missing_link" | head -1 | grep -oE '[0-9]+' || true)"
    printf 'Push refused: PR #%s latest CI check failed on head %s: %s%s\n' \
      "$pr" "$remote_sha" "$missing_check" "${run_id:+ (run $run_id)}" >&2
    printf 'Read the failed CI step, then run the exact failing unit command locally through:\n' >&2
    printf 'node "$HOME/.zenoforge/checkout/scripts/branch-delivery-preflight.mjs" --mode push --target main --repair-ci-branch %q --repair-ci-failure-link %q --repair-ci-check %q --repair-ci-failed-head %q --repair-ci-failed-at %q --repair-ci-failing-path %q --repair-ci-command %q\n' \
      "$branch" "$missing_link" "$missing_check" "$remote_sha" "$missing_completed_at" '<failing test file>' '<exact failing command from CI log>' >&2
    printf 'For a complete check, remove --repair-ci-failing-path and add --repair-ci-full-check; use it only after running the entire failed check. A focused unit records focused-passed, never shard passed.\n' >&2
    printf 'If local infrastructure prevents that command, remove --repair-ci-failing-path and replace --repair-ci-command with --repair-ci-only-reason %q. See %s\n' \
      '<specific CI-only limitation>' "https://github.com/$repo/blob/main/engine/night/dispatch.sh" >&2
    printf 'For diff-unrelated recovery, --repair-ci-stale-on-main requires the exact unit to pass on tested HEAD and fresh origin/main; --repair-ci-reproduces-on-main requires failure on both. Both require the path outside the PR diff.\n' >&2
    printf 'If the same failure reproduces on origin/main outside the PR diff, use --repair-ci-reproduces-on-main with --repair-ci-failing-path %q.\n' \
      '<failing test file>' >&2
    refuse failed-ci-without-receipt "$branch" "$local_sha" "$remote_sha" "$pr" "$missing_check" "$missing_link"
  fi

  if [[ -n "$override_reason" ]]; then
    if [[ "$override_reason" == conflict-sweeper-conflicting-pr && "$mergeable" == CONFLICTING ]]; then
      record_event override "$override_reason" "$branch" "$local_sha" "$remote_sha" "$pr"
      continue
    fi
    if [[ "$override_reason" == main-red-stale-shared-failure && "$main_red_override_used" == 1 ]]; then
      continue
    fi
    if [[ "$override_reason" == main-red-stale-shared-failure ]]; then
      refuse invalid-main-red-override "$branch" "$local_sha" "$remote_sha" "$pr" "$override_reason"
    fi
    refuse invalid-conflict-override "$branch" "$local_sha" "$remote_sha" "$pr" "$override_reason"
  fi

  if ! git merge-base --is-ancestor "$remote_sha" "$local_sha" >/dev/null 2>&1; then
    check_count="$(jq 'length' <<< "$checks")"
    all_green="$(jq -r 'length > 0 and all(.[]; .bucket == "pass")' <<< "$checks")"
    if [[ "$mergeable" == MERGEABLE && "$is_draft" == false && "$check_count" -gt 0 && "$all_green" == true ]]; then
      printf 'Push refused: PR #%s is mergeable and every reported check passed at remote head %s. Keep this head for the scheduler merge lane. See %s\n' \
        "$pr" "$remote_sha" "https://github.com/$repo/blob/main/docs/agents/issue-pipeline.md" >&2
      refuse green-mergeable-non-ff "$branch" "$local_sha" "$remote_sha" "$pr"
    fi
  fi
done

exit 0
