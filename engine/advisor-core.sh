#!/usr/bin/env bash
# advisor-core.sh -- shared "resume a persisted verdict / persist a fresh
# one / apply its GitHub comment exactly once" core for the advisor leg.
# Source this, do not execute it (same convention as lib.sh).
#
# Pulled out of run-advisor.sh 2026-09-19, the same day an external code
# review found a real gap in the resume mechanism commit 54f148be6 had just
# added directly to that script: the resume check compared the full fresh
# {title, body, comments} against what was stored at persist time, with no
# way to distinguish "the ticket genuinely changed" from "my own Apply
# already posted its own comment successfully, and only a LATER step (the
# label swap) failed". The second shape, taken literally, made the resume
# check discard a perfectly good pending verdict in exactly the scenario it
# exists to protect: comment lands, next side-effect hiccups, next tick's
# fresh `gh issue view` now includes the advisor's own comment, compares
# unequal to the pre-comment snapshot, and "input changed" wins -- a real
# 8-30+ minute web-advisor-provider re-reasoning pass paid for a second time,
# purely because the fix's OWN success looked like drift.
#
# Two things closed here, together, because they are the same root cause
# (this leg treating "a verdict was computed" and "a verdict was applied"
# as one indivisible step) surfacing at two different points:
#
#   1. Effect receipts (advisor_apply_comment_with_receipt() below) --
#      Apply's own `gh issue comment` is now planned, posted, and confirmed
#      as a tracked side-effect of THIS pending verdict, not a bare
#      fire-and-forget apply_gh_write call. advisor_resume_check() below
#      subtracts a fresh comment from the comparison ONLY when it can PROVE
#      -- by GitHub's own assigned comment id, matched exactly, never
#      inferred -- that this exact pending verdict already produced it, so
#      its own successful side-effect is never mistaken for "the ticket
#      changed", while a genuinely new comment (a human, a different bot,
#      or an edit of an existing one) still is. No hashing/fingerprinting
#      anywhere in this comparison (the project hash ban; the same
#      house rule same_failure_streak() (lib.sh) already states) -- a
#      GitHub-assigned comment id is a real foreign identifier, not a
#      digest this code derives from content.
#
#   2. Episode-sequence guard (advisor_persist_pending() below,
#      advisor_episode_seq the state field) -- route_to_advisor()/
#      give_up_on_issue() (lib.sh) increment advisor_episode_seq every time
#      they start a fresh episode. A reasoning pass records the value that
#      was current when it began (run-advisor.sh's own dispatch call site);
#      advisor_persist_pending() re-checks that value, inside the SAME
#      state_merge call that would write the verdict, against whatever
#      advisor_episode_seq reads NOW. A mismatch means a new episode began
#      while this pass was still in flight (a stale dispatch that only just
#      finished polling, or a genuinely stuck old process) -- that result
#      must never be written as pending or applied. One state_merge call,
#      not a separate check-then-write, is what makes the guard atomic
#      against the same class of race route_to_advisor()/route_to_recut()/
#      give_up_on_issue() already close for the label side of this state
#      machine ("a failed state_merge must not move the label", applied
#      here to a data field instead).
#
# Written to be usable by a future multi-ticket caller too (not built yet
# -- see run-advisor.sh's own header for why THIS rollout stays scoped to
# the single-ticket path): every function here takes its issue number and
# JSON explicitly as arguments, none of it reads run-advisor.sh's own
# script-global variables.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

# Compare the ruling that controls routing and work, not the advisor's
# explanation. Sorting path arrays and folding whitespace avoids churn from
# formatting changes without hiding a changed decision.
advisor_verdict_material() {
  local ruling="$1" effective="$2" ruling_file result
  ruling_file="$(jq_arg_file "$ruling")" || return 1
  if ! result="$(jq -ncS --arg effective "$effective" --slurpfile ruling "$ruling_file" '
    def text($value): ($value // "" | gsub("[[:space:]]+"; " ") | sub("^ "; "") | sub(" $"; ""));
    {
      effective_verdict: $effective,
      risk_class: (if $effective == "misclassified" then ($ruling[0].risk_class // "") else "" end),
      level: (if $effective == "misclassified" then ($ruling[0].level // "") else "" end),
      decision_md: (if $effective == "advised" or $effective == "guarded" then text($ruling[0].decision_md) else "" end),
      recut_md: (if $effective == "recut" then text($ruling[0].recut_md) else "" end),
      founder_question_md: (if $effective == "maintainer" then text($ruling[0].founder_question_md) else "" end),
      founder_subject: (if $effective == "maintainer" then text($ruling[0].founder_subject) else "" end),
      merge_conditions_md: text($ruling[0].merge_conditions_md),
      required_test_paths: (($ruling[0].required_test_paths // []) | unique | sort),
      expected_packages_addendum: (if $effective == "misclassified" then (($ruling[0].expected_packages_addendum // []) | unique | sort) else [] end),
      duplicate_of: ($ruling[0].duplicate_of // null)
    }
  ' )"; then
    rm -f "$ruling_file"
    return 1
  fi
  rm -f "$ruling_file"
  printf '%s\n' "$result"
}

# advisor_convergence_action <prior-state-json> <material-json> <effective> <ruling-json>
# Legacy states keep advisor_decision when route_to_advisor clears advisor_ruled_at.
advisor_convergence_action() {
  local prior="$1" material="$2" effective="$3" ruling="$4" ruling_file material_file result
  ruling_file="$(jq_arg_file "$ruling")" || return 1
  material_file="$(jq_arg_file "$material")" || { rm -f "$ruling_file"; return 1; }
  if ! result="$(jq -r --arg effective "$effective" --slurpfile material "$material_file" --slurpfile ruling "$ruling_file" '
    def text($value): ($value // "" | gsub("[[:space:]]+"; " ") | sub("^ "; "") | sub(" $"; ""));
    if $effective == "tracker" then "same"
    elif .advisor_last_verdict.material == null
      and (.advisor_ruled_at != null or .state == "needs-advisor")
      and (.advisor_decision | type) == "string"
      and ($effective == "advised" or $effective == "guarded")
      and (($effective == "guarded") == (.guarded == true))
      and text(.advisor_decision) == text($ruling[0].decision_md)
      and text(.merge_conditions_md) == text($ruling[0].merge_conditions_md)
      and ((.required_test_paths // []) | unique | sort) == (($ruling[0].required_test_paths // []) | unique | sort) then
      if .advisor_convergence_pass == true then "recut"
      elif text($ruling[0].decision_md) != "" then "one-pass"
      else "recut" end
    elif .advisor_last_verdict.material == null then "new"
    elif .advisor_last_verdict.material != $material[0] then
      if ((.advisor_last_verdict.material.effective_verdict // "") == "advised"
        or (.advisor_last_verdict.material.effective_verdict // "") == "guarded"
        or (.advisor_last_verdict.material.effective_verdict // "") == "misclassified")
        and ($effective == "advised" or $effective == "guarded" or $effective == "misclassified") then "recut"
      else "new" end
    elif ($effective == "advised" or $effective == "guarded" or $effective == "misclassified") then
      if .advisor_convergence_pass == true then "recut"
      elif text($ruling[0].decision_md) != "" then "one-pass"
      else "recut" end
    else "same" end
  ' <<< "$prior")"; then
    rm -f "$ruling_file" "$material_file"
    return 1
  fi
  rm -f "$ruling_file" "$material_file"
  printf '%s\n' "$result"
}

advisor_append_convergence_brief() {
  local n="$1" points="$2" current next file points_file points_json
  [ -n "$points" ] || return 0
  current="$(state_read "$n" | jq -r '.brief_md // empty')" || return 1
  points_file="$(jq_arg_file "$points")" || return 1
  next="$(cat "$points_file")"
  rm -f "$points_file"
  next="${current:+$current$'\n\n'}## Advisor convergence fix points

$next"
  file="$(jq_arg_file "$next")" || return 1
  points_json="$(jq -n --rawfile b "$file" '$b')" || { rm -f "$file"; return 1; }
  rm -f "$file"
  state_merge "$n" ".brief_md = $points_json"
}

# Record one ticket-scoped advisor failure. Batch parse failures share this
# path with the single-ticket caller so attempts, backoff, diagnostics, and
# the bounded not-completed transition stay identical.
# advisor_record_failed_attempt <n> <reason> <pause> <tail> <output> <status> [caller] [model] [batch-job-id]
advisor_record_failed_attempt() {
  local n="$1" reason="$2" should_pause="${3:-1}" tail="$4" call_output="$5" status="$6"
  local caller="${7:-}" model="${8:-}" batch_job_id="${9:-}"
  local prior old_reason old_tail old_streak streak reason_json tail_json reason_file tail_file attempts

  if [ -n "$batch_job_id" ]; then
    prior="$(state_read "$n")"
    if [ "$(jq -r '.advisor_batch_parse_failure_job_id // empty' <<< "$prior")" = "$batch_job_id" ]; then
      echo "advisor_record_failed_attempt: #$n -- batch job $batch_job_id already counted; skipping duplicate parse failure" >&2
      return 0
    fi
  fi

  state_bump_attempts "$n" || return 1
  if [ -n "$model" ]; then
    pause_for_backoff "$n" "$call_output" "$status" "$should_pause" web-advisor-provider "$model" "$caller" || return 1
  elif [ -n "$caller" ]; then
    pause_for_backoff "$n" "$call_output" "$status" "$should_pause" web-advisor-provider unknown "$caller" || return 1
  else
    pause_for_backoff "$n" "$call_output" "$status" "$should_pause" web-advisor-provider || return 1
  fi
  if [ "${MODEL_CALL_ENVIRONMENTAL_FAILURE:-0}" = 1 ]; then
    state_unbump_attempts "$n" || return 1
    echo "advisor_record_failed_attempt: #$n agent binary/tool unavailable; kept advisor stage and refunded attempt" >&2
    return 0
  fi
  if model_call_is_configuration_error "$call_output" "$status"; then
    echo "advisor_record_failed_attempt: #$n configuration fault; attempt refunded and advisor held" >&2
    return 0
  fi

  prior="$(state_read "$n")"
  old_reason="$(jq -r '.last_failure_reason // ""' <<< "$prior")"
  old_tail="$(jq -r '.last_failure_tail // ""' <<< "$prior")"
  old_streak="$(jq -r '.same_failure_streak // 0' <<< "$prior")"
  streak="$(same_failure_streak "$old_reason" "$old_tail" "$reason" "$tail" "$old_streak")"
  reason_file="$(jq_arg_file "$reason")"
  tail_file="$(jq_arg_file "$tail")"
  reason_json="$(jq -n --rawfile r "$reason_file" '$r')"
  tail_json="$(jq -n --rawfile t "$tail_file" '$t')"
  rm -f "$reason_file" "$tail_file"
  if [ -n "$batch_job_id" ]; then
    local job_file job_json
    job_file="$(jq_arg_file "$batch_job_id")"
    job_json="$(jq -n --rawfile job "$job_file" '$job')"
    rm -f "$job_file"
    state_merge "$n" ".last_failure_reason = $reason_json | .last_failure_tail = $tail_json | .same_failure_streak = $streak | .advisor_batch_parse_failure_job_id = $job_json" || return 1
  else
    state_merge "$n" ".last_failure_reason = $reason_json | .last_failure_tail = $tail_json | .same_failure_streak = $streak" || return 1
  fi

  attempts="$(state_attempts "$n")"
  if [ "$attempts" -ge "$CONCLUDE_RUN_ATTEMPT_CAP" ]; then
    record_run_decision "$n" wrapper "Advisor could not complete a run after $attempts attempts: $reason" 1 || return 1
    conclude_run "$n" not-completed "The advisor could not complete a run after $attempts attempts. Missing capability: whatever this specific failure needs (see the reason below) -- this is an environment/tooling gap, not a judgment the advisor reached and could not make. Last reason: $reason" \
      || echo "advisor_record_failed_attempt: conclude_run refused outcome=not-completed for #$n -- see its own stderr above; ticket stays in flight for the next dispatch" >&2
  fi
}

# apply_gh_write <gh subcommand and args...> -- every mutating `gh` call
# applying an advisor verdict (a comment, the final label swap) goes
# through this instead of guarded_write directly (guarded_write itself is
# still what this delegates to for DRY_RUN and for the actual call).
# Defect 2, 2026-09-15 (zf-advisor-1205, live): those calls had no
# failure handling at all -- `Post "https://api.github.com/graphql":
# net/http: TLS handshake timeout` crashed the whole run under `set -e`
# AFTER the (paid for) model call verdict was already computed, discarding
# it with nothing recorded. run-advisor.sh's own initial `gh issue view`
# call already routes any failure through record_env_fault() and exits
# before anything is charged to the ticket; these later calls needed the
# equivalent, not a copy of that exact shape, because by this point in the
# run there is a real verdict to protect, not just a read to retry.
#
# gh_failure_is_transient() (lib.sh) draws the line: a network/TLS/
# timeout/5xx shape records an environment fault (env:gh-api, same
# signature the initial gh issue view call already uses, so the systemic
# check sees one ledger, not two) and ends this run cleanly -- exit 0,
# nothing charged (fail_attempt() is the only thing that ever bumps
# .attempts here, and this path never reaches it), retried next tick. A
# genuine `gh` refusal (404, permissions, a malformed mutation) is NOT in
# that pattern and stays a real failure: this prints it and exits
# non-zero, same as an unwrapped `guarded_write gh ...` always did, so
# `set -e` still kills the run and the systemd unit still shows failed.
#
# Not applied to admit_guarded() (lib.sh, called for the guarded verdict)
# or notify_email_verbatim() (a different failure class -- Gmail, not
# `gh`): both stay outside this fix's scope, same as this defect's own
# ticket scoped it (run-advisor.sh's own apply block).
#
# 2026-09-19: moved here from run-advisor.sh unchanged, alongside the
# resume/persist/comment-receipt functions that already depended on it --
# a future multi-ticket caller needs the identical transient-failure
# contract for its own writes, not a second hand-copy.
#
# CALL THIS AS A BARE STATEMENT, never as `x="$(apply_gh_write ...)"` --
# found live writing advisor_apply_comment_with_receipt() below: `exit`
# inside a command-substitution subshell only kills that subshell, not the
# calling script, so wrapping this call in `$(...)` silently defeats its
# entire transient/hard-failure contract (the caller sees a captured
# string, control returns normally, `set -e` never fires). $out's own
# echo, just below, is deliberately the SAME line whether this returns 0
# or exits -- APPLY_GH_WRITE_OUTPUT (a plain global, not a return value
# bash has no way to carry a string in) is how a caller that needs the
# successful call's own stdout (gh issue comment's created-comment URL)
# reads it back, after this returns 0, not by capturing this call itself.
APPLY_GH_WRITE_OUTPUT=""
apply_gh_write() {
  local out status
  APPLY_GH_WRITE_OUTPUT=""
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] $*" >&2
    return 0
  fi
  set +e
  out="$("$@" 2>&1)"
  status=$?
  set -e
  [ -n "$out" ] && echo "$out"
  if [ "$status" -eq 0 ]; then
    APPLY_GH_WRITE_OUTPUT="$out"
    return 0
  fi
  if gh_failure_is_transient "$out"; then
    record_env_fault env:gh-api advisor "${N:-0}" "$out"
    echo "run-advisor: #${N:-0} -- transient gh failure applying the verdict; recorded as an environment fault (env:gh-api), not charged to this ticket; will retry next tick. Detail: $out" >&2
    # A batch has independent tickets to finish after one transient write.
    # Its caller opts in and handles the non-zero return; the single-ticket
    # path preserves its existing clean-exit behavior.
    [ "${ADVISOR_APPLY_SOFT_FAILURE:-0}" = "1" ] && return 2
    exit 0
  fi
  echo "run-advisor: #${N:-0} -- gh call failed applying the verdict (not classified as transient -- treating as a real failure): $out" >&2
  [ "${ADVISOR_APPLY_SOFT_FAILURE:-0}" = "1" ] && return 1
  exit 1
}

# Apply new repository-owner ruling comments before either advisor path can
# poll or dispatch. A comment is the decision source; its URL is the durable
# cursor and marker, so partial retries do not repost or apply stale verdicts.
ADVISOR_MAINTAINER_RULING_APPLIED=0
advisor_apply_maintainer_ruling() {
  local n="$1" issue_json="$2" prior_state="$3"
  local N="$n" owner after rulings count latest_at latest_url marker body_file patch episode filter
  local ADVISOR_APPLY_SOFT_FAILURE=1
  ADVISOR_MAINTAINER_RULING_APPLIED=0

  if ! jq -e 'any(.labels[]?; .name == "needs-advisor")' >/dev/null 2>&1 <<< "$issue_json"; then
    return 0
  fi

  owner="${REPO%%/*}"
  after="$(jq -r '.founder_ruling_comment_at // empty' <<< "$prior_state")"
  if ! rulings="$(jq -c --arg owner "$owner" --arg after "$after" '
    [.comments[]?
      | select((.author.login // "" | ascii_downcase) == ($owner | ascii_downcase))
      | select((.body // "") | test("^维护者(补充)?裁决"))
      | select((.createdAt // "") > $after)]
    | sort_by(.createdAt)
  ' <<< "$issue_json")"; then
    echo "advisor_apply_maintainer_ruling: #$n -- could not read maintainer ruling comments; skipping advisor dispatch" >&2
    return 1
  fi
  count="$(jq 'length' <<< "$rulings")"
  [ "$count" -gt 0 ] || return 0

  latest_at="$(jq -r '.[-1].createdAt // empty' <<< "$rulings")"
  latest_url="$(jq -r '.[-1].url // empty' <<< "$rulings")"
  if [ -z "$latest_at" ] || [ -z "$latest_url" ]; then
    echo "advisor_apply_maintainer_ruling: #$n -- newest maintainer ruling has no timestamp or source URL; skipping advisor dispatch" >&2
    return 1
  fi
  marker="<!-- advisor-maintainer-rulings-through:$latest_url -->"
  mkdir -p "$AGENT_HOME"
  body_file="$(mktemp "$AGENT_HOME/advisor-maintainer-ruling.XXXXXX")" || return 1
  if ! jq -r --arg disclaimer "$BOT_DISCLAIMER" --arg marker "$marker" '
    $disclaimer + "\n\n**Maintainer ruling applied without advisor.**\n\n" +
    (map("Source: " + (.url // .createdAt) + "\n\n> " + ((.body // "") | gsub("\n"; "\n> "))) | join("\n\n")) +
    "\n\n" + $marker
  ' <<< "$rulings" > "$body_file"; then
    rm -f "$body_file"
    echo "advisor_apply_maintainer_ruling: #$n -- could not build the ruling summary; skipping advisor dispatch" >&2
    return 1
  fi
  if ! jq -e --arg marker "$marker" 'any(.comments[]?; ((.body // "") | contains($marker)))' \
    >/dev/null 2>&1 <<< "$issue_json"; then
    if ! apply_gh_write gh issue comment "$n" --repo "$REPO" --body-file "$body_file"; then
      rm -f "$body_file"
      return 1
    fi
  fi
  rm -f "$body_file"

  episode="$(jq -r '.advisor_episode_seq // 0' <<< "$prior_state")"
  patch="$(jq -n --arg at "$latest_at" --arg url "$latest_url" \
    '{founder_ruling_comment_at:$at, maintainer_ruling_comment_url:$url, maintainer_ruling_source:"github-comment"}')"
  filter="if (.advisor_episode_seq // 0) != $episode then error(\"new advisor episode while applying maintainer ruling\") else del(.pending_advisor_verdict, .advisor_decision, .web_advisor_provider_job_id, .web_advisor_provider_job_started_at, .web_advisor_provider_job_episode_seq) | . + $patch | .advisor_episode_seq = ((.advisor_episode_seq // 0) + 1) | .maintainer_ruling_applied_episode_seq = .advisor_episode_seq end"
  if ! issue_transition "$n" ready-for-agent founder-ruling-applied "$filter"; then
    echo "advisor_apply_maintainer_ruling: #$n -- state/label transition failed after applying the public ruling" >&2
    return 1
  fi
  issue_label_cache_invalidate

  ADVISOR_MAINTAINER_RULING_APPLIED=1
  echo "advisor_apply_maintainer_ruling: #$n -- applied $count newer maintainer ruling comment(s); advisor dispatch bypassed" >&2
}

# advisor_comment_id_from_url <url-or-text> -- the numeric comment id
# GitHub assigns, parsed off the SAME URL both `gh issue comment` prints on
# stdout on success and `gh issue view --json comments` returns per-comment
# as .url (https://github.com/OWNER/REPO/issues/N#issuecomment-123456). A
# real, GitHub-assigned identifier -- never a hash/digest of content this
# code derives itself (the project hash ban) -- used only to
# recognize "this exact GitHub object", never to fingerprint or
# fuzzy-match text.
advisor_comment_id_from_url() {
  grep -oE 'issuecomment-[0-9]+' <<< "$1" | tail -n1 | sed 's/^issuecomment-//'
}

# advisor_resume_check <n> <issue_json> <prior_state_json> -- prints the
# resumable verdict's raw result (compact JSON, the same shape run-
# advisor.sh's own $RESULT already carries) on stdout iff .pending_
# advisor_verdict (from $prior_state_json) is safe to resume Apply from
# without a fresh model call; prints nothing (and only diagnostics, to
# stderr) otherwise. See this file's header for the two things checked, in
# order: the episode still matches, and the ticket's own {title, body,
# comments} -- minus any comment this exact pending verdict is confirmed to
# have posted itself -- still equal what was stored when the verdict was
# computed. Ties go to re-reasoning: any doubt here (no pending verdict, a
# stale episode, or input that still differs after the subtraction) prints
# nothing, and the caller's own ordinary dispatch path runs unchanged.
advisor_resume_check() {
  local n="$1" issue_json="$2" prior_state_json="$3"
  local pending current_episode pending_episode remaining_comments fresh_input stored_input
  local issue_file pending_file remaining_file

  pending="$(echo "$prior_state_json" | jq -c '.pending_advisor_verdict // empty')"
  [ -z "$pending" ] && return 0

  current_episode="$(echo "$prior_state_json" | jq -r '.advisor_episode_seq // 0')"
  pending_episode="$(echo "$pending" | jq -r '.episode_seq // 0')"
  if [ "$pending_episode" != "$current_episode" ]; then
    echo "run-advisor: #$n -- a pending verdict exists but belongs to a prior advisor episode (its episode_seq=$pending_episode, current=$current_episode) -- discarding it and re-reasoning from scratch, never applying a result left over from an episode that already ended" >&2
    return 0
  fi

  # Subtract only a fresh comment this exact pending verdict's own effect
  # receipts can PROVE it produced -- an exact (confirmed id, confirmed
  # body) match against the receipt, nothing looser. Never "any bot
  # comment" (a different bot, or a human quoting the disclaimer, would
  # wrongly vanish) and never the model-prompt trim view
  # (advisor_prune_own_comments()) -- both were the exact shortcut the
  # design review that found this bug flagged as wrong: it would silently
  # swallow a genuine human edit arriving in the same window as this
  # verdict's own comment.
  #
  # $issue_json/$pending are untrusted-size (a full comment thread, a
  # model's own reasoning_md/decision_md) -- jq_arg_file()/--slurpfile
  # (lib.sh), never --arg/--argjson, same MAX_ARG_STRLEN concern that
  # function's own comment documents.
  issue_file="$(jq_arg_file "$issue_json")"
  pending_file="$(jq_arg_file "$pending")"
  # any(. as $r | ...), not any(... .confirmed_id ...) bare: jq evaluates a
  # function ARGUMENT (endswith's own argument here) against `.` as it
  # stands AT THAT POINT in the pipe -- inside `($c.url // "") | endswith(...)`,
  # that is $c.url itself (a plain string) by the time endswith's argument
  # is evaluated, not the receipt object any(f) iterates over. Binding the
  # current receipt to $r first, then referencing $r.confirmed_id/
  # $r.confirmed_body explicitly, sidesteps that rebinding entirely instead
  # of relying on an ambient `.` that has already changed meaning by the
  # time it's read. Found live writing this file's own regression test
  # ("Cannot index string with string \"confirmed_id\"").
  remaining_comments="$(jq -c -n --slurpfile issue "$issue_file" --slurpfile p "$pending_file" '
    ($issue[0].comments // []) as $fresh
    | ([($p[0].effects // {})[] | select(.confirmed_id != null and .confirmed_id != "")]) as $receipts
    | [ $fresh[] | . as $c
        | select(
            ($receipts | any(. as $r | (($c.url // "") | endswith("issuecomment-" + $r.confirmed_id)) and ($r.confirmed_body == $c.body)))
            | not
          )
      ]
  ')"
  remaining_file="$(jq_arg_file "$remaining_comments")"
  fresh_input="$(jq -c -n --slurpfile issue "$issue_file" --slurpfile comments "$remaining_file" \
    '{title: $issue[0].title, body: $issue[0].body, comments: $comments[0]}')"
  rm -f "$issue_file" "$pending_file" "$remaining_file"
  stored_input="$(echo "$pending" | jq -c '.input')"

  if [ "$fresh_input" = "$stored_input" ]; then
    echo "run-advisor: #$n -- resuming a verdict already computed at $(echo "$pending" | jq -r '.computed_at // "an earlier tick"') (title/body/comments unchanged since, after excluding this verdict's own confirmed side-effects) -- skipping a fresh web-advisor-provider call, retrying whatever GitHub side-effect did not complete last time" >&2
    echo "$pending" | jq -c '.result'
    return 0
  fi
  echo "run-advisor: #$n -- a pending verdict exists but the ticket's own title/body/comments changed since it was computed (beyond this verdict's own confirmed side-effects) -- discarding it and re-reasoning from scratch (never apply a stale verdict to a ticket that moved on)" >&2
  return 0
}

# advisor_persist_pending <n> <reasoning_episode_seq> <result_json>
# <issue_json> <model_used> -- persists $result_json and its actual model
# source to .pending_advisor_verdict, but
# ONLY if advisor_episode_seq in the state file -- read fresh, INSIDE this
# one state_merge call, never from a snapshot the caller took earlier --
# still equals $reasoning_episode_seq (the value that was current when this
# reasoning pass began; see run-advisor.sh's own dispatch call site for
# where that gets recorded). The check and the write are one jq program
# inside one state_merge call, so there is no separate "check state, then
# merge" window for a fresh episode to land in between -- the same
# atomicity idiom route_to_advisor()/route_to_recut()/give_up_on_issue()
# (lib.sh) already use for "a failed state_merge must not move the label",
# applied here to a data field instead. Returns non-zero (nothing written)
# on either a stale episode or an ordinary state_merge failure; the caller
# must abort before any GitHub side-effect either way, same as before this
# function existed.
advisor_persist_pending() {
  local n="$1" expected_seq="$2" result_json="$3" issue_json="$4" model_used="${5:-unknown}"
  local result_file input_snapshot input_file patch filter

  result_file="$(jq_arg_file "$result_json")"
  input_snapshot="$(echo "$issue_json" | jq -c '{title, body, comments}')"
  input_file="$(jq_arg_file "$input_snapshot")"
  patch="$(jq -n --slurpfile result "$result_file" --slurpfile input "$input_file" --argjson seq "$expected_seq" --arg model "$model_used" \
    '{result: $result[0], input: $input[0], computed_at: (now | todate), episode_seq: $seq, model_used: $model, effects: {}}')"
  rm -f "$result_file" "$input_file"

  filter="if (.advisor_episode_seq // 0) != $expected_seq then error(\"run-advisor: #$n -- advisor_episode_seq is now \" + ((.advisor_episode_seq // 0)|tostring) + \", not the $expected_seq this reasoning pass began with -- a new episode started while it was in flight, refusing to persist a stale verdict\") else . + {pending_advisor_verdict: $patch} end"
  state_merge "$n" "$filter"
}

# advisor_apply_comment_with_receipt <n> <effect_name> <body> <issue_json>
# -- posts a `gh issue comment` for the CURRENT pending verdict's Apply
# step as a tracked, reconciled side-effect instead of a bare apply_gh_
# write call, so a later tick that resumes this exact pending verdict can
# tell "I already posted this" from "I have not posted this yet" -- see
# this file's own header for the incident this closes.
#
# Reads/writes .pending_advisor_verdict.effects.<effect_name> in this
# ticket's own state. Skips the network call (returns 0 immediately) when
# EITHER:
#   - a receipt already carries a confirmed_id for this exact $body (this
#     run, or an earlier tick resuming the same pending verdict, already
#     posted it), or
#   - a comment whose body exactly matches $body is already visibly on the
#     issue in $issue_json (the write landed on a prior tick, but that
#     tick's OWN confirmation step never got to run -- an ambiguous
#     outcome, not a failure, so this reconciles against the real GitHub
#     state before ever considering a repost -- the same best-effort
#     posture apply_gh_write()'s own TLS-handshake-timeout handling
#     already takes for a transient gh failure elsewhere in this file:
#     not a full exactly-once guarantee, but reconcile-before-retry,
#     matching this codebase's existing standard for gh-write retries).
# A genuine post records the plan (best-effort -- its own failure does not
# block the actual gh call, since the write itself is what matters) BEFORE
# calling gh, and the CONFIRMED id/body after gh actually succeeds -- $out
# is `gh issue comment`'s own stdout contract, the created comment's URL,
# which apply_gh_write() already threads through unchanged on success.
advisor_apply_comment_with_receipt() {
  local n="$1" effect_name="$2" body="$3" issue_json="$4"
  local pending confirmed_id planned_body existing_url existing_id out
  local body_file body_json filter comment_id

  pending="$(state_read "$n" | jq -c '.pending_advisor_verdict // {}')"
  confirmed_id="$(echo "$pending" | jq -r --arg e "$effect_name" '.effects[$e].confirmed_id // empty')"
  planned_body="$(echo "$pending" | jq -r --arg e "$effect_name" '.effects[$e].planned_body // empty')"
  if [ -n "$confirmed_id" ] && [ "$planned_body" = "$body" ]; then
    echo "run-advisor: #$n -- $effect_name already confirmed posted (comment id $confirmed_id) for this exact pending verdict -- not reposting" >&2
    return 0
  fi

  # $body is untrusted-size (a model's own reasoning_md/decision_md) --
  # jq_arg_file()/--rawfile (lib.sh), never --arg, same MAX_ARG_STRLEN
  # concern that function's own comment documents. Written once, reused for
  # both the reconcile check below and the planned-effect patch further
  # down, instead of paying for the temp file twice.
  body_file="$(jq_arg_file "$body")"
  existing_url="$(echo "$issue_json" | jq -r --rawfile b "$body_file" '[.comments[]? | select(.body == $b)] | last | .url // empty')"
  if [ -n "$existing_url" ]; then
    existing_id="$(advisor_comment_id_from_url "$existing_url")"
    echo "run-advisor: #$n -- $effect_name's planned comment is already on the issue (matched by exact body, id $existing_id) -- not reposting; reconciling the receipt instead" >&2
    rm -f "$body_file"
    advisor_confirm_comment_effect "$n" "$effect_name" "$existing_id" "$body"
    return 0
  fi

  body_json="$(jq -n --rawfile b "$body_file" '$b')"
  rm -f "$body_file"
  filter=".pending_advisor_verdict.effects.$effect_name = {decision_id: (.pending_advisor_verdict.computed_at // \"\"), effect_name: \"$effect_name\", planned_body: $body_json, confirmed_id: null, confirmed_body: null}"
  state_merge "$n" "$filter" || echo "run-advisor: #$n -- could not persist the planned-effect receipt for $effect_name before posting (continuing anyway -- the gh write itself is what matters; the reconcile-by-body-match above still protects a future tick against a double-post even without this bookkeeping)" >&2

  # Bare statement, NOT `out="$(apply_gh_write ...)"` -- see apply_gh_write's
  # own comment for why: this call's transient/hard-failure handling
  # (record_env_fault + exit 0, or exit 1) only works when `exit` can reach
  # this script's own top level, which a command-substitution subshell
  # would block. The batch caller opts into a non-zero soft failure instead
  # of that exit; propagate it before reading the success-only side channel.
  local apply_status=0
  apply_gh_write gh issue comment "$n" --repo "$REPO" --body "$body" || apply_status=$?
  [ "$apply_status" -eq 0 ] || return "$apply_status"
  out="$APPLY_GH_WRITE_OUTPUT"
  comment_id="$(advisor_comment_id_from_url "$out")"
  if [ -z "$comment_id" ]; then
    echo "run-advisor: #$n -- $effect_name posted but no comment id could be parsed from gh's own output -- receipt stays unconfirmed; a later tick's reconcile-by-body-match still prevents a double-post" >&2
    return 0
  fi
  advisor_confirm_comment_effect "$n" "$effect_name" "$comment_id" "$body"
}

# advisor_confirm_comment_effect <n> <effect_name> <comment_id> <body> --
# records the REAL, GitHub-assigned id (and the body it actually carries)
# for a comment this exact pending verdict is now known to have produced,
# either by posting it itself or by finding it already there on reconcile.
# Best-effort: its own failure is logged, not fatal -- the comment IS
# already on GitHub either way, and the body-match reconcile in
# advisor_apply_comment_with_receipt() above still prevents a double-post
# on a future tick even without this receipt.
advisor_confirm_comment_effect() {
  local n="$1" effect_name="$2" comment_id="$3" body="$4"
  local body_file body_json filter
  body_file="$(jq_arg_file "$body")"
  body_json="$(jq -n --rawfile b "$body_file" '$b')"
  rm -f "$body_file"
  filter=".pending_advisor_verdict.effects.$effect_name.confirmed_id = \"$comment_id\" | .pending_advisor_verdict.effects.$effect_name.confirmed_body = $body_json"
  state_merge "$n" "$filter" || echo "run-advisor: #$n -- could not persist the confirmed receipt for $effect_name (comment id $comment_id) -- the comment IS posted on GitHub; a later tick's body-match reconcile still prevents a double-post even without this receipt" >&2
}
