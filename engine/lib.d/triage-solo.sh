# Triage batch selection for retry-alone issues (queue row 897). The selection
# helpers run inside issue-pipeline.sh's run_intake_dispatch(), where
# TRIAGE_BATCH_IDS, TRIAGE_RETRY_ALONE, triage_slots and triage_skip() live;
# the solo-run helpers run inside run-triage-batch.sh, where INCLUDED_IDS,
# SOLO_RETRY_AT_START and STATUS live. They live here only because both
# scripts are at their size-ratchet baseline.
# 2026-11-21: a flagged issue used to replace the whole batch, so each one
# cost a full 11-19 minute batch run in which nothing else was triaged, and a
# batch that failed whole flagged every member -- 9 of 13 dispatches ran one
# flagged issue alone while 25-55 issues waited. Now a flagged issue waits
# its turn behind the normal batch and gets one solo run, capped at two solo
# result failures.

# triage_flagged_selection <issue> <queue-label>, with the loop's candidate
# snapshot JSON on stdin. Called from the two selection loops after every
# earlier skip check has passed. A flagged issue carrying the maintainer test
# label keeps the old behaviour (incident guard founder-filed-issue-triage-
# starvation) and runs alone at once: returns 0 and the caller breaks its
# loop with this issue as the whole batch. Any other flagged issue is
# remembered as the solo candidate -- the first one across both loops -- and
# the caller goes on filling the normal batch; triage_solo_candidate_dispatch
# decides after both loops whether the candidate runs.
triage_flagged_selection() {
  local n="$1" label="$2" candidates
  candidates="$(cat)"
  if issue_has_maintainer_test_label "$(jq -c --argjson n "$n" '[.[] | select(.number == $n)][0]' <<< "$candidates")"; then
    if ensure_issue_roadmap_parent_for_dispatch "$n" "$label"; then
      TRIAGE_BATCH_IDS=("$n")
      TRIAGE_RETRY_ALONE=1
      return 0
    fi
    triage_skip roadmap_parent
    return 1
  fi
  if [ -z "${TRIAGE_SOLO_CANDIDATE:-}" ]; then
    TRIAGE_SOLO_CANDIDATE="$n"
    TRIAGE_SOLO_CANDIDATE_LABEL="$label"
  fi
  return 1
}

# triage_solo_candidate_dispatch -- after both selection loops: the remembered
# solo candidate runs alone only when no unflagged issue was selected and a
# slot is free, so triage_slots above 0 means no batch unit is active. Always
# returns 0; a candidate whose roadmap placement fails is skipped, not run.
triage_solo_candidate_dispatch() {
  [ "${#TRIAGE_BATCH_IDS[@]}" -eq 0 ] || return 0
  [ -n "${TRIAGE_SOLO_CANDIDATE:-}" ] || return 0
  [ "$triage_slots" -gt 0 ] || return 0
  if ! ensure_issue_roadmap_parent_for_dispatch "$TRIAGE_SOLO_CANDIDATE" "$TRIAGE_SOLO_CANDIDATE_LABEL"; then
    triage_skip roadmap_parent
    return 0
  fi
  TRIAGE_BATCH_IDS=("$TRIAGE_SOLO_CANDIDATE")
  TRIAGE_RETRY_ALONE=1
}

# triage_solo_flag_clear_after_model_call -- called from run-triage-batch.sh
# right after the batch's model call returned, with any exit status: a solo
# retry run -- one whose only included issue entered flagged -- takes the
# flag off before results are handled, so the same flag never buys a second
# solo run. A run that ends before the model call (queued, deferred, quota
# stop) never calls this and leaves the flag. Always returns 0.
triage_solo_flag_clear_after_model_call() {
  [ "${#INCLUDED_IDS[@]}" -eq 1 ] || return 0
  [ -n "${SOLO_RETRY_AT_START[${INCLUDED_IDS[0]}]:-}" ] || return 0
  if ! state_merge "${INCLUDED_IDS[0]}" 'del(.triage_batch_retry_alone)'; then
    record_env_fault env:triage-result-state triage-batch "${INCLUDED_IDS[0]}" "could not clear the solo retry flag after the model call" || true
  fi
}

# triage_solo_count_result_failure <issue> <reason> -- called from
# run-triage-batch.sh's triage_batch_fail_issue() after its stale-result
# guards and attempt bump. Solo retry runs count only result failures --
# model exit 0 with an invalid or missing record; a non-zero exit, timeout or
# provider fault does not count. Returns 1 when nothing was counted or the
# first failure was counted: the caller continues its ordinary handling.
# Returns 0 at the second failure, after the terminal path: the issue is not
# returned to a queue.
triage_solo_count_result_failure() {
  local n="$1" reason="$2" solo_result_failures
  [ "$STATUS" -eq 0 ] || return 1
  [ "${#INCLUDED_IDS[@]}" -eq 1 ] || return 1
  [ -n "${SOLO_RETRY_AT_START[$n]:-}" ] || return 1
  solo_result_failures=$(( $(state_read "$n" | jq -r '.triage_solo_result_failures // 0') + 1 ))
  if ! state_merge "$n" ".triage_solo_result_failures = $solo_result_failures"; then
    record_env_fault env:triage-result-state triage-batch "$n" "could not count the solo triage result failure" || true
  fi
  [ "$solo_result_failures" -ge 2 ] || return 1
  conclude_run "$n" not-completed "two solo triage result failures; the last one: $reason" || true
  # Row 897 round 2: the conclusion is pipeline state, but the supervisor
  # learns the issue left the queue through the engine's existing notice
  # path (quarantine.sh's quarantine_supervisor_notice). A failed notice
  # never undoes or fails the conclusion.
  quarantine_supervisor_notice triage solo-concluded "issue=#$n reason=$reason" \
    || echo "run-triage-batch: #$n conclusion notice failed; the conclusion stands" >&2
  echo "run-triage-batch: #$n hit the solo retry cap of two result failures; it does not return to a queue" >&2
  return 0
}
