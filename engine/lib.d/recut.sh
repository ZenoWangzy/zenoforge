
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
