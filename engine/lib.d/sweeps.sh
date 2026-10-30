
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

maintainer_test_issue_candidate() {
  local issue_json="$1" roster="${ZF_AGENT_RECIPIENTS_FILE:-$AGENT_HOME/recipients.json}" founder_login
  [ -f "$roster" ] || return 1
  founder_login="$(jq -r '.founder_login // empty' "$roster" 2>/dev/null)" || return 1
  [ -n "$founder_login" ] || return 1
  jq -e --arg maintainer "$founder_login" --arg bot_marker "$BOT_COMMENT_MARKER" \
    --arg recut_marker "$RECUT_CHILD_MARKER" "$MAINTAINER_TEST_CANDIDATE_FILTER" \
    <<< "$issue_json" >/dev/null 2>&1
}


issue_has_maintainer_test_label() {
  jq -e 'any(.labels[]?; .name == "founder-test")' <<< "$1" >/dev/null 2>&1
}


issue_is_maintainer_test() {
  issue_has_maintainer_test_label "$1" || maintainer_test_issue_candidate "$1"
}

ensure_maintainer_test_label() {
  local existing
  [ "$MAINTAINER_TEST_LABEL_READY" = 1 ] && return 0
  existing="$(gh label list --repo "$REPO" --limit 200 --json name -q '.[].name' 2>/dev/null)" || return 1
  if ! grep -qx -- founder-test <<< "$existing"; then
    if ! guarded_write gh label create founder-test --repo "$REPO" --color 5319E7 \
        --description "Maintainer-filed test and demo issue" >/dev/null; then
      existing="$(gh label list --repo "$REPO" --limit 200 --json name -q '.[].name' 2>/dev/null)" || return 1
      grep -qx -- founder-test <<< "$existing" || return 1
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
  guarded_write gh issue edit "$n" --repo "$REPO" --add-label founder-test >/dev/null
}


label_maintainer_test_candidates() {
  local issues="$1" live_issue_json n candidates founder_login
  local roster="${ZF_AGENT_RECIPIENTS_FILE:-$AGENT_HOME/recipients.json}"
  jq -e 'type == "array" and all(.[]; type == "object" and (.labels | type == "array"))' \
    <<< "$issues" >/dev/null || return 1
  [ -f "$roster" ] || { printf '%s\n' "$issues"; return 0; }
  founder_login="$(jq -r '.founder_login // empty' "$roster" 2>/dev/null)" || return 1
  # Same predicate as point classification; batch the unchanged local gates.
  candidates="$(jq -c --arg maintainer "$founder_login" --arg bot_marker "$BOT_COMMENT_MARKER" \
    --arg recut_marker "$RECUT_CHILD_MARKER" \
    "[.[] | select(any(.labels[]?; .name == \"founder-test\") | not) | select($MAINTAINER_TEST_CANDIDATE_FILTER)]" \
    <<< "$issues" | python3 -c '
import json, pathlib, sys
states = pathlib.Path(sys.argv[1])
for issue in json.load(sys.stdin):
    try:
        checked = json.loads((states / (str(issue["number"]) + ".json")).read_text()).get("founder_test_checked") is True
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
      echo "issue-pipeline: cannot re-read #$n to classify founder-test origin; skipping it this tick" >&2
      continue
    fi
    [ "$(jq -r '.state // empty' <<< "$live_issue_json")" = OPEN ] || continue
    if ! maintainer_test_issue_candidate "$live_issue_json"; then
      state_merge "$n" '.founder_test_checked = true' >/dev/null 2>&1 || true
      continue
    fi
    if ! label_maintainer_test_issue "$live_issue_json"; then
      echo "issue-pipeline: failed to apply founder-test label to #$n" >&2
      return 1
    fi
    issues="$(jq -c --argjson n "$n" 'map(if .number == $n then .labels += [{name:"founder-test"}] else . end)' <<< "$issues")" || return 1
  done <<< "$candidates"
  printf '%s\n' "$issues"
}

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
# issues-json 是 open issue 数组（含 body/labels）；父票 = 正文含 vecta-batch-state
# 标记的票。STATE 里 critical_path 列表和 delay_cost=critical 都进关键路径；
# 解析失败的父票跳过（stderr 一行），不让一张坏父票停掉整个 sweep。
batch_state_band_map() {
  jq -r '
    def state_blocks($body):
      [$body | scan("<!-- vecta-batch-state\\s*(\\{.*?\\})\\s*-->") | .[0]] ;
    # gh api --paginate --slurp 交付的是页数组；直接喂平铺数组也要能解析。
    [ .[] | if type == "array" then .[] else . end
      | select(type == "object" and has("number") and (has("pull_request") | not)) ] as $issues
    | ([$issues[] | select((.body // "") | contains("vecta-batch-state"))
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
  local candidates issue_pages n issue_json issue_after_write issue_state recut_status state_labels_json lane_match_status maintainer_test founder_login roster intake_since candidate_branch source_issue
  local rescued=0 scan_complete=1 mutation_failed=0 state_label marker="$AGENT_HOME/unlabeled-issue-sweep-alerted"
  local inbox="$AGENT_HOME/supervisor-inbox"
  local -a edit_args=()

  state_labels_json="$(printf '%s\n' "${ALL_STATE_LABELS[@]}" | jq -R . | jq -cs .)" || return 1
  roster="${ZF_AGENT_RECIPIENTS_FILE:-$AGENT_HOME/recipients.json}"
  founder_login="$(jq -r '.founder_login // empty' "$roster" 2>/dev/null || true)"
  if ! issue_pages="$(gh api --paginate --slurp "repos/$REPO/issues?state=open&per_page=100")"; then
    echo "sweep_unlabeled_issues: could not list open issues; leaving alert state unchanged" >&2
    return 1
  fi
  # The pipeline files issues under the maintainer account too, so "authored by
  # the maintainer" matched 203 of 210 open issues and every tick re-read each one
  # with comments (17+ min, 2026-09-27). A maintainer test issue is recognised when
  # it is new: only issues created inside the intake window qualify, and one
  # already judged (founder_test_checked in local state) is not re-read.
  intake_since="$(date -u -d "-${ZF_MAINTAINER_TEST_INTAKE_HOURS:-48} hours" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  if ! candidates="$(jq -r --argjson states "$state_labels_json" --arg maintainer "$founder_login" --arg since "$intake_since" '
    if type != "array" or any(.[]; type != "array") then error("invalid paginated issue response")
    else
      (add // [])[]
      | select(type == "object" and (has("pull_request") | not) and .state == "open")
      | [.labels[]?.name] as $names
      | if all($states[]; . as $state | ($names | index($state)) == null) then "\(.number)\tunlabeled"
        elif ($maintainer != "") and ((.user.login // "") | ascii_downcase) == ($maintainer | ascii_downcase)
          and (($names | index("founder-test")) == null) and ((.created_at // "") >= $since) then "\(.number)\tmaintainer"
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
      && state_read "$n" 2>/dev/null | jq -e '.founder_test_checked == true' >/dev/null 2>&1; then
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
        echo "sweep_unlabeled_issues: cannot ensure founder-test label for #$n; skipping" >&2
        scan_complete=0
        continue
      fi
      maintainer_test=1
    fi
    if jq -e --argjson states "$state_labels_json" \
      '[.labels[]?.name] as $names | any($states[]; . as $state | ($names | index($state)) != null)' \
      <<< "$issue_json" >/dev/null; then
      if [ "$maintainer_test" = 1 ] && ! label_maintainer_test_issue "$issue_json"; then
        echo "sweep_unlabeled_issues: failed to label founder-test issue #$n; skipping" >&2
        scan_complete=0
      elif [ "$candidate_branch" = maintainer ]; then
        state_merge "$n" '.founder_test_checked = true' >/dev/null 2>&1 || true
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
      echo "sweep_unlabeled_issues: failed to label founder-test issue #$n; skipping" >&2
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
  marker="<!-- vecta-conclusion-requeue issue=$n episode=$episode -->"
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
