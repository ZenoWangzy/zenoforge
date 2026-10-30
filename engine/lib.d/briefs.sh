
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
