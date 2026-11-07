# Per-item subshells (one per candidate or owner) must not `source lib.sh`: loading it costs about 0.5s.
# They source the definition-only lib.d modules they call instead; a subshell keeps those
# names out of the scheduler. Needing another lib.sh function per item means extracting it into such a module.
scheduler_scope_lib() { # module... -> source lib.d/<module>.sh into the calling subshell
  local module
  for module in "$@"; do source "$SCHEDULER_SCOPE_LIB_DIR/$module.sh" || return 1; done
}
# The lib.sh values a pure subshell cannot derive (REPO from the origin remote, lib's cwd) are read from one
# lib.sh load per scheduler process. Call it in the parent shell: a command substitution cannot cache.
scheduler_lib_context() {
  local out
  [[ "${SCHEDULER_LIB_CONTEXT_FOR:-}" == "$SCHEDULER_AGENT_LIB" ]] && return 0
  out="$(REPO_DIR="$ROOT" MODEL_POLICY_SOURCE_CHECK_ONLY=1; source "$SCHEDULER_AGENT_LIB" >/dev/null || exit 1; printf '%s\n%s\n' "$REPO" "$REPO_DIR")" || return 1
  { IFS= read -r SCHEDULER_LIB_REPO; IFS= read -r SCHEDULER_LIB_REPO_DIR; } <<<"$out"
  SCHEDULER_LIB_CONTEXT_FOR="$SCHEDULER_AGENT_LIB"
}
scheduler_jq_arg_file() (
  REPO_DIR="$ROOT"
  source "$SCHEDULER_AGENT_LIB" || return 1
  jq_arg_file "$1"
)
scheduler_issue_intake_parent_reason() (
  local preserved_gh=""
  declare -F gh >/dev/null 2>&1 && preserved_gh="$(declare -f gh | sed '1s/^gh ()/scheduler_gh ()/')"
  scheduler_lib_context || return 2
  REPO="$SCHEDULER_LIB_REPO"
  cd "$SCHEDULER_LIB_REPO_DIR" || return 2
  scheduler_scope_lib selection-scope || return 2
  if [[ -n "$preserved_gh" ]]; then
    eval "$preserved_gh"
    TICK_INTAKE_GH_INVOKE=scheduler_gh
    gh() { intake_gh_read "$@"; }
  fi
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
  source "${SCHEDULER_SCOPE_LIB_DIR%/lib.d}/write-guard.sh" && agent_pipeline_write_guard 'scheduler_issue_state' "$AGENT_HOME" || return 1
  scheduler_scope_lib issue-state || return 1
  STATE_DIR="$AGENT_HOME/state"
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
  # An on-hold issue stays on-hold (route_to_recut records the evidence and keeps the hold): the recut is queued behind
  # that hold, which reconcile_size_recuts parks and lifts, so it counts as routed.
  state_read "$1" | jq -e '(.state == "needs-recut" or .state == "on-hold") and .size_admission.lines > .size_admission.limit' >/dev/null
)
scheduler_footprint_filter_main() (
  local scope="$1" preserve_missing="${2:-false}" main_ref=refs/remotes/origin/main specs='' path object kept='' objects_output index
  local -a paths=() objects=()
  [[ "$preserve_missing" == true ]] && { printf '%s\n' "$scope"; return 0; }
  jq -e 'type == "array" and all(.[]; type == "string")' <<<"$scope" >/dev/null 2>&1 \
    || { printf '%s\n' "$scope"; return 0; }
  mapfile -t paths < <(jq -r '.[]' <<<"$scope")
  ((${#paths[@]})) || { printf '[]\n'; return 0; }
  # A missing/stale main ref cannot prove that a prediction is dead; keep the
  # current scope until the scheduler has a readable main tree again.
  git -C "$ROOT" cat-file -e "$main_ref^{tree}" 2>/dev/null || { printf '%s\n' "$scope"; return 0; }
  for path in "${paths[@]}"; do specs+="$main_ref:$path"$'\n'; done
  objects_output="$(printf '%s' "$specs" | git -C "$ROOT" cat-file --batch-check='%(objectname)' 2>/dev/null)" \
    || { printf '%s\n' "$scope"; return 0; }
  mapfile -t objects <<<"$objects_output"
  ((${#objects[@]} == ${#paths[@]})) || { printf '%s\n' "$scope"; return 0; }
  for object in "${objects[@]}"; do
    [[ -n "$object" ]] || { printf '%s\n' "$scope"; return 0; }
  done
  for ((index=0; index<${#paths[@]}; index++)); do
    object="${objects[$index]:-}"
    [[ -n "$object" && "$object" != *' missing' ]] || continue
    kept+="${paths[$index]}"$'\n'
  done
  printf '%s' "$kept" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique'
)

scheduler_footprint() (
  local u="$1" state issue actual scope preserve_missing=false
  if [[ "$(jq -r '.footprint_source // empty' <<<"$u")" == pr-diff ]] \
    && jq -e '(.footprint | type) == "array" and (.footprint | length) > 0' <<<"$u" >/dev/null; then
    scope="$(jq -c '.footprint' <<<"$u")"
    preserve_missing=true
  else
    # Older units kept the triage package prediction beside #4510's write-end
    # record. Once a worker has produced a PR diff, preserve paths it created.
    # An empty array (a run that wrote nothing, or an empty PR-diff read) is no
    # information: it falls through to the ledger footprint and the fallbacks below.
    actual="$(jq -r '[.history[]? | select(.stage=="write-end") | .result] | last // empty' <<<"$u")"
    if jq -e 'type == "array" and length > 0' <<<"$actual" >/dev/null 2>&1; then
      scope="$(jq -c . <<<"$actual")"
      preserve_missing=true
    else
      scheduler_scope_lib selection-scope || return 1
      issue="$(jq -r '.issue // empty' <<<"$u")"
      state="$(cat "$AGENT_HOME/state/$issue.json" 2>/dev/null)"; [[ -n "$state" ]] || state='{}'
      if jq -e '(.footprint // []) | length > 0' <<<"$u" >/dev/null; then
        scope="$(jq -c '.footprint' <<<"$u")"
      elif jq -e '([.expected_paths[]?, .expected_packages[]?] | length) > 0' <<<"$state" >/dev/null; then
        scope="$(selection_scope_json <<<"$state")"
      else
        scope="$(issue_change_surface_json "$u" "$(jq -r '.task // ""' <<<"$u")" '[]')"
      fi
    fi
  fi
  scheduler_footprint_filter_main "$scope" "$preserve_missing"
)
