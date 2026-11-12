# hold_rule and its supervisor ruling kinds. Split out of holds.sh to stay under that file's size baseline.

# hold_rule N|issue-N|pr-N requeue|approve|arbiter|recut|ready COMMENT: a supervisor ruling. Records supervisor-<action> in the
# unit history (refills the stop-loss/arbitration budgets; a parked unit is moved by scheduler.sh --rule) and releases a
# scheduler-stop-loss hold, or a supervisor/head hold on the allowlist below, if the issue has one. COMMENT must be an owner comment on the issue (or the PR for pr-N).
hold_rule() {
  local target="${1:-}" action="${2:-}" comment_id="${3:-}" blocker="${4:-}" unit n state="" current_state comment sched issue_state allow_release=0 release_patch=.
  [[ "$target" =~ ^[1-9][0-9]*$ ]] && target="issue-$target"
  [[ "$target" =~ ^(issue|pr)-([1-9][0-9]*)$ && "$action" =~ ^(requeue|reroute|approve|arbiter|recut|reblock|supersede-handoff|ready)$ && "$comment_id" =~ ^[1-9][0-9]*$ ]] || return 64
  unit="$target"; n="${unit#*-}"
  [[ "$action" != ready || "$unit" == issue-* ]] || { echo "hold_rule: --ready takes an issue, not a PR" >&2; return 64; }
  if [[ "$unit" == issue-* ]]; then
    state="$(state_read "$n")" || return 1
    jq -e '.state != "on-hold" or .hold.holder == "scheduler-stop-loss"' <<< "$state" >/dev/null || {
      # Allowlist of (holder, kind) pairs a ruling may release, from real hold records: supervisor holds written by run-recut.sh
      # and head/supervisor manual holds. Founder, other humans and unknown holders are never here. The owner-comment check below still runs first.
      jq -e '.hold | (.holder == "supervisor" and (.kind | IN("production-access", "guarded-recut-repeat", "manual"))) or (.holder == "head" and .kind == "manual")' <<< "$state" >/dev/null || {
        echo "hold_rule: #$n is held by someone other than scheduler-stop-loss" >&2
        return 1
      }
      allow_release=1
    }
  fi
  comment="$(gh api "repos/$REPO/issues/comments/$comment_id")" || return 1
  jq -e --arg u "https://api.github.com/repos/$REPO/issues/$n" '.issue_url == $u and .author_association == "OWNER"' <<< "$comment" >/dev/null || {
    echo "hold_rule: comment $comment_id is not an owner comment on #$n" >&2
    return 1
  }
  if [[ "$action" == ready ]]; then # the state gate is the only refusal for a hold: on-hold is not one of these states
    case "$(jq -r '.state // "untracked"' <<< "$state")" in
      tracker|needs-advisor|needs-triage) ;;
      *) echo "hold_rule: #$n is $(jq -r '.state // "untracked"' <<< "$state"); --ready needs tracker, needs-advisor or needs-triage" >&2; return 1 ;;
    esac
    issue_state="$(gh issue view "$n" --repo "$REPO" --json state -q .state)" || return 1
    [[ "$issue_state" == OPEN ]] || { echo "hold_rule: #$n is closed; --ready needs an open issue" >&2; return 1; }
  fi
  sched="$(dirname -- "$_AGENT_LIB_DIR/lib.sh")/mac-autopilot/scheduler.sh"
  # recut needs the issue out of on-hold first, or route_to_recut leaves it on-hold
  # An allowlisted hold is released on any action, and the old holder, kind, reason and comment id are kept in the issue state.
  if [[ "$allow_release" == 1 ]]; then
    release_patch=".hold_release_rulings = ((.hold_release_rulings // []) + [$(jq -c --argjson c "$comment_id" '{holder:.hold.holder,kind:.hold.kind,reason:.hold.release_condition,comment_id:$c,released_at:(now|todate)}' <<< "$state")])" || return 1
  fi
  if [[ ( "$action" == recut || "$allow_release" == 1 ) && -n "$state" ]] && jq -e '.state == "on-hold"' <<< "$state" >/dev/null; then
    state_requeue "$n" release-hold hold-requeue "$release_patch" "$(jq -c .hold <<< "$state")" || return 1
    state=""
  fi
  bash "$sched" --rule "$unit" "$action" "$(jq -r .html_url <<< "$comment")" "$(jq -r '.body[0:4000]' <<< "$comment")" "$blocker" || return 1
  # ready writes the state the intake ruling episode reads (state_changed_from/state_changed_at); a label-only edit does not.
  if [[ "$action" == ready ]]; then issue_transition "$n" ready-for-agent "ruling-ready:$comment_id" || return 1; fi
  if [[ -n "$state" ]] && jq -e '.state == "on-hold"' <<< "$state" >/dev/null; then current_state="$(state_read "$n")" || return 1
    jq -e '.state != "on-hold" and .hold == null' <<< "$current_state" >/dev/null || state_requeue "$n" release-hold hold-requeue . "$(jq -c .hold <<< "$state")"
  fi
}
