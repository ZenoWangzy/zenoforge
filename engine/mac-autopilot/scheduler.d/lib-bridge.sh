scheduler_jq_arg_file() (
  REPO_DIR="$ROOT"
  source "$SCHEDULER_AGENT_LIB" || return 1
  jq_arg_file "$1"
)
scheduler_issue_intake_parent_reason() (
  local preserved_gh=""
  declare -F gh >/dev/null 2>&1 && preserved_gh="$(declare -f gh)"
  REPO_DIR="$ROOT" MODEL_POLICY_SOURCE_CHECK_ONLY=1
  source "$SCHEDULER_AGENT_LIB" || return 2
  [[ -z "$preserved_gh" ]] || eval "$preserved_gh"
  issue_intake_parent_reason "$@"
)
scheduler_jq_arg_file() (
  REPO_DIR="$ROOT" MODEL_POLICY_SOURCE_CHECK_ONLY=1
  source "$SCHEDULER_AGENT_LIB" || return 1
  jq_arg_file "$1"
)
scheduler_issue_transition() ( # issue stage reason：通过 lib.sh 的唯一 stage-label writer
  local preserved_gh=""
  declare -F gh >/dev/null 2>&1 && preserved_gh="$(declare -f gh)"
  REPO_DIR="$ROOT"
  source "$SCHEDULER_AGENT_LIB" || return 1
  [[ -z "$preserved_gh" ]] || eval "$preserved_gh"
  issue_transition "$@"
)
scheduler_route_to_recut() ( # issue：lib.sh 的唯一 needs-recut 入口
  local preserved_gh=""
  declare -F gh >/dev/null 2>&1 && preserved_gh="$(declare -f gh)"
  REPO_DIR="$ROOT"
  source "$SCHEDULER_AGENT_LIB" || return 1
  [[ -z "$preserved_gh" ]] || eval "$preserved_gh"
  # on-hold 或 pipeline-system 的 issue 不会落到 needs-recut：只有真进了 recut 队列才算成功。
  route_to_recut "$1" || return 1
  [[ "$(state_read "$1" | jq -r '.state // empty')" == needs-recut ]] || { echo "issue #$1 routed to $(state_read "$1" | jq -r '.state // "unknown"'), not needs-recut" >&2; return 1; }
)
scheduler_issue_transition_allowed() ( # issue stage reason：先验证当前持久状态能否完成 label 转移
  local issue="$1" to="$2" reason="$3" before from
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
  REPO_DIR="$ROOT"
  source "$SCHEDULER_AGENT_LIB" || return 1
  before="$(state_read "$issue")" || return 1
  from="$(jqf -r '.state // "untracked"' <<<"$before")" || return 1
  if [[ "$to" == needs-info ]] && jqf -e '.tracker_parent == true or .state == "tracker"' <<<"$before" >/dev/null 2>&1; then
    return 1
  fi
  issue_transition_allowed "$from" "$to" "$reason"
)
scheduler_conclude_merged_pr() ( # issue pr：合入即写发布状态（#4515 单一事实源）
  local preserved_gh=""
  declare -F gh >/dev/null 2>&1 && preserved_gh="$(declare -f gh)"
  REPO_DIR="$ROOT"
  source "$SCHEDULER_AGENT_LIB" || return 1
  [[ -z "$preserved_gh" ]] || eval "$preserved_gh"

  conclude_merged_run "$1" "$2" "PR #$2 was merged by the autopilot merge lane. Waiting on Postsubmit validate before release."
)
scheduler_issue_state() (
  local f lock_fd
  REPO_DIR="$ROOT"
  source "$SCHEDULER_AGENT_LIB" || return 1
  f="$(state_file "$1")" || return 1
  # issue_transition writes state before the label and rolls back on failure.
  # Defer reconciliation while that transaction is in progress.
  mkdir -p "$STATE_DIR" || return 1
  exec {lock_fd}>"$f.lock" || return 1
  flock -sn "$lock_fd" || return 1
  state_read "$1"
)
scheduler_size_recut_active() (
  REPO_DIR="$ROOT"
  source "$SCHEDULER_AGENT_LIB" || return 0
  stage_unit_active recut "$1"
)
scheduler_recut_route() ( # issue evidence-json → one durable recut route with caller gh preserved
  local preserved_gh="" evidence="$2"
  declare -F gh >/dev/null 2>&1 && preserved_gh="$(declare -f gh)"
  REPO_DIR="$ROOT"
  source "$SCHEDULER_AGENT_LIB" || return 1
  [[ -z "$preserved_gh" ]] || eval "$preserved_gh"
  route_to_recut "$1" "" "$evidence"
)
scheduler_size_recut() ( # issue lines limit unit branch head → one durable recut route
  local evidence
  evidence="$(jq -cn --argjson lines "$2" --argjson limit "$3" --arg unit "$4" --arg branch "$5" --arg head "$6" '{kind:"size-admission",lines:$lines,limit:$limit,unit:$unit,branch:$branch,head:$head}')"
  scheduler_recut_route "$1" "$evidence" || return 1
  REPO_DIR="$ROOT"
  source "$SCHEDULER_AGENT_LIB" || return 1
  state_read "$1" | jq -e '.state == "needs-recut" and .size_admission.lines > .size_admission.limit' >/dev/null
)
scheduler_footprint() (
  local u="$1" state issue actual
  if [[ "$(jq -r '.footprint_source // empty' <<<"$u")" == pr-diff ]] \
    && jq -e '(.footprint | type) == "array"' <<<"$u" >/dev/null; then
    jq -c '.footprint' <<<"$u"; return
  fi
  # Older units kept the triage package prediction beside #4510's write-end
  # record. Once a worker has produced a PR diff, that actual file set is the
  # scope for its next repair and for other units checking the active worker.
  actual="$(jq -r '[.history[]? | select(.stage=="write-end") | .result] | last // empty' <<<"$u")"
  if jq -e 'type == "array"' <<<"$actual" >/dev/null 2>&1; then
    jq -c . <<<"$actual"; return
  fi
  if jq -e 'has("footprint")' <<<"$u" >/dev/null; then jq -c '.footprint' <<<"$u"; return; fi
  REPO_DIR="$ROOT" MODEL_POLICY_SOURCE_CHECK_ONLY=1
  source "$SCHEDULER_AGENT_LIB" || return 1
  issue="$(jq -r '.issue // empty' <<<"$u")"
  state="$(cat "$STATE_DIR/$issue.json" 2>/dev/null)"; [[ -n "$state" ]] || state='{}'
  if jq -e '(.footprint // []) | length > 0' <<<"$u" >/dev/null; then
    jq -c '.footprint' <<<"$u"
  elif jq -e '([.expected_paths[]?, .expected_packages[]?] | length) > 0' <<<"$state" >/dev/null; then
    selection_scope_json <<<"$state"
  else
    issue_change_surface_json "$u" "$(jq -r '.task // ""' <<<"$u")" '[]'
  fi
)
