# hold_rule and its supervisor ruling kinds. Split out of holds.sh to stay under that file's size baseline.

# hold_rule N|issue-N|pr-N requeue|approve|arbiter|recut|ready COMMENT: a supervisor ruling. Records supervisor-<action> in the
# unit history (refills the stop-loss/arbitration budgets; a parked unit is moved by scheduler.sh --rule) and releases a
# scheduler-stop-loss hold, or a supervisor/head hold on the allowlist below, if the issue has one. COMMENT must be an owner comment on the issue (or the PR for pr-N).
# A fifth argument (hold.sh --requeue --size-waiver N, or hold.sh --waiver --size-waiver N for an implement or *-pending unit) sets the unit's .size_waiver with the comment author and first line as the reason; the waiver alone keeps the stage and the hold.
# 2026-11-17 (issue-4354): close sets the unit closed with a supervisor-close event and leaves the GitHub issue, its labels and its open PR alone; rule_entry refuses an open PR.
hold_rule_usage() {
  printf '%s\n' 'hold.sh --rule: invalid arguments; usage: --rule <issue|issue-N|pr-N> --requeue|--reroute|--approve|--arbiter|--recut|--reblock|--supersede-handoff|--ready|--close --comment <id> [--blocked-on <N>]|--waiver --comment <id> --size-waiver <max_lines>; decide only with --check [--author <login>] and no --comment; --size-waiver is allowed only with --requeue or alone as --waiver; --reroute keeps an existing waiver; --ready requires an open tracker, needs-advisor or needs-triage issue; report only on an unchanged PR head must say "report only" or "report-only".' >&2
  return 64
}

hold_rule_scheduler_path() {
  local engine="${_AGENT_LIB_DIR:-${ZF_ENGINE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}}"
  printf '%s/mac-autopilot/scheduler.sh\n' "$engine"
}


hold_rule_decide() {
  local target="${1:-}" action="${2:-}" comment_id="${3:-}" blocker="${4:-}" waiver="${5:-}" check_only="${6:-false}" author="${7:-}" unit n comment owner current_author sched issue_state state_name rc scheduler_output
  HOLD_RULE_REFUSAL_TEXT=""
  [[ "$target" =~ ^[1-9][0-9]*$ ]] && target="issue-$target"
  [[ "$target" =~ ^(issue|pr)-([1-9][0-9]*)$ && "$action" =~ ^(requeue|reroute|approve|arbiter|recut|reblock|supersede-handoff|ready|close|waiver)$ ]] || { echo "hold_rule: invalid target or action" >&2; return 64; }
  if [[ "$check_only" == true ]]; then
    [[ -z "$comment_id" && ( -z "$author" || "$author" =~ ^[A-Za-z0-9-]+$ ) ]] || { echo "hold_rule: --comment is not accepted with --check; --author must be a login" >&2; return 64; }
  else
    [[ "$comment_id" =~ ^[1-9][0-9]*$ ]] || { echo "hold_rule: invalid comment id" >&2; return 64; }
  fi
  unit="$target"; n="${unit#*-}"
  [[ "$action" != waiver || -n "$waiver" ]] || { echo "hold_rule: waiver needs --size-waiver N" >&2; return 64; }
  [[ -z "$waiver" || ( ( "$action" == requeue || "$action" == waiver ) && "$waiver" =~ ^[1-9][0-9]*$ ) ]] || { echo "hold_rule: --size-waiver is allowed only with --requeue or alone as --waiver; --reroute keeps an existing waiver" >&2; return 64; }
  [[ "$action" != ready || "$unit" == issue-* ]] || { echo "hold_rule: --ready takes an issue, not a PR" >&2; return 64; }
  if gh_rate_limit_active graphql >/dev/null 2>&1; then
    HOLD_RULE_REFUSAL_TEXT="hold_rule: GitHub GraphQL backoff is active"
    return 75
  fi
  if [[ "$unit" == issue-* && "$action" != waiver ]]; then
    HOLD_RULE_STATE="$(state_read "$n")" || { HOLD_RULE_REFUSAL_TEXT="hold_rule: initial state read failed for #$n"; return 75; }
    jq -e 'type == "object"' <<< "$HOLD_RULE_STATE" >/dev/null 2>&1 || { HOLD_RULE_REFUSAL_TEXT="hold_rule: initial state is unreadable for #$n"; return 75; }
    if ! jq -e '.state != "on-hold" or .hold.holder == "scheduler-stop-loss"' <<< "$HOLD_RULE_STATE" >/dev/null; then
      if ! jq -e '.hold | (.holder == "supervisor" and (.kind | IN("production-access", "guarded-recut-repeat", "manual", "recut-loop"))) or (.holder == "head" and .kind == "manual")' <<< "$HOLD_RULE_STATE" >/dev/null; then
        HOLD_RULE_REFUSAL_TEXT="hold_rule: #$n is held by someone other than scheduler-stop-loss"
        return 1
      fi
      HOLD_RULE_ALLOW_RELEASE=1
    else
      HOLD_RULE_ALLOW_RELEASE=0
    fi
  else
    HOLD_RULE_STATE=""
    HOLD_RULE_ALLOW_RELEASE=0
  fi
  if [[ "$check_only" == true ]]; then
    current_author="$(gh api user --jq .login 2>/dev/null)" || { HOLD_RULE_REFUSAL_TEXT="hold_rule: authenticated author could not be read"; return 75; }
    [[ -n "$current_author" ]] || { HOLD_RULE_REFUSAL_TEXT="hold_rule: authenticated author could not be read"; return 75; }
    [[ -z "$author" || "$author" == "$current_author" ]] || { HOLD_RULE_REFUSAL_TEXT="hold_rule: --author does not match the authenticated GitHub author"; return 1; }
    owner="$(gh api "repos/$REPO" --jq .owner.login 2>/dev/null)" || { HOLD_RULE_REFUSAL_TEXT="hold_rule: repository owner could not be read"; return 75; }
    [[ -n "$owner" ]] || { HOLD_RULE_REFUSAL_TEXT="hold_rule: repository owner could not be read"; return 75; }
    [[ -n "$current_author" && "$current_author" == "$owner" ]] || { HOLD_RULE_REFUSAL_TEXT="hold_rule: ruling author is not the repository owner"; return 1; }
    HOLD_RULE_AUTHOR="$current_author"
    HOLD_RULE_HTML_URL="https://github.com/$REPO/issues/$n#issuecomment-1"
    HOLD_RULE_BODY=""
    HOLD_RULE_COMMENT_ID=""
  else
    comment="$(gh api "repos/$REPO/issues/comments/$comment_id")" || { HOLD_RULE_REFUSAL_TEXT="hold_rule: GitHub comment lookup failed for comment $comment_id"; return 75; }
    jq -e 'type == "object" and (.issue_url | type == "string") and (.author_association | type == "string")' <<< "$comment" >/dev/null 2>&1 || { HOLD_RULE_REFUSAL_TEXT="hold_rule: GitHub comment response was unreadable"; return 75; }
    if ! jq -e --arg u "https://api.github.com/repos/$REPO/issues/$n" '.issue_url == $u' <<< "$comment" >/dev/null; then
      HOLD_RULE_REFUSAL_TEXT="hold_rule: ruling comment is not on #$n"
      return 1
    fi
    if ! jq -e '.author_association == "OWNER"' <<< "$comment" >/dev/null; then
      HOLD_RULE_REFUSAL_TEXT="hold_rule: ruling author is not the repository owner"
      return 1
    fi
    HOLD_RULE_AUTHOR="$(jq -r '.user.login // empty' <<< "$comment")"
    HOLD_RULE_HTML_URL="$(jq -r .html_url <<< "$comment")"
    HOLD_RULE_BODY="$(jq -r '.body[0:4000]' <<< "$comment")"
    HOLD_RULE_COMMENT_ID="$comment_id"
  fi
  if [[ "$action" == ready ]]; then
    state_name="$(jq -r '.state // "untracked"' <<< "$HOLD_RULE_STATE")"
    case "$state_name" in
      tracker|needs-advisor|needs-triage) ;;
      *) HOLD_RULE_REFUSAL_TEXT="hold_rule: #$n is $state_name; --ready needs tracker, needs-advisor or needs-triage"; return 1 ;;
    esac
    issue_state="$(issue_rest_state "$n" "$REPO")" || { HOLD_RULE_REFUSAL_TEXT="hold_rule: #$n state is unreadable; --ready refused"; return 75; }
    [[ "$issue_state" == OPEN ]] || { HOLD_RULE_REFUSAL_TEXT="hold_rule: #$n is closed; --ready needs an open issue"; return 1; }
  fi
  sched="$(hold_rule_scheduler_path)"
  scheduler_output="$(bash "$sched" --rule-check "$unit" "$action" "$HOLD_RULE_HTML_URL" "$HOLD_RULE_BODY" "$blocker" "$waiver" "$HOLD_RULE_AUTHOR" 2>&1)" || {
    rc=$?
    HOLD_RULE_REFUSAL_TEXT="${scheduler_output#would refuse: }"
    [[ "$rc" == 75 ]] && return 75
    return "$rc"
  }
  return 0
}

hold_rule_apply() {
  local target="$1" action="$2" blocker="${3:-}" waiver="${4:-}" unit n state="$HOLD_RULE_STATE" current_state sched allow_release="$HOLD_RULE_ALLOW_RELEASE" comment_id="$HOLD_RULE_COMMENT_ID" release_patch=. rc
  unit="$target"; [[ "$unit" =~ ^[1-9][0-9]*$ ]] && unit="issue-$unit"; n="${unit#*-}"
  sched="$(hold_rule_scheduler_path)"
  # recut needs the issue out of on-hold first, or route_to_recut leaves it on-hold
  # An allowlisted hold is released on any action, and the old holder, kind, reason and comment id are kept in the issue state.
  if [[ "$allow_release" == 1 ]]; then
    release_patch=".hold_release_rulings = ((.hold_release_rulings // []) + [$(jq -c --argjson c "$comment_id" '{holder:.hold.holder,kind:.hold.kind,reason:.hold.release_condition,comment_id:$c,released_at:(now|todate)}' <<< "$state")])" || { echo "hold_rule: could not prepare the hold-release record for #$n" >&2; return 1; }
  fi
  if [[ ( "$action" == recut || "$allow_release" == 1 ) && -n "$state" ]] && jq -e '.state == "on-hold"' <<< "$state" >/dev/null; then
    state_requeue "$n" release-hold hold-requeue "$release_patch" "$(jq -c .hold <<< "$state")" || { echo "hold_rule: pre-ruling hold release failed for #$n; --$action was not run" >&2; return 1; }
    state=""
  fi
  bash "$sched" --rule "$unit" "$action" "$HOLD_RULE_HTML_URL" "$HOLD_RULE_BODY" "$blocker" "$waiver" "$HOLD_RULE_AUTHOR" || { echo "hold_rule: scheduler --rule refused #$n --$action; see the scheduler refusal above" >&2; return 1; }
  # ready writes the state the intake ruling episode reads (state_changed_from/state_changed_at); a label-only edit does not.
  if [[ "$action" == ready ]]; then issue_transition "$n" ready-for-agent "ruling-ready:$comment_id" || { echo "hold_rule: ready-state transition failed for #$n after the ruling was recorded" >&2; return 1; }; fi
  if [[ "$action" != waiver && -n "$state" ]] && jq -e '.state == "on-hold"' <<< "$state" >/dev/null; then
    current_state="$(state_read "$n")" || { echo "hold_rule: post-ruling state read failed for #$n after --$action was recorded" >&2; return 1; }
    if ! jq -e '.state != "on-hold" and .hold == null' <<< "$current_state" >/dev/null; then
      state_requeue "$n" release-hold hold-requeue . "$(jq -c .hold <<< "$state")" || { rc=$?; echo "hold_rule: final hold release failed for #$n after --$action was recorded" >&2; return "$rc"; }
    fi
  fi
}

hold_rule() {
  local target="${1:-}" action="${2:-}" comment_id="${3:-}" blocker="${4:-}" waiver="${5:-}" check_only="${6:-false}" author="${7:-}" rc
  rc=0; hold_rule_decide "$target" "$action" "$comment_id" "$blocker" "$waiver" "$check_only" "$author" || rc=$?
  if (( rc != 0 )); then
    if [[ "$check_only" == true && "$rc" == 1 ]]; then printf 'would refuse: %s\n' "$HOLD_RULE_REFUSAL_TEXT"; return 1; fi
    if [[ -n "$HOLD_RULE_REFUSAL_TEXT" ]]; then echo "$HOLD_RULE_REFUSAL_TEXT" >&2; fi
    return "$rc"
  fi
  if [[ "$check_only" == true ]]; then printf 'would-apply hold.sh --rule %s --%s\n' "$target" "$action"; return 0; fi
  hold_rule_apply "$target" "$action" "$blocker" "$waiver"
}

hold_rule_cli() {
  local target="${1:-}" action="" comment_id="" blocker="" waiver="" check_only=false author="" seen_comment=false seen_blocker=false seen_waiver=false seen_author=false
  (($# >= 2)) && [[ "$2" =~ ^--(requeue|reroute|approve|arbiter|recut|reblock|supersede-handoff|ready|close|waiver)$ ]] || { hold_rule_usage; return 64; }
  action="${2#--}"
  shift 2
  while (($#)); do
    case "$1" in
      --check) [[ "$check_only" == false ]] || { hold_rule_usage; return 64; }; check_only=true; shift ;;
      --comment) [[ "$seen_comment" == false && $# -ge 2 ]] || { hold_rule_usage; return 64; }; seen_comment=true; comment_id="$2"; shift 2 ;;
      --author) [[ "$seen_author" == false && $# -ge 2 ]] || { hold_rule_usage; return 64; }; seen_author=true; author="$2"; shift 2 ;;
      --blocked-on) [[ "$seen_blocker" == false && $# -ge 2 ]] || { hold_rule_usage; return 64; }; seen_blocker=true; blocker="$2"; shift 2 ;;
      --size-waiver) [[ "$seen_waiver" == false && $# -ge 2 ]] || { hold_rule_usage; return 64; }; seen_waiver=true; waiver="$2"; shift 2 ;;
      *) hold_rule_usage; return 64 ;;
    esac
  done
  [[ "$check_only" != true || "$seen_comment" == false ]] || { hold_rule_usage; return 64; }
  [[ "$check_only" == true || ( "$seen_comment" == true && "$seen_author" == false ) ]] || { hold_rule_usage; return 64; }
  [[ "$action" != waiver || "$seen_waiver" == true ]] || { hold_rule_usage; return 64; }
  [[ "$seen_waiver" == false || ( "$action" == requeue || "$action" == waiver ) ]] || { hold_rule_usage; return 64; }
  hold_rule "$target" "$action" "$comment_id" "$blocker" "$waiver" "$check_only" "$author"
}
