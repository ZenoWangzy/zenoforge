#!/usr/bin/env bash
# Hand-agent exit handoff (ruling unowned-node-is-a-bug).
#
# When a hand agent exits, its roster row leaves agents.txt within seconds
# (worktree-lifecycle.sh watch). Everything that happens later -- a landing
# that fails an hour after the owner exited, a fix left uncommitted, a
# BLOCKED-ON report written on the way out -- used to have no owner: on
# 2026-10-07/08 five failed landings and one 32.5M-token uncommitted fix sat
# until the supervisor re-dispatched about 15 owners by hand.
#
# dispatch.sh writes a durable per-name registry record that outlives the
# roster row, and the exit watcher stamps the exit HEAD on it. Handoff helpers
# keep each exited owner's next open step in the blocked-agent registry, and
# redispatch_landed_blocked_hand_agents (the only resume path) resumes it with
# a note naming that step. A second exit on the same unresolved step goes to
# the supervisor inbox once instead of looping.
#
# Defines functions only; sourced by dispatch.sh, land-queue.sh and
# worktree-lifecycle.sh. Callers provide NIGHT (and say/H where they use the
# blocked-agent functions below).

hand_registry_dir() { printf '%s/hand-registry\n' "$NIGHT"; }

# hand_registry_record <name> <json-object>: the last dispatch of <name>.
hand_registry_record() {
  local name="$1" entry="$2" dir tmp
  [[ "$name" =~ ^[[:alnum:]_.-]+$ ]] || return 1
  dir="$(hand_registry_dir)"
  mkdir -p -- "$dir" || return 1
  tmp="$(mktemp "$dir/.$name.XXXXXX")" || return 1
  if jq -ce 'select(type == "object")' <<< "$entry" > "$tmp" 2>/dev/null && mv -f -- "$tmp" "$dir/$name.json"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# hand_registry_record_exit <worktree> <pid>: stamp the exit HEAD and whether
# the tree still held uncommitted work, before cleanup may remove the tree.
hand_registry_record_exit() {
  local target="$1" pid="$2" file head dirty=false tmp
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
  for file in "$(hand_registry_dir)"/*.json; do
    [ -f "$file" ] || continue
    jq -e --arg wt "$target" --argjson pid "$pid" '.worktree == $wt and .pid == $pid' "$file" >/dev/null 2>&1 || continue
    head="$(git -C "$target" rev-parse --verify HEAD 2>/dev/null || true)"
    if [ -n "$(git -C "$target" status --porcelain=v1 2>/dev/null)" ]; then dirty=true; fi
    tmp="$(mktemp "$file.XXXXXX")" || return 1
    if jq -c --arg head "$head" --argjson dirty "$dirty" --argjson at "$(date +%s)" \
      '.exit_head = $head | .exit_dirty = $dirty | .exit_at = $at' "$file" > "$tmp" && mv -f -- "$tmp" "$file"; then
      :
    else
      rm -f -- "$tmp"
      return 1
    fi
  done
}

# A pending addendum keeps a clean worktree alive until its one resume is queued.
hand_addendum_pending_for_report() {
  local name="$1" report="$2" pending lock_file heading needs_resume=0 lock_fd
  [[ "$name" =~ ^[[:alnum:]_.-]+$ && "$name" != . && "$name" != .. ]] || return 1
  pending="$NIGHT/$name.pending-addenda"
  [ -s "$pending" ] || return 1
  lock_file="$NIGHT/$name.addenda.lock"
  if ! exec {lock_fd}>>"$lock_file"; then return 0; fi
  if ! flock -s "$lock_fd"; then exec {lock_fd}>&-; return 0; fi
  [ -s "$pending" ] || { flock -u "$lock_fd" || true; exec {lock_fd}>&-; return 1; }
  case "$report" in "~"/*) report="$HOME/${report:2}" ;; esac
  while IFS= read -r heading || [ -n "$heading" ]; do
    [ -n "$heading" ] || continue
    if ! grep -Fq -- "$heading" "$report" 2>/dev/null; then
      needs_resume=1
      break
    fi
  done < "$pending"
  flock -u "$lock_fd" || true
  exec {lock_fd}>&-
  [ "$needs_resume" = 1 ]
}

# Called by the roster exit watcher after worktree cleanup and roster removal.
hand_addendum_after_exit() {
  local target="$1" pid="$2" file entry name brief report helper
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
  for file in "$(hand_registry_dir)"/*.json; do
    [ -f "$file" ] || continue
    entry="$(jq -ce --arg wt "$target" --argjson pid "$pid" \
      'select(.worktree == $wt and .pid == $pid)' "$file" 2>/dev/null || true)"
    [ -n "$entry" ] || continue
    name="$(jq -r '.name // empty' <<< "$entry")"
    [[ "$name" =~ ^[[:alnum:]_.-]+$ && "$name" != . && "$name" != .. ]] || return 0
    brief="$(jq -r '.brief // empty' <<< "$entry")"
    report="$(jq -r '.report // empty' <<< "$entry")"
    [ -n "$brief" ] || brief="$NIGHT/briefs/$name.md"
    [ -n "$report" ] || report="$NIGHT/$name-report.md"
    helper="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/brief-addendum.sh"
    [[ -x "$helper" ]] || return 1
    bash "$helper" --agent-exited "$name" "$target" "$brief" "$report"
    return $?
  done
  return 0
}

hand_registry_entry_live() {
  local entry="$1" pid start_ticks
  pid="$(jq -r '.pid // empty' <<< "$entry")"
  start_ticks="$(jq -r '.start_ticks // empty' <<< "$entry")"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  hand_agent_pid_live "$pid" "$start_ticks"
}

hand_report_first_line() {
  local report="$1" header=""
  case "$report" in "~/"*) report="$HOME/${report:2}" ;; esac
  if [ -r "$report" ]; then IFS= read -r header < "$report" || true; fi
  printf '%s\n' "$header"
}

hand_exit_finish_deferred_landings() {
  local owner="$1" agent_home="${AGENT_HOME:-${H:-$(dirname -- "$NIGHT")}}"
  local land_queue="${ZF_ENGINE_LIVE:-$agent_home/checkout/engine}/land-queue.sh"
  [[ -x "$land_queue" ]] || return 0
  bash "$land_queue" finish-deferred-owner "$owner"
}

# One jq pass over the registry, one line per record:
# worktree US pid US start_ticks US report US branch US exit_head US exit_dirty US record-json US name
# (US = \x1f). Every tick reads every record, so keep per-record work in bash.
hand_registry_rows() {
  local -a files=()
  shopt -s nullglob
  files=("$(hand_registry_dir)"/*.json)
  shopt -u nullglob
  ((${#files[@]})) || return 0
  jq -r 'select(type == "object" and (.name | type) == "string")
    | [(.worktree // ""), (.pid // "" | tostring), (.start_ticks // "" | tostring), (.report // ""),
       (.branch // ""), (.exit_head // ""), (if has("exit_dirty") then (.exit_dirty | tostring) else "" end), tojson, .name] | join("\u001f")' \
    "${files[@]}" 2>/dev/null || true
}

hand_exit_deferred_landing_owners() {
  local agent_home="${AGENT_HOME:-${H:-$(dirname -- "$NIGHT")}}" requests_dir
  local -a requests=()
  requests_dir="${ZF_LAND_QUEUE_DIR:-$agent_home/land-queue}/requests"
  shopt -s nullglob
  requests=("$requests_dir"/*.json)
  shopt -u nullglob
  ((${#requests[@]})) || return 0
  jq -sr '[.[] | select(.post_land_conclusion_pending == true and .post_land_conclusion_deferred == true and
    .post_land_conclusion_exit_checked != true) | .owner] | unique | .[]' "${requests[@]}" 2>/dev/null || true
}

hand_row_live() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] || return 1
  hand_agent_pid_live "$1" "$2"
}

# hand_registry_terminal_exit <head-branch> <head-sha>: 0 when the hand agent
# that pushed this exact PR head has exited with a final report, so the PR's
# next step (merge when green, a PR owner when red) is due now, not after the
# generic ownerless delay.
hand_registry_terminal_exit() {
  local branch="$1" sha="$2" worktree pid ticks report row_branch exit_head exit_dirty entry name rows
  [ -n "$branch" ] && [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  if [ "$#" -ge 3 ]; then rows="$3"; else rows="$(hand_registry_rows)"; fi
  while IFS=$'\x1f' read -r worktree pid ticks report row_branch exit_head exit_dirty entry name; do
    [ "$row_branch" = "$branch" ] && [ "$exit_head" = "$sha" ] && [ "$exit_dirty" != true ] || continue
    hand_row_live "$pid" "$ticks" && continue
    case "$(hand_report_first_line "$report")" in
      'STATUS: DONE'|'STATUS: DONE '*|'STATUS: PR-UPDATED'|'STATUS: PR-UPDATED '*|'STATUS: FOLLOWUP('*) return 0 ;;
    esac
  done <<< "$rows"
  return 1
}

# Worktrees a live hand agent (registry or roster) or an active landing owns.
hand_exit_owned_worktrees() {
  local rows="$1" requests="${ZF_LAND_QUEUE_DIR:-$AGENT_HOME/land-queue}/requests"
  local worktree pid ticks row _rest
  local -a files=()
  while IFS=$'\x1f' read -r worktree pid ticks _rest; do
    [ -n "$worktree" ] || continue
    hand_row_live "$pid" "$ticks" && printf '%s\n' "$worktree"
  done <<< "$rows"
  if [ -r "$NIGHT/agents.txt" ]; then
    while IFS= read -r row || [ -n "$row" ]; do
      [[ "$row" == *$'\t'* ]] || continue
      IFS=$'\x1f' read -r pid _ _ _ worktree _ _ _ _ _ _ ticks _ <<< "${row//$'\t'/$'\x1f'}"
      hand_row_live "$pid" "$ticks" && printf '%s\n' "$worktree"
    done < "$NIGHT/agents.txt"
  fi
  shopt -s nullglob
  files=("$requests"/*.json)
  shopt -u nullglob
  ((${#files[@]})) || return 0
  jq -rs '.[] | select(.state == "queued" or .state == "running") | .worktree // empty' "${files[@]}" 2>/dev/null || true
}

# hand_exit_handoff_need <worktree> <pid> <start-ticks> <report> <exit-dirty> <owned-worktrees>:
# prints "kind<TAB>dependency<TAB>key" for an exited owner whose next step is open.
hand_exit_handoff_need() {
  local worktree="$1" pid="$2" ticks="$3" report="$4" exit_dirty="$5" owned_worktrees="$6" header dependency report_mtime head
  [ -n "$worktree" ] && [ -d "$worktree" ] || return 0
  hand_row_live "$pid" "$ticks" && return 0
  [[ $'\n'"$owned_worktrees"$'\n' == *$'\n'"$worktree"$'\n'* ]] && return 0
  case "$report" in "~/"*) report="$HOME/${report:2}" ;; esac
  header="$(hand_report_first_line "$report")"
  case "$header" in
    'STATUS: BLOCKED-ON '*)
      dependency="${header#STATUS: BLOCKED-ON }"
      case "$dependency" in *$'\t'*) return 0 ;; esac
      report_mtime="$(stat -c %Y -- "$report" 2>/dev/null || printf 0)"
      printf 'blocked\t%s\tblocked %s %s\n' "$dependency" "$dependency" "$report_mtime"
      return 0
      ;;
  esac
  # The exit watcher stamped a clean tree: nothing changes it until the next
  # dispatch, which writes a fresh record. Only stamped-dirty or unstamped trees
  # pay for git status.
  [ "$exit_dirty" != false ] || return 0
  if [ -n "$(git -C "$worktree" status --porcelain=v1 2>/dev/null)" ]; then
    head="$(git -C "$worktree" rev-parse --verify HEAD 2>/dev/null || true)"
    report_mtime="$(stat -c %Y -- "$report" 2>/dev/null || printf 0)"
    printf 'uncommitted\tuncommitted-work\tuncommitted %s %s\n' "$head" "$report_mtime"
  fi
}

hand_exit_handoff_ledger_file() { printf '%s/hand-exit-handoff.json\n' "$NIGHT"; }

hand_exit_handoff_ledger_set() {
  local name="$1" value="$2" file tmp
  file="$(hand_exit_handoff_ledger_file)"
  [ -s "$file" ] || printf '{}\n' > "$file"
  tmp="$(mktemp "$file.XXXXXX")" || return 1
  if jq -c --arg name "$name" --argjson value "$value" '.[$name] = $value' "$file" > "$tmp" && mv -f -- "$tmp" "$file"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

hand_blocked_registry_has() {
  local name="$1"
  [ -s "$BLOCKED_HAND_AGENTS" ] || return 1
  jq -e --arg name "$name" 'type == "array" and any(.[]; .name == $name)' "$BLOCKED_HAND_AGENTS" >/dev/null 2>&1
}

# hand_exit_handoff_open <mode>: walk exited owners with an open next step.
# mode=act (night tick): give each exactly one owner -- the blocked-agent
# registry (resumed by redispatch_landed_blocked_hand_agents) or, when the step
# repeats after a resume or the report is past 24h, the supervisor inbox once.
# mode=report (HEALTH): print the ones that still have no owner.
hand_exit_handoff_open() {
  local mode="$1" BLOCKED_HAND_AGENTS="${BLOCKED_HAND_AGENTS:-$NIGHT/blocked-hand-agents.json}"
  local rows owned_worktrees deferred_owners worktree pid ticks report branch exit_head exit_dirty entry name need kind dependency key previous escalate_reason role out=""
  local -A blocked_names=() escalated_keys=()
  # HEALTH reads history every tick; parse registries once, before any Git work.
  while IFS= read -r name; do
    [ -n "$name" ] && blocked_names["$name"]=1
  done < <(jq -r 'select(type == "array") | .[].name // empty' "$BLOCKED_HAND_AGENTS" 2>/dev/null)
  if [[ "$mode" == report ]]; then
    while IFS=$'\x1f' read -r name key; do
      [ -n "$name" ] && escalated_keys["$name"]="$key"
    done < <(jq -r 'to_entries[] | select(.value.escalated == true) | [.key, .value.key] | join("\u001f")' \
      "$(hand_exit_handoff_ledger_file)" 2>/dev/null)
  fi
  rows="$(hand_registry_rows)"
  owned_worktrees="$(hand_exit_owned_worktrees "$rows")"
  if [[ "$mode" == act ]]; then deferred_owners="$(hand_exit_deferred_landing_owners)"; fi
  while IFS=$'\x1f' read -r worktree pid ticks report branch exit_head exit_dirty entry name; do
    [ -n "$entry" ] || continue
    [[ "$name" =~ ^[[:alnum:]_.-]+$ ]] || continue
    if [[ "$mode" == act && " $deferred_owners " == *" $name "* ]] && ! hand_row_live "$pid" "$ticks"; then
      hand_exit_finish_deferred_landings "$name" || say "HAND-EXIT-LANDING-FINALIZE-FAILED $name"
    fi
    [[ -n "${blocked_names[$name]:-}" ]] && continue
    need="$(hand_exit_handoff_need "$worktree" "$pid" "$ticks" "$report" "$exit_dirty" "$owned_worktrees")"
    [ -n "$need" ] || continue
    IFS=$'\t' read -r kind dependency key <<< "$need"
    if [ "$mode" = report ]; then
      [[ "${escalated_keys[$name]:-}" == "$key" ]] && continue
      out+="${out:+ }$name($kind)"
      continue
    fi
    previous="$(jq -c --arg name "$name" '.[$name] // {}' "$(hand_exit_handoff_ledger_file)" 2>/dev/null || printf '{}')"
    escalate_reason=""
    if [ "$(jq -r '.key // empty' <<< "$previous")" = "$key" ]; then
      [ "$(jq -r '.escalated // false' <<< "$previous")" = true ] && continue
      escalate_reason="resumed once for this step and exited again without resolving it"
    elif blocked_hand_agent_report_expired "$report"; then
      escalate_reason="report older than 24h; past the automatic resume window"
    fi
    if [ -n "$escalate_reason" ]; then
      if AGENT_HOME="${AGENT_HOME:-$H}" supervisor_inbox_append_once "hand-exit-handoff:$name:$key" \
        "hand-exit-handoff name=$name kind=$kind dependency=$dependency worktree=$worktree report=$report: $escalate_reason"; then
        hand_exit_handoff_ledger_set "$name" "$(jq -cn --arg key "$key" --arg kind "$kind" '{key:$key,kind:$kind,escalated:true,escalated_at:now}')" \
          || say "HAND-EXIT-HANDOFF-LEDGER-FAILED $name"
        say "HAND-EXIT-HANDOFF-ESCALATED $name kind=$kind dependency=$dependency"
      else
        say "HAND-EXIT-HANDOFF-ESCALATION-FAILED $name kind=$kind"
      fi
      continue
    fi
    role="$(jq -r '.role // empty' <<< "$entry")"
    if [ -z "$role" ]; then
      role="$(hand_agent_role_for_identity "$(jq -r '.model // empty' <<< "$entry")" "$(jq -r '.effort // empty' <<< "$entry")" 2>/dev/null || true)"
    fi
    if blocked_hand_agent_upsert "$pid" "$name" "$role" "$worktree" \
      "$(jq -r '.brief // empty' <<< "$entry")" "$report" "$(jq -r '.log // empty' <<< "$entry")" \
      "$(jq -r '.attempt // 0' <<< "$entry")" "$dependency" "$ticks" \
      "$(jq -r '.owned_issues // empty' <<< "$entry")" "$(jq -r '.owned_nodes // empty' <<< "$entry")"; then
      hand_exit_handoff_ledger_set "$name" "$(jq -cn --arg key "$key" --arg kind "$kind" '{key:$key,kind:$kind,registered_at:now,escalated:false}')" \
        || say "HAND-EXIT-HANDOFF-LEDGER-FAILED $name"
      say "HAND-EXIT-HANDOFF-REGISTERED $name kind=$kind dependency=$dependency worktree=$worktree"
    else
      say "HAND-EXIT-HANDOFF-REGISTER-FAILED $name kind=$kind dependency=$dependency"
    fi
  done <<< "$rows"
  [ "$mode" != report ] || printf '%s\n' "$out"
}

hand_exit_handoff_sweep() { hand_exit_handoff_open act; }

# Exited owners with an open next step and no owner: HEALTH hand-agents reads this.
hand_exit_handoff_ownerless() { hand_exit_handoff_open report; }

hand_blocked_resume_note() {
  local dependency="$1" ticket request reason sha fields
  case "$dependency" in
    lesson-metadata-fix-forward\ *)
      ticket="${dependency#lesson-metadata-fix-forward }"
      request="${ZF_LAND_QUEUE_DIR:-$AGENT_HOME/land-queue}/requests/$ticket.json"
      sha="$(jq -r '.lesson_metadata_fix_forward.sha // "unknown"' "$request" 2>/dev/null)"
      fields="$(jq -r '.lesson_metadata_fix_forward.fields // "missing details"' "$request" 2>/dev/null | tr '\r\n\t' '   ' | sed 's/[[:space:]]*$//' | cut -c1-240)"
      printf 'RESUME: post-land metadata fix-forward for landing %s at %s: %s. Compare every named recurrence candidate and write the difference in recurrence_difference; do not append candidate IDs without comparison. Commit, rebase, rerun fast schema check, and re-enqueue.\n' \
        "$ticket" "$sha" "$fields"
      ;;
    landing-failed\ *)
      ticket="${dependency#landing-failed }"
      request="${ZF_LAND_QUEUE_DIR:-$AGENT_HOME/land-queue}/requests/$ticket.json"
      reason="$(jq -j '.reason // empty' "$request" 2>/dev/null | tr '\r\n\t' '   ' | cut -c1-200)"
      sha="$(jq -r '.lesson_metadata_fix_forward.sha // empty' "$request" 2>/dev/null)"
      fields="$(jq -r '.lesson_metadata_fix_forward.fields // empty' "$request" 2>/dev/null | tr '\r\n\t' '   ' | sed 's/[[:space:]]*$//' | cut -c1-240)"
      if [[ -n "$fields" ]]; then
        printf 'RESUME: landing %s failed: %s. Also fix post-land metadata at %s: %s. Compare every named recurrence candidate and write the difference in recurrence_difference; do not append candidate IDs without comparison. Log: %s/logs/%s.log. Fix in this worktree, rebase on origin/main, rerun checks, and re-enqueue.\n' \
          "$ticket" "${reason:-unknown}" "$sha" "$fields" "${ZF_LAND_QUEUE_DIR:-$AGENT_HOME/land-queue}" "$ticket"
      else
        printf 'RESUME: landing %s failed: %s. Log: %s/logs/%s.log. Find the failing check, fix it in this worktree, drop a trailing fold commit (git reset --keep HEAD~1), rebase on origin/main, rerun that check, and re-enqueue the landing.\n' \
          "$ticket" "${reason:-unknown}" "${ZF_LAND_QUEUE_DIR:-$AGENT_HOME/land-queue}" "$ticket"
      fi
      ;;
    uncommitted-work)
      printf 'RESUME: you exited with uncommitted changes in this worktree. Finish the work if it is incomplete, commit what belongs to the fix (discard the rest), and re-land: land-queue enqueue for pipeline code, push and update the PR for product code.\n'
      ;;
    *) printf 'dependency landed: %s\n' "$dependency" ;;
  esac
}

# ---- blocked-agent registry
blocked_hand_agent_remove() {
  local name="$1" tmp
  [ -f "$BLOCKED_HAND_AGENTS" ] || return 0
  jq -e 'type=="array"' "$BLOCKED_HAND_AGENTS" >/dev/null 2>&1 || return 1
  tmp="$(mktemp "$NIGHT/.blocked-hand-agents.XXXXXX")" || return 1
  jq --arg name "$name" 'map(select(.name != $name))' "$BLOCKED_HAND_AGENTS" > "$tmp" \
    && mv -- "$tmp" "$BLOCKED_HAND_AGENTS" || { rm -f -- "$tmp"; return 1; }
}

blocked_hand_agent_report_expired() {
  local report="$1" modified now
  modified="$(stat -c %Y -- "$report" 2>/dev/null || true)"
  [[ "$modified" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s)"
  (( now - modified > 86400 ))
}

blocked_hand_agent_set_dependency_satisfied() {
  local name="$1" satisfied="$2" tmp
  [ -f "$BLOCKED_HAND_AGENTS" ] || return 0
  tmp="$(mktemp "$NIGHT/.blocked-hand-agents.XXXXXX")" || return 1
  jq --arg name "$name" --argjson satisfied "$satisfied" \
    'map(if .name == $name then .dependency_satisfied = $satisfied else . end)' \
    "$BLOCKED_HAND_AGENTS" > "$tmp" && mv -- "$tmp" "$BLOCKED_HAND_AGENTS" \
    || { rm -f -- "$tmp"; return 1; }
}

blocked_hand_agent_upsert() {
  local pid="$1" name="$2" role="$3" worktree="$4" brief="$5" report="$6" log="$7" attempt="$8" dependency="$9" start_ticks="${10}" owned_issues="${11}" owned_nodes="${12}" item tmp brief_file dependency_satisfied=false
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$attempt" =~ ^[0-9]+$ && "$name" =~ ^[[:alnum:]_.-]+$ ]] || return 1
  hand_agent_role_is_supported "$role" || return 1
  case "$dependency" in *$'\t'*|*$'\n'*) return 1 ;; esac
  if blocked_hand_agent_dependency_landed "$dependency"; then dependency_satisfied=true; fi
  [ -f "$BLOCKED_HAND_AGENTS" ] || printf '[]\n' > "$BLOCKED_HAND_AGENTS"
  jq -e 'type=="array"' "$BLOCKED_HAND_AGENTS" >/dev/null 2>&1 || return 1
  brief_file="$(jq_arg_file "$brief")" || return 1
  if ! item="$(jq -cn --argjson pid "$pid" --arg name "$name" --arg role "$role" \
    --arg worktree "$worktree" --rawfile brief "$brief_file" --arg report "$report" --arg log "$log" \
    --argjson attempt "$attempt" --arg dependency "$dependency" --arg start_ticks "$start_ticks" \
    --arg owned_issues "$owned_issues" --arg owned_nodes "$owned_nodes" --argjson dependency_satisfied "$dependency_satisfied" \
    --argjson blocked_at "$(date +%s)" \
    '{pid:$pid,name:$name,role:$role,worktree:$worktree,brief:$brief,report:$report,log:$log,attempt:$attempt,dependency:$dependency,dependency_satisfied:$dependency_satisfied,start_ticks:$start_ticks,owned_issues:$owned_issues,owned_nodes:$owned_nodes,blocked_at:$blocked_at}')"; then
    rm -f -- "$brief_file"
    return 1
  fi
  rm -f -- "$brief_file"
  tmp="$(mktemp "$NIGHT/.blocked-hand-agents.XXXXXX")" || return 1
  jq --argjson item "$item" 'map(select(.name != $item.name)) + [$item]' "$BLOCKED_HAND_AGENTS" > "$tmp" \
    && mv -- "$tmp" "$BLOCKED_HAND_AGENTS" || { rm -f -- "$tmp"; return 1; }
  say "HAND-AGENT-BLOCKED-RECORDED $name dependency=$dependency"
}

capture_blocked_hand_agents() {
  local row pid name model effort worktree brief report log attempt started_at role start_ticks owned_issues owned_nodes header dependency ticket
  local -A latest_rows=()
  [ -f "$NIGHT/agents.txt" ] || return 0
  while IFS= read -r row || [ -n "$row" ]; do
    if [[ "$row" == *$'\t'* ]]; then
      IFS=$'\x1f' read -r pid name model effort worktree brief report log attempt started_at role start_ticks owned_issues owned_nodes \
        <<< "${row//$'\t'/$'\x1f'}"
    else
      read -r pid name model worktree _ <<< "$row"
      effort=max; brief=""; report="$NIGHT/$name-report.md"; log=""; attempt=0; start_ticks=""; owned_issues=""; owned_nodes=""
    fi
    [[ "$name" =~ ^[[:alnum:]_.-]+$ ]] || continue
    latest_rows["$name"]="$row"
  done < "$NIGHT/agents.txt"
  for name in "${!latest_rows[@]}"; do
    row="${latest_rows[$name]}"
    if [[ "$row" == *$'\t'* ]]; then
      IFS=$'\x1f' read -r pid name model effort worktree brief report log attempt started_at role start_ticks owned_issues owned_nodes \
        <<< "${row//$'\t'/$'\x1f'}"
    else
      read -r pid name model worktree _ <<< "$row"
      effort=max; brief=""; report="$NIGHT/$name-report.md"; log=""; attempt=0; start_ticks=""; owned_issues=""; owned_nodes=""
    fi
    [ -n "$report" ] || report="$NIGHT/$name-report.md"
    case "$report" in "~/"*) report="$HOME/${report:2}" ;; esac
    header="$(sed -n '1p' "$report" 2>/dev/null || true)"
    case "$header" in
      'STATUS: BLOCKED-ON '*)
        dependency="${header#STATUS: BLOCKED-ON }"
        [ -n "${role:-}" ] || role="$(hand_agent_role_for_identity "$model" "$effort" 2>/dev/null || true)"
        if blocked_hand_agent_report_expired "$report"; then
          blocked_hand_agent_remove "$name" || say "HAND-AGENT-BLOCKED-REMOVE-FAILED $name"
          say "HAND-AGENT-BLOCKED-EXPIRED $name report-older-than=24h"
        else
          blocked_hand_agent_upsert "$pid" "$name" "${role:-}" "$worktree" "$brief" "$report" "$log" "${attempt:-0}" "$dependency" "${start_ticks:-}" "${owned_issues:-}" "${owned_nodes:-}" || \
            say "HAND-AGENT-BLOCKED-RECORD-FAILED $name"
        fi
        ;;
      DONE|'STATUS: DONE'|'STATUS: LANDING-QUEUED')
        blocked_hand_agent_remove "$name" || say "HAND-AGENT-BLOCKED-REMOVE-FAILED $name"
        ;;
      'STATUS: LANDING-QUEUED '*)
        ticket="${header#STATUS: LANDING-QUEUED }"
        if [[ "$ticket" =~ ^[0-9]+$ ]]; then
          blocked_hand_agent_remove "$name" || say "HAND-AGENT-BLOCKED-REMOVE-FAILED $name"
        fi
        ;;
    esac
  done
}

blocked_hand_agent_dependency_landed() {
  local dependency="$1" issue agent report request ticket roster_row roster_name roster_report state
  case "$dependency" in
    uncommitted-work) return 0 ;;
    land-lock) return 0 ;; # the landing lock no longer exists, so nothing is left to wait on
    issue\ *)
      issue="${dependency#issue }"
      [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
      state="$(timeout 15 gh issue view "$issue" -R "$REPO" --json state --jq .state 2>/dev/null || true)"
      [ "$state" = CLOSED ]
      ;;
    agent\ *)
      agent="${dependency#agent }"
      [[ "$agent" =~ ^[[:alnum:]_.-]+$ ]] || return 1
      report="$NIGHT/$agent-report.md"
      if [ -f "$NIGHT/agents.txt" ]; then
        while IFS= read -r roster_row || [ -n "$roster_row" ]; do
          [[ "$roster_row" == *$'\t'* ]] || continue
          IFS=$'\x1f' read -r _ roster_name _ _ _ _ roster_report _ _ \
            <<< "${roster_row//$'\t'/$'\x1f'}"
          [ "$roster_name" = "$agent" ] && [ -n "$roster_report" ] && report="$roster_report"
        done < "$NIGHT/agents.txt"
      fi
      case "$(sed -n '1p' "$report" 2>/dev/null)" in DONE|'STATUS: DONE') return 0 ;; esac
      return 1
      ;;
    landing-failed\ *)
      ticket="${dependency#landing-failed }"
      [[ "$ticket" =~ ^[0-9]{20}$ ]] || return 1
      request="$H/land-queue/requests/$ticket.json"
      jq -e --arg ticket "$ticket" '.ticket == $ticket and .state == "failed" and (.report | type == "string")' \
        "$request" >/dev/null 2>&1 || return 1
      report="$(jq -r '.report' "$request")"
      grep -Fq "LANDING-FAILED $ticket " "$report"
      ;;
    lesson-metadata-fix-forward\ *)
      ticket="${dependency#lesson-metadata-fix-forward }"
      [[ "$ticket" =~ ^[0-9]{20}$ ]] || return 1
      request="$H/land-queue/requests/$ticket.json"
      jq -e --arg ticket "$ticket" \
        '.ticket == $ticket and .lesson_metadata_fix_forward.state == "queued" and .lesson_metadata_fix_forward.owner_queued == true' \
        "$request" >/dev/null 2>&1
      ;;
    *)
      timeout 30 git -C "$REPO_DIR" log origin/main --format=%s 2>/dev/null | grep -Eq -- "$dependency"
      ;;
  esac
}

redispatch_landed_blocked_hand_agents() {
  local entry pid name role legacy_model legacy_effort worktree brief report log attempt dependency start_ticks owned_issues owned_nodes dependency_satisfied resume_worktree
  [ -f "$BLOCKED_HAND_AGENTS" ] || return 0
  jq -e 'type=="array"' "$BLOCKED_HAND_AGENTS" >/dev/null 2>&1 || { say "HAND-AGENT-BLOCKED-LIST-INVALID; redispatch skipped"; return 0; }
  while IFS= read -r entry; do
    pid="$(jq -r '.pid' <<< "$entry")"
    name="$(jq -r '.name' <<< "$entry")"
    role="$(jq -r '.role // empty' <<< "$entry")"
    if [ -z "$role" ]; then
      legacy_model="$(jq -r '.model // empty' <<< "$entry")"
      legacy_effort="$(jq -r '.effort // empty' <<< "$entry")"
      role="$(hand_agent_role_for_identity "$legacy_model" "$legacy_effort" 2>/dev/null || true)"
    fi
    worktree="$(jq -r '.worktree' <<< "$entry")"
    brief="$(jq -r '.brief' <<< "$entry")"
    report="$(jq -r '.report' <<< "$entry")"
    log="$(jq -r '.log' <<< "$entry")"
    attempt="$(jq -r '.attempt' <<< "$entry")"
    dependency="$(jq -r '.dependency' <<< "$entry")"
    start_ticks="$(jq -r '.start_ticks // empty' <<< "$entry")"
    owned_issues="$(jq -r '.owned_issues // empty' <<< "$entry")"
    owned_nodes="$(jq -r '.owned_nodes // empty' <<< "$entry")"
    if blocked_hand_agent_report_expired "$report"; then
      blocked_hand_agent_remove "$name" || say "HAND-AGENT-BLOCKED-REMOVE-FAILED $name"
      say "HAND-AGENT-BLOCKED-EXPIRED $name report-older-than=24h"
      continue
    fi
    hand_agent_role_is_supported "$role" || { say "HAND-AGENT-BLOCKED-ROLE-INVALID $name; redispatch skipped"; continue; }
    if blocked_hand_agent_dependency_landed "$dependency"; then
      dependency_satisfied=true
      blocked_hand_agent_set_dependency_satisfied "$name" true || say "HAND-AGENT-BLOCKED-UPDATE-FAILED $name"
    else
      dependency_satisfied=false
      blocked_hand_agent_set_dependency_satisfied "$name" false || say "HAND-AGENT-BLOCKED-UPDATE-FAILED $name"
      continue
    fi
    hand_agent_pid_live "$pid" "$start_ticks" && continue
    resume_worktree="$(agent_latest_worktree_for_hand "${ZF_HAND_REPO_DIR:-$REPO_DIR}" \
      "$name" "$(hand_registry_dir)/$name.json" "$report" "$worktree" 2>/dev/null || true)"
    if [[ -z "$resume_worktree" ]]; then
      supervisor_inbox_append_once "hand-resume-worktree-unusable:$name" \
        "hand-resume-worktree-unusable name=$name worktree=$worktree report=$report registry=$(hand_registry_dir)/$name.json" \
        || say "HAND-AGENT-BLOCKED-RESUME-INBOX-FAILED $name"
      say "HAND-AGENT-BLOCKED-RESUME-WORKTREE-UNUSABLE $name worktree=$worktree"
      continue
    fi
    worktree="$resume_worktree"
    if HAND_ISSUES="$owned_issues" HAND_NODES="$owned_nodes" bash "${ZF_ENGINE_DIR:-$REPO_DIR/engine}/night/dispatch.sh" \
      "$worktree" "$brief" "$name" "$role" "$report" "$attempt" "$(hand_blocked_resume_note "$dependency")" >> "$LOG" 2>&1; then
      blocked_hand_agent_remove "$name" || say "HAND-AGENT-BLOCKED-REMOVE-FAILED $name after redispatch"
      say "HAND-AGENT-BLOCKED-REDISPATCHED $name dependency=$dependency worktree=$worktree"
    else
      say "HAND-AGENT-BLOCKED-REDISPATCH-FAILED $name dependency=$dependency"
    fi
  done < <(jq -c '.[]' "$BLOCKED_HAND_AGENTS")
}
