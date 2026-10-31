
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
  local head_ref identity touches_lessons pr_state reconcile_script agent_home manifest_failed=0 incident_guards_file incident_guards_path
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
  incident_guards_file="$(zf_config_file state/incident-guards.json 2>/dev/null || true)"
  if [[ "$incident_guards_file" == "$ZF_REPO_DIR/"* ]]; then
    incident_guards_path="${incident_guards_file#"$ZF_REPO_DIR"/}"
  else
    incident_guards_path="${ZF_PACK_REL:-engine}/state/incident-guards.json"
  fi
  if ! identity="$(gh pr view "$pr" --repo "$REPO" --json headRefName,headRefOid,files,state,mergeCommit \
    -q '[.headRefName, .headRefOid, any(.files[]; (.path | startswith("lessons/")) or .path == "'"$incident_guards_path"'"), .state, (.mergeCommit.oid // "")] | @tsv')"; then
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
      reconcile_script="${ZF_ENGINE_LIVE:-$agent_home/checkout/engine}/land-direct-main.sh"
      [[ -r "$reconcile_script" ]] || reconcile_script="$ZF_ENGINE_DIR/land-direct-main.sh"
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


# rebase_agent_pr_onto_main <head_ref> <base_sha> <pr_number>
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
  local head_ref="$1" base_sha="$2" pr_number="${3:-}" scratch
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
    if declare -F pack_rebase_hook >/dev/null && ! pack_rebase_hook "$scratch" "$pr_number"; then
      result=2
    elif ! ZF_PUSH_GUARD_OVERRIDE_REASON=conflict-sweeper-conflicting-pr guarded_write git -C "$scratch" push origin \
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

    if declare -F merge_agent_pr_migration_gate >/dev/null && ! merge_agent_pr_migration_gate "$n" "$pr_number" "$match_head_commit"; then
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

  if [ "$unattended" != "1" ] && declare -F merge_agent_pr_migration_gate >/dev/null \
    && ! merge_agent_pr_migration_gate "$n" "$pr_number" "$match_head_commit"; then
    return 1
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

  if declare -F fruit_migration_order_gate >/dev/null && ! fruit_migration_order_gate "$pr_number" "$match_head_commit"; then
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
      if declare -F fruit_migration_order_gate >/dev/null && ! fruit_migration_order_gate "$pr_number" "$match_head_commit"; then
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
