_AGENT_LIB_DIR="${_AGENT_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}" # a module sourced without lib.sh (land snapshot) still finds the lib dir

pipeline_system_issue_labels_json() {
  local rulings_file
  rulings_file="$(cd -- "$(dirname -- "$_AGENT_LIB_DIR/lib.sh")" && pwd -P)/state/rulings.json"
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


pipeline_system_external_close_comment_valid() {
  local issue="$1" body="$2" repo="$ZF_INFRA_REPO" default_branch pr_json pr_ref sha_ref pr_number sha
  local -a prs=() sha_refs=()
  grep -Eiq "$repo" <<< "$body" || return 1
  mapfile -t prs < <(grep -Eio 'pull request[[:space:]]*#?[[:space:]]*[0-9]+|pr[[:space:]]*#?[[:space:]]*[0-9]+' <<< "$body" | grep -Eo '[0-9]+' | sort -u || true)
  mapfile -t sha_refs < <(grep -Eio "$repo@[[:xdigit:]]{40,64}|merge[[:space:]]+sha[[:space:]:=]+[[:xdigit:]]{40,64}" <<< "$body" || true)
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
  comment="结案：delivered in $ZF_INFRA_REPO PR $pr_number, merged as $ZF_INFRA_REPO@$merge_sha."
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
